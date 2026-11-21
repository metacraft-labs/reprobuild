## Releasing an ``osproc.Process`` without ``osproc.close``'s double close.
##
## THE DEFECT (Nim stdlib, POSIX ``proc close(p: Process)``)
## ========================================================
##
## ``startProcess`` with ``options = {poStdErrToStdOut}`` sets
## ``errHandle = outHandle``. ``close`` then releases the output (through
## ``outStream`` when one exists, else the raw handle) and afterwards runs
## ``close(errStream)`` / ``close(errHandle)`` on the SAME descriptor number a
## second time. The Windows branch guards this with
## ``if p.outHandle != p.errHandle``; the POSIX branch has none. Everything
## built on ``close`` inherits it: ``execCmdEx`` and ``execProcess`` both
## default to ``poStdErrToStdOut``. Reproduction and upstream report:
## reprobuild-specs ``upstream-bugs/nim-osproc-close-double-closes-merged-stderr/``.
##
## Single-threaded, the second ``close`` is a harmless ``EBADF``. With other
## threads in the process it is not: between the two calls any other thread
## may be handed that lowest-free number — by its own ``pipe()`` in
## ``startProcess``, an ``open()``, an ``opendir()``, a socket — and the
## second ``close`` then silently closes THAT descriptor out from under its
## owner. In ``repro_test_runner`` (8-16 worker threads) this produced, in full
## suite runs 25/26, "supervisor did not become ready ... end of stream" with
## the supervisor still running, ``spawn failed (i/o): errno: 21 'Is a
## directory'`` and ``spawn failed: Bad file descriptor``.
##
## WHO MUST USE THIS
## =================
##
## Code that can run while ANOTHER thread of the same process allocates or
## uses descriptors: the test runner's workers, and the build engine's
## scheduler thread whenever its worker pool is live (in-process monitor
## hosting: pooled ``finishMonitor`` and depfile flushes open, write and
## rename files concurrently with the scheduler's own spawns) — which includes
## every built-in executor the scheduler calls inline (workspace VCS, foreign
## provisioners, the elevated-exec broker). Single-threaded CLI paths are
## unaffected and are not required to switch.
##
## THIS MODULE STARTS NOTHING. ``execCmdExCloseOnce`` — the ``execCmdEx``
## equivalent — lives in ``repro_core/process_exec`` so that the build engine,
## whose imports ``t_every_launch_path_is_monitored`` audits for ways to spawn
## a child, can import the release without importing a spawn primitive.

import std/[osproc, streams]

when defined(posix):
  import std/importutils

proc closeProcessOnce*(p: Process) =
  ## Release ``p``'s pipes, closing each descriptor EXACTLY ONCE. A drop-in
  ## replacement for ``osproc.close`` for any option set: merged
  ## (``poStdErrToStdOut``) or separate stderr, streams already created or
  ## not, ``poParentStreams`` (nothing to release on POSIX, as in
  ## ``osproc.close``).
  ##
  ## Safe to call twice: every descriptor is closed THROUGH its stream, and
  ## ``FileStream`` nils its ``File`` on close, so a repeated call is a no-op
  ## rather than another stale ``close`` of a number some other thread may
  ## own by now. (``inputStream`` / ``outputStream`` / ``errorStream`` create
  ## the stream on first use, so this also works when nothing touched them.)
  when defined(posix):
    privateAccess(Process)
    if poParentStreams in p.options:
      return
    let merged = p.errHandle == p.outHandle
    try:
      p.inputStream.close()
    finally:
      try:
        p.outputStream.close()
      finally:
        if not merged:
          # A separate stderr pipe is a descriptor of its own; release it.
          # The merged one IS the output stream's and was closed above.
          p.errorStream.close()
  else:
    # Windows ``osproc.close`` guards ``outHandle != errHandle`` and also
    # releases the process/thread handles; it is correct there.
    close(p)
