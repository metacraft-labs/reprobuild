import std/[net, os, osproc, strutils, tempfiles, unittest]

import repro_core
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
  repoRoot() / "build" / "bin" / "repro"

proc daemonEndpoint(tempRoot: string): string =
  "/tmp" / (tempRoot.extractFilename & ".sock")

proc daemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", daemonEndpoint(tempRoot),
    "--state-dir", tempRoot / "state",
    "--log", tempRoot / "state" / "logs" / "repro-daemon.log"
  ]

proc reproDaemonCommand(tempRoot: string; action: string): string =
  shellCommand(@[publicReproBin(), "daemon", action] & daemonArgs(tempRoot))

proc stopDaemon(tempRoot: string) =
  discard runShell(reproDaemonCommand(tempRoot, "stop"), repoRoot())
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard

proc fieldValue(output, field: string): string =
  for line in output.splitLines:
    let prefix = field & ": "
    if line.startsWith(prefix):
      return line[prefix.len .. ^1]
  ""

proc fakeMismatch(endpoint: string): string =
  var socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE)
  defer: socket.close()
  socket.connectUnix(endpoint)
  let fake = binaryIdentity("m1-protocol-mismatch-fake-client",
    getAppFilename(), versionString())
  socket.writeFrame(udkHello, helloBody(fake, UserDaemonFeatureFlags,
    "protocol-mismatch-test", repoRoot(), protocolMajor = 999'u16))
  let frame = socket.readFrame()
  check frame.kind == udkError
  parseErrorBody(frame.body)

suite "Local daemons/control-plane M1 user-daemon lifecycle":
  test "integration_user_daemon_lifecycle_common":
    let tempRoot = createTempDir("repro-daemon-m1-lifecycle", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    let initial = requireSuccess(reproDaemonCommand(tempRoot, "status"),
      repoRoot())
    check initial.contains("repro daemon: not-running")
    check initial.contains(daemonEndpoint(tempRoot))
    check not initial.contains("repro store daemon")

    let started = requireSuccess(reproDaemonCommand(tempRoot, "start"),
      repoRoot())
    check started.contains("repro daemon: running")
    check started.contains("role: repro-daemon/user")
    check started.contains("protocol: 1.1")
    check started.contains("features: lifecycle,status,logs,shutdown")
    check started.contains("active-sessions: 0")
    check not started.contains("reprostored")
    let generation1 = fieldValue(started, "generation")
    check generation1.len > 0

    let secondStart = requireSuccess(reproDaemonCommand(tempRoot, "start"),
      repoRoot())
    check secondStart.contains("repro daemon: running")
    check fieldValue(secondStart, "generation") == generation1

    let status = requireSuccess(reproDaemonCommand(tempRoot, "status"),
      repoRoot())
    check status.contains("repro daemon: running")
    check status.contains("binary-name: repro-daemon")
    check status.contains("endpoint: " & daemonEndpoint(tempRoot))

    let logs = requireSuccess(reproDaemonCommand(tempRoot, "logs"),
      repoRoot())
    check logs.contains("started role=repro-daemon/user")
    check logs.contains("handshake client=repro")

    let stopped = requireSuccess(reproDaemonCommand(tempRoot, "stop"),
      repoRoot())
    check stopped.contains("repro daemon: stopped")

    let afterStop = requireSuccess(reproDaemonCommand(tempRoot, "status"),
      repoRoot())
    check afterStop.contains("repro daemon: not-running")
    check not fileExists(tempRoot / "state" / "status" /
      (daemonEndpoint(tempRoot).extractFilename & ".status"))

    let restarted = requireSuccess(reproDaemonCommand(tempRoot, "restart"),
      repoRoot())
    check restarted.contains("repro daemon: running")
    let generation2 = fieldValue(restarted, "generation")
    check generation2.len > 0
    check generation2 != generation1

    let finalStop = requireSuccess(reproDaemonCommand(tempRoot, "stop"),
      repoRoot())
    check finalStop.contains("repro daemon: stopped")

  test "integration_user_daemon_protocol_mismatch_fails_clear":
    let tempRoot = createTempDir("repro-daemon-m1-protocol", "")
    defer:
      stopDaemon(tempRoot)
      removeDir(tempRoot)

    discard requireSuccess(reproDaemonCommand(tempRoot, "start"), repoRoot())
    let message = fakeMismatch(daemonEndpoint(tempRoot))
    check message.contains("user daemon protocol mismatch")
    check message.contains("client major 999")
    check message.contains("daemon major 1")

    let status = requireSuccess(reproDaemonCommand(tempRoot, "status"),
      repoRoot())
    check status.contains("repro daemon: running")
