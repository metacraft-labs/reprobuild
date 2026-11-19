## What the `source` edge computes from a package's tree, read from git
## objects: the source digest, the canonical archive, the `.nimble` file,
## and the facts the version record needs (symbolic links, gitlinks).
##
## Pure: the input is the list of tree entries and the bytes of their blobs;
## nothing here opens a file of the package, so a symbolic link is data (its
## target text) and can never be followed (threat model G4).
##
## * **Links.** A link whose target is absolute, or whose target, resolved
##   lexically from the link's directory, leaves the package directory or
##   passes through another link, points OUTSIDE the tree. Such a version is
##   `unreadable` (spec § 6.1). Every link, in or out, is stored in the
##   archive as a link: its target text, never the bytes of what it names.
## * **Gitlinks.** A gitlink (a submodule entry) sets `gitlinks`. Its
##   `.gitmodules` URL is never fetched: each is classified by the origin
##   egress policy and recorded with that verdict (threat model G35); whether
##   such versions are offered is operator question A4.
## * **Digest.** The tree digest is the lock's canonical tree hash for
##   integrity (`repro_multihash.narStyleTreeMultihash`) over the package's
##   regular files, path and content, which is what that hash computes over a
##   checkout of the same tree.
## * **Archive.** A deterministic POSIX ustar archive: regular files and
##   links in byte order of their paths, owner 0, time 0, mode 0644 or 0755
##   for files and 0777 for links, a PAX header for a path or link target
##   that does not fit the ustar fields.

import std/[algorithm, strutils, tables]

import nimcrypto/sha2

import repro_multihash

import ./egress
import ./origin_git

type
  LinkVerdict* = enum
    lvInside = "in"
    lvOutside = "out"

  SourceLink* = object
    path*, target*: string
    verdict*: LinkVerdict

  SubmoduleUrl* = object
    path*, url*: string
    verdict*: string
      ## `refused:<egress refusal kind>`, or `not-fetched` for a URL the
      ## policy would allow: no gitlink is fetched in this version

  NimbleFileLookup* = enum
    nlFound = "found"
    nlNone = "none"
    nlAmbiguous = "ambiguous"

  SourceFacts* = object
    treeDigest*: string     ## lower-case hex of the BLAKE3 tree digest
    archiveSha256*: string  ## lower-case hex
    archiveSize*: int64
    commitTime*: int64      ## the commit's own date (provenance only)
    files*: seq[string]     ## regular files, sorted
    links*: seq[SourceLink]
    gitlinks*: seq[(string, string)] ## (path, commit)
    submodules*: seq[SubmoduleUrl]
    nimble*: NimbleFileLookup
    nimblePath*: string
    nimbleCandidates*: seq[string]

proc linkVerdict*(linkPath, target: string;
                  isLink: proc(p: string): bool): LinkVerdict =
  ## Does the link at ``linkPath`` (relative to the package directory) stay
  ## inside it? Lexical, from the link's own directory; a target through
  ## another link counts as outside, so a chain cannot hide an escape.
  if target.len == 0 or target.startsWith("/") or '\0' in target:
    return lvOutside
  var parts: seq[string]
  let dir = linkPath.rsplit('/', maxsplit = 1)
  if dir.len == 2:
    for p in dir[0].split('/'):
      if p.len > 0: parts.add p
  for p in target.split('/'):
    case p
    of "", ".": discard
    of "..":
      if parts.len == 0:
        return lvOutside
      parts.setLen(parts.len - 1)
    else:
      parts.add p
      if isLink(parts.join("/")) and parts.join("/") != linkPath:
        return lvOutside
  lvInside

proc parseGitmodules*(text: string): seq[(string, string)] =
  ## (path, url) of each `[submodule "..."]` section of a `.gitmodules`.
  var path, url = ""
  var inSection = false
  proc flush(acc: var seq[(string, string)]) =
    if inSection and (path.len > 0 or url.len > 0):
      acc.add (path, url)
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0 or line[0] in {'#', ';'}: continue
    if line.startsWith("["):
      flush(result)
      inSection = line.toLowerAscii().startsWith("[submodule")
      path = ""
      url = ""
      continue
    let eq = line.find('=')
    if eq < 0 or not inSection: continue
    let k = line[0 ..< eq].strip().toLowerAscii()
    var v = line[eq + 1 .. ^1].strip()
    if v.len >= 2 and v[0] == '"' and v[^1] == '"':
      v = v[1 ..< v.high]
    if k == "path": path = v
    elif k == "url": url = v
  flush(result)

proc classifySubmoduleUrl*(url: string): string =
  ## The egress policy's verdict on a `.gitmodules` URL, without contacting
  ## it: rule 1 (scheme, credentials, shape). Rule 2 needs a resolution,
  ## which would itself be a contact the policy has not decided to make.
  try:
    discard parseOriginUrl(url)
    "not-fetched"
  except EgressError as e:
    "refused:" & $e.refusal.kind

# ---------------------------------------------------------------------------
# The canonical archive
# ---------------------------------------------------------------------------

proc octal(v: int64; width: int): string =
  result = toOct(v, width - 1)
  result.add '\0'

proc header(name, link: string; size: int64; mode: int; typeflag: char;
            prefix = ""): string =
  result = newString(512)
  for i in 0 ..< 512: result[i] = '\0'
  proc put(dst: var string; at: int; s: string) =
    for i, c in s: dst[at + i] = c
  put(result, 0, name)
  put(result, 100, octal(mode, 8))
  put(result, 108, octal(0, 8))
  put(result, 116, octal(0, 8))
  put(result, 124, octal(size, 12))
  put(result, 136, octal(0, 12))
  put(result, 148, "        ")
  result[156] = typeflag
  put(result, 157, link)
  put(result, 257, "ustar\0")
  put(result, 263, "00")
  put(result, 345, prefix)
  var sum = 0
  for c in result: sum += ord(c)
  put(result, 148, toOct(sum, 6) & "\0 ")

proc pad(n: int64): string =
  let r = int(n mod 512)
  if r == 0: "" else: repeat('\0', 512 - r)

proc paxRecord(key, value: string): string =
  ## `<len> <key>=<value>\n`, where `<len>` counts itself.
  let body = " " & key & "=" & value & "\n"
  var n = body.len + 1
  while ($n).len + body.len != n:
    n = ($n).len + body.len
  $n & body

proc addEntry(tar: var string; path, link: string; content: string;
              mode: int; typeflag: char) =
  var pax = ""
  var name = path
  var prefix = ""
  if path.len > 100:
    var split = -1
    for i in countdown(min(path.len - 1, 155), 1):
      if path[i] == '/' and path.len - i - 1 <= 100 and path.len - i - 1 > 0:
        split = i
        break
    if split > 0:
      prefix = path[0 ..< split]
      name = path[split + 1 .. ^1]
    else:
      pax.add paxRecord("path", path)
      name = path[0 ..< 100]
  var linkField = link
  if link.len > 100:
    pax.add paxRecord("linkpath", link)
    linkField = link[0 ..< 100]
  if pax.len > 0:
    tar.add header("PaxHeader", "", pax.len, 0o644, 'x')
    tar.add pax
    tar.add pad(pax.len)
  tar.add header(name, linkField, content.len, mode, typeflag, prefix)
  tar.add content
  tar.add pad(content.len)

proc canonicalArchive*(entries: seq[TreeEntry];
                       blobs: Table[string, string]): string =
  ## The deterministic archive of a package tree (see the module
  ## docstring). Gitlinks have no content and are not in it.
  var sorted = entries
  sorted.sort(proc (a, b: TreeEntry): int = cmp(a.path, b.path))
  for e in sorted:
    case e.kind
    of teFile:
      result.addEntry(e.path, "", blobs.getOrDefault(e.oid), 0o644, '0')
    of teExecutable:
      result.addEntry(e.path, "", blobs.getOrDefault(e.oid), 0o755, '0')
    of teSymlink:
      result.addEntry(e.path, blobs.getOrDefault(e.oid), "", 0o777, '2')
    of teGitlink, teOther:
      discard
  result.add repeat('\0', 1024)

# ---------------------------------------------------------------------------
# Facts
# ---------------------------------------------------------------------------

proc lowerHex(bytes: openArray[byte]): string =
  const digits = "0123456789abcdef"
  for b in bytes:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0x0f)]

proc sourceFacts*(tree: FetchedTree): tuple[facts: SourceFacts;
                                            archive: string;
                                            nimbleBytes: string] =
  ## Everything the `source` edge outputs about one tree.
  var f = SourceFacts(commitTime: tree.commitTime)
  var links = initTable[string, bool]()
  for e in tree.entries:
    if e.kind == teSymlink: links[e.path] = true
  let isLink = proc(p: string): bool = p in links
  var regular: seq[tuple[path: string, content: string]]
  for e in tree.entries:
    case e.kind
    of teFile, teExecutable:
      f.files.add e.path
      regular.add (e.path, tree.blobs.getOrDefault(e.oid))
    of teSymlink:
      let target = tree.blobs.getOrDefault(e.oid)
      f.links.add SourceLink(path: e.path, target: target,
        verdict: linkVerdict(e.path, target, isLink))
    of teGitlink:
      f.gitlinks.add (e.path, e.oid)
    of teOther:
      discard
  f.files.sort()
  let mh = narStyleTreeMultihash(regular)
  f.treeDigest = mh["blake3:".len .. ^1]
  if f.gitlinks.len > 0:
    for e in tree.entries:
      if e.path == ".gitmodules" and e.kind in {teFile, teExecutable}:
        for (p, u) in parseGitmodules(tree.blobs.getOrDefault(e.oid)):
          f.submodules.add SubmoduleUrl(path: p, url: u,
            verdict: classifySubmoduleUrl(u))
    f.submodules.sort(proc (a, b: SubmoduleUrl): int =
      result = cmp(a.path, b.path)
      if result == 0: result = cmp(a.url, b.url))
  # The `.nimble` file: directly in the package directory, as Nimble finds
  # it (a link to one is read only when it stays in the tree).
  var candidates: seq[(string, string)]
  for e in tree.entries:
    if '/' in e.path: continue
    if not (e.path.endsWith(".nimble") or e.path.endsWith(".babel")): continue
    case e.kind
    of teFile, teExecutable:
      candidates.add (e.path, tree.blobs.getOrDefault(e.oid))
    of teSymlink:
      let target = tree.blobs.getOrDefault(e.oid)
      if linkVerdict(e.path, target, isLink) == lvInside:
        for t in tree.entries:
          if t.path == target and t.kind in {teFile, teExecutable}:
            candidates.add (e.path, tree.blobs.getOrDefault(t.oid))
    else: discard
  candidates.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  var nimbleBytes = ""
  case candidates.len
  of 0: f.nimble = nlNone
  of 1:
    f.nimble = nlFound
    f.nimblePath = candidates[0][0]
    nimbleBytes = candidates[0][1]
  else:
    f.nimble = nlAmbiguous
    for c in candidates: f.nimbleCandidates.add c[0]
  let archive = canonicalArchive(tree.entries, tree.blobs)
  f.archiveSha256 = lowerHex(sha256.digest(archive).data)
  f.archiveSize = archive.len
  (f, archive, nimbleBytes)

proc modulesUnder*(files: seq[string]; srcDir: string): seq[string] =
  ## The top-level module names under ``srcDir``: `<srcDir>/<name>.nim`.
  let prefix = srcDir.strip(chars = {'/'})
  for path in files:
    var rest = path
    if prefix.len > 0:
      if not path.startsWith(prefix & "/"): continue
      rest = path[prefix.len + 1 .. ^1]
    if '/' in rest or not rest.endsWith(".nim"): continue
    let name = rest[0 ..< rest.len - 4]
    var ok = name.len > 0
    for c in name:
      if ord(c) < 0x21 or ord(c) > 0x7e: ok = false
    if ok and name notin result: result.add name
  result.sort()
