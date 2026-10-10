## t_process_close_once — ``repro_core/process_close``: releasing an
## ``osproc.Process`` closes every descriptor exactly once, for EVERY option
## set; and ``repro_core/process_exec``'s ``execCmdExCloseOnce`` is
## ``execCmdEx`` in everything but that.
##
## ``osproc.close`` on POSIX closes a ``poStdErrToStdOut`` child's merged
## descriptor twice; in a multi-threaded process the second close lands on a
## descriptor another thread has just been handed. The merged case, with a
## control proving the victim instrument sees ``osproc.close``'s stale close,
## is ``tests/unit/t_runner_closes_merged_pipes_once.nim`` (the runner's
## regression test, which drives this same helper). This file pins what the
## shared helper adds for the engine's call sites: separate-stderr children
## (all three pipes released, and released once), ``poParentStreams`` (nothing
## of the parent's is closed), and ``execCmdExCloseOnce``'s parity with the
## stdlib call it replaces.
##
## The victim technique: after the helper has released a number, ``dup2`` an
## unrelated descriptor onto it — what another thread's ``pipe()``/``open()``
## does — and check that releasing again leaves it open.

import std/[os, osproc, streams, strtabs, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_core/process_close
import repro_core/process_exec

when defined(posix):
  import std/posix

  proc isOpen(fd: cint): bool =
    fcntl(fd, F_GETFD) != -1

  proc placeVictimAt(fd: cint): cint =
    let source = posix.open("/dev/null", O_RDONLY)
    doAssert source >= 0
    doAssert dup2(source, fd) == fd
    discard posix.close(source)
    fd

  proc lowestFreeDescriptor(): cint =
    ## The number the next ``open`` gets. Equal before and after an
    ## operation means it neither leaked a descriptor nor closed one it did
    ## not open (below the old lowest-free mark, which is what a stale close
    ## of a just-reused number would do).
    result = posix.open("/dev/null", O_RDONLY)
    doAssert result >= 0
    discard posix.close(result)

suite "closeProcessOnce and execCmdExCloseOnce release each descriptor once":
  test "a separate-stderr child: all three pipes released, and only once":
    when defined(posix):
      let p = startProcess("/bin/sh", args = ["-c", "echo out; echo err >&2"],
                           options = {})
      check p.outputStream.readAll() == "out\n"
      check p.errorStream.readAll() == "err\n"
      discard p.waitForExit()
      let fds = [cint(p.inputHandle), cint(p.outputHandle),
                 cint(p.errorHandle)]
      check fds[1] != fds[2]
      closeProcessOnce(p)
      for fd in fds:
        check not isOpen(fd)
      var victims: seq[cint] = @[]
      for fd in fds:
        victims.add placeVictimAt(fd)
      closeProcessOnce(p)
      for fd in victims:
        check isOpen(fd)
        discard posix.close(fd)
    else:
      skip("not POSIX — osproc's Windows close(Process) is correct")

  test "a merged child whose streams were never created is released once":
    when defined(posix):
      let p = startProcess("/bin/sh", args = ["-c", "echo hi >&2"],
                           options = {poStdErrToStdOut})
      discard p.waitForExit()
      let merged = cint(p.outputHandle)
      let input = cint(p.inputHandle)
      check cint(p.errorHandle) == merged
      closeProcessOnce(p)
      check not isOpen(merged)
      check not isOpen(input)
      let victim = placeVictimAt(merged)
      closeProcessOnce(p)
      check isOpen(victim)
      discard posix.close(victim)
    else:
      skip("not POSIX — osproc's Windows close(Process) is correct")

  test "poParentStreams: the parent's own stdio is left alone":
    when defined(posix):
      let p = startProcess("true", options = {poParentStreams, poUsePath})
      discard p.waitForExit()
      closeProcessOnce(p)
      check isOpen(0)
      check isOpen(1)
      check isOpen(2)
    else:
      skip("not POSIX — osproc's Windows close(Process) is correct")

  test "execCmdExCloseOnce matches execCmdEx and leaks nothing":
    when defined(posix):
      const script = "echo out; echo err >&2; printf 'no-newline'; exit 3"
      let before = lowestFreeDescriptor()
      let ours = execCmdExCloseOnce(script)
      check lowestFreeDescriptor() == before
      let theirs = execCmdEx(script)
      check ours == theirs
      check ours.exitCode == 3
      check "err" in ours.output

      let fed = execCmdExCloseOnce("cat", input = "line one\nline two\n")
      check fed == (output: "line one\nline two\n", exitCode: 0)

      let dir = getTempDir()
      let env = newStringTable({"PROCESS_CLOSE_PROBE": "seen"},
                               modeCaseSensitive)
      let located = execCmdExCloseOnce("pwd; echo $PROCESS_CLOSE_PROBE",
                                       env = env, workingDir = dir)
      check located == execCmdEx("pwd; echo $PROCESS_CLOSE_PROBE",
                                 env = env, workingDir = dir)
      check located.output.endsWith("seen\n")

      # Non-merged options are passed through exactly as execCmdEx would.
      let split = execCmdExCloseOnce("echo out; echo err >&2",
                                     options = {poUsePath})
      check split == (output: "out\n", exitCode: 0)
      check lowestFreeDescriptor() == before
    else:
      skip("not POSIX — osproc's Windows close(Process) is correct")
