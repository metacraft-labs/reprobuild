## Forwarding a terminating signal to the daemons this invocation owns.
##
## THE RULE (reprobuild-pm `spec/RunQuota-Host-Configuration.md`, "\"Terminated
## when the top-level build ends\" means however it ends"). On POSIX a daemon
## `repro` starts for its own invocation must not outlive it, whether the
## invocation returns, raises, or is ended by a signal. `defer` blocks cover the
## first two and no signal at all, which is how an e2e test's `terminate()` of
## `repro dev` left a `runquotad` behind for hours (reprobuild-pm issue
## `2026-09-28-auto-started-runquotad-outlives-a-terminated-repro-and-holds-its-callers-pipe`).
## So while the invocation owns a daemon, SIGTERM, SIGINT, SIGHUP and SIGQUIT
## are caught here, the daemon is sent SIGTERM, and the signal then takes the
## course it would have taken anyway:
##
##   * a previous HANDLER is called, with the `siginfo_t` when it asked for one
##     (`SA_SIGINFO`) -- so a `setControlCHook`, Nim's own SIGINT report, or
##     anything else installed before the daemon was started still runs;
##   * a previous DEFAULT disposition is restored and the signal re-raised, so
##     the process dies of that signal and its exit status still names it
##     (143 for SIGTERM, not some exit code of ours). The re-raised signal is
##     blocked while this handler runs and is delivered the moment it returns;
##   * a signal whose disposition was IGNORE is never hooked. It does not end
##     the invocation, so it must not end the invocation's daemon either --
##     `nohup repro …` keeps its daemon across a hangup.
##
## SIGKILL and the OOM killer cannot be caught by anything; the daemon's own
## parent watch (`RUNQUOTA_EXIT_WITH_PARENT`, passed by the spawn) covers those.
##
## WHY C. A signal handler may call only async-signal-safe functions; Nim's
## runtime gives no such guarantee for anything it generates (a `seq` access
## may raise, a string may allocate). The handler therefore lives in C and does
## exactly three things that POSIX lists as safe: `kill`, `sigaction` and
## `raise`. The owned pids are a fixed array of `volatile sig_atomic_t`-sized
## slots, written by the registering thread and only read by the handler.
## `push_hook_protocol.nim` keeps its pending-cleanup handler in C for the same
## reason and in the same shape.
##
## SEVERAL DAEMONS AT ONCE. One invocation normally owns one, but tests drive
## `startAutoRunQuotaIfNeeded` repeatedly in one process, so ownership is a
## small fixed table: registration installs or rearms handlers as needed,
## and the previous dispositions are restored when the LAST pid is released. A registration that finds the table full is refused rather than
## silently left unforwarded, and the caller says so.
##
## RESTORING ONLY WHAT IS STILL OURS. If something installed its own handler
## for one of these signals while a daemon was owned, the release leaves that
## handler in place rather than clobbering it with the disposition from
## before: the later installer made a decision this module has no right to
## undo.
##
## THE PID-REUSE WINDOW. The caller retains waitable-child SIGCHLD semantics
## and permits no independent reaper while a daemon is registered, then
## unregisters BEFORE terminating and reaping it. Under that contract the
## handler cannot signal a recycled pid -- except in the instant between the
## handler loading a slot and calling `kill` while the releasing thread clears
## that slot, terminates and reaps the daemon, and the kernel recycles the pid.
## That needs a signal to land during a release and a full pid wrap inside one
## handler invocation; it is accepted rather than locked against, because a
## lock is not something a signal handler may take.

import std/osproc

when defined(posix):
  import std/os
  {.emit: """
  #include <sys/types.h>
  #include <sys/wait.h>
  #include <errno.h>
  #include <signal.h>
  #include <string.h>

  /* Auto-reaping would release a registered pid behind the forwarder's
     back. Observe the caller's disposition without changing any of it. */
  static int rb_od_reaping_error(void) {
    struct sigaction current;
    if (sigaction(SIGCHLD, NULL, &current) != 0) return errno;
    if (current.sa_handler == SIG_IGN || (current.sa_flags & SA_NOCLDWAIT))
      return EINVAL;
    return 0;
  }

  /* Readiness must not reap a pid while the signal table still owns it. */
  static int rb_od_child_running(int pid) {
    siginfo_t info;
    int result;
    do {
      memset(&info, 0, sizeof(info));
      result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT);
    } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    return info.si_pid == 0;
  }

  #define RB_OD_MAX_PIDS 16
  #define RB_OD_SIGNAL_COUNT 4

  static const int rb_od_signals[RB_OD_SIGNAL_COUNT] =
    { SIGTERM, SIGINT, SIGHUP, SIGQUIT };
  static volatile sig_atomic_t rb_od_pids[RB_OD_MAX_PIDS];
  static struct sigaction rb_od_previous[RB_OD_SIGNAL_COUNT];
  static int rb_od_hooked[RB_OD_SIGNAL_COUNT];
  static int rb_od_armed = 0;

  static void rb_od_handler(int sig, siginfo_t *info, void *context) {
    int saved_errno = errno;
    int i;
    for (i = 0; i < RB_OD_MAX_PIDS; i++) {
      pid_t pid = (pid_t)rb_od_pids[i];
      if (pid > 0) kill(pid, SIGTERM);
    }
    for (i = 0; i < RB_OD_SIGNAL_COUNT; i++) {
      if (rb_od_signals[i] != sig) continue;
      const struct sigaction *previous = &rb_od_previous[i];
      if (previous->sa_handler == SIG_DFL) {
        /* The default action, so the process dies OF this signal. It is
           usually blocked while this handler runs, so the re-raise
           is delivered as soon as the handler returns -- with the default
           disposition, which kills. */
        struct sigaction dfl;
        memset(&dfl, 0, sizeof(dfl));
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        sigaction(sig, &dfl, NULL);
        raise(sig);
      } else if (previous->sa_handler == SIG_IGN) {
        /* Special dispositions remain special even with SA_SIGINFO set. */
      } else if (previous->sa_flags & SA_SIGINFO) {
        previous->sa_sigaction(sig, info, context);
      } else {
        previous->sa_handler(sig);
      }
      break;
    }
    errno = saved_errno;
  }

  static int rb_od_is_ours(int sig) {
    struct sigaction current;
    if (sigaction(sig, NULL, &current) != 0) return 0;
    return (current.sa_flags & SA_SIGINFO) &&
           current.sa_sigaction == rb_od_handler;
  }

  static void rb_od_disarm(void) {
    int i;
    if (!rb_od_armed) return;
    for (i = 0; i < RB_OD_SIGNAL_COUNT; i++) {
      if (rb_od_hooked[i] && rb_od_is_ours(rb_od_signals[i]))
        sigaction(rb_od_signals[i], &rb_od_previous[i], NULL);
      rb_od_hooked[i] = 0;
    }
    rb_od_armed = 0;
  }

  static int rb_od_arm(void) {
    int i;
    struct sigaction ours;
    for (i = 0; i < RB_OD_SIGNAL_COUNT; i++) {
      /* A returning SA_RESETHAND callback leaves the kernel disposition
         default while existing ownership remains registered. A NEW child
         still needs forwarding. Keep callbacks we still own (recapturing
         ours would recurse), and otherwise chain the disposition NOW in
         force, including a handler the application installed meanwhile. */
      if (rb_od_hooked[i] && rb_od_is_ours(rb_od_signals[i])) continue;
      rb_od_hooked[i] = 0;
      if (sigaction(rb_od_signals[i], NULL, &rb_od_previous[i]) != 0) continue;
      /* An IGNORED signal does not end the invocation, so it must not end
         its daemon: leave it exactly as it is. */
      if (rb_od_previous[i].sa_handler == SIG_IGN) continue;
      /* Preserve the prior mask and delivery semantics, including
         SA_RESTART, SA_NODEFER and SA_RESETHAND. Only the callback changes;
         SA_SIGINFO gives the forwarder enough information to chain either
         form of previous callback. */
      ours = rb_od_previous[i];
      ours.sa_sigaction = rb_od_handler;
      ours.sa_flags |= SA_SIGINFO;
      if (sigaction(rb_od_signals[i], &ours, NULL) == 0) rb_od_hooked[i] = 1;
    }
    rb_od_armed = 1;
    return 1;
  }

  static int rb_od_register(int pid) {
    int i;
    int error;
    if (pid <= 0) { errno = EINVAL; return 0; }
    error = rb_od_reaping_error();
    if (error != 0) { errno = error; return 0; }
    for (i = 0; i < RB_OD_MAX_PIDS; i++) {
      if (rb_od_pids[i] == 0) {
        /* The slot is filled BEFORE the handlers exist, so a signal that
           arrives the instant they do already finds the pid. */
        rb_od_pids[i] = pid;
        return rb_od_arm();
      }
    }
    errno = ENOSPC;
    return 0;
  }

  static void rb_od_unregister(int pid) {
    int i, remaining = 0;
    if (pid <= 0) return;
    for (i = 0; i < RB_OD_MAX_PIDS; i++) {
      if (rb_od_pids[i] == pid) rb_od_pids[i] = 0;
      if (rb_od_pids[i] != 0) remaining++;
    }
    if (remaining == 0) rb_od_disarm();
  }

  static int rb_od_owned_count(void) {
    int i, count = 0;
    for (i = 0; i < RB_OD_MAX_PIDS; i++) if (rb_od_pids[i] != 0) count++;
    return count;
  }

  static int rb_od_signal_is_hooked(int sig) {
    return rb_od_armed && rb_od_is_ours(sig);
  }
  """.}

  proc rbOdReapingError(): cint {.importc: "rb_od_reaping_error", nodecl.}
  proc rbOdChildRunning(pid: cint): cint {.importc: "rb_od_child_running", nodecl.}
  proc rbOdRegister(pid: cint): cint {.importc: "rb_od_register", nodecl.}
  proc rbOdUnregister(pid: cint) {.importc: "rb_od_unregister", nodecl.}
  proc rbOdOwnedCount(): cint {.importc: "rb_od_owned_count", nodecl.}
  proc rbOdSignalIsHooked(sig: cint): cint
    {.importc: "rb_od_signal_is_hooked", nodecl.}

proc ensureOwnedDaemonReaping*() =
  ## Refuse automatic ownership before spawning when SIGCHLD would let the
  ## kernel reap children without our consent. Preserve the caller's handler,
  ## mask and flags. Reusing an existing daemon does not require ownership.
  when defined(posix):
    let error = rbOdReapingError()
    if error != 0:
      raiseOSError(OSErrorCode(error), "cannot auto-start runquotad: SIGCHLD " &
        "must keep exited children waitable; SIG_IGN and SA_NOCLDWAIT " &
        "are unsupported for owned daemons")
  else:
    discard

proc registerOwnedDaemon*(pid: int): bool =
  ## Starts forwarding SIGTERM/SIGINT/SIGHUP/SIGQUIT to `pid` (as SIGTERM),
  ## arming or rearming handlers as needed on registration. Call it right
  ## after the spawn, BEFORE waiting for the daemon to become ready: a signal
  ## during that wait must stop the daemon too. `false` when the pid could not
  ## be recorded (the table is full, the pid is not positive, or SIGCHLD
  ## auto-reaps children); always `false` on Windows, whose daemon is not owned.
  ## The caller must keep ordinary waitable-child SIGCHLD semantics while
  ## ownership lasts and unregister BEFORE any other code reaps this child.
  when defined(posix):
    result = rbOdRegister(cint(pid)) != 0
  else:
    discard pid
    result = false

proc unregisterOwnedDaemon*(pid: int) =
  ## Stops forwarding to `pid`, and restores the previous dispositions when
  ## no owned daemon remains. Call it BEFORE terminating and reaping the
  ## daemon, so the handler never signals a pid that may have been reused.
  ## Unregistering a pid that is not registered is a no-op.
  when defined(posix):
    rbOdUnregister(cint(pid))
  else:
    discard pid

proc ownedDaemonCount*(): int =
  ## How many daemons are currently registered. For tests.
  when defined(posix):
    result = int(rbOdOwnedCount())
  else:
    result = 0

proc ownedDaemonSignalIsHooked*(sig: cint): bool =
  ## Whether `sig` is currently routed through the forwarder. For tests.
  when defined(posix):
    result = rbOdSignalIsHooked(sig) != 0
  else:
    discard sig
    result = false

proc ownedDaemonStillRunning*(process: Process): bool =
  ## Observe readiness without releasing the kernel's reservation of an owned
  ## child's pid. POSIX osproc.running reaps an exited child; waitid WNOWAIT
  ## leaves it waitable until the caller unregisters before ordinary cleanup.
  ## Errors (including ECHILD) leave that cleanup to the caller too.
  when defined(posix):
    let state = rbOdChildRunning(cint(processID(process)))
    if state < 0:
      raiseOSError(OSErrorCode(-state))
    result = state != 0
  else:
    result = process.running
