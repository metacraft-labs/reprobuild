## A daemon's status record belongs to its ENDPOINT, and is found where the
## daemon wrote it.
##
## WHAT WENT WRONG. The record's path was derived twice. The writer used
## `config.stateDir / "status" / (safePathSegment(endpoint.extractFilename) &
## ".status")`; `statusFileForEndpoint` restated it rooted at
## `userDaemonStateDir()`, which knows nothing about `--state-dir`. And both
## kept only the endpoint's LAST COMPONENT. Endpoints live in per-run scratch
## directories precisely because the basename is not unique, so every
## `<run>/d.sock` daemon on one state directory shared the single record
## `d.sock.status`. `cleanupStaleUserDaemonDiscovery` -- which
## `startUserDaemon` runs for an endpoint that does not answer -- then deleted
## that file, i.e. a LIVE same-basename daemon's record.
##
## WHAT THESE CASES ASSERT. Every daemon here is a real `repro-daemon
## --foreground`: this binary re-executes itself in fixture mode and hands its
## arguments to `runUserDaemonCommand`, the function the `repro-daemon` entry
## point calls, so `--endpoint` and `--state-dir` go through the production
## flag parser. A stale daemon is made the way one is made in the field: the
## process is SIGKILLed, leaving its socket file and its record behind. The
## cases pin: a stale sibling's discovery cleanup leaves a live daemon's record
## alone and still removes the stale one's; a daemon started with a non-default
## `--state-dir` wrote its record exactly where `statusFileForEndpoint(stateDir,
## endpoint)` says; and a LEGACY basename-keyed record left by an older daemon
## is removed only when it names the stale endpoint itself.
##
## The survival cases find a daemon's record by scanning the status directory
## for one whose `endpoint=` line names it, not by asking the naming proc, so
## they are statements about what is on disk rather than about this file's
## arithmetic.
##
## WHY THERE IS NO "ONE DAEMON EXITS WHILE ITS SIBLING RUNS" CASE. Two daemons
## cannot be live on one state directory at once: `acquireUserDaemonLock`
## flocks `<stateDir>/.repro-daemon.lock` before the daemon touches its record,
## and the second one exits with "user daemon lock is held". The last case pins
## that, because it is what keeps the exit-path `removeEndpointFiles` from ever
## meeting a live sibling's record; the reachable collision is the stale
## cleanup above.
##
## MOCK POLICY: no mocks. Real daemon processes, real sockets, a real kill, and
## the exported cleanup entry point the CLI calls. Every daemon this file starts
## is killed in a `defer`.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_daemon_core

const FixtureFlag = "--daemon-fixture"

if paramCount() >= 1 and paramStr(1) == FixtureFlag:
  # `repro-daemon --foreground <flags>`, in this process.
  var args = @["--foreground"]
  for i in 2 .. paramCount():
    args.add(paramStr(i))
  quit(runUserDaemonCommand(args))

when defined(posix):
  type Daemon = object
    process: Process
    endpoint: string

  proc startDaemon(endpoint, stateDir: string): Daemon =
    ## A real daemon on ``endpoint`` with ``--state-dir stateDir``, returned
    ## once it answers a status handshake.
    result.endpoint = endpoint
    result.process = startProcess(getAppFilename(),
      args = [FixtureFlag, "--endpoint", endpoint, "--state-dir", stateDir],
      options = {poParentStreams})
    discard waitForUserDaemonStatus(endpoint, 30_000)

  proc killDaemon(daemon: var Daemon) =
    ## SIGKILL: no defer runs, so the socket file and the record stay behind,
    ## which is how a stale daemon arises.
    if daemon.process != nil:
      if daemon.process.running:
        daemon.process.kill()
      discard daemon.process.waitForExit()
      daemon.process.close()
      daemon.process = nil

  proc stopDaemon(daemon: var Daemon) =
    if daemon.process != nil:
      try:
        requestUserDaemonShutdown(daemon.endpoint)
      except CatchableError:
        discard
      daemon.killDaemon()

  proc configFor(endpoint, stateDir: string): UserDaemonConfig =
    result = defaultUserDaemonConfig()
    result.endpoint = endpoint
    result.stateDir = stateDir
    result.logPath = stateDir / "logs" / "repro-daemon.log"

  proc recordsNaming(stateDir, endpoint: string): seq[string] =
    ## Every status record under ``stateDir`` whose ``endpoint=`` line is
    ## exactly ``endpoint``.
    let dir = stateDir / "status"
    if not dirExists(dir):
      return
    for path in walkFiles(dir / "*.status"):
      if ("endpoint=" & endpoint) in readFile(path).splitLines():
        result.add(path)

  proc writeLegacyRecord(stateDir, basename, endpoint: string): string =
    ## A record as an older-generation daemon wrote it: keyed on the basename.
    result = stateDir / "status" / (basename & ".status")
    createDir(parentDir(result))
    writeFile(result, "role=" & UserDaemonRole & "\nendpoint=" & endpoint &
      "\nstateDir=" & stateDir & "\npid=1\n")

  # The lease reaper reads a lease store outside the scratch directory; these
  # cases have no leases and must not touch one.
  putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "0")

  suite "a daemon status record identifies the endpoint, not its basename":
    test "a stale same-basename sibling's cleanup keeps the live daemon's record":
      let scratch = createTempDir("repro-status-", "")
      defer: removeDir(scratch)
      let stateDir = scratch / "state"
      let liveEndpoint = scratch / "a" / "d.sock"
      let staleEndpoint = scratch / "b" / "d.sock"
      var stale = startDaemon(staleEndpoint, stateDir)
      defer: stale.killDaemon()
      check recordsNaming(stateDir, staleEndpoint).len == 1
      stale.killDaemon()
      # Premise: what the kill left is stale in exactly the sense the cleanup
      # gates on -- the socket file is there and nothing answers it.
      check userDaemonEndpointExists(staleEndpoint)
      check not userDaemonEndpointAcceptsConnections(staleEndpoint)

      var live = startDaemon(liveEndpoint, stateDir)
      defer: live.stopDaemon()
      check recordsNaming(stateDir, liveEndpoint).len == 1

      # What `startUserDaemon` runs before relaunching the stale endpoint.
      check cleanupStaleUserDaemonDiscovery(configFor(staleEndpoint, stateDir))

      checkpoint("status dir: " & $toSeq(walkFiles(stateDir / "status" /
        "*.status")))
      check queryUserDaemonStatus(liveEndpoint).running
      check recordsNaming(stateDir, liveEndpoint).len == 1
      # ...and the cleanup still does its job for the stale endpoint.
      check recordsNaming(stateDir, staleEndpoint).len == 0
      check not userDaemonEndpointExists(staleEndpoint)

      live.stopDaemon()
      check recordsNaming(stateDir, liveEndpoint).len == 0

    test "under --state-dir the record is where statusFileForEndpoint says":
      let scratch = createTempDir("repro-status-", "")
      defer: removeDir(scratch)
      let stateDir = scratch / "override-state"
      let endpoint = scratch / "run" / "d.sock"
      check stateDir != userDaemonStateDir()
      var daemon = startDaemon(endpoint, stateDir)
      defer: daemon.stopDaemon()
      let path = statusFileForEndpoint(stateDir, endpoint)
      checkpoint("reader path: " & path)
      checkpoint("records on disk: " & $recordsNaming(stateDir, endpoint))
      check fileExists(path)
      if fileExists(path):
        let lines = readFile(path).splitLines()
        check ("endpoint=" & endpoint) in lines
        check ("stateDir=" & stateDir) in lines
        check ("pid=" & $daemon.process.processID) in lines
      check recordsNaming(stateDir, endpoint) == @[path]

    test "stale cleanup removes a legacy record that names the stale endpoint":
      let scratch = createTempDir("repro-status-", "")
      defer: removeDir(scratch)
      let stateDir = scratch / "state"
      let endpoint = scratch / "b" / "d.sock"
      let legacy = writeLegacyRecord(stateDir, "d.sock", endpoint)
      check not userDaemonEndpointAcceptsConnections(endpoint)
      check cleanupStaleUserDaemonDiscovery(configFor(endpoint, stateDir))
      check not fileExists(legacy)

    test "stale cleanup keeps a legacy record that names another endpoint":
      # The legacy name is shared by every `d.sock`; only its contents say
      # whose it is, and it may belong to a live older-generation daemon.
      let scratch = createTempDir("repro-status-", "")
      defer: removeDir(scratch)
      let stateDir = scratch / "state"
      let endpoint = scratch / "b" / "d.sock"
      let legacy = writeLegacyRecord(stateDir, "d.sock", scratch / "a" /
        "d.sock")
      discard cleanupStaleUserDaemonDiscovery(configFor(endpoint, stateDir))
      check fileExists(legacy)

    test "cleanup keeps a legacy record for an endpoint that is live":
      let scratch = createTempDir("repro-status-", "")
      defer: removeDir(scratch)
      let stateDir = scratch / "state"
      let endpoint = scratch / "b" / "d.sock"
      var daemon = startDaemon(endpoint, stateDir)
      defer: daemon.stopDaemon()
      let legacy = writeLegacyRecord(stateDir, "d.sock", endpoint)
      discard cleanupStaleUserDaemonDiscovery(configFor(endpoint, stateDir))
      check fileExists(legacy)

    test "a second daemon on a live daemon's state dir is refused":
      # The premise of the header's last paragraph.
      let scratch = createTempDir("repro-status-", "")
      defer: removeDir(scratch)
      let stateDir = scratch / "state"
      let liveEndpoint = scratch / "a" / "d.sock"
      var live = startDaemon(liveEndpoint, stateDir)
      defer: live.stopDaemon()
      let second = execCmdEx(quoteShellCommand([getAppFilename(), FixtureFlag,
        "--endpoint", scratch / "b" / "d.sock", "--state-dir", stateDir]))
      checkpoint(second.output)
      check second.exitCode != 0
      check "lock is held" in second.output
      check queryUserDaemonStatus(liveEndpoint).running
      check recordsNaming(stateDir, liveEndpoint).len == 1
