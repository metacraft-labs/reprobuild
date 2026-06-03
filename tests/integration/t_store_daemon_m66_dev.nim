import std/[json, os, osproc, re, streams, strtabs, strutils, tempfiles,
    times, unittest]

import repro_local_store
import repro_store_daemon
import repro_test_support

# Spec-layout invariants from
# reprobuild-specs/Local-Content-Addressed-Store.md §"Why SQLite for the
# store index" / §"`cas/`" and §"Schema".
# Keep these regexes in lock-step with the path-shaping procs in
# libs/repro_local_store/src/repro_local_store/store.nim
# (`realizationDirName`, `casBlobRelative`).
const
  PrefixDirNameRe = r"^[^/]+-[0-9a-f]{16}$"
  CasBlobNameRe = r"^[0-9a-f]{64}$"
  CasShardDirRe = r"^[0-9a-f]{2}$"

proc assertSpecLayoutAfterRealize(storeRoot, realizedPrefixPath: string) =
  ## Cross-check the spec-required on-disk shape of a daemon-mediated
  ## realization. The same contract is asserted on the M67 path in
  ## t_integration_daemon_nix_and_tarball_realize.nim. We duplicate the
  ## short version here (kept inline because the two test files do not
  ## share a helpers module) so a regression in the synthetic-payload
  ## daemon write path is caught next to the test that exercised it.
  ##
  ## NOTE: the intermediate `<package-segment>` directory under
  ## `prefixes/` is adapter-specific (synthetic, tarball, and nix each
  ## pick a different shape), so we assert the nesting depth and the
  ## trailing `<version>-<16hex>` regex but do not require a uniform
  ## package-segment shape. The `cas/` subtree may be empty for direct-
  ## rename realizations; we assert only the sharding contract for any
  ## blobs that happen to be present.

  # SQLite index in WAL mode — index.db plus the sidecar WAL/SHM files.
  check fileExists(storeRoot / "index.db")
  check fileExists(storeRoot / "index.db-wal")
  check fileExists(storeRoot / "index.db-shm")

  # Realized prefix lives at depth 2 under `<root>/prefixes/...` and
  # carries the receipt sidecar.
  let prefixesRoot = storeRoot / "prefixes"
  check dirExists(prefixesRoot)
  check realizedPrefixPath.startsWith(prefixesRoot)
  check fileExists(realizedPrefixPath / ReceiptFileName)
  check realizedPrefixPath.parentDir.parentDir == prefixesRoot
  check realizedPrefixPath.extractFilename.match(re(PrefixDirNameRe))

  # cas/blake3/<aa>/<full-hash> sharding contract: every blob, if any,
  # must live under a two-hex-char shard directory whose name matches
  # the first two chars of the blob's full hash.
  let casRoot = storeRoot / "cas" / "blake3"
  check dirExists(casRoot)
  for shardKind, shardPath in walkDir(casRoot):
    if shardKind != pcDir:
      continue
    let shardName = shardPath.extractFilename
    check shardName.match(re(CasShardDirRe))
    for blobKind, blobPath in walkDir(shardPath):
      if blobKind != pcFile:
        continue
      let blobName = blobPath.extractFilename
      check blobName.match(re(CasBlobNameRe))
      check blobName[0 ..< 2] == shardName

const
  RealizationA =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

proc shortEndpoint(name: string): string =
  # Portable AF_UNIX-or-Named-Pipe endpoint that matches what the
  # store daemon's IPC abstraction expects on each platform.
  daemonSocketEndpoint("repro-m66-" & $getCurrentProcessId() & "-" & name)

proc binaryPath(): string = getAppFilename()

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc reprostoredBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("reprostored", ExeExt)

proc makeEnv(endpoint, runtimeRoot: string): StringTableRef =
  result = newStringTable()
  for key, value in envPairs():
    result[key] = value
  result["REPROSTORED_ENDPOINT"] = endpoint
  result["XDG_RUNTIME_DIR"] = runtimeRoot

proc waitForStatus(endpoint, storeRoot: string; timeoutMs = 5000):
    StoreDaemonStatus =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    let status = queryDevStatus(endpoint)
    if status.running and os.normalizedPath(status.storeRoot) ==
        os.normalizedPath(storeRoot):
      return status
    sleep(25)
  raise newException(OSError, "store daemon did not become ready")

proc stopIfRunning(endpoint: string) =
  if queryDevStatus(endpoint).running:
    try: stopDevDaemon(endpoint) except CatchableError: discard

proc syntheticReq(storeRoot, holderId, rootId: string;
                  delayMs = 0): SyntheticRealizeRequest =
  SyntheticRealizeRequest(
    storeRoot: storeRoot,
    realizationIdHex: RealizationA,
    packageName: "shared-synthetic",
    version: "1.0.0",
    payload: "shared payload\n",
    holderId: holderId,
    rootId: rootId,
    delayMs: delayMs)

proc runClientWorker(args: seq[string]): int =
  ## <mode> <endpoint> <storeRoot> <holder> <rootId> <statusFile>
  ## <barrier|-> <delayMs>
  doAssert args.len >= 9
  let mode = args[1]
  let endpoint = args[2]
  let storeRoot = args[3]
  let holder = args[4]
  let rootId = args[5]
  let statusFile = args[6]
  let barrier = args[7]
  let delayMs = parseInt(args[8])
  if barrier != "-":
    let deadline = epochTime() + 10.0
    while epochTime() < deadline and not fileExists(barrier):
      sleep(5)
  let req = syntheticReq(storeRoot, holder, rootId, delayMs)
  let res =
    if mode == "daemon":
      realizeSyntheticViaDaemon(req, endpoint)
    elif mode == "fallback":
      realizeSyntheticWithFallback(req, endpoint)
    else:
      raise newException(ValueError, "unknown client worker mode: " & mode)
  writeFile(statusFile, $(%*{
    "status": res.status,
    "path": res.realizedPrefixPath,
    "hash": res.realizationHashHex,
    "rootId": res.rootId,
    "writerMode": res.writerMode
  }))
  0

when isMainModule:
  let args = commandLineParams()
  if args.len > 0 and args[0] == "--client":
    quit(runClientWorker(args))

suite "M66 development store daemon":
  test "integration_store_daemon_direct_mode_fallback":
    let root = createTempDir("repro-m66-direct-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let endpoint = shortEndpoint("missing")
    let storeRoot = root / "store"

    let status = queryDevStatus(endpoint)
    check not status.running

    let res = realizeSyntheticWithFallback(
      syntheticReq(storeRoot, "holder-a", "root-a"), endpoint)
    check res.writerMode == "direct"
    check res.realizedPrefixPath.startsWith(storeRoot)
    check fileExists(res.realizedPrefixPath / "bin" / "tool")
    check readFile(res.realizedPrefixPath / "bin" / "tool") ==
      "shared payload\n"

    var store = openStore(storeRoot)
    defer: store.close()
    check store.listPrefixes().len == 1
    let receipt = readReceiptFile(res.realizedPrefixPath / ReceiptFileName)
    check receipt.writerMode == "direct"

  test "integration_store_daemon_is_distinct_from_watch_daemon":
    let root = createTempDir("repro-m66-distinct-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let runtimeRoot = root / "run"
    createDir(runtimeRoot)
    let endpoint = shortEndpoint("distinct")
    let storeRoot = root / "store"
    defer: stopIfRunning(endpoint)

    check fileExists(reprostoredBin())
    let statusAbsent = requireSuccess(shellCommand([
      publicReproBin(), "store", "daemon", "status", "--dev",
      "--store-root", storeRoot
    ], env = [("REPROSTORED_ENDPOINT", endpoint),
      ("XDG_RUNTIME_DIR", runtimeRoot)]))
    check statusAbsent.contains("not-running")

    let started = requireSuccess(shellCommand([
      publicReproBin(), "store", "daemon", "start", "--dev",
      "--store-root", storeRoot
    ], env = [("REPROSTORED_ENDPOINT", endpoint),
      ("XDG_RUNTIME_DIR", runtimeRoot)]))
    check started.contains("profile: development-store")
    check started.contains("store-root: " & storeRoot)

    let userDaemon = requireFailure(shellCommand([publicReproBin(), "daemon"]))
    check userDaemon.contains("usage: repro")
    check not userDaemon.contains("development-store")

    let stopped = requireSuccess(shellCommand([
      publicReproBin(), "store", "daemon", "stop", "--dev",
      "--store-root", storeRoot
    ], env = [("REPROSTORED_ENDPOINT", endpoint),
      ("XDG_RUNTIME_DIR", runtimeRoot)]))
    check stopped.contains("stopped")
    check not queryDevStatus(endpoint).running

  test "integration_store_daemon_dev_shared_realize":
    let root = createTempDir("repro-m66-shared-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let runtimeRoot = root / "run"
    createDir(runtimeRoot)
    let endpoint = shortEndpoint("shared")
    let storeRoot = root / "store"
    defer: stopIfRunning(endpoint)

    let startOut = requireSuccess(shellCommand([
      publicReproBin(), "store", "daemon", "start", "--dev",
      "--store-root", storeRoot
    ], env = [("REPROSTORED_ENDPOINT", endpoint),
      ("XDG_RUNTIME_DIR", runtimeRoot)]))
    check startOut.contains("running")

    let barrier = root / "go"
    let statusA = root / "a.json"
    let statusB = root / "b.json"
    let p1 = startProcess(binaryPath(), args = @["--client", "daemon",
      endpoint, storeRoot, "holder-a", "root-a", statusA, barrier, "0"],
      options = {poStdErrToStdOut})
    let p2 = startProcess(binaryPath(), args = @["--client", "daemon",
      endpoint, storeRoot, "holder-b", "root-b", statusB, barrier, "0"],
      options = {poStdErrToStdOut})
    sleep(50)
    writeFile(barrier, "go")
    let rc1 = p1.waitForExit()
    let rc2 = p2.waitForExit()
    if rc1 != 0: checkpoint(p1.outputStream.readAll())
    if rc2 != 0: checkpoint(p2.outputStream.readAll())
    check rc1 == 0
    check rc2 == 0
    p1.close()
    p2.close()

    let a = parseJson(readFile(statusA))
    let b = parseJson(readFile(statusB))
    check a["path"].getStr() == b["path"].getStr()
    check a["writerMode"].getStr() == "daemon"
    check b["writerMode"].getStr() == "daemon"
    check fileExists(a["path"].getStr() / "bin" / "tool")

    assertSpecLayoutAfterRealize(storeRoot, a["path"].getStr())

    var store = openStore(storeRoot)
    defer: store.close()
    check store.listPrefixes().len == 1
    check store.listRoots().len == 2
    let receipt = readReceiptFile(a["path"].getStr() / ReceiptFileName)
    check receipt.writerMode == "daemon"

    releaseDevRoot("holder-a", "root-a", endpoint)
    let gc1 = store.gc(graceSeconds = 0)
    check gc1.quarantined.len == 0
    check dirExists(a["path"].getStr())

    releaseDevRoot("holder-b", "root-b", endpoint)
    let gc2 = store.gc(graceSeconds = 0)
    check gc2.quarantined.len == 1

  test "integration_store_daemon_dev_lockfile_excludes_second_daemon":
    let root = createTempDir("repro-m66-lock-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let runtimeRoot = root / "run"
    createDir(runtimeRoot)
    let endpoint = shortEndpoint("lock")
    let storeRoot = root / "store"
    let env = makeEnv(endpoint, runtimeRoot)
    defer: stopIfRunning(endpoint)

    let daemon = startProcess(reprostoredBin(),
      args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
      env = env,
      options = {poStdErrToStdOut})
    defer: daemon.close()
    let first = waitForStatus(endpoint, storeRoot)
    check first.pid > 0
    check fileExists(devDaemonLockPath(storeRoot))

    let second = startProcess(reprostoredBin(),
      args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
      env = env,
      options = {poStdErrToStdOut})
    let secondRc = second.waitForExit()
    let secondOut = second.outputStream.readAll()
    second.close()
    check secondRc != 0
    check secondOut.contains("daemon lock held")
    check secondOut.contains("reprostored --dev")

    let stillRunning = queryDevStatus(endpoint)
    check stillRunning.running
    check stillRunning.pid == first.pid
    check stillRunning.storeRoot == storeRoot

    let statusOut = requireSuccess(shellCommand([
      publicReproBin(), "store", "daemon", "status", "--dev",
      "--store-root", storeRoot
    ], env = [("REPROSTORED_ENDPOINT", endpoint),
      ("XDG_RUNTIME_DIR", runtimeRoot)]))
    check statusOut.contains("repro store daemon: running")
    check statusOut.contains("pid: " & $first.pid)

  test "integration_store_daemon_dev_crash_recovery":
    let root = createTempDir("repro-m66-crash-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let runtimeRoot = root / "run"
    createDir(runtimeRoot)
    let endpoint = shortEndpoint("crash")
    let storeRoot = root / "store"
    let env = makeEnv(endpoint, runtimeRoot)

    var daemon = startProcess(reprostoredBin(),
      args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
      env = env,
      options = {poStdErrToStdOut})
    discard waitForStatus(endpoint, storeRoot)

    let statusSlow = root / "slow.json"
    let client = startProcess(binaryPath(), args = @["--client", "daemon",
      endpoint, storeRoot, "holder-crash", "root-crash", statusSlow, "-",
      "5000"], options = {poStdErrToStdOut})
    let deadline = epochTime() + 5.0
    while epochTime() < deadline:
      if dirExists(storeRoot / "tmp"):
        var tmpEntries = 0
        for kind, _ in walkDir(storeRoot / "tmp", relative = false):
          if kind in {pcDir, pcLinkToDir}: inc tmpEntries
        if tmpEntries > 0:
          break
      sleep(25)
    daemon.kill()
    discard daemon.waitForExit()
    daemon.close()
    let clientRc = client.waitForExit()
    let clientOut = client.outputStream.readAll()
    client.close()
    check clientRc != 0
    check not fileExists(statusSlow)
    check clientOut.contains("lost connection to dev store daemon during realize")
    check fileExists(devDaemonLockPath(storeRoot))

    daemon = startProcess(reprostoredBin(),
      args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
      env = env,
      options = {poStdErrToStdOut})
    defer:
      stopIfRunning(endpoint)
      daemon.close()
    discard waitForStatus(endpoint, storeRoot)

    var afterRecover = openStore(storeRoot)
    defer: afterRecover.close()
    check afterRecover.sweepStaging().len == 0

    let res = realizeSyntheticViaDaemon(
      syntheticReq(storeRoot, "holder-crash", "root-crash", 0), endpoint)
    check res.writerMode == "daemon"
    check fileExists(res.realizedPrefixPath / "bin" / "tool")

  test "integration_store_daemon_dev_corrupt_index_recovers_and_rebuilds":
    let root = createTempDir("repro-m66-corrupt-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let runtimeRoot = root / "run"
    createDir(runtimeRoot)
    let endpoint = shortEndpoint("corrupt")
    let storeRoot = root / "store"
    let env = makeEnv(endpoint, runtimeRoot)
    var restoredPrefixId: PrefixIdBytes
    var restoredPrefixPath = ""

    block createPrefix:
      var store = openStore(storeRoot)
      defer: store.close()
      let hint = StoreReceiptHint(
        adapter: "synthetic",
        packageName: "preexisting-synthetic",
        version: "0.1.0",
        declaredExecutablePath: "bin/tool",
        lockIdentity: "synthetic:preexisting",
        materializationMechanism: "directory")
      restoredPrefixId = computeRealizationHash(hint.packageName,
        hint.version, hint.adapter, hint.lockIdentity,
        hint.declaredExecutablePath)
      let realized = store.realizePrefix(restoredPrefixId, hint,
        proc (stagingDir: string; mechanism: var string) =
          createDir(stagingDir / "bin")
          writeFile(stagingDir / "bin" / "tool", "preexisting payload\n")
          mechanism = "directory")
      restoredPrefixPath = realized.absolutePath
      check fileExists(restoredPrefixPath / ReceiptFileName)
    try: removeFile(storeRoot / "index.db-wal") except OSError: discard
    try: removeFile(storeRoot / "index.db-shm") except OSError: discard
    writeFile(storeRoot / "index.db", "not a sqlite database\n")

    let daemon = startProcess(reprostoredBin(),
      args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
      env = env,
      options = {poStdErrToStdOut})
    discard waitForStatus(endpoint, storeRoot)

    block verifyRebuiltPrefix:
      var rebuilt = openStore(storeRoot)
      defer: rebuilt.close()
      let row = rebuilt.lookupPrefix(restoredPrefixId)
      check row.found
      check row.row.realizedPath == prefixRelativePath(
        "preexisting-synthetic", "0.1.0", restoredPrefixId)
      check rebuilt.listRoots().len == 0
      check dirExists(storeRoot / "recovery" / "index-db-corrupt")

    let daemonRealized = realizeSyntheticViaDaemon(
      syntheticReq(storeRoot, "holder-corrupt", "root-corrupt", 0), endpoint)
    check daemonRealized.writerMode == "daemon"
    check fileExists(daemonRealized.realizedPrefixPath / "bin" / "tool")

    stopIfRunning(endpoint)
    let rc = daemon.waitForExit()
    let daemonOut = daemon.outputStream.readAll()
    daemon.close()
    check rc == 0
    check daemonOut.contains("rebuilt corrupt index.db")
    check daemonOut.contains("quarantine=")

    try: removeFile(storeRoot / "index.db-wal") except OSError: discard
    try: removeFile(storeRoot / "index.db-shm") except OSError: discard
    writeFile(storeRoot / "index.db", "not a sqlite database, again\n")
    let recoverOut = requireSuccess(shellCommand([
      publicReproBin(), "store", "recover", "--store-root=" & storeRoot
    ], env = [("REPROSTORED_ENDPOINT", endpoint),
      ("XDG_RUNTIME_DIR", runtimeRoot)]))
    check recoverOut.contains("index rebuilt: yes")
    check recoverOut.contains("index quarantine:")
    check recoverOut.contains("reinserted prefixes: 2")

    var afterCliRecover = openStore(storeRoot)
    defer: afterCliRecover.close()
    check afterCliRecover.lookupPrefix(restoredPrefixId).found
    check afterCliRecover.listPrefixes().len == 2
