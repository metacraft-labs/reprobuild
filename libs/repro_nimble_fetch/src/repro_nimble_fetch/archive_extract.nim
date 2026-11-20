## Extracting a source archive in process, confined to a staging directory.
##
## Threat model G11. A source archive comes from a mirror (the canonical
## archive) or from an origin's forge (a `.tar.gz` of the commit). Neither is
## trusted, so this reader never hands an archive to `tar`: it parses the
## POSIX ustar format itself (with pax extended headers,
## https://pubs.opengroup.org/onlinepubs/9799919799/utilities/pax.html) and
## applies, to every member, the rule of threat-model control C6 that the
## binary cache's own extractor applies:
##
## 1. **Names.** A member name that is empty, absolute, holds a NUL, or has an
##    empty, `.` or `..` component is refused.
## 2. **No write through a link** (`repro_core/confined_write`,
##    `refuseWriteThroughSymlink`): no component of the path a member is
##    written to may already be a symbolic link, the member itself included.
##    So `d -> /etc` followed by `d/passwd` is refused at `d/passwd`.
## 3. **Kinds.** Regular files, directories and symbolic links are extracted.
##    A hard link, a device, a FIFO, a contiguous file, a GNU long-name record
##    or any other type is refused: none can come from a git tree.
## 4. **Duplicates.** A member whose path was already extracted is refused,
##    so a later member cannot replace an earlier one after it was checked.
## 5. **Links stay inside.** After the last member, every link's target is
##    resolved lexically from the link's directory; one that is absolute,
##    leaves the tree or passes through another link is refused (the rule the
##    generator applies when it marks such a version `unreadable`).
## 6. **Bounds.** At most `maxEntries` members and `maxBytes` of content.
## 7. **Well-formed.** Every header's checksum is verified, a member's data
##    must lie inside the archive, the archive must end with its end-of-archive
##    block, and a pax `size` must equal the header's (the data is located by
##    the header's), so no two readers can see different members.
##
## A refusal is an `ExtractRefusal` naming the member and the rule; the
## caller discards the whole staging directory (`fetch.nim`). Modes are
## normalized: a regular file is written 0644, or 0755 when its archive mode
## has the owner executable bit, exactly what the canonical tree digest
## records; owners and times are not restored.

import std/[os, strutils, tables]

import repro_core/confined_write

import repro_nimble_generator/source_tree

type
  ExtractRule* = enum
    xrName = "name"                 ## rule 1
    xrThroughLink = "through-link"  ## rule 2
    xrKind = "kind"                 ## rule 3 (hard link, device, ...)
    xrDuplicate = "duplicate"       ## rule 4
    xrLinkOutside = "link-outside"  ## rule 5
    xrBounds = "bounds"             ## rule 6
    xrMalformed = "malformed"       ## not a well-formed archive

  ExtractRefusal* = object of IOError
    rule*: ExtractRule
    member*: string

  ExtractLimits* = object
    maxEntries*: int
    maxBytes*: int64

  ExtractOptions* = object
    stripComponents*: int
      ## leading path components every member must have and loses (a forge
      ## archive's single `<repo>-<commit>/` directory: 1)
    subdir*: string
      ## after stripping, keep only the members under this directory, rooted
      ## there (a package's `?subdir=`); "" keeps everything
    limits*: ExtractLimits

  ExtractedTree* = object
    files*, links*: int
    bytes*: int64

const DefaultExtractLimits* = ExtractLimits(maxEntries: 200_000,
  maxBytes: 512'i64 * 1024 * 1024)
  ## The generator's own transfer bound (`egress.DefaultLimits.maxBytes`): a
  ## source the generator could not have fetched is not one a client takes,
  ## and a decompression bomb costs at most this much memory.

proc refusal(rule: ExtractRule; member, detail: string) {.noreturn.} =
  var e = newException(ExtractRefusal, "archive member " & member.escape() &
    " refused (" & $rule & "): " & detail)
  e.rule = rule
  e.member = member
  raise e

proc cstr(block512: string; at, width: int): string =
  ## A NUL-terminated header field.
  result = block512[at ..< at + width]
  let z = result.find('\0')
  if z >= 0: result.setLen(z)

proc octalField(block512: string; at, width: int; member: string): int64 =
  ## An octal numeric field, or a base-256 one (high bit of the first byte),
  ## as GNU tar and pax write large sizes.
  if (ord(block512[at]) and 0x80) != 0:
    if (ord(block512[at]) and 0x40) != 0:
      refusal(xrMalformed, member, "negative base-256 number")
    var v = int64(ord(block512[at]) and 0x3f)
    for i in at + 1 ..< at + width:
      if v > (high(int64) shr 8):
        refusal(xrBounds, member, "number too large")
      v = (v shl 8) or int64(ord(block512[i]))
    return v
  let text = cstr(block512, at, width).strip(chars = {' ', '\0'})
  if text.len == 0: return 0
  for c in text:
    if c notin {'0'..'7'}:
      refusal(xrMalformed, member, "non-octal numeric field " & text.escape())
  if text.len > 21:
    refusal(xrBounds, member, "number too large")
  fromOct[int64](text)

proc checksumOk(block512: string): bool =
  var sum = 0'i64
  for i in 0 ..< 512:
    sum += (if i in 148 ..< 156: 32 else: ord(block512[i]))
  let stored = cstr(block512, 148, 8).strip(chars = {' ', '\0'})
  if stored.len == 0: return false
  for c in stored:
    if c notin {'0'..'7'}: return false
  fromOct[int64](stored) == sum

proc parsePax(body, member: string): Table[string, string] =
  ## `<len> <key>=<value>\n` records.
  var pos = 0
  while pos < body.len:
    let sp = body.find(' ', pos)
    if sp < 0: refusal(xrMalformed, member, "pax record without a length")
    var n: int
    try: n = parseInt(body[pos ..< sp])
    except ValueError: refusal(xrMalformed, member, "pax record length")
    if n <= 0 or pos + n > body.len or body[pos + n - 1] != '\n':
      refusal(xrMalformed, member, "pax record overruns its header")
    let rec = body[sp + 1 ..< pos + n - 1]
    let eq = rec.find('=')
    if eq <= 0: refusal(xrMalformed, member, "pax record without a key")
    result[rec[0 ..< eq]] = rec[eq + 1 .. ^1]
    pos += n

proc safeComponents(name: string): seq[string] =
  ## Rule 1: the components of a member name, or a refusal.
  if name.len == 0:
    refusal(xrName, name, "empty name")
  if '\0' in name:
    refusal(xrName, name, "name holds NUL")
  if name.startsWith("/"):
    refusal(xrName, name, "absolute name")
  var n = name
  if n.endsWith("/"): n.setLen(n.len - 1)
  for part in n.split('/'):
    if part.len == 0 or part == "." or part == "..":
      refusal(xrName, name, "the component " & part.escape() &
        " is empty, `.` or `..`")
    result.add part

proc extractArchive*(archive: string; staging: string;
                     options: ExtractOptions): ExtractedTree =
  ## Extract the plain (uncompressed) tar ``archive`` into ``staging``, an
  ## empty directory private to the caller, under the module's rules. Raises
  ## `ExtractRefusal` for a refused or malformed archive, leaving whatever it
  ## wrote for the caller to discard.
  var pos = 0
  var pending = initTable[string, string]()  # pax 'x' for the next member
  var written = initTable[string, char]()    # rel -> '0' file, '5' dir, '2' link
  var links: seq[(string, string)]
  var entries = 0
  let limits = options.limits
  let subPrefix =
    if options.subdir.len > 0: options.subdir.strip(chars = {'/'}) & "/"
    else: ""
  var stripTop = ""
  while true:
    if pos + 512 > archive.len:
      refusal(xrMalformed, "", "the archive ends without its end-of-archive " &
        "blocks")
    let header = archive[pos ..< pos + 512]
    pos += 512
    var allZero = true
    for c in header:
      if c != '\0':
        allZero = false
        break
    if allZero:
      break
    if not checksumOk(header):
      refusal(xrMalformed, cstr(header, 0, 100), "header checksum mismatch")
    let typeflag = header[156]
    var name = cstr(header, 0, 100)
    let magic = header[257 ..< 263]
    if magic.startsWith("ustar"):
      let prefix = cstr(header, 345, 155)
      if prefix.len > 0: name = prefix & "/" & name
    var linkName = cstr(header, 157, 100)
    let size = octalField(header, 124, 12, name)
    if size < 0 or size > archive.len - pos:
      refusal(xrMalformed, name, "the member's size runs past the archive")
    let body = archive[pos ..< pos + int(size)]
    pos += int((size + 511) div 512 * 512)
    if typeflag in {'x', 'g'}:
      if size > 1024 * 1024:
        refusal(xrBounds, name, "pax header larger than 1 MiB")
      if typeflag == 'x':
        pending = parsePax(body, name)
      # A global header ('g') carries only comments here (a forge's commit
      # id); a global path or linkpath would apply to every member, which no
      # source archive needs, so it is refused.
      elif "path" in parsePax(body, name) or "linkpath" in parsePax(body, name):
        refusal(xrMalformed, name, "a global pax header sets a path")
      continue
    if "path" in pending: name = pending["path"]
    if "linkpath" in pending: linkName = pending["linkpath"]
    if "size" in pending and pending["size"] != $size:
      # The member's data was located by the header's size; a pax size that
      # says otherwise would make another reader see other members.
      refusal(xrMalformed, name, "the pax size " & pending["size"].escape() &
        " disagrees with the header's " & $size)
    pending.clear()
    inc entries
    if entries > limits.maxEntries:
      refusal(xrBounds, name, "more than " & $limits.maxEntries & " members")
    var parts = safeComponents(name)
    # Strip the forge's top directory: every member is under the same one.
    if options.stripComponents > 0:
      if options.stripComponents != 1:
        refusal(xrMalformed, name, "only one component can be stripped")
      if stripTop.len == 0: stripTop = parts[0]
      elif parts[0] != stripTop:
        refusal(xrName, name, "outside the archive's top directory " &
          stripTop.escape())
      parts = parts[1 .. ^1]
      if parts.len == 0:
        if typeflag != '5':
          refusal(xrKind, name, "the top directory is not a directory")
        continue
    var rel = parts.join("/")
    if subPrefix.len > 0:
      if not (rel & "/").startsWith(subPrefix): continue
      if rel & "/" == subPrefix: continue
      rel = rel[subPrefix.len .. ^1]
    if rel in written:
      refusal(xrDuplicate, name, "a second member at " & rel.escape())
    case typeflag
    of '0', '\0':
      try: refuseWriteThroughSymlink(staging, rel)
      except IOError as e: refusal(xrThroughLink, name, e.msg)
      let mode = octalField(header, 100, 8, name)
      result.bytes += size
      if result.bytes > limits.maxBytes:
        refusal(xrBounds, name, "the content passes " & $limits.maxBytes &
          " bytes")
      let abs = staging / rel
      createDir(parentDir(abs))
      writeFile(abs, body)
      setFilePermissions(abs,
        if (mode and 0o100) != 0:
          {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
           fpOthersRead, fpOthersExec}
        else:
          {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
      written[rel] = '0'
      inc result.files
    of '5':
      try: refuseWriteThroughSymlink(staging, rel)
      except IOError as e: refusal(xrThroughLink, name, e.msg)
      createDir(staging / rel)
      written[rel] = '5'
    of '2':
      if linkName.len == 0 or '\0' in linkName:
        refusal(xrName, name, "a link with an empty target")
      try: refuseWriteThroughSymlink(staging, rel)
      except IOError as e: refusal(xrThroughLink, name, e.msg)
      let abs = staging / rel
      createDir(parentDir(abs))
      createSymlink(linkName, abs)
      written[rel] = '2'
      links.add (rel, linkName)
      inc result.links
    of '1':
      refusal(xrKind, name, "a hard link (to " & linkName.escape() & ")")
    else:
      refusal(xrKind, name, "member type " & ($typeflag).escape() &
        " cannot come from a source tree")
  # Rule 5, over the whole tree: a link created inside staging is harmless
  # until something follows it, so it is judged against every member.
  let isLink = proc(p: string): bool = written.getOrDefault(p) == '2'
  for (rel, target) in links:
    if linkVerdict(rel, target, isLink) == lvOutside:
      refusal(xrLinkOutside, rel, "the link's target " & target.escape() &
        " is outside the tree")
