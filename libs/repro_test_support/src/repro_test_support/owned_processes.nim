## Stop the processes a test started, and only those.
##
## THE RULE. Test code signals only what it started: a PID it holds, or a
## process group or session it created. It never kills by name or by
## command-line pattern (``pkill``, ``pkill -f``, ``killall``). On a shared
## host a pattern matches every other session's process of the same shape --
## an ``ah-cli`` test's ``pkill -f`` killed two agent sessions on 2026-11-13,
## and this repository's own ``pkill -f <socket path>`` cleanups stopped every
## concurrent run's helper (reprobuild-pm issue 2026-11-13, "reprobuild tests
## and committed root scripts kill processes by pattern").
## ``scripts/check_pattern_kills.py`` refuses the pattern shapes; this module
## is what to use instead when the process to stop was started by the PRODUCT
## on the test's behalf, so the test never held its handle:
##
## * ``stopUnixSocketServer(socketPath)`` -- a helper daemon the product
##   spawned on a socket path the test chose. The process to stop is the one
##   listening on that socket, read from the KERNEL through the peer
##   credentials of a connection to it (``SO_PEERCRED`` on Linux,
##   ``LOCAL_PEERPID`` on macOS), not from a process table scan. A path that
##   nothing listens on stops nothing.
##
## * ``installSetsidRecorder(binDir, record)`` + ``stopRecordedSessions`` --
##   a command the product DETACHES with ``setsid`` (the post-commit cache
##   push). Once detached it is nobody's child, so neither a handle nor
##   parentage reaches it. The recorder is a ``setsid`` shim placed first on
##   the product's ``PATH``: it runs the real ``setsid`` with a tiny ``sh``
##   in front of the command, and that ``sh`` -- the new session's leader,
##   whose pid is therefore the session's process-group id -- appends its pid
##   to ``record`` and ``exec``s the command, keeping the pid. Everything the
##   detached command starts (``git push``, its hooks, a ``git gc``) inherits
##   the group, so ``kill(-pgid)`` reaches exactly the detached work and
##   nothing a concurrent session started.
##
## * ``openProcessJob`` + ``adopt`` + ``terminate`` -- the Windows
##   counterpart for detached work. Windows has no ``setsid`` and no
##   process groups to signal, and a detached child's ``ParentProcessId``
##   names a process that has usually exited by teardown (the thin
##   ``repro`` client starts the engine, the engine starts the push, and
##   both return), so parentage cannot reach it either. A job object can:
##   every process a job member creates joins the job unless it is created
##   with ``CREATE_BREAKAWAY_FROM_JOB``, so ``TerminateJobObject`` ends
##   exactly the tree the test started, however detached.
##
## WHY NOT JUST A PID. A pid is a number the kernel reissues once the process
## is reaped. Each stop below signals only while the target is observably
## still the same thing: the socket's server is re-read from the kernel, and
## a process group is signalled only while ``kill(-pgid, 0)`` says it still
## has members -- a pgid cannot be reissued while any member lives. A job
## holds processes, not numbers, so it has no reuse window at all.
##
## The socket and session procs are POSIX only, and on Windows report
## nothing stopped; the job procs are Windows only, and on POSIX report
## nothing adopted or stopped.

import std/[os, strutils]

when defined(posix):
  import std/[nativesockets, net, posix, times]
when defined(windows):
  import std/winlean

const DefaultGraceMs* = 10_000
  ## How long a SIGTERMed process gets to exit before it is SIGKILLed.

when defined(posix):
  proc isZombie(pid: int): bool =
    ## Linux: the process has exited and waits only to be reaped. A zombie
    ## still answers ``kill(pid, 0)``, so without this a server that exited
    ## at once would look alive until the grace period ran out.
    when defined(linux):
      try:
        let stat = readFile("/proc/" & $pid & "/stat")
        let close = stat.rfind(')')
        result = close >= 0 and close + 2 < stat.len and stat[close + 2] == 'Z'
      except IOError, OSError:
        result = false
    else:
      result = false

  proc gone(pid: int): bool =
    ## True once ``pid`` has exited. Reaps it when it is this process's own
    ## child (a helper the product spawned in-process is), so its pid is
    ## released rather than left as a zombie of the test.
    var status: cint
    let reaped = waitpid(Pid(pid), status, WNOHANG)
    if reaped == Pid(pid):
      return true
    if posix.kill(Pid(pid), 0) != 0:
      return errno == ESRCH
    isZombie(pid)

  proc waitGone(pid: int; deadline: float): bool =
    while epochTime() < deadline:
      if gone(pid):
        return true
      sleep(20)
    gone(pid)

  when defined(linux):
    type Ucred {.importc: "struct ucred", header: "<sys/socket.h>".} = object
      pid: Pid
      uid: Uid
      gid: Gid
    var SO_PEERCRED {.importc, header: "<sys/socket.h>".}: cint

    proc peerPidUid(fd: SocketHandle): tuple[pid, uid: int] =
      var c: Ucred
      var len = SockLen(sizeof(c))
      if getsockopt(fd, SOL_SOCKET, SO_PEERCRED, addr c, addr len) != 0:
        raiseOSError(osLastError(), "SO_PEERCRED")
      (int(c.pid), int(c.uid))
  elif defined(macosx):
    var LOCAL_PEERPID {.importc, header: "<sys/un.h>".}: cint
    const SolLocal = cint(0)
      ## ``SOL_LOCAL`` (<sys/un.h>): the level of the ``LOCAL_*`` options.
    proc getpeereid(s: SocketHandle; uid: var Uid; gid: var Gid): cint {.
      importc, header: "<unistd.h>".}

    proc peerPidUid(fd: SocketHandle): tuple[pid, uid: int] =
      var pid: Pid
      var len = SockLen(sizeof(pid))
      if getsockopt(fd, SolLocal, LOCAL_PEERPID, addr pid, addr len) != 0:
        raiseOSError(osLastError(), "LOCAL_PEERPID")
      var uid: Uid
      var gid: Gid
      if getpeereid(fd, uid, gid) != 0:
        raiseOSError(osLastError(), "getpeereid")
      (int(pid), int(uid))
  else:
    proc peerPidUid(fd: SocketHandle): tuple[pid, uid: int] =
      raise newException(OSError,
        "no peer-pid socket option on this platform")

proc unixSocketServerPid*(socketPath: string): int =
  ## The pid of the process listening on the Unix socket ``socketPath``, as
  ## the kernel reports it for a connection to it; ``-1`` when nothing
  ## accepts connections there (no socket file, or a stale one).
  result = -1
  when defined(posix):
    var sock: Socket
    try:
      sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    except OSError:
      return -1
    try:
      sock.connectUnix(socketPath)
      let peer = peerPidUid(sock.getFd())
      if peer.pid > 0:
        result = peer.pid
    except OSError:
      result = -1
    finally:
      sock.close()

proc stopUnixSocketServer*(socketPath: string;
                           graceMs = DefaultGraceMs): bool =
  ## Stop the process listening on ``socketPath`` and return once it has
  ## exited: ``SIGTERM``, then ``SIGKILL`` after ``graceMs``. Returns true
  ## when a server was found and stopped, false when nothing listened there.
  ##
  ## When the server is this process's own child (a helper the product
  ## spawned in-process), it is reaped here, so a ``Process`` handle the
  ## caller still holds for it reports ``ECHILD`` afterwards.
  ##
  ## Refuses (raises ``OSError``) a server owned by another user: a socket
  ## path the test chose is served by the test's own user, so anything else
  ## means the path was not private after all, and stopping it would be the
  ## very hazard this module exists to prevent.
  when defined(posix):
    var sock: Socket
    var peer: tuple[pid, uid: int]
    try:
      sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    except OSError:
      return false
    try:
      try:
        sock.connectUnix(socketPath)
      except OSError:
        return false
      peer = peerPidUid(sock.getFd())
    finally:
      sock.close()
    if peer.pid <= 1:
      return false
    if peer.uid != int(getuid()):
      raise newException(OSError, "the server on " & socketPath &
        " (pid " & $peer.pid & ") runs as uid " & $peer.uid &
        ", not this test's; refusing to signal it")
    if peer.pid == getCurrentProcessId():
      return false
    if gone(peer.pid):
      return true
    discard posix.kill(Pid(peer.pid), SIGTERM)
    if waitGone(peer.pid, epochTime() + graceMs.float / 1000.0):
      return true
    # Still the same process: it has not exited since the check above, so its
    # pid has not been reissued.
    if not gone(peer.pid):
      discard posix.kill(Pid(peer.pid), SIGKILL)
    discard waitGone(peer.pid, epochTime() + 5.0)
    true
  else:
    false

proc installSetsidRecorder*(binDir, recordPath, realSetsid: string): bool =
  ## Write a ``setsid`` shim into ``binDir`` that records, in ``recordPath``,
  ## the process-group id of every session it starts, then runs the command
  ## exactly as the real ``setsid`` -- ``realSetsid``, the absolute path the
  ## CALLER resolved from its own ``PATH`` before ``binDir`` is on it, so
  ## the shim never delegates to itself -- would. Put
  ## ``binDir`` first on the ``PATH`` of the product command whose detached
  ## work the test must be able to stop. Returns false (and writes nothing)
  ## when ``realSetsid`` is empty: where there is no real ``setsid`` the
  ## product cannot detach through one either.
  ##
  ## The path is a parameter rather than resolved here because this module
  ## is library code, where ambient binary resolution is ratcheted
  ## (``scripts/check_ambient_execution.sh``); the test that needs the shim
  ## is where resolving a host tool belongs.
  ##
  ## The real ``setsid`` runs ``sh -c 'echo $$ >> record; exec "$@"'``: that
  ## ``sh`` is the process ``setsid`` made a session leader (directly, or in
  ## the child it forks when it is itself a group leader), so ``$$`` is the
  ## new session's -- and process group's -- id, and ``exec`` keeps it for
  ## the command.
  when defined(posix):
    if realSetsid.len == 0 or not realSetsid.isAbsolute:
      return false
    createDir(binDir)
    let shim = binDir / "setsid"
    writeFile(shim,
      "#!/bin/sh\n" &
      "# Test recorder for repro_test_support/owned_processes: records the\n" &
      "# detached session's process-group id, then runs the command.\n" &
      "exec " & quoteShell(realSetsid) & " /bin/sh -c " &
      quoteShell("echo $$ >> " & quoteShell(recordPath) & "; exec \"$@\"") &
      " setsid-recorded \"$@\"\n")
    setFilePermissions(shim, {fpUserRead, fpUserWrite, fpUserExec})
    true
  else:
    false

proc recordedSessions*(recordPath: string): seq[int] =
  ## The process-group ids ``installSetsidRecorder``'s shim has recorded.
  if not fileExists(recordPath):
    return
  for line in readFile(recordPath).splitLines():
    let text = line.strip()
    if text.len > 0 and text.allCharsInSet(Digits):
      try:
        let pgid = parseInt(text)
        if pgid > 1 and pgid notin result:
          result.add(pgid)
      except ValueError:
        discard

proc stopRecordedSessions*(recordPath: string; graceMs = 0;
                           waitMs = DefaultGraceMs): int =
  ## Stop every process group recorded in ``recordPath`` that still has
  ## members: wait up to ``graceMs`` for it to finish on its own, then
  ## ``SIGKILL`` the group, and wait up to ``waitMs`` for it to empty.
  ## Returns how many groups had to be signalled.
  when defined(posix):
    let own = int(getpgrp())
    for pgid in recordedSessions(recordPath):
      if pgid == own:
        continue
      if posix.kill(Pid(-pgid), 0) != 0:
        continue
      let graceEnd = epochTime() + graceMs.float / 1000.0
      while posix.kill(Pid(-pgid), 0) == 0 and epochTime() < graceEnd:
        sleep(20)
      # Signalled only while the group still has members: a pgid is not
      # reissued while any member of the group lives.
      if posix.kill(Pid(-pgid), 0) == 0:
        discard posix.kill(Pid(-pgid), SIGKILL)
        inc result
      let waitEnd = epochTime() + waitMs.float / 1000.0
      while posix.kill(Pid(-pgid), 0) == 0 and epochTime() < waitEnd:
        sleep(20)
  else:
    0

# ---------------------------------------------------------------------------
# Windows: a job object holding what the test started.
# ---------------------------------------------------------------------------

when defined(windows):
  type
    JobBasicLimit {.pure.} = object
      ## ``JOBOBJECT_BASIC_LIMIT_INFORMATION``
      ## (https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-jobobject_basic_limit_information).
      perProcessUserTimeLimit: int64
      perJobUserTimeLimit: int64
      limitFlags: uint32
      minimumWorkingSetSize: uint
      maximumWorkingSetSize: uint
      activeProcessLimit: uint32
      affinity: uint
      priorityClass: uint32
      schedulingClass: uint32
    IoCounters {.pure.} = object
      a, b, c, d, e, f: uint64
    JobExtendedLimit {.pure.} = object
      ## ``JOBOBJECT_EXTENDED_LIMIT_INFORMATION``.
      basic: JobBasicLimit
      io: IoCounters
      processMemoryLimit: uint
      jobMemoryLimit: uint
      peakProcessMemoryUsed: uint
      peakJobMemoryUsed: uint
    JobBasicAccounting {.pure.} = object
      ## ``JOBOBJECT_BASIC_ACCOUNTING_INFORMATION``
      ## (https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-jobobject_basic_accounting_information).
      totalUserTime, totalKernelTime: int64
      thisPeriodTotalUserTime, thisPeriodTotalKernelTime: int64
      totalPageFaultCount: uint32
      totalProcesses: uint32
      activeProcesses: uint32
      totalTerminatedProcesses: uint32

  const
    JobObjectBasicAccountingInformation = 1'i32
    JobObjectExtendedLimitInformation = 9'i32
    JobObjectLimitKillOnJobClose = 0x2000'u32

  proc createJobObjectW(attrs: pointer; name: WideCString): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateJobObjectW".}
  proc setInformationJobObject(job: Handle; cls: int32; info: pointer;
                               size: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetInformationJobObject".}
  proc queryInformationJobObject(job: Handle; cls: int32; info: pointer;
                                 size: uint32; returned: ptr uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "QueryInformationJobObject".}
  proc assignProcessToJobObject(job, process: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "AssignProcessToJobObject".}
  proc terminateJobObject(job: Handle; code: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "TerminateJobObject".}

type ProcessJob* = object
  ## Windows: a job object that the processes a test starts are adopted
  ## into, and so everything THEY start too (see the module header). POSIX:
  ## an inert value, so a caller needs no ``when`` around it.
  when defined(windows):
    handle: Handle

proc openProcessJob*(): ProcessJob =
  ## A new, empty job. It is created ``KILL_ON_JOB_CLOSE``, so even a test
  ## that dies before its teardown leaves nothing of the job running once
  ## the test process -- the only holder of the handle -- has gone.
  ## Raises ``OSError`` when the job cannot be created.
  when defined(windows):
    result.handle = createJobObjectW(nil, nil)
    if result.handle == 0:
      raiseOSError(osLastError(), "CreateJobObjectW")
    var limit = JobExtendedLimit()
    limit.basic.limitFlags = JobObjectLimitKillOnJobClose
    if setInformationJobObject(result.handle,
        JobObjectExtendedLimitInformation, addr limit,
        uint32(sizeof(limit))) == 0:
      let err = osLastError()
      discard closeHandle(result.handle)
      raiseOSError(err, "SetInformationJobObject")
  else:
    discard

proc adopt*(job: ProcessJob; pid: int): bool =
  ## Put the running process ``pid`` -- one the test has just started, so
  ## it still holds the handle and the number cannot have been reissued --
  ## into ``job``. Call it right after starting the process: a child the
  ## process creates BEFORE this call is not in the job.
  ## ``processesStarted`` lets the caller see that it was in time. Returns
  ## false when the process could not be adopted (POSIX: always).
  when defined(windows):
    if job.handle == 0 or pid <= 0:
      return false
    let process = openProcess(PROCESS_SET_QUOTA or PROCESS_TERMINATE,
      WINBOOL(0), DWORD(pid))
    if process == 0:
      return false
    defer: discard closeHandle(process)
    assignProcessToJobObject(job.handle, process) != 0
  else:
    false

proc processesStarted*(job: ProcessJob): int =
  ## How many processes have ever been in ``job``: the adopted ones and
  ## every process they and their descendants created. ``-1`` when it
  ## cannot be read (POSIX: always). A control for the caller -- a job that
  ## holds fewer than the tree it expected was adopted too late, and its
  ## teardown would miss what escaped.
  when defined(windows):
    if job.handle == 0:
      return -1
    var info = JobBasicAccounting()
    if queryInformationJobObject(job.handle,
        JobObjectBasicAccountingInformation, addr info, uint32(sizeof(info)),
        nil) == 0:
      return -1
    int(info.totalProcesses)
  else:
    -1

proc terminate*(job: ProcessJob): bool =
  ## End every process still in ``job``. Returns false when there is no job
  ## or the call failed (POSIX: always).
  when defined(windows):
    job.handle != 0 and terminateJobObject(job.handle, 1'u32) != 0
  else:
    false

proc close*(job: var ProcessJob) =
  ## Release the job; under ``KILL_ON_JOB_CLOSE`` this also ends whatever
  ## is still in it.
  when defined(windows):
    if job.handle != 0:
      discard closeHandle(job.handle)
      job.handle = 0
  else:
    discard
