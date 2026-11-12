## The process mechanics of the SHARED PER-USER ``runquotad`` a POSIX
## ``repro`` starts when no RunQuota service is provisioned (reprobuild-pm
## ``spec/RunQuota-Host-Configuration.md``, "The shared per-user daemon
## (POSIX)"): the idle period, the stale-socket removal, the detached start
## through an intermediate process, and the readiness wait.
##
## The DECISIONS -- which endpoint, adopt or start, the handover to a daemon
## from another build, the hold -- are made in ``startAutoRunQuotaIfNeeded``
## (``repro_cli_support``). What is here is everything that touches a process
## or a file descriptor on the way, so each rule has one implementation.
##
## WHY THE DAEMON IS NOT OWNED ANY MORE. Until 2026-11-11 the daemon a POSIX
## invocation started was PRIVATE to it: a fresh endpoint directory per
## build, terminating signals forwarded to it, ``RUNQUOTA_EXIT_WITH_PARENT``
## so it died with its parent, and a terminate at release. Two concurrent
## builds then each admitted against the whole budget, which is the one thing
## RunQuota exists to prevent (reprobuild-pm issue
## ``2026-11-05-auto-started-runquotad-is-private-per-invocation-instead-of-a-shared-idle-exit-daemon``).
## The daemon now OUTLIVES the invocation that started it, is shared by every
## invocation of the user, and ends itself after ``--idle-exit-after``
## seconds with no client. Everything that existed to end it with its
## invocation -- the signal forwarder (``owned_daemon_signals``), the parent
## watch, the startup-output pipes -- is gone, and what replaces it is below.

when defined(posix):
  import std/[monotimes, os, osproc, strutils, times]
  import std/importutils
  import std/posix
  from repro_core/descriptor_inheritance import
    markInheritableDescriptorsCloseOnExec, restoreInheritableDescriptors

  const
    autoRunQuotaIdleExitEnvVar* = "REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS"
      ## How long the per-user daemon ``repro`` STARTS stays up with no client
      ## connection. Read only when a daemon is started: an adopted daemon
      ## keeps the period it was started with.
    defaultAutoRunQuotaIdleExitSeconds* = 600
    userDaemonReadinessCeiling* = initDuration(seconds = 120)
      ## How long a daemon that is ALIVE but not yet listening is waited for,
      ## and how long a launcher waits for a daemon that holds the lifetime
      ## lock without answering. On a heavily loaded host (load around 200) a
      ## healthy ``runquotad`` can take tens of seconds to bind; 300 polls of
      ## 50 ms (~15 s) failed builds against daemons that were about to answer.
    userDaemonLogTailBytes* = 64 * 1024
      ## How much of ``runquotad.log`` a startup error carries.
    exitWithParentEnvVars = ["RUNQUOTA_EXIT_WITH_PARENT",
      "RUNQUOTA_EXIT_WITH_PARENT_PID"]
      ## The parent watch of the old, invocation-owned daemon. Removed from
      ## the environment of the daemon started here: it must outlive its
      ## parent, and a caller's environment can still carry the variables
      ## (a ``runquotad`` that was itself started with them, say).

  var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
    ## Not exported by ``std/posix``.

  proc autoRunQuotaIdleExitSeconds*(): int =
    ## ``REPROBUILD_RUNQUOTA_IDLE_EXIT_SECONDS``, default 600. A POSITIVE
    ## INTEGER, written in decimal digits and nothing else; anything else
    ## raises ``ValueError`` naming the variable, and the caller raises it
    ## BEFORE anything is started. An empty value counts as unset, as an
    ## empty ``RUNQUOTA_SOCKET`` does.
    let raw = getEnv(autoRunQuotaIdleExitEnvVar)
    if raw.len == 0:
      return defaultAutoRunQuotaIdleExitSeconds
    var valid = raw.len <= 9
    for ch in raw:
      if ch notin Digits:
        valid = false
    if valid:
      result = parseInt(raw)
      if result > 0:
        return
    raise newException(ValueError, autoRunQuotaIdleExitEnvVar &
      " must be a positive whole number of seconds (the idle period after " &
      "which the per-user runquotad exits), got: " & raw.escape)

  proc removeStaleUserEndpointSocket*(socket: string) =
    ## Unlink what a dead daemon left at ``socket``. The caller has checked,
    ## under the start lock, that nobody holds the lifetime lock, so nothing
    ## is listening there. Only a SOCKET owned by the effective uid is
    ## removed; anything else at the path is refused, never deleted -- the
    ## directory is verified owner-only, so something else there is
    ## something this user did not expect.
    var info: Stat
    if lstat(socket.cstring, info) != 0:
      let code = errno
      if code == ENOENT:
        return
      raise newException(OSError, "runquota per-user endpoint " & socket &
        ": cannot be inspected (" & $strerror(code) & ")")
    if not S_ISSOCK(info.st_mode) or int64(info.st_uid) != int64(geteuid()):
      raise newException(OSError, "runquota per-user endpoint " & socket &
        ": no daemon holds its lifetime lock, but what is at the path is " &
        "not a socket owned by this user (uid " & $geteuid() &
        "); refusing to remove it. Remove it by hand")
    if unlink(socket.cstring) != 0 and errno != ENOENT:
      raise newException(OSError, "runquota per-user endpoint " & socket &
        ": cannot remove the stale socket (" & $strerror(errno) & ")")

  proc atLeastThree(fd: cint; what: string): cint =
    ## ``fd`` moved to a descriptor above 2 (close-on-exec), so that the
    ## ``dup2`` onto 0, 1 and 2 in the child never finds it already there --
    ## a ``dup2`` onto itself would keep its close-on-exec flag, and the
    ## daemon would start with that stream closed.
    if fd > 2:
      return fd
    result = fcntl(fd, F_DUPFD_CLOEXEC, cint(3))
    let code = errno
    discard posix.close(fd)
    if result < 0:
      raise newException(OSError, "cannot prepare " & what &
        " for runquotad (" & $strerror(code) & ")")

  proc openUserDaemonLog*(path: string): cint =
    ## Opens ``runquotad.log`` for the daemon about to start: TRUNCATED, then
    ## appended to. The caller holds the start lock and the lifetime lock is
    ## free, so no daemon is writing it. ``O_NOFOLLOW`` because the
    ## directory is the user's, not a place a link should redirect a write.
    result = posix.open(path.cstring,
      O_WRONLY or O_CREAT or O_TRUNC or O_APPEND or O_CLOEXEC or oNoFollow,
      Mode(0o600))
    if result < 0:
      raise newException(OSError, "cannot open the runquotad log " & path &
        " (" & $strerror(errno) & ")")
    result = atLeastThree(result, "the log " & path)

  proc closeUserDaemonLog*(fd: cint) =
    ## This process's copy of the log descriptor; the daemon has its own.
    discard posix.close(fd)

  proc userDaemonLogTail*(path: string): string =
    ## The last ``userDaemonLogTailBytes`` of the log, with an explicit notice
    ## when earlier output was dropped. Never raises: it feeds an error
    ## message, which must not be replaced by a failure to read the log.
    try:
      var f: File
      if not open(f, path, fmRead):
        return "\n(the runquotad log " & path & " could not be opened)"
      defer: f.close()
      let size = f.getFileSize()
      let start = max(0'i64, size - int64(userDaemonLogTailBytes))
      f.setFilePos(start)
      let text = f.readAll().strip(leading = false)
      if text.len == 0:
        return "\n(the runquotad log " & path & " is empty)"
      result = "\nrunquotad log " & path & ":\n"
      if start > 0:
        result.add("[truncated: the first " & $start & " bytes were " &
          "dropped; the last " & $userDaemonLogTailBytes & " follow]\n")
      result.add(text)
    except CatchableError as error:
      result = "\n(the runquotad log " & path & " could not be read: " &
        error.msg & ")"

  # ---------------------------------------------------------------------------
  # The detached start, through an INTERMEDIATE process.
  #
  # The daemon is NEVER A CHILD OF THE INVOCATION (reprobuild-pm
  # `spec/RunQuota-Host-Configuration.md`, "The shared per-user daemon
  # (POSIX)"). Until 2026-11-12 it was forked directly, and `repro exec` then
  # replaced itself with the command it runs: the daemon became THAT command's
  # child, a zombie the command never reaped once the daemon idled out, and an
  # extra child that a command waiting for all of its children
  # (`sh -c '... & wait'`, any `wait()` loop run to `ECHILD`) waited for until
  # the idle period ended -- 600 s by default.
  #
  #   repro (launcher) ── fork ──> intermediate ── setsid, fork ──> runquotad
  #        <── status pipe: daemon pid, later its exit ──
  #        ── control pipe: SIGTERM / SIGKILL requests, EOF = release ──>
  #
  # The intermediate is the daemon's parent for exactly as long as the
  # launcher waits for readiness, and that is what keeps every readiness
  # diagnostic intact: it alone can `waitpid` the daemon, it reports the raw
  # wait status (exit code or signal) over the STATUS pipe, and because it
  # does not reap the daemon until it has exited, the daemon's pid cannot be
  # recycled while the launcher may still ask for it to be signalled. The
  # launcher never signals the daemon itself: it writes the request on the
  # CONTROL pipe and the intermediate, which has just seen its child alive
  # and not reaped, sends it. Once the launcher is done -- the daemon
  # answered, or its fate has been read -- it closes the control pipe; the
  # intermediate `_exit`s WITHOUT touching the daemon, the launcher reaps it
  # synchronously, and the daemon is reparented to the system's reaper (init,
  # or the nearest `PR_SET_CHILD_SUBREAPER` ancestor). A launcher that dies
  # mid-wait closes the control pipe by dying, with the same result.
  #
  # The intermediate stays alive until that release even after it has
  # reported the daemon's exit. So the only way a launcher write can meet a
  # pipe with no reader is the intermediate having been killed from outside,
  # and that write is made with SIGPIPE blocked (`writeControl`) so it is an
  # `EPIPE`, not this invocation's death.
  #
  # Both pipes are close-on-exec, so the daemon -- which `execve`s -- holds
  # neither, and `markInheritableDescriptorsCloseOnExec` is held across the
  # first `fork` so that neither child inherits any other descriptor above 2.
  # Between `fork` and `exec`/`_exit` both children make ONLY async-signal-
  # safe calls (`fork`, `setsid`, `sigaction`, `chdir`, `dup2`, `execve`,
  # `read`, `write`, `poll`, `waitpid`, `kill`, `close`, `_exit`) on values
  # prepared before the first `fork`: this process is multi-threaded, and the
  # children are copies of one thread of it.
  # ---------------------------------------------------------------------------

  type
    LaunchRecord {.packed.} = object
      ## One message from the intermediate on the status pipe. A fixed-size
      ## record far below `PIPE_BUF`, so each `write` is atomic and a `read`
      ## of `sizeof(LaunchRecord)` bytes returns a whole one or nothing.
      tag: char
        ## `P` the daemon's pid; `F` its `fork` failed (errno); `X` it exited
        ## and was reaped (raw wait status); `E` it can no longer be waited
        ## for (errno of the failed `waitpid`).
      value: int32

    UserDaemonLaunch* = object
      ## A daemon started by `spawnDetachedUserDaemon` and the intermediate
      ## process watching it. `waitForUserDaemon` consumes it: on every path
      ## out of it the intermediate has been released and reaped and both
      ## descriptors are closed.
      daemon*: int
        ## The daemon's pid. It is NOT this process's child.
      intermediate: Pid
      status: cint
        ## Read end of the status pipe; -1 once closed.
      control: cint
        ## Write end of the control pipe; -1 once closed (= released).

  const
    commandTerminate = 'T'
    commandKill = 'K'

  when defined(linux):
    proc pipe2(fds: var array[0..1, cint]; flags: cint): cint {.
      importc, header: "<unistd.h>".}

  proc closeOnExecPipe(what: string): array[0..1, cint] =
    ## A pipe whose both ends are close-on-exec. `pipe2(O_CLOEXEC)` where it
    ## exists, so no other thread's `fork`+`exec` can catch the ends without
    ## the flag; elsewhere (macOS has no `pipe2`) the flag is set at once.
    when defined(linux):
      if pipe2(result, O_CLOEXEC) != 0:
        raise newException(OSError, "cannot start runquotad: cannot create " &
          "the " & what & " pipe (" & $strerror(errno) & ")")
    else:
      if posix.pipe(result) != 0:
        raise newException(OSError, "cannot start runquotad: cannot create " &
          "the " & what & " pipe (" & $strerror(errno) & ")")
      for fd in result:
        discard fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) or FD_CLOEXEC)

  proc writeRecord(fd: cint; tag: char; value: cint) {.inline.} =
    ## Used by the intermediate only, between `fork` and `_exit`: a stack
    ## value and one `write`, nothing that allocates or locks. A launcher that
    ## has gone makes the write fail (or the default `SIGPIPE` end the
    ## intermediate), and either way there is nobody left to tell.
    var record = LaunchRecord(tag: tag, value: int32(value))
    discard posix.write(fd, addr record, sizeof(record))

  proc exitText(status: cint): string =
    ## The fate of a reaped child, in the words the readiness error uses:
    ## an exit code and a signal are different reports and never folded into
    ## one another.
    if WIFEXITED(status): "exit code " & $WEXITSTATUS(status)
    elif WIFSIGNALED(status): "signal " & $WTERMSIG(status)
    else: "wait status " & $status

  type
    LaunchReadKind = enum
      lrRecord   ## a whole record arrived
      lrNothing  ## none within the time given
      lrClosed   ## the intermediate's end is closed: it has exited
      lrFailed   ## the pipe could not be read (`error`)
    LaunchRead = object
      kind: LaunchReadKind
      record: LaunchRecord
      error: cint

  proc readLaunchRecord(launch: UserDaemonLaunch; timeoutMs: int): LaunchRead =
    ## The next record on the status pipe, waiting at most ``timeoutMs`` on
    ## the monotonic clock. Never raises: its answers feed the readiness
    ## report, which says itself what could not be observed.
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    while true:
      let remaining = clamp((deadline - getMonoTime()).inMilliseconds,
        0'i64, int64(high(int32)))
      var ready = TPollfd(fd: launch.status, events: POLLIN)
      let polled = posix.poll(addr ready, 1, cint(remaining))
      if polled < 0:
        let code = errno
        if code == EINTR and remaining > 0:
          continue
        if code == EINTR:
          return LaunchRead(kind: lrNothing)
        return LaunchRead(kind: lrFailed, error: code)
      if polled == 0:
        return LaunchRead(kind: lrNothing)
      var record: LaunchRecord
      let got = posix.read(launch.status, addr record, sizeof(record))
      if got == sizeof(record):
        return LaunchRead(kind: lrRecord, record: record)
      if got == 0:
        return LaunchRead(kind: lrClosed)
      if got < 0:
        let code = errno
        if code == EINTR or code == EAGAIN:
          continue
        return LaunchRead(kind: lrFailed, error: code)
      # A short read cannot happen to a record written in one `write` below
      # `PIPE_BUF`; if it does, the stream is no longer in step.
      return LaunchRead(kind: lrFailed, error: EIO)

  proc writeControl(launch: UserDaemonLaunch; command: char): bool =
    ## Asks the intermediate to signal the daemon. ``SIGPIPE`` is blocked on
    ## this thread for the ``write``: the intermediate keeps its end open
    ## until it is released, so the pipe has no reader only if it was killed
    ## from outside, and that must be an ``EPIPE`` here rather than the end
    ## of this invocation. A ``SIGPIPE`` the write raised is consumed before
    ## the mask is restored.
    if launch.control < 0:
      return false
    var blocked, previous: Sigset
    discard sigemptyset(blocked)
    discard sigaddset(blocked, SIGPIPE)
    discard pthread_sigmask(SIG_BLOCK, blocked, previous)
    var message = command
    let wrote = posix.write(launch.control, addr message, 1)
    let code = errno
    if wrote < 0 and code == EPIPE and sigismember(previous, SIGPIPE) == 0:
      var pending: Sigset
      if sigpending(pending) == 0 and sigismember(pending, SIGPIPE) == 1:
        var received: cint = 0
        discard sigwait(blocked, received)
    discard pthread_sigmask(SIG_SETMASK, previous, blocked)
    wrote == 1

  proc releaseIntermediate(launch: var UserDaemonLaunch;
                           forceful = false): string =
    ## RELEASES the intermediate (closes the control pipe: it exits without
    ## touching the daemon), closes the status pipe and REAPS the
    ## intermediate before returning, so no process of the launch is left a
    ## child of this one. Idempotent. ``forceful`` (no pid was reported, so
    ## the intermediate is not doing its job) kills it first.
    ##
    ## Returns " (the intermediate process ended with ...)" when it ended
    ## other than by a clean release, for an error to carry; "" otherwise.
    if launch.control >= 0:
      discard posix.close(launch.control)
      launch.control = -1
    if launch.status >= 0:
      discard posix.close(launch.status)
      launch.status = -1
    if launch.intermediate <= 0:
      return ""
    let intermediate = launch.intermediate
    launch.intermediate = 0
    if forceful:
      discard posix.kill(intermediate, SIGKILL)
    # A released intermediate exits at once. One that does not within 5 s
    # (stopped, say) is killed rather than waited for without bound; it is
    # our unreaped child, so the pid is still its.
    var raw: cint = 0
    var reaped = Pid(0)
    for _ in 0 ..< 100:
      reaped = waitpid(intermediate, raw, WNOHANG)
      if reaped != 0 and not (reaped < 0 and errno == EINTR):
        break
      sleep(50)
    if reaped == 0:
      discard posix.kill(intermediate, SIGKILL)
      while true:
        reaped = waitpid(intermediate, raw, 0)
        if not (reaped < 0 and errno == EINTR):
          break
    if reaped == intermediate and not forceful and WIFEXITED(raw) and
        WEXITSTATUS(raw) == 0:
      return ""
    if reaped == intermediate:
      return " (the intermediate process ended with " & exitText(raw) & ")"
    # `ECHILD`: something else reaped it (this process ignores SIGCHLD).
    ""

  proc spawnDetachedUserDaemon*(exe: string; args: seq[string];
                                logFd: cint): UserDaemonLaunch =
    ## Starts ``exe args`` as the per-user daemon, through an intermediate
    ## process (see the block above), and returns once the intermediate has
    ## reported the daemon's pid. The caller must hand the result to
    ## ``waitForUserDaemon``, which releases and reaps the intermediate.
    ##
    ## The daemon OUTLIVES this invocation, so it must hold nothing of it:
    ##
    ## * NOT A CHILD of this process: its parent is the intermediate, and
    ##   then the system's reaper;
    ## * a NEW SESSION (the intermediate's ``setsid``): a terminal's
    ##   ``SIGINT`` / ``SIGHUP`` addressed to the invocation's process group
    ##   does not reach it;
    ## * working directory ``/``: it pins no caller directory;
    ## * stdin ``/dev/null``, stdout and stderr appended to ``logFd``
    ##   (``runquotad.log``);
    ## * NO DESCRIPTOR ABOVE 2. ``osproc`` and other code in this process
    ##   create descriptors without ``O_CLOEXEC``, and a daemon that inherited
    ##   the write end of the pipe a caller reads ``repro``'s output from kept
    ##   ``$(repro exec ...)`` waiting for as long as the daemon lived
    ##   (reprobuild-pm issue 2026-10-23). Every descriptor above 2 is made
    ##   close-on-exec for the duration of the first ``fork``
    ##   (``markInheritableDescriptorsCloseOnExec``, the rule RunQuota's
    ##   process backend applies with ``closeInheritedChildFds``) and restored
    ##   afterwards; the two pipes to the intermediate are close-on-exec from
    ##   birth. A spawn another thread makes in that window loses only
    ##   descriptors above 2 it did not ``dup2`` into place, and the build's
    ##   launch paths give every child 0, 1 and 2 and nothing else;
    ## * ``SIGCHLD`` at its default disposition, so that the intermediate can
    ##   wait for it even when this process ignores ``SIGCHLD`` (an ignored
    ##   ``SIGCHLD`` makes the kernel reap children unasked, and their exit
    ##   status is lost) -- and so that the daemon does not inherit that
    ##   setting across ``execve`` either;
    ## * the invocation's environment without ``RUNQUOTA_EXIT_WITH_PARENT*``.
    ##   The caller has already published ``RUNQUOTA_SOCKET`` and
    ##   ``RUNQUOTA_ENDPOINT_SCOPE=private`` into it.
    ##
    ## WHY ``fork`` AND NOT ``osproc``. ``startProcess`` can give the child
    ## pipes or this process's own streams, never a file, has no new-session
    ## option, and always makes the process it starts this process's child.
    # `exe` is `findRunQuotaDaemonBin`'s answer: already resolved (an
    # executable `RUNQUOTAD_BIN`, a `PATH` hit, the sibling build), so it is
    # only made absolute here -- the child changes to `/` before `execve` --
    # and never searched for again.
    let resolved = absolutePath(exe)
    var argv = @[resolved]
    argv.add(args)
    var environment: seq[string] = @[]
    for key, value in envPairs():
      if key notin exitWithParentEnvVars:
        environment.add(key & "=" & value)
    let cargv = allocCStringArray(argv)
    defer: deallocCStringArray(cargv)
    let cenv = allocCStringArray(environment)
    defer: deallocCStringArray(cenv)
    let execFailure = "repro: could not execute " & resolved & "\n"
    let devNullOpened = posix.open("/dev/null".cstring, O_RDONLY or O_CLOEXEC)
    if devNullOpened < 0:
      raise newException(OSError, "cannot open /dev/null for runquotad (" &
        $strerror(errno) & ")")
    let devNull = atLeastThree(devNullOpened, "/dev/null")
    defer: discard posix.close(devNull)
    let root = "/".cstring
    var defaultChild: Sigaction
    defaultChild.sa_handler = SIG_DFL
    discard sigemptyset(defaultChild.sa_mask)
    # [0] read end, [1] write end. STATUS: intermediate -> launcher.
    # CONTROL: launcher -> intermediate.
    let statusPipe = closeOnExecPipe("status")
    var controlPipe: array[0..1, cint]
    try:
      controlPipe = closeOnExecPipe("control")
    except OSError:
      discard posix.close(statusPipe[0])
      discard posix.close(statusPipe[1])
      raise
    let madeCloseOnExec = markInheritableDescriptorsCloseOnExec()
    let intermediate = fork()
    if intermediate == 0:
      # THE INTERMEDIATE. Async-signal-safe calls only, from here to every
      # `exitnow`.
      #
      # Its copies of the launcher's ends go first: a control pipe whose
      # write end it held itself would never report the launcher's release.
      discard posix.close(statusPipe[0])
      discard posix.close(controlPipe[1])
      let status = statusPipe[1]
      let control = controlPipe[0]
      discard sigaction(SIGCHLD, defaultChild, nil)
      discard setsid()
      let daemon = fork()
      if daemon == 0:
        # THE DAEMON. Both pipes are close-on-exec and vanish at `execve`.
        discard posix.chdir(root)
        if dup2(devNull, 0) < 0 or dup2(logFd, 1) < 0 or dup2(logFd, 2) < 0:
          exitnow(127)
        discard execve(cargv[0], cargv, cenv)
        discard posix.write(2, execFailure.cstring, execFailure.len)
        exitnow(127)
      if daemon < 0:
        writeRecord(status, 'F', errno)
        exitnow(1)
      writeRecord(status, 'P', cint(daemon))
      # Watch the daemon until the launcher releases us. After the daemon's
      # exit has been reported, or once it can no longer be waited for, only
      # the release is waited for: the launcher's `writeControl` relies on
      # this end staying open until then.
      var watching = true
      while true:
        if watching:
          var raw: cint = 0
          let reaped = waitpid(daemon, raw, WNOHANG)
          if reaped == daemon:
            writeRecord(status, 'X', raw)
            watching = false
          elif reaped < 0 and errno != EINTR:
            writeRecord(status, 'E', errno)
            watching = false
        var ready = TPollfd(fd: control, events: POLLIN)
        let polled = posix.poll(addr ready, 1, cint(if watching: 50 else: -1))
        if polled < 0:
          if errno == EINTR:
            continue
          # The release can no longer be observed; leave the daemon to the
          # reaper rather than spin.
          exitnow(0)
        if polled == 0:
          continue
        var command: char
        let got = posix.read(control, addr command, 1)
        if got == 0:
          # THE RELEASE: the launcher closed the control pipe (or died).
          # The daemon is not touched; it is reparented when we exit.
          exitnow(0)
        if got < 0:
          if errno == EINTR or errno == EAGAIN:
            continue
          exitnow(0)
        # Signalled only while still watching: the daemon has not been
        # reaped, so its pid is still its own and cannot reach a recycled
        # one.
        if watching:
          if command == commandTerminate:
            discard posix.kill(daemon, SIGTERM)
          elif command == commandKill:
            discard posix.kill(daemon, SIGKILL)
    let forkError = errno
    restoreInheritableDescriptors(madeCloseOnExec)
    # The intermediate's ends are its own now.
    discard posix.close(statusPipe[1])
    discard posix.close(controlPipe[0])
    if intermediate < 0:
      discard posix.close(statusPipe[0])
      discard posix.close(controlPipe[1])
      raise newException(OSError, "cannot start runquotad: fork failed (" &
        $strerror(forkError) & ")")
    result = UserDaemonLaunch(daemon: 0, intermediate: intermediate,
      status: statusPipe[0], control: controlPipe[1])
    # The pid, or why there is none. The intermediate writes it as soon as
    # its `fork` returns, so this waits for two `fork`s, not for the daemon.
    let reported = readLaunchRecord(result,
      int(userDaemonReadinessCeiling.inMilliseconds))
    if reported.kind == lrRecord and reported.record.tag == 'P' and
        reported.record.value > 0:
      result.daemon = int(reported.record.value)
      return
    let why =
      case reported.kind
      of lrRecord:
        if reported.record.tag == 'F':
          "fork failed (" & $strerror(cint(reported.record.value)) & ")"
        else:
          "the intermediate process sent an unexpected record"
      of lrClosed: "the intermediate process ended before it reported " &
        "the daemon's pid"
      of lrNothing: "the intermediate process did not report the " &
        "daemon's pid within " & $userDaemonReadinessCeiling.inSeconds & " s"
      of lrFailed: "the status pipe could not be read (" &
        $strerror(cint(reported.error)) & ")"
    let ended = releaseIntermediate(result, forceful = true)
    raise newException(OSError, "cannot start runquotad: " & why & ended)

  const hostOwnerRefusalMarker* = "configured daemon owner uid "
    ## The words `runquota_ipc.inspectPath` puts in front of the uid the HOST
    ## endpoint policy expects (`rendezvousPolicy`: `RUNQUOTA_ENDPOINT_OWNER_UID`,
    ## else the `runquota` account). A private policy never names an owner
    ## other than the effective caller, so a refusal that names a different
    ## one was produced by the host policy. Matching a sibling's wording is
    ## held honest by `t_auto_runquota_uses_private_endpoint_policy.nim`, which
    ## provokes the refusal from the real daemon rather than from a copy of
    ## this string.

  proc hostOwnerRefusalUid*(text: string): int64 =
    ## The daemon owner uid a host-policy endpoint refusal named in `text`
    ## (the daemon's log), or -1 when it carries no such refusal. The last
    ## occurrence wins: the refusal is the last thing a daemon says before it
    ## exits.
    let at = text.rfind(hostOwnerRefusalMarker)
    if at < 0:
      return -1
    var digits = ""
    for ch in text[at + hostOwnerRefusalMarker.len .. ^1]:
      if ch notin Digits:
        break
      digits.add ch
    if digits.len == 0 or digits.len > 18:
      return -1
    int64(parseBiggestInt(digits))

  proc hostPolicyDaemonRemedy*(runquotad, logText: string): string =
    ## The remedy for a started daemon that refused its private endpoint
    ## under the HOST policy, or "" when its log shows no such refusal.
    ## repro hands the daemon `RUNQUOTA_ENDPOINT_SCOPE=private`, and a private
    ## policy only ever expects the effective caller, so a refusal naming
    ## another owner uid means this `runquotad` ignored the selection: it
    ## predates private endpoints (runquota 35b9dfe). The version string
    ## cannot tell such a build from a current one, so the remedy names the
    ## binary that was started instead. Without this the operator sees only
    ## "configured daemon owner uid <n>" and reads it as a host problem.
    let refusedOwner = hostOwnerRefusalUid(logText)
    if refusedOwner < 0 or refusedOwner == int64(geteuid()):
      return ""
    "\nremedy: " & runquotad & " checked the private endpoint repro " &
      "created for it against the host policy (daemon owner uid " &
      $refusedOwner & ") although repro selected RUNQUOTA_ENDPOINT_SCOPE=" &
      "private, so this runquotad predates private RunQuota endpoints. " &
      "Point RUNQUOTAD_BIN at a current runquotad (or remove the stale one " &
      "from PATH), or start the host's RunQuota service."

  proc waitForUserDaemon*(launch: var UserDaemonLaunch;
                          exe, socket, logPath: string;
                          answered: proc (): bool): int =
    ## Waits for the daemon ``launch`` just started until ``answered()`` (it
    ## is reachable, and the caller now holds it) or it has exited -- not for
    ## a fixed number of polls -- and returns its pid. Raises ``OSError``
    ## otherwise, with the tail of its log, and the error says WHICH WAY THE
    ## WAIT ENDED and how long after the start (reprobuild-pm
    ## ``spec/RunQuota-Host-Configuration.md``, "The shared per-user daemon
    ## (POSIX)"):
    ##
    ## * it EXITED before it listened: at once, with its exit code or the
    ##   signal that ended it, as the intermediate read them;
    ## * it was STILL RUNNING at the ceiling (120 s on the monotonic clock):
    ##   it is wedged, so the intermediate is asked to terminate it
    ##   (``SIGTERM``, then ``SIGKILL`` after 5 s), and the error says repro
    ##   terminated it;
    ## * its state COULD NOT BE OBSERVED (the intermediate could not wait for
    ##   it, ended unexpectedly, or the status pipe failed), with the reason.
    ##   No signal is sent then: nothing that still holds the daemon unreaped
    ##   vouches for its pid.
    ##
    ## The fate is read before anything signals the daemon, so a daemon that
    ## died on its own and one this launcher killed -- which leave the same
    ## refused socket behind and send an investigator to opposite halves of
    ## the system -- are never reported alike.
    ##
    ## On EVERY path out, returned or raised, the intermediate has been
    ## released and reaped (``releaseIntermediate``): the daemon is then no
    ## process's child of this invocation, and nothing is left to reap later.
    let started = getMonoTime()
    let deadline = started + userDaemonReadinessCeiling
    let prefix = "runquotad did not become reachable at " & socket & " (" &
      exe & ")"
    proc since(): string =
      $(getMonoTime() - started).inMilliseconds & " ms after it was started"
    proc diagnostics(): string =
      # The log's tail, then -- when the log shows the daemon refused its
      # private endpoint under the HOST policy -- what that means and what
      # to do (`hostPolicyDaemonRemedy`).
      let tail = userDaemonLogTail(logPath)
      tail & hostPolicyDaemonRemedy(exe, tail)
    # Why the daemon's state can no longer be read, once it cannot. From
    # then on only `answered()` and the ceiling end the wait.
    var unobservable = ""
    try:
      while true:
        if answered():
          return launch.daemon
        if unobservable.len == 0:
          # Doubles as the 50 ms pause, and wakes at once when the
          # intermediate reports an exit.
          let got = readLaunchRecord(launch, 50)
          case got.kind
          of lrNothing:
            discard
          of lrRecord:
            if got.record.tag == 'X':
              raise newException(OSError, prefix & ": it exited before it " &
                "listened, " & since() & ", with " &
                exitText(cint(got.record.value)) & diagnostics())
            elif got.record.tag == 'E':
              unobservable = "the process watching it could not wait for " &
                "it: " & $strerror(cint(got.record.value))
            else:
              unobservable = "the process watching it sent an unexpected " &
                "record"
          of lrClosed:
            unobservable = "the process watching it ended unexpectedly" &
              releaseIntermediate(launch)
          of lrFailed:
            unobservable = "its status pipe could not be read: " &
              $strerror(got.error)
          if unobservable.len > 0 and posix.kill(Pid(launch.daemon), 0) != 0:
            # Gone, and its exit status with the watcher: the log is all
            # that is left.
            raise newException(OSError, prefix & ": its state could not be " &
              "observed (" & unobservable & "), " & since() & "; it is " &
              "gone" & diagnostics())
        else:
          sleep(50)
        if getMonoTime() >= deadline:
          if unobservable.len == 0:
            # The intermediate last saw it alive and has not reaped it, so
            # the signal it sends on our behalf cannot reach a recycled pid.
            # Its exit is waited for (5 s after each signal), so the daemon
            # is gone before the error is raised; what it reports is not
            # needed -- the fate was read above.
            discard writeControl(launch, commandTerminate)
            if readLaunchRecord(launch, 5_000).kind == lrNothing:
              discard writeControl(launch, commandKill)
              discard readLaunchRecord(launch, 5_000)
            raise newException(OSError, prefix & ": it was still running " &
              since() & ", at the " & $userDaemonReadinessCeiling.inSeconds &
              " s readiness ceiling, but never answered the reachability " &
              "probe; repro terminated it" & diagnostics())
          raise newException(OSError, prefix & ": its state could not be " &
            "observed (" & unobservable & "), " & since() & ", at the " &
            $userDaemonReadinessCeiling.inSeconds & " s readiness ceiling; " &
            "no signal was sent" & diagnostics())
    finally:
      discard releaseIntermediate(launch)

  proc spawnedDaemonProcess*(pid: int): owned(Process) =
    ## An ``osproc.Process`` naming the daemon just started, for the callers
    ## that take one -- ``trustDaemonWeSpawned`` above all, whose argument
    ## type is its soundness argument (only the code that started a daemon
    ## can hold one). The daemon is not this process's child (its parent was
    ## the intermediate, and is now the system's reaper), so nothing may wait
    ## for it through this value: it owns no stream (``poParentStreams``),
    ## and ``close`` releases nothing and never waits.
    privateAccess(Process)
    Process(id: Pid(pid), options: {poParentStreams})
