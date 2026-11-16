## Running one apply action as a child process with a deadline, its output
## in a file rather than a pipe, and its whole process tree killed when the
## deadline passes.
##
## WHY THIS EXISTS — win-ci-bare-001, 2026-11-15
## =============================================
##
## The deploy agent (`repro deploy-agent`, a Task Scheduler task every 10
## minutes) ran the elevated Python tool-cache seed through
## `runInlineExecCall`. The binary on the box was reprobuild `39ad8158`, whose
## spawn read the child's merged stdout+stderr pipe with ONE `readAll` and then
## called `waitForExit`. On Windows that `readAll` returns after the first
## `ReadFile` that does not fill its buffer (see
## `repro_core/process_streams`), so the agent stopped reading after the first
## few bytes. CPython's `setup.ps1` then wrote ~805 KB into a pipe nobody was
## reading, blocked once the pipe buffer was full, and the agent waited on it
## with no deadline. The tick never ended, the task refused every later run
## with 0x800710E0, and the runner it had drained stayed stopped for ~21 h.
##
## `6b3f6099c` had already replaced that `readAll` with `drainStream`, which
## reads to EOF, so a current build does not deadlock on a chatty child. Two
## defects remained, and both have the same outcome — a tick that never ends:
##
##   * nothing bounded the wait. A child that hangs for any other reason (a
##     prompt, a locked file, a network call without a timeout) held the
##     agent forever;
##   * `drainStream` returns only when EVERY write handle to the pipe is
##     closed. A child that exits while a descendant still holds its stdout
##     (a service it started, a straggling installer) holds the agent until
##     that descendant exits, which may be never.
##
## So this runner does not use a pipe at all. The child's stdout and stderr go
## to a temp FILE, which can never fill up and does not care who still has it
## open; stdin is the null device, so a child that reads stdin sees EOF at
## once instead of waiting on a pipe the parent never writes or closes. After
## the child exits, or after the deadline, the tail of that file is the
## captured output.
##
## THE DEADLINE KILLS THE TREE, NOT THE CHILD
## ==========================================
##
## Killing only the direct child is what Task Scheduler did when the 5-hour
## task limit fired on the same box: `repro.exe` went away and the seed's
## PowerShell wrapper stayed behind, blocked. So:
##
##   * Windows: the child is created SUSPENDED, assigned to a Job Object, and
##     only then resumed, so every descendant it starts is in the job from its
##     first instruction. At the deadline `TerminateJobObject` kills all of
##     them. If the job cannot be created or assigned (it can be refused when
##     the agent's own job forbids nesting), the tree is walked by parent pid
##     instead, in-process, which misses only descendants whose parent has
##     already exited.
##   * POSIX: the child is the leader of a new process group, and the deadline
##     sends SIGKILL to the group.
##
## Descendants that are still running when the child exits ON TIME are left
## alone. The job has no KILL_ON_JOB_CLOSE limit on purpose: an action may
## legitimately start something meant to outlive it, and killing that on a
## successful exit would be a new failure mode, not a fix.

import std/[os, strtabs, strutils, times]

when defined(windows):
  import std/winlean
else:
  import std/posix

type
  BoundedExecOutcome* = object
    exitCode*: int
      ## The child's exit code. Meaningless when ``timedOut``.
    timedOut*: bool
      ## The deadline passed and the process tree was killed.
    killNote*: string
      ## How the tree was killed, for the diagnostic. Empty unless
      ## ``timedOut``.
    outputTail*: string
      ## The last ``tailBytes`` bytes the child (and any descendant sharing
      ## its stdout/stderr) wrote.
    outputBytes*: int64
      ## The total number of bytes written to the output file.
    elapsedMs*: int64

  BoundedExecError* = object of CatchableError
    ## The child could not be started at all.

proc readFileTail(path: string; tailBytes: int): tuple[tail: string; size: int64] =
  ## The last ``tailBytes`` bytes of ``path`` and the file's size. A missing or
  ## unreadable file reads as empty: the capture is diagnostic, and failing the
  ## action because its log could not be read would replace the real outcome.
  try:
    var f: File
    if not open(f, path, fmRead):
      return ("", 0'i64)
    defer: close(f)
    let size = getFileSize(f)
    let start = max(0'i64, size - int64(tailBytes))
    setFilePos(f, start)
    var buf = newString(int(size - start))
    if buf.len > 0:
      let got = readChars(f, toOpenArray(buf, 0, buf.len - 1))
      buf.setLen(got)
    result = (buf, size)
  except CatchableError:
    result = ("", 0'i64)

proc newSinkPath(): string =
  let dir = getTempDir()
  result = dir / ("repro-inline-exec-" & $getCurrentProcessId() & "-" &
    $int64(epochTime() * 1_000_000.0) & ".log")

# ---------------------------------------------------------------------------
# Windows.
# ---------------------------------------------------------------------------

when defined(windows):
  const
    CreateSuspendedFlag = 0x00000004'i32

  proc createJobObjectW(lpJobAttributes: pointer; lpName: WideCString): Handle {.
    stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}
  proc assignProcessToJobObject(hJob, hProcess: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}
  proc terminateJobObject(hJob: Handle; uExitCode: uint32): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}

  const
    Th32csSnapProcess = 0x00000002'i32
    ProcessTerminateRight = 0x0001'i32

  type
    ProcessEntry32W {.pure.} = object
      dwSize: int32
      cntUsage: int32
      th32ProcessID: int32
      th32DefaultHeapID: uint
      th32ModuleID: int32
      cntThreads: int32
      th32ParentProcessID: int32
      pcPriClassBase: int32
      dwFlags: int32
      szExeFile: array[260, Utf16Char]

  proc createToolhelp32Snapshot(dwFlags, th32ProcessID: int32): Handle {.
    stdcall, dynlib: "kernel32", importc: "CreateToolhelp32Snapshot".}
  proc process32FirstW(hSnapshot: Handle; lppe: var ProcessEntry32W): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "Process32FirstW".}
  proc process32NextW(hSnapshot: Handle; lppe: var ProcessEntry32W): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "Process32NextW".}

  proc killTreeByParentPid(root: int32): int =
    ## The fallback when there is no job: walk the process table by parent
    ## pid and terminate every descendant of ``root``, deepest first. It
    ## misses only descendants whose parent has already exited (their parent
    ## pid then names nobody, or a reused pid). Done in-process rather than by
    ## running `taskkill /T`, which would resolve a binary from PATH.
    ## Returns how many processes were terminated.
    var parents: seq[(int32, int32)] = @[]
    let snap = createToolhelp32Snapshot(Th32csSnapProcess, 0)
    if snap == INVALID_HANDLE_VALUE:
      return 0
    var e = ProcessEntry32W(dwSize: int32(sizeof(ProcessEntry32W)))
    if process32FirstW(snap, e) != 0:
      while true:
        parents.add((e.th32ProcessID, e.th32ParentProcessID))
        if process32NextW(snap, e) == 0:
          break
    discard closeHandle(snap)
    var tree = @[root]
    var i = 0
    while i < tree.len:
      for (pid, ppid) in parents:
        if ppid == tree[i] and pid != root and pid notin tree:
          tree.add(pid)
      inc i
    for j in countdown(tree.high, 0):
      let h = openProcess(ProcessTerminateRight, 0, DWORD(tree[j]))
      if h != 0:
        if terminateProcess(h, 1) != 0:
          inc result
        discard closeHandle(h)

  proc windowsCommandLine(argv: openArray[string]): string =
    for i, arg in argv:
      if i > 0:
        result.add(' ')
      result.add(quoteShellWindows(arg))

  proc windowsEnvBlock(env: StringTableRef): string =
    ## A CREATE_UNICODE_ENVIRONMENT block, before UTF-16 conversion:
    ## `NAME=VALUE\0` ... `\0`.
    var s = ""
    for k, v in env.pairs:
      s.add(k)
      s.add('=')
      s.add(v)
      s.add('\0')
    s.add('\0')
    result = s

  proc runBoundedWindows(argv: seq[string]; cwd: string; env: StringTableRef;
                         timeoutMs: int; sinkPath: string;
                         tailBytes: int): BoundedExecOutcome =
    var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil, bInheritHandle: 1)
    let sink = createFileW(newWideCString(sinkPath), GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, addr sa,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    if sink == INVALID_HANDLE_VALUE:
      raise newException(BoundedExecError, "cannot create output file " &
        sinkPath & ": " & osErrorMsg(osLastError()))
    let nul = createFileW(newWideCString("NUL"), GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE, addr sa, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0)
    if nul == INVALID_HANDLE_VALUE:
      discard closeHandle(sink)
      raise newException(BoundedExecError, "cannot open NUL for stdin: " &
        osErrorMsg(osLastError()))

    var si = STARTUPINFO(cb: int32(sizeof(STARTUPINFO)),
      dwFlags: STARTF_USESTDHANDLES, hStdInput: nul, hStdOutput: sink,
      hStdError: sink)
    var pi: PROCESS_INFORMATION
    # The UTF-16 buffers are owned here and outlive the call; the raw
    # pointers CreateProcessW takes are borrowed from them. A nil environment
    # block means "inherit", a nil directory "the parent's".
    var cmdObj = newWideCString(windowsCommandLine(argv))
    var envObj, cwdObj: WideCStringObj
    var envBlock: WideCString = nil
    var cwdW: WideCString = nil
    if env != nil:
      envObj = newWideCString(windowsEnvBlock(env))
      envBlock = toWideCString(envObj)
    if cwd.len > 0:
      cwdObj = newWideCString(cwd)
      cwdW = toWideCString(cwdObj)
    let cmdLine = toWideCString(cmdObj)
    var flags = CreateSuspendedFlag
    if env != nil:
      flags = flags or CREATE_UNICODE_ENVIRONMENT
    let started = createProcessW(nil, cmdLine, nil, nil, 1, flags,
      envBlock, cwdW, si, pi)
    let startErr = osLastError()
    # The child has its own copies now; the parent must not keep the sink
    # open, or nothing about the file's lifetime would depend on the child.
    discard closeHandle(sink)
    discard closeHandle(nul)
    if started == 0:
      raise newException(BoundedExecError, "CreateProcessW failed for `" &
        argv.join(" ") & "`: " & osErrorMsg(startErr))
    defer:
      discard closeHandle(pi.hThread)
      discard closeHandle(pi.hProcess)

    # Into the job BEFORE the first instruction runs, so no descendant can be
    # started outside it.
    var job = createJobObjectW(nil, nil)
    var inJob = false
    var jobNote = ""
    if job == 0:
      jobNote = "CreateJobObject failed: " & osErrorMsg(osLastError())
    else:
      inJob = assignProcessToJobObject(job, pi.hProcess) != 0
      if not inJob:
        jobNote = "AssignProcessToJobObject refused: " &
          osErrorMsg(osLastError())
        discard closeHandle(job)
        job = 0
    defer:
      if job != 0:
        discard closeHandle(job)
    discard resumeThread(pi.hThread)

    let t0 = epochTime()
    let waitMs = if timeoutMs > 0: int32(min(timeoutMs, int(high(int32) - 1)))
                 else: INFINITE
    let waited = waitForSingleObject(pi.hProcess, waitMs)
    if waited == WAIT_TIMEOUT:
      result.timedOut = true
      if inJob and terminateJobObject(job, 1'u32) != 0:
        result.killNote = "TerminateJobObject killed the action's job"
      else:
        if jobNote.len == 0:
          jobNote = "TerminateJobObject failed: " & osErrorMsg(osLastError())
        # The tree walk needs the intermediate processes to be alive, which
        # they are: the direct child has not exited.
        let killed = killTreeByParentPid(pi.dwProcessId)
        discard terminateProcess(pi.hProcess, 1)
        result.killNote = "terminated " & $killed &
          " process(es) found by parent pid, because " & jobNote
      discard waitForSingleObject(pi.hProcess, 30_000)
    var code: int32
    if getExitCodeProcess(pi.hProcess, code) != 0:
      result.exitCode = int(code)
    else:
      result.exitCode = -1
    result.elapsedMs = int64((epochTime() - t0) * 1000.0)
    let (tail, size) = readFileTail(sinkPath, tailBytes)
    result.outputTail = tail
    result.outputBytes = size

# ---------------------------------------------------------------------------
# POSIX.
# ---------------------------------------------------------------------------

else:
  proc resolveExecutable(name: string; env: StringTableRef): string =
    ## `poUsePath` semantics: a bare name is looked up on PATH — the child's
    ## PATH when the action carries an environment, the agent's otherwise.
    if '/' in name:
      return name
    let path =
      if env != nil and env.hasKey("PATH"): env["PATH"]
      else: getEnv("PATH")
    for dir in path.split(PathSep):
      if dir.len == 0:
        continue
      let candidate = dir / name
      if fileExists(candidate) and access(candidate.cstring, X_OK) == 0:
        return candidate
    return name

  proc runBoundedPosix(argv: seq[string]; cwd: string; env: StringTableRef;
                       timeoutMs: int; sinkPath: string;
                       tailBytes: int): BoundedExecOutcome =
    let exe = resolveExecutable(argv[0], env)
    # Everything the child touches is prepared before fork: between fork and
    # exec only async-signal-safe calls are allowed, and an allocation is not
    # one (another thread may hold the allocator's lock at the fork).
    let cArgv = allocCStringArray(argv)
    defer: deallocCStringArray(cArgv)
    var envList: seq[string] = @[]
    if env != nil:
      for k, v in env.pairs:
        envList.add(k & "=" & v)
    let cEnv = if env != nil: allocCStringArray(envList) else: nil
    defer:
      if cEnv != nil: deallocCStringArray(cEnv)
    let cExe = exe.cstring
    let cCwd = cwd.cstring
    let hasCwd = cwd.len > 0

    let sinkFd = posix.open(sinkPath.cstring,
      O_WRONLY or O_CREAT or O_TRUNC or O_CLOEXEC, 0o600)
    if sinkFd < 0:
      raise newException(BoundedExecError, "cannot create output file " &
        sinkPath & ": " & osErrorMsg(osLastError()))
    let nullFd = posix.open("/dev/null", O_RDONLY or O_CLOEXEC)
    if nullFd < 0:
      discard posix.close(sinkFd)
      raise newException(BoundedExecError, "cannot open /dev/null: " &
        osErrorMsg(osLastError()))

    let t0 = epochTime()
    let pid = fork()
    if pid < 0:
      let err = osLastError()
      discard posix.close(sinkFd)
      discard posix.close(nullFd)
      raise newException(BoundedExecError, "fork failed for `" &
        argv.join(" ") & "`: " & osErrorMsg(err))
    if pid == 0:
      # Child. A process group of its own, so the deadline can kill the tree.
      discard setpgid(0, 0)
      discard dup2(nullFd, 0)
      discard dup2(sinkFd, 1)
      discard dup2(sinkFd, 2)
      if hasCwd and chdir(cCwd) != 0:
        exitnow(126)
      if cEnv != nil:
        discard execve(cExe, cArgv, cEnv)
      else:
        discard execv(cExe, cArgv)
      exitnow(127)
    # Parent. Set the group here too: whichever of the two runs first wins,
    # and a kill(-pid) before the child's own setpgid must still find it.
    discard setpgid(pid, pid)
    discard posix.close(sinkFd)
    discard posix.close(nullFd)

    var status: cint
    var reaped = false
    var sleepMs = 5
    while true:
      let r = waitpid(pid, status, WNOHANG)
      if r == pid:
        reaped = true
        break
      if r < 0 and errno != EINTR:
        break
      if timeoutMs > 0 and (epochTime() - t0) * 1000.0 >= float(timeoutMs):
        break
      sleep(sleepMs)
      sleepMs = min(sleepMs * 2, 100)
    if not reaped:
      result.timedOut = true
      discard kill(-pid, SIGKILL)
      discard kill(pid, SIGKILL)
      result.killNote = "SIGKILL to process group " & $pid
      while waitpid(pid, status, 0) < 0 and errno == EINTR:
        discard
    if WIFEXITED(status):
      result.exitCode = int(WEXITSTATUS(status))
    elif WIFSIGNALED(status):
      result.exitCode = 128 + int(WTERMSIG(status))
    else:
      result.exitCode = -1
    result.elapsedMs = int64((epochTime() - t0) * 1000.0)
    let (tail, size) = readFileTail(sinkPath, tailBytes)
    result.outputTail = tail
    result.outputBytes = size

proc runBoundedExec*(argv: seq[string]; cwd = ""; env: StringTableRef = nil;
                     timeoutMs = 0; tailBytes = 4096;
                     sinkPath = ""): BoundedExecOutcome =
  ## Run ``argv`` with stdout and stderr going to a file and stdin from the
  ## null device, wait at most ``timeoutMs`` (``<= 0``: no deadline), and on
  ## the deadline kill the whole process tree. ``env == nil`` inherits the
  ## caller's environment; otherwise ``env`` is the child's whole
  ## environment. A bare ``argv[0]`` is looked up on PATH.
  ##
  ## ``sinkPath`` names the output file; by default a fresh file in the temp
  ## directory, removed afterwards. A caller-supplied file is kept.
  ##
  ## Raises ``BoundedExecError`` only when the child cannot be started. A
  ## timeout is reported in the result, not raised: the caller decides what an
  ## action that ran out of time means.
  if argv.len == 0:
    raise newException(BoundedExecError, "runBoundedExec: empty argv")
  let ownSink = sinkPath.len == 0
  let sink = if ownSink: newSinkPath() else: sinkPath
  try:
    when defined(windows):
      result = runBoundedWindows(argv, cwd, env, timeoutMs, sink, tailBytes)
    else:
      result = runBoundedPosix(argv, cwd, env, timeoutMs, sink, tailBytes)
  finally:
    if ownSink:
      # A descendant that outlived the child may still hold the file open on
      # Windows, which refuses the delete; a leftover temp file is harmless.
      try: removeFile(sink) except CatchableError: discard
