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

import std/[osproc, streams, strtabs]
import ./process_close

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
  var p = startProcess(command, options = options + {poEvalCommand},
    workingDir = workingDir, env = env)
  try:
    var outp = outputStream(p)
    if input.len > 0:
      inputStream(p).write(input)
    close inputStream(p)
    result = ("", -1)
    var line = newStringOfCap(120)
    while true:
      if outp.readLine(line):
        result[0].add(line)
        result[0].add("\n")
      else:
        result[1] = peekExitCode(p)
        if result[1] != -1: break
  finally:
    closeProcessOnce(p)
