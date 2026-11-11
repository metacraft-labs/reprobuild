## On a POSIX host with no provisioned RunQuota service, every invocation of
## one user adopts ONE shared ``runquotad`` on that user's well-known
## endpoint, starting it when none is alive, and that daemon outlives the
## invocations and exits by itself once it has been idle.
##
## THE DEFECT THIS PINS (reprobuild-pm issue
## ``2026-11-05-auto-started-runquotad-is-private-per-invocation-instead-of-a-shared-idle-exit-daemon``).
## ``repro`` started a PRIVATE daemon for each top-level invocation, on a
## per-build socket in a fresh directory, and terminated it when the
## invocation ended. Two concurrent builds each leased against their own
## daemon, which saw only its own build, so RunQuota -- whose whole point is a
## global view of the host -- had none. ``repro exec`` stopped its daemon
## before running the command and restored the caller's ``RUNQUOTA_SOCKET``,
## so the command saw no daemon at all. The contract now is reprobuild-pm
## ``spec/RunQuota-Host-Configuration.md``, "The shared per-user daemon
## (POSIX)", whose test list this file implements:
##
##   * two sequential invocations and two concurrent ones use one daemon
##     (same pid);
##   * the daemon outlives the invocation and exits after the idle period;
##   * a stale socket left by a killed daemon is replaced;
##   * a directory owned by another uid, or with a wrong mode it cannot fix,
##     is refused;
##   * the error of a daemon that exits before listening carries its log.
##
## WHAT THIS RUNS. The real ``repro`` CLI (``REPROBUILD_REPRO``, default
## ``build/bin/repro``) running ``repro exec <tiny project> -- <this binary>
## --probe``: the real provider compile, the real ``runquotad`` (the one
## ``RUNQUOTAD_BIN`` / ``PATH`` / the sibling checkout resolves), real sockets
## and lock files. The command ``repro exec`` runs is this test binary in
## probe mode, which reports the endpoint it inherited, whether a daemon
## answers there, and which pid holds that endpoint's lifetime lock. The
## daemon's identity is read from the lifetime lock (``/proc/locks``), never
## from the socket file, because a daemon killed with ``SIGKILL`` leaves its
## socket behind (``repro_test_support/per_user_runquota``).
##
## ISOLATION. Every case names a scratch endpoint directory through
## ``RUNQUOTA_USER_ENDPOINT_DIR`` and stops, in a ``defer``, the daemon it
## caused to be started there. The real per-user endpoint is never touched:
## other processes of this uid may be using it.
##
## THE ONE FIXTURE THAT IS NOT A DAEMON. The last case sets ``RUNQUOTAD_BIN``
## to a shell script that writes more than 64 KiB to both streams and exits
## 23. It is not a fake daemon -- it implements no part of the protocol and
## nothing here pretends it does -- it is the smallest "``runquotad`` that
## exits before it listens", which a real daemon cannot be made to be with
## output of a chosen size.
##
## FALSIFIABILITY. Against reprobuild ``b50a8c9d6`` (the per-invocation
## daemon) the probe sees no ``RUNQUOTA_SOCKET`` at all (``repro exec``
## restored the caller's), no lifetime lock is held after ``repro`` exits, the
## endpoint directory override is ignored so no directory is refused, and the
## startup error names no ``runquotad.log``.
##
## LINUX ONLY for the pid comparisons: ``/proc/locks`` is the reader, and
## ``/proc/self/fd`` is the directory whose mode its owner cannot change.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/per_user_runquota
import repro_test_support/reasoned_skip
import runquota_client

const ProbeFlag = "--probe-shared-runquota"

when defined(posix):
  if paramCount() == 1 and paramStr(1) == ProbeFlag:
    # The command `repro exec` runs: what endpoint did the invocation publish,
    # does a daemon answer there, and which pid holds it.
    let socket = getEnv("RUNQUOTA_SOCKET", "")
    echo "probe-socket=" & socket
    echo "probe-scope=" & getEnv("RUNQUOTA_ENDPOINT_SCOPE", "")
    var reached = "no"
    if socket.len > 0:
      try:
        var client = runquota_client.connectDefault()
        client.close()
        reached = "yes"
      except CatchableError as error:
        reached = "no: " & error.msg
    echo "probe-reached=" & reached
    echo "probe-pid=" & (if socket.len > 0: $lifetimeLockHolderPid(socket)
                         else: "0")
    quit(0)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc probeValue(output, key: string): string =
  for line in output.splitLines():
    let stripped = line.strip()
    if stripped.startsWith(key & "="):
      return stripped[key.len + 1 .. ^1]
  ""

when defined(linux):
  import std/posix

  type Fixture = object
    scratch: string
    project: string
    endpointDir: string
    socket: string
    env: StringTableRef
    cli: string

  proc newFixture(): Fixture =
    result.cli = getEnv("REPROBUILD_REPRO", reproBinaryPath())
    requireHostBinary(result.cli)
    result.scratch = createTempDir("repro-shared-rq-", "")
    result.project = result.scratch / "project"
    createDir(result.project)
    writeFile(result.project / "repro.nim", "import repro_project_dsl\n" &
      "package fixture:\n  devEnv:\n    setEnv \"SHARED_RQ_CASE\", \"1\"\n")
    result.endpointDir = scratchUserEndpointDir()
    result.socket = userSocketIn(result.endpointDir)
    var env = newStringTable(modeCaseSensitive)
    for name, value in envPairs():
      if not name.startsWith("__REPRO_"):
        env[name] = value
    env["REPROBUILD_ACTION_CACHE_ROOT"] = result.scratch / "action-cache"
    env["XDG_CACHE_HOME"] = result.scratch / "user-cache"
    # `repro exec` compiles the recipe and keeps that compile's nimcache under
    # TMPDIR; inside the scratch it goes with the case instead of outliving
    # it. The endpoint directory is named explicitly below, so its socket
    # path does not depend on this.
    createDir(result.scratch / "tmp")
    env["TMPDIR"] = result.scratch / "tmp"
    env["REPRO_ACTION_CACHE_SHM"] = "0"
    env["REPRO_DAEMON"] = "off"
    env["REPROBUILD_AUTO_RUNQUOTA"] = "1"
    env["REPROBUILD_NO_RUNQUOTA"] = ""
    env["RUNQUOTA_USER_ENDPOINT_DIR"] = result.endpointDir
    env["RUNQUOTAD_BIN"] = requireRunQuotaDaemonBin(repoRoot())
    env["REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS"] = "600"
    # The caller selects nothing: the invocation must find the per-user
    # endpoint by itself.
    env.del("RUNQUOTA_SOCKET")
    env.del("RUNQUOTA_ENDPOINT_SCOPE")
    if not env.hasKey("REPRO_NIM_COMPILER") or
        env["REPRO_NIM_COMPILER"].len == 0:
      env["REPRO_NIM_COMPILER"] = findExe("nim", followSymlinks = false)
    if not env.hasKey("REPRO_BOOTSTRAP_CC") or
        env["REPRO_BOOTSTRAP_CC"].len == 0:
      env["REPRO_BOOTSTRAP_CC"] = findExe("cc", followSymlinks = false)
    result.env = env

  proc dispose(fixture: Fixture; startedPids: openArray[int]) =
    ## Stop the daemon this case caused to be started (the last pid it saw
    ## holding the lock is the one it may signal as a last resort), then
    ## remove the scratch tree.
    var started = 0
    for pid in startedPids:
      if pid > 0: started = pid
    stopUserDaemon(fixture.socket, started)
    removeDir(fixture.scratch)

  proc startExec(fixture: Fixture; outFile: string;
                 env: StringTableRef = nil): Process =
    ## `repro exec <project> -- <this binary> --probe`, stdout and stderr to
    ## `outFile`: a file, not a pipe, so two concurrent invocations cannot
    ## block on a pipe this case is not reading yet.
    let useEnv = if env == nil: fixture.env else: env
    startProcess("/bin/sh", workingDir = fixture.project,
      args = ["-c", "out=\"$1\"; shift; exec \"$@\" > \"$out\" 2>&1", "sh",
        outFile, fixture.cli, "exec", fixture.project, "--",
        getAppFilename(), ProbeFlag],
      env = useEnv, options = {})

  proc finishExec(process: Process; outFile: string):
      tuple[exitCode: int; output: string] =
    let code = process.waitForExit(900_000)
    if process.running:
      process.terminate()
      discard process.waitForExit()
    process.close()
    (exitCode: code,
     output: (if fileExists(outFile): readFile(outFile) else: ""))

  proc runExec(fixture: Fixture; tag: string;
               env: StringTableRef = nil): tuple[exitCode: int; output: string] =
    let outFile = fixture.scratch / ("exec-" & tag & ".out")
    finishExec(startExec(fixture, outFile, env), outFile)

  proc modeOf(path: string): int =
    var info: Stat
    doAssert lstat(path.cstring, info) == 0
    int(info.st_mode) and 0o7777

  proc envWith(fixture: Fixture; key, value: string): StringTableRef =
    result = newStringTable(modeCaseSensitive)
    for k, v in fixture.env:
      result[k] = v
    result[key] = value

  suite "the shared per-user runquotad":
    test "two sequential invocations use one daemon, which outlives them":
      let fixture = newFixture()
      var pids: seq[int]
      defer: dispose(fixture, pids)
      # Owned by this user with a mode the launcher must repair, not refuse.
      require posix.mkdir(fixture.endpointDir.cstring, Mode(0o755)) == 0
      require chmod(fixture.endpointDir.cstring, Mode(0o755)) == 0

      let first = runExec(fixture, "first")
      checkpoint("first: exit=" & $first.exitCode & "\n" & first.output)
      require first.exitCode == 0
      check probeValue(first.output, "probe-socket") == fixture.socket
      check probeValue(first.output, "probe-scope") == "private"
      check probeValue(first.output, "probe-reached") == "yes"
      let firstPid = parseInt(probeValue(first.output, "probe-pid"))
      pids.add(firstPid)
      check firstPid > 0
      check modeOf(fixture.endpointDir) == 0o700
      # OUTLIVES the invocation: `repro` has exited, the daemon has not.
      check lifetimeLockHolderPid(fixture.socket) == firstPid
      check pidAlive(firstPid)

      let second = runExec(fixture, "second")
      checkpoint("second: exit=" & $second.exitCode & "\n" & second.output)
      require second.exitCode == 0
      check probeValue(second.output, "probe-reached") == "yes"
      # The SAME daemon, adopted rather than restarted.
      check parseInt(probeValue(second.output, "probe-pid")) == firstPid
      check lifetimeLockHolderPid(fixture.socket) == firstPid

    test "two concurrent invocations start one daemon":
      let fixture = newFixture()
      var pids: seq[int]
      defer: dispose(fixture, pids)
      # Warm the provider compile first so the two invocations below race
      # for the daemon, not for the compile; then retire the daemon the
      # warm-up started, so the race starts with NO daemon alive.
      let warm = runExec(fixture, "warm")
      checkpoint("warm: exit=" & $warm.exitCode & "\n" & warm.output)
      require warm.exitCode == 0
      let warmPid = parseInt(probeValue(warm.output, "probe-pid"))
      pids.add(warmPid)
      stopUserDaemon(fixture.socket, warmPid)
      require not lifetimeLockHeld(fixture.socket)

      let outA = fixture.scratch / "exec-a.out"
      let outB = fixture.scratch / "exec-b.out"
      let a = startExec(fixture, outA)
      let b = startExec(fixture, outB)
      let ra = finishExec(a, outA)
      let rb = finishExec(b, outB)
      checkpoint("a: exit=" & $ra.exitCode & "\n" & ra.output)
      checkpoint("b: exit=" & $rb.exitCode & "\n" & rb.output)
      require ra.exitCode == 0
      require rb.exitCode == 0
      let pidA = parseInt(probeValue(ra.output, "probe-pid"))
      let pidB = parseInt(probeValue(rb.output, "probe-pid"))
      pids.add(pidA)
      check pidA > 0
      check pidA != warmPid
      check pidA == pidB
      check probeValue(ra.output, "probe-reached") == "yes"
      check probeValue(rb.output, "probe-reached") == "yes"
      check lifetimeLockHolderPid(fixture.socket) == pidA

    test "the daemon exits by itself after the idle period":
      let fixture = newFixture()
      var pids: seq[int]
      defer: dispose(fixture, pids)
      let env = envWith(fixture, "REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS", "3")
      let run = runExec(fixture, "idle", env)
      checkpoint("exit=" & $run.exitCode & "\n" & run.output)
      require run.exitCode == 0
      let pid = parseInt(probeValue(run.output, "probe-pid"))
      pids.add(pid)
      check pid > 0
      # Alive once `repro` has gone (it outlives the invocation) ...
      check lifetimeLockHolderPid(fixture.socket) == pid
      # ... and gone, with its socket, once nobody has connected for the
      # period. 60 s is the budget for a 3 s period on a loaded host.
      check waitLifetimeLockFree(fixture.socket, 60_000)
      # The daemon releases its lifetime lock as the last step of its
      # orderly shutdown, a moment BEFORE the process is gone; and once gone
      # it is reaped by whoever it was re-parented to. So the pid is waited
      # for, within the same budget, rather than read once.
      var waitedForExit = 0
      while pidAlive(pid) and waitedForExit < 60_000:
        sleep(50)
        waitedForExit += 50
      check not pidAlive(pid)
      check not socketPresent(fixture.socket)

    test "a stale socket left by a killed daemon is replaced":
      let fixture = newFixture()
      var pids: seq[int]
      defer: dispose(fixture, pids)
      let first = runExec(fixture, "before-kill")
      checkpoint("before kill: exit=" & $first.exitCode & "\n" & first.output)
      require first.exitCode == 0
      let killed = parseInt(probeValue(first.output, "probe-pid"))
      pids.add(killed)
      require killed > 0
      require lifetimeLockHolderPid(fixture.socket) == killed
      # This case's own invocation started it, so this case may kill it.
      require posix.kill(Pid(killed), SIGKILL) == 0
      require waitLifetimeLockFree(fixture.socket, 30_000)
      # The precondition the case is about: the socket is still there.
      require socketPresent(fixture.socket)

      let second = runExec(fixture, "after-kill")
      checkpoint("after kill: exit=" & $second.exitCode & "\n" & second.output)
      require second.exitCode == 0
      let replacement = parseInt(probeValue(second.output, "probe-pid"))
      pids.add(replacement)
      check replacement > 0
      check replacement != killed
      check probeValue(second.output, "probe-reached") == "yes"
      check lifetimeLockHolderPid(fixture.socket) == replacement

    test "a directory owned by another uid is refused":
      if geteuid() == 0:
        skip("running as root: root owns /tmp, so a directory owned by " &
          "another uid cannot be arranged without a second account")
      else:
        let fixture = newFixture()
        defer: dispose(fixture, [])
        # `/tmp` is root's: an existing directory this user does not own.
        let env = envWith(fixture, "RUNQUOTA_USER_ENDPOINT_DIR", "/tmp")
        let run = runExec(fixture, "foreign", env)
        checkpoint("exit=" & $run.exitCode & "\n" & run.output)
        check run.exitCode != 0
        check "per-user endpoint directory /tmp" in run.output
        check "is owned by uid 0" in run.output
        # Both remedies, as the specification requires.
        check "remove it" in run.output
        check "RUNQUOTA_USER_ENDPOINT_DIR" in run.output
        check "probe-socket=" notin run.output

    test "a directory with a wrong mode the user cannot fix is refused":
      if geteuid() == 0:
        skip("running as root: root can change the mode of /proc/self/fd, " &
          "so a mode the user cannot fix cannot be arranged")
      else:
        let fixture = newFixture()
        defer: dispose(fixture, [])
        # `/proc/self/fd` is owned by the process that resolves it, with mode
        # 0500, and the kernel refuses its owner a chmod.
        let env = envWith(fixture, "RUNQUOTA_USER_ENDPOINT_DIR",
          "/proc/self/fd")
        let run = runExec(fixture, "unfixable", env)
        checkpoint("exit=" & $run.exitCode & "\n" & run.output)
        check run.exitCode != 0
        check "per-user endpoint directory /proc/self/fd" in run.output
        check "cannot be set to 0700" in run.output
        check "RUNQUOTA_USER_ENDPOINT_DIR" in run.output
        check "probe-socket=" notin run.output

    test "the error of a daemon that exits before listening carries its log":
      let fixture = newFixture()
      defer: dispose(fixture, [])
      let refusing = fixture.scratch / "refusing-runquotad"
      writeFile(refusing, "#!/bin/sh\n" &
        "i=0; while [ $i -lt 4096 ]; do printf 'stdout-padding-0123456789\\n'; " &
        "printf 'stderr-padding-0123456789\\n' >&2; i=$((i+1)); done\n" &
        "printf 'specific startup stdout reason\\n'\n" &
        "printf 'specific startup stderr refusal\\n' >&2\nexit 23\n")
      setFilePermissions(refusing, {fpUserRead, fpUserWrite, fpUserExec})
      let env = envWith(fixture, "RUNQUOTAD_BIN", refusing)
      let run = runExec(fixture, "refusing", env)
      checkpoint("exit=" & $run.exitCode & "\n" & run.output)
      check run.exitCode != 0
      check "runquotad did not become reachable" in run.output
      check "runquotad.log" in run.output
      check "specific startup stdout reason" in run.output
      check "specific startup stderr refusal" in run.output
      # More than 64 KiB was written: the notice says what was dropped.
      check "truncated" in run.output
      check "probe-socket=" notin run.output
      # The log is where the specification puts it, and holds all of it.
      let log = fixture.endpointDir / "runquotad.log"
      check fileExists(log)
      if fileExists(log):
        check "specific startup stderr refusal" in readFile(log)
else:
  suite "the shared per-user runquotad":
    test "two sequential invocations use one daemon, which outlives them":
      skip("Linux only: the daemon's identity is read from /proc/locks")
