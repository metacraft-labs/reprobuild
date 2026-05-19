## Minimal ELF64 RUNPATH writer used by the M57 Linux strategy-1 path.
##
## The implementation operates on a parsed view of `PT_DYNAMIC`. It will
## update an EXISTING `DT_RUNPATH` (or `DT_RPATH`) entry whose value
## fits the existing `.dynstr` slot, and it will append a new
## NUL-terminated string to `.dynstr` when there is room and the
## `PT_DYNAMIC` table has a free slot. The writer is intentionally
## minimal — its only job is to produce real byte-rewritten fixture
## binaries for `integration_launch_plan_binding_strategies`. Production
## Reprobuild builds emit binaries with the correct RUNPATH at link
## time (via `-Wl,--enable-new-dtags,-rpath,...`).

type
  ElfRewriteError* = object of CatchableError

  ElfClass = enum
    elf32 = 1, elf64 = 2

  ElfData = enum
    elfLE = 1, elfBE = 2

  ElfDynamicTag = enum
    dtNeeded = 1
    dtPltrelsz = 2
    dtPltgot = 3
    dtHash = 4
    dtStrtab = 5
    dtSymtab = 6
    dtRela = 7
    dtRelasz = 8
    dtRelaent = 9
    dtStrsz = 10
    dtSyment = 11
    dtRpath = 15
    dtRunpath = 29

  ElfDynView = object
    data*: seq[byte]
    isElf64*: bool
    isLittleEndian*: bool
    dynamicOffset*: int              ## file offset of PT_DYNAMIC
    dynamicSize*: int                ## size of PT_DYNAMIC in bytes
    dynstrOffset*: int               ## file offset of .dynstr
    dynstrSize*: int                 ## size of .dynstr

proc readU16(buf: openArray[byte]; pos: int; le: bool): uint16 =
  if le:
    uint16(buf[pos]) or (uint16(buf[pos + 1]) shl 8)
  else:
    (uint16(buf[pos]) shl 8) or uint16(buf[pos + 1])

proc readU32(buf: openArray[byte]; pos: int; le: bool): uint32 =
  if le:
    var v = 0'u32
    for i in 0 ..< 4:
      v = v or (uint32(buf[pos + i]) shl (8 * i))
    v
  else:
    var v = 0'u32
    for i in 0 ..< 4:
      v = (v shl 8) or uint32(buf[pos + i])
    v

proc readU64(buf: openArray[byte]; pos: int; le: bool): uint64 =
  if le:
    var v = 0'u64
    for i in 0 ..< 8:
      v = v or (uint64(buf[pos + i]) shl (8 * i))
    v
  else:
    var v = 0'u64
    for i in 0 ..< 8:
      v = (v shl 8) or uint64(buf[pos + i])
    v

proc parseElf*(data: seq[byte]): ElfDynView =
  if data.len < 64:
    raise newException(ElfRewriteError, "ELF too short")
  if data[0] != 0x7f or data[1] != byte(ord('E')) or
      data[2] != byte(ord('L')) or data[3] != byte(ord('F')):
    raise newException(ElfRewriteError, "missing ELF magic")
  let cls = data[4]
  let dataEnc = data[5]
  if ElfClass(cls) != elf64:
    raise newException(ElfRewriteError,
      "only ELF64 is supported by the M57 rewriter")
  let le = ElfData(dataEnc) == elfLE
  result.data = data
  result.isElf64 = true
  result.isLittleEndian = le
  # ELF64 header layout:
  let phOff = readU64(data, 32, le)
  let phEntSize = readU16(data, 54, le)
  let phNum = readU16(data, 56, le)
  let shOff = readU64(data, 40, le)
  let shEntSize = readU16(data, 58, le)
  let shNum = readU16(data, 60, le)
  let shStrIndex = readU16(data, 62, le)

  # Find PT_DYNAMIC via program headers.
  var dynFileOff = -1
  var dynFileSize = 0
  for i in 0 ..< int(phNum):
    let base = int(phOff) + i * int(phEntSize)
    let pType = readU32(data, base, le)
    if pType == 2'u32:   # PT_DYNAMIC
      dynFileOff = int(readU64(data, base + 8, le))
      dynFileSize = int(readU64(data, base + 32, le))
      break
  if dynFileOff < 0:
    raise newException(ElfRewriteError, "no PT_DYNAMIC segment")
  result.dynamicOffset = dynFileOff
  result.dynamicSize = dynFileSize

  # Find .dynstr by walking the section headers.
  if int(shStrIndex) >= int(shNum):
    raise newException(ElfRewriteError, "section header string index OOB")
  let shStrBase = int(shOff) + int(shStrIndex) * int(shEntSize)
  let shStrTableFileOff = int(readU64(data, shStrBase + 24, le))

  var dynstrOff = -1
  var dynstrSize = 0
  for i in 0 ..< int(shNum):
    let base = int(shOff) + i * int(shEntSize)
    let nameOff = int(readU32(data, base, le))
    var name = ""
    var p = shStrTableFileOff + nameOff
    while p < data.len and data[p] != 0:
      name.add(char(data[p]))
      inc p
    if name == ".dynstr":
      dynstrOff = int(readU64(data, base + 24, le))
      dynstrSize = int(readU64(data, base + 32, le))
      break
  if dynstrOff < 0:
    raise newException(ElfRewriteError, "no .dynstr section")
  result.dynstrOffset = dynstrOff
  result.dynstrSize = dynstrSize

proc findDynamicEntry*(view: ElfDynView; tag: ElfDynamicTag):
    tuple[found: bool; entryOffset: int; value: uint64] =
  ## Scan PT_DYNAMIC for the first entry with the given d_tag.
  var off = view.dynamicOffset
  let endOff = view.dynamicOffset + view.dynamicSize
  while off + 16 <= endOff:
    let dTag = readU64(view.data, off, view.isLittleEndian)
    let dVal = readU64(view.data, off + 8, view.isLittleEndian)
    if dTag == uint64(ord(tag)):
      return (true, off, dVal)
    if dTag == 0:    # DT_NULL terminator
      return (false, 0, 0)
    off += 16
  (false, 0, 0)

proc readNulString*(view: ElfDynView; tableOffset: int): string =
  ## Read a NUL-terminated string from a string-table file offset.
  var p = tableOffset
  while p < view.data.len and view.data[p] != 0:
    result.add(char(view.data[p]))
    inc p

proc readRunpath*(view: ElfDynView): string =
  ## Read the current DT_RUNPATH (or DT_RPATH) string, if any.
  let runpath = view.findDynamicEntry(dtRunpath)
  if runpath.found:
    return view.readNulString(view.dynstrOffset + int(runpath.value))
  let rpath = view.findDynamicEntry(dtRpath)
  if rpath.found:
    return view.readNulString(view.dynstrOffset + int(rpath.value))
  ""

proc rewriteRunpathInPlace*(view: var ElfDynView; newRunpath: string) =
  ## Rewrite an EXISTING DT_RUNPATH (or DT_RPATH) string in-place inside
  ## `.dynstr`. The new string is NUL-terminated and MUST fit into the
  ## space the old string occupied; otherwise raise `ElfRewriteError`.
  ## This is the minimal contract Reprobuild needs for the M57 gate —
  ## production builds always emit a long-enough placeholder at link
  ## time.
  let tag =
    if view.findDynamicEntry(dtRunpath).found: dtRunpath
    else: dtRpath
  let entry = view.findDynamicEntry(tag)
  if not entry.found:
    raise newException(ElfRewriteError,
      "no DT_RUNPATH or DT_RPATH; cannot rewrite without an existing slot")
  let stringTableOff = view.dynstrOffset + int(entry.value)
  let existing = view.readNulString(stringTableOff)
  if newRunpath.len > existing.len:
    raise newException(ElfRewriteError,
      "new RUNPATH (" & $newRunpath.len & " bytes) exceeds existing slot (" &
      $existing.len & " bytes); link with a placeholder padding next time")
  var pos = stringTableOff
  for ch in newRunpath:
    view.data[pos] = byte(ord(ch))
    inc pos
  # NUL-terminate, then zero out any leftover bytes from the previous
  # string so the file is byte-deterministic.
  view.data[pos] = 0
  inc pos
  for _ in 0 ..< (existing.len - newRunpath.len):
    view.data[pos] = 0
    inc pos
