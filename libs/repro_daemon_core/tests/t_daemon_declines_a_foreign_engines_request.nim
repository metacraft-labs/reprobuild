## A per-user daemon must not serve a build or watch for an engine that is not
## its own image.
##
## reprobuild-pm issue 2026-10-16 ("A `repro build --dry-run` routed to the
## shared per-user daemon failed with `unsupported interface envelope
## version`"). Every checkout on a host talks to ONE per-user endpoint. A
## client makes sure that daemon is its own build by comparing image digests
## in `startUserDaemon`, and restarts it when they differ -- but that check
## runs BEFORE the request is sent. Another workspace whose reprobuild is a
## different build does the same check against the same endpoint, finds the
## daemon "outdated" from ITS point of view, and restarts it onto its own
## engine. A request sent in that window is served by the other workspace's
## engine, which then reads this checkout's build state: interface artifacts
## written by this checkout's newer engine carry an envelope version the older
## engine does not know, and the build fails with `unsupported interface
## envelope version` -- a fail-closed check doing its job on data it should
## never have been handed.
##
## The client cannot close that window from its side: whatever it checks, the
## daemon can be swapped after the check. The daemon can close it, because the
## request names the engine it was sent for (`publicCliPath`). These cases
## pin that a request naming a DIFFERENT image is declined as unsupported with
## fallback allowed (`reason: engine-mismatch`) before it is accepted, so the
## client falls back to its own engine; that a request naming the daemon's own
## image is still accepted; and that a request naming no image (an older
## client) is still accepted, since nothing proves a mismatch.
##
## WITHOUT THE FIX the foreign-image cases fail: the daemon accepts the request
## (a `bekAccepted` event is streamed) and the terminal event is the worker's
## "executor is not registered" answer, not an engine-mismatch decline.
##
## MOCK POLICY: no mocks. Each daemon is a real `repro-daemon --foreground`:
## this binary re-executes itself in fixture mode and hands its arguments to
## `runUserDaemonCommand`, so the daemon's own image IS this test binary. The
## "foreign engine" is a real file whose bytes differ from it. Requests travel
## over the real socket through the same client procs `repro` uses. No build
## executor is registered in the fixture daemon, which is what makes an
## ACCEPTED request observable without running a build.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_daemon_core

const FixtureFlag = "--daemon-fixture"

if paramCount() >= 1 and paramStr(1) == FixtureFlag:
  var args = @["--foreground"]
  for i in 2 .. paramCount():
    args.add(paramStr(i))
  quit(runUserDaemonCommand(args))

when defined(posix):
  type Daemon = object
    process: Process
    endpoint: string

  proc startDaemon(endpoint, stateDir: string): Daemon =
    result.endpoint = endpoint
    result.process = startProcess(getAppFilename(),
      args = [FixtureFlag, "--endpoint", endpoint, "--state-dir", stateDir],
      options = {poParentStreams})
    discard waitForUserDaemonStatus(endpoint, 30_000)

  proc stopDaemon(daemon: var Daemon) =
    if daemon.process != nil:
      try:
        requestUserDaemonShutdown(daemon.endpoint)
      except CatchableError:
        discard
      if daemon.process.running:
        daemon.process.kill()
      discard daemon.process.waitForExit()
      daemon.process.close()
      daemon.process = nil

  proc foreignEngineCopy(dir: string): string =
    ## Another build of the engine: an executable whose bytes differ from the
    ## daemon's running image.
    result = dir / "other-engine"
    copyFile(getAppFilename(), result)
    let f = open(result, fmAppend)
    f.write("\0another build")
    f.close()
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  var runCounter = 0
  proc nextRunNumber(): int =
    inc runCounter
    runCounter

  proc buildRequest(workDir, publicCliPath: string): UserDaemonBuildRequest =
    UserDaemonBuildRequest(runId: "engine-mismatch-" & $getCurrentProcessId() &
      "-" & $nextRunNumber(),
      workingDir: workDir, projectRoot: workDir,
      publicCliPath: publicCliPath, rawArgs: @["--dry-run", "."],
      attached: true, cancelOnDisconnect: true)

  proc watchRequest(workDir, publicCliPath: string): UserDaemonWatchRequest =
    UserDaemonWatchRequest(runId: "engine-mismatch-watch-" &
      $getCurrentProcessId() & "-" & $nextRunNumber(),
      workingDir: workDir, projectRoot: workDir,
      publicCliPath: publicCliPath, rawArgs: @["."],
      attached: true, cancelOnDisconnect: true, maxCycles: 1)

  proc kinds(events: seq[UserDaemonBuildEvent]): seq[UserDaemonBuildEventKind] =
    for e in events:
      result.add(e.kind)

  proc terminalOf(events: seq[UserDaemonBuildEvent]): UserDaemonBuildEvent =
    for e in events:
      if e.terminal:
        return e

  # No lease store is involved; keep the reaper off it.
  putEnv("REPRO_DAEMON_LEASE_REAP_INTERVAL_MS", "0")

  suite "a daemon declines a request sent for another engine":
    var scratch, endpoint: string
    var daemon: Daemon
    setup:
      scratch = createTempDir("repro-eng-", "")
      endpoint = scratch / "d.sock"
      daemon = startDaemon(endpoint, scratch / "state")
    teardown:
      daemon.stopDaemon()
      removeDir(scratch)

    test "a build request naming a different engine image is declined":
      let other = foreignEngineCopy(scratch)
      let res = requestUserDaemonBuild(buildRequest(scratch, other), endpoint)
      checkpoint("events: " & $kinds(res.events))
      let terminal = terminalOf(res.events)
      checkpoint("terminal: " & terminal.message & " " & terminal.payloadJson)
      check not res.supported
      check terminal.kind == bekUnsupported
      check "\"fallbackAllowed\":true" in terminal.payloadJson
      check "\"reason\":\"engine-mismatch\"" in terminal.payloadJson
      check bekAccepted notin kinds(res.events)

    test "a build request naming the daemon's own image is accepted":
      let res = requestUserDaemonBuild(
        buildRequest(scratch, getAppFilename()), endpoint)
      checkpoint("events: " & $kinds(res.events))
      let terminal = terminalOf(res.events)
      checkpoint("terminal: " & terminal.message & " " & terminal.payloadJson)
      check bekAccepted in kinds(res.events)
      check "engine-mismatch" notin terminal.payloadJson
      # The fixture registers no executor: an accepted request ends here.
      check "executor is not registered" in terminal.message

    test "a watch request naming a different engine image is declined":
      let other = foreignEngineCopy(scratch)
      let res = requestUserDaemonWatchStart(watchRequest(scratch, other),
        endpoint)
      checkpoint("events: " & $kinds(res.events))
      let terminal = terminalOf(res.events)
      checkpoint("terminal: " & terminal.message & " " & terminal.payloadJson)
      check not res.supported
      check terminal.kind == bekUnsupported
      check "\"fallbackAllowed\":true" in terminal.payloadJson
      check "\"reason\":\"engine-mismatch\"" in terminal.payloadJson
      check bekAccepted notin kinds(res.events)

    test "a request naming no engine image is not declined":
      # An older client sends no `publicCliPath`; nothing proves a mismatch,
      # so the daemon serves it exactly as before.
      let res = requestUserDaemonBuild(buildRequest(scratch, ""), endpoint)
      checkpoint("events: " & $kinds(res.events))
      let terminal = terminalOf(res.events)
      check bekAccepted in kinds(res.events)
      check "engine-mismatch" notin terminal.payloadJson
