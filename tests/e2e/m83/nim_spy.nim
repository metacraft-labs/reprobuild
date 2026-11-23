## The pass-through `nim` the profile-compile-edge gates put first on `PATH`
## (see `profile_compile_edge_harness.nim`, which compiles this file once per
## test process and copies the binary into each sandbox as `nim` / `nim.exe`).
##
## It appends one line, `nim <args joined by spaces>`, to a log and then runs
## the REAL compiler with the arguments unchanged. It decides nothing and
## rewrites nothing: the compile is still the real Nim on the real profile.
##
## WHY A COMPILED PROGRAM AND NOT A SHELL SCRIPT. The spy used to be a
## two-line `#!/bin/sh` script, which tied every gate behind it to POSIX
## hosts. On Windows there is no `/bin/sh` to run it, and a `nim` that is a
## script is not found by `PATH` lookup there at all. On macOS `/bin/sh` is a
## SIP platform binary: the loader strips `DYLD_*` from it, so the real `nim`
## it `exec`s would run without the monitor shim the edge relies on. A
## native executable has neither problem.
##
## CONFIGURATION. The log path and the real compiler are read from
## `nim-spy.conf` next to the executable (line 1: the log, line 2: the real
## `nim`), so one compiled binary serves every sandbox and the spy reads
## nothing from the environment that the edge's action key could depend on.
##
## FORWARDING. On POSIX the spy `execv`s the real compiler, so the process
## tree the monitor sees is the same as with the old `exec` script. Windows
## has no `exec`; the spy starts the compiler as its child with the parent's
## standard handles and exits with the child's exit code.

import std/[os, strutils]
when not defined(windows):
  import std/posix
else:
  import std/osproc

const SpyConfName* = "nim-spy.conf"

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("nim spy: " & msg)
  quit(127)

proc main() =
  let confPath = getAppFilename().parentDir / SpyConfName
  if not fileExists(confPath):
    fail("missing " & confPath)
  let lines = readFile(confPath).splitLines()
  if lines.len < 2 or lines[0].len == 0 or lines[1].len == 0:
    fail(confPath & " must name the log (line 1) and the real nim (line 2)")
  let logPath = lines[0]
  let realNim = lines[1]
  let args = commandLineParams()

  var log: File
  if not open(log, logPath, fmAppend):
    fail("cannot append to " & logPath)
  log.writeLine("nim " & args.join(" "))
  log.close()

  when defined(windows):
    let p = startProcess(realNim, args = args, options = {poParentStreams})
    let code = p.waitForExit()
    p.close()
    quit(code)
  else:
    var argv = allocCStringArray(@[realNim] & args)
    discard execv(realNim.cstring, argv)
    deallocCStringArray(argv)
    fail("cannot exec " & realNim & ": " & $strerror(errno))

when isMainModule:
  main()
