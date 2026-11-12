## `repro exec -- <cmd>` does not leave its caller's output pipe open after it
## exits, even though it started a `runquotad`.
##
## THE DEFECT THIS PINS (reprobuild-pm issue 2026-10-23, "on Windows the
## auto-started runquotad inherits `repro exec`'s stdout and stderr"). Every
## verb that computes a dev environment starts a `runquotad` when none is
## reachable. On Windows that daemon binds the shared per-user pipe and is
## deliberately left running when `repro` exits, and it was started through
## `osproc.startProcess`, which calls `CreateProcessW` with
## `bInheritHandles = TRUE` and no handle list. The daemon therefore held a
## copy of every inheritable handle `repro` had, including the write end of
## the pipe its caller was reading. `$(repro exec ...)` never returned, and
## every Windows CI job that ran it hung until its job timeout.
##
## THE SHAPE OF THE CASE IS THE SHAPE OF THE INCIDENT:
##
##   this test (the `$(...)` role: reads stdout+stderr to EOF)
##     └─ repro exec <project> -- <this binary in probe mode>  (the engine image)
##          └─ runquotad (auto-started; on Windows, left running)
##
## The case requires the pipe to reach EOF within `EofBudgetMs` of `repro`
## exiting. EOF because the daemon had died would prove nothing, so on every
## platform the daemon this invocation started must still be running when EOF
## is seen:
##
##   * POSIX: the daemon is the SHARED PER-USER one (reprobuild-pm
##     `spec/RunQuota-Host-Configuration.md`, "The shared per-user daemon
##     (POSIX)"), and it outlives the invocation by design. The case names a
##     scratch endpoint directory through `RUNQUOTA_USER_ENDPOINT_DIR`, so the
##     invocation must START a daemon there (nothing else serves it), and after
##     EOF it requires that daemon to hold the endpoint's lifetime lock and be
##     alive. The daemon is then stopped the way an operator would
##     (`RetireDaemon`), never left behind.
##   * WINDOWS: the case gives the invocation a private `USERNAME`, so the
##     per-user pipe name (`\\.\pipe\runquota-<USERNAME>`) is one nothing
##     else serves, and a daemon this case did not start cannot be adopted
##     instead. It finds the daemon as the server of that private pipe
##     (`GetNamedPipeServerProcessId`), requires it to be alive after EOF, and
##     then terminates it.
##
## AND THE COMMAND SEES THE SHARED ENDPOINT (POSIX). `repro exec` no longer
## stops its daemon before `execve` or restores the caller's
## `RUNQUOTA_SOCKET`: the command it runs inherits the per-user socket and
## `RUNQUOTA_ENDPOINT_SCOPE=private`, and reaches a serving daemon through
## them. The command is this binary in probe mode, which reports both. A
## second case passes a BOGUS inherited `RUNQUOTA_SOCKET` (a path nothing
## serves): the invocation recovers to the per-user daemon, and the command
## sees the per-user socket rather than the bogus one. Until 2026-11-11 the
## POSIX daemon was owned by the invocation and stopped with it, and the
## command inherited the caller's endpoint.
##
## MOCK POLICY -- NO MOCKS. The real `repro` CLI, a real recipe compiled by
## the real provider compile, the real `runquotad`, real OS pipes, real lock
## files and the kernel's own pipe-server identity. Arranged rather than
## produced: the private endpoint (directory or pipe name) that forces a
## start, as described above.

import std/[monotimes, os, osproc, strtabs, strutils, tempfiles, times,
  unittest]

import repro_test_support
import repro_test_support/reasoned_skip
when defined(posix):
  import repro_test_support/per_user_runquota
  import runquota_client

const
  ProbeFlag = "--print-runquota-endpoint"
  ExecDeadlineMs = 600_000
    ## A cold provider compile is tens of seconds; past this the case kills
    ## `repro` and fails rather than wedging the suite.
  EofBudgetMs = 5_000
    ## How long after `repro` exits the pipe may stay open. The fixed path
    ## reaches EOF as `repro` exits.

if paramCount() == 1 and paramStr(1) == ProbeFlag:
  # The inner command: report the endpoint the invocation published, and
  # (POSIX) whether a daemon answers there.
  echo "probe-runquota-socket=" & getEnv("RUNQUOTA_SOCKET", "")
  echo "probe-runquota-scope=" & getEnv("RUNQUOTA_ENDPOINT_SCOPE", "")
  echo "probe-username=" & getEnv("USERNAME", "")
  when defined(posix):
    var reached = "no"
    if getEnv("RUNQUOTA_SOCKET", "").len > 0:
      try:
        var client = runquota_client.connectDefault()
        client.close()
        reached = "yes"
      except CatchableError as error:
        reached = "no: " & error.msg
    echo "probe-runquota-reached=" & reached
  quit(0)

proc nowMs(): int64 = getMonoTime().ticks div 1_000_000

type PipeState = enum
  psEof, psOpen

when defined(windows):
  import std/winlean

  const
    ErrorBrokenPipe = 109
    ErrorPipeBusy = 231
    ProcessTerminate = 0x0001'i32
    ProcessQueryLimitedInformation = 0x1000'i32
    StillActive = 259'i32

  proc getNamedPipeServerProcessId(pipe: Handle; serverPid: ptr uint32):
      WINBOOL {.stdcall, dynlib: "kernel32",
        importc: "GetNamedPipeServerProcessId".}

  proc drainUntilEof(handle: FileHandle; timeoutMs: int;
                     collected: var string): PipeState =
    ## Read the pipe until every writer has closed it (EOF, which a pipe
    ## reports as ERROR_BROKEN_PIPE) or `timeoutMs` passes with a writer
    ## still holding it. PeekNamedPipe bounds every wait.
    let pipe = Handle(handle)
    let deadline = nowMs() + timeoutMs
    var buffer: array[4096, char]
    while true:
      var available: int32 = 0
      if not peekNamedPipe(pipe, nil, 0, nil, addr available, nil):
        let error = osLastError()
        if error.int32 == ErrorBrokenPipe:
          return psEof
        raiseOSError(error, "PeekNamedPipe on repro exec's stdout")
      if available > 0:
        var got: int32 = 0
        if readFile(pipe, addr buffer[0], int32(buffer.len), addr got,
            nil) != 0 and got > 0:
          for i in 0 ..< int(got):
            collected.add buffer[i]
        continue
      if nowMs() >= deadline:
        return psOpen
      sleep(50)

  proc pipeServerPid(pipePath: string): int =
    ## The pid serving `pipePath`, or 0 when nothing serves it.
    for _ in 0 ..< 40:
      let h = createFileW(newWideCString(pipePath),
        GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0)
      if h == INVALID_HANDLE_VALUE:
        if osLastError().int32 == ErrorPipeBusy:
          sleep(50)
          continue
        return 0
      var pid: uint32 = 0
      let ok = getNamedPipeServerProcessId(h, addr pid)
      discard closeHandle(h)
      return (if ok != 0: int(pid) else: 0)
    0

  proc processAlive(pid: int): bool =
    let h = openProcess(ProcessQueryLimitedInformation, 0, DWORD(pid))
    if h == 0:
      return false
    defer: discard closeHandle(h)
    var code: int32 = 0
    getExitCodeProcess(h, code) != 0 and code == StillActive

  proc terminatePid(pid: int) =
    let h = openProcess(ProcessTerminate, 0, DWORD(pid))
    if h != 0:
      discard terminateProcess(h, 1)
      discard closeHandle(h)
else:
  import std/posix

  proc drainUntilEof(handle: FileHandle; timeoutMs: int;
                     collected: var string): PipeState =
    ## Read the pipe until every writer has closed it (`read` returns 0) or
    ## `timeoutMs` passes with a writer still holding it. `poll` bounds every
    ## wait.
    let fd = cint(handle)
    let deadline = nowMs() + timeoutMs
    var buffer: array[4096, char]
    while true:
      let remaining = max(0'i64, deadline - nowMs())
      var pfd = TPollfd(fd: fd, events: POLLIN)
      let ready = posix.poll(addr pfd, 1, cint(min(remaining, 200'i64)))
      if ready > 0:
        let got = posix.read(fd, addr buffer[0], buffer.len)
        if got == 0:
          return psEof
        if got > 0:
          for i in 0 ..< got:
            collected.add buffer[i]
          continue
        if errno != EINTR:
          raiseOSError(osLastError(), "read on repro exec's stdout")
      if nowMs() >= deadline:
        return psOpen

proc killProcessTree(pid: int) =
  try:
    when defined(windows):
      let taskkill = findExe("taskkill")
      if taskkill.len > 0:
        discard execCmdEx(quoteShellCommand([taskkill, "/F", "/T", "/PID", $pid]))
    else:
      discard posix.kill(Pid(pid), SIGKILL)
  except CatchableError:
    discard

proc runquotadAvailable(): bool =
  let pinned = getEnv("RUNQUOTAD_BIN", "")
  (pinned.len > 0 and fileExists(pinned)) or findExe("runquotad").len > 0

proc probeValue(output, key: string): string =
  for line in output.splitLines():
    let stripped = line.strip()
    if stripped.startsWith(key & "="):
      return stripped[key.len + 1 .. ^1]
  ""

proc execEnvironment(scratch: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for name, value in envPairs():
    if not name.startsWith("__REPRO_"):
      result[name] = value
  result["REPROBUILD_ACTION_CACHE_ROOT"] = scratch / "action-cache"
  result["XDG_CACHE_HOME"] = scratch / "user-cache"
  result["LOCALAPPDATA"] = scratch / "user-cache"
  result["REPRO_ACTION_CACHE_SHM"] = "0"
  result["REPRO_DAEMON"] = "off"
  result["REPROBUILD_AUTO_RUNQUOTA"] = "1"
  if not result.hasKey("REPRO_NIM_COMPILER") or
      result["REPRO_NIM_COMPILER"].len == 0:
    result["REPRO_NIM_COMPILER"] = findExe("nim", followSymlinks = false)
  if not result.hasKey("REPRO_BOOTSTRAP_CC") or
      result["REPRO_BOOTSTRAP_CC"].len == 0:
    let cc = when defined(windows): "gcc" else: "cc"
    result["REPRO_BOOTSTRAP_CC"] = findExe(cc, followSymlinks = false)

proc runExecAndGradeEof(inheritedSocket: string) =
  ## One `repro exec` with this case as its `$(...)` caller. On POSIX
  ## `inheritedSocket` is the `RUNQUOTA_SOCKET` the caller passes ("" for
  ## none); Windows ignores it and uses its private pipe.
  # exec is handled by the engine; the thin client delegates this verb to it
  # (on POSIX by `execv`, so the process is the same one). `REPROBUILD_REPRO`
  # points the case at another build of the same pair.
  let cli = getEnv("REPROBUILD_REPRO", reproBinaryPath(stem = "reprobuild"))
  requireHostBinary(cli)
  let scratch = createTempDir("repro-exec-rq-pipe-", "")
  defer: removeDirEventually(scratch, attempts = 50, sleepMs = 100)
  let project = scratch / "project"
  createDir(project)
  writeFile(project / "repro.nim", "import repro_project_dsl\n" &
    "package fixture:\n  devEnv:\n    setEnv \"EXEC_PIPE_CASE\", \"1\"\n")
  var env = execEnvironment(scratch)
  when defined(windows):
    discard inheritedSocket
    # Alphanumeric, so runquota's pipe-name sanitising leaves it as is.
    let privateUser = "reproexecpipe" & $getCurrentProcessId()
    let privatePipe = r"\\.\pipe\runquota-" & privateUser
    env["USERNAME"] = privateUser
    env["RUNQUOTA_SOCKET"] = ""
    require pipeServerPid(privatePipe) == 0
  else:
    # A scratch per-user endpoint: nothing serves it, so the invocation has
    # to START the daemon there, and the real per-user daemon of this uid
    # (which other processes may be using) is never touched.
    let endpointDir = scratchUserEndpointDir()
    let userSocket = userSocketIn(endpointDir)
    env["RUNQUOTA_USER_ENDPOINT_DIR"] = endpointDir
    env["RUNQUOTAD_BIN"] = requireRunQuotaDaemonBin(getCurrentDir())
    env.del("RUNQUOTA_ENDPOINT_SCOPE")
    if inheritedSocket.len > 0:
      env["RUNQUOTA_SOCKET"] = inheritedSocket
    else:
      env.del("RUNQUOTA_SOCKET")

  # The `$(...)` role: stdout and stderr on ONE pipe this case reads.
  let invocation = startProcess(cli, workingDir = project,
    args = ["exec", project, "--", getAppFilename(), ProbeFlag],
    env = env, options = {poStdErrToStdOut})
  var daemonPid = 0
  try:
    let pipe = invocation.outputHandle
    var output = ""
    var state = psOpen
    let execDeadline = nowMs() + ExecDeadlineMs
    while invocation.running and nowMs() < execDeadline:
      state = drainUntilEof(pipe, 200, output)
      if state == psEof:
        break
    # EOF can be seen a moment before the exit is observable.
    while invocation.running and nowMs() < execDeadline:
      sleep(20)
    let execExit = invocation.peekExitCode()
    if execExit == -1:
      killProcessTree(invocation.processID)
    checkpoint("repro exec exit=" & $execExit & ", output:\n" & output)
    require execExit == 0

    # THE PROPERTY. `repro` is gone; only a process it left behind could
    # still hold the write end.
    let eofWait = nowMs()
    if state != psEof:
      state = drainUntilEof(pipe, EofBudgetMs, output)
    checkpoint("pipe " & $state & " " & $(nowMs() - eofWait) &
      " ms after repro exec exited; output:\n" & output)

    when defined(windows):
      daemonPid = pipeServerPid(privatePipe)
      checkpoint("runquotad serving " & privatePipe & ": pid " &
        $daemonPid)
      # Control: the daemon this invocation started is still running, so
      # the EOF is not the daemon having died.
      check daemonPid > 0
      check daemonPid > 0 and processAlive(daemonPid)
      check probeValue(output, "probe-username") == privateUser
    else:
      # Control: the daemon this invocation started at the scratch endpoint
      # is still running, so the EOF is not the daemon having died.
      check lifetimeLockHeld(userSocket)
      daemonPid = lifetimeLockHolderPid(userSocket)
      checkpoint("runquotad holding " & userSocket & ": pid " & $daemonPid)
      when defined(linux):
        check daemonPid > 0 and pidAlive(daemonPid)
      # The command inherited the SHARED endpoint -- not the caller's bogus
      # one, not nothing -- and a daemon answers there.
      check probeValue(output, "probe-runquota-socket") == userSocket
      check probeValue(output, "probe-runquota-scope") == "private"
      check probeValue(output, "probe-runquota-reached") == "yes"
    check "probe-runquota-socket=" in output
    check state == psEof
  finally:
    when defined(windows):
      if daemonPid == 0:
        daemonPid = pipeServerPid(privatePipe)
      if daemonPid > 0:
        terminatePid(daemonPid)
    else:
      stopUserDaemon(userSocket, daemonPid)
    if invocation.running:
      killProcessTree(invocation.processID)
    invocation.close()

suite "repro exec stdio and the auto-started runquotad":
  test "repro exec's caller sees EOF once repro exits":
    if not runquotadAvailable():
      skip("no runquotad: set RUNQUOTAD_BIN or put runquotad on PATH " &
        "(the dev shell provides it)")
    else:
      runExecAndGradeEof("")

  test "the command reaches the shared daemon although the caller passed a bogus socket":
    when defined(windows):
      skip("the per-user POSIX endpoint only; Windows clears RUNQUOTA_SOCKET")
    else:
      if not runquotadAvailable():
        skip("no runquotad: set RUNQUOTAD_BIN or put runquotad on PATH " &
          "(the dev shell provides it)")
      else:
        runExecAndGradeEof(getTempDir() / ("no-such-runquota-" &
          $getCurrentProcessId() & ".sock"))
