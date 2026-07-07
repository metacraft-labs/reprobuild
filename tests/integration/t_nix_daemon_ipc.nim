## Test: C++ Nix Evaluation Daemon IPC & Warm Cache Validation
##
## This test validates the C++ Nix evaluation daemon (`reprobuild-nix-daemon`)
## IPC protocol, socket handshakes, malformed message handling, in-memory caching,
## and idle self-reaping behavior.

import std/[unittest, os, osproc, json, strutils, net, nativesockets, times, streams]

const RepoMarker = "repro.nim"

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

suite "C++ Nix Evaluation Daemon IPC Integration Tests":

  test "Scenario 1.1, 1.2, 1.3, 1.4, 1.5: Cold Start, IPC Exchange, Warm Cache, and Dependencies":
    let repoRoot = findRepoRoot()
    let daemonPath = repoRoot.parentDir / "reprobuild-nix-daemon" / "build" / "reprobuild-nix-daemon"
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
    
    # Scenario 1.2 & 1.4: Well-formed resolve request
    let req = %*{
      "action": "resolve",
      "selector": ".#reprobuild",
      "workspaceRoot": repoRoot
    }
    sock.send($req & "\n")
    respLine = ""
    sock.readLine(respLine)
    sock.close()
    
    check respLine.len > 0
    let resp = parseJson(respLine)
    check resp["status"].getStr() == "success"
    check resp["paths"].len > 0
    check resp["dependencies"].len > 0
    
    # Scenario 1.4: Accurate Dependency Tracking (check flake.nix is in dependencies)
    var foundFlakeNix = false
    for dep in resp["dependencies"]:
      let depPath = dep["path"].getStr()
      if depPath.endsWith("flake.nix"):
        foundFlakeNix = true
        check dep["hash"].getStr().len > 0
    check foundFlakeNix
    
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
    
    # Clean up daemon
    discard execCmd("pkill -f -u $USER reprobuild-nix-daemon-ipc.sock || true")
    removeFile(socketPath)

  test "Scenario 1.6: Self-Reaping Timeout":
    let repoRoot = findRepoRoot()
    let daemonPath = repoRoot.parentDir / "reprobuild-nix-daemon" / "build" / "reprobuild-nix-daemon"
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
