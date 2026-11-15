## Does a build output carry the physical path of a checkout?
##
## Caching-Architecture.md §"Design for XPC-AREQ1", decision D4: before the
## engine writes a portable record -- the record another checkout of the same
## sources may be served from -- it scans each declared output for the
## physical path of every tracked logical root of the invocation and of every
## declared source tree. An output that contains one makes the record
## non-portable. A deterministic compile of the same logical inputs can differ
## between two checkouts only by a path it embeds, so "the outputs here are
## path-free" is what lets a second checkout take these bytes as its own.
##
## A plain byte scan is not enough, and that is measured, not supposed: GCC
## on the toolchains this engine provisions compresses `.debug_*` sections by
## default (`SHF_COMPRESSED`), so a `-g` object names its checkout only inside
## a zlib stream and a `strings`-style scan of the file finds nothing
## (measured on this engine's provisioned toolchain). The scan therefore
## reads, in addition to the raw bytes:
##
## * every `SHF_COMPRESSED` section of an ELF file, decompressed -- zlib
##   (`ELFCOMPRESS_ZLIB`) and zstd (`ELFCOMPRESS_ZSTD`), the two compression
##   types of the ELF gABI
##   (https://www.sco.com/developers/gabi/latest/ch4.sheader.html#compression_header);
## * every member of an `ar` archive, each scanned the same way
##   (https://www.freebsd.org/cgi/man.cgi?query=ar&sektion=5 for the format);
## * the target text of a symbolic link, which is an embedded path too;
## * every file under a directory output.
##
## FAIL CLOSED. What cannot be read cannot be shown path-free: a compressed
## section that does not decode, a zstd section on a host where libzstd cannot
## be loaded, an output that cannot be opened -- each answers "not portable"
## with the reason, never "no path found". The cost of a false positive is a
## record kept local; the cost of a false negative is serving one checkout's
## debug info, or a `__FILE__` string, to another.

import std/[options, os, strutils]

import repro_core/paths
import repro_core/zlib_inflate
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types
import repro_binary_cache_client/decompress

type
  EmbeddedRootNeedle* = object
    ## One physical path to look for, and what to call it in a diagnostic.
    label*: string      ## the root's label (`project`, `store`, ...)
    path*: string       ## its physical spelling, as the bytes would carry it

  EmbeddedRootFinding* = object
    ## The outcome of scanning one output. `found` and `unscannable` are
    ## exclusive; both empty means the output is path-free.
    found*: bool
    label*: string      ## which root was found
    path*: string       ## the physical path that was found
    where*: string      ## where in the output: "bytes", "section .debug_str
                        ## (zlib)", "member add.o section .debug_info (zlib)"
    unscannable*: string
      ## Non-empty when the output, or part of it, could not be read; the
      ## caller treats that exactly like a found path (fail closed).

const
  MaxExpandedSection = 1 shl 30
    ## A compressed section declaring more than this is refused as
    ## unscannable rather than decompressed: no real debug section is a
    ## gigabyte, and the cap keeps a hostile `ch_size` from exhausting memory.
  ShfCompressed = 0x800'u64
  ShtNobits = 8'u32
  ElfCompressZlib = 1'u32
  ElfCompressZstd = 2'u32

proc needleSpellings*(needles: openArray[EmbeddedRootNeedle]):
    seq[EmbeddedRootNeedle] =
  ## The spellings worth searching for: each path without a trailing
  ## separator, and on a path with backslashes its forward-slash spelling too
  ## (and the reverse), since a tool may print either. Empty paths and the
  ## filesystem root itself are dropped: a root of `/` would match every
  ## absolute path any output names, which would make no record portable and
  ## says nothing about a checkout.
  for needle in needles:
    var p = needle.path
    while p.len > 1 and p[^1] in {'/', '\\'}:
      p.setLen(p.len - 1)
    if p.len < 2:
      continue
    var spellings = @[p]
    let forward = p.replace('\\', '/')
    let backward = p.replace('/', '\\')
    if forward notin spellings: spellings.add(forward)
    if backward notin spellings and '\\' in p: spellings.add(backward)
    for spelling in spellings:
      var seen = false
      for existing in result:
        if existing.path == spelling:
          seen = true
          break
      if not seen:
        result.add(EmbeddedRootNeedle(label: needle.label, path: spelling))

proc findNeedle(data: openArray[char]; needles: openArray[EmbeddedRootNeedle];
                where: string): Option[EmbeddedRootFinding] =
  ## The first needle (in the caller's order) that occurs in `data`.
  if data.len == 0:
    return none(EmbeddedRootFinding)
  var text = newString(data.len)
  copyMem(addr text[0], unsafeAddr data[0], data.len)
  for needle in needles:
    if needle.path.len > 0 and text.find(needle.path) >= 0:
      return some(EmbeddedRootFinding(found: true, label: needle.label,
        path: needle.path, where: where))
  none(EmbeddedRootFinding)

proc unscannableAt(where, why: string): EmbeddedRootFinding =
  EmbeddedRootFinding(unscannable: where & ": " & why)

# --- ELF -------------------------------------------------------------------

type ElfView = object
  is64: bool
  little: bool

proc u16(data: string; pos: int; v: ElfView): uint64 =
  if pos < 0 or pos + 2 > data.len: raise newException(ValueError, "truncated")
  let a = uint64(ord(data[pos]))
  let b = uint64(ord(data[pos + 1]))
  if v.little: a or (b shl 8) else: (a shl 8) or b

proc u32(data: string; pos: int; v: ElfView): uint64 =
  if pos < 0 or pos + 4 > data.len: raise newException(ValueError, "truncated")
  result = 0
  for i in 0 ..< 4:
    let byteAt = uint64(ord(data[pos + (if v.little: i else: 3 - i)]))
    result = result or (byteAt shl (8 * i))

proc u64(data: string; pos: int; v: ElfView): uint64 =
  if pos < 0 or pos + 8 > data.len: raise newException(ValueError, "truncated")
  result = 0
  for i in 0 ..< 8:
    let byteAt = uint64(ord(data[pos + (if v.little: i else: 7 - i)]))
    result = result or (byteAt shl (8 * i))

proc word(data: string; pos: int; v: ElfView): uint64 =
  if v.is64: u64(data, pos, v) else: u32(data, pos, v)

proc isElf(data: string): bool =
  data.len >= 16 and data[0] == '\x7f' and data[1] == 'E' and
    data[2] == 'L' and data[3] == 'F'

proc zstdExpand(stream: string; limit: int): seq[byte] =
  ## One whole zstd frame sequence, expanded through the binary-cache
  ## client's libzstd binding. Raises when libzstd cannot be loaded, when the
  ## stream is malformed, or when it expands past `limit` (the section's
  ## declared size).
  let d = newDecompressor(ckZstd)
  defer: d.close()
  var overflow = false
  var output: seq[byte] = @[]
  let sink = proc (chunk: openArray[byte]) {.gcsafe.} =
    {.cast(gcsafe).}:
      if output.len + chunk.len > limit:
        overflow = true
      else:
        output.add(chunk)
  if stream.len > 0:
    d.feed(stream.toOpenArrayByte(0, stream.high), sink)
  d.finish(sink)
  if overflow:
    raise newException(ValueError,
      "zstd stream expands past the section's declared size")
  output

proc scanElfSections(data: string; needles: openArray[EmbeddedRootNeedle];
                     context: string): Option[EmbeddedRootFinding] =
  ## Decompress and scan every `SHF_COMPRESSED` section of the ELF image in
  ## `data`. Uncompressed sections are already covered by the caller's raw
  ## scan. `none` means no compressed section names a needle.
  let v = ElfView(is64: data[4] == '\x02', little: data[5] != '\x02')
  if data[4] notin {'\x01', '\x02'}:
    return some(unscannableAt(context, "ELF class byte is neither 32 nor 64"))
  try:
    let shoff = int(if v.is64: u64(data, 0x28, v) else: u32(data, 0x20, v))
    let shentsize = int(u16(data, (if v.is64: 0x3A else: 0x2E), v))
    var shnum = int(u16(data, (if v.is64: 0x3C else: 0x30), v))
    let shstrndxRaw = int(u16(data, (if v.is64: 0x3E else: 0x32), v))
    if shoff == 0:
      return none(EmbeddedRootFinding)   # no section table: raw scan covers it
    let expected = if v.is64: 64 else: 40
    if shentsize != expected:
      return some(unscannableAt(context,
        "unexpected section header size " & $shentsize))
    # Extended numbering (gABI): e_shnum == 0 puts the count in sh_size of
    # section 0, and SHN_XINDEX puts the string-table index in its sh_link.
    if shnum == 0:
      shnum = int(word(data, shoff + (if v.is64: 32 else: 20), v))
    var shstrndx = shstrndxRaw
    if shstrndx == 0xffff:
      shstrndx = int(u32(data, shoff + (if v.is64: 40 else: 24), v))
    proc header(i: int): tuple[name: int, typ: uint64, flags: uint64,
                               offset: int, size: int] =
      let base = shoff + i * shentsize
      result.name = int(u32(data, base, v))
      result.typ = u32(data, base + 4, v)
      result.flags = word(data, base + 8, v)
      result.offset = int(word(data, base + (if v.is64: 24 else: 16), v))
      result.size = int(word(data, base + (if v.is64: 32 else: 20), v))
    var strtab = (offset: 0, size: 0)
    if shstrndx > 0 and shstrndx < shnum:
      let h = header(shstrndx)
      strtab = (offset: h.offset, size: h.size)
    proc sectionName(nameOffset: int): string =
      if strtab.size == 0 or nameOffset < 0 or nameOffset >= strtab.size:
        return "#" & $nameOffset
      var i = strtab.offset + nameOffset
      while i < data.len and i < strtab.offset + strtab.size and
          data[i] != '\0':
        result.add(data[i])
        inc i
    for i in 1 ..< shnum:
      let h = header(i)
      if h.typ == ShtNobits:
        continue
      if (h.flags and ShfCompressed) == 0:
        # The legacy GNU format (`-gz=zlib-gnu`, `objcopy
        # --compress-debug-sections=zlib-gnu`, still written by binutils
        # 2.46): no `SHF_COMPRESSED` flag, a `.zdebug*` name, and contents
        # "ZLIB", the expanded size as 8 big-endian bytes, then a zlib
        # stream. Missing it would let a debug object hide its checkout.
        let legacyName = sectionName(h.name)
        if not legacyName.startsWith(".zdebug"):
          continue
        let at = context & "section " & legacyName
        if h.offset < 0 or h.size < 12 or h.offset + h.size > data.len or
            data[h.offset ..< h.offset + 4] != "ZLIB":
          return some(unscannableAt(at,
            "legacy compressed debug section has no ZLIB header"))
        var legacySize = 0'u64
        for k in 0 ..< 8:
          legacySize = (legacySize shl 8) or uint64(ord(data[h.offset + 4 + k]))
        if legacySize > uint64(MaxExpandedSection):
          return some(unscannableAt(at, "declares an expanded size of " &
            $legacySize & " bytes"))
        var legacyExpanded: seq[byte]
        try:
          legacyExpanded = zlibDecompress(
            data[h.offset + 12 ..< h.offset + h.size], 0, int(legacySize))
        except InflateError as err:
          return some(unscannableAt(at, "zlib stream does not decode (" &
            err.reason & ")"))
        except CatchableError as err:
          return some(unscannableAt(at, "zlib stream cannot be read: " &
            err.msg))
        if legacyExpanded.len > 0:
          let hit = findNeedle(cast[ptr UncheckedArray[char]](
            addr legacyExpanded[0]).toOpenArray(0, legacyExpanded.high),
            needles, at & " (zlib-gnu)")
          if hit.isSome:
            return hit
        continue
      let name = sectionName(h.name)
      let at = context & "section " & name
      let chdrSize = if v.is64: 24 else: 12
      if h.offset < 0 or h.size < chdrSize or h.offset + h.size > data.len:
        return some(unscannableAt(at, "compressed section lies outside the file"))
      let chType = u32(data, h.offset, v)
      let chSize = int(if v.is64: u64(data, h.offset + 8, v)
                       else: u32(data, h.offset + 4, v))
      if chSize < 0 or chSize > MaxExpandedSection:
        return some(unscannableAt(at, "declares an expanded size of " &
          $chSize & " bytes"))
      let stream = data[h.offset + chdrSize ..< h.offset + h.size]
      var expanded: seq[byte]
      var algorithm = ""
      try:
        case chType
        of ElfCompressZlib:
          algorithm = "zlib"
          expanded = zlibDecompress(stream, 0, chSize)
        of ElfCompressZstd:
          algorithm = "zstd"
          expanded = zstdExpand(stream, chSize)
        else:
          return some(unscannableAt(at, "unknown compression type " & $chType))
      except InflateError as err:
        return some(unscannableAt(at, "zlib stream does not decode (" &
          err.reason & ")"))
      except CatchableError as err:
        return some(unscannableAt(at, algorithm & " stream cannot be read: " &
          err.msg))
      if expanded.len > 0:
        let hit = findNeedle(cast[ptr UncheckedArray[char]](
          addr expanded[0]).toOpenArray(0, expanded.high), needles,
          at & " (" & algorithm & ")")
        if hit.isSome:
          return hit
  except ValueError:
    return some(unscannableAt(context, "ELF section table is truncated"))
  none(EmbeddedRootFinding)

# --- ar --------------------------------------------------------------------

proc scanBytes*(data: string; needles: openArray[EmbeddedRootNeedle];
                context = ""): EmbeddedRootFinding

proc scanArchiveMembers(data: string; needles: openArray[EmbeddedRootNeedle];
                        context: string): Option[EmbeddedRootFinding] =
  ## Each member of a (System V / GNU / BSD) `ar` archive, scanned as a file
  ## of its own -- which is what reaches into a member object's compressed
  ## debug sections. The archive's raw bytes were already scanned by the
  ## caller; a thin archive (`!<thin>`) stores no member bytes at all, and its
  ## member names are in those raw bytes.
  const Magic = "!<arch>\n"
  var pos = Magic.len
  var longNames = ""
  while pos + 60 <= data.len:
    let header = data[pos ..< pos + 60]
    if header[58 .. 59] != "`\n":
      return some(unscannableAt(context, "ar member header at offset " &
        $pos & " is malformed"))
    var name = header[0 ..< 16].strip(leading = false)
    let sizeText = header[48 ..< 58].strip()
    var size = 0
    try: size = parseInt(sizeText)
    except ValueError:
      return some(unscannableAt(context, "ar member size '" & sizeText &
        "' is not a number"))
    var start = pos + 60
    if size < 0 or start + size > data.len:
      return some(unscannableAt(context, "ar member at offset " & $pos &
        " runs past the end of the archive"))
    var length = size
    if name == "//":
      longNames = data[start ..< start + size]
    elif name.startsWith("#1/"):
      # BSD: the name is stored in front of the member's bytes.
      var nameLen = 0
      try: nameLen = parseInt(name[3 .. ^1])
      except ValueError: nameLen = 0
      if nameLen > 0 and nameLen <= size:
        name = data[start ..< start + nameLen].strip(leading = false,
          chars = {'\0'})
        start += nameLen
        length -= nameLen
    elif name.len > 1 and name[0] == '/' and name[1] in Digits:
      var offset = 0
      try: offset = parseInt(name[1 .. ^1])
      except ValueError: offset = -1
      if offset >= 0 and offset < longNames.len:
        let finish = longNames.find('\n', offset)
        name = longNames[offset ..< (if finish < 0: longNames.len else: finish)]
    if name notin ["/", "//", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED"]:
      let member = data[start ..< start + length]
      let finding = scanBytes(member, needles,
        context & "member " & name.strip(chars = {'/'}) & " ")
      if finding.found or finding.unscannable.len > 0:
        return some(finding)
    pos = pos + 60 + size + (size and 1)
  none(EmbeddedRootFinding)

proc scanBytes*(data: string; needles: openArray[EmbeddedRootNeedle];
                context = ""): EmbeddedRootFinding =
  ## Scan the bytes of one file: raw, then (for ELF) every compressed
  ## section, then (for an archive) every member. `needles` must already be
  ## the spellings `needleSpellings` produced.
  let raw = findNeedle(data.toOpenArray(0, data.high), needles,
    (if context.len > 0: context & "bytes" else: "bytes"))
  if raw.isSome:
    return raw.get()
  if isElf(data):
    let hit = scanElfSections(data, needles, context)
    if hit.isSome:
      return hit.get()
  elif data.startsWith("!<arch>\n"):
    let hit = scanArchiveMembers(data, needles, context)
    if hit.isSome:
      return hit.get()
  EmbeddedRootFinding()

proc scanOutputForEmbeddedRoots*(path: string;
                                 needles: openArray[EmbeddedRootNeedle]):
    EmbeddedRootFinding =
  ## Scan one declared output -- a file, a symbolic link, or a directory
  ## (every entry under it) -- for any of `needles`. An absent output is
  ## path-free (an optional output that was not produced embeds nothing).
  let spellings = needleSpellings(needles)
  if spellings.len == 0:
    return EmbeddedRootFinding()
  let p = extendedPath(path)
  proc scanOne(file: string; shown: string): EmbeddedRootFinding =
    if symlinkExists(file):
      let target =
        try: expandSymlink(file)
        except OSError as err:
          return unscannableAt(shown, "symbolic link cannot be read: " & err.msg)
      let hit = findNeedle(target.toOpenArray(0, target.high), spellings,
        shown & " link target")
      if hit.isSome:
        return hit.get()
      return EmbeddedRootFinding()
    let data =
      try: readFile(file)
      except IOError as err:
        return unscannableAt(shown, "cannot be read: " & err.msg)
      except OSError as err:
        return unscannableAt(shown, "cannot be read: " & err.msg)
    result = scanBytes(data, spellings)
    if result.found or result.unscannable.len > 0:
      result.where = (if result.where.len > 0: shown & " " & result.where
                      else: shown)
  if symlinkExists(p) or fileExists(p):
    return scanOne(p, extractFilename(path))
  if dirExists(p):
    try:
      for entry in walkDirRec(p, yieldFilter = {pcFile, pcLinkToFile,
          pcLinkToDir}, followFilter = {pcDir}, relative = true):
        let finding = scanOne(p / entry, entry.replace('\\', '/'))
        if finding.found or finding.unscannable.len > 0:
          return finding
    except OSError as err:
      return unscannableAt(extractFilename(path),
        "directory cannot be listed: " & err.msg)
  EmbeddedRootFinding()

proc describe*(finding: EmbeddedRootFinding; logicalOutput: string): string =
  ## The trace text for a record this finding makes non-portable.
  if finding.found:
    "output " & logicalOutput & " embeds the physical path of the " &
      finding.label & " root (" & finding.path & ", in " & finding.where &
      "); a record that names a checkout cannot be served to another " &
      "(map the path away, e.g. -ffile-prefix-map=<root>=., to share it)"
  elif finding.unscannable.len > 0:
    "output " & logicalOutput & " cannot be scanned for embedded checkout " &
      "paths (" & finding.unscannable & "), so it is not shown path-free"
  else:
    ""
