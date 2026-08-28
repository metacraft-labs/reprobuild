## Test: Python Nix Evaluation Daemon IPC & Warm Cache Validation
##
## This test validates the in-repo Python Nix evaluation daemon
## (`tools/reprobuild-nix-daemon/reprobuild-nix-daemon`) IPC protocol, socket
## handshakes, malformed message handling, dependency-keyed in-memory caching,
## and idle self-reaping behavior.

import std/[unittest, os, osproc, json, strutils, net, nativesockets, times,
  streams, tempfiles, strtabs]

const RepoMarker = "repro.nim"
const FixtureRelRoot = "tests/fixtures/nix-daemon-local-flake"
const FixtureSelector = ".#hello-sh"
const FixtureExecutable = "bin/reprobuild-nix-daemon-fixture"
const FixtureExpression = "default.nix"
const FixtureFlakeNixSha256 =
  "4c7cdf3febfe4ccb9adf5f91bad3a0179cbb8a24ed4b1bc2a2d55bf07e4521d7"
const FixtureFlakeLockSha256 =
  "253b9070e88fd3ea6d247f4859279209375e9107e241af3c523b0e33a395c624"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc findNixDaemon(repoRoot: string): string =
  let envBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
  for candidate in [
    envBin,
    repoRoot / "build" / "reprobuild-nix-daemon",
    repoRoot / "tools" / "reprobuild-nix-daemon" / "reprobuild-nix-daemon",
    repoRoot.parentDir / "reprobuild-nix-daemon" / "build" /
      "reprobuild-nix-daemon"
  ]:
    if candidate.len == 0:
      continue
    if fileExists(candidate):
      when defined(posix):
        let perms = getFilePermissions(candidate)
        if fpUserExec notin perms and fpGroupExec notin perms and
            fpOthersExec notin perms:
          raise newException(IOError,
            "reprobuild-nix-daemon is not executable: " & candidate)
      return candidate
  raise newException(IOError,
    "reprobuild-nix-daemon missing; set REPROBUILD_NIX_DAEMON_BIN")

proc prepareFixtureRoot(repoRoot: string): string =
  let sourceRoot = repoRoot / FixtureRelRoot
  result = createTempDir("repro-nix-daemon-fixture-", "")
  copyFile(sourceRoot / "flake.nix", result / "flake.nix")
  copyFile(sourceRoot / "flake.lock", result / "flake.lock")
  copyFile(sourceRoot / FixtureExpression, result / FixtureExpression)
  for args in [
    "init -q",
    "add flake.nix flake.lock " & FixtureExpression
  ]:
    let (output, code) = execCmdEx("git -C " & quoteShell(result) & " " & args)
    if code != 0:
      raise newException(IOError,
        "failed to prepare Nix fixture git index: " & output)

proc fixtureDependencyHash(resp: JsonNode; path: string): string =
  for dep in resp["dependencies"]:
    if dep["path"].getStr() == path:
      return dep["hash"].getStr()
  check false
  ""

proc requireFixtureDependency(resp: JsonNode; path, expectedHash: string) =
  check fixtureDependencyHash(resp, path) == expectedHash

suite "Python Nix Evaluation Daemon IPC Integration Tests":

  when defined(posix):
    test "non-executable REPROBUILD_NIX_DAEMON_BIN is rejected":
      let repoRoot = findRepoRoot()
      let previousDaemonBin = getEnv("REPROBUILD_NIX_DAEMON_BIN")
      let sentinel = getTempDir() / "reprobuild-nix-daemon-nonexec"
      writeFile(sentinel, "#!/bin/sh\necho should-not-run\n")
      setFilePermissions(sentinel, {fpUserRead, fpUserWrite, fpGroupRead,
        fpOthersRead})
      putEnv("REPROBUILD_NIX_DAEMON_BIN", sentinel)
      try:
        expect IOError:
          discard findNixDaemon(repoRoot)
      finally:
        putEnv("REPROBUILD_NIX_DAEMON_BIN", previousDaemonBin)
        removeFile(sentinel)

    test "host Nix process strips provisioned dynamic-loader paths":
      let repoRoot = findRepoRoot()
      let daemonPath = findNixDaemon(repoRoot)
      let fixtureRoot = createTempDir("repro-nix-daemon-loader-env-", "")
      defer: removeDir(fixtureRoot)
      writeFile(fixtureRoot / "flake.nix", "{ outputs = _: {}; }\n")

      let fakeBin = fixtureRoot / "bin"
      createDir(fakeBin)
      let fakeNix = fakeBin / "nix"
      writeFile(fakeNix, """#!/bin/sh
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  echo "LD_LIBRARY_PATH leaked into host nix" >&2
  exit 42
fi
printf '%s\n' /tmp/reprobuild-nix-daemon-fake-store
""")
      setFilePermissions(fakeNix, {fpUserRead, fpUserWrite, fpUserExec})

      let socketPath = fixtureRoot / "nix-daemon.sock"
      var childEnv = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        childEnv[key] = value
      childEnv["PATH"] = fakeBin & PathSep & childEnv.getOrDefault("PATH")
      childEnv["LD_LIBRARY_PATH"] = fixtureRoot / "target-libraries"

      let daemonProcess = startProcess(daemonPath,
        args = ["--idle-exit-ms=30000", "--socket-path=" & socketPath],
        env = childEnv, options = {})
      defer:
        if daemonProcess.running:
          daemonProcess.terminate()
        daemonProcess.close()
        removeFile(socketPath)

      var sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
        protocol = IPPROTO_IP)
      var connected = false
      for i in 0 .. 40:
        sleep(50)
        try:
          sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
            protocol = IPPROTO_IP)
          sock.connectUnix(socketPath)
          connected = true
          break
        except CatchableError:
          discard
      check connected

      let req = %*{
        "action": "resolve",
        "selector": ".#fake",
        "workspaceRoot": fixtureRoot
      }
      sock.send($req & "\n")
      var respLine = ""
      sock.readLine(respLine)
      sock.close()
      check respLine.len > 0
      let resp = parseJson(respLine)
      check resp["status"].getStr() == "success"
      check resp["paths"][0].getStr() ==
        "/tmp/reprobuild-nix-daemon-fake-store"

  test "Scenario 1.1, 1.2, 1.3, 1.4, 1.5: Cold Start, IPC Exchange, Warm Cache, and Dependencies":
    let repoRoot = findRepoRoot()
    let fixtureRoot = prepareFixtureRoot(repoRoot)
    defer: removeDir(fixtureRoot)
    let daemonPath = findNixDaemon(repoRoot)
    let socketPath = "/tmp/reprobuild-nix-daemon-ipc.sock"
    
    # Assert daemon binary is built and present
    check fileExists(daemonPath)
    
    # Stop any running instance and remove old socket
    discard execCmd("pkill -f -u $USER reprobuild-nix-daemon-ipc.sock || true")
    removeFile(socketPath)
    
    # Spawn daemon process detached
    discard startProcess(daemonPath, args = ["--idle-exit-ms=30000", "--socket-path=" & socketPath], options = {})
    
    # Connect to the UNIX domain socket
    var sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
    var connected = false
    for i in 0 .. 40:
      sleep(50)
      try:
        sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
        sock.connectUnix(socketPath)
        connected = true
        break
      except CatchableError:
        discard
        
    check connected
    
    # Scenario 1.2: JSON IPC Exchange (Malformed JSON)
    sock.send("malformed_json_here\n")
    var respLine = ""
    sock.readLine(respLine)
    check respLine.len > 0
    let errResp = parseJson(respLine)
    check errResp["status"].getStr() == "error"
    check errResp.hasKey("error")
    sock.close()
    
    # Re-connect for valid request
    sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
    sock.connectUnix(socketPath)
    
    # Scenario 1.2 & 1.4: Well-formed resolve request. Keep this fixture
    # lightweight; the IPC suite validates the daemon protocol, not a full
    # repo package build.
    let req = %*{
      "action": "resolve",
      "selector": FixtureSelector,
      "workspaceRoot": fixtureRoot
    }
    sock.send($req & "\n")
    respLine = ""
    sock.readLine(respLine)
    sock.close()
    
    check respLine.len > 0
    let resp = parseJson(respLine)
    check resp["status"].getStr() == "success"
    check resp["paths"].len > 0
    check fileExists(resp["paths"][0].getStr() / FixtureExecutable)
    check resp["dependencies"].len > 0
    
    # Scenario 1.4: Accurate Dependency Tracking. The dependency assertions are
    # tied to the local flake actually used for resolution, not the repo root.
    let flakeNix = fixtureRoot / "flake.nix"
    let flakeLock = fixtureRoot / "flake.lock"
    requireFixtureDependency(resp, flakeNix, FixtureFlakeNixSha256)
    requireFixtureDependency(resp, flakeLock, FixtureFlakeLockSha256)

    # Custom stdlib tools use synthetic selectors backed by a local Nix
    # expression. The expression path must reach the daemon and participate in
    # its dependency-keyed cache identity.
    let expressionFile = fixtureRoot / FixtureExpression
    let expressionReq = %*{
      "action": "resolve",
      "selector": "reprobuild-test-expression",
      "expressionFile": expressionFile,
      "workspaceRoot": fixtureRoot
    }
    sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
      protocol = IPPROTO_IP)
    sock.connectUnix(socketPath)
    sock.send($expressionReq & "\n")
    respLine = ""
    sock.readLine(respLine)
    sock.close()
    let expressionResp = parseJson(respLine)
    check expressionResp["status"].getStr() == "success"
    check expressionResp["paths"].len > 0
    check fileExists(expressionResp["paths"][0].getStr() / FixtureExecutable)
    check fixtureDependencyHash(expressionResp, expressionFile).len > 0
    
    # Scenario 1.3: Warm In-Memory Cache Performance
    # Measure duration of the second identical request
    sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
    sock.connectUnix(socketPath)
    
    let startTime = epochTime()
    sock.send($req & "\n")
    respLine = ""
    sock.readLine(respLine)
    sock.close()
    let durationMs = (epochTime() - startTime) * 1000.0
    
    check respLine.len > 0
    let resp2 = parseJson(respLine)
    check resp2["status"].getStr() == "success"
    checkpoint("Cache hit resolution completed in: " & $durationMs & " ms")
    check durationMs < 50.0 # Warm cache hit should easily resolve within <50ms

    # Cache invalidation: the daemon cache key must include the observed input
    # hashes, otherwise this second response would reuse the first dependency
    # hash for the same selector/root after flake.nix changes.
    let mutableFixture = prepareFixtureRoot(repoRoot)
    defer: removeDir(mutableFixture)
    let mutableReq = %*{
      "action": "resolve",
      "selector": FixtureSelector,
      "workspaceRoot": mutableFixture
    }
    sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
    sock.connectUnix(socketPath)
    sock.send($mutableReq & "\n")
    respLine = ""
    sock.readLine(respLine)
    sock.close()
    let mutableResp = parseJson(respLine)
    check mutableResp["status"].getStr() == "success"
    let originalMutableHash = fixtureDependencyHash(mutableResp,
      mutableFixture / "flake.nix")

    writeFile(mutableFixture / "flake.nix",
      readFile(mutableFixture / "flake.nix") & "\n# dependency hash mutation\n")
    sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
    sock.connectUnix(socketPath)
    sock.send($mutableReq & "\n")
    respLine = ""
    sock.readLine(respLine)
    sock.close()
    let mutatedResp = parseJson(respLine)
    check mutatedResp["status"].getStr() == "success"
    let mutatedHash = fixtureDependencyHash(mutatedResp,
      mutableFixture / "flake.nix")
    check mutatedHash != originalMutableHash
    
    # Clean up daemon
    discard execCmd("pkill -f -u $USER reprobuild-nix-daemon-ipc.sock || true")
    removeFile(socketPath)

  test "Scenario 1.6: Self-Reaping Timeout":
    let repoRoot = findRepoRoot()
    let daemonPath = findNixDaemon(repoRoot)
    let socketPath = "/tmp/reprobuild-nix-daemon-reap.sock"
    
    # Assert daemon binary is built and present
    check fileExists(daemonPath)
    removeFile(socketPath)
    
    # Spawn daemon process and capture output streams
    let pProcess = startProcess(daemonPath, args = ["--idle-exit-ms=1000", "--socket-path=" & socketPath], options = {})
    
    # Wait for startup and check socket file is created
    var socketCreated = false
    for i in 0 .. 20:
      sleep(100)
      try:
        discard getFileInfo(socketPath)
        socketCreated = true
        break
      except OSError:
        discard
        
    if not socketCreated:
      echo "=== Daemon Start Failed ==="
      try:
        echo "Process running: ", pProcess.running
        echo "Daemon stderr: ", pProcess.errorStream.readAll()
        echo "Daemon stdout: ", pProcess.outputStream.readAll()
      except CatchableError as e:
        echo "Error reading stream: ", e.msg
      echo "==========================="

    check socketCreated
    
    # Wait for idle timeout (1.5 seconds)
    sleep(1500)
    
    # Check that daemon process terminated and socket file is removed
    var socketDeleted = false
    try:
      discard getFileInfo(socketPath)
    except OSError:
      socketDeleted = true
    check socketDeleted
    pProcess.close()
