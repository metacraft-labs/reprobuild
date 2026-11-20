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
## request states the digest of the engine it was sent for (`engineDigest`,
## the digest the client's staleness check compared). These cases pin that a
## request stating a DIFFERENT engine is declined as unsupported with
## fallback allowed (`reason: engine-mismatch`) before it is accepted, so the
## client falls back to its own engine; that a request stating the daemon's
## own engine is still accepted.
##
## THE PATH DOES NOT DECIDE (reprobuild-pm issue 2026-11-16, "The daemon
## identifies a request's engine by a path it may see differently";
## reprobuild-pm `spec/Local-Daemons-And-Control-Plane.md` §"A Daemon Serves
## Only Its Own Engine"). The daemon used to digest the file it found at the
## request's `publicCliPath`. A daemon whose filesystem view differs from the
## client's (a service manager mounting a different `/home`) can find a
## different file there, and when that file is a copy of its own image it
## served a request from another engine. The confirmation case runs the
## daemon in a private mount namespace (`unshare -Urm`, no root needed) where
## the client's engine path is bind-mounted over by a copy of the daemon's
## own image, and asserts the request is declined. Its companions: a request
## whose path IS a copy of the daemon's image but whose stated digest is
## another engine's is declined, and a request stating the daemon's own
## digest is served whatever its path says.
##
## THE CHECK FAILS CLOSED (reprobuild-pm issue 2026-11-16, "The daemon serves
## a build or watch request whose engine identity is unknown";
## `spec/Failure-Semantics.md` §"General Rules"). The daemon serves only when
## BOTH digests are known and equal. A request that states no digest (a
## client that predates `engineDigest`, whose body ends before it) and a
## daemon that cannot digest its own running image are declined the same way
## with `reason: engine-unknown`, carrying only the digests that are known,
## and with no session record created. A current client always states its
## digest, so these cases speak the raw protocol through the same request
## procs with the field emptied, or send a body truncated before it.
##
## WITHOUT THE FIX the namespace case and the copied-image case fail: the
## daemon digests the file it sees at `publicCliPath`, finds its own image,
## and accepts the request (a `bekAccepted` event is streamed).

## MOCK POLICY: no mocks. Each daemon is a real `repro daemon serve
## --foreground`: this binary re-executes itself in fixture mode, reads its
## arguments through repro's generated parser (`userDaemonConfigOfArgs`) and
## runs the daemon, so the daemon's own image IS this test binary. The
## "foreign engine" is a real file whose bytes differ from it. Requests travel
## over the real socket through the same client procs `repro` uses. No build
## executor is registered in the fixture daemon, which is what makes an
## ACCEPTED request observable without running a build.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_daemon_core
from repro_cli_support/daemon_cli import userDaemonConfigOfArgs
import repro_test_support/reasoned_skip

const FixtureFlag = "--daemon-fixture"

if paramCount() >= 1 and paramStr(1) == FixtureFlag:
  # `repro daemon serve --foreground <flags>`, in this process: the flags
  # read by repro's generated parser into the configuration `repro daemon
  # serve` runs (`userDaemonConfigOfArgs`).
  quit(runUserDaemonForeground(userDaemonConfigOfArgs(
    @["daemon", "serve", "--foreground"] & commandLineParams()[1 .. ^1])))

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

  proc privateMountTools(): tuple[unshare, mount: string] =
    ## `unshare` and the util-linux `mount` beside it, or "" for each that is
    ## missing. The `mount` on PATH may be a setuid wrapper (NixOS
    ## `/run/wrappers`), which refuses to run inside a user namespace, so the
    ## one shipped with `unshare` is preferred.
    result.unshare = findExe("unshare")
    if result.unshare.len == 0:
      return
    let sibling = parentDir(expandFilename(result.unshare)) / "mount"
    result.mount =
      if fileExists(sibling): sibling
      else: findExe("mount")

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

  proc startDaemonSeeing(endpoint, stateDir, path, replacement: string;
                         tools: tuple[unshare, mount: string]): Daemon =
    ## A fixture daemon in a private user+mount namespace in which `path`
    ## shows the bytes of `replacement`: the daemon and its clients see
    ## different files at one path, as under a service manager that mounts
    ## a different `/home`. The socket's directory is shared, so the client
    ## outside reaches it. `unshare` execs the shell, which execs the daemon,
    ## so the process handle is the daemon itself.
    result.endpoint = endpoint
    let script = quoteShell(tools.mount) & " --bind " &
      quoteShell(replacement) & " " & quoteShell(path) & " && exec " &
      quoteShellCommand([getAppFilename(), FixtureFlag, "--endpoint",
        endpoint, "--state-dir", stateDir])
    result.process = startProcess(tools.unshare,
      args = ["-Urm", "--", "/bin/sh", "-c", script],
      options = {poParentStreams})
    try:
      discard waitForUserDaemonStatus(endpoint, 30_000)
    except CatchableError:
      # The caller never receives the handle, so its teardown cannot stop a
      # daemon that comes up late: stop it here before re-raising.
      result.stopDaemon()
      raise

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

  proc ownDigest(): string =
    ## The daemon's running digest: the fixture daemon's image is this binary.
    imageDigestHex(getAppFilename())

  proc buildRequest(workDir, publicCliPath, engineDigest: string):
      UserDaemonBuildRequest =
    UserDaemonBuildRequest(runId: "engine-mismatch-" & $getCurrentProcessId() &
      "-" & $nextRunNumber(),
      workingDir: workDir, projectRoot: workDir,
      publicCliPath: publicCliPath, engineDigest: engineDigest,
      rawArgs: @["--dry-run", "."],
      attached: true, cancelOnDisconnect: true)

  proc watchRequest(workDir, publicCliPath, engineDigest: string):
      UserDaemonWatchRequest =
    UserDaemonWatchRequest(runId: "engine-mismatch-watch-" &
      $getCurrentProcessId() & "-" & $nextRunNumber(),
      workingDir: workDir, projectRoot: workDir,
      publicCliPath: publicCliPath, engineDigest: engineDigest,
      rawArgs: @["."],
      attached: true, cancelOnDisconnect: true, maxCycles: 1)

  proc sendRawBuildBody(endpoint: string; body: seq[byte]):
      seq[UserDaemonBuildEvent] =
    ## `requestUserDaemonBuild` with a hand-made body, for a client whose
    ## request ends before a field the current encoder always writes.
    var socket = connectUserDaemon(endpoint, commandMode = "build",
      requiredFeatures = ["build-routing", "build-events"])
    defer: socket.closeIpcConn()
    socket.writeFrame(udkBuildRequest, body)
    while true:
      let frame = socket.readFrame()
      doAssert frame.kind == udkBuildEvent, "unexpected frame " & $frame.kind
      let event = parseBuildEventBody(frame.body)
      result.add(event)
      if event.terminal:
        return

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

    # A template, not a proc: `check` must expand inside the test so a
    # failure marks the test failed rather than only setting the exit code.
    template checkMismatchDecline(res: untyped) =
      checkpoint("events: " & $kinds(res.events))
      let terminal = terminalOf(res.events)
      checkpoint("terminal: " & terminal.message & " " & terminal.payloadJson)
      check not res.supported
      check terminal.kind == bekUnsupported
      check terminal.exitCode == 64
      check "\"fallbackAllowed\":true" in terminal.payloadJson
      check "\"reason\":\"engine-mismatch\"" in terminal.payloadJson
      check bekAccepted notin kinds(res.events)
      check requestUserDaemonSessions(endpoint).len == 0

    template checkServed(res: untyped) =
      checkpoint("events: " & $kinds(res.events))
      let terminal = terminalOf(res.events)
      checkpoint("terminal: " & terminal.message & " " & terminal.payloadJson)
      check bekAccepted in kinds(res.events)
      check "engine-mismatch" notin terminal.payloadJson
      check "engine-unknown" notin terminal.payloadJson
      # The fixture registers no executor: an accepted request ends here.
      check "executor is not registered" in terminal.message

    test "a build request stating a different engine's digest is declined":
      let other = foreignEngineCopy(scratch)
      let res = requestUserDaemonBuild(
        buildRequest(scratch, other, imageDigestHex(other)), endpoint)
      checkMismatchDecline(res)

    test "a build request stating the daemon's own digest is accepted":
      let res = requestUserDaemonBuild(
        buildRequest(scratch, getAppFilename(), ownDigest()), endpoint)
      checkServed(res)

    test "a watch request stating a different engine's digest is declined":
      let other = foreignEngineCopy(scratch)
      let res = requestUserDaemonWatchStart(
        watchRequest(scratch, other, imageDigestHex(other)), endpoint)
      checkMismatchDecline(res)

    test "a request whose path is a copy of the daemon's image but whose digest is another engine's is declined":
      # The path names bytes identical to the daemon's own image; the engine
      # the client actually runs is another. Digesting the path would serve
      # it. The stated digest decides.
      let ownCopy = scratch / "own-copy"
      copyFile(getAppFilename(), ownCopy)
      let other = foreignEngineCopy(scratch)
      let res = requestUserDaemonBuild(
        buildRequest(scratch, ownCopy, imageDigestHex(other)), endpoint)
      checkMismatchDecline(res)

    test "a request stating the daemon's own digest is served whatever its path says":
      # The path no longer decides identity, so a relative, missing or
      # different path with the right digest is served.
      checkServed(requestUserDaemonBuild(buildRequest(scratch,
        extractFilename(getAppFilename()), ownDigest()), endpoint))
      checkServed(requestUserDaemonBuild(buildRequest(scratch,
        scratch / "no-such-engine", ownDigest()), endpoint))
      checkServed(requestUserDaemonBuild(buildRequest(scratch,
        foreignEngineCopy(scratch), ownDigest()), endpoint))

    # A template, not a proc: see `checkMismatchDecline`.
    template checkUnknownDecline(events: seq[UserDaemonBuildEvent]) =
      checkpoint("events: " & $kinds(events))
      let terminal = terminalOf(events)
      checkpoint("terminal: " & terminal.message & " " & terminal.payloadJson)
      check terminal.kind == bekUnsupported
      check terminal.exitCode == 64
      check "\"fallbackAllowed\":true" in terminal.payloadJson
      check "\"reason\":\"engine-unknown\"" in terminal.payloadJson
      # The daemon knows its own digest in this fixture; the request stated
      # none.
      check "\"daemonImageHash\":\"" in terminal.payloadJson
      check "\"requestImageHash\":\"" notin terminal.payloadJson
      check bekAccepted notin kinds(events)
      check requestUserDaemonSessions(endpoint).len == 0

    test "a build request stating no engine digest is declined as unknown":
      # Its path is the daemon's own image, which used to be enough. An
      # identity nobody stated proves nothing, so the request is not served.
      let res = requestUserDaemonBuild(
        buildRequest(scratch, getAppFilename(), ""), endpoint)
      check not res.supported
      checkUnknownDecline(res.events)

    test "a watch request stating no engine digest is declined as unknown":
      let res = requestUserDaemonWatchStart(
        watchRequest(scratch, getAppFilename(), ""), endpoint)
      check not res.supported
      checkUnknownDecline(res.events)

    test "a build body from a client before engineDigest is declined as unknown":
      # The body ends after `environmentIsComplete`, as an older client's
      # does: the empty digest's encoding (a zero u32 length) is cut off.
      let body = buildRequestBody(
        buildRequest(scratch, getAppFilename(), ""))
      checkUnknownDecline(sendRawBuildBody(endpoint, body[0 ..< body.len - 4]))

  suite "a daemon that sees a different file at the client's engine path":
    # The confirmation of reprobuild-pm issue 2026-11-16 ("The daemon
    # identifies a request's engine by a path it may see differently").
    var scratch, endpoint: string
    var daemon: Daemon
    setup:
      scratch = createTempDir("repro-eng-ns-", "")
      endpoint = scratch / "d.sock"
    teardown:
      daemon.stopDaemon()
      removeDir(scratch)

    test "a request is declined although the daemon's view of its path is the daemon's own image":
      let tools = privateMountTools()
      # Probe exactly what the fixture does: bind one file over another.
      # (A directory bind of a mount the namespace inherited locked fails
      # with EINVAL, so `/` would be a false negative.)
      writeFile(scratch / "probe-a", "a")
      writeFile(scratch / "probe-b", "b")
      let probe =
        if tools.unshare.len == 0 or tools.mount.len == 0: -1
        else: execCmd(quoteShellCommand([tools.unshare, "-Urm", "--",
          tools.mount, "--bind", scratch / "probe-a", scratch / "probe-b"]))
      if probe != 0:
        skip("an unprivileged user+mount namespace is unavailable here " &
          "(unshare=" & tools.unshare & " mount=" & tools.mount & ")")
      else:
        # Outside, the client's engine is another build; inside the daemon's
        # namespace the same path shows a copy of the daemon's own image.
        let clientEngine = foreignEngineCopy(scratch)
        let ownCopy = scratch / "own-copy"
        copyFile(getAppFilename(), ownCopy)
        daemon = startDaemonSeeing(endpoint, scratch / "state", clientEngine,
          ownCopy, tools)
        let res = requestUserDaemonBuild(buildRequest(scratch, clientEngine,
          imageDigestHex(clientEngine)), endpoint)
        checkpoint("events: " & $kinds(res.events))
        let terminal = terminalOf(res.events)
        checkpoint("terminal: " & terminal.message & " " &
          terminal.payloadJson)
        check not res.supported
        check terminal.kind == bekUnsupported
        check "\"reason\":\"engine-mismatch\"" in terminal.payloadJson
        check bekAccepted notin kinds(res.events)

  suite "the engine verdict fails closed on an unknown identity":
    # A daemon that cannot digest its own running image cannot be produced
    # through the fixture daemon (its image is this readable test binary), so
    # this drives the daemon's own verdict proc with the empty running digest
    # it would hold in that state.
    test "a daemon that cannot digest its own image declines":
      let verdict = foreignEngineVerdict(ownDigest(), "")
      check verdict.decline
      check verdict.reason == "engine-unknown"
      check verdict.requestImageHash.len > 0
      check verdict.daemonImageHash.len == 0

    test "known and equal digests are served":
      let verdict = foreignEngineVerdict(ownDigest(), ownDigest())
      check not verdict.decline
      check verdict.reason == ""

    test "the stated digest is what the client's staleness check expects":
      # `expectedUserDaemonDigest` is the value a client puts in
      # `engineDigest`. It must equal the running digest of a daemon started
      # from that image, or every routed request would be declined.
      var config = defaultUserDaemonConfig(devMode = true)
      let scratch = createTempDir("repro-eng-", "")
      defer: removeDir(scratch)
      config.stateDir = scratch / "state"
      check expectedUserDaemonDigest(getAppFilename(), config) == ownDigest()
      config.devMode = false
      check expectedUserDaemonDigest(getAppFilename(), config) == ownDigest()
      check expectedUserDaemonDigest(scratch / "missing", config) == ""
