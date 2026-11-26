## A terminating signal that reaches a build cancels the build.
##
## The scheduler puts every externally launched action in a process group of
## its own (`assignProcessGroup`), and the RunQuota launch paths give each
## action a tree of its own as well. That is what lets cancellation tear a
## shell wrapper down together with its children. It also means a signal sent
## to the engine -- `timeout` sending SIGTERM, a terminal's Ctrl-C reaching
## the foreground group, a closed terminal's SIGHUP -- reaches the engine
## only. Under the default disposition the engine then died on the spot: the
## scheduler's teardown (the `finally` in `runBuild`) never ran, and every
## running action, with its io monitor and its whole tree, kept running as an
## orphan. An interface extraction that was spinning under a second
## `LD_PRELOAD` interposer was left burning a core for hours after `timeout`
## killed the `repro lint` that started it.
##
## While a build runs, `acquireTerminationGuard` therefore catches SIGINT,
## SIGTERM and SIGHUP and records which one arrived. The scheduler polls
## `terminationSignal` with its other cancellation checks, so the build
## unwinds through its ordinary teardown, which stops every running action's
## tree. When the last build in the process has finished unwinding,
## `releaseTerminationGuard` restores the previous dispositions and raises the
## recorded signal again, so the process still ends the way the sender asked:
## killed by that signal, with the exit status a shell or `timeout` reports
## for it. Only the delay is new.
##
## Rules this module keeps:
##
## * A disposition is taken over only while it is the default one: `SIG_DFL`,
##   or for SIGINT the Nim runtime's own handler, which ends the process the
##   same way after printing (`isDefaultDisposition`). A host that ignores a
##   signal, or handles it itself (a daemon with a shutdown handler, a test
##   harness, a Nim `setControlCHook`), keeps exactly what it installed, and
##   the build sees no signal through this module. On release the previous
##   disposition is restored before the signal is raised again, so the Nim
##   runtime still prints its interrupt message.
## * Builds nest and run concurrently (the interface extraction runs a build
##   inside the command's own build; the daemon serves several builds). The
##   guard is reference-counted: the first acquire installs the handlers, the
##   last release restores them, and only that last release raises the
##   signal again. Every build in between sees the recorded signal and
##   cancels.
## * A second terminating signal while the first is being acted on is not
##   deferred again: the handler restores the default disposition and raises
##   it, so a stuck teardown can still be interrupted the usual way.
## * The handler acts only in the process that installed it. A child forked
##   by the engine inherits the handlers until it calls `execve`, and one
##   cancelled in that window must die as before, not record the signal in
##   its own copy of this module and then exec and run on.
## * The handler only stores a number, or restores the default and raises,
##   so it calls nothing that is not async-signal-safe (`signal(7)`, "Async-
##   signal-safe functions": https://man7.org/linux/man-pages/man7/signal-safety.7.html).
##
## SIGKILL cannot be caught, so a build killed with it still leaves its
## actions behind; nothing in the process can prevent that.
##
## Windows has no POSIX signals, so this module is inert there. How a
## console interrupt, or a terminated engine, reaches a Windows action tree
## is a separate question this module does not answer.

when defined(posix):
  import std/[locks, posix]

  const GuardedSignalCount = 3

  proc guardedSignals(): array[GuardedSignalCount, cint] =
    ## SIGINT, SIGTERM and SIGHUP. A proc, not a `const`: on macOS
    ## `std/posix` binds the signal numbers as `importc` variables, which a
    ## constant expression cannot read.
    [SIGINT, SIGTERM, SIGHUP]

  var
    receivedSignal: cint
      ## The first terminating signal delivered while a guard is held, or 0.
      ## Written by the handler (atomically) and read by any thread.
    guardLock: Lock
    guardCount: int
      ## Builds currently holding the guard. Under ``guardLock``.
    installed: array[GuardedSignalCount, bool]
      ## Which of ``guardedSignals()`` this module took over. Under
      ## ``guardLock``.
    previous: array[GuardedSignalCount, Sigaction]
      ## What each signal's disposition was before the take-over.
    guardPid: cint
      ## The process that installed the handlers. Stored before they are
      ## installed and read by the handler, so it can tell the engine from a
      ## child forked by the engine that has not yet called `execve`.

  initLock(guardLock)

  proc c_sigaction(sig: cint; act, oldAct: ptr Sigaction): cint {.
    importc: "sigaction", header: "<signal.h>".}
    ## `sigaction(2)` with both pointers nullable, as C declares it.

  proc c_pthread_sigmask(how: cint; set, oldSet: ptr Sigset): cint {.
    importc: "pthread_sigmask", header: "<signal.h>".}

  proc c_raise(sig: cint): cint {.importc: "raise", header: "<signal.h>".}
    ## `raise(3)`: in a threaded process it is `pthread_kill(pthread_self(),
    ## sig)`, a signal directed at the calling thread. `kill(getpid(), sig)`
    ## is directed at the process, and the kernel may hand it to any thread
    ## that does not block it, so this thread could return from the build
    ## (and its caller report a failure) before the signal is acted on.

  proc onTerminationSignal(sig: cint) {.noconv.} =
    # Async-signal-safe only: atomics, `getpid`, `signal` and `kill` (all
    # listed in signal-safety(7)).
    if getpid() != Pid(atomicLoadN(addr guardPid, ATOMIC_SEQ_CST)):
      # A child the engine forked keeps the engine's handlers until its
      # `execve`, and an action launcher that forks (RunQuota's does) may
      # cancel that child in exactly that window: a batch rolled back right
      # after it started one. Recording the signal there would swallow it,
      # and the child would exec and run on as an orphan. Die as the default
      # disposition would have; the signal is blocked while this handler
      # runs, so it is delivered the moment the handler returns.
      discard signal(sig, SIG_DFL)
      discard kill(getpid(), sig)
      return
    var expected: cint = 0
    if not atomicCompareExchangeN(addr receivedSignal, addr expected, sig,
        false, ATOMIC_SEQ_CST, ATOMIC_SEQ_CST):
      # A second terminating signal: the teardown the first one asked for
      # did not finish quickly enough for whoever is sending. Die now, as the
      # default disposition would have.
      discard signal(sig, SIG_DFL)
      discard kill(getpid(), sig)

  when not defined(noSignalHandler) and not defined(useNimRtl):
    proc nimRuntimeSignalHandler(sign: cint) {.importc: "signalHandler",
      noconv.}
      ## The handler the Nim runtime installs for SIGINT in every program
      ## (`lib/system/excpt.nim`, `registerSignalHandler`). It prints the
      ## interrupt and a stack trace, restores `SIG_DFL` and raises the
      ## signal again, so the process ends exactly as under the default
      ## disposition. It is the SIGINT disposition of every Nim program that
      ## has not replaced it, the engine included, so it counts as the
      ## default here; a `setControlCHook` replaces it and does not.

  proc isDefaultDisposition(sig: cint; current: var Sigaction): bool =
    ## Whether the disposition of `sig` ends the process with that signal
    ## and nothing else: `SIG_DFL`, or the Nim runtime's own handler, which
    ## does the same after printing.
    if c_sigaction(sig, nil, addr current) != 0:
      return false
    # A handler installed with SA_SIGINFO is never one of those.
    if (current.sa_flags and SA_SIGINFO) != 0:
      return false
    let handler = cast[pointer](current.sa_handler)
    if handler == cast[pointer](SIG_DFL):
      return true
    when declared(nimRuntimeSignalHandler):
      handler == cast[pointer](nimRuntimeSignalHandler)
    else:
      false

  proc acquireTerminationGuard*() =
    ## Called when a build starts. Takes over SIGINT, SIGTERM and SIGHUP for
    ## as long as any build in the process runs, each only if its disposition
    ## is still the default one.
    withLock guardLock:
      inc guardCount
      if guardCount > 1:
        return
      atomicStoreN(addr guardPid, cint(getpid()), ATOMIC_SEQ_CST)
      for i, sig in guardedSignals():
        installed[i] = false
        var current: Sigaction
        if not isDefaultDisposition(sig, current):
          continue
        var handler: Sigaction
        handler.sa_handler = onTerminationSignal
        discard sigemptyset(handler.sa_mask)
        # SA_RESTART: an interrupted read or wait elsewhere in the engine
        # resumes instead of failing with EINTR; the scheduler notices the
        # signal by polling, not by an interrupted call.
        handler.sa_flags = SA_RESTART
        if c_sigaction(sig, addr handler, addr previous[i]) == 0:
          installed[i] = true

  proc terminationSignal*(): cint =
    ## The terminating signal delivered while a build held the guard, or 0.
    ## Non-zero means the process is shutting down at a sender's request:
    ## every running build cancels.
    atomicLoadN(addr receivedSignal, ATOMIC_SEQ_CST)

  proc releaseTerminationGuard*() =
    ## Called when a build has finished, including its teardown. The last
    ## build to finish restores the dispositions it found and, when a
    ## terminating signal arrived meanwhile, raises that signal again under
    ## the restored disposition, which ends the process.
    var reraise: cint = 0
    withLock guardLock:
      if guardCount == 0:
        return
      dec guardCount
      if guardCount > 0:
        return
      for i, sig in guardedSignals():
        if installed[i]:
          discard c_sigaction(sig, addr previous[i], nil)
          installed[i] = false
      reraise = terminationSignal()
    if reraise != 0:
      # Unblock it in this thread and direct it at this thread, so it is
      # delivered here before `raise` returns: under `SIG_DFL` the process
      # ends at once, and the Nim runtime's SIGINT handler runs on this
      # thread and then ends it the same way.
      var only: Sigset
      discard sigemptyset(only)
      discard sigaddset(only, reraise)
      discard c_pthread_sigmask(SIG_UNBLOCK, addr only, nil)
      discard c_raise(reraise)

else:
  proc acquireTerminationGuard*() = discard
  proc terminationSignal*(): cint = 0
  proc releaseTerminationGuard*() = discard
