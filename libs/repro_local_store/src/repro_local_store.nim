import std/[options, os, sets, tables, times]

when defined(linux):
  import std/posix

import repro_core
import repro_hash

# Re-export the new M56 content-addressed local store API. The pre-M56
# `LocalCas` and `ActionCache` types below remain for the action-cache
# code path the M9 build engine still consumes; the M56 entry points
# live in `repro_local_store/store.nim` and
# `repro_local_store/sqlite3_binding.nim`.
import ./repro_local_store/sqlite3_binding
import ./repro_local_store/store
export sqlite3_binding
export store

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

  OutputBlob* = object
    path*: string
    blob*: CasBlobRef
    permissions*: set[FilePermission]

  ActionResultRecord* = object
    weakFingerprint*: ContentDigest
    policy*: FileFingerprintPolicy
    inputs*: seq[FileFingerprint]
    strongFingerprint*: ContentDigest
    outputs*: seq[OutputBlob]

  LocalCas* = object
    root*: string

  ActionCache* = object
    root*: string
    recordsPath*: string
    hotRoot: string
    hotRecordsPath: string
    hotIndexPath: string
    loadedAllRecords: bool
    hotIndexDirty: bool
    byWeak: Table[string, seq[ActionResultRecord]]
    hotByWeak: Table[string, ActionResultRecord]
    hotInputs: seq[FileFingerprint]

  FileMetadataCache* = object
    entries: Table[string, FileMetadata]

  ActionCacheLookupStatus* = enum
    aclMissNoRecord
    aclMissInputChanged
    aclHit
    aclHybridCutoff
    aclRejectedCorruptOutput

  ActionCacheLookup* = object
    status*: ActionCacheLookupStatus
    record*: ActionResultRecord
    message*: string

  HotIndexDecode = object
    records: Table[string, ActionResultRecord]
    inputs: seq[FileFingerprint]

const
  ActionRecordMagic = "RBAR"
  ActionRecordVersion = 2'u16
  ActionHotRecordMagic = "RBAH"
  ActionHotRecordVersion = 1'u16
  ActionHotIndexMagic = "RBHI"
  ActionHotIndexVersion = 1'u16
  RecordTailMask = 0xffff_ffff'u64
  ActionCacheCompactThreshold = 256 * 1024
  MaxRecordsPerWeakFingerprint = 2
  AllFilePermissions {.used.} = {fpUserExec, fpUserWrite, fpUserRead,
    fpGroupExec, fpGroupWrite, fpGroupRead,
    fpOthersExec, fpOthersWrite, fpOthersRead}
    # Windows: marked {.used.} because readPermissions only iterates this set
    # on POSIX hosts; on Windows we discard the recorded mask entirely.

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

proc fingerprintMetadata(path: string): FileMetadata =
  when defined(linux):
    var stat: Stat
    if lstat(path, stat) != 0:
      return FileMetadata(kind: ffkMissing)
    result.kind =
      if S_ISREG(stat.st_mode):
        ffkRegular
      elif S_ISDIR(stat.st_mode):
        ffkDirectory
      elif S_ISLNK(stat.st_mode):
        try:
          let info = getFileInfo(path, followSymlink = false)
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
  else:
    if not fileExists(path) and not dirExists(path):
      return FileMetadata(kind: ffkMissing)
    let info = getFileInfo(path, followSymlink = false)
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

proc initFileMetadataCache*(): FileMetadataCache =
  FileMetadataCache(entries: initTable[string, FileMetadata]())

proc clear*(cache: var FileMetadataCache) =
  cache.entries.clear()

proc fingerprintMetadata(path: string;
                         cache: ptr FileMetadataCache): FileMetadata =
  if cache.isNil:
    return fingerprintMetadata(path)
  if cache[].entries.hasKey(path):
    return cache[].entries[path]
  result = fingerprintMetadata(path)
  cache[].entries[path] = result

proc fileBytesForHash(path: string; metadata: FileMetadata): seq[byte] =
  if metadata.kind != ffkRegular:
    return @[]
  bytes(readFile(path))

proc isDirectRegularFile(path: string): bool =
  when defined(linux):
    var stat: Stat
    lstat(path, stat) == 0 and S_ISREG(stat.st_mode)
  else:
    let info = getFileInfo(path, followSymlink = false)
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

proc digestHex*(digest: ContentDigest): string =
  toHex(digest.bytes)

proc openLocalCas*(root: string): LocalCas =
  result.root = root
  createDir(result.root)
  createDir(result.root / "tmp")

proc blobPath*(cas: LocalCas; digest: ContentDigest): string =
  let hex = digestHex(digest)
  cas.root / hex[0 .. 1] / hex[2 .. ^1]

proc blobRef*(digest: ContentDigest; sizeBytes: uint64): CasBlobRef =
  CasBlobRef(digest: digest, sizeBytes: sizeBytes)

proc readBlob*(cas: LocalCas; blob: CasBlobRef): seq[byte] =
  let path = cas.blobPath(blob.digest)
  if not fileExists(path):
    raise newException(CacheIntegrityError, "missing CAS object " &
      digestHex(blob.digest))
  result = bytes(readFile(path))
  if uint64(result.len) != blob.sizeBytes:
    raise newException(CacheIntegrityError, "CAS size mismatch for " &
      digestHex(blob.digest))
  let actual = casDigest(result)
  if actual != blob.digest:
    raise newException(CacheIntegrityError, "CAS digest mismatch for " &
      digestHex(blob.digest))

proc verifyBlob*(cas: LocalCas; blob: CasBlobRef) =
  discard cas.readBlob(blob)

proc storeBlob*(cas: LocalCas; payload: openArray[byte]): CasBlobRef =
  result.digest = casDigest(payload)
  result.sizeBytes = uint64(payload.len)
  let finalPath = cas.blobPath(result.digest)
  if fileExists(finalPath):
    cas.verifyBlob(result)
    return
  createDir(finalPath.splitPath.head)
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  writeFile(tmpPath, byteString(payload))
  try:
    moveFile(tmpPath, finalPath)
  except OSError:
    if fileExists(tmpPath):
      removeFile(tmpPath)
    if fileExists(finalPath):
      cas.verifyBlob(result)
    else:
      raise

proc storeFileBlob*(cas: LocalCas; path: string; sizeBytes: uint64): CasBlobRef =
  result.digest = casFileDigest(path, sizeBytes)
  result.sizeBytes = sizeBytes
  let finalPath = cas.blobPath(result.digest)
  if fileExists(finalPath):
    cas.verifyBlob(result)
    return
  createDir(finalPath.splitPath.head)
  let now = getTime()
  let tmpPath = cas.root / "tmp" / (digestHex(result.digest) & "." &
    $getCurrentProcessId() & "." & $now.toUnix & "." & $now.nanosecond)
  copyFile(path, tmpPath)
  try:
    moveFile(tmpPath, finalPath)
  except OSError:
    if fileExists(tmpPath):
      removeFile(tmpPath)
    if fileExists(finalPath):
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
  var payloads: seq[seq[byte]] = @[]
  for output in record.outputs:
    payloads.add(cas.readBlob(output.blob))
  for i, output in record.outputs:
    let destination = materialPath(outputRoot, output.path)
    createDir(destination.splitPath.head)
    let tmpPath = destination & ".reprotmp." & $getCurrentProcessId()
    writeFile(tmpPath, byteString(payloads[i]))
    # Windows: rwx permissions are not preserved (see writePermissions);
    # applying setFilePermissions with an empty set would clobber the file's
    # NTFS ACLs in unhelpful ways, so we skip it entirely. Follow-up:
    # preserve ACLs / read-only attribute via icacls / SetFileAttributes.
    when not defined(windows):
      setFilePermissions(tmpPath, output.permissions)
    if fileExists(destination):
      removeFile(destination)
    moveFile(tmpPath, destination)
    when not defined(windows):
      setFilePermissions(destination, output.permissions)

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
  result.writeU32Le(uint32(record.outputs.len))
  for output in record.outputs:
    result.writeString(output.path)
    result.writeDigest(output.blob.digest)
    result.writeU64Le(output.blob.sizeBytes)
    result.writePermissions(output.permissions)

proc decodeRecord(payload: openArray[byte]): ActionResultRecord =
  if payload.len < 6:
    raiseEnvelopeError(eeMalformed, "truncated action record")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionRecordMagic[i])):
      raiseEnvelopeError(eeUnknownMagic, "unknown action record magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  if version != ActionRecordVersion:
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
  let outputCount = int(readU32Le(payload, pos))
  result.outputs = newSeq[OutputBlob](outputCount)
  for i in 0 ..< outputCount:
    result.outputs[i].path = readString(payload, pos)
    let digest = readDigest(payload, pos)
    let size = readU64Le(payload, pos)
    result.outputs[i].blob = blobRef(digest, size)
    result.outputs[i].permissions = readPermissions(payload, pos)
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action record bytes")

proc writeActionResultRecordFile*(path: string; record: ActionResultRecord) =
  createDir(parentDir(path))
  writeFile(path, byteString(encodeRecord(record)))

proc metadataOnly(input: FileFingerprint): FileFingerprint =
  FileFingerprint(
    path: input.path,
    policy: input.policy,
    metadata: input.metadata,
    hasLocalHash: false)

proc encodeHotRecord(record: ActionResultRecord): seq[byte] =
  result.add(byte(ord(ActionHotRecordMagic[0])))
  result.add(byte(ord(ActionHotRecordMagic[1])))
  result.add(byte(ord(ActionHotRecordMagic[2])))
  result.add(byte(ord(ActionHotRecordMagic[3])))
  result.writeU16Le(ActionHotRecordVersion)
  result.writeDigest(record.weakFingerprint)
  result.add(byte(ord(record.policy)))
  result.writeU32Le(uint32(record.inputs.len))
  for input in record.inputs:
    result.writeString(input.path)
    result.add(byte(ord(input.policy)))
    result.writeMetadata(input.metadata)

proc decodeHotRecord(payload: openArray[byte]): ActionResultRecord =
  if payload.len < 6:
    raiseEnvelopeError(eeMalformed, "truncated action hot record")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionHotRecordMagic[i])):
      raiseEnvelopeError(eeUnknownMagic, "unknown action hot record magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  if version != ActionHotRecordVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported action hot record version")
  result.weakFingerprint = readDigest(payload, pos)
  let policy = readByte(payload, pos)
  if policy > byte(ord(ffpHybrid)):
    raiseEnvelopeError(eeMalformed, "invalid hot record policy")
  result.policy = FileFingerprintPolicy(policy)
  let inputCount = int(readU32Le(payload, pos))
  result.inputs = newSeq[FileFingerprint](inputCount)
  for i in 0 ..< inputCount:
    result.inputs[i].path = readString(payload, pos)
    let inputPolicy = readByte(payload, pos)
    if inputPolicy > byte(ord(ffpHybrid)):
      raiseEnvelopeError(eeMalformed, "invalid hot input policy")
    result.inputs[i].policy = FileFingerprintPolicy(inputPolicy)
    result.inputs[i].metadata = readMetadata(payload, pos)
    result.inputs[i].hasLocalHash = false
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action hot record bytes")

proc hotRecordPath(cache: ActionCache; weak: ContentDigest): string =
  cache.hotRoot / digestFileName(weak)

proc hotMetadataRecord(record: ActionResultRecord): ActionResultRecord =
  result = record
  result.inputs.setLen(0)
  for input in record.inputs:
    result.inputs.add(metadataOnly(input))
  result.outputs.setLen(0)
  result.strongFingerprint = ContentDigest()

proc recordTail(payload: openArray[byte]): uint32 =
  uint32(localHash(payload).value and RecordTailMask)

proc appendFramedPayload(path: string; payload: openArray[byte]) =
  var frame: seq[byte] = @[]
  frame.writeU32Le(uint32(payload.len))
  frame.add(payload)
  frame.writeU32Le(recordTail(payload))
  var handle = open(path, fmAppend)
  try:
    handle.write(byteString(frame))
  finally:
    handle.close()

proc appendHotRecord(cache: var ActionCache; record: ActionResultRecord) =
  var hot = record
  hot = hotMetadataRecord(record)
  let payload = encodeHotRecord(hot)
  appendFramedPayload(cache.hotRecordsPath, payload)
  cache.hotByWeak[digestKey(record.weakFingerprint)] = hot
  cache.hotIndexDirty = true

proc hotInputKey(input: FileFingerprint): string =
  input.path & "\0" & $ord(input.policy) & "\0" &
    $ord(input.metadata.kind) & "\0" & $input.metadata.sizeBytes & "\0" &
    $input.metadata.mtimeNs

proc rebuildHotInputs(cache: var ActionCache) =
  var seen = initHashSet[string]()
  cache.hotInputs.setLen(0)
  for key in cache.hotByWeak.keys:
    for input in cache.hotByWeak[key].inputs:
      let inputKey = hotInputKey(input)
      if seen.contains(inputKey):
        continue
      seen.incl(inputKey)
      cache.hotInputs.add(input)

proc encodeHotIndex(records: Table[string, ActionResultRecord]): seq[byte] =
  type
    InputKey = object
      path: string
      policy: FileFingerprintPolicy
      metadata: FileMetadata
  var inputIds = initTable[string, uint32]()
  var inputs: seq[InputKey] = @[]
  var recordInputIds = initTable[string, seq[uint32]]()
  for key in records.keys:
    var ids: seq[uint32] = @[]
    for input in records[key].inputs:
      let inputKey = hotInputKey(input)
      if not inputIds.hasKey(inputKey):
        inputIds[inputKey] = uint32(inputs.len)
        inputs.add(InputKey(path: input.path, policy: input.policy,
          metadata: input.metadata))
      ids.add(inputIds[inputKey])
    recordInputIds[key] = ids

  result.add(byte(ord(ActionHotIndexMagic[0])))
  result.add(byte(ord(ActionHotIndexMagic[1])))
  result.add(byte(ord(ActionHotIndexMagic[2])))
  result.add(byte(ord(ActionHotIndexMagic[3])))
  result.writeU16Le(ActionHotIndexVersion)
  result.writeU32Le(uint32(inputs.len))
  for input in inputs:
    result.writeString(input.path)
    result.add(byte(ord(input.policy)))
    result.writeMetadata(input.metadata)
  result.writeU32Le(uint32(records.len))
  for key in records.keys:
    let record = records[key]
    result.writeDigest(record.weakFingerprint)
    result.add(byte(ord(record.policy)))
    let ids = recordInputIds[key]
    result.writeU32Le(uint32(ids.len))
    for id in ids:
      result.writeU32Le(id)

proc decodeHotIndex(payload: openArray[byte]): HotIndexDecode =
  result.records = initTable[string, ActionResultRecord]()
  if payload.len < 6:
    raiseEnvelopeError(eeMalformed, "truncated action hot index")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionHotIndexMagic[i])):
      raiseEnvelopeError(eeUnknownMagic, "unknown action hot index magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  if version != ActionHotIndexVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported action hot index version")
  let inputCount = int(readU32Le(payload, pos))
  var inputs = newSeq[FileFingerprint](inputCount)
  for i in 0 ..< inputCount:
    inputs[i].path = readString(payload, pos)
    let policy = readByte(payload, pos)
    if policy > byte(ord(ffpHybrid)):
      raiseEnvelopeError(eeMalformed, "invalid hot index input policy")
    inputs[i].policy = FileFingerprintPolicy(policy)
    inputs[i].metadata = readMetadata(payload, pos)
    inputs[i].hasLocalHash = false
  let recordCount = int(readU32Le(payload, pos))
  for _ in 0 ..< recordCount:
    var record: ActionResultRecord
    record.weakFingerprint = readDigest(payload, pos)
    let policy = readByte(payload, pos)
    if policy > byte(ord(ffpHybrid)):
      raiseEnvelopeError(eeMalformed, "invalid hot index record policy")
    record.policy = FileFingerprintPolicy(policy)
    let recordInputCount = int(readU32Le(payload, pos))
    record.inputs = newSeq[FileFingerprint](recordInputCount)
    for i in 0 ..< recordInputCount:
      let inputId = int(readU32Le(payload, pos))
      if inputId < 0 or inputId >= inputs.len:
        raiseEnvelopeError(eeMalformed, "invalid hot index input reference")
      record.inputs[i] = inputs[inputId]
    result.records[digestKey(record.weakFingerprint)] = record
  result.inputs = inputs
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action hot index bytes")

proc writeHotIndex(cache: ActionCache) =
  writeFile(cache.hotIndexPath, byteString(encodeHotIndex(cache.hotByWeak)))

proc sourceNewerThanIndex(sourcePath, indexPath: string): bool =
  if not fileExists(sourcePath):
    return false
  if not fileExists(indexPath):
    return true
  getLastModificationTime(sourcePath) > getLastModificationTime(indexPath)

proc loadHotRecords(cache: var ActionCache) =
  cache.hotByWeak.clear()
  if fileExists(cache.hotIndexPath) and
      not sourceNewerThanIndex(cache.hotRecordsPath, cache.hotIndexPath):
    try:
      let decoded = decodeHotIndex(bytes(readFile(cache.hotIndexPath)))
      cache.hotByWeak = decoded.records
      cache.hotInputs = decoded.inputs
      return
    except EnvelopeError:
      cache.hotByWeak.clear()
      cache.hotInputs.setLen(0)
  if not fileExists(cache.hotRecordsPath):
    return
  let raw = bytes(readFile(cache.hotRecordsPath))
  var pos = 0
  while pos + 8 <= raw.len:
    let length = int(readU32Le(raw, pos))
    if length < 0 or pos + length + 4 > raw.len:
      break
    let payloadStart = pos
    let payloadEnd = pos + length - 1
    let payload = raw[payloadStart .. payloadEnd]
    pos += length
    let tail = readU32Le(raw, pos)
    if tail != recordTail(payload):
      break
    try:
      let record = decodeHotRecord(payload)
      cache.hotByWeak[digestKey(record.weakFingerprint)] = record
    except EnvelopeError:
      discard
  if getFileSize(cache.hotRecordsPath) >= ActionCacheCompactThreshold:
    cache.rebuildHotInputs()
    cache.writeHotIndex()
    cache.hotIndexDirty = false
  else:
    cache.rebuildHotInputs()

proc readHotRecord(cache: ActionCache; weak: ContentDigest):
    tuple[found: bool; record: ActionResultRecord] =
  let key = digestKey(weak)
  if cache.hotByWeak.hasKey(key):
    return (found: true, record: cache.hotByWeak[key])
  let path = cache.hotRecordPath(weak)
  if not fileExists(path):
    return
  try:
    result.record = decodeHotRecord(bytes(readFile(path)))
    if result.record.weakFingerprint == weak:
      result.found = true
  except EnvelopeError:
    discard

proc appendRecord(cache: var ActionCache; record: ActionResultRecord) =
  let payload = encodeRecord(record)
  var frame: seq[byte] = @[]
  frame.writeU32Le(uint32(payload.len))
  frame.add(payload)
  frame.writeU32Le(recordTail(payload))
  var handle = open(cache.recordsPath, fmAppend)
  try:
    handle.write(byteString(frame))
  finally:
    handle.close()
  let key = digestKey(record.weakFingerprint)
  var records = cache.byWeak.mgetOrPut(key, @[])
  records.add(record)
  if records.len > MaxRecordsPerWeakFingerprint:
    records = records[records.len - MaxRecordsPerWeakFingerprint .. ^1]
  cache.byWeak[key] = records
  cache.appendHotRecord(record)

proc loadRecords(cache: var ActionCache) =
  cache.byWeak.clear()
  cache.loadedAllRecords = true
  if not fileExists(cache.recordsPath):
    return
  let raw = bytes(readFile(cache.recordsPath))
  var pos = 0
  while pos + 8 <= raw.len:
    let length = int(readU32Le(raw, pos))
    if length < 0 or pos + length + 4 > raw.len:
      break
    let payloadStart = pos
    let payloadEnd = pos + length - 1
    let payload = raw[payloadStart .. payloadEnd]
    pos += length
    let tail = readU32Le(raw, pos)
    if tail != recordTail(payload):
      break
    try:
      let record = decodeRecord(payload)
      let key = digestKey(record.weakFingerprint)
      cache.byWeak.mgetOrPut(key, @[]).add(record)
    except EnvelopeError:
      discard

proc compactLoadedRecords(cache: var ActionCache) =
  var frameBytes: seq[byte] = @[]
  for key in cache.byWeak.keys:
    var records = cache.byWeak[key]
    if records.len > MaxRecordsPerWeakFingerprint:
      records = records[records.len - MaxRecordsPerWeakFingerprint .. ^1]
      cache.byWeak[key] = records
    for record in records:
      let payload = encodeRecord(record)
      frameBytes.writeU32Le(uint32(payload.len))
      frameBytes.add(payload)
      frameBytes.writeU32Le(recordTail(payload))
    if records.len > 0:
      cache.hotByWeak[digestKey(records[^1].weakFingerprint)] =
        hotMetadataRecord(records[^1])
  writeFile(cache.recordsPath, byteString(frameBytes))
  cache.writeHotIndex()

proc maybeCompactRecords(cache: var ActionCache) =
  if not fileExists(cache.recordsPath):
    return
  if getFileSize(cache.recordsPath) < ActionCacheCompactThreshold:
    return
  compactLoadedRecords(cache)

proc openActionCache*(root: string): ActionCache =
  result.root = root
  result.recordsPath = root / "action-results.records"
  result.hotRoot = root / "hot-records"
  result.hotRecordsPath = root / "action-results.hot.records"
  result.hotIndexPath = root / "action-results.hot.index"
  result.loadedAllRecords = false
  result.hotIndexDirty = false
  result.byWeak = initTable[string, seq[ActionResultRecord]]()
  result.hotByWeak = initTable[string, ActionResultRecord]()
  result.hotInputs = @[]
  createDir(result.root)
  createDir(result.hotRoot)
  if not fileExists(result.recordsPath):
    writeFile(result.recordsPath, "")
  if not fileExists(result.hotRecordsPath):
    writeFile(result.hotRecordsPath, "")
  result.loadHotRecords()

proc flushHotIndex*(cache: var ActionCache) =
  if not cache.hotIndexDirty:
    return
  cache.rebuildHotInputs()
  cache.writeHotIndex()
  cache.hotIndexDirty = false

proc lookupHotMetadataRecord*(cache: ActionCache; weak: ContentDigest;
                              policy: FileFingerprintPolicy):
    Option[ActionResultRecord] =
  if policy notin {ffpTimestamp, ffpHybrid}:
    return none(ActionResultRecord)
  let key = digestKey(weak)
  if not cache.hotByWeak.hasKey(key):
    return none(ActionResultRecord)
  let record = cache.hotByWeak[key]
  if record.policy != policy:
    return none(ActionResultRecord)
  some(record)

proc hotMetadataInputsUnchanged*(cache: ActionCache;
                                 metadataCache: ptr FileMetadataCache = nil): bool =
  for input in cache.hotInputs:
    if fingerprintMetadata(input.path, metadataCache) != input.metadata:
      return false
  true

proc hotMetadataRecordCount*(cache: ActionCache): int =
  cache.hotByWeak.len

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

proc ensureLoadedRecords(cache: var ActionCache) =
  if cache.loadedAllRecords:
    return
  cache.loadRecords()
  cache.maybeCompactRecords()

proc recordActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         inputPaths, outputPaths: openArray[string];
                         outputRoot = ""): ActionResultRecord =
  result.weakFingerprint = weak
  result.policy = policy
  for path in inputPaths:
    result.inputs.add(observeFile(path, policy))
  result.strongFingerprint = computeStrongFingerprint(weak, result.inputs)
  for path in outputPaths:
    let source = materialPath(outputRoot, path)
    let sourceMetadata = fingerprintMetadata(source)
    # Windows: getFilePermissions returns a synthetic POSIX set derived from
    # the read-only attribute; we don't preserve it (see writePermissions),
    # so emit an empty set here. The cache record still round-trips cleanly.
    when defined(windows):
      let perms: set[FilePermission] = {}
    else:
      let perms = getFilePermissions(source)
    let blob =
      if sourceMetadata.kind == ffkRegular and isDirectRegularFile(source):
        cas.storeFileBlob(source, sourceMetadata.sizeBytes)
      else:
        cas.storeBlob(bytes(readFile(source)))
    result.outputs.add(OutputBlob(path: path, blob: blob, permissions: perms))
  cache.appendRecord(result)

proc refreshedInputs(record: ActionResultRecord; changed: var bool;
                     hybridCutoff: var bool;
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
        return
      if not result.reusedRecordedInputs:
        result.inputs[i] = recorded
    of ffpChecksum:
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if (not recorded.hasLocalHash) or (not current.hasLocalHash) or
          current.localHash != recorded.localHash:
        changed = true
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
        return
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if not current.hasLocalHash:
        changed = true
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
        return

proc verifyOutputs(cas: LocalCas; record: ActionResultRecord) =
  for output in record.outputs:
    cas.verifyBlob(output.blob)

proc lookupActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy;
                         verifyOutputBlobs = true;
                         allowMetadataOnlyHit = false;
                         metadataCache: ptr FileMetadataCache = nil): ActionCacheLookup =
  let key = digestKey(weak)
  if allowMetadataOnlyHit and not verifyOutputBlobs and policy in {ffpTimestamp, ffpHybrid}:
    let hot = cache.readHotRecord(weak)
    if hot.found and hot.record.policy == policy:
      var changed = false
      for input in hot.record.inputs:
        if fingerprintMetadata(input.path, metadataCache) != input.metadata:
          changed = true
          break
      if not changed:
        return ActionCacheLookup(status: aclHit, record: hot.record)

  cache.ensureLoadedRecords()
  if not cache.byWeak.hasKey(key):
    return ActionCacheLookup(status: aclMissNoRecord)
  var sawInputChange = false
  let records = cache.byWeak[key]
  for i in countdown(records.high, 0):
    let record = records[i]
    if record.policy != policy:
      continue
    var changed = false
    var hybridCutoff = false
    let refreshed = refreshedInputs(record, changed, hybridCutoff,
      metadataCache)
    if changed:
      sawInputChange = true
      continue
    var candidate = record
    if not refreshed.reusedRecordedInputs:
      candidate.inputs = refreshed.inputs
      candidate.strongFingerprint = computeStrongFingerprint(weak,
        candidate.inputs)
      if candidate.strongFingerprint != record.strongFingerprint:
        sawInputChange = true
        continue
    if verifyOutputBlobs:
      try:
        cas.verifyOutputs(candidate)
      except CacheIntegrityError as err:
        return ActionCacheLookup(status: aclRejectedCorruptOutput,
          record: candidate, message: err.msg)
    if hybridCutoff:
      cache.appendRecord(candidate)
      return ActionCacheLookup(status: aclHybridCutoff, record: candidate)
    return ActionCacheLookup(status: aclHit, record: candidate)
  if sawInputChange:
    ActionCacheLookup(status: aclMissInputChanged)
  else:
    ActionCacheLookup(status: aclMissNoRecord)
