## Local-only activation bundle writer/reader (M71 Phase A).
##
## The bundle is a deterministic binary envelope stored as one CAS blob
## in the source local store. It represents an already-realized local
## generation and carries the pointer envelope, pointer-referenced CAS
## artifacts, additional activation-time CAS blobs, and complete
## realized-prefix file closures.

import std/[algorithm, os, strutils, tables]
from repro_core/paths import extendedPath

import blake3
import repro_core
import repro_local_store

import ./errors
import ./manifest
import ./pointer
import ./state_dir

const
  ActivationBundleMagic* = "RBAB"
  ActivationBundleSchemaVersionV1*: uint16 = 1
  ActivationBundleSchemaVersionV2*: uint16 = 2
  ActivationBundleSchemaVersion*: uint16 = ActivationBundleSchemaVersionV2
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

  ActivationBundleCasBlobEntry* = object
    digest*: Digest256
    contentBytes*: seq[byte]

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
    casBlobs*: seq[ActivationBundleCasBlobEntry]
    prefixes*: seq[ActivationBundlePrefixClosure]

  ActivationBundleWriteResult* = object
    generationIdHex*: string
    bundleDigest*: PrefixIdBytes
    bundleDigestHex*: string
    bundlePath*: string
    bundleBytes*: seq[byte]

  ActivationBundleImportResult* = object
    bundleDigest*: PrefixIdBytes
    bundleDigestHex*: string
    targetBundlePath*: string
    bundleAlreadyPresent*: bool
    prefixesImported*: int
    prefixesAlreadyPresent*: int
    bytesReceived*: int

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

proc activationDigestHex(digest: Digest256): string =
  prefixIdHex(toPrefixId(digest))

proc parseBundleHexNibble(c: char): int =
  case c
  of '0' .. '9': int(ord(c) - ord('0'))
  of 'a' .. 'f': int(ord(c) - ord('a') + 10)
  of 'A' .. 'F': int(ord(c) - ord('A') + 10)
  else:
    raise newException(ValueError, "not a hex nibble: " & $c)

proc parsePrefixIdHex*(hex: string): PrefixIdBytes =
  ## Parse a 64-character BLAKE3-256 hex digest for activation-bundle
  ## transfer/import CLI plumbing.
  if hex.len != DigestSize * 2:
    raise newException(ValueError,
      "expected " & $(DigestSize * 2) & " hex chars, got " & $hex.len)
  for i in 0 ..< DigestSize:
    let high = parseBundleHexNibble(hex[2 * i])
    let low = parseBundleHexNibble(hex[2 * i + 1])
    result[i] = byte((high shl 4) or low)

proc bytesFromFile(path: string): seq[byte] =
  let raw = readFile(extendedPath(path))
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc normalizeRelPath(path: string): string =
  result = path
  for i in 0 ..< result.len:
    if result[i] == '\\':
      result[i] = '/'

proc isSafeStoreRelativePath(path: string): bool =
  if path.len == 0 or path.startsWith("/") or path.startsWith("\\"):
    return false
  let normalized = normalizeRelPath(path)
  if normalized != path:
    return false
  for part in normalized.split('/'):
    if part.len == 0 or part == "." or part == "..":
      return false
  true

proc requireSafeBundlePath(filePath, field, path: string) =
  if not isSafeStoreRelativePath(path):
    raiseActivationBundleCorrupt(filePath, field,
      "unsafe relative path in activation bundle: " & path)

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
  result.writeU32Le(uint32(bundle.casBlobs.len))
  for blob in bundle.casBlobs:
    result.writeDigest(blob.digest)
    result.writeBlob(blob.contentBytes)
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
  if version != ActivationBundleSchemaVersionV1 and
     version != ActivationBundleSchemaVersionV2:
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
  if version >= ActivationBundleSchemaVersionV2:
    if pos + 4 > bodyEnd:
      raiseActivationBundleCorrupt(filePath, "casBlobs", "truncated count")
    let blobCount = int(readU32Le(bytes, pos))
    result.casBlobs = newSeq[ActivationBundleCasBlobEntry](blobCount)
    var previous = ""
    for i in 0 ..< blobCount:
      var blob: ActivationBundleCasBlobEntry
      blob.digest = readDigest(bytes, pos, bodyEnd, filePath,
        "casBlobs[" & $i & "].digest")
      blob.contentBytes = readBlob(bytes, pos, bodyEnd, filePath,
        "casBlobs[" & $i & "].contentBytes")
      let actual = blake3.digest(blob.contentBytes)
      if actual != blob.digest:
        raiseActivationBundleCorrupt(filePath,
          "casBlobs[" & $i & "].digest",
          "CAS blob content digest mismatch")
      let key = activationDigestHex(blob.digest)
      if previous.len > 0 and key <= previous:
        raiseActivationBundleCorrupt(filePath,
          "casBlobs[" & $i & "].digest",
          "CAS blob list is not strictly sorted by digest")
      previous = key
      result.casBlobs[i] = blob
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

proc collectActivationCasBlobs(store: Store;
                               manifest: ActivationManifest):
    seq[ActivationBundleCasBlobEntry] =
  var seen = initTable[string, bool]()
  var blobs: seq[ActivationBundleCasBlobEntry]

  proc addDigest(digest: Digest256) =
    let key = activationDigestHex(digest)
    if key in seen:
      return
    seen[key] = true
    blobs.add(ActivationBundleCasBlobEntry(
      digest: digest,
      contentBytes: store.readCasBlob(toPrefixId(digest))))

  for command in manifest.exportedCommands:
    addDigest(command.launchPlanDigest)
  for generated in manifest.generatedFiles:
    addDigest(generated.storeContentHash)

  blobs.sort(proc(a, b: ActivationBundleCasBlobEntry): int =
    cmp(activationDigestHex(a.digest), activationDigestHex(b.digest)))
  blobs

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
  let manifest = decodeManifestBytes(result.activationManifestBytes)
  result.casBlobs = collectActivationCasBlobs(store, manifest)
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

proc validateExistingPrefixTree(filePath: string; store: Store;
                                closure: ActivationBundlePrefixClosure;
                                absolutePrefix: string;
                                receiptDigest: PrefixIdBytes): bool =
  if not dirExists(extendedPath(absolutePrefix)):
    return false
  let receiptPath = absolutePrefix / ReceiptFileName
  if not fileExists(extendedPath(receiptPath)):
    raiseActivationBundleCorrupt(filePath, "prefix.existingReceipt",
      "existing prefix is missing " & ReceiptFileName & ": " & absolutePrefix)
  let existingReceipt = bytesFromFile(receiptPath)
  if blake3.digest(existingReceipt) != receiptDigest:
    raiseActivationBundleCorrupt(filePath, "prefix.existingReceipt",
      "existing prefix receipt digest mismatch: " & absolutePrefix)
  if existingReceipt != closure.receiptBytes:
    raiseActivationBundleCorrupt(filePath, "prefix.existingReceipt",
      "existing prefix receipt bytes differ: " & absolutePrefix)

  var expected = initTable[string, Digest256]()
  for entry in closure.files:
    expected[entry.relativePath] = entry.contentDigest

  var seen = initTable[string, bool]()
  for rel in walkDirRec(extendedPath(absolutePrefix),
      yieldFilter = {pcFile, pcLinkToFile}, relative = true):
    let normalized = normalizeRelPath(rel)
    if normalized notin expected:
      raiseActivationBundleCorrupt(filePath, "prefix.existingFiles",
        "existing prefix contains unexpected file: " & normalized)
    let content = bytesFromFile(absolutePrefix / rel)
    if blake3.digest(content) != expected[normalized]:
      raiseActivationBundleCorrupt(filePath, "prefix.existingFiles",
        "existing prefix file digest mismatch: " & normalized)
    seen[normalized] = true

  for entry in closure.files:
    if entry.relativePath notin seen:
      raiseActivationBundleCorrupt(filePath, "prefix.existingFiles",
        "existing prefix is missing file: " & entry.relativePath)
  true

proc materializeImportedPrefix(filePath: string; store: var Store;
                               closure: ActivationBundlePrefixClosure;
                               receipt: RealizationReceipt;
                               receiptDigest: PrefixIdBytes) =
  let finalPath = store.absolutePrefixPath(closure.storeRelativePath)
  if dirExists(extendedPath(finalPath)):
    if validateExistingPrefixTree(filePath, store, closure, finalPath,
        receiptDigest):
      discard store.insertPrefixOrIgnore(PrefixRow(
        prefixId: closure.prefixId,
        packageName: receipt.packageName,
        version: receipt.version,
        realizedPath: closure.storeRelativePath,
        adapter: receipt.adapter,
        receiptDigest: receiptDigest,
        createdAtUnix: receipt.createdAtUnix))
      return

  let stage = store.allocateStagingDir()
  try:
    for entry in closure.files:
      requireSafeBundlePath(filePath, "prefix.files.relativePath",
        entry.relativePath)
      let target = stage / entry.relativePath.replace('/', DirSep)
      createDir(extendedPath(parentDir(target)))
      writeFile(extendedPath(target), bytesToString(entry.contentBytes))
    let stagedReceipt = stage / ReceiptFileName
    if not fileExists(extendedPath(stagedReceipt)):
      raiseActivationBundleCorrupt(filePath, "prefix.receipt",
        "bundle did not materialize " & ReceiptFileName)
    if bytesFromFile(stagedReceipt) != closure.receiptBytes:
      raiseActivationBundleCorrupt(filePath, "prefix.receipt",
        "materialized receipt bytes differ from bundle receipt bytes")

    createDir(extendedPath(parentDir(finalPath)))
    try:
      moveDir(extendedPath(stage), extendedPath(finalPath))
    except OSError:
      if dirExists(extendedPath(stage)):
        try: removeDir(extendedPath(stage)) except OSError: discard
      if not dirExists(extendedPath(finalPath)):
        raise
      if not validateExistingPrefixTree(filePath, store, closure, finalPath,
          receiptDigest):
        raiseActivationBundleCorrupt(filePath, "prefix.publish",
          "prefix publish lost race to a non-matching directory")

    discard store.insertPrefixOrIgnore(PrefixRow(
      prefixId: closure.prefixId,
      packageName: receipt.packageName,
      version: receipt.version,
      realizedPath: closure.storeRelativePath,
      adapter: receipt.adapter,
      receiptDigest: receiptDigest,
      createdAtUnix: receipt.createdAtUnix))
  except CatchableError:
    if dirExists(extendedPath(stage)):
      try: removeDir(extendedPath(stage)) except OSError: discard
    raise

proc importActivationBundleBytes*(store: var Store; bytes: openArray[byte];
                                  expectedDigestHex = "";
                                  filePath = "<memory>"):
    ActivationBundleImportResult =
  ## Target-side Phase C receive/import primitive. It validates the
  ## RBAB envelope and per-file digests, stores the complete bundle as
  ## a target CAS object, then imports each realized prefix closure
  ## under `prefixes/...` without registering roots or touching any
  ## generation pointer.
  result.bytesReceived = bytes.len
  let actualDigest = toPrefixId(blake3.digest(bytes))
  result.bundleDigest = actualDigest
  result.bundleDigestHex = prefixIdHex(actualDigest)
  if expectedDigestHex.len > 0:
    let expected = parsePrefixIdHex(expectedDigestHex)
    if expected != actualDigest:
      raiseActivationBundleCorrupt(filePath, "bundleDigest",
        "received bundle digest " & result.bundleDigestHex &
        " does not match expected " & expectedDigestHex)

  let bundle = decodeActivationBundleBytes(bytes, filePath)
  result.targetBundlePath = store.casPath(result.bundleDigest)
  result.bundleAlreadyPresent = fileExists(extendedPath(result.targetBundlePath))
  discard store.storeCasBlob(bytes)
  store.verifyCasBlob(result.bundleDigest)

  for i, blob in bundle.casBlobs:
    let key = toPrefixId(blob.digest)
    let stored = store.storeCasBlob(blob.contentBytes)
    if stored != key:
      raiseActivationBundleCorrupt(filePath,
        "casBlobs[" & $i & "].digest",
        "stored CAS blob digest did not match bundle digest")
    store.verifyCasBlob(key)

  for i, closure in bundle.prefixes:
    requireSafeBundlePath(filePath, "prefixes[" & $i & "].storeRelativePath",
      closure.storeRelativePath)
    if not closure.storeRelativePath.startsWith("prefixes/"):
      raiseActivationBundleCorrupt(filePath,
        "prefixes[" & $i & "].storeRelativePath",
        "prefix path must live under prefixes/")
    let receipt = decodeReceipt(closure.receiptBytes)
    if receipt.realizationHash != closure.prefixId:
      raiseActivationBundleCorrupt(filePath,
        "prefixes[" & $i & "].receipt.realizationHash",
        "receipt realization hash does not match closure prefix id")
    if normalizeRelPath(receipt.realizedPath) != closure.storeRelativePath:
      raiseActivationBundleCorrupt(filePath,
        "prefixes[" & $i & "].receipt.realizedPath",
        "receipt path does not match bundle prefix path")
    let canonicalPath = prefixRelativePath(receipt.packageName,
      receipt.version, closure.prefixId)
    if canonicalPath != closure.storeRelativePath:
      raiseActivationBundleCorrupt(filePath,
        "prefixes[" & $i & "].storeRelativePath",
        "bundle prefix path is not canonical for receipt metadata")
    let rd = blake3.digest(closure.receiptBytes)
    var sawReceipt = false
    for j, entry in closure.files:
      requireSafeBundlePath(filePath,
        "prefixes[" & $i & "].files[" & $j & "].relativePath",
        entry.relativePath)
      if entry.relativePath == ReceiptFileName:
        sawReceipt = true
        if entry.contentBytes != closure.receiptBytes:
          raiseActivationBundleCorrupt(filePath,
            "prefixes[" & $i & "].files[" & $j & "]",
            "receipt file entry bytes do not match prefix receipt bytes")
      if blake3.digest(entry.contentBytes) != entry.contentDigest:
        raiseActivationBundleCorrupt(filePath,
          "prefixes[" & $i & "].files[" & $j & "].contentDigest",
          "file content digest mismatch")
    if not sawReceipt:
      raiseActivationBundleCorrupt(filePath,
        "prefixes[" & $i & "].files",
        "prefix closure is missing " & ReceiptFileName)

    let lookup = store.lookupPrefix(closure.prefixId)
    let finalPath = store.absolutePrefixPath(closure.storeRelativePath)
    if lookup.found and lookup.row.realizedPath != closure.storeRelativePath:
      raiseActivationBundleCorrupt(filePath,
        "prefixes[" & $i & "].storeRelativePath",
        "target index has same prefix id at a different path")
    if lookup.found and dirExists(extendedPath(finalPath)):
      discard validateExistingPrefixTree(filePath, store, closure, finalPath,
        rd)
      inc result.prefixesAlreadyPresent
    elif dirExists(extendedPath(finalPath)):
      discard validateExistingPrefixTree(filePath, store, closure, finalPath,
        rd)
      discard store.insertPrefixOrIgnore(PrefixRow(
        prefixId: closure.prefixId,
        packageName: receipt.packageName,
        version: receipt.version,
        realizedPath: closure.storeRelativePath,
        adapter: receipt.adapter,
        receiptDigest: rd,
        createdAtUnix: receipt.createdAtUnix))
      inc result.prefixesAlreadyPresent
    else:
      materializeImportedPrefix(filePath, store, closure, receipt, rd)
      inc result.prefixesImported
