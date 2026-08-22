import std/[os, strutils, tempfiles, times, unittest]

import repro_hash
import repro_local_store

import repro_test_support

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

var timestampBump = 0

proc setDifferentTimestamp(path: string) =
  inc timestampBump
  let prior = getFileInfo(path).lastWriteTime
  setLastModificationTime(path, prior + initDuration(seconds = 10 + timestampBump))

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc readU32Le(raw: string; offset: int): uint32 =
  uint32(ord(raw[offset])) or
    (uint32(ord(raw[offset + 1])) shl 8) or
    (uint32(ord(raw[offset + 2])) shl 16) or
    (uint32(ord(raw[offset + 3])) shl 24)

proc writeU32Le(value: uint32): string =
  result = newString(4)
  result[0] = char(value and 0xff'u32)
  result[1] = char((value shr 8) and 0xff'u32)
  result[2] = char((value shr 16) and 0xff'u32)
  result[3] = char((value shr 24) and 0xff'u32)

proc perEdgeDirPath(cacheRoot: string; weak: ContentDigest): string =
  ## AC-1b: the edge's DIRECTORY of `<nonce>.rec` path-set files.
  cacheRoot / "action-cache" / "hot-records" / perEdgeRecordFileName(weak)

proc perEdgeRecFilePath(cacheRoot: string; weak: ContentDigest): string =
  ## Path of one (the first) `<nonce>.rec` file inside the edge's directory.
  let dir = perEdgeDirPath(cacheRoot, weak)
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".rec"):
        return path
  perEdgeDirPath(cacheRoot, weak)  # non-existent → caller's fileExists fails

proc perEdgeDirBytes(cacheRoot: string; weak: ContentDigest): int64 =
  ## Sum of every `.rec` file's size in the edge's directory (AC-1b).
  let dir = perEdgeDirPath(cacheRoot, weak)
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(".rec"):
        result += getFileSize(path)

proc checkPerEdgeRecordFrame(recordsPath: string) =
  ## The authoritative per-edge file is an `RBPE` container (magic + version
  ## + record count) whose first contained record is the existing `RBAR`
  ## full-record frame.
  check fileExists(recordsPath)
  let raw = readFile(recordsPath)
  check raw.len >= 10
  if raw.len >= 10:
    check raw[0 .. 3] == "RBPE"
    let count = int(readU32Le(raw, 6))
    check count >= 1
    let payloadLen = int(readU32Le(raw, 10))
    check payloadLen >= 6
    check raw.len >= 14 + payloadLen + 4
    check raw[14 .. 17] == "RBAR"

proc perEdgeRecordsBytes(cacheRoot: string): int =
  ## Total on-disk size of every per-edge `<nonce>.rec` file across all edge
  ## directories, i.e. the whole record store's footprint under the AC-1b
  ## per-edge layout. Used where the old tests measured `action-results.records`
  ## size.
  let dir = cacheRoot / "action-cache" / "hot-records"
  if not dirExists(dir):
    return 0
  for kind, path in walkDir(dir):
    if kind == pcDir:
      for k2, p2 in walkDir(path):
        if k2 == pcFile and p2.endsWith(".rec"):
          result += int(getFileSize(p2))

suite "integration_action_cache_fingerprint_policies":
  when isNixSupported:
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
        checkPerEdgeRecordFrame(perEdgeRecFilePath(reproRoot, weakFor("timestamp")))

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
        let recordsSizeAfterCutoff =
          perEdgeDirBytes(reproRoot, weakFor("hybrid"))
        let refreshedHit = cache.lookupActionResult(cas, weakFor("hybrid"), ffpHybrid)
        check refreshedHit.status == aclHit
        check perEdgeDirBytes(reproRoot, weakFor("hybrid")) ==
          recordsSizeAfterCutoff

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
        writeFile(casObject, "fixture-output\nbravo\n")
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

      block oversizedActionRecordFrameIsIgnored:
        let oversizedRoot = tempRoot / "oversized-action-record"
        let oversizedReproRoot = oversizedRoot / ".repro"
        createDir(oversizedRoot)
        let oversizedCas = openLocalCas(oversizedReproRoot / "cas")
        var oversizedCache = openActionCache(oversizedReproRoot / "action-cache")
        # Hand-write a corrupt per-edge file: valid RBPE header claiming one
        # record whose inner RBAR frame length is oversized. The decoder must
        # ignore it (no records → clean miss), never trust the length. Written
        # as a legacy single FILE at the edge path — also exercises the AC-1b
        # back-compat read of a pre-existing AC-1 file.
        let oversizedWeak = weakFor("oversized-action-record")
        let oversizedFrameLen = uint32(64 * 1024 * 1024 + 1)
        var corrupt = "RBPE"
        corrupt.add(writeU32Le(1'u32)[0 .. 1])       # version (u16) = 1
        corrupt.add(writeU32Le(1'u32))               # record count = 1
        corrupt.add(writeU32Le(oversizedFrameLen))   # inner frame length
        createDir(oversizedReproRoot / "action-cache" / "hot-records")
        writeFile(perEdgeDirPath(oversizedReproRoot, oversizedWeak), corrupt)

        let lookup = oversizedCache.lookupActionResult(oversizedCas,
          oversizedWeak, ffpChecksum)
        check lookup.status == aclMissNoRecord

      block perEdgeRecordSurvivesGlobalLogDamage:
        # The former global `action-results.*` files no longer exist. A build
        # that reads an edge's record must go through its per-edge file, and
        # stray legacy global files (or a damaged one) must not affect it:
        # `openActionCache` ignores-then-deletes them on open.
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
        # The per-edge directory exists; no global append-log/index is created.
        check dirExists(perEdgeDirPath(hotReproRoot, weakFor("hot-metadata-record")))
        check not fileExists(hotReproRoot / "action-cache" / "action-results.hot.index")

        # Plant a damaged legacy global file. Re-opening must delete it and
        # still serve the edge from its per-edge file.
        writeFile(hotReproRoot / "action-cache" / "action-results.records",
          "truncated full action cache")
        var hotReloaded = openActionCache(hotReproRoot / "action-cache")
        check not fileExists(hotReproRoot / "action-cache" / "action-results.records")
        let defaultHit = hotReloaded.lookupActionResult(hotCas,
          weakFor("hot-metadata-record"), ffpHybrid, verifyOutputBlobs = false)
        check defaultHit.status == aclHit
        # A metadata-only hit now revalidates the declared outputs against
        # the record (Incremental-Invalidation.md §"Minimum check set"
        # Step 3.3), so the lookup has to be told where those outputs live --
        # the same root the record was written with. Omitting it leaves the
        # record's relative `out.txt` unresolvable and the lookup fails
        # closed, which is the intended direction for an unanswerable check.
        let hotHit = hotReloaded.lookupActionResult(hotCas,
          weakFor("hot-metadata-record"), ffpHybrid, verifyOutputBlobs = false,
          allowMetadataOnlyHit = true, outputRoot = hotActionRoot)
        check hotHit.status == aclHit
        check hotHit.record.inputs.len == 1
        check hotHit.record.inputs[0].path == inputPath

      block metadataOnlyOutputRecords:
        let localRoot = tempRoot / "metadata-only-output"
        createDir(localRoot)
        let inputPath = localRoot / "input.txt"
        let outputPath = localRoot / "out.txt"
        writeFile(inputPath, "alpha\n")
        runFixtureAction(inputPath, outputPath)

        let record = cache.recordActionResult(cas, weakFor("metadata-only-output"),
          ffpHybrid, [inputPath], ["out.txt"], localRoot,
          storeOutputBlobs = false)
        check record.outputPayloadKind == opkMetadataOnly
        check record.outputs.len == 1
        check record.outputs[0].path == "out.txt"
        check record.outputs[0].metadata.kind == ffkRegular

        let metadataHit = cache.lookupActionResult(cas,
          weakFor("metadata-only-output"), ffpHybrid, verifyOutputBlobs = false)
        check metadataHit.status == aclHit

        removeIfExists(outputPath)
        let restoreLookup = cache.lookupActionResult(cas,
          weakFor("metadata-only-output"), ffpHybrid)
        check restoreLookup.status == aclMissNoOutputPayload
        expect CacheIntegrityError:
          cas.restoreOutputs(record, localRoot)

      block timestampDirectoryProbeIsExistenceOnly:
        let localRoot = tempRoot / "timestamp-directory-probe"
        createDir(localRoot)
        writeFile(localRoot / "out.txt", "one\n")

        discard cache.recordActionResult(cas,
          weakFor("timestamp-directory-probe"), ffpTimestamp,
          [localRoot], ["out.txt"], localRoot)
        writeFile(localRoot / "later-created-output.txt", "two\n")

        let lookup = cache.lookupActionResult(cas,
          weakFor("timestamp-directory-probe"), ffpTimestamp,
          verifyOutputBlobs = false)
        check lookup.status == aclHit

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
