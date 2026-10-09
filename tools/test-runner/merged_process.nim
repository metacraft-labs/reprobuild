## Release the pipes of a child started with ``poStdErrToStdOut``.
##
## A module of its own so the regression test can drive exactly the code the
## runner runs (``tests/unit/t_runner_closes_merged_pipes_once.nim``).

import std/[osproc, streams]

proc closeMergedProcess*(p: Process) =
  ## Close the pipes of a child started with ``poStdErrToStdOut`` — every
  ## supervisor and direct child this runner spawns — closing each
  ## descriptor EXACTLY ONCE. Use this instead of ``osproc.close``.
  ##
  ## ``osproc.close`` double-closes on POSIX. With ``poStdErrToStdOut``,
  ## ``startProcess`` sets ``errHandle = outHandle``, and the POSIX
  ## ``close`` closes the output (through ``outStream`` when one exists,
  ## else the raw handle) and then calls ``close(errHandle)`` on the SAME
  ## descriptor number a second time; unlike the Windows branch it has no
  ## ``outHandle != errHandle`` guard. In a single-threaded program the
  ## second ``close`` is a harmless ``EBADF``. In this runner it is not:
  ## between the two calls any other worker thread may be handed that
  ## lowest-free number — by the ``pipe()`` inside its own
  ## ``startProcess`` (under ``spawnLock``, which does not cover
  ## ``close``), by ``opendir("/proc")`` in the owner-token scan, by a
  ## result-file ``open`` — and the second ``close`` then silently closes
  ## THAT descriptor out from under its owner. Under ``--threads=8`` this
  ## produced, in different full runs:
  ##
  ## * ``supervisor did not become ready ... observed: end of stream`` with
  ##   the supervisor still running: the spawning worker's pipe read end
  ##   was closed (``readLine`` fails with EBADF, which reads as EOF), or
  ##   was reused by an empty file;
  ## * ``spawn failed (i/o): errno: 21 'Is a directory'``: the read end was
  ##   closed and the number re-issued to ``opendir("/proc")`` before the
  ##   handshake ``readLine`` ran;
  ## * ``spawn failed: Bad file descriptor``: a pipe end inside
  ##   ``startProcess`` itself was closed before the fork's ``dup2``.
  ##
  ## Serialising the spawn (``spawnLock``) and retrying it could never fix
  ## any of these, because the destructive ``close`` runs on another
  ## thread outside the lock.
  when defined(posix):
    # Both descriptors are closed THROUGH their streams. ``inputStream`` /
    # ``outputStream`` create the stream on first use, so this works whether
    # or not anything touched it, and ``FileStream`` nils its ``File`` on
    # close, so a second call on the same ``Process`` is a no-op rather than
    # another stale ``close`` of a number some other thread may now own.
    # The merged stdout/stderr descriptor is the output stream's; there is
    # no separate error descriptor to close.
    p.inputStream.close()
    p.outputStream.close()
  else:
    # Windows ``osproc.close`` guards ``outHandle != errHandle`` and also
    # releases the process/thread handles; it is correct there.
    close(p)
