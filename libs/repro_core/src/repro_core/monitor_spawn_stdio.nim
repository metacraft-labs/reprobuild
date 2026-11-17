## The stdio, stdin, umask and descriptor-table state a child started by
## io-mon's in-process spawn (``startMonitor`` / ``runMonitored``) inherits.
##
## io-mon spawns its monitored root with ``poParentStreams``: the child
## inherits THIS process's descriptors 0, 1 and 2, its file-creation mask, and
## every descriptor above 2 not marked close-on-exec. Every in-process host of
## io-mon therefore has to establish those across the spawn itself. This
## module is the one implementation of that, used by the build engine around
## each hosted action (``startMonitorHost``) and by the Go standard convention
## around the monitored ``go list`` it runs at graph-emission time
## (``repro_standard_provider/conventions/go.nim``). It was the engine's own
## private helper until a second host needed it; the reasoning below is the
## engine's, and holds for any single-threaded host.
##
## THIS MODULE STARTS NOTHING (the caller's ``startMonitor`` does), so the
## build engine — whose imports ``t_every_launch_path_is_monitored`` audits for
## ways to spawn a child — can import it.

type MonitorSpawnContextError* = object of OSError
  ## Raised when the spawn context cannot be established; nothing has been
  ## changed in the process when it is.

proc raiseSpawnContext(message: string) {.noreturn.} =
  raise newException(MonitorSpawnContextError, message)

when defined(posix):
  from std/posix import Mode, umask, dup2, close, fcntl, F_DUPFD_CLOEXEC
  import repro_core/descriptor_inheritance

  type MonitorSpawnContext* = object
    ## The descriptors and mask ``beginMonitorSpawnContext`` changed, held
    ## so ``endMonitorSpawnContext`` can put every one of them back.
    savedIn: cint
    savedOut: cint
    savedErr: cint
    nullFile: File
    outFile: File
    errFile: File
    savedMask: Mode
    madeCloseOnExec: seq[cint]
    active: bool

  proc beginMonitorSpawnContext*(outPath, errPath: string): MonitorSpawnContext =
    ## Re-establish, across io-mon's spawn, the three things the retired
    ## ``/bin/sh -c 'umask 022 && <repro> internal io monitor …'`` wrapper and
    ## RunQuota's process backend used to provide for free.
    ##
    ## STDIO. io-mon spawns with ``poParentStreams``, so the monitored child
    ## inherits THIS process's descriptors 0, 1 and 2 — for the engine, the
    ## user's terminal, not a per-action capture. Pointing 1 and 2 at two
    ## per-action files across the spawn gives the engine back separate
    ## ``stdout`` and ``stderr``, and does it WITHOUT the monitored tree
    ## opening anything: the child inherits descriptors that are already open,
    ## so no ``open`` of a log path enters its dependency evidence. (A shell
    ## redirect inside the monitored command would have put both log paths
    ## into ``monitorWrites`` — which is why this is done here and not there.)
    ##
    ## STDIN, and it is descriptor 0 that makes this a correctness fix rather
    ## than a capture convenience. EVERY other launch path gives the child
    ## ``/dev/null`` on descriptor 0 — RunQuota's POSIX backend opens it
    ## explicitly before ``execvp`` (``runquota_process.nim``), so an action
    ## that reads stdin sees immediate EOF. ``poParentStreams`` hands the child
    ## the ENGINE's stdin instead, which in a normal ``repro build`` is the
    ## user's terminal: a monitored action that reads stdin would block the
    ## build waiting for a keystroke, or worse, eat one. Redirecting it here
    ## makes the hosted path answer EOF like every other path.
    ##
    ## UMASK. ``umaskWrappedArgv`` (M9.R.36.3) pins every spawned tool to the
    ## canonical 0022 mask by wrapping the argv in a shell. A hosted action has
    ## no wrapper shell to carry it, and monitoring one would add the shell's
    ## own reads to the action's evidence, so the mask is set here and restored
    ## immediately; a child inherits it across ``fork``.
    ##
    ## SAFE BECAUSE THE SCHEDULER IS SINGLE-THREADED, AND BECAUSE THE ONLY
    ## OTHER THREADS OPEN NOTHING. The engine runs N concurrent child
    ## PROCESSES from one poll loop, not N threads, so no other SCHEDULER code
    ## can observe the window between this call and
    ## ``endMonitorSpawnContext``.
    ##
    ## The qualification is Engine-Threadpool TP-1's, and the previous version
    ## of this comment — "``createThread`` has zero occurrences in this
    ## library" — was already wrong when it was written: HM-5's flush worker
    ## was in ``repro_build_engine/monitor_flush.nim``, inside this library.
    ## The claim that MATTERS was never the thread count anyway, it is what
    ## those threads do, and it is checked rather than assumed in
    ## ``worker_pool.nim``'s header: a pool worker opens no file and creates
    ## no file, so neither the ``dup2`` on 0/1/2 nor the ``umask`` can be
    ## observed by one. A future pool tenant that opens or creates a file
    ## re-opens both questions, and it breaks by interleaving one action's
    ## output into another's.
    ##
    ## EVERY DESCRIPTOR ABOVE 2, which is the same parity question as stdin
    ## one number further up. RunQuota's POSIX backend closes every inherited
    ## descriptor above 2 between ``fork`` and ``execvp``
    ## (``closeInheritedChildFds`` in ``runquota_process.nim``), so a wrapped
    ## action — and the ``repro internal io monitor`` reference it is compared
    ## against — starts with 0, 1 and 2 and nothing else. io-mon's spawn closes
    ## nothing, so a hosted action used to start with whatever this process
    ## held open without ``FD_CLOEXEC``: the three stdio copies saved just
    ## below (``dup`` does not set the flag), plus anything the engine's own
    ## parent leaked into it. The test runner hands every test process its own
    ## pipe ends that way, and under a parallel run the other tests' too.
    ## Those descriptors are real kernel objects inside the monitored tree —
    ## an action that ``fstat``s or reads one sees a pipe it did not create,
    ## and every descriptor it opens itself lands at a different number than
    ## it would under the wrapper, which is how TP-2's evidence comparison
    ## caught it (a ``chan=localfd role=create`` record carrying fd 22 hosted
    ## and fd 4 wrapped). Marking them close-on-exec for the spawn window
    ## gives the hosted child the same table the other launch paths give; the
    ## flags are restored in ``endMonitorSpawnContext``.
    flushFile(stdout)
    flushFile(stderr)
    result.savedIn = fcntl(cint(0), F_DUPFD_CLOEXEC, cint(3))
    result.savedOut = fcntl(cint(1), F_DUPFD_CLOEXEC, cint(3))
    result.savedErr = fcntl(cint(2), F_DUPFD_CLOEXEC, cint(3))
    if result.savedIn < 0 or result.savedOut < 0 or result.savedErr < 0:
      if result.savedIn >= 0: discard close(result.savedIn)
      if result.savedOut >= 0: discard close(result.savedOut)
      if result.savedErr >= 0: discard close(result.savedErr)
      raiseSpawnContext("in-process monitor host: cannot duplicate stdio")

    proc closeSaved(ctx: MonitorSpawnContext) =
      discard close(ctx.savedIn)
      discard close(ctx.savedOut)
      discard close(ctx.savedErr)

    if not open(result.nullFile, "/dev/null", fmRead):
      closeSaved(result)
      raiseSpawnContext("in-process monitor host: cannot open /dev/null")
    if not open(result.outFile, outPath, fmWrite):
      close(result.nullFile)
      closeSaved(result)
      raiseSpawnContext("in-process monitor host: cannot open stdout capture " &
        outPath)
    if not open(result.errFile, errPath, fmWrite):
      close(result.nullFile)
      close(result.outFile)
      closeSaved(result)
      raiseSpawnContext("in-process monitor host: cannot open stderr capture " &
        errPath)
    discard dup2(cint(getFileHandle(result.nullFile)), cint(0))
    discard dup2(cint(getFileHandle(result.outFile)), cint(1))
    discard dup2(cint(getFileHandle(result.errFile)), cint(2))
    result.savedMask = umask(Mode(0o022))
    result.madeCloseOnExec = markInheritableDescriptorsCloseOnExec()
    result.active = true

  proc endMonitorSpawnContext*(ctx: var MonitorSpawnContext) =
    if not ctx.active:
      return
    ctx.active = false
    restoreInheritableDescriptors(ctx.madeCloseOnExec)
    discard umask(ctx.savedMask)
    flushFile(stdout)
    flushFile(stderr)
    discard dup2(ctx.savedIn, cint(0))
    discard dup2(ctx.savedOut, cint(1))
    discard dup2(ctx.savedErr, cint(2))
    discard close(ctx.savedIn)
    discard close(ctx.savedOut)
    discard close(ctx.savedErr)
    close(ctx.nullFile)
    close(ctx.outFile)
    close(ctx.errFile)
else:
  type MonitorSpawnContext* = object
    active: bool

  proc beginMonitorSpawnContext*(outPath, errPath: string): MonitorSpawnContext =
    discard outPath
    discard errPath

  proc endMonitorSpawnContext*(ctx: var MonitorSpawnContext) =
    discard ctx

