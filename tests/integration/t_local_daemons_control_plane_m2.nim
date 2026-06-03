import std/[os, osproc, strutils, tempfiles, times, unittest]

when defined(posix):
  import std/net

  const LiveEndpointScript = """
import os
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
server.settimeout(0.2)
deadline = time.time() + 15.0
accepted = 0

while time.time() < deadline and accepted < 8:
    try:
        client, _ = server.accept()
    except socket.timeout:
        continue
    accepted += 1
    client.close()

server.close()
"""

when defined(windows):
  import repro_daemon_core

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  var parts: seq[string] = @[]
  for arg in args:
    parts.add(q(arg))
  parts.join(" ")

proc runShell(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireSuccess(command: string; cwd = getCurrentDir()): string =
  let res = runShell(command, cwd)
  if res.code != 0:
    checkpoint(res.output)
  check res.code == 0
  res.output

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc daemonEndpoint(tempRoot: string): string =
  "/tmp" / (tempRoot.extractFilename & ".sock")

proc daemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", daemonEndpoint(tempRoot),
    "--state-dir", tempRoot / "state",
    "--log", tempRoot / "state" / "logs" / "repro-daemon.log"
  ]

proc reproDaemonCommand(tempRoot: string; action: string;
                        extra: seq[string] = @[]): string =
  shellCommand(@[publicReproBin(), "daemon", action] & extra &
    daemonArgs(tempRoot))

proc statusPath(tempRoot: string): string =
  tempRoot / "state" / "status" /
    (daemonEndpoint(tempRoot).extractFilename & ".status")

proc stopDaemon(tempRoot: string) =
  discard runShell(reproDaemonCommand(tempRoot, "stop"), repoRoot())
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard

proc waitForRunning(tempRoot: string) =
  let deadline = epochTime() + 10.0
  while epochTime() < deadline:
    let res = runShell(reproDaemonCommand(tempRoot, "status"), repoRoot())
    if res.code == 0 and res.output.contains("repro daemon: running"):
      return
    sleep(25)
  checkpoint(runShell(reproDaemonCommand(tempRoot, "status"), repoRoot()).output)
  check false

when defined(posix):
  proc endpointPresent(endpoint: string): bool =
    try:
      discard getFileInfo(endpoint, followSymlink = false)
      true
    except OSError:
      false

  proc endpointAcceptsConnections(endpoint: string): bool =
    var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
    defer: socket.close()
    try:
      socket.connectUnix(endpoint)
      true
    except CatchableError:
      false

  proc waitForEndpoint(endpoint: string) =
    let deadline = epochTime() + 5.0
    while epochTime() < deadline:
      if endpointAcceptsConnections(endpoint):
        return
      sleep(25)
    checkpoint("endpoint did not accept connections: " & endpoint)
    check false

  proc startLiveEndpoint(endpoint: string): owned(Process) =
    startProcess("python3",
      args = @["-c", LiveEndpointScript, endpoint],
      options = {poUsePath, poStdErrToStdOut})

suite "Local daemons/control-plane M2 platform launch and discovery":
  test "integration_user_daemon_sessions_idle_empty":
    when defined(posix):
      let tempRoot = createTempDir("repro-daemon-m2-sessions", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      discard requireSuccess(reproDaemonCommand(tempRoot, "start"), repoRoot())
      let sessions = requireSuccess(reproDaemonCommand(tempRoot, "sessions"),
        repoRoot())
      check sessions.strip() == "repro daemon sessions: none"
    else:
      echo "[platform N/A] POSIX user-daemon sessions test"

  test "integration_user_daemon_stale_discovery_repair":
    when defined(posix):
      let tempRoot = createTempDir("repro-daemon-m2-stale", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      createDir(parentDir(daemonEndpoint(tempRoot)))
      writeFile(daemonEndpoint(tempRoot), "stale endpoint placeholder\n")
      createDir(parentDir(statusPath(tempRoot)))
      writeFile(statusPath(tempRoot), "pid=1\nendpoint=" &
        daemonEndpoint(tempRoot) & "\n")

      let initial = requireSuccess(reproDaemonCommand(tempRoot, "status"),
        repoRoot())
      check initial.contains("repro daemon: not-running")
      check not fileExists(daemonEndpoint(tempRoot))
      check not fileExists(statusPath(tempRoot))

      let liveEndpoint = startLiveEndpoint(daemonEndpoint(tempRoot))
      defer:
        if liveEndpoint.running():
          liveEndpoint.terminate()
          discard liveEndpoint.waitForExit()
        liveEndpoint.close()
      waitForEndpoint(daemonEndpoint(tempRoot))
      createDir(parentDir(statusPath(tempRoot)))
      writeFile(statusPath(tempRoot), "pid=2\nendpoint=" &
        daemonEndpoint(tempRoot) & "\n")
      let live = requireSuccess(reproDaemonCommand(tempRoot, "status"),
        repoRoot())
      check live.contains("repro daemon: not-running")
      check endpointPresent(daemonEndpoint(tempRoot))
      check fileExists(statusPath(tempRoot))
      if liveEndpoint.running():
        liveEndpoint.terminate()
        discard liveEndpoint.waitForExit()
      if endpointPresent(daemonEndpoint(tempRoot)):
        removeFile(daemonEndpoint(tempRoot))
      if fileExists(statusPath(tempRoot)):
        removeFile(statusPath(tempRoot))

      discard requireSuccess(reproDaemonCommand(tempRoot, "start"), repoRoot())
      check fileExists(statusPath(tempRoot))
      discard requireSuccess(reproDaemonCommand(tempRoot, "status"), repoRoot())
      check fileExists(statusPath(tempRoot))
    else:
      echo "[platform N/A] POSIX stale discovery repair test"

  test "integration_user_daemon_launch_macos":
    when defined(macosx):
      let tempRoot = createTempDir("repro-daemon-m2-macos", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let foreground = startProcess(publicReproBin(),
        args = @["daemon", "start", "--foreground"] & daemonArgs(tempRoot),
        workingDir = repoRoot(),
        options = {poUsePath, poStdErrToStdOut})
      waitForRunning(tempRoot)
      let fgSessions = requireSuccess(reproDaemonCommand(tempRoot, "sessions"),
        repoRoot())
      check fgSessions.strip() == "repro daemon sessions: none"
      discard requireSuccess(reproDaemonCommand(tempRoot, "stop"), repoRoot())
      check foreground.waitForExit() == 0
      foreground.close()

      let started = requireSuccess(reproDaemonCommand(tempRoot, "start"),
        repoRoot())
      check started.contains("repro daemon: running")
      check started.contains("role: repro-daemon/user")
      let logs = requireSuccess(reproDaemonCommand(tempRoot, "logs"),
        repoRoot())
      check logs.contains("launch requested backend=")
    else:
      echo "[platform N/A] macOS launch gate"

  test "integration_user_daemon_launch_linux":
    when defined(linux):
      let tempRoot = createTempDir("repro-daemon-m2-linux", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let started = requireSuccess(reproDaemonCommand(tempRoot, "start"),
        repoRoot())
      check started.contains("repro daemon: running")
      let logs = requireSuccess(reproDaemonCommand(tempRoot, "logs"),
        repoRoot())
      check logs.contains("backend=systemd-user") or
        logs.contains("backend=posix-fork")
    else:
      echo "[platform N/A] Linux launch gate"

  test "integration_user_daemon_launch_windows":
    when defined(windows):
      let tempRoot = createTempDir("repro-daemon-m2-windows", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let started = runShell(reproDaemonCommand(tempRoot, "start"), repoRoot())
      checkpoint(started.output)
      check started.code == 0
      check started.output.contains("repro daemon: running")
      check defaultUserDaemonEndpoint().startsWith("\\\\.\\pipe\\")
    else:
      echo "[platform N/A] Windows launch gate"
