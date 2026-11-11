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
import ./process_close

when defined(posix):
  import std/posix

  proc fmemopen(buf: pointer; size: csize_t; mode: cstring): File {.
    importc, header: "<stdio.h>".}

  proc drainUntilChildExits(p: Process; fd: cint): tuple[raw: string,
      exitCode: int] {.raises: [OSError].} =
    ## Read ``fd`` until EOF OR until ``p`` itself has exited, whichever
    ## comes first, and return the bytes with the child's exit code.
    ##
    ## EOF alone is not the end of the child. Every process that inherited
    ## the write end holds the pipe open, and git hands it to the
    ## automatic maintenance it detaches after a fetch or commit
    ## (``git maintenance run --auto --detach`` and the ``repack`` /
    ## ``pack-objects`` under it). Waiting for EOF then waits for a
    ## repack of the whole repository, long after git has answered and
    ## exited. Once the direct child is gone, what it wrote is already
    ## in the pipe: drain that without blocking and stop.
    const PollIntervalMs = 50
    var buf {.noinit.}: array[16384, char]
    var pfd = TPollfd(fd: fd, events: POLLIN)
    var childExited = false
    while true:
      pfd.revents = 0
      let timeout = if childExited: 0 else: PollIntervalMs
      let ready = posix.poll(addr pfd, 1, timeout)
      if ready < 0:
        if errno == EINTR: continue
        raiseOSError(osLastError())
      if ready > 0:
        let n = posix.read(fd, addr buf[0], buf.len)
        if n < 0:
          if errno == EINTR or errno == EAGAIN: continue
          raiseOSError(osLastError())
        if n == 0:
          # EOF: every writer is gone; the child's status is all that is
          # left to collect.
          result.exitCode = waitForExit(p)
          return
        let previousLen = result.raw.len
        result.raw.setLen(previousLen + n)
        copyMem(addr result.raw[previousLen], addr buf[0], n)
        continue
      if childExited:
        # The child is gone and the pipe holds nothing more of its output.
        # Whoever still has the write end open is not this child.
        return
      result.exitCode = peekExitCode(p)
      childExited = result.exitCode != -1

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
