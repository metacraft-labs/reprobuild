import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_daemon_core
import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc liveEndpointHelperSource(): string =
  repoRoot() / "tests" / "fixtures" / "local-daemons-control-plane" /
    "live-endpoint-helper" / "live_endpoint_helper.nim"

proc liveEndpointHelperBin(): string =
  repoRoot() / "build" / "test-bin" /
    addFileExt("live_endpoint_helper", ExeExt)

proc daemonEndpoint(tempRoot: string): string =
  daemonSocketEndpoint(tempRoot.extractFilename)

proc daemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", daemonEndpoint(tempRoot),
    "--state-dir", tempRoot / "state",
    "--log", tempRoot / "state" / "logs" / "repro-daemon.log"
  ]

proc reproDaemonCommand(tempRoot: string; action: string;
                        extra: seq[string] = @[]): CmdSpec =
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
  checkpoint(runShell(reproDaemonCommand(tempRoot, "status"),
    repoRoot()).output)
  check false

proc endpointPresent(endpoint: string): bool =
  endpointExistsLocal(endpoint)

proc endpointAccepts(endpoint: string): bool =
  endpointAcceptsConnections(endpoint)

proc waitForEndpoint(endpoint: string) =
  let deadline = epochTime() + 5.0
  while epochTime() < deadline:
    if endpointAccepts(endpoint):
      return
    sleep(25)
  checkpoint("endpoint did not accept connections: " & endpoint)
  check false

proc startLiveEndpoint(endpoint: string): owned(Process) =
  ## Spawn the portable Nim helper that binds ``endpoint`` and
  ## accepts a small number of connections, then exits. The helper
  ## binary is built up-front by ``scripts/run_tests.sh`` (per the
  ## "no `just build` from inside a test" rule); a missing binary
  ## here is a harness configuration error, not something the test
  ## should attempt to recover from in-band.
  let helperBin = liveEndpointHelperBin()
  if not fileExists(helperBin):
    raise newException(OSError,
      "live-endpoint helper missing at " & helperBin & "; build it " &
      "via the test harness (scripts/run_tests.sh)")
  startProcess(helperBin, args = @[endpoint],
    options = {poUsePath, poStdErrToStdOut})

when isNixSupported:
  suite "Local daemons/control-plane M2 platform launch and discovery":
    test "integration_user_daemon_sessions_idle_empty":
      let tempRoot = createTempDir("repro-daemon-m2-sessions", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      discard requireSuccess(reproDaemonCommand(tempRoot, "start"), repoRoot())
      let sessions = requireSuccess(reproDaemonCommand(tempRoot, "sessions"),
        repoRoot())
      check sessions.strip() == "repro daemon sessions: none"

    test "integration_user_daemon_stale_discovery_repair":
      let tempRoot = createTempDir("repro-daemon-m2-stale", "")
      defer:
        stopDaemon(tempRoot)
        removeDir(tempRoot)

      let endpoint = daemonEndpoint(tempRoot)
      when endpointKindOf("") == ekUnixSocket or true:
        # The stale-file scenario is meaningful only when the endpoint
        # lives on a filesystem path — on Windows the kernel-managed
        # named-pipe namespace has no notion of a stale file. The
        # discovery-files (under ``state/``) are filesystem on every
        # platform so the post-bind cleanup checks ARE still valid.
        when defined(posix):
          createDir(parentDir(endpoint))
          writeFile(endpoint, "stale endpoint placeholder\n")
        createDir(parentDir(statusPath(tempRoot)))
        writeFile(statusPath(tempRoot), "pid=1\nendpoint=" &
          endpoint & "\n")

        let initial = requireSuccess(reproDaemonCommand(tempRoot, "status"),
          repoRoot())
        check initial.contains("repro daemon: not-running")
        when defined(posix):
          check not fileExists(endpoint)
        check not fileExists(statusPath(tempRoot))

      let liveEndpoint = startLiveEndpoint(endpoint)
      defer:
        if liveEndpoint.running():
          liveEndpoint.terminate()
          discard liveEndpoint.waitForExit()
        liveEndpoint.close()
      waitForEndpoint(endpoint)
      createDir(parentDir(statusPath(tempRoot)))
      writeFile(statusPath(tempRoot), "pid=2\nendpoint=" & endpoint & "\n")
      let live = requireSuccess(reproDaemonCommand(tempRoot, "status"),
        repoRoot())
      check live.contains("repro daemon: not-running")
      check endpointPresent(endpoint)
      check fileExists(statusPath(tempRoot))
      if liveEndpoint.running():
        liveEndpoint.terminate()
        discard liveEndpoint.waitForExit()
      when defined(posix):
        try: removeFile(endpoint) except OSError: discard
      if fileExists(statusPath(tempRoot)):
        removeFile(statusPath(tempRoot))

      discard requireSuccess(reproDaemonCommand(tempRoot, "start"), repoRoot())
      check fileExists(statusPath(tempRoot))
      discard requireSuccess(reproDaemonCommand(tempRoot, "status"), repoRoot())
      check fileExists(statusPath(tempRoot))

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
        let fgSessions = requireSuccess(reproDaemonCommand(tempRoot,
          "sessions"), repoRoot())
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
