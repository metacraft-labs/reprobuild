## M56 integration verification gate
## `integration_local_store_layout_and_atomic_writes`.
##
## The gate has four scenarios per the milestone description:
##
## 1. Two writers materialize TWO DIFFERENT prefixes concurrently and the
##    rename → INSERT OR IGNORE protocol yields TWO published prefixes
##    on disk plus TWO index rows.
## 2. Two writers race the SAME prefix-id. Exactly one wins the rename
##    and inserts the index row; the loser observes "target exists",
##    drops its staging dir, and the redundant `INSERT OR IGNORE` is a
##    no-op. No lockfile is required and none is observed on disk.
## 3. A CAS blob whose on-disk bytes do not hash to its key is detected
##    on read (`ECasDigestMismatch`).
## 4. `repro store recover` cleans up both a half-written staging dir
##    and an unindexed `prefixes/...` directory written by a writer that
##    crashed between rename and insert (and quarantines a receipt
##    whose realization-hash does not match the directory leaf).
##
## Concurrency methodology: scenarios 1 and 2 spawn TWO REAL OS
## PROCESSES via `startProcess`. The test binary doubles as the writer
## when invoked with `--worker <case> <store-root> <barrier> <id>`.
## Each worker spins until the barrier file appears (a Unix-style
## "ready" file the parent writes to release every worker
## simultaneously), then opens the shared store, materializes, and
## emits its outcome to a per-worker JSON status file. This is a real
## concurrency exercise — no synchronous stand-ins.

import std/[json, monotimes, os, osproc, sequtils, streams, strutils,
    tempfiles, times, unittest]

import repro_local_store

const BarrierFileName = "go.barrier"

# ---------------------------------------------------------------------------
# Worker shared helpers
# ---------------------------------------------------------------------------

proc waitForBarrier(path: string; timeoutSecs = 30) =
  let deadline = getMonoTime() + initDuration(seconds = timeoutSecs)
  while getMonoTime() < deadline:
    if fileExists(path):
      return
    sleep(5)
  raise newException(OSError, "barrier file did not appear: " & path)

proc workerSamePrefixOutcome(storeRoot, prefixHashHex, workerId: string;
                            sharedPayload: string): JsonNode =
  ## Worker for scenario 2: two workers race the same prefix-id.
  ## Returns the outcome label so the parent can verify exactly-one
  ## winner. The payload is identical across workers so both produce
  ## the same realization hash from the same inputs.
  var store = openStore(storeRoot)
  defer: store.close()
  let hint = StoreReceiptHint(
    adapter: "tarball",
    packageName: "concurrent",
    version: "1.0.0",
    declaredExecutablePath: "bin/tool",
    lockIdentity: "tarball:concurrent@1.0.0",
    materializationMechanism: "directory")
  let prefixId = computeRealizationHash(hint.packageName, hint.version,
    hint.adapter, hint.lockIdentity, hint.declaredExecutablePath)
  doAssert prefixIdHex(prefixId) == prefixHashHex,
    "test bug: workers disagree on realization hash"
  let outcome = store.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      createDir(stagingDir / "bin")
      writeFile(stagingDir / "bin" / "tool", sharedPayload)
      mechanism = "directory")
  result = %*{
    "worker": workerId,
    "outcome": $outcome.outcome,
    "prefixIdHex": prefixIdHex(outcome.prefixId),
    "relativePath": outcome.relativePath,
    "absolutePath": outcome.absolutePath
  }

proc workerDifferentPrefixOutcome(storeRoot, packageName, workerId: string):
    JsonNode =
  ## Worker for scenario 1: two workers publish two DIFFERENT prefix-ids
  ## concurrently. Each worker uses its own package name so the
  ## realization hashes are deterministically distinct.
  var store = openStore(storeRoot)
  defer: store.close()
  let hint = StoreReceiptHint(
    adapter: "tarball",
    packageName: packageName,
    version: "0.1.0",
    declaredExecutablePath: "bin/tool",
    lockIdentity: "tarball:" & packageName & "@0.1.0",
    materializationMechanism: "directory")
  let prefixId = computeRealizationHash(hint.packageName, hint.version,
    hint.adapter, hint.lockIdentity, hint.declaredExecutablePath)
  let outcome = store.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      createDir(stagingDir / "bin")
      writeFile(stagingDir / "bin" / "tool",
        "payload-for-" & packageName & "\n")
      mechanism = "directory")
  result = %*{
    "worker": workerId,
    "outcome": $outcome.outcome,
    "prefixIdHex": prefixIdHex(outcome.prefixId),
    "relativePath": outcome.relativePath,
    "absolutePath": outcome.absolutePath
  }

proc runWorker(args: seq[string]): int =
  ## Dispatch a worker mode invoked as `<test-binary> --worker <case>
  ## <storeRoot> <barrierFile> <statusFile> <extra...>`.
  doAssert args.len >= 5
  let scenario = args[1]
  let storeRoot = args[2]
  let barrier = args[3]
  let statusFile = args[4]
  let workerId = args[5]
  waitForBarrier(barrier)
  var outcome: JsonNode
  case scenario
  of "same-prefix":
    # args[6] is the expected prefixId hex; args[7] is the shared payload.
    doAssert args.len >= 8
    outcome = workerSamePrefixOutcome(storeRoot, args[6], workerId, args[7])
  of "different-prefix":
    # args[6] is the package name unique to this worker.
    doAssert args.len >= 7
    outcome = workerDifferentPrefixOutcome(storeRoot, args[6], workerId)
  else:
    raise newException(ValueError, "unknown worker scenario: " & scenario)
  writeFile(statusFile, $outcome)
  return 0

# ---------------------------------------------------------------------------
# Parent (verifier) helpers
# ---------------------------------------------------------------------------

proc binaryPath(): string =
  ## Returns the absolute path of THIS test binary so the test can
  ## spawn worker copies of itself.
  getAppFilename()

proc spawnWorker(scenarioArgs: seq[string]): Process =
  let cmdArgs = @["--worker"] & scenarioArgs
  startProcess(binaryPath(), args = cmdArgs, options = {poStdErrToStdOut,
    poUsePath})

proc readStatusJson(path: string): JsonNode =
  for _ in 0 ..< 200:
    if fileExists(path):
      try:
        return parseJson(readFile(path))
      except CatchableError:
        discard
    sleep(10)
  raise newException(OSError, "status file never materialized: " & path)

# ---------------------------------------------------------------------------
# Entry point: if invoked as a worker, dispatch and exit before unittest.
# ---------------------------------------------------------------------------

when isMainModule:
  let pargs = commandLineParams()
  if pargs.len > 0 and pargs[0] == "--worker":
    quit(runWorker(pargs))

suite "integration_local_store_layout_and_atomic_writes":

  test "scenario_1_two_different_prefixes_concurrent":
    ## Two REAL OS processes publish two different prefixes against
    ## the same store. Both must succeed; the index must contain both
    ## rows; both directories must exist.
    let root = createTempDir("repro-m56-layout-", "")
    defer:
      try: removeDir(root) except OSError: discard

    let storeRoot = root / "store"
    block initStore:
      # Create the store and close it so the workers see a fully-built
      # layout. SQLite WAL mode tolerates this fine, but the test is
      # simpler if the workers don't race the schema init.
      var s = openStore(storeRoot)
      s.close()

    let barrier = root / BarrierFileName
    let status1 = root / "w1.json"
    let status2 = root / "w2.json"

    let p1 = spawnWorker(@["different-prefix", storeRoot, barrier,
      status1, "w1", "alpha"])
    let p2 = spawnWorker(@["different-prefix", storeRoot, barrier,
      status2, "w2", "beta"])
    sleep(50)   # Give both workers time to reach the barrier wait.
    writeFile(barrier, "go")

    let rc1 = p1.waitForExit()
    let rc2 = p2.waitForExit()
    if rc1 != 0:
      echo "w1 stdout:"; echo p1.outputStream.readAll()
    if rc2 != 0:
      echo "w2 stdout:"; echo p2.outputStream.readAll()
    check rc1 == 0
    check rc2 == 0
    p1.close()
    p2.close()

    let s1 = readStatusJson(status1)
    let s2 = readStatusJson(status2)
    check s1["outcome"].getStr() == "roPublished"
    check s2["outcome"].getStr() == "roPublished"
    check s1["prefixIdHex"].getStr() != s2["prefixIdHex"].getStr()
    check dirExists(s1["absolutePath"].getStr())
    check dirExists(s2["absolutePath"].getStr())
    check fileExists(s1["absolutePath"].getStr() / ".repro-receipt")
    check fileExists(s2["absolutePath"].getStr() / ".repro-receipt")

    # Reopen the store and inspect the index.
    var verifier = openStore(storeRoot)
    defer: verifier.close()
    let rows = verifier.listPrefixes()
    check rows.len == 2
    var alphaSeen = false
    var betaSeen = false
    for row in rows:
      if row.packageName == "alpha": alphaSeen = true
      if row.packageName == "beta": betaSeen = true
      let abs = verifier.absolutePrefixPath(row.realizedPath)
      check dirExists(abs)
    check alphaSeen
    check betaSeen

  test "scenario_2_same_prefix_id_one_winner":
    ## Two REAL OS processes race the SAME prefix-id. Exactly one must
    ## be `roPublished`; the other must be `roLoserOfRace` (or
    ## `roAlreadyPresent`). The index must contain ONE row, and the
    ## prefix directory must exist exactly once.
    let root = createTempDir("repro-m56-same-prefix-", "")
    defer:
      try: removeDir(root) except OSError: discard

    let storeRoot = root / "store"
    var initStore = openStore(storeRoot)
    initStore.close()

    # Precompute the expected hash so both workers can assert they
    # agree before the race.
    let hint = StoreReceiptHint(
      adapter: "tarball",
      packageName: "concurrent",
      version: "1.0.0",
      declaredExecutablePath: "bin/tool",
      lockIdentity: "tarball:concurrent@1.0.0")
    let expectedId = computeRealizationHash(hint.packageName, hint.version,
      hint.adapter, hint.lockIdentity, hint.declaredExecutablePath)
    let expectedHex = prefixIdHex(expectedId)

    let barrier = root / BarrierFileName
    let status1 = root / "w1.json"
    let status2 = root / "w2.json"
    let sharedPayload = "deterministic-payload\n"

    let p1 = spawnWorker(@["same-prefix", storeRoot, barrier, status1,
      "w1", expectedHex, sharedPayload])
    let p2 = spawnWorker(@["same-prefix", storeRoot, barrier, status2,
      "w2", expectedHex, sharedPayload])
    sleep(50)
    writeFile(barrier, "go")

    let rc1 = p1.waitForExit()
    let rc2 = p2.waitForExit()
    if rc1 != 0:
      echo "w1 stdout:"; echo p1.outputStream.readAll()
    if rc2 != 0:
      echo "w2 stdout:"; echo p2.outputStream.readAll()
    check rc1 == 0
    check rc2 == 0
    p1.close()
    p2.close()

    let s1 = readStatusJson(status1)
    let s2 = readStatusJson(status2)
    # Exactly one winner. The loser can be either roLoserOfRace (lost
    # the rename) or roAlreadyPresent (the rename had completed and the
    # pre-flight `SELECT realized_path FROM prefixes WHERE prefix_id =
    # ?` short-circuited before any stage). The spec accepts both as
    # the "loser of race" outcome.
    let o1 = s1["outcome"].getStr()
    let o2 = s2["outcome"].getStr()
    var winners = 0
    var losers = 0
    for o in [o1, o2]:
      if o == "roPublished":
        inc winners
      elif o == "roLoserOfRace" or o == "roAlreadyPresent":
        inc losers
    check winners == 1
    check losers == 1

    var verifier = openStore(storeRoot)
    defer: verifier.close()
    let rows = verifier.listPrefixes()
    check rows.len == 1
    check rows[0].packageName == "concurrent"
    check prefixIdHex(rows[0].prefixId) == expectedHex

    # NO lockfile artefact must appear in the store.
    check not fileExists(storeRoot / "index" / "locks")
    check not dirExists(storeRoot / "index" / "locks")
    var foundLockfile = false
    for kind, path in walkDir(storeRoot, relative = false):
      let leaf = path.extractFilename.toLowerAscii()
      if leaf.contains(".lock") or leaf.contains("lockfile"):
        foundLockfile = true
    check not foundLockfile

  test "scenario_3_corrupt_cas_blob_detected_on_read":
    ## A blob whose bytes do not hash to its key must be rejected on
    ## read with `ECasDigestMismatch`. We deliberately corrupt a blob
    ## by overwriting its bytes after `storeCasBlob` has placed it.
    let root = createTempDir("repro-m56-cas-corrupt-", "")
    defer:
      try: removeDir(root) except OSError: discard
    var store = openStore(root / "store")
    defer: store.close()
    const original = "valid-payload\n"
    var payload = newSeq[byte](original.len)
    for i, ch in original: payload[i] = byte(ord(ch))
    let key = store.storeCasBlob(payload)
    # First read: must succeed and verify cleanly.
    let recovered = store.readCasBlob(key)
    check recovered.len == original.len

    # Corrupt the on-disk blob.
    let onDisk = store.casPath(key)
    check fileExists(onDisk)
    writeFile(onDisk, "tampered-bytes\n")

    var raised = false
    try:
      discard store.readCasBlob(key)
    except ECasDigestMismatch:
      raised = true
    check raised

  test "scenario_4_recover_cleans_staging_and_unindexed_prefixes":
    ## A leftover `tmp/<random>/` directory must be unconditionally
    ## swept. An unindexed `prefixes/<pkg>/<dir>/` directory written by
    ## a writer that crashed between rename and insert must be
    ## re-validated against its receipt and re-inserted. A receipt
    ## whose realization-hash does not match the directory leaf must
    ## be quarantined to `gc/pending-deletion/`.
    let root = createTempDir("repro-m56-recover-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let storeRoot = root / "store"
    var store = openStore(storeRoot)

    # 1. Plant a half-written staging dir.
    let staleStage = store.tmpRoot / "stale-staging"
    createDir(staleStage)
    writeFile(staleStage / "partial.txt", "partially-written\n")
    check dirExists(staleStage)

    # 2. Plant an unindexed prefix dir written with a valid receipt.
    let hintGood = StoreReceiptHint(
      adapter: "tarball",
      packageName: "stranded-good",
      version: "1.0.0",
      declaredExecutablePath: "bin/tool",
      lockIdentity: "tarball:stranded-good@1.0.0",
      materializationMechanism: "directory")
    let goodId = computeRealizationHash(hintGood.packageName, hintGood.version,
      hintGood.adapter, hintGood.lockIdentity, hintGood.declaredExecutablePath)
    let goodRel = prefixRelativePath(hintGood.packageName, hintGood.version,
      goodId)
    let goodAbs = store.absolutePrefixPath(goodRel)
    createDir(goodAbs / "bin")
    writeFile(goodAbs / "bin" / "tool", "stranded-tool-body\n")
    let receiptGood = RealizationReceipt(
      schemaVersion: 1'u16,
      adapter: hintGood.adapter,
      packageName: hintGood.packageName,
      version: hintGood.version,
      realizationHash: goodId,
      realizedPath: goodRel,
      declaredExecutablePath: hintGood.declaredExecutablePath,
      lockIdentity: hintGood.lockIdentity,
      materializationMechanism: "directory",
      createdAtUnix: getTime().toUnix,
      writerProcessId: 1,
      writerMode: "direct")
    writeReceiptFile(goodAbs / ".repro-receipt", receiptGood)

    # 3. Plant a prefix dir with a MISMATCHED receipt → must be
    # quarantined as EReceiptMismatch.
    let hintBad = StoreReceiptHint(
      adapter: "tarball",
      packageName: "stranded-bad",
      version: "0.1.0",
      declaredExecutablePath: "bin/tool",
      lockIdentity: "tarball:stranded-bad@0.1.0",
      materializationMechanism: "directory")
    let badIdReal = computeRealizationHash(hintBad.packageName,
      hintBad.version, hintBad.adapter, hintBad.lockIdentity,
      hintBad.declaredExecutablePath)
    var badIdLie = badIdReal
    badIdLie[0] = byte((int(badIdLie[0]) xor 0xff) and 0xff)
    badIdLie[1] = byte((int(badIdLie[1]) xor 0x55) and 0xff)
    # Directory leaf uses `badIdReal` (the one the on-disk content
    # would naturally produce); the receipt records `badIdLie` so the
    # post-recover check rejects the prefix.
    let badRel = prefixRelativePath(hintBad.packageName, hintBad.version,
      badIdReal)
    let badAbs = store.absolutePrefixPath(badRel)
    createDir(badAbs / "bin")
    writeFile(badAbs / "bin" / "tool", "tampered-body\n")
    let receiptBad = RealizationReceipt(
      schemaVersion: 1'u16,
      adapter: hintBad.adapter,
      packageName: hintBad.packageName,
      version: hintBad.version,
      realizationHash: badIdLie,
      realizedPath: badRel,
      declaredExecutablePath: hintBad.declaredExecutablePath,
      lockIdentity: hintBad.lockIdentity,
      materializationMechanism: "directory",
      createdAtUnix: getTime().toUnix,
      writerProcessId: 1,
      writerMode: "direct")
    writeReceiptFile(badAbs / ".repro-receipt", receiptBad)

    # 4. Plant a prefix dir with NO receipt — must be quarantined too.
    let orphanAbs = store.prefixesRoot / "stranded-orphan" / "0.0.0-deadbeefdeadbeef"
    createDir(orphanAbs)
    writeFile(orphanAbs / "marker.txt", "no-receipt\n")

    # Run recovery.
    let report = store.recover()
    check report.quickCheck == "ok"
    check report.sweptStagingDirs.len >= 1
    check report.reinsertedPrefixes.len >= 1
    check report.quarantinedPrefixes.len >= 2

    # Validate the good prefix was indexed.
    let look = store.lookupPrefix(goodId)
    check look.found
    check look.row.packageName == "stranded-good"
    check dirExists(goodAbs)

    # The mismatched prefix's directory is no longer in prefixes/.
    check not dirExists(badAbs)
    # The orphan prefix's directory is no longer in prefixes/.
    check not dirExists(orphanAbs)
    # The staging dir is gone.
    check not dirExists(staleStage)

    # The gc/pending-deletion/ holds the quarantined trees.
    var quarantineCount = 0
    for kind, _ in walkDir(store.gcPendingRoot, relative = false):
      if kind in {pcDir, pcLinkToDir}:
        inc quarantineCount
    check quarantineCount >= 2

    store.close()

  test "public_cli_repro_store_recover_runs_the_same_protocol":
    ## End-to-end coverage of the public `repro store recover` command.
    ## Compiles the CLI, plants a stale staging dir under `tmp/`, then
    ## verifies the CLI sweeps it.
    let root = createTempDir("repro-m56-recover-cli-", "")
    defer:
      try: removeDir(root) except OSError: discard

    # Compile the public `repro` CLI binary.
    proc findReproSource(): string =
      var current = getAppFilename().parentDir
      for _ in 0 .. 8:
        if dirExists(current / "libs") and
            fileExists(current / "apps" / "repro" / "repro.nim"):
          return current / "apps" / "repro" / "repro.nim"
        let p = current.parentDir
        if p == current: break
        current = p
      ""
    let source = findReproSource()
    check source.len > 0
    let outBin = root / "repro-bin" / "repro.exe"
    createDir(outBin.parentDir)
    let buildArgs = @["nim", "c", "--hints:off", "--verbosity:0",
      "--nimcache:" & (root / "nimcache-repro"),
      "--out:" & outBin, source]
    let buildCmd = buildArgs.mapIt(quoteShell(it)).join(" ")
    let buildRes = execCmdEx(buildCmd)
    check buildRes.exitCode == 0
    check fileExists(outBin)

    let storeRoot = root / "store"
    block init:
      var s = openStore(storeRoot)
      defer: s.close()
      let staleStage = s.tmpRoot / "cli-stale"
      createDir(staleStage)
      writeFile(staleStage / "in-flight.txt", "left behind\n")

    let res = execCmdEx(quoteShell(outBin) & " store recover " &
      "--store-root=" & quoteShell(storeRoot))
    check res.exitCode == 0
    check res.output.contains("quick_check: ok")
    check res.output.contains("swept staging dirs: 1")

    var verifier = openStore(storeRoot)
    defer: verifier.close()
    check not dirExists(verifier.tmpRoot / "cli-stale")
