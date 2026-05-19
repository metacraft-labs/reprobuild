## Minimal Mach-O LC_RPATH writer used by the M57 macOS strategy-1 path.
##
## Like the ELF rewriter, this is intentionally minimal: it locates an
## existing `LC_RPATH` load command and rewrites its embedded path
## string in place. Production Reprobuild realizations link with
## `-Wl,-rpath,<placeholder>` so the placeholder slot is long enough to
## accept any of the dependency dirs we install into.

type
  MachoRewriteError* = object of CatchableError

  MachoView* = object
    data*: seq[byte]
    isLittleEndian*: bool
    headerSize*: int
    commandCount*: int
    sizeOfCmds*: int

const
  LcRpath = 0x1c'u32 or 0x80000000'u32   # LC_RPATH (req-dylib-bit set)
  MhMagic64Le = 0xfeedfacf'u32

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

proc parseMacho*(data: seq[byte]): MachoView =
  if data.len < 32:
    raise newException(MachoRewriteError, "Mach-O too short")
  let magicLe = readU32(data, 0, true)
  if magicLe != MhMagic64Le:
    raise newException(MachoRewriteError,
      "only Mach-O 64-bit little-endian is supported")
  result.data = data
  result.isLittleEndian = true
  result.headerSize = 32
  result.commandCount = int(readU32(data, 16, true))
  result.sizeOfCmds = int(readU32(data, 20, true))

iterator loadCommands*(view: MachoView): tuple[index: int; offset: int;
                                               cmd: uint32; cmdSize: int] =
  var off = view.headerSize
  for i in 0 ..< view.commandCount:
    if off + 8 > view.data.len:
      raise newException(MachoRewriteError, "load command OOB at index " & $i)
    let cmd = readU32(view.data, off, true)
    let cmdSize = int(readU32(view.data, off + 4, true))
    yield (i, off, cmd, cmdSize)
    off += cmdSize

proc readNulString(buf: openArray[byte]; start, limit: int): string =
  var p = start
  while p < limit and buf[p] != 0:
    result.add(char(buf[p]))
    inc p

proc readRpathStrings*(view: MachoView): seq[string] =
  for lc in loadCommands(view):
    if lc.cmd == LcRpath:
      let strOff = int(readU32(view.data, lc.offset + 8, true))
      let strStart = lc.offset + strOff
      let strLimit = lc.offset + lc.cmdSize
      result.add(readNulString(view.data, strStart, strLimit))

proc rewriteFirstRpath*(view: var MachoView; newRpath: string) =
  ## Locate the first `LC_RPATH` and rewrite its path string in-place.
  ## The new path NUL-terminated MUST fit into the existing slot.
  for lc in loadCommands(view):
    if lc.cmd == LcRpath:
      let strOff = int(readU32(view.data, lc.offset + 8, true))
      let strStart = lc.offset + strOff
      let strLimit = lc.offset + lc.cmdSize
      let existing = readNulString(view.data, strStart, strLimit)
      if newRpath.len > existing.len:
        raise newException(MachoRewriteError,
          "new LC_RPATH (" & $newRpath.len &
          " bytes) does not fit in existing slot (" & $existing.len & " bytes)")
      var pos = strStart
      for ch in newRpath:
        view.data[pos] = byte(ord(ch))
        inc pos
      view.data[pos] = 0
      inc pos
      for _ in 0 ..< (existing.len - newRpath.len):
        view.data[pos] = 0
        inc pos
      return
  raise newException(MachoRewriteError,
    "no LC_RPATH load command; cannot rewrite")
