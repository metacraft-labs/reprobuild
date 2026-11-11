## The process mechanics of the SHARED PER-USER ``runquotad`` a POSIX
## ``repro`` starts when no RunQuota service is provisioned (reprobuild-pm
## ``spec/RunQuota-Host-Configuration.md``, "The shared per-user daemon
## (POSIX)"): the idle period, the stale-socket removal, the detached start,
## the readiness wait and the non-blocking reaping.
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
  import std/[locks, monotimes, os, osproc, strutils, times]
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

  proc spawnDetachedUserDaemon*(exe: string; args: seq[string];
                                logFd: cint): int =
    ## Starts ``exe args`` as the per-user daemon and returns its pid. The
    ## daemon OUTLIVES this invocation, so it must hold nothing of it:
    ##
    ## * a NEW SESSION (``setsid``): a terminal's ``SIGINT`` / ``SIGHUP``
    ##   addressed to the invocation's process group does not reach it;
    ## * working directory ``/``: it pins no caller directory;
    ## * stdin ``/dev/null``, stdout and stderr appended to ``logFd``
    ##   (``runquotad.log``);
    ## * NO DESCRIPTOR ABOVE 2. ``osproc`` and other code in this process
    ##   create descriptors without ``O_CLOEXEC``, and a daemon that inherited
    ##   the write end of the pipe a caller reads ``repro``'s output from kept
    ##   ``$(repro exec ...)`` waiting for as long as the daemon lived
    ##   (reprobuild-pm issue 2026-10-23). Every descriptor above 2 is made
    ##   close-on-exec for the duration of the ``fork``
    ##   (``markInheritableDescriptorsCloseOnExec``, the rule RunQuota's
    ##   process backend applies with ``closeInheritedChildFds``) and restored
    ##   afterwards. A spawn another thread makes in that window loses only
    ##   descriptors above 2 it did not ``dup2`` into place, and the build's
    ##   launch paths give every child 0, 1 and 2 and nothing else;
    ## * the invocation's environment without ``RUNQUOTA_EXIT_WITH_PARENT*``.
    ##   The caller has already published ``RUNQUOTA_SOCKET`` and
    ##   ``RUNQUOTA_ENDPOINT_SCOPE=private`` into it.
    ##
    ## WHY ``fork`` AND NOT ``osproc``. ``startProcess`` can give the child
    ## pipes or this process's own streams, never a file, and has no new-
    ## session option. The child here makes only async-signal-safe calls
    ## (``setsid``, ``chdir``, ``dup2``, ``execve``, ``write``, ``_exit``)
    ## on values prepared before the ``fork``, which is what a multi-threaded
    ## process may do between ``fork`` and ``exec``.
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
    let madeCloseOnExec = markInheritableDescriptorsCloseOnExec()
    let pid = fork()
    if pid == 0:
      discard setsid()
      discard posix.chdir(root)
      if dup2(devNull, 0) < 0 or dup2(logFd, 1) < 0 or dup2(logFd, 2) < 0:
        exitnow(127)
      discard execve(cargv[0], cargv, cenv)
      discard posix.write(2, execFailure.cstring, execFailure.len)
      exitnow(127)
    let forkError = errno
    restoreInheritableDescriptors(madeCloseOnExec)
    if pid < 0:
      raise newException(OSError, "cannot start runquotad: fork failed (" &
        $strerror(forkError) & ")")
    int(pid)

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

  proc exitText(status: cint): string =
    ## The fate of a reaped child, in the words the readiness error uses:
    ## an exit code and a signal are different reports and never folded into
    ## one another.
    if WIFEXITED(status): "exit code " & $WEXITSTATUS(status)
    elif WIFSIGNALED(status): "signal " & $WTERMSIG(status)
    else: "wait status " & $status

  proc waitForUserDaemon*(pid: int; exe, socket, logPath: string;
                          answered: proc (): bool) =
    ## Waits for the daemon ``pid`` just started until ``answered()`` (it is
    ## reachable, and the caller now holds it) or it has exited -- not for a
    ## fixed number of polls. Raises ``OSError`` otherwise, with the tail of
    ## its log, and the error says WHICH WAY THE WAIT ENDED and how long after
    ## the start (reprobuild-pm ``spec/RunQuota-Host-Configuration.md``, "The
    ## shared per-user daemon (POSIX)"):
    ##
    ## * it EXITED before it listened: at once, with its exit code or the
    ##   signal that ended it;
    ## * it was STILL RUNNING at the ceiling (120 s on the monotonic clock):
    ##   it is wedged, so it is terminated and reaped (``SIGTERM``, then
    ##   ``SIGKILL`` after 5 s), and the error says repro terminated it;
    ## * its state COULD NOT BE OBSERVED (``waitpid`` failed, e.g. ``ECHILD``
    ##   because something else reaped it), with the reason. No signal is
    ##   sent then: the pid may no longer be the daemon's.
    ##
    ## The fate is read before anything here signals or reaps the daemon, so
    ## a daemon that died on its own and one this launcher killed -- which
    ## leave the same refused socket behind and send an investigator to
    ## opposite halves of the system -- are never reported alike.
    ##
    ## Either way the child has been reaped (or is not ours to reap) when this
    ## raises. On success it has not: it is the caller's to reap later,
    ## without blocking.
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
    var lastError: cint = 0
    while true:
      if answered():
        return
      var status: cint = 0
      let reaped = waitpid(Pid(pid), status, WNOHANG)
      if reaped == Pid(pid):
        raise newException(OSError, prefix & ": it exited before it " &
          "listened, " & since() & ", with " & exitText(status) &
          diagnostics())
      if reaped < 0:
        let code = errno
        lastError = code
        if code != EINTR and posix.kill(Pid(pid), 0) != 0:
          # Reaped by somebody else (a SIGCHLD set to SIG_IGN reaps children
          # by itself), and gone: the exit status is lost, not the log.
          raise newException(OSError, prefix & ": its state could not be " &
            "observed (" & $strerror(code) & "), " & since() & "; it is " &
            "gone" & diagnostics())
      if getMonoTime() >= deadline:
        if reaped == 0:
          # Still our unreaped child, so the pid is still its: signalling
          # it cannot reach a recycled pid.
          discard posix.kill(Pid(pid), SIGTERM)
          var gone = false
          for _ in 0 ..< 100:
            if waitpid(Pid(pid), status, WNOHANG) != 0:
              gone = true
              break
            sleep(50)
          if not gone:
            discard posix.kill(Pid(pid), SIGKILL)
            discard waitpid(Pid(pid), status, 0)
          raise newException(OSError, prefix & ": it was still running " &
            since() & ", at the " & $userDaemonReadinessCeiling.inSeconds &
            " s readiness ceiling, but never answered the reachability " &
            "probe; repro terminated it" & diagnostics())
        raise newException(OSError, prefix & ": its state could not be " &
          "observed (" & $strerror(lastError) & "), " & since() & ", at the " &
          $userDaemonReadinessCeiling.inSeconds & " s readiness ceiling; " &
          "no signal was sent" & diagnostics())
      sleep(50)

  # ---------------------------------------------------------------------------
  # Reaping, without blocking.
  #
  # The daemon stays a child of the invocation that started it until that
  # invocation exits. A short-lived `repro` exits soon and the daemon is
  # re-parented; a LONG-LIVED one -- the user build daemon, which runs builds
  # on threads of one process -- would collect a zombie for every daemon that
  # idled out under it. So every pid started here is recorded, and
  # `reapSpawnedUserDaemons` collects the ones that have exited, never
  # waiting: at release, and at every later start.
  #
  # A plain array of pids under a lock, not a `seq`: it is shared by the
  # build threads, and holds nothing the garbage collector owns.
  # ---------------------------------------------------------------------------

  var
    spawnedLock: Lock
    spawnedPids: array[32, int32]
  initLock(spawnedLock)

  proc recordSpawnedUserDaemon*(pid: int) =
    ## Remember ``pid`` for ``reapSpawnedUserDaemons``. With the table full
    ## (32 daemons started by one process, none exited yet) the pid is not
    ## recorded; it costs at most one zombie until this process exits.
    withLock spawnedLock:
      for slot in spawnedPids.mitems:
        if slot == 0:
          slot = int32(pid)
          return

  proc reapSpawnedUserDaemons*() =
    ## Collect every recorded daemon that has exited, without blocking. A pid
    ## that is no longer this process's child (``ECHILD``: reaped elsewhere)
    ## is forgotten too.
    withLock spawnedLock:
      for slot in spawnedPids.mitems:
        if slot != 0:
          var status: cint = 0
          let reaped = waitpid(Pid(slot), status, WNOHANG)
          if reaped == Pid(slot) or (reaped < 0 and errno == ECHILD):
            slot = 0

  proc spawnedDaemonProcess*(pid: int): owned(Process) =
    ## An ``osproc.Process`` naming the daemon just started, for the callers
    ## that take one -- ``trustDaemonWeSpawned`` above all, whose argument
    ## type is its soundness argument (only the process that started a child
    ## can hold one). It owns no stream (``poParentStreams``), so ``close``
    ## releases nothing and never waits.
    privateAccess(Process)
    Process(id: Pid(pid), options: {poParentStreams})
