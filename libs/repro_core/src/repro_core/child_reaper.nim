## Reaping a child this process started and then leaves running.
##
## THE DEFECT THIS EXISTS FOR
## ==========================
##
## A process that starts a helper meant to outlive the request -- the shared
## Nix evaluation helper is the first -- is still that helper's PARENT:
## ``poDaemon`` gives the child its own session, it does not reparent it.
## When the helper later exits by itself (it idles out), it stays a
## ``<defunct>`` child until its parent waits for it, and a parent that
## dropped its ``Process`` handle once the helper answered never does. A user
## daemon's build worker and a direct ``repro build`` were both seen holding
## ``[reprobuild-nix-] <defunct>`` for the rest of the build (reprobuild-pm
## issue ``2026-11-19-a-daemon-hosted-build-blocks-its-client-forever-when-
## the-workers-nix-child-has-died.md``).
##
## A zombie is not only untidy. It keeps its pid and its ``/proc`` entry, so a
## pid probe reads it as alive, and anything that waits for all of a process's
## children waits for it.
##
## WHY A THREAD, AND NOT ``SIGCHLD`` OR ``waitpid(-1)``
## ====================================================
##
## Ignoring ``SIGCHLD`` or reaping with ``waitpid(-1)`` would take the exit
## status of every OTHER child of the process -- each ``osproc`` child, each
## monitored action -- away from the code that is waiting for it. The thread
## started here waits for ONE pid, the one it was given, and nothing else.
##
## The thread is created with EVERY SIGNAL BLOCKED. A signal sent to the
## process is delivered to any thread that does not block it, and this one
## must never be the thread that runs the process's interrupt handler in
## place of the thread that is waiting to be interrupted.
##
## While it waits it holds no lock and touches no shared state. Starting and
## ending a thread does take the allocator's lock for a moment, as any other
## thread of this (already multi-threaded) process does.
##
## THIS MODULE STARTS NOTHING. It imports ``waitpid`` and no way to spawn a
## child, so the build engine -- whose imports
## ``t_every_launch_path_is_monitored`` audits -- can import it.

when defined(posix):
  from std/posix import Pid, Pthread, Sigset, waitpid, EINTR, errno,
    sigfillset, pthread_sigmask, pthread_detach, SIG_SETMASK

  proc waitForOneChild(pid: int) {.thread.} =
    var status: cint = 0
    while true:
      let waited = waitpid(Pid(pid), status, 0)
      if waited == Pid(pid):
        return
      if waited < 0 and errno != EINTR:
        # ``ECHILD``: not our child, or already reaped. Nothing is owed.
        return

proc reapWhenExited*(pid: int) =
  ## Arrange for the child ``pid`` of THIS process to be waited for when it
  ## exits, however long that takes, without blocking the caller. The caller
  ## gives up the child's exit status: call this only once nothing else will
  ## wait for ``pid``.
  ##
  ## Best effort in one respect: when no thread can be started the child is
  ## not waited for, and is reaped by whoever reaps this process's orphans
  ## once this process exits, as it was before this existed.
  ##
  ## A no-op where there are no zombies (Windows), and for a ``pid`` that is
  ## not a child of this process.
  when defined(posix):
    if pid <= 0:
      return
    # The thread object must outlive the thread, which outlives this call by
    # the child's lifetime; it is shared memory that is never freed. One per
    # child handed over, so a handful per process. The thread itself is
    # detached, so its stack is released when it ends.
    let thread = createShared(Thread[int])
    # A new thread starts with its creator's signal mask.
    var allSignals, previous: Sigset
    discard sigfillset(allSignals)
    let masked = pthread_sigmask(SIG_SETMASK, allSignals, previous) == 0
    try:
      createThread(thread[], waitForOneChild, pid)
      discard pthread_detach(cast[Pthread](thread[].handle))
    except ResourceExhaustedError:
      freeShared(thread)
    finally:
      if masked:
        discard pthread_sigmask(SIG_SETMASK, previous, allSignals)
  else:
    discard pid
