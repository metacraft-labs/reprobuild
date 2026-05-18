import std/[os, tables, times]

import repro_core
import repro_hash

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
    byWeak: Table[string, seq[ActionResultRecord]]

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

const
  ActionRecordMagic = "RBAR"
  ActionRecordVersion = 1'u16
  RecordTailMask = 0xffff_ffff'u64

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

proc fingerprintMetadata(path: string): FileMetadata =
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

proc fileBytesForHash(path: string; metadata: FileMetadata): seq[byte] =
  if metadata.kind != ffkRegular:
    return @[]
  bytes(readFile(path))

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
    if fileExists(destination):
      removeFile(destination)
    moveFile(tmpPath, destination)

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
  if pos != payload.len:
    raiseEnvelopeError(eeMalformed, "trailing action record bytes")

proc writeActionResultRecordFile*(path: string; record: ActionResultRecord) =
  createDir(parentDir(path))
  writeFile(path, byteString(encodeRecord(record)))

proc recordTail(payload: openArray[byte]): uint32 =
  uint32(localHash(payload).value and RecordTailMask)

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
  cache.byWeak.mgetOrPut(key, @[]).add(record)

proc loadRecords(cache: var ActionCache) =
  cache.byWeak.clear()
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

proc openActionCache*(root: string): ActionCache =
  result.root = root
  result.recordsPath = root / "action-results.records"
  createDir(result.root)
  if not fileExists(result.recordsPath):
    writeFile(result.recordsPath, "")
  result.loadRecords()

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
    let data = bytes(readFile(source))
    result.outputs.add(OutputBlob(path: path, blob: cas.storeBlob(data)))
  cache.appendRecord(result)

proc refreshedInputs(record: ActionResultRecord;
                     changed: var bool; hybridCutoff: var bool): seq[FileFingerprint] =
  result = newSeq[FileFingerprint](record.inputs.len)
  for i, recorded in record.inputs:
    let currentMetadata = fingerprintMetadata(recorded.path)
    case recorded.policy
    of ffpTimestamp:
      if currentMetadata != recorded.metadata:
        changed = true
        return
      result[i] = recorded
    of ffpChecksum:
      let current = observeFileWithMetadata(recorded.path, recorded.policy,
        currentMetadata)
      if (not recorded.hasLocalHash) or (not current.hasLocalHash) or
          current.localHash != recorded.localHash:
        changed = true
        return
      result[i] = recorded
    of ffpHybrid:
      if currentMetadata == recorded.metadata:
        result[i] = recorded
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
        result[i] = current
        hybridCutoff = true
      else:
        changed = true
        return

proc verifyOutputs(cas: LocalCas; record: ActionResultRecord) =
  for output in record.outputs:
    cas.verifyBlob(output.blob)

proc lookupActionResult*(cache: var ActionCache; cas: LocalCas;
                         weak: ContentDigest; policy: FileFingerprintPolicy): ActionCacheLookup =
  let key = digestKey(weak)
  if not cache.byWeak.hasKey(key):
    return ActionCacheLookup(status: aclMissNoRecord)
  var sawInputChange = false
  for record in cache.byWeak[key]:
    if record.policy != policy:
      continue
    var changed = false
    var hybridCutoff = false
    let inputs = refreshedInputs(record, changed, hybridCutoff)
    if changed:
      sawInputChange = true
      continue
    var candidate = record
    candidate.inputs = inputs
    candidate.strongFingerprint = computeStrongFingerprint(weak, candidate.inputs)
    if candidate.strongFingerprint != record.strongFingerprint:
      sawInputChange = true
      continue
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
