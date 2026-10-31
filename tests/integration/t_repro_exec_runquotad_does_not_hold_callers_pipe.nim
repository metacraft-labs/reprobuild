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
## exiting. Two controls keep that honest:
##
##   * The spawn arm really ran. The inner command is this binary in probe
##     mode, printing the `RUNQUOTA_SOCKET` it inherited. On POSIX the case
##     points `RUNQUOTA_SOCKET` at a path that does not exist, so both of
##     `startAutoRunQuotaIfNeeded`'s reachability early returns fall through,
##     and the probe must report a DIFFERENT socket: the per-invocation one the
##     spawned daemon bound. On Windows the case gives the invocation a private
##     `USERNAME`, so the per-user pipe name (`\\.\pipe\runquota-<USERNAME>`)
##     is one nothing else serves, and a daemon this case did not start cannot
##     be adopted instead.
##   * WINDOWS: the daemon is still running when EOF is seen. EOF because the
##     daemon had died would prove nothing. The case finds the daemon as the
##     server of that private pipe (`GetNamedPipeServerProcessId`), requires it
##     to be alive after EOF, and then terminates it.
##
## POSIX keeps a different lifetime rule: the daemon is OWNED by the
## invocation and stops with it (`t_auto_runquota_daemon_ends_with_its_invocation`
## grades that, and that its descriptors above 2 are not inherited). So on
## POSIX the daemon is gone by the time `repro` exits, and this case grades
## the property a caller observes -- prompt EOF on `repro exec`'s own output
## -- through the real CLI, without the "still running" control.
##
## MOCK POLICY -- NO MOCKS. The real `repro` CLI, a real recipe compiled by
## the real provider compile, the real `runquotad`, real OS pipes and the
## kernel's own pipe-server identity. Arranged rather than produced: the
## endpoint that forces the spawn arm, as described above.

import std/[monotimes, os, osproc, strtabs, strutils, tempfiles, times,
  unittest]

import repro_test_support
import repro_test_support/reasoned_skip

const
  ProbeFlag = "--print-runquota-endpoint"
  ExecDeadlineMs = 600_000
    ## A cold provider compile is tens of seconds; past this the case kills
    ## `repro` and fails rather than wedging the suite.
  EofBudgetMs = 5_000
    ## How long after `repro` exits the pipe may stay open. The fixed path
    ## reaches EOF as `repro` exits.

if paramCount() == 1 and paramStr(1) == ProbeFlag:
  # The inner command: report the endpoint the invocation published.
  echo "probe-runquota-socket=" & getEnv("RUNQUOTA_SOCKET", "")
  echo "probe-username=" & getEnv("USERNAME", "")
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

suite "repro exec stdio and the auto-started runquotad":
  test "repro exec's caller sees EOF once repro exits":
    if not runquotadAvailable():
      skip("no runquotad: set RUNQUOTAD_BIN or put runquotad on PATH " &
        "(the dev shell provides it)")
    else:
      # exec is handled by the engine; the thin client delegates this verb
      # to it (on POSIX by `execv`, so the process is the same one).
      let cli = requireHostBinary(reproBinaryPath(stem = "reprobuild"))
      let scratch = createTempDir("repro-exec-rq-pipe-", "")
      defer: removeDirEventually(scratch, attempts = 50, sleepMs = 100)
      let project = scratch / "project"
      createDir(project)
      writeFile(project / "repro.nim", "import repro_project_dsl\n" &
        "package fixture:\n  devEnv:\n    setEnv \"EXEC_PIPE_CASE\", \"1\"\n")

      var env = newStringTable(modeCaseSensitive)
      for name, value in envPairs():
        if not name.startsWith("__REPRO_"):
          env[name] = value
      env["REPROBUILD_ACTION_CACHE_ROOT"] = scratch / "action-cache"
      env["XDG_CACHE_HOME"] = scratch / "user-cache"
      env["LOCALAPPDATA"] = scratch / "user-cache"
      env["REPRO_ACTION_CACHE_SHM"] = "0"
      env["REPRO_DAEMON"] = "off"
      env["REPROBUILD_AUTO_RUNQUOTA"] = "1"
      if not env.hasKey("REPRO_NIM_COMPILER") or
          env["REPRO_NIM_COMPILER"].len == 0:
        env["REPRO_NIM_COMPILER"] = findExe("nim", followSymlinks = false)
      if not env.hasKey("REPRO_BOOTSTRAP_CC") or
          env["REPRO_BOOTSTRAP_CC"].len == 0:
        let cc = when defined(windows): "gcc" else: "cc"
        env["REPRO_BOOTSTRAP_CC"] = findExe(cc, followSymlinks = false)
      let bogusSocket = scratch / "no-such-runquota.sock"
      when defined(windows):
        # Alphanumeric, so runquota's pipe-name sanitising leaves it as is.
        let privateUser = "reproexecpipe" & $getCurrentProcessId()
        let privatePipe = r"\\.\pipe\runquota-" & privateUser
        env["USERNAME"] = privateUser
        env["RUNQUOTA_SOCKET"] = ""
        require pipeServerPid(privatePipe) == 0
      else:
        env["RUNQUOTA_SOCKET"] = bogusSocket

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
          # Control: the spawn arm ran and published the socket it bound.
          let published = probeValue(output, "probe-runquota-socket")
          check published.len > 0
          check published != bogusSocket
        check "probe-runquota-socket=" in output
        check state == psEof
      finally:
        when defined(windows):
          if daemonPid == 0:
            daemonPid = pipeServerPid(privatePipe)
          if daemonPid > 0:
            terminatePid(daemonPid)
        if invocation.running:
          killProcessTree(invocation.processID)
        invocation.close()
