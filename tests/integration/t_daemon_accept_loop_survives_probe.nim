## Regression cover for the daemon accept loop's two starvation modes.
##
## Both were observed in production, in the local-daemon family, as a
## readiness poll that burned its whole 60 s budget reporting
## ``repro daemon: not-running`` against a daemon that had already logged its
## own ``started`` line:
##
##   run 5  t_local_daemons_control_plane_m8
##            :: integration_stats_snapshot_compare
##   run 6  t_local_daemons_control_plane_m7
##            :: integration_daemon_stats_capture_opt_in
##
## The victim moved between binaries because neither test is at fault: the
## daemon's single-threaded accept loop could be permanently disabled by any
## client, and every daemon-using suite is a candidate victim.
##
##   1. DEAD PEER. ``endpointAcceptsConnections`` — the liveness probe every
##      ``repro daemon status`` runs on the not-running path via
##      ``cleanupStaleUserDaemonDiscovery`` — connects and closes without
##      sending a frame. The loop accepts it, ``readFrame`` raises
##      "unexpected EOF reading 10 bytes", and the error handler tries to
##      report that back over the already-closed socket. The unbounded send
##      used to go through Nim's ``net.send``, which swallows ``EPIPE`` under
##      ``SocketFlag.SafeDisconn`` WITHOUT advancing its write cursor and
##      therefore retries forever. Measured on the wedged daemon: 704_864
##      ``sendto(...) = -1 EPIPE`` syscalls in ~3 s, one core pinned at 100%,
##      and no further ``accept`` for the life of the process.
##
##   2. SILENT PEER. A client that connects and then neither sends nor closes
##      held the loop in an unbounded ``readFrame`` for as long as it liked,
##      so every other client's handshake timed out.
##
## Both cases here drive the REAL daemon binary over a REAL unix socket with
## the REAL production client entry points — no mocks, no fakes, no injected
## seams. That is deliberate: the defect lived precisely in the interaction
## between the production probe, the kernel's socket teardown semantics, and
## the loop's error path, and any stub of those would have hidden it.

import std/[os, osproc, tempfiles, times, unittest]

import repro_daemon_core
import repro_test_support

proc repoRoot(): string =
  getCurrentDir()

proc publicReproBin(): string =
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt)

proc daemonEndpoint(tempRoot: string): string =
  daemonSocketEndpoint(tempRoot.extractFilename)

proc daemonStateDir(tempRoot: string): string =
  tempRoot / "state"

proc daemonLogPath(tempRoot: string): string =
  daemonStateDir(tempRoot) / "logs" / "repro-daemon.log"

proc daemonArgs(tempRoot: string): seq[string] =
  @[
    "--endpoint", daemonEndpoint(tempRoot),
    "--state-dir", daemonStateDir(tempRoot),
    "--log", daemonLogPath(tempRoot)
  ]

proc daemonLog(tempRoot: string): string =
  if fileExists(daemonLogPath(tempRoot)): readFile(daemonLogPath(tempRoot))
  else: "(no daemon log at " & daemonLogPath(tempRoot) & ")"

proc waitForRunning(tempRoot: string; timeoutSeconds: float): bool =
  ## Poll the daemon's own status handshake until it answers "running".
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if queryUserDaemonStatus(daemonEndpoint(tempRoot)).running:
      return true
    sleep(25)
  false

proc startForegroundDaemon(tempRoot: string): owned(Process) =
  createDir(daemonStateDir(tempRoot))
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard
  result = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground"] & daemonArgs(tempRoot),
    workingDir = repoRoot(),
    options = {poUsePath, poStdErrToStdOut})
  if not waitForRunning(tempRoot, 60.0):
    checkpoint(daemonLog(tempRoot))
    if result.running():
      result.terminate()
      discard result.waitForExit()
    result.close()
    raise newException(IOError,
      "daemon under test never became ready at " & daemonEndpoint(tempRoot))

proc closeForegroundDaemon(daemon: var owned(Process); tempRoot: string) =
  if not daemon.isNil:
    if daemon.running():
      daemon.terminate()
      discard daemon.waitForExit()
    daemon.close()
  try: removeFile(daemonEndpoint(tempRoot)) except OSError: discard

suite "Daemon accept loop survives hostile clients":
  test "integration_daemon_survives_readiness_probe":
    ## A bare connect-and-close probe must cost the daemon one client slot,
    ## not its whole accept loop.
    let tempRoot = createTempDir("repro-daemon-probe", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)
    let endpoint = daemonEndpoint(tempRoot)

    # The production probe, called exactly as `cleanupStaleUserDaemonDiscovery`
    # calls it. Several times: the wedge needs only one, but repeating proves
    # the loop keeps draining them.
    for i in 1 .. 3:
      check userDaemonEndpointAcceptsConnections(endpoint)

      let started = epochTime()
      let status = queryUserDaemonStatus(endpoint)
      let elapsed = epochTime() - started
      if not status.running:
        checkpoint("probe #" & $i & ": daemon stopped serving after a " &
          "connect-and-close probe; status handshake took " &
          $int(elapsed * 1000) & "ms")
        checkpoint(daemonLog(tempRoot))
      check status.running
      # A live daemon answers a local status handshake in single-digit
      # milliseconds. A wedged one answers only when the client gives up
      # after `UserDaemonHandshakeTimeoutMs`, so this also catches a daemon
      # that is technically alive but no longer scheduling `accept`.
      check elapsed < (UserDaemonHandshakeTimeoutMs.float / 1000.0) / 2.0

    check daemon.running()

  test "integration_daemon_survives_client_that_leaves_mid_handshake":
    ## The same dead-peer write, reached through a path the accept loop does
    ## NOT bound: a client that completes its half of the handshake and then
    ## goes away before the daemon answers. ``handleHello`` writes the
    ## hello-ack with the default (unbounded) timeout, as do the build and
    ## watch event streams — so this case covers the whole class of writes to
    ## a peer that has already gone, not just the accept loop's error reply.
    ## Any client that times out and exits, or that the user interrupts,
    ## leaves the daemon holding exactly this socket.
    let tempRoot = createTempDir("repro-daemon-halfshake", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)
    let endpoint = daemonEndpoint(tempRoot)

    for i in 1 .. 3:
      # Real protocol frame, real socket, then a real disconnect — the daemon
      # has a complete hello to parse and nobody left to send the ack to.
      var abandoning = connectIpc(endpoint)
      abandoning.writeFrame(udkHello, helloBody(
        binaryIdentity("repro", getAppFilename(), "test"),
        UserDaemonFeatureFlags, "status", ""))
      abandoning.closeIpcConn()

      let started = epochTime()
      let status = queryUserDaemonStatus(endpoint)
      let elapsed = epochTime() - started
      if not status.running:
        checkpoint("abandon #" & $i & ": daemon stopped serving after a " &
          "client left mid-handshake; status handshake took " &
          $int(elapsed * 1000) & "ms")
        checkpoint(daemonLog(tempRoot))
      check status.running
      check elapsed < (UserDaemonHandshakeTimeoutMs.float / 1000.0) / 2.0

    check daemon.running()

  test "integration_daemon_accept_loop_recovers_from_silent_client":
    ## A client that connects and then says nothing must not starve the
    ## other clients indefinitely: the loop's bounded request read drops it
    ## and returns to `accept`.
    let tempRoot = createTempDir("repro-daemon-silent", "")
    var daemon: owned(Process)
    defer:
      closeForegroundDaemon(daemon, tempRoot)
      removeDir(tempRoot)
    daemon = startForegroundDaemon(tempRoot)
    let endpoint = daemonEndpoint(tempRoot)

    # Connect and deliberately send nothing at all — no hello, no close.
    var silent = connectIpc(endpoint)
    defer: silent.closeIpcConn()

    # The loop must free itself within its own request-read bound. The budget
    # is that bound plus generous slack for a loaded CI host; it is well under
    # the point where a caller's readiness poll would give up.
    let recovered = waitForRunning(tempRoot,
      (ServerRequestReadTimeoutMs.float / 1000.0) + 20.0)
    if not recovered:
      checkpoint("daemon never returned to accept while a silent client " &
        "held the loop")
      checkpoint(daemonLog(tempRoot))
    check recovered
    check daemon.running()
