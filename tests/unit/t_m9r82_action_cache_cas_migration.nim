import std/[os, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_cas_store
import repro_core
import repro_hash
import repro_local_store

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.m9r82." & name), hdActionFingerprint)

proc writeFixture(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc r11Hash(blob: CasBlobRef): ContentHash =
  toContentHash(blob.digest.bytes)

proc r11Path(cas: CasStore; blob: CasBlobRef): string =
  cas.casPath(blob.r11Hash())

suite "M9.R.82 action-cache R11 CAS migration":
  test "engine restore path routes through R11 materialization helper":
    let engineSource = readFile(
      "libs/repro_build_engine/src/repro_build_engine.nim")
    check not engineSource.contains(".restoreOutputs(")
    check engineSource.contains("materializeActionCacheOutputs")
    check engineSource.contains(".casMaterialize(")

  test "Store file blob recording streams through R11 CAS":
    let storeSource = readFile(
      "libs/repro_local_store/src/repro_local_store.nim")
    let marker = "proc storeFileBlob*(cas: var Store; path: string; sizeBytes: uint64): CasBlobRef ="
    let start = storeSource.find(marker)
    check start >= 0
    if start >= 0:
      let nextProc = storeSource.find("\nproc ", start + marker.len)
      let body =
        if nextProc >= 0: storeSource[start ..< nextProc]
        else: storeSource[start .. ^1]
      check body.contains("storeCasFileBlob(path, sizeBytes)")
      check body.contains("r11CasDigest")
      check not body.contains("readFile")
      check not body.contains("storeBlob(payload)")

  test "record writes R11 CAS layout and cache hit restores through helper":
    let tempRoot = createTempDir("repro-m9r82-r11-restore-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "cached alpha\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("r11-restore"),
      ffpChecksum, [inputPath], ["out.txt"], actionRoot)

    let blobHex = $record.outputs[0].blob.r11Hash()
    let r11Object = sharedRoot / "cas" / "blake3" / blobHex[0 .. 1] / blobHex
    let legacyObject = sharedRoot / "cas" / blobHex[0 .. 1] / blobHex[2 .. ^1]
    check cas.r11Path(record.outputs[0].blob) == r11Object
    check fileExists(r11Object)
    check not fileExists(legacyObject)

    removeIfExists(outputPath)
    var reloaded = openActionCache(sharedRoot / "action-cache")
    let hit = reloaded.lookupActionResult(cas.inner, weakFor("r11-restore"),
      ffpChecksum)
    check hit.status == aclHit
    cas.materializeActionCacheOutputs(hit.record, actionRoot)
    check readFile(outputPath) == "cached alpha\n"

  test "directory outputs round-trip through R11 CAS":
    let tempRoot = createTempDir("repro-m9r82-r11-directory-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputDir = actionRoot / "tree"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputDir / "nested" / "payload.txt", "cached tree\n")
    createDir(outputDir / "empty")
    when defined(posix):
      createSymlink("nested/payload.txt", outputDir / "payload-link")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner,
      weakFor("r11-directory"), ffpChecksum, [inputPath], ["tree"],
      actionRoot)
    require record.outputs.len == 1
    check record.outputs[0].metadata.kind == ffkDirectory
    let snapshot = cas.casGet(record.outputs[0].blob.r11Hash())
    check snapshot.len >= 4
    check snapshot[0 .. 3] == @[byte('R'), byte('B'), byte('D'), byte('T')]

    removeDir(outputDir)
    var reloaded = openActionCache(sharedRoot / "action-cache")
    let hit = reloaded.lookupActionResult(cas.inner,
      weakFor("r11-directory"), ffpChecksum)
    check hit.status == aclHit
    cas.materializeActionCacheOutputs(hit.record, actionRoot)
    check readFile(outputDir / "nested" / "payload.txt") == "cached tree\n"
    check dirExists(outputDir / "empty")
    when defined(posix):
      check symlinkExists(outputDir / "payload-link")
      check expandSymlink(outputDir / "payload-link") == "nested/payload.txt"

    writeFile(outputDir / "stale.txt", "must be replaced\n")
    cas.materializeActionCacheOutputs(hit.record, actionRoot)
    check not fileExists(outputDir / "stale.txt")
    check readFile(outputDir / "nested" / "payload.txt") == "cached tree\n"

  test "legacy LocalCas records reject cleanly under R11 verifier":
    let tempRoot = createTempDir("repro-m9r82-legacy-reject-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "legacy cached alpha\n")

    let legacyCas = openLocalCas(sharedRoot / "cas")
    var cache = openActionCache(sharedRoot / "action-cache")
    discard cache.recordActionResult(legacyCas, weakFor("legacy-record"),
      ffpChecksum, [inputPath], ["out.txt"], actionRoot)
    removeIfExists(outputPath)

    var r11Cas = openCasStore(sharedRoot)
    defer: r11Cas.close()
    let lookup = cache.lookupActionResult(r11Cas.inner, weakFor("legacy-record"),
      ffpChecksum)
    check lookup.status == aclRejectedCorruptOutput
    check not fileExists(outputPath)

  test "hybrid cutoff uses same R11 materialization helper":
    let tempRoot = createTempDir("repro-m9r82-hybrid-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "hybrid cached alpha\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("hybrid-cutoff"),
      ffpHybrid, [inputPath], ["out.txt"], actionRoot)
    let priorMetadata = record.inputs[0].metadata

    removeIfExists(outputPath)
    setLastModificationTime(inputPath,
      getFileInfo(inputPath).lastWriteTime + initDuration(seconds = 10))
    let cutoff = cache.lookupActionResult(cas.inner, weakFor("hybrid-cutoff"),
      ffpHybrid)
    check cutoff.status == aclHybridCutoff
    check cutoff.record.inputs[0].metadata != priorMetadata
    cas.materializeActionCacheOutputs(cutoff.record, actionRoot)
    check readFile(outputPath) == "hybrid cached alpha\n"

  test "corrupt later R11 blob rejects without partial output restore":
    let tempRoot = createTempDir("repro-m9r82-fail-closed-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputA = actionRoot / "a.txt"
    let outputB = actionRoot / "b.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputA, "cached a\n")
    writeFixture(outputB, "cached b\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("corrupt-later"),
      ffpChecksum, [inputPath], ["a.txt", "b.txt"], actionRoot)
    writeFile(cas.r11Path(record.outputs[1].blob), "corrupted later blob\n")
    removeIfExists(outputA)
    removeIfExists(outputB)

    let lookup = cache.lookupActionResult(cas.inner, weakFor("corrupt-later"),
      ffpChecksum)
    check lookup.status == aclRejectedCorruptOutput

    var raised = false
    try:
      cas.materializeActionCacheOutputs(record, actionRoot)
    except ECasDigestMismatch:
      raised = true
    check raised
    check not fileExists(outputA)
    check not fileExists(outputB)

  test "metadata-only records remain non-restorable payload hits":
    let tempRoot = createTempDir("repro-m9r82-metadata-only-", "")
    defer:
      try: removeDir(extendedPath(tempRoot)) except OSError: discard

    let sharedRoot = tempRoot / ".repro"
    let actionRoot = tempRoot / "work"
    let inputPath = actionRoot / "input.txt"
    let outputPath = actionRoot / "out.txt"
    writeFixture(inputPath, "alpha\n")
    writeFixture(outputPath, "metadata only\n")

    var cas = openCasStore(sharedRoot)
    defer: cas.close()
    var cache = openActionCache(sharedRoot / "action-cache")
    let record = cache.recordActionResult(cas.inner, weakFor("metadata-only"),
      ffpHybrid, [inputPath], ["out.txt"], actionRoot,
      storeOutputBlobs = false)
    check record.outputPayloadKind == opkMetadataOnly

    let metadataHit = cache.lookupActionResult(cas.inner,
      weakFor("metadata-only"), ffpHybrid, verifyOutputBlobs = false)
    check metadataHit.status == aclHit

    removeIfExists(outputPath)
    let restoreLookup = cache.lookupActionResult(cas.inner,
      weakFor("metadata-only"), ffpHybrid)
    check restoreLookup.status == aclMissNoOutputPayload
    expect CacheIntegrityError:
      cas.materializeActionCacheOutputs(record, actionRoot)
    check not fileExists(outputPath)
