## Strict Windows PE/PDB identity and private-function symbol resolution.
##
## Parsing the PE CodeView record and PDB stream 1 is portable.  The final
## private-symbol lookup is Windows-only and runs through a serialized DbgHelp
## transaction; DbgHelp is documented as single-threaded.  Callers must never
## convert a missing identity or a failed lookup into a zero RVA.

import std/[os, strutils]
from repro_core/paths import extendedPath

type
  WindowsPdbIdentity* = object
    guid*: array[16, byte]
    age*: uint32

  PeCodeViewFacts* = object
    identity*: WindowsPdbIdentity
    pdbPath*: string

  WindowsPdbResolveStatus* = enum
    wprsOk
    wprsPeCodeViewIdentityMissing
    wprsPdbIdentityUnreadable
    wprsPdbIdentityMismatch
    wprsPdbSymbolAbsent
    wprsPdbSymbolAmbiguous
    wprsDbgHelpInitializeFailed
    wprsDbgHelpSearchPathFailed
    wprsDbgHelpLoadFailed
    wprsDbgHelpEnumerateFailed
    wprsDbgHelpInvalidAddress
    wprsDbgHelpCleanupFailed

  WindowsPdbResolution* = object
    status*: WindowsPdbResolveStatus
    reason*: string
    rva*: uint64
    size*: uint32
    matchCount*: uint32
    win32Error*: uint32
    imageIdentity*: WindowsPdbIdentity
    pdbIdentity*: WindowsPdbIdentity

proc readU8(data: string; pos: int; what: string): uint8 =
  if pos < 0 or pos >= data.len:
    raise newException(ValueError, "truncated " & what)
  uint8(ord(data[pos]))

proc readU16Le(data: string; pos: int; what: string): uint16 =
  if pos < 0 or pos + 2 > data.len:
    raise newException(ValueError, "truncated " & what)
  uint16(readU8(data, pos, what)) or
    (uint16(readU8(data, pos + 1, what)) shl 8)

proc readU32Le(data: string; pos: int; what: string): uint32 =
  if pos < 0 or pos + 4 > data.len:
    raise newException(ValueError, "truncated " & what)
  uint32(readU8(data, pos, what)) or
    (uint32(readU8(data, pos + 1, what)) shl 8) or
    (uint32(readU8(data, pos + 2, what)) shl 16) or
    (uint32(readU8(data, pos + 3, what)) shl 24)

proc checkedRange(data: string; offset, size: uint64; what: string) =
  if offset > uint64(data.len) or size > uint64(data.len) - offset:
    raise newException(ValueError, what & " lies outside the file")

proc pdbIdentityText*(identity: WindowsPdbIdentity): string =
  ## Raw GUID bytes are intentional: PE RSDS and PDB stream 1 store identical
  ## byte sequences, so no mixed-endian textual GUID conversion is involved.
  for value in identity.guid:
    result.add toHex(value, 2)
  result.add "-" & $identity.age

proc parsePdbIdentity*(path: string): WindowsPdbIdentity =
  let data = readFile(extendedPath(path))
  const magic = "Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0"
  if data.len < 56 or data[0 ..< magic.len] != magic:
    raise newException(ValueError, "not an MSF 7 PDB: " & path)
  let blockSize = int(readU32Le(data, 32, "PDB block size"))
  let blockCount = int(readU32Le(data, 40, "PDB block count"))
  let directorySize = int(readU32Le(data, 44, "PDB directory size"))
  let blockMap = int(readU32Le(data, 52, "PDB block-map address"))
  if blockSize < 512 or blockSize > 65536 or
      (blockSize and (blockSize - 1)) != 0:
    raise newException(ValueError, "invalid PDB block size: " & $blockSize)
  if blockCount <= 0 or uint64(blockCount) * uint64(blockSize) > uint64(data.len):
    raise newException(ValueError, "PDB block count exceeds the file")
  if directorySize < 4:
    raise newException(ValueError, "PDB stream directory is empty")
  let directoryBlockCount = (directorySize + blockSize - 1) div blockSize
  if directoryBlockCount * 4 > blockSize:
    raise newException(ValueError,
      "PDB directory block map exceeds the supported MSF 7 superblock map")
  checkedRange(data, uint64(blockMap) * uint64(blockSize),
               uint64(directoryBlockCount) * 4'u64,
               "PDB directory block map")
  var directory = newString(directorySize)
  var copied = 0
  for index in 0 ..< directoryBlockCount:
    let blockNumber = int(readU32Le(
      data, blockMap * blockSize + index * 4, "PDB directory block number"))
    if blockNumber < 0 or blockNumber >= blockCount:
      raise newException(ValueError, "PDB directory names an invalid block")
    let amount = min(blockSize, directorySize - copied)
    checkedRange(data, uint64(blockNumber) * uint64(blockSize),
                 uint64(amount), "PDB directory block")
    copyMem(addr directory[copied], unsafeAddr data[blockNumber * blockSize],
            amount)
    copied += amount
  let streamCount = int(readU32Le(directory, 0, "PDB stream count"))
  if streamCount < 2 or streamCount > 1_000_000:
    raise newException(ValueError, "PDB lacks identity stream 1")
  let sizesEnd = 4'u64 + uint64(streamCount) * 4'u64
  checkedRange(directory, 4, uint64(streamCount) * 4'u64,
               "PDB stream sizes")
  var cursor = int(sizesEnd)
  var identityBlocks: seq[uint32]
  var identitySize = -1
  for stream in 0 ..< streamCount:
    let encodedSize = readU32Le(directory, 4 + stream * 4, "PDB stream size")
    if encodedSize == 0xffff_ffff'u32:
      continue
    let size = int(encodedSize)
    let blocks = (size + blockSize - 1) div blockSize
    checkedRange(directory, uint64(cursor), uint64(blocks) * 4'u64,
                 "PDB stream block list")
    if stream == 1:
      identitySize = size
      for blockIndex in 0 ..< blocks:
        identityBlocks.add readU32Le(
          directory, cursor + blockIndex * 4, "PDB identity-stream block")
    cursor += blocks * 4
  if identitySize < 28:
    raise newException(ValueError, "PDB identity stream 1 is truncated")
  var identityStream = newString(identitySize)
  copied = 0
  for encodedBlock in identityBlocks:
    let blockNumber = int(encodedBlock)
    if blockNumber < 0 or blockNumber >= blockCount:
      raise newException(ValueError, "PDB identity stream names an invalid block")
    let amount = min(blockSize, identitySize - copied)
    checkedRange(data, uint64(blockNumber) * uint64(blockSize),
                 uint64(amount), "PDB identity block")
    copyMem(addr identityStream[copied],
            unsafeAddr data[blockNumber * blockSize], amount)
    copied += amount
  result.age = readU32Le(identityStream, 8, "PDB age")
  for index in 0 ..< result.guid.len:
    result.guid[index] = readU8(identityStream, 12 + index, "PDB GUID")

type PeSection = object
  virtualAddress: uint32
  virtualSize: uint32
  rawOffset: uint32
  rawSize: uint32

proc peRvaToFileOffset(data: string; rva, size, sizeOfHeaders: uint32;
                       sections: openArray[PeSection]): int =
  if rva < sizeOfHeaders:
    checkedRange(data, uint64(rva), uint64(size), "PE header RVA")
    return int(rva)
  for section in sections:
    let span = max(section.virtualSize, section.rawSize)
    if rva >= section.virtualAddress and
        uint64(rva) + uint64(size) <=
          uint64(section.virtualAddress) + uint64(span):
      let local = rva - section.virtualAddress
      if uint64(local) + uint64(size) > uint64(section.rawSize):
        raise newException(ValueError, "PE RVA occupies zero-filled section data")
      let offset = section.rawOffset + local
      checkedRange(data, uint64(offset), uint64(size), "PE section RVA")
      return int(offset)
  raise newException(ValueError, "PE RVA is not mapped by a section")

proc parsePeCodeViewFacts*(path: string): PeCodeViewFacts =
  let data = readFile(extendedPath(path))
  if data.len < 64 or data[0] != 'M' or data[1] != 'Z':
    raise newException(ValueError, "not a PE image: " & path)
  let peOffset = int(readU32Le(data, 0x3c, "PE header offset"))
  checkedRange(data, uint64(peOffset), 24, "PE signature and COFF header")
  if data[peOffset ..< peOffset + 4] != "PE\0\0":
    raise newException(ValueError, "invalid PE signature: " & path)
  if readU16Le(data, peOffset + 4, "PE machine") != 0x8664'u16:
    raise newException(ValueError, "PE image is not AMD64: " & path)
  let sectionCount = int(readU16Le(data, peOffset + 6, "PE section count"))
  let optionalSize = int(readU16Le(data, peOffset + 20, "PE optional size"))
  let optionalOffset = peOffset + 24
  checkedRange(data, uint64(optionalOffset), uint64(optionalSize),
               "PE optional header")
  if optionalSize < 112 or
      readU16Le(data, optionalOffset, "PE optional magic") != 0x20b'u16:
    raise newException(ValueError, "PE image is not PE32+: " & path)
  let sizeOfHeaders = readU32Le(data, optionalOffset + 60, "PE header size")
  let directoryCount = readU32Le(
    data, optionalOffset + 108, "PE data-directory count")
  if directoryCount <= 6:
    raise newException(ValueError, "pe-codeview-identity-missing: " & path)
  let debugDirectory = optionalOffset + 112 + 6 * 8
  if debugDirectory + 8 > optionalOffset + optionalSize:
    raise newException(ValueError, "PE debug data directory is truncated")
  let debugRva = readU32Le(data, debugDirectory, "PE debug RVA")
  let debugSize = readU32Le(data, debugDirectory + 4, "PE debug size")
  if debugRva == 0'u32 or debugSize < 28'u32 or debugSize mod 28'u32 != 0'u32:
    raise newException(ValueError, "pe-codeview-identity-missing: " & path)
  let sectionTable = optionalOffset + optionalSize
  checkedRange(data, uint64(sectionTable), uint64(sectionCount) * 40'u64,
               "PE section table")
  var sections: seq[PeSection]
  for index in 0 ..< sectionCount:
    let pos = sectionTable + index * 40
    sections.add PeSection(
      virtualSize: readU32Le(data, pos + 8, "PE section virtual size"),
      virtualAddress: readU32Le(data, pos + 12, "PE section RVA"),
      rawSize: readU32Le(data, pos + 16, "PE section raw size"),
      rawOffset: readU32Le(data, pos + 20, "PE section raw offset"))
  let tableOffset = peRvaToFileOffset(
    data, debugRva, debugSize, sizeOfHeaders, sections)
  var found = false
  for index in 0 ..< int(debugSize div 28'u32):
    let pos = tableOffset + index * 28
    if readU32Le(data, pos + 12, "PE debug type") != 2'u32:
      continue
    let recordSize = readU32Le(data, pos + 16, "PE CodeView size")
    let recordOffset = int(readU32Le(data, pos + 24, "PE CodeView offset"))
    if recordSize < 25'u32:
      continue
    checkedRange(data, uint64(recordOffset), uint64(recordSize),
                 "PE CodeView record")
    if data[recordOffset ..< recordOffset + 4] != "RSDS":
      continue
    var facts: PeCodeViewFacts
    for byteIndex in 0 ..< facts.identity.guid.len:
      facts.identity.guid[byteIndex] = readU8(
        data, recordOffset + 4 + byteIndex, "PE CodeView GUID")
    facts.identity.age = readU32Le(data, recordOffset + 20,
                                   "PE CodeView age")
    let pathStart = recordOffset + 24
    let pathLimit = recordOffset + int(recordSize)
    var cursor = pathStart
    while cursor < pathLimit and data[cursor] != '\0':
      facts.pdbPath.add data[cursor]
      inc cursor
    if cursor >= pathLimit:
      raise newException(ValueError, "PE CodeView PDB path is not terminated")
    if found and facts.identity != result.identity:
      raise newException(ValueError, "PE has conflicting RSDS identities")
    if not found:
      result = facts
      found = true
  if not found:
    raise newException(ValueError, "pe-codeview-identity-missing: " & path)

proc readPeImageBytesAtRva*(path: string; rva: uint64;
                            count: int): seq[byte] =
  ## Read bytes from the file-backed image at one RVA. This is coordinator
  ## evidence for the Windows live-byte check: the PE has already been tied to
  ## its full PDB by CodeView GUID+age, and the in-process agent compares these
  ## bytes with the retained loaded module before publishing anything.
  if count < 0 or rva > uint64(high(uint32)) or
      uint64(count) > uint64(high(uint32)):
    raise newException(ValueError, "PE RVA byte request overflows uint32")
  let data = readFile(extendedPath(path))
  if data.len < 64 or data[0] != 'M' or data[1] != 'Z':
    raise newException(ValueError, "not a PE image: " & path)
  let peOffset = int(readU32Le(data, 0x3c, "PE header offset"))
  checkedRange(data, uint64(peOffset), 24, "PE signature and COFF header")
  if data[peOffset ..< peOffset + 4] != "PE\0\0":
    raise newException(ValueError, "invalid PE signature: " & path)
  if readU16Le(data, peOffset + 4, "PE machine") != 0x8664'u16:
    raise newException(ValueError, "PE image is not AMD64: " & path)
  let sectionCount = int(readU16Le(data, peOffset + 6, "PE section count"))
  let optionalSize = int(readU16Le(data, peOffset + 20, "PE optional size"))
  let optionalOffset = peOffset + 24
  checkedRange(data, uint64(optionalOffset), uint64(optionalSize),
               "PE optional header")
  if optionalSize < 64 or
      readU16Le(data, optionalOffset, "PE optional magic") != 0x20b'u16:
    raise newException(ValueError, "PE image is not PE32+: " & path)
  let sizeOfHeaders = readU32Le(data, optionalOffset + 60, "PE header size")
  let sectionTable = optionalOffset + optionalSize
  checkedRange(data, uint64(sectionTable), uint64(sectionCount) * 40'u64,
               "PE section table")
  var sections: seq[PeSection]
  for index in 0 ..< sectionCount:
    let pos = sectionTable + index * 40
    sections.add PeSection(
      virtualSize: readU32Le(data, pos + 8, "PE section virtual size"),
      virtualAddress: readU32Le(data, pos + 12, "PE section RVA"),
      rawSize: readU32Le(data, pos + 16, "PE section raw size"),
      rawOffset: readU32Le(data, pos + 20, "PE section raw offset"))
  let offset = peRvaToFileOffset(
    data, uint32(rva), uint32(count), sizeOfHeaders, sections)
  result = newSeq[byte](count)
  for index in 0 ..< count:
    result[index] = byte(ord(data[offset + index]))

when defined(windows):
  const moduleDirectory = currentSourcePath.parentDir
  {.compile: moduleDirectory / "../../c/repro_hcr_windows_pdb.c".}
  when defined(vcc):
    {.passL: "dbghelp.lib".}
  else:
    {.passL: "-ldbghelp".}

  type NativePdbResult {.bycopy.} = object
    status: uint32
    matchCount: uint32
    win32Error: uint32
    functionSize: uint32
    rva: uint64

  proc nativeResolve(imagePath, searchPath, symbolName: WideCString):
      NativePdbResult {.importc: "repro_hcr_windows_pdb_resolve_function",
                         cdecl.}

proc resolveWindowsPdbFunction*(imagePath, pdbPath,
                                symbolName: string): WindowsPdbResolution =
  var peFacts: PeCodeViewFacts
  try:
    peFacts = parsePeCodeViewFacts(imagePath)
  except ValueError as error:
    result.status = wprsPeCodeViewIdentityMissing
    result.reason = error.msg
    return
  result.imageIdentity = peFacts.identity
  try:
    result.pdbIdentity = parsePdbIdentity(pdbPath)
  except ValueError as error:
    result.status = wprsPdbIdentityUnreadable
    result.reason = "pdb-identity-unreadable: " & error.msg
    return
  if result.imageIdentity != result.pdbIdentity:
    result.status = wprsPdbIdentityMismatch
    result.reason = "pe-pdb-identity-mismatch: PE " &
      pdbIdentityText(result.imageIdentity) & " PDB " &
      pdbIdentityText(result.pdbIdentity)
    return
  when defined(windows):
    let native = nativeResolve(
      newWideCString(absolutePath(imagePath)),
      newWideCString(parentDir(absolutePath(pdbPath))),
      newWideCString(symbolName))
    result.rva = native.rva
    result.size = native.functionSize
    result.matchCount = native.matchCount
    result.win32Error = native.win32Error
    case native.status
    of 0:
      result.status = wprsOk
      result.reason = "ok"
    of 1:
      result.status = wprsDbgHelpInitializeFailed
      result.reason = "dbghelp-initialize-failed"
    of 2:
      result.status = wprsDbgHelpSearchPathFailed
      result.reason = "dbghelp-search-path-failed"
    of 3:
      result.status = wprsDbgHelpLoadFailed
      result.reason = "dbghelp-module-load-failed"
    of 4:
      result.status = wprsDbgHelpEnumerateFailed
      result.reason = "dbghelp-symbol-enumeration-failed"
    of 5:
      result.status = wprsPdbSymbolAbsent
      result.reason = "pdb-symbol-absent"
    of 6:
      result.status = wprsPdbSymbolAmbiguous
      result.reason = "pdb-symbol-ambiguous"
    of 7:
      result.status = wprsDbgHelpInvalidAddress
      result.reason = "dbghelp-symbol-address-invalid"
    else:
      result.status = wprsDbgHelpCleanupFailed
      result.reason = "dbghelp-cleanup-failed"
  else:
    result.status = wprsDbgHelpLoadFailed
    result.reason = "windows-dbghelp-required"
