## Local-only activation bundle writer/reader (M71 Phase A).
##
## The bundle is a deterministic binary envelope stored as one CAS blob
## in the source local store. It represents an already-realized local
## generation and carries the pointer envelope, pointer-referenced CAS
## artifacts, and complete realized-prefix file closures.

import std/[algorithm, os]
from repro_core/paths import extendedPath

import blake3
import repro_core
import repro_local_store

import ./errors
import ./pointer
import ./state_dir

const
  ActivationBundleMagic* = "RBAB"
  ActivationBundleSchemaVersion*: uint16 = 1
  BundleHeaderSize = 4 + 2 + 4
  BundleTrailerSize = 32
  ActivationRuntimePlaceholderKind* = "phase-a-placeholder"

type
  ActivationBundleFileEntry* = object
    relativePath*: string
    contentDigest*: Digest256
    contentBytes*: seq[byte]

  ActivationBundlePrefixClosure* = object
    prefixId*: Digest256
    storeRelativePath*: string
    receiptBytes*: seq[byte]
    files*: seq[ActivationBundleFileEntry]

  ActivationBundle* = object
    schemaVersion*: uint16
    sourceGenerationId*: GenerationId
    hostIdentity*: string
    activationTimestamp*: int64
    pointerEnvelopeBytes*: seq[byte]
    activationManifestBytes*: seq[byte]
    intentSnapshotBytes*: seq[byte]
    configurableGraphBytes*: seq[byte]
    activationRuntimeKind*: string
    activationRuntimeBytes*: seq[byte]
    prefixes*: seq[ActivationBundlePrefixClosure]

  ActivationBundleWriteResult* = object
    generationIdHex*: string
    bundleDigest*: PrefixIdBytes
    bundleDigestHex*: string
    bundlePath*: string
    bundleBytes*: seq[byte]

proc writeBytes(outp: var seq[byte]; data: openArray[byte]) =
  for b in data:
    outp.add(b)

proc writeDigest(outp: var seq[byte]; digest: Digest256) =
  for b in digest:
    outp.add(b)

proc writeBlob(outp: var seq[byte]; data: openArray[byte]) =
  outp.writeU64Le(uint64(data.len))
  outp.writeBytes(data)

proc readDigest(buf: openArray[byte]; pos: var int;
                bodyEnd: int; filePath, field: string): Digest256 =
  if pos + DigestSize > bodyEnd:
    raiseActivationBundleCorrupt(filePath, field, "truncated digest")
  for i in 0 ..< DigestSize:
    result[i] = buf[pos + i]
  pos += DigestSize

proc readBlob(buf: openArray[byte]; pos: var int;
              bodyEnd: int; filePath, field: string): seq[byte] =
  if pos + 8 > bodyEnd:
    raiseActivationBundleCorrupt(filePath, field, "truncated blob length")
  let n = int(readU64Le(buf, pos))
  if pos + n > bodyEnd:
    raiseActivationBundleCorrupt(filePath, field,
      "declared blob length overflows body")
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = buf[pos + i]
  pos += n

proc readStringBounded(buf: openArray[byte]; pos: var int;
                       bodyEnd: int; filePath, field: string): string =
  if pos + 4 > bodyEnd:
    raiseActivationBundleCorrupt(filePath, field, "truncated string length")
  let n = int(readU32Le(buf, pos))
  if pos + n > bodyEnd:
    raiseActivationBundleCorrupt(filePath, field,
      "declared string length overflows body")
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(buf[pos + i])
  pos += n

proc toPrefixId(digest: Digest256): PrefixIdBytes =
  for i in 0 ..< DigestSize:
    result[i] = digest[i]

proc bytesFromFile(path: string): seq[byte] =
  let raw = readFile(extendedPath(path))
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc normalizeRelPath(path: string): string =
  result = path
  for i in 0 ..< result.len:
    if result[i] == '\\':
      result[i] = '/'

proc encodeBody(bundle: ActivationBundle): seq[byte] =
  result.writeBytes(bundle.sourceGenerationId)
  result.writeU64Le(uint64(bundle.activationTimestamp))
  result.writeString(bundle.hostIdentity)
  result.writeBlob(bundle.pointerEnvelopeBytes)
  result.writeBlob(bundle.activationManifestBytes)
  result.writeBlob(bundle.intentSnapshotBytes)
  result.writeBlob(bundle.configurableGraphBytes)
  result.writeString(bundle.activationRuntimeKind)
  result.writeBlob(bundle.activationRuntimeBytes)
  result.writeU32Le(uint32(bundle.prefixes.len))
  for prefix in bundle.prefixes:
    result.writeDigest(prefix.prefixId)
    result.writeString(prefix.storeRelativePath)
    result.writeBlob(prefix.receiptBytes)
    result.writeU32Le(uint32(prefix.files.len))
    for entry in prefix.files:
      result.writeString(entry.relativePath)
      result.writeDigest(entry.contentDigest)
      result.writeBlob(entry.contentBytes)

proc encodeActivationBundle*(bundle: ActivationBundle): seq[byte] =
  ## Serialize an activation bundle with the same envelope convention
  ## as pointer/manifest/snapshot artifacts: magic, schema version,
  ## body length, body, trailing BLAKE3-256 checksum.
  let body = encodeBody(bundle)
  result = newSeqOfCap[byte](BundleHeaderSize + body.len + BundleTrailerSize)
  for ch in ActivationBundleMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(ActivationBundleSchemaVersion)
  result.writeU32Le(uint32(body.len))
  result.writeBytes(body)
  let checksum = blake3.digest(result)
  result.writeBytes(checksum)

proc decodeActivationBundleBytes*(bytes: openArray[byte];
                                  filePath = "<memory>"): ActivationBundle =
  ## Strict reader for tests and future target-side ingestion. It
  ## validates magic, schema version, body length, and trailing
  ## checksum before returning decoded fields.
  if bytes.len < BundleHeaderSize + BundleTrailerSize:
    raiseActivationBundleCorrupt(filePath, "envelope",
      "file is too short to be an activation bundle")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(ActivationBundleMagic[i])):
      raiseActivationBundleCorrupt(filePath, "magic",
        "expected '" & ActivationBundleMagic & "' magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != ActivationBundleSchemaVersion:
    raiseActivationBundleCorrupt(filePath, "schemaVersion",
      "unsupported activation-bundle schema version " & $version)
  let bodyLen = int(readU32Le(bytes, pos))
  if pos + bodyLen + BundleTrailerSize != bytes.len:
    raiseActivationBundleCorrupt(filePath, "bodyLength",
      "declared body length disagrees with file size")
  let bodyEnd = pos + bodyLen
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< DigestSize:
    if bytes[bodyEnd + i] != expected[i]:
      raiseActivationBundleCorrupt(filePath, "trailingChecksum",
        "BLAKE3-256 trailing checksum mismatch")

  if pos + GenerationIdSize > bodyEnd:
    raiseActivationBundleCorrupt(filePath, "sourceGenerationId",
      "truncated generation id")
  for i in 0 ..< GenerationIdSize:
    result.sourceGenerationId[i] = bytes[pos + i]
  pos += GenerationIdSize
  result.schemaVersion = version
  if pos + 8 > bodyEnd:
    raiseActivationBundleCorrupt(filePath, "activationTimestamp",
      "truncated timestamp")
  result.activationTimestamp = int64(readU64Le(bytes, pos))
  result.hostIdentity = readStringBounded(bytes, pos, bodyEnd, filePath,
    "hostIdentity")
  result.pointerEnvelopeBytes = readBlob(bytes, pos, bodyEnd, filePath,
    "pointerEnvelopeBytes")
  result.activationManifestBytes = readBlob(bytes, pos, bodyEnd, filePath,
    "activationManifestBytes")
  result.intentSnapshotBytes = readBlob(bytes, pos, bodyEnd, filePath,
    "intentSnapshotBytes")
  result.configurableGraphBytes = readBlob(bytes, pos, bodyEnd, filePath,
    "configurableGraphBytes")
  result.activationRuntimeKind = readStringBounded(bytes, pos, bodyEnd,
    filePath, "activationRuntimeKind")
  result.activationRuntimeBytes = readBlob(bytes, pos, bodyEnd, filePath,
    "activationRuntimeBytes")
  if pos + 4 > bodyEnd:
    raiseActivationBundleCorrupt(filePath, "prefixes", "truncated count")
  let prefixCount = int(readU32Le(bytes, pos))
  result.prefixes = newSeq[ActivationBundlePrefixClosure](prefixCount)
  for i in 0 ..< prefixCount:
    var closure: ActivationBundlePrefixClosure
    closure.prefixId = readDigest(bytes, pos, bodyEnd, filePath,
      "prefixes[" & $i & "].prefixId")
    closure.storeRelativePath = readStringBounded(bytes, pos, bodyEnd,
      filePath, "prefixes[" & $i & "].storeRelativePath")
    closure.receiptBytes = readBlob(bytes, pos, bodyEnd, filePath,
      "prefixes[" & $i & "].receiptBytes")
    if pos + 4 > bodyEnd:
      raiseActivationBundleCorrupt(filePath, "prefixes[" & $i & "].files",
        "truncated file count")
    let fileCount = int(readU32Le(bytes, pos))
    closure.files = newSeq[ActivationBundleFileEntry](fileCount)
    for j in 0 ..< fileCount:
      var entry: ActivationBundleFileEntry
      entry.relativePath = readStringBounded(bytes, pos, bodyEnd, filePath,
        "prefixes[" & $i & "].files[" & $j & "].relativePath")
      entry.contentDigest = readDigest(bytes, pos, bodyEnd, filePath,
        "prefixes[" & $i & "].files[" & $j & "].contentDigest")
      entry.contentBytes = readBlob(bytes, pos, bodyEnd, filePath,
        "prefixes[" & $i & "].files[" & $j & "].contentBytes")
      let actual = blake3.digest(entry.contentBytes)
      if actual != entry.contentDigest:
        raiseActivationBundleCorrupt(filePath,
          "prefixes[" & $i & "].files[" & $j & "].contentDigest",
          "file content digest mismatch")
      closure.files[j] = entry
    result.prefixes[i] = closure
  if pos != bodyEnd:
    raiseActivationBundleCorrupt(filePath, "body",
      "trailing " & $(bodyEnd - pos) & " bytes after declared bundle fields")

proc collectPrefixClosure(store: Store; prefixDigest: Digest256):
    ActivationBundlePrefixClosure =
  let prefixId = toPrefixId(prefixDigest)
  let lookup = store.lookupPrefix(prefixId)
  if not lookup.found:
    raiseActivationBundleCorrupt("<build>", "realizedPrefixIds",
      "prefix " & digestHex(prefixDigest) & " is not present in store index")
  let absPrefix = store.absolutePrefixPath(lookup.row.realizedPath)
  if not dirExists(extendedPath(absPrefix)):
    raiseActivationBundleCorrupt("<build>", "realizedPrefixPath",
      "prefix directory is missing: " & absPrefix)
  let receiptPath = absPrefix / ReceiptFileName
  if not fileExists(extendedPath(receiptPath)):
    raiseActivationBundleCorrupt("<build>", "receipt",
      "prefix receipt is missing: " & receiptPath)
  result.prefixId = prefixDigest
  result.storeRelativePath = normalizeRelPath(lookup.row.realizedPath)
  result.receiptBytes = bytesFromFile(receiptPath)
  discard decodeReceipt(result.receiptBytes)

  var paths: seq[tuple[rel: string; abs: string]]
  for rel in walkDirRec(extendedPath(absPrefix),
      yieldFilter = {pcFile, pcLinkToFile}, relative = true):
    let normalized = normalizeRelPath(rel)
    paths.add((rel: normalized, abs: absPrefix / rel))
  paths.sort(proc(a, b: tuple[rel: string; abs: string]): int =
    cmp(a.rel, b.rel))
  for p in paths:
    let content = bytesFromFile(p.abs)
    result.files.add(ActivationBundleFileEntry(
      relativePath: p.rel,
      contentDigest: blake3.digest(content),
      contentBytes: content))

proc buildActivationBundle*(stateDir: string; store: Store;
                            generationId = "current"): ActivationBundle =
  ## Assemble the deterministic in-memory bundle for an already
  ## realized local generation. `generationId` may be "current" or a
  ## full 32-hex generation id.
  let resolvedId =
    if generationId.len == 0 or generationId == "current":
      readCurrentGenerationId(stateDir)
    else:
      generationId
  if resolvedId.len == 0:
    raiseActivationBundleCorrupt("<build>", "generation",
      "no current generation is recorded")
  discard parseGenerationIdHex(resolvedId)
  let ppath = pointerPath(stateDir, resolvedId)
  if not fileExists(extendedPath(ppath)):
    raiseActivationBundleCorrupt("<build>", "pointer",
      "pointer file is missing: " & ppath)
  let pointerBytes = bytesFromFile(ppath)
  let envelope = decodePointerBytes(pointerBytes, ppath)
  let sourceIdHex = generationIdHex(envelope.generationId)
  if sourceIdHex != resolvedId:
    raiseActivationBundleCorrupt("<build>", "generationId",
      "pointer generation id " & sourceIdHex &
      " does not match requested id " & resolvedId)

  result.schemaVersion = ActivationBundleSchemaVersion
  result.sourceGenerationId = envelope.generationId
  result.hostIdentity = envelope.hostIdentity
  result.activationTimestamp = envelope.activationTimestamp
  result.pointerEnvelopeBytes = pointerBytes
  result.activationManifestBytes = store.readCasBlob(
    toPrefixId(envelope.activationManifestDigest))
  result.intentSnapshotBytes = store.readCasBlob(
    toPrefixId(envelope.intentSnapshotDigest))
  result.configurableGraphBytes = store.readCasBlob(
    toPrefixId(envelope.configurableGraphDigest))
  result.activationRuntimeKind = ActivationRuntimePlaceholderKind
  result.activationRuntimeBytes = @[]
  for prefixDigest in envelope.realizedPrefixIds:
    result.prefixes.add(collectPrefixClosure(store, prefixDigest))

proc writeActivationBundle*(stateDir: string; store: var Store;
                            generationId = "current"):
    ActivationBundleWriteResult =
  ## Encode the local generation bundle and store it as one CAS blob in
  ## the source store. The operation is idempotent because the encoded
  ## bytes are deterministic and `storeCasBlob` is content-addressed.
  let bundle = buildActivationBundle(stateDir, store, generationId)
  let bytes = encodeActivationBundle(bundle)
  let digest = store.storeCasBlob(bytes)
  result.generationIdHex = generationIdHex(bundle.sourceGenerationId)
  result.bundleDigest = digest
  result.bundleDigestHex = prefixIdHex(digest)
  result.bundlePath = store.casPath(digest)
  result.bundleBytes = bytes
