import std/[os, tempfiles, times, unittest]

import repro_hash
import repro_local_store

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.m9.fixture." & name), hdActionFingerprint)

proc runFixtureAction(inputPath, outputPath: string) =
  createDir(outputPath.splitPath.head)
  writeFile(outputPath, "fixture-output\n" & readFile(inputPath))

proc setStableTimestamp(path: string) =
  setLastModificationTime(path, fromUnix(1_700_000_000))

proc rewritePreservingTimestamp(path, content: string) =
  let prior = getFileInfo(path).lastWriteTime
  writeFile(path, content)
  setLastModificationTime(path, prior)

proc readable(path: string): bool =
  try:
    discard readFile(path)
    true
  except CatchableError:
    false

proc setDifferentTimestamp(path: string) =
  let prior = getFileInfo(path).lastWriteTime
  setLastModificationTime(path, prior + initDuration(seconds = 10))

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc readU32Le(raw: string; offset: int): uint32 =
  uint32(ord(raw[offset])) or
    (uint32(ord(raw[offset + 1])) shl 8) or
    (uint32(ord(raw[offset + 2])) shl 16) or
    (uint32(ord(raw[offset + 3])) shl 24)

proc checkActionRecordsFrame(recordsPath: string) =
  check fileExists(recordsPath)
  let raw = readFile(recordsPath)
  check raw.len >= 12
  if raw.len >= 12:
    let payloadLen = int(readU32Le(raw, 0))
    check payloadLen >= 6
    check raw.len >= 4 + payloadLen + 4
    check raw[4 .. 7] == "RBAR"

suite "integration_action_cache_fingerprint_policies":
  test "local CAS, memoization, restore, corruption rejection, and fingerprint policies":
    let tempRoot = createTempDir("repro-m9-action-cache", "")
    defer: removeDir(tempRoot)

    let reproRoot = tempRoot / ".repro"
    let cas = openLocalCas(reproRoot / "cas")
    var cache = openActionCache(reproRoot / "action-cache")

    block timestampPolicy:
      let root = tempRoot / "timestamp"
      createDir(root)
      let inputPath = root / "input.txt"
      let outputPath = root / "out.txt"
      writeFile(inputPath, "alpha\n")
      setStableTimestamp(inputPath)
      runFixtureAction(inputPath, outputPath)

      let record = cache.recordActionResult(cas, weakFor("timestamp"),
        ffpTimestamp, [inputPath], ["out.txt"], root)
      check record.inputs.len == 1
      check not record.inputs[0].hasLocalHash
      check record.outputs.len == 1
      check readBlob(cas, record.outputs[0].blob) == asBytes("fixture-output\nalpha\n")
      checkActionRecordsFrame(reproRoot / "action-cache" / "action-results.records")

      removeIfExists(outputPath)
      var reloaded = openActionCache(reproRoot / "action-cache")
      let hit = reloaded.lookupActionResult(cas, weakFor("timestamp"), ffpTimestamp)
      check hit.status == aclHit
      cas.restoreOutputs(hit.record, root)
      check readFile(outputPath) == "fixture-output\nalpha\n"

      removeIfExists(outputPath)
      rewritePreservingTimestamp(inputPath, "bravo\n")
      check observeFile(inputPath, ffpTimestamp).metadata == record.inputs[0].metadata
      let staleHit = cache.lookupActionResult(cas, weakFor("timestamp"), ffpTimestamp)
      check staleHit.status == aclHit
      cas.restoreOutputs(staleHit.record, root)
      check readFile(outputPath) == "fixture-output\nalpha\n"

      removeIfExists(outputPath)
      setDifferentTimestamp(inputPath)
      let miss = cache.lookupActionResult(cas, weakFor("timestamp"), ffpTimestamp)
      check miss.status == aclMissInputChanged
      check not fileExists(outputPath)

    block checksumPolicy:
      let root = tempRoot / "checksum"
      createDir(root)
      let inputPath = root / "input.txt"
      let outputPath = root / "out.txt"
      writeFile(inputPath, "alpha\n")
      setStableTimestamp(inputPath)
      runFixtureAction(inputPath, outputPath)

      let record = cache.recordActionResult(cas, weakFor("checksum"),
        ffpChecksum, [inputPath], ["out.txt"], root)
      check record.inputs.len == 1
      check record.inputs[0].hasLocalHash

      removeIfExists(outputPath)
      setDifferentTimestamp(inputPath)
      let hit = cache.lookupActionResult(cas, weakFor("checksum"), ffpChecksum)
      check hit.status == aclHit
      cas.restoreOutputs(hit.record, root)
      check readFile(outputPath) == "fixture-output\nalpha\n"

      block executableOutputPermissions:
        let execRoot = tempRoot / "executable-output"
        createDir(execRoot)
        let execInput = execRoot / "input.txt"
        let execOutput = execRoot / "tool"
        let execPermissions = {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec}
        writeFile(execInput, "alpha\n")
        writeFile(execOutput, "#!/bin/sh\necho restored-exec\n")
        setFilePermissions(execOutput, execPermissions)

        let execRecord = cache.recordActionResult(cas,
          weakFor("executable-output"), ffpChecksum, [execInput], ["tool"],
          execRoot)
        check execRecord.outputs[0].permissions == execPermissions

        removeIfExists(execOutput)
        var execReloaded = openActionCache(reproRoot / "action-cache")
        let execHit = execReloaded.lookupActionResult(cas,
          weakFor("executable-output"), ffpChecksum)
        check execHit.status == aclHit
        cas.restoreOutputs(execHit.record, execRoot)
        check readFile(execOutput) == "#!/bin/sh\necho restored-exec\n"
        check getFilePermissions(execOutput) == execPermissions

      removeIfExists(outputPath)
      rewritePreservingTimestamp(inputPath, "bravo\n")
      let miss = cache.lookupActionResult(cas, weakFor("checksum"), ffpChecksum)
      check miss.status == aclMissInputChanged
      check not fileExists(outputPath)

    block hybridPolicy:
      let root = tempRoot / "hybrid"
      createDir(root)
      let inputPath = root / "input.txt"
      let outputPath = root / "out.txt"
      writeFile(inputPath, "alpha\n")
      runFixtureAction(inputPath, outputPath)

      let record = cache.recordActionResult(cas, weakFor("hybrid"),
        ffpHybrid, [inputPath], ["out.txt"], root)
      check record.inputs.len == 1
      check record.inputs[0].hasLocalHash
      let priorMetadata = record.inputs[0].metadata

      removeIfExists(outputPath)
      setDifferentTimestamp(inputPath)
      let cutoff = cache.lookupActionResult(cas, weakFor("hybrid"), ffpHybrid)
      check cutoff.status == aclHybridCutoff
      check cutoff.record.inputs[0].metadata != priorMetadata
      check cutoff.record.inputs[0].metadata == observeFile(inputPath, ffpHybrid).metadata
      cas.restoreOutputs(cutoff.record, root)
      check readFile(outputPath) == "fixture-output\nalpha\n"
      let recordsSizeAfterCutoff = getFileInfo(reproRoot / "action-cache" /
        "action-results.records").size
      let refreshedHit = cache.lookupActionResult(cas, weakFor("hybrid"), ffpHybrid)
      check refreshedHit.status == aclHit
      check getFileInfo(reproRoot / "action-cache" /
        "action-results.records").size == recordsSizeAfterCutoff

      block noHashFastPath:
        let fastRoot = tempRoot / "hybrid-fast-path"
        createDir(fastRoot)
        let fastInput = fastRoot / "input.txt"
        let fastOutput = fastRoot / "out.txt"
        writeFile(fastInput, "alpha\n")
        runFixtureAction(fastInput, fastOutput)

        let fastRecord = cache.recordActionResult(cas, weakFor("hybrid-fast-path"),
          ffpHybrid, [fastInput], ["out.txt"], fastRoot)
        let originalPermissions = getFilePermissions(fastInput)
        removeIfExists(fastOutput)
        setFilePermissions(fastInput, {})
        defer: setFilePermissions(fastInput, originalPermissions)

        check observeFile(fastInput, ffpTimestamp).metadata ==
          fastRecord.inputs[0].metadata
        check not readable(fastInput)
        let fastHit = cache.lookupActionResult(cas, weakFor("hybrid-fast-path"),
          ffpHybrid)
        check fastHit.status == aclHit
        cas.restoreOutputs(fastHit.record, fastRoot)
        check readFile(fastOutput) == "fixture-output\nalpha\n"

      removeIfExists(outputPath)
      writeFile(inputPath, "bravo\n")
      setDifferentTimestamp(inputPath)
      let miss = cache.lookupActionResult(cas, weakFor("hybrid"), ffpHybrid)
      check miss.status == aclMissInputChanged
      check not fileExists(outputPath)

    block sharedMetadataCache:
      let root = tempRoot / "shared-metadata-cache"
      createDir(root)
      let sharedInput = root / "shared.h"
      let outputA = root / "a.o"
      let outputB = root / "b.o"
      writeFile(sharedInput, "alpha\n")
      writeFile(outputA, "a\n")
      writeFile(outputB, "b\n")

      discard cache.recordActionResult(cas, weakFor("shared-metadata-a"),
        ffpHybrid, [sharedInput], ["a.o"], root)
      discard cache.recordActionResult(cas, weakFor("shared-metadata-b"),
        ffpHybrid, [sharedInput], ["b.o"], root)

      var metadataMemo = initFileMetadataCache()
      let hitA = cache.lookupActionResult(cas, weakFor("shared-metadata-a"),
        ffpHybrid, metadataCache = addr metadataMemo)
      let hitB = cache.lookupActionResult(cas, weakFor("shared-metadata-b"),
        ffpHybrid, metadataCache = addr metadataMemo)
      check hitA.status == aclHit
      check hitB.status == aclHit

      writeFile(sharedInput, "bravo\n")
      setDifferentTimestamp(sharedInput)
      metadataMemo.clear()
      let missA = cache.lookupActionResult(cas, weakFor("shared-metadata-a"),
        ffpHybrid, metadataCache = addr metadataMemo)
      let missB = cache.lookupActionResult(cas, weakFor("shared-metadata-b"),
        ffpHybrid, metadataCache = addr metadataMemo)
      check missA.status == aclMissInputChanged
      check missB.status == aclMissInputChanged

    block corruptCasObject:
      let root = tempRoot / "corrupt"
      createDir(root)
      let inputPath = root / "input.txt"
      let outputPath = root / "out.txt"
      writeFile(inputPath, "alpha\n")
      runFixtureAction(inputPath, outputPath)

      let record = cache.recordActionResult(cas, weakFor("corrupt"),
        ffpChecksum, [inputPath], ["out.txt"], root)
      let casObject = cas.blobPath(record.outputs[0].blob.digest)
      writeFile(casObject, "corrupted")
      removeIfExists(outputPath)

      let skippedLookup = cache.lookupActionResult(cas, weakFor("corrupt"),
        ffpChecksum, verifyOutputBlobs = false)
      check skippedLookup.status == aclHit
      let lookup = cache.lookupActionResult(cas, weakFor("corrupt"), ffpChecksum)
      check lookup.status == aclRejectedCorruptOutput
      check not fileExists(outputPath)
      expect CacheIntegrityError:
        cas.restoreOutputs(record, root)
      check not fileExists(outputPath)

    block hotMetadataRecordSurvivesAppendLogDamage:
      let hotRoot = tempRoot / "hot-metadata"
      let hotReproRoot = hotRoot / ".repro"
      let hotActionRoot = hotRoot / "action"
      createDir(hotActionRoot)
      let hotCas = openLocalCas(hotReproRoot / "cas")
      var hotCache = openActionCache(hotReproRoot / "action-cache")
      let inputPath = hotActionRoot / "input.txt"
      let outputPath = hotActionRoot / "out.txt"
      writeFile(inputPath, "alpha\n")
      runFixtureAction(inputPath, outputPath)
      discard hotCache.recordActionResult(hotCas, weakFor("hot-metadata-record"),
        ffpHybrid, [inputPath], ["out.txt"], hotActionRoot)
      hotCache.flushHotIndex()
      check fileExists(hotReproRoot / "action-cache" / "action-results.hot.index")

      writeFile(hotReproRoot / "action-cache" / "action-results.records",
        "truncated full action cache")
      var hotReloaded = openActionCache(hotReproRoot / "action-cache")
      let defaultMiss = hotReloaded.lookupActionResult(hotCas,
        weakFor("hot-metadata-record"), ffpHybrid, verifyOutputBlobs = false)
      check defaultMiss.status == aclMissNoRecord
      let hotHit = hotReloaded.lookupActionResult(hotCas,
        weakFor("hot-metadata-record"), ffpHybrid, verifyOutputBlobs = false,
        allowMetadataOnlyHit = true)
      check hotHit.status == aclHit
      check hotHit.record.inputs.len == 1
      check hotHit.record.inputs[0].path == inputPath

    block newestMismatchedRecordFallsBackToOlderHit:
      let weak = weakFor("newest-mismatch-fallback")
      let oldRoot = tempRoot / "newest-mismatch-old"
      createDir(oldRoot)
      let oldInput = oldRoot / "input.txt"
      let oldOutput = oldRoot / "out.txt"
      writeFile(oldInput, "alpha\n")
      writeFile(oldOutput, "older-valid-output\n")
      let oldRecord = cache.recordActionResult(cas, weak, ffpChecksum,
        [oldInput], ["out.txt"], oldRoot)

      let newRoot = tempRoot / "newest-mismatch-new"
      createDir(newRoot)
      let newInput = newRoot / "input.txt"
      let newOutput = newRoot / "out.txt"
      writeFile(newInput, "bravo\n")
      writeFile(newOutput, "newer-stale-output\n")
      discard cache.recordActionResult(cas, weak, ffpChecksum,
        [newInput], ["out.txt"], newRoot)
      writeFile(newInput, "charlie\n")

      let lookup = cache.lookupActionResult(cas, weak, ffpChecksum)
      check lookup.status == aclHit
      check lookup.record.strongFingerprint == oldRecord.strongFingerprint

    block newestCorruptOtherwiseMatchingRecordRejectsImmediately:
      let weak = weakFor("newest-corrupt-rejects")
      let oldRoot = tempRoot / "newest-corrupt-old"
      createDir(oldRoot)
      let oldInput = oldRoot / "input.txt"
      let oldOutput = oldRoot / "out.txt"
      writeFile(oldInput, "alpha\n")
      writeFile(oldOutput, "older-valid-output-for-corrupt-test\n")
      discard cache.recordActionResult(cas, weak, ffpChecksum,
        [oldInput], ["out.txt"], oldRoot)

      let newRoot = tempRoot / "newest-corrupt-new"
      createDir(newRoot)
      let newInput = newRoot / "input.txt"
      let newOutput = newRoot / "out.txt"
      writeFile(newInput, "alpha\n")
      writeFile(newOutput, "newer-output\n")
      let newRecord = cache.recordActionResult(cas, weak, ffpChecksum,
        [newInput], ["out.txt"], newRoot)
      writeFile(cas.blobPath(newRecord.outputs[0].blob.digest), "corrupted")

      let lookup = cache.lookupActionResult(cas, weak, ffpChecksum)
      check lookup.status == aclRejectedCorruptOutput
