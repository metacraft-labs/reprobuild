## ``execCmdEx`` without ``osproc.close``'s double close.
##
## ``osproc.execCmdEx`` releases its child with ``osproc.close``, which on
## POSIX closes a ``poStdErrToStdOut`` child's merged stdout/stderr descriptor
## twice — and ``poStdErrToStdOut`` is ``execCmdEx``'s default. Where another
## thread of the process may be handed that number in between, the second
## close destroys that thread's descriptor. See ``repro_core/process_close``
## for the defect, the measurements and who must use this.
##
## A module of its own, apart from ``process_close``: this one STARTS a child
## (it is as ambient as ``execCmdEx``, and ``scripts/check_ambient_execution.sh``
## counts its callers), and the build engine must be able to import the
## release without importing a way to spawn.

import std/[oserrors, osproc, streams, strtabs]
from std/os import sleep
import ./process_close

when defined(posix):
  import std/posix

  proc fmemopen(buf: pointer; size: csize_t; mode: cstring): File {.
    importc, header: "<stdio.h>".}

  var FIONREAD {.importc, header: "<sys/ioctl.h>".}: cuint

  proc appendRead(fd: cint; sink: var string; limit: int): int {.
      raises: [OSError].} =
    ## One ``read`` of at most ``limit`` bytes from ``fd`` onto ``sink``.
    ## Returns the count, 0 at EOF.
    var buf {.noinit.}: array[16384, char]
    while true:
      let n = posix.read(fd, addr buf[0], min(limit, buf.len))
      if n < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      if n > 0:
        let previousLen = sink.len
        sink.setLen(previousLen + n)
        copyMem(addr sink[previousLen], addr buf[0], n)
      return n

  proc drainPipesUntilChildExits*(p: Process; fds: openArray[cint];
      sinks: var openArray[string]; maxFirstBytes = -1):
      tuple[exitCode: int; truncated: bool] {.raises: [OSError].} =
    ## Read every pipe in ``fds`` (``sinks[i]`` collects ``fds[i]``) until
    ## each is at EOF OR ``p`` itself has exited, whichever comes first, and
    ## return the child's exit code. The pipes are polled together, so a
    ## child that fills one while another is unread never blocks.
    ##
    ## EOF alone is not the end of the child. Every process that inherited
    ## a write end holds the pipe open. ``startProcess`` leaves the child
    ## a second copy of it under its original descriptor number besides
    ## stdout/stderr, so even a daemon that closes its standard streams
    ## keeps it, and git hands it to the automatic maintenance it detaches
    ## after a fetch or commit
    ## (``git maintenance run --auto --detach`` and the ``repack`` /
    ## ``pack-objects`` under it). Waiting for EOF then waits for a
    ## repack of the whole repository, long after git has answered and
    ## exited. Once the direct child is gone, everything it wrote is
    ## already in the pipes: take exactly the bytes queued there at that
    ## moment, without blocking, and stop. Bytes a grandchild writes
    ## later are not the child's output.
    ##
    ## ``maxFirstBytes`` >= 0 stops as soon as ``sinks[0]`` holds more than
    ## that many bytes: ``truncated`` is set and ``exitCode`` is -1, and the
    ## caller decides what to do with the still-running child (kill it).
    ##
    ## References: poll(2) https://man7.org/linux/man-pages/man2/poll.2.html,
    ## FIONREAD https://man7.org/linux/man-pages/man2/FIONREAD.2const.html.
    const PollIntervalMs = 50
    var pfds = newSeq[TPollfd](fds.len)
    var open = newSeq[bool](fds.len)
    for i in 0 ..< fds.len:
      open[i] = true
    result.exitCode = -1
    while true:
      var anyOpen = false
      for i in 0 ..< fds.len:
        # poll(2) ignores an entry whose descriptor is negative.
        pfds[i] = TPollfd(fd: (if open[i]: fds[i] else: -1), events: POLLIN)
        anyOpen = anyOpen or open[i]
      if not anyOpen:
        # EOF everywhere: every writer is gone; the child's status is all
        # that is left to collect. (Polled rather than ``waitForExit``,
        # whose signature carries a ``ValueError`` for its timeout.) A pipe
        # usually reports EOF a moment before the exited child can be
        # reaped, so the wait is short and polled finely: every git command
        # the caller runs pays it.
        while true:
          result.exitCode = peekExitCode(p)
          if result.exitCode != -1: return
          sleep(1)
      let ready = posix.poll(addr pfds[0], Tnfds(pfds.len), PollIntervalMs)
      if ready < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      if ready > 0:
        for i in 0 ..< fds.len:
          if open[i] and pfds[i].revents != 0:
            # POLLIN, POLLHUP or POLLERR: the read returns data, EOF or the
            # error without blocking.
            if appendRead(fds[i], sinks[i], high(int)) == 0:
              open[i] = false
      if maxFirstBytes >= 0 and sinks.len > 0 and
          sinks[0].len > maxFirstBytes:
        result.truncated = true
        result.exitCode = -1
        return
      # Asked after every read too, not only when the pipes are quiet: a
      # grandchild that keeps writing would otherwise keep this loop
      # reading for as long as it runs.
      let code = peekExitCode(p)
      if code != -1:
        for i in 0 ..< fds.len:
          if not open[i]: continue
          var queued: cint = 0
          if ioctl(fds[i], FIONREAD, addr queued) < 0:
            raiseOSError(osLastError())
          var remaining = int(queued)
          while remaining > 0:
            let n = appendRead(fds[i], sinks[i], remaining)
            if n == 0: break
            remaining -= n
        result.exitCode = code
        return

  proc drainUntilChildExits(p: Process; fd: cint): tuple[raw: string,
      exitCode: int] {.raises: [OSError].} =
    ## ``drainPipesUntilChildExits`` over one pipe.
    var sinks = [""]
    result.exitCode = drainPipesUntilChildExits(p, [fd], sinks).exitCode
    result.raw = move sinks[0]

proc execCmdExCloseOnce*(command: string;
                         options: set[ProcessOption] = {poStdErrToStdOut,
                                                        poUsePath};
                         env: StringTableRef = nil;
                         workingDir = ""; input = ""):
    tuple[output: string, exitCode: int] {.raises: [OSError, IOError].} =
  ## ``osproc.execCmdEx`` with the same signature, defaults and result, whose
  ## child is released by ``closeProcessOnce`` instead of ``osproc.close``.
  ## The body mirrors the stdlib's line for line (``poEvalCommand`` added,
  ## ``input`` written then stdin closed, lines read until EOF and the exit
  ## code is known); the only differences are the release, and that the
  ## release also runs when reading raises (the stdlib leaks the pipes then).
  ##
  ## On POSIX it also returns once the child has EXITED, without waiting for
  ## the output pipe to reach EOF: a grandchild the child left running in
  ## the background (git's detached automatic maintenance) inherits the pipe
  ## and would otherwise hold the caller until it finishes. Whatever the
  ## child wrote before exiting is still returned; what a grandchild writes
  ## afterwards is not.
  var p = startProcess(command, options = options + {poEvalCommand},
    workingDir = workingDir, env = env)
  try:
    if input.len > 0:
      inputStream(p).write(input)
    close inputStream(p)
    result = ("", -1)
    var line = newStringOfCap(120)
    when defined(posix):
      var drained = drainUntilChildExits(p, cint(outputHandle(p)))
      result[1] = drained.exitCode
      # Re-split the captured bytes with the ``File.readLine`` the stdlib
      # loop reads the pipe with (``outputStream`` is a ``FileStream``), over
      # an in-memory ``FILE``, so the output keeps ``execCmdEx``'s exact
      # shape: line terminators, a final line without one, embedded NULs.
      if drained.raw.len > 0:
        let mem = fmemopen(addr drained.raw[0], csize_t(drained.raw.len),
          "r")
        if mem == nil:
          raiseOSError(osLastError())
        try:
          while mem.readLine(line):
            result[0].add(line)
            result[0].add("\n")
        finally:
          close(mem)
    else:
      var outp = outputStream(p)
      while true:
        if outp.readLine(line):
          result[0].add(line)
          result[0].add("\n")
        else:
          result[1] = peekExitCode(p)
          if result[1] != -1: break
  finally:
    closeProcessOnce(p)
