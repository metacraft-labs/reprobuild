import std/[json, os, osproc, streams, strtabs, strutils, tempfiles,
    times, unittest]

import repro_local_store
import repro_store_daemon

const
  RealizationA =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

proc shortEndpoint(name: string): string =
  "/tmp/repro-m66-" & $getCurrentProcessId() & "-" & name & ".sock"

proc binaryPath(): string = getAppFilename()

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / "repro"

proc reprostoredBin(): string =
  repoRoot() / "build" / "bin" / "reprostored"

proc makeEnv(endpoint, runtimeRoot: string): StringTableRef =
  result = newStringTable()
  for key, value in envPairs():
    result[key] = value
  result["REPROSTORED_ENDPOINT"] = endpoint
  result["XDG_RUNTIME_DIR"] = runtimeRoot

proc q(value: string): string = quoteShell(value)

proc shellCommand(args: openArray[string];
                  env: openArray[(string, string)] = []): string =
  var parts: seq[string] = @[]
  for (name, value) in env:
    parts.add(name & "=" & q(value))
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc requireSuccess(command: string; cwd = repoRoot()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint(res.output)
  check res.exitCode == 0
  res.output

proc requireFailure(command: string; cwd = repoRoot()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode == 0:
    checkpoint(res.output)
  check res.exitCode != 0
  res.output

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

  test "integration_store_daemon_dev_corrupt_index_refuses_startup":
    let root = createTempDir("repro-m66-corrupt-", "")
    defer:
      try: removeDir(root) except OSError: discard
    let runtimeRoot = root / "run"
    createDir(runtimeRoot)
    let endpoint = shortEndpoint("corrupt")
    let storeRoot = root / "store"
    let env = makeEnv(endpoint, runtimeRoot)

    block createIndex:
      var store = openStore(storeRoot)
      store.close()
    try: removeFile(storeRoot / "index.db-wal") except OSError: discard
    try: removeFile(storeRoot / "index.db-shm") except OSError: discard
    writeFile(storeRoot / "index.db", "not a sqlite database\n")

    let daemon = startProcess(reprostoredBin(),
      args = @["--dev", "--store-root", storeRoot, "--endpoint", endpoint],
      env = env,
      options = {poStdErrToStdOut})
    let rc = daemon.waitForExit()
    let daemonOut = daemon.outputStream.readAll()
    daemon.close()
    check rc != 0
    check daemonOut.contains("index.db") or
      daemonOut.contains("database") or daemonOut.contains("quick_check")
    check not queryDevStatus(endpoint).running
