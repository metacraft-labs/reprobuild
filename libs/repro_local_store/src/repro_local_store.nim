import std/[options, os, sets, strutils, tables, times]

when defined(linux):
  import std/posix

when defined(windows):
  import std/winlean

import repro_core
import repro_hash

# Re-export the new M56 content-addressed local store API. The pre-M56
# `LocalCas` and `ActionCache` types below remain for the action-cache
# code path the M9 build engine still consumes; the M56 entry points
# live in `repro_local_store/store.nim` and
# `repro_local_store/sqlite3_binding.nim`.
import ./repro_local_store/sqlite3_binding
import ./repro_local_store/store
import ./repro_local_store/lru_eviction
import ./repro_local_store/sandbox_manifest
export sqlite3_binding
export store
export lru_eviction
export sandbox_manifest

type
  LocalStoreError* = object of CatchableError
  CacheIntegrityError* = object of LocalStoreError
  ActionRecordError* = object of LocalStoreError

  FileFingerprintPolicy* = enum
    ffpTimestamp
    ffpChecksum
    ffpHybrid

  FingerprintedFileKind* = enum
    ffkMissing
    ffkRegular
    ffkDirectory
    ffkOther

  FileMetadata* = object
    kind*: FingerprintedFileKind
    sizeBytes*: uint64
    mtimeNs*: uint64

  FileFingerprint* = object
    path*: string
    policy*: FileFingerprintPolicy
    metadata*: FileMetadata
    hasLocalHash*: bool
    localHash*: LocalInvalidationHash

  CasBlobRef* = object
    digest*: ContentDigest
    sizeBytes*: uint64

  OutputPayloadKind* = enum
    opkCasBlobs
    opkMetadataOnly

  OutputBlob* = object
    path*: string
    metadata*: FileMetadata
    blob*: CasBlobRef
    permissions*: set[FilePermission]

  ActionResultRecord* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy
    inputs*: seq[FileFingerprint]
    strongFingerprint*: ContentDigest
    outputPayloadKind*: OutputPayloadKind
    outputs*: seq[OutputBlob]

  LocalCas* = object
    root*: string

  ActionCache* = object
    root*: string
    # Directory holding the authoritative per-edge record files. Each edge
    # (keyed by its weak fingerprint via `digestFileName`) owns exactly one
    # file `hot-records/<key>` containing that edge's bounded record set
    # (<= MaxRecordsPerWeakFingerprint path-sets). There is no global
    # append-only log anymore; every write is a temp-file + atomic-rename
    # rewrite of a single edge's file, so cross-edge contention is impossible
    # and independent concurrent builds of the same edge converge on an
    # equivalent file via rename() (Action-Cache-Per-Edge-Store.md §2, §3).
    hotRoot: string

  FileMetadataCache* = object
    entries: Table[string, FileMetadata]
    stats: FileMetadataCacheStats

  FileMetadataCacheStats* = object
    currentRunHits*: int
    coldStats*: int
    warmEntries*: int
    warmRevalidated*: int
    warmUnchanged*: int
    warmChanged*: int

  ActionCacheLookupStatus* = enum
    aclMissNoRecord
    aclMissInputChanged
    aclMissNoOutputPayload
    aclHit
    aclHybridCutoff
    aclRejectedCorruptOutput

  ActionCacheLookup* = object
    status*: ActionCacheLookupStatus
    record*: ActionResultRecord
    message*: string
    changedInputPath*: string

  HotMetadataProbe* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy

  HotMetadataScanStatus* = enum
    hmssUnavailable
    hmssHit
    hmssMissingRecord
    hmssInputChanged
    hmssCorrupt

  HotMetadataScan* = object
    status*: HotMetadataScanStatus
    recordCount*: int
    inputCount*: int
    checkedInputCount*: int

const
  ActionRecordMagic = "RBAR"
  ActionRecordVersion = 3'u16
  # Per-edge record file: a small self-describing container holding the
  # edge's bounded record set. Each contained record is the existing
  # `RBAR` full-record frame, so producers/consumers (incl. the peer cache)
  # stay byte-compatible with `encodeActionResultRecord`.
  PerEdgeFileMagic = "RBPE"
  PerEdgeFileVersion = 1'u16
  RecordTailMask = 0xffff_ffff'u64
  MaxActionRecordFrameBytes = 64 * 1024 * 1024
  MaxRecordsPerWeakFingerprint = 2
  AllFilePermissions {.used.} = {fpUserExec, fpUserWrite, fpUserRead,
    fpGroupExec, fpGroupWrite, fpGroupRead,
    fpOthersExec, fpOthersWrite, fpOthersRead}
    # Windows: marked {.used.} because readPermissions only iterates this set
    # on POSIX hosts; on Windows we discard the recorded mask entirely.

var processWarmFileMetadataEntries = initTable[string, FileMetadata]()

proc byteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc readByte(data: openArray[byte]; pos: var int): byte =
  if pos >= data.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = data[pos]
  inc pos

proc writeDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.add(byte(ord(digest.algorithm)))
  outp.add(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigest(data: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByte(data, pos)
  let domain = readByte(data, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid digest algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid digest domain")
  if pos + 32 > data.len:
    raiseEnvelopeError(eeMalformed, "truncated digest bytes")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = data[pos + i]
  pos += 32

proc writeLocalHash(outp: var seq[byte]; value: LocalInvalidationHash) =
  outp.add(byte(ord(value.algorithm)))
  outp.add(byte(ord(value.domain)))
  outp.writeU64Le(value.value)

proc readLocalHash(data: openArray[byte]; pos: var int): LocalInvalidationHash =
  let algorithm = readByte(data, pos)
  let domain = readByte(data, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid local hash algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid local hash domain")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  result.value = readU64Le(data, pos)

proc writeMetadata(outp: var seq[byte]; metadata: FileMetadata) =
  outp.add(byte(ord(metadata.kind)))
  outp.writeU64Le(metadata.sizeBytes)
  outp.writeU64Le(metadata.mtimeNs)

proc readMetadata(data: openArray[byte]; pos: var int): FileMetadata =
  let kind = readByte(data, pos)
  if kind > byte(ord(ffkOther)):
    raiseEnvelopeError(eeMalformed, "invalid file metadata kind")
  result.kind = FingerprintedFileKind(kind)
  result.sizeBytes = readU64Le(data, pos)
  result.mtimeNs = readU64Le(data, pos)

proc writePermissions(outp: var seq[byte]; permissions: set[FilePermission]) =
  # Windows: the POSIX rwx model does not apply to NTFS (NTFS uses ACLs).
  # For the first round of the Windows port, serialize 0 so cached records
  # round-trip without applying nonsensical permissions on restore. Proper
  # ACL / SetFileAttributes preservation is a follow-up.
  when defined(windows):
    outp.writeU16Le(0'u16)
  else:
    var mask = 0'u16
    for permission in permissions:
      mask = mask or (1'u16 shl ord(permission))
    outp.writeU16Le(mask)

proc readPermissions(data: openArray[byte]; pos: var int): set[FilePermission] =
  let mask = readU16Le(data, pos)
  let knownMask = (1'u16 shl (ord(fpOthersRead) + 1)) - 1
  if (mask and not knownMask) != 0:
    raiseEnvelopeError(eeMalformed, "invalid file permission mask")
  # Windows: any mask we encounter (whether 0 from a Windows writer or
  # a non-zero mask from a POSIX writer) is intentionally discarded — the
  # rwx bits have no Windows equivalent and we don't try to translate them
  # onto NTFS ACLs yet.
  when defined(windows):
    discard mask
    result = {}
  else:
    for permission in AllFilePermissions:
      if (mask and (1'u16 shl ord(permission))) != 0:
        result.incl(permission)

proc writeFingerprint(outp: var seq[byte]; fp: FileFingerprint) =
  outp.writeString(fp.path)
  outp.add(byte(ord(fp.policy)))
  outp.writeMetadata(fp.metadata)
  outp.add(if fp.hasLocalHash: 1'u8 else: 0'u8)
  if fp.hasLocalHash:
    outp.writeLocalHash(fp.localHash)

proc readFingerprint(data: openArray[byte]; pos: var int): FileFingerprint =
  result.path = readString(data, pos)
  let policy = readByte(data, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid fingerprint policy")
  result.policy = FileFingerprintPolicy(policy)
  result.metadata = readMetadata(data, pos)
  case readByte(data, pos)
  of 0:
    result.hasLocalHash = false
  of 1:
    result.hasLocalHash = true
    result.localHash = readLocalHash(data, pos)
  else:
    raiseEnvelopeError(eeMalformed, "invalid local hash presence flag")

proc digestKey(digest: ContentDigest): string =
  $ord(digest.algorithm) & ":" & $ord(digest.domain) & ":" & toHex(digest.bytes)

proc digestFileName(digest: ContentDigest): string =
  $ord(digest.algorithm) & "-" & $ord(digest.domain) & "-" &
    toHex(digest.bytes) & ".rbar"

proc perEdgeRecordFileName*(weak: ContentDigest): string =
  ## Name of the authoritative per-edge record file for `weak` inside the
  ## cache's `hot-records/` directory. Exposed so callers (GC/retention,
  ## tooling, tests) can locate an individual edge's file without
  ## duplicating the naming scheme.
  digestFileName(weak)

when defined(windows):
  # Minimal binding to GetFileAttributesExW so fingerprintMetadata can collect
  # kind+size+mtime in ONE syscall. The stdlib path (fileExists + dirExists +
  # getFileInfo) was three calls -- two GetFileAttributesW plus a much heavier
  # CreateFile/GetFileInformationByHandle/CloseHandle round trip -- and noop
  # cache hits stat hundreds of inputs/outputs per build.
  type
    Win32FileAttributeData = object
      dwFileAttributes: int32
      ftCreationTime: FILETIME
      ftLastAccessTime: FILETIME
      ftLastWriteTime: FILETIME
      nFileSizeHigh: int32
      nFileSizeLow: int32

  proc getFileAttributesExW(lpFileName: WideCString;
                            fInfoLevelId: int32;
                            lpFileInformation: pointer): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "GetFileAttributesExW",
    sideEffect.}

  const
    GetFileExInfoStandard = 0'i32
    FileTimeEpochDiff100Ns = 116_444_736_000_000_000'i64

proc fingerprintMetadata(path: string): FileMetadata =
  let fsPath = extendedPath(path)
  when defined(linux):
    var stat: Stat
    if lstat(fsPath.cstring, stat) != 0:
      return FileMetadata(kind: ffkMissing)
    result.kind =
      if S_ISREG(stat.st_mode):
        ffkRegular
      elif S_ISDIR(stat.st_mode):
        ffkDirectory
      elif S_ISLNK(stat.st_mode):
        try:
          let info = getFileInfo(fsPath, followSymlink = false)
          case info.kind
          of pcFile, pcLinkToFile:
            ffkRegular
          of pcDir, pcLinkToDir:
            ffkDirectory
        except OSError:
          ffkMissing
      else:
        ffkOther
    result.sizeBytes =
      if stat.st_size < 0: 0'u64 else: uint64(stat.st_size)
    result.mtimeNs = uint64(cast[int64](stat.st_mtim.tv_sec)) *
      1_000_000_000'u64 + uint64(stat.st_mtim.tv_nsec)
  elif defined(windows):
    var data: Win32FileAttributeData
    let wide = newWideCString(fsPath)
    if getFileAttributesExW(wide, GetFileExInfoStandard, addr data) == 0:
      return FileMetadata(kind: ffkMissing)
    if (data.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) != 0:
      result.kind = ffkDirectory
    else:
      result.kind = ffkRegular
      result.sizeBytes = (uint64(cast[uint32](data.nFileSizeHigh)) shl 32) or
        uint64(cast[uint32](data.nFileSizeLow))
      # FILETIME is 100-ns ticks since 1601-01-01 UTC; convert to ns since
      # the Unix epoch so the value matches what the Linux stat path emits.
      let ft100Ns = (int64(cast[uint32](data.ftLastWriteTime.dwHighDateTime)) shl 32) or
        int64(cast[uint32](data.ftLastWriteTime.dwLowDateTime))
      let unixNs100 = ft100Ns - FileTimeEpochDiff100Ns
      if unixNs100 > 0:
        result.mtimeNs = uint64(unixNs100) * 100'u64
  else:
    if not fileExists(fsPath) and not dirExists(fsPath):
      return FileMetadata(kind: ffkMissing)
    let info = getFileInfo(fsPath, followSymlink = false)
    result.kind =
      case info.kind
      of pcFile, pcLinkToFile:
        ffkRegular
      of pcDir, pcLinkToDir:
        ffkDirectory
    result.sizeBytes = uint64(max(info.size, 0))
    let mtime = info.lastWriteTime
    result.mtimeNs = uint64(mtime.toUnix) * 1_000_000_000'u64 +
      uint64(mtime.nanosecond)
  if result.kind == ffkDirectory:
    # Existing-directory probes depend on the fact that a directory exists,
    # not on the physical directory inode mtime. Directory enumeration needs a
    # membership fingerprint; the transitional monitor path stores those
    # observations as probes, so recording directory mtimes would make actions
    # miss whenever their own output directory is touched.
    result.sizeBytes = 0
    result.mtimeNs = 0

proc initFileMetadataCache*(): FileMetadataCache =
  FileMetadataCache(entries: initTable[string, FileMetadata]())

proc clear*(cache: var FileMetadataCache) =
  cache.entries.clear()

proc invalidate*(cache: var FileMetadataCache; path: string) =
  cache.entries.del(path)

proc metadataStats*(cache: FileMetadataCache): FileMetadataCacheStats =
  cache.stats

proc fingerprintMetadata(path: string;
                         cache: ptr FileMetadataCache): FileMetadata =
  if cache.isNil:
    return fingerprintMetadata(path)
  if cache[].entries.hasKey(path):
    inc cache[].stats.currentRunHits
    return cache[].entries[path]
  let hadWarmEntry = processWarmFileMetadataEntries.hasKey(path)
  let priorMetadata =
    if hadWarmEntry: processWarmFileMetadataEntries[path]
    else: FileMetadata()
  if hadWarmEntry:
    inc cache[].stats.warmEntries
    inc cache[].stats.warmRevalidated
  else:
    inc cache[].stats.coldStats
  result = fingerprintMetadata(path)
  if hadWarmEntry:
    if result == priorMetadata:
      inc cache[].stats.warmUnchanged
    else:
      inc cache[].stats.warmChanged
  cache[].entries[path] = result
  processWarmFileMetadataEntries[path] = result

proc fileBytesForHash(path: string; metadata: FileMetadata): seq[byte] =
  if metadata.kind != ffkRegular:
    return @[]
  bytes(readFile(extendedPath(path)))

proc isDirectRegularFile(path: string): bool =
  when defined(linux):
    var stat: Stat
    lstat(extendedPath(path).cstring, stat) == 0 and S_ISREG(stat.st_mode)
  else:
    let info = getFileInfo(extendedPath(path), followSymlink = false)
    info.kind == pcFile

proc observeFileWithMetadata(path: string; policy: FileFingerprintPolicy;
                             metadata: FileMetadata): FileFingerprint =
  result.path = path
  result.policy = policy
  result.metadata = metadata
  if policy in {ffpChecksum, ffpHybrid}:
    result.hasLocalHash = true
    result.localHash = localHash(fileBytesForHash(path, result.metadata))

proc observeFile*(path: string; policy: FileFingerprintPolicy): FileFingerprint =
  observeFileWithMetadata(path, policy, fingerprintMetadata(path))

proc observeFile*(path: string; policy: FileFingerprintPolicy;
                  cache: ptr FileMetadataCache): FileFingerprint =
  observeFileWithMetadata(path, policy, fingerprintMetadata(path, cache))

proc isVolatileDevicePath(path: string): bool =
  let normalized = path.replace('\\', '/')
  normalized == "/dev" or normalized.startsWith("/dev/") or
    normalized == "/proc" or normalized.startsWith("/proc/") or
    normalized == "/sys" or normalized.startsWith("/sys/") or
    normalized == "/run" or normalized.startsWith("/run/")

proc isRecordableInput(input: FileFingerprint): bool =
  if input.path.isVolatileDevicePath():
    return false
  input.metadata.kind != ffkOther

proc digestHex*(digest: ContentDigest): string =
  toHex(digest.bytes)

proc openLocalCas*(root: string): LocalCas =
  result.root = root
  createDir(extendedPath(result.root))
  createDir(extendedPath(result.root / "tmp"))

proc blobPath*(cas: LocalCas; digest: ContentDigest): string =
  let hex = digestHex(digest)
  cas.root / hex[0 .. 1] / hex[2 .. ^1]

proc blobRef*(digest: ContentDigest; sizeBytes: uint64): CasBlobRef =
  CasBlobRef(digest: digest, sizeBytes: sizeBytes)

proc readBlob*(cas: LocalCas; blob: CasBlobRef): seq[byte] =
  let path = cas.blobPath(blob.digest)
  if not fileExists(extendedPath(path)):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  result = bytes(readFile(extendedPath(path)))
  if uint64(result.len) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  let actual = casDigest(result)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc verifyBlob*(cas: LocalCas; blob: CasBlobRef) =
  let path = cas.blobPath(blob.digest)
  if not fileExists(extendedPath(path)):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  let info = getFileInfo(extendedPath(path), followSymlink = false)
  if uint64(info.size) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  let actual = casFileDigest(extendedPath(path), blob.sizeBytes)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc storeBlob*(cas: LocalCas; payload: openArray[byte]): CasBlobRef =
  result.digest = casDigest(payload)
  result.sizeBytes = uint64(payload.len)
  let finalPath = cas.blobPath(result.digest)
  if fileExists(extendedPath(finalPath)):
    cas.verifyBlob(result)
    return
  createDir(extendedPath(finalPath.splitPath.head))
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(extendedPath(tmpPath), byteString(payload))
  try:
    moveFile(extendedPath(tmpPath), extendedPath(finalPath))
  except OSError:
    if fileExists(extendedPath(tmpPath)):
      removeFile(extendedPath(tmpPath))
    if fileExists(extendedPath(finalPath)):
      cas.verifyBlob(result)
    else:
      raise

proc storeFileBlob*(cas: LocalCas; path: string; sizeBytes: uint64): CasBlobRef =
  result.digest = casFileDigest(extendedPath(path), sizeBytes)
  result.sizeBytes = sizeBytes
  let finalPath = cas.blobPath(result.digest)
  let finalFsPath = extendedPath(finalPath)
  if fileExists(finalFsPath):
    cas.verifyBlob(result)
    return
  createDir(extendedPath(finalPath.splitPath.head))
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  let tmpFsPath = extendedPath(tmpPath)
  copyFile(extendedPath(path), tmpFsPath)
  try:
    moveFile(tmpFsPath, finalFsPath)
  except OSError:
    if fileExists(tmpFsPath):
      removeFile(tmpFsPath)
    if fileExists(finalFsPath):
      cas.verifyBlob(result)
    else:
      raise

proc materialPath(root, path: string): string =
  if path.isAbsolute or root.len == 0:
    path
  else:
    root / path

proc restoreOutputs*(cas: LocalCas; record: ActionResultRecord;
                     outputRoot = "") =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  var payloads: seq[seq[byte]] = @[]
  for output in record.outputs:
    payloads.add(cas.readBlob(output.blob))
  for i, output in record.outputs:
    let destination = materialPath(outputRoot, output.path)
    createDir(extendedPath(destination.splitPath.head))
    let tmpPath = destination & ".reprotmp." & $getCurrentProcessId()
    writeFile(extendedPath(tmpPath), byteString(payloads[i]))
    # Windows: rwx permissions are not preserved (see writePermissions);
    # applying setFilePermissions with an empty set would clobber the file's
    # NTFS ACLs in unhelpful ways, so we skip it entirely. Follow-up:
    # preserve ACLs / read-only attribute via icacls / SetFileAttributes.
    when not defined(windows):
      setFilePermissions(extendedPath(tmpPath), output.permissions)
    if fileExists(extendedPath(destination)):
      removeFile(extendedPath(destination))
    moveFile(extendedPath(tmpPath), extendedPath(destination))
    when not defined(windows):
      setFilePermissions(extendedPath(destination), output.permissions)

proc strongIdentityPayload(weak: ContentDigest;
                           inputs: openArray[FileFingerprint]): seq[byte] =
  result.add(byte(ord('R')))
  result.add(byte(ord('B')))
  result.add(byte(ord('S')))
  result.add(byte(ord('F')))
  result.writeDigest(weak)
  result.writeU32Le(uint32(inputs.len))
  for input in inputs:
    result.writeString(input.path)
    result.add(byte(ord(input.policy)))
    case input.policy
    of ffpTimestamp:
      result.writeMetadata(input.metadata)
    of ffpChecksum, ffpHybrid:
      if not input.hasLocalHash:
        raise newException(ActionRecordError,
          "content fingerprint missing for " & input.path)
      result.writeLocalHash(input.localHash)

proc computeStrongFingerprint*(weak: ContentDigest;
                               inputs: openArray[FileFingerprint]): ContentDigest =
  blake3DomainDigest(strongIdentityPayload(weak, inputs), hdActionFingerprint)

proc encodeRecord(record: ActionResultRecord): seq[byte] =
  result.add(byte(ord(ActionRecordMagic[0])))
  result.add(byte(ord(ActionRecordMagic[1])))
  result.add(byte(ord(ActionRecordMagic[2])))
  result.add(byte(ord(ActionRecordMagic[3])))
  result.writeU16Le(ActionRecordVersion)
  result.writeDigest(record.weakFingerprint)
  result.add(byte(ord(record.policy)))
  result.writeU32Le(uint32(record.inputs.len))
  for input in record.inputs:
    result.writeFingerprint(input)
  result.writeDigest(record.strongFingerprint)
  result.add(byte(ord(record.outputPayloadKind)))
  result.writeU32Le(uint32(record.outputs.len))
  for output in record.outputs:
    result.writeString(output.path)
    result.writeMetadata(output.metadata)
    result.writePermissions(output.permissions)
    case record.outputPayloadKind
    of opkCasBlobs:
      result.writeDigest(output.blob.digest)
      result.writeU64Le(output.blob.sizeBytes)
    of opkMetadataOnly:
      discard

proc decodeRecord(payload: openArray[byte]): ActionResultRecord =
  if payload.len < 6:
    raiseEnvelopeError(eeMalformed, "truncated action record")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionRecordMagic[i])):
      raiseEnvelopeError(eeUnknownMagic, "unknown action record magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  if version notin {2'u16, ActionRecordVersion}:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported action record version")
  result.weakFingerprint = readDigest(payload, pos)
  let policy = readByte(payload, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid record policy")
  result.policy = FileFingerprintPolicy(policy)
  let inputCount = int(readU32Le(payload, pos))
  result.inputs = newSeq[FileFingerprint](inputCount)
  for i in 0 ..< inputCount:
    result.inputs[i] = readFingerprint(payload, pos)
  result.strongFingerprint = readDigest(payload, pos)
  if version >= 3'u16:
    let outputPayloadKind = readByte(payload, pos)
    if outputPayloadKind > byte(ord(opkMetadataOnly)):
      raiseEnvelopeError(eeMalformed, "invalid output payload kind")
    result.outputPayloadKind = OutputPayloadKind(outputPayloadKind)
  else:
    result.outputPayloadKind = opkCasBlobs
  let outputCount = int(readU32Le(payload, pos))
  result.outputs = newSeq[OutputBlob](outputCount)
  for i in 0 ..< outputCount:
    result.outputs[i].path = readString(payload, pos)
    if version >= 3'u16:
      result.outputs[i].metadata = readMetadata(payload, pos)
      result.outputs[i].permissions = readPermissions(payload, pos)
      case result.outputPayloadKind
      of opkCasBlobs:
        let digest = readDigest(payload, pos)
        let size = readU64Le(payload, pos)
        result.outputs[i].blob = blobRef(digest, size)
      of opkMetadataOnly:
        discard
    else:
      let digest = readDigest(payload, pos)
      let size = readU64Le(payload, pos)
      result.outputs[i].blob = blobRef(digest, size)
      result.outputs[i].permissions = readPermissions(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action record bytes")

proc writeActionResultRecordFile*(path: string; record: ActionResultRecord) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), byteString(encodeRecord(record)))

proc encodeActionResultRecord*(record: ActionResultRecord): seq[byte] =
  ## Public wrapper over the on-disk record codec. Used by the peer-cache
  ## action-bundle (`repro_peer_cache/action_bundle.nim`) so producer and
  ## consumer agree byte-for-byte with the on-disk action-cache encoding.
  encodeRecord(record)

proc decodeActionResultRecord*(payload: openArray[byte]): ActionResultRecord =
  ## Public wrapper over the on-disk record codec. Inverse of
  ## `encodeActionResultRecord`. Raises `EnvelopeError` on malformed
  ## input.
  decodeRecord(payload)

proc metadataOnly(input: FileFingerprint): FileFingerprint =
  FileFingerprint(
    path: input.path,
    policy: input.policy,
    metadata: input.metadata,
    hasLocalHash: false)

proc hotRecordPath(cache: ActionCache; weak: ContentDigest): string =
  ## Authoritative per-edge record file for `weak`. One file per edge; it
  ## holds the edge's full bounded record set (<= MaxRecordsPerWeakFingerprint).
  cache.hotRoot / digestFileName(weak)

proc hotMetadataRecord(record: ActionResultRecord): ActionResultRecord =
  result = record
  result.inputs.setLen(0)
  for input in record.inputs:
    result.inputs.add(metadataOnly(input))
  result.outputs.setLen(0)
  result.outputPayloadKind = opkMetadataOnly
  result.strongFingerprint = ContentDigest()

proc recordTail(payload: openArray[byte]): uint32 =
  uint32(localHash(payload).value and RecordTailMask)

proc encodePerEdgeFile(records: openArray[ActionResultRecord]): seq[byte] =
  ## Serialize an edge's bounded record set into its per-edge container.
  ## Each contained record is the existing `RBAR` full-record frame, so the
  ## bytes are identical to what `encodeActionResultRecord` produces for a
  ## single record.
  result.add(byte(ord(PerEdgeFileMagic[0])))
  result.add(byte(ord(PerEdgeFileMagic[1])))
  result.add(byte(ord(PerEdgeFileMagic[2])))
  result.add(byte(ord(PerEdgeFileMagic[3])))
  result.writeU16Le(PerEdgeFileVersion)
  result.writeU32Le(uint32(records.len))
  for record in records:
    let payload = encodeRecord(record)
    result.writeU32Le(uint32(payload.len))
    result.add(payload)
    result.writeU32Le(recordTail(payload))

proc decodePerEdgeFile(raw: openArray[byte]): seq[ActionResultRecord] =
  ## Inverse of `encodePerEdgeFile`. Tolerates a truncated tail (a crashed
  ## writer that lost the rename race leaves either the old file or a
  ## complete new file; a torn body is treated as "stop at the last intact
  ## record" rather than raising, matching the pre-existing frame reader).
  if raw.len < 10:
    return
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return
  var pos = 4
  let version = readU16Le(raw, pos)
  if version != PerEdgeFileVersion:
    return
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      break
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or pos + length + 4 > raw.len:
      break
    let payload = raw[pos .. pos + length - 1]
    pos += length
    let tail = readU32Le(raw, pos)
    if tail != recordTail(payload):
      break
    try:
      result.add(decodeRecord(payload))
    except EnvelopeError:
      break

proc perEdgeRecordFileIsIntact*(raw: openArray[byte]): bool =
  ## Strict validator: true iff `raw` is a byte-complete per-edge file — a
  ## valid RBPE header whose declared record count is fully present and every
  ## contained RBAR frame decodes with a matching tail and no trailing bytes.
  ## Unlike `decodePerEdgeFile` (which stops at the first torn frame), this
  ## rejects a torn/interleaved file. Used to prove atomicity: an atomic
  ## rename never publishes a file that fails this check; a truncate-then-write
  ## can. An empty file is treated as "not yet an intact record file".
  if raw.len == 0:
    return false
  if raw.len < 10:
    return false
  for i in 0 ..< 4:
    if raw[i] != byte(ord(PerEdgeFileMagic[i])):
      return false
  var pos = 4
  if readU16Le(raw, pos) != PerEdgeFileVersion:
    return false
  let count = int(readU32Le(raw, pos))
  for _ in 0 ..< count:
    if pos + 8 > raw.len:
      return false
    let length = int(readU32Le(raw, pos))
    if length < 0 or length > MaxActionRecordFrameBytes or
        pos + length + 4 > raw.len:
      return false
    let payload = raw[pos .. pos + length - 1]
    pos += length
    if readU32Le(raw, pos) != recordTail(payload):
      return false
    try:
      discard decodeRecord(payload)
    except EnvelopeError:
      return false
  pos == raw.len

proc loadPerEdgeRecords(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Read the single authoritative `hot-records/<key>` file for `weak`.
  ## O(1) file open — never a whole-cache scan.
  let path = cache.hotRecordPath(weak)
  if not fileExists(extendedPath(path)):
    return
  try:
    result = decodePerEdgeFile(bytes(readFile(extendedPath(path))))
  except OSError, IOError:
    result = @[]

proc writePerEdgeRecords(cache: ActionCache; weak: ContentDigest;
                         records: openArray[ActionResultRecord]) =
  ## Atomically publish an edge's record set: encode to a uniquely named
  ## temp file, fsync-free `rename()` over `hot-records/<key>`. A rewrite of
  ## exactly one edge's file, never an append. Concurrent independent builds
  ## of the same edge each produce an equivalent file and the last rename
  ## wins — convergence by construction (Action-Cache-Per-Edge-Store.md §2.1).
  let finalPath = cache.hotRecordPath(weak)
  createDir(extendedPath(cache.hotRoot))
  let now = getTime()
  let tmpPath = cache.hotRoot / (digestFileName(weak) & ".tmp." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(extendedPath(tmpPath), byteString(encodePerEdgeFile(records)))
  try:
    moveFile(extendedPath(tmpPath), extendedPath(finalPath))
  except OSError:
    if fileExists(extendedPath(tmpPath)):
      removeFile(extendedPath(tmpPath))
    raise

proc writePerEdgeRecord(cache: ActionCache; record: ActionResultRecord) =
  ## Merge `record` into its edge's bounded set (dedup by strong fingerprint,
  ## keep the most recent MaxRecordsPerWeakFingerprint path-sets) and rewrite
  ## the per-edge file atomically. Idempotent: re-installing an identical
  ## record leaves the file byte-unchanged in content.
  var records = cache.loadPerEdgeRecords(record.weakFingerprint)
  var filtered: seq[ActionResultRecord] = @[]
  for existing in records:
    if existing.strongFingerprint != record.strongFingerprint:
      filtered.add(existing)
  filtered.add(record)
  if filtered.len > MaxRecordsPerWeakFingerprint:
    filtered = filtered[filtered.len - MaxRecordsPerWeakFingerprint .. ^1]
  cache.writePerEdgeRecords(record.weakFingerprint, filtered)

proc hotInputKey(input: FileFingerprint): string =
  input.path & "\0" & $ord(input.policy) & "\0" &
    $ord(input.metadata.kind) & "\0" & $input.metadata.sizeBytes & "\0" &
    $input.metadata.mtimeNs

proc scanHotIndexMetadataInputsUnchanged*(cache: ActionCache;
                                          probes: openArray[HotMetadataProbe];
                                          metadataCache: ptr FileMetadataCache = nil):
                                          HotMetadataScan =
  ## Batch "are all these edges still cache hits" check, now served by
  ## reading each probe's single authoritative `hot-records/<key>` file
  ## instead of scanning a global index. Cost is O(probes), page-cached,
  ## never a whole-cache scan. Result semantics match the former index
  ## scan: hmssHit iff every probe has a matching record whose inputs are
  ## all metadata-unchanged; hmssMissingRecord if any probe has no matching
  ## record; hmssInputChanged if a matched record's input changed.
  if probes.len == 0:
    return HotMetadataScan(status: hmssHit)
  var checkedInputs = 0
  var totalRecords = 0
  for probe in probes:
    let records = cache.loadPerEdgeRecords(probe.weakFingerprint)
    var matched = false
    for record in records:
      inc totalRecords
      if record.weakFingerprint == probe.weakFingerprint and
          record.policy == probe.policy:
        matched = true
    if not matched:
      return HotMetadataScan(status: hmssMissingRecord,
        recordCount: totalRecords)
    for record in records:
      if record.weakFingerprint == probe.weakFingerprint and
          record.policy == probe.policy:
        for input in record.inputs:
          inc checkedInputs
          if fingerprintMetadata(input.path, metadataCache) != input.metadata:
            return HotMetadataScan(status: hmssInputChanged,
              recordCount: totalRecords, checkedInputCount: checkedInputs)
  HotMetadataScan(status: hmssHit, recordCount: totalRecords,
    checkedInputCount: checkedInputs)

proc readHotRecord(cache: var ActionCache; weak: ContentDigest):
    tuple[found: bool; record: ActionResultRecord] =
  ## Read the newest metadata-only view of the edge's record from its single
  ## per-edge file. Returns the most recent record (last in the bounded set)
  ## matching `weak`, downcast to metadata-only so callers observe the same
  ## shape the old hot store returned.
  let records = cache.loadPerEdgeRecords(weak)
  for i in countdown(records.high, 0):
    if records[i].weakFingerprint == weak:
      return (found: true, record: hotMetadataRecord(records[i]))

proc appendActionResultRecord*(cache: var ActionCache;
                               record: ActionResultRecord) {.gcsafe.} =
  ## Public bridge so the peer-cache reader can install a peer-fetched
  ## record into the local action cache. Writes the edge's per-edge file
  ## (temp + atomic rename), never an append. Idempotency is bounded by
  ## `MaxRecordsPerWeakFingerprint`; re-installing an identical record
  ## leaves the file's record set unchanged.
  {.cast(gcsafe).}:
    cache.writePerEdgeRecord(record)

proc loadRecordsForWeak(cache: ActionCache; weak: ContentDigest):
    seq[ActionResultRecord] =
  ## Full-record lookup for one edge: read the single authoritative
  ## `hot-records/<key>` file, keeping only records whose weak fingerprint
  ## matches (defensive against a hash collision on the filename). Never a
  ## whole-cache scan.
  for record in cache.loadPerEdgeRecords(weak):
    if record.weakFingerprint == weak:
      result.add(record)
      if result.len > MaxRecordsPerWeakFingerprint:
        result = result[result.len - MaxRecordsPerWeakFingerprint .. ^1]

const LegacyGlobalStoreFiles = [
  "action-results.records",
  "action-results.hot.records",
  "action-results.hot.index"]

proc removeLegacyGlobalStore(root: string) =
  ## One-time ignore-then-delete of the pre-existing global append-log files
  ## (Action-Cache-Per-Edge-Store.md §3). Best-effort: a busy concurrent
  ## reader on another host/process may still hold one open; a failed unlink
  ## is harmless because the per-edge store is authoritative and the global
  ## files are never read.
  for name in LegacyGlobalStoreFiles:
    let path = root / name
    if fileExists(extendedPath(path)):
      try:
        removeFile(extendedPath(path))
      except OSError:
        discard

proc openActionCache*(root: string): ActionCache =
  result.root = root
  result.hotRoot = root / "hot-records"
  createDir(extendedPath(result.root))
  createDir(extendedPath(result.hotRoot))
  # One-time cleanup: the old global append-log store is gone. Ignore any
  # pre-existing `action-results.*` files and delete them on open so a
  # migrated cache root stops growing without a re-init.
  removeLegacyGlobalStore(result.root)

proc flushHotIndex*(cache: var ActionCache) =
  ## Retained as a public no-op for callers that flushed the former
  ## write-behind hot index. Per-edge records are now written synchronously
  ## and atomically at record time, so there is nothing to flush. (The
  ## shared-memory write-back tier is AC-2; this proc gains real work there.)
  discard

proc lookupHotMetadataRecord*(cache: var ActionCache; weak: ContentDigest;
                              policy: FileFingerprintPolicy):
    Option[ActionResultRecord] =
  ## Metadata-only lookup served from the edge's single per-edge file.
  if policy notin {ffpTimestamp, ffpHybrid}:
    return none(ActionResultRecord)
  let hot = cache.readHotRecord(weak)
  if not hot.found or hot.record.policy != policy:
    return none(ActionResultRecord)
  some(hot.record)

proc hotMetadataInputsUnchanged*(cache: var ActionCache;
                                 metadataCache: ptr FileMetadataCache = nil): bool =
  ## Retained for API compatibility. There is no whole-cache hot-input set
  ## to scan anymore; per-edge input freshness is checked by the batch
  ## `scanHotIndexMetadataInputsUnchanged` / per-record helpers. With no
  ## global set to iterate, this trivially holds.
  true

proc hotMetadataRecordCount*(cache: var ActionCache): int =
  ## The former whole-cache count is meaningless without a global hot store.
  ## Returning 0 makes the build engine's `actions.len == count` shortcut
  ## never fire, so it always takes the per-record path (which reads each
  ## edge's file) — semantics-preserving, no whole-cache scan.
  0

proc hotMetadataRecordInputsUnchanged*(records: openArray[ActionResultRecord];
                                       metadataCache: ptr FileMetadataCache = nil): bool =
  var seen = initHashSet[string]()
  for record in records:
    for input in record.inputs:
      let inputKey = hotInputKey(input)
      if seen.contains(inputKey):
        continue
      seen.incl(inputKey)
      if fingerprintMetadata(input.path, metadataCache) != input.metadata:
        return false
  true

proc recordActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         inputPaths, outputPaths: openArray[string];
                         outputRoot = "";
                         storeOutputBlobs = true;
                         metadataCache: ptr FileMetadataCache = nil):
                         ActionResultRecord =
  result.weakFingerprint = weak
  result.policy = policy
  for path in inputPaths:
    let input = observeFile(path, policy, metadataCache)
    if input.isRecordableInput():
      result.inputs.add(input)
  result.strongFingerprint = computeStrongFingerprint(weak, result.inputs)
  result.outputPayloadKind =
    if storeOutputBlobs: opkCasBlobs else: opkMetadataOnly
  for path in outputPaths:
    let source = materialPath(outputRoot, path)
    let sourceMetadata = fingerprintMetadata(source, metadataCache)
    # Windows: getFilePermissions returns a synthetic POSIX set derived from
    # the read-only attribute; we don't preserve it (see writePermissions),
    # so emit an empty set here. The cache record still round-trips cleanly.
    when defined(windows):
      let perms: set[FilePermission] = {}
    else:
      let perms = getFilePermissions(extendedPath(source))
    let blob =
      if storeOutputBlobs:
        if sourceMetadata.kind == ffkRegular and isDirectRegularFile(source):
          cas.storeFileBlob(source, sourceMetadata.sizeBytes)
        else:
          cas.storeBlob(bytes(readFile(extendedPath(source))))
      else:
        CasBlobRef()
    result.outputs.add(OutputBlob(path: path, metadata: sourceMetadata,
      blob: blob, permissions: perms))
  cache.writePerEdgeRecord(result)

proc refreshedInputs(record: ActionResultRecord; changed: var bool;
                     hybridCutoff: var bool;
                     changedInputPath: var string;
                     metadataCache: ptr FileMetadataCache):
                     tuple[inputs: seq[FileFingerprint],
                           reusedRecordedInputs: bool] =
  result.reusedRecordedInputs = true
  for i, recorded in record.inputs:
    let currentMetadata = fingerprintMetadata(recorded.path, metadataCache)
    case recorded.policy
    of ffpTimestamp:
      if currentMetadata != recorded.metadata:
        changed = true
        changedInputPath = recorded.path
        return
      if not result.reusedRecordedInputs:
        result.inputs[i] = recorded
    of ffpChecksum:
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if (not recorded.hasLocalHash) or (not current.hasLocalHash) or
          current.localHash != recorded.localHash:
        changed = true
        changedInputPath = recorded.path
        return
      if not result.reusedRecordedInputs:
        result.inputs[i] = recorded
    of ffpHybrid:
      if currentMetadata == recorded.metadata:
        if not result.reusedRecordedInputs:
          result.inputs[i] = recorded
        continue
      if not recorded.hasLocalHash:
        changed = true
        changedInputPath = recorded.path
        return
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if not current.hasLocalHash:
        changed = true
        changedInputPath = recorded.path
        return
      if current.localHash == recorded.localHash:
        if result.reusedRecordedInputs:
          result.inputs = newSeq[FileFingerprint](record.inputs.len)
          for prior in 0 ..< i:
            result.inputs[prior] = record.inputs[prior]
          result.reusedRecordedInputs = false
        result.inputs[i] = current
        hybridCutoff = true
      else:
        changed = true
        changedInputPath = recorded.path
        return

proc verifyOutputs(cas: LocalCas; record: ActionResultRecord) =
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  for output in record.outputs:
    cas.verifyBlob(output.blob)

proc lookupActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         verifyOutputBlobs = true;
                         allowMetadataOnlyHit = false;
                         metadataCache: ptr FileMetadataCache = nil): ActionCacheLookup =
  if allowMetadataOnlyHit and not verifyOutputBlobs and policy in {ffpTimestamp, ffpHybrid}:
    let hot = cache.readHotRecord(weak)
    if hot.found and hot.record.policy == policy:
      var changed = false
      var changedInput = ""
      for input in hot.record.inputs:
        if fingerprintMetadata(input.path, metadataCache) != input.metadata:
          changed = true
          changedInput = input.path
          break
      if not changed:
        return ActionCacheLookup(status: aclHit, record: hot.record)
      return ActionCacheLookup(
        status: aclMissInputChanged,
        record: hot.record,
        message: "input metadata changed: " & changedInput,
        changedInputPath: changedInput)

  let records = cache.loadRecordsForWeak(weak)
  if records.len == 0:
    return ActionCacheLookup(status: aclMissNoRecord,
      message: "no cache record for weak fingerprint")
  var sawInputChange = false
  var firstChangedInput = ""
  for i in countdown(records.high, 0):
    let record = records[i]
    if record.policy != policy:
      continue
    var changed = false
    var hybridCutoff = false
    var changedInput = ""
    let refreshed = refreshedInputs(record, changed, hybridCutoff,
      changedInput, metadataCache)
    if changed:
      sawInputChange = true
      if firstChangedInput.len == 0:
        firstChangedInput = changedInput
      continue
    var candidate = record
    if not refreshed.reusedRecordedInputs:
      candidate.inputs = refreshed.inputs
      candidate.strongFingerprint = computeStrongFingerprint(weak,
        candidate.inputs)
      if candidate.strongFingerprint != record.strongFingerprint:
        sawInputChange = true
        if firstChangedInput.len == 0:
          firstChangedInput = "strong fingerprint"
        continue
    if verifyOutputBlobs:
      if candidate.outputPayloadKind != opkCasBlobs:
        return ActionCacheLookup(status: aclMissNoOutputPayload,
          record: candidate,
          message: "cache record does not contain output payloads")
      try:
        cas.verifyOutputs(candidate)
      except CacheIntegrityError as err:
        return ActionCacheLookup(status: aclRejectedCorruptOutput,
          record: candidate, message: err.msg)
    if hybridCutoff:
      cache.writePerEdgeRecord(candidate)
      return ActionCacheLookup(status: aclHybridCutoff, record: candidate)
    return ActionCacheLookup(status: aclHit, record: candidate)
  if sawInputChange:
    ActionCacheLookup(
      status: aclMissInputChanged,
      message:
        if firstChangedInput.len > 0:
          "input changed: " & firstChangedInput
        else:
          "input changed",
      changedInputPath: firstChangedInput)
  else:
    ActionCacheLookup(status: aclMissNoRecord,
      message: "no matching cache record for policy")
