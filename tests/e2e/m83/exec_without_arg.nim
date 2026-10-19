## A pass-through program that runs a configured executable with every
## argument it was given EXCEPT the configured arguments, which it drops.
##
## Used by `t_e2e_profile_compile_clang_first_run_published.nim` as the C
## compiler of its positive control: a "clang" that is handed
## `-fno-temp-file` by the profile compile, answers the compile's probe like
## the real clang (the probe passes the flag too, and it is dropped there as
## well, so the probe still succeeds), and yet never lets the real clang see
## the flag. The compile is otherwise the real clang on the real sources.
##
## WHY A COMPILED PROGRAM AND NOT A SHELL SCRIPT. For the same reason as
## `nim_spy.nim`: on macOS `/bin/sh` is a SIP platform binary whose loader
## strips `DYLD_*`, so a clang `exec`'d from a script would run without the
## monitor shim and the control would prove nothing there. A native
## executable keeps the shim on the whole chain, so the control runs on Linux
## and macOS alike.
##
## CONFIGURATION. `exec-without-arg.conf` next to the executable: line 1 the
## real executable (an absolute path), lines 2 onward the arguments to drop. Nothing
## is read from the environment, so the program adds nothing an action key
## could depend on beyond its own image and that file.
##
## FORWARDING. On POSIX it `execv`s the real executable, so the process tree
## the monitor sees has the real compiler where the wrapper was. Windows has
## no `exec`; there it starts the executable as its child with the parent's
## standard handles and exits with the child's exit code.

import std/[os, strutils]
when not defined(windows):
  import std/posix
else:
  import std/osproc

const ExecWithoutArgConfName* = "exec-without-arg.conf"

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("exec-without-arg: " & msg)
  quit(127)

proc main() =
  let confPath = getAppFilename().parentDir / ExecWithoutArgConfName
  if not fileExists(confPath):
    fail("missing " & confPath)
  let lines = readFile(confPath).splitLines()
  if lines.len < 2 or lines[0].len == 0 or lines[1].len == 0:
    fail(confPath & " must name the real executable (line 1) and the " &
      "argument to drop (line 2)")
  let realExe = lines[0]
  var dropped: seq[string]
  for line in lines[1..^1]:
    if line.len > 0:
      dropped.add line
  var args: seq[string]
  for arg in commandLineParams():
    if arg notin dropped:
      args.add arg

  when defined(windows):
    let p = startProcess(realExe, args = args, options = {poParentStreams})
    let code = p.waitForExit()
    p.close()
    quit(code)
  else:
    var argv = allocCStringArray(@[realExe] & args)
    discard execv(realExe.cstring, argv)
    deallocCStringArray(argv)
    fail("cannot exec " & realExe & ": " & $strerror(errno))

when isMainModule:
  main()
