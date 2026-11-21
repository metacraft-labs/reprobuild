## Keeping this process's descriptors above 2 out of a child it starts.
##
## THE PROBLEM. A POSIX child inherits every descriptor its parent holds
## without ``FD_CLOEXEC``, and Nim's ``osproc`` -- like plenty of other code --
## creates descriptors without it. Its ``startProcess`` builds its pipes with
## plain ``pipe()`` and ``dup2``s them onto the child's 0/1/2 WITHOUT closing
## the originals, so a process started that way holds extra copies of its own
## stdio pipe ends at numbers above 2, and passes them on to everything it
## starts. A descendant holding a copy of a pipe's write end keeps that pipe
## open: a caller reading the process's output to end of file then waits for
## the descendant to exit, not for the process it started.
##
## THE RULE this module implements is RunQuota's (``closeInheritedChildFds``
## in ``runquota_process.nim``): a child starts with 0, 1 and 2 and nothing
## else. ``osproc``'s spawn offers no hook between ``fork`` and ``exec`` in
## which to close descriptors, so the rule is applied from the PARENT side
## instead: every descriptor above 2 is marked close-on-exec across the spawn,
## and the flags are put back afterwards. Only the flag moves; no descriptor is
## closed, so nothing the process itself is using changes under it.
##
## WHO USES IT. The build engine around io-mon's in-process spawn
## (``beginMonitorSpawnContext``), and ``repro_cli_support`` around the spawn of
## the ``runquotad`` an invocation owns (``startAutoRunQuotaIfNeeded``) and
## around the detached post-commit cache push (``spawnAsyncCachePush``).
##
## THE WINDOW IS PROCESS-WIDE. Between the mark and the restore, a spawn made
## by ANOTHER thread also loses every descriptor above 2 it did not ``dup2``
## into place (``dup2`` clears ``FD_CLOEXEC`` on its target, so stdio set up
## through spawn file actions is unaffected). Callers keep the window to the
## one spawn, and state why no other thread of theirs passes a descriptor
## above 2 to a child during it.
##
## THIS MODULE STARTS NOTHING, so the build engine -- whose imports
## ``t_every_launch_path_is_monitored`` audits for ways to spawn a child --
## can import it.

when defined(posix):
  import std/[os, strutils]
  from std/posix import fcntl, F_GETFD, F_SETFD, FD_CLOEXEC

  proc markInheritableDescriptorsCloseOnExec*(): seq[cint] =
    ## Every descriptor above 2 that THIS process holds without
    ## ``FD_CLOEXEC`` is given it, and the ones changed are returned so
    ## ``restoreInheritableDescriptors`` can put them back exactly as they
    ## were.
    ##
    ## The descriptor table is ENUMERATED (``/proc/self/fd`` on Linux,
    ## ``/dev/fd`` elsewhere) rather than scanned numerically, for the reason
    ## ``runquota_process.nim`` gives: a loop bounded by ``RLIMIT_NOFILE`` is
    ## a million ``fcntl`` calls on hosts that raise it. A descriptor that
    ## vanishes between the listing and the ``fcntl`` (the listing's own
    ## directory handle, for one) fails the ``F_GETFD`` and is skipped.
    let listing = when defined(linux): "/proc/self/fd" else: "/dev/fd"
    var candidates: seq[cint] = @[]
    try:
      for kind, path in walkDir(listing, relative = true):
        try:
          let fd = parseInt(path)
          if fd > 2:
            candidates.add(cint(fd))
        except ValueError:
          discard
    except OSError:
      return
    for fd in candidates:
      let flags = fcntl(fd, F_GETFD)
      if flags < 0 or (flags and FD_CLOEXEC) != 0:
        continue
      if fcntl(fd, F_SETFD, flags or FD_CLOEXEC) == 0:
        result.add(fd)

  proc restoreInheritableDescriptors*(changed: openArray[cint]) =
    ## Undoes ``markInheritableDescriptorsCloseOnExec``: clears
    ## ``FD_CLOEXEC`` on exactly the descriptors it changed. A descriptor
    ## closed in between fails the ``F_GETFD`` and is left alone.
    for fd in changed:
      let flags = fcntl(fd, F_GETFD)
      if flags >= 0:
        discard fcntl(fd, F_SETFD, flags and not FD_CLOEXEC)

  proc setCloseOnExec*(fd: cint): bool {.discardable.} =
    ## Marks one descriptor close-on-exec for good -- for a descriptor this
    ## process created and no child of it should ever hold, such as its own
    ## end of a pipe to a child. ``false`` when the descriptor is not open.
    let flags = fcntl(fd, F_GETFD)
    if flags < 0:
      return false
    if (flags and FD_CLOEXEC) != 0:
      return true
    fcntl(fd, F_SETFD, flags or FD_CLOEXEC) == 0
