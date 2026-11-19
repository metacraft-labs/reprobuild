## The action-output sidecar (Provider-Compile-Tiering.md §"A TryCompile hit
## must replay the probe's output"): the stdout and stderr of the execution
## behind a record, as CAS blobs, kept beside the `.rec` so a hit can print
## what the run printed.
##
## Pinned here: the codec round-trips and refuses -- as `none`, never as a
## guess -- a sidecar for another record, from another version, or torn; the
## streams come back byte for byte, empty ones included, through the CAS;
## a missing or corrupt blob reads as "unknown", not as empty output; and the
## sidecar's blobs belong to its entry for the retention GC.
##
## No mocks: entries are written through the production `recordActionResult`
## into a real `ActionCache` and `LocalCas` on a real temporary directory.

import std/[options, os, strutils, tempfiles, unittest]


import repro_hash
import repro_local_store

proc weakOf(name: string): ContentDigest =
  ## `repro_build_engine.weakFingerprintFromText`'s construction, written out
  ## so this layer does not import the one above it.
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

proc publish(cache: var ActionCache; cas: LocalCas; root, name: string):
    ActionResultRecord =
  let input = root / (name & ".in")
  let output = root / (name & ".out.txt")
  writeFile(input, "input of " & name)
  writeFile(output, "output of " & name)
  cache.recordActionResult(cas, weakOf(name), ffpChecksum, @[input],
    @[output], root, storeOutputBlobs = false)

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc sidecarPaths(cache: ActionCache): seq[string] =
  if not dirExists(cache.hotRecordsRoot):
    return
  for path in walkDirRec(cache.hotRecordsRoot):
    if path.endsWith(ActionOutputFileExt):
      result.add(path)

suite "action-output sidecar":

  test "the codec round-trips and refuses what is not its record's":
    let output = RecordedActionOutput(
      stdout: CasBlobRef(digest: weakOf("stdout"), sizeBytes: 12),
      stderr: CasBlobRef())
    let raw = encodeActionOutput("ab12", output)
    let decoded = decodeActionOutput(raw, "ab12")
    require decoded.isSome
    check decoded.get() == output
    # Another record's sidecar, renamed beside this one.
    check decodeActionOutput(raw, "cd34").isNone
    # Torn, extended, or from another version.
    check decodeActionOutput(raw[0 ..< raw.len - 1], "ab12").isNone
    check decodeActionOutput(raw & @[0'u8], "ab12").isNone
    var future = raw
    # version-literal-ok: 0xff is a far-future version this build never writes, not current + 1
    future[4] = 0xff'u8
    check decodeActionOutput(future, "ab12").isNone

  test "a record's streams come back byte for byte":
    let root = createTempDir("repro-action-output-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let record = cache.publish(cas, root, "compile")
    let stdoutText = "line one\r\nline two\n\x00binary\xff"
    let stderrText = "Using built-in specs.\nCOLLECT_GCC=gcc\n"
    cache.recordActionOutput(cas, record.weakFingerprint,
      record.strongFingerprint, stdoutText, stderrText)
    check cache.sidecarPaths().len == 1
    let replay = cache.recordedActionOutputFor(cas, record.weakFingerprint,
      record.strongFingerprint)
    require replay.isSome
    check replay.get().stdout == stdoutText
    check replay.get().stderr == stderrText

  test "a silent run is recorded as silent, not as unknown":
    let root = createTempDir("repro-action-output-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let record = cache.publish(cas, root, "silent")
    # Before the sidecar is written the output is unknown.
    check cache.recordedActionOutputFor(cas, record.weakFingerprint,
      record.strongFingerprint).isNone
    cache.recordActionOutput(cas, record.weakFingerprint,
      record.strongFingerprint, "", "")
    let replay = cache.recordedActionOutputFor(cas, record.weakFingerprint,
      record.strongFingerprint)
    require replay.isSome
    check replay.get().stdout.len == 0
    check replay.get().stderr.len == 0

  test "a lost or corrupt blob makes the output unknown":
    let root = createTempDir("repro-action-output-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let record = cache.publish(cas, root, "lossy")
    cache.recordActionOutput(cas, record.weakFingerprint,
      record.strongFingerprint, "captured stdout", "")
    let sidecar = cache.sidecarPaths()
    require sidecar.len == 1
    let blob = decodeActionOutput(
      bytesOf(readFile(sidecar[0])),
      digestHex(record.strongFingerprint)).get().stdout
    let blobFile = cas.blobPath(blob.digest)
    require fileExists(blobFile)
    writeFile(blobFile, "tampered stdout")
    check cache.recordedActionOutputFor(cas, record.weakFingerprint,
      record.strongFingerprint).isNone
    removeFile(blobFile)
    check cache.recordedActionOutputFor(cas, record.weakFingerprint,
      record.strongFingerprint).isNone

  test "the retention GC counts the sidecar's blobs as its entry's":
    let root = createTempDir("repro-action-output-", "")
    defer:
      try: removeDir(root)
      except OSError: discard
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let record = cache.publish(cas, root, "gc")
    cache.recordActionOutput(cas, record.weakFingerprint,
      record.strongFingerprint, "out", "err")
    let entries = cache.scanCacheEntries(RetentionGcPolicy())
    require entries.len == 1
    let decoded = decodeActionOutput(
      bytesOf(readFile(cache.sidecarPaths()[0])),
      digestHex(record.strongFingerprint)).get()
    check digestHex(decoded.stdout.digest) in entries[0].blobDigests
    check digestHex(decoded.stderr.digest) in entries[0].blobDigests
    # Removing the entry removes its sidecar with it.
    check removeCacheEntry(entries[0])
    check cache.sidecarPaths().len == 0
