## t_runner_closes_merged_pipes_once — the test runner must release a
## ``poStdErrToStdOut`` child's pipes without closing any descriptor number a
## second time.
##
## The defect: ``osproc.close`` on POSIX closes the merged stdout/stderr
## descriptor twice (``errHandle == outHandle``, no guard). In the
## multi-threaded runner the second ``close`` hit whatever another worker had
## just been given that number — the pipe its supervisor handshake was about
## to read — and full suite runs ended ~1-2 random cases per run as harness
## errors: "supervisor did not become ready ... end of stream" (with the
## supervisor still running), ``errno: 21 'Is a directory'`` (the number had
## gone to ``opendir("/proc")``) and ``Bad file descriptor``.
##
## The race needs another thread to win a microsecond window, so these cases
## make it DETERMINISTIC instead: release the descriptor once, put a "victim"
## descriptor at the same number with ``dup2`` — exactly what the other
## worker's ``pipe()``/``open()`` did — and then observe whether the release
## path closes the victim. The first case proves the instrument discriminates
## (``osproc.close`` does kill the victim); the rest hold the runner's
## ``closeMergedProcess`` to never doing so.

import std/[osproc, streams, unittest]
import repro_test_support/reasoned_skip

when defined(posix):
  import std/posix
  import "../../tools/test-runner/merged_process"

  const Marker = "READY"

  proc spawnMerged(): Process =
    ## The runner's shape: a child whose stderr is merged into stdout.
    startProcess("/bin/sh", args = ["-c", "echo " & Marker],
                 options = {poStdErrToStdOut})

  proc isOpen(fd: cint): bool =
    fcntl(fd, F_GETFD) != -1

  proc placeVictimAt(fd: cint): cint =
    ## Occupy ``fd`` with a fresh, unrelated descriptor, as a sibling
    ## worker's ``pipe()`` or ``opendir()`` would after the first close.
    let source = posix.open("/dev/null", O_RDONLY)
    doAssert source >= 0
    doAssert dup2(source, fd) == fd
    discard posix.close(source)
    fd

  proc readMarkerAndReap(p: Process): bool =
    var line = ""
    result = p.outputStream.readLine(line) and line == Marker
    discard p.waitForExit()

suite "runner closes merged child pipes once":
  test "osproc.close closes the merged descriptor a second time":
    when defined(posix):
      # Pins the upstream defect and proves the victim instrument can see a
      # stale close at all; without this case the ones below could pass by
      # construction.
      let p = spawnMerged()
      check readMarkerAndReap(p)
      let merged = cint(p.outputHandle)
      p.outputStream.close()          # osproc.close's own first release
      let victim = placeVictimAt(merged)
      close(p)                        # ... then close(errHandle) on it again
      check not isOpen(victim)
    else:
      skip("not POSIX — the double close is in osproc's POSIX close(Process)")

  test "closeMergedProcess never closes a re-issued descriptor number":
    when defined(posix):
      let p = spawnMerged()
      check readMarkerAndReap(p)
      let merged = cint(p.outputHandle)
      let input = cint(p.inputHandle)
      p.outputStream.close()
      let victim = placeVictimAt(merged)
      closeMergedProcess(p)
      check isOpen(victim)
      check not isOpen(input)
      discard posix.close(victim)
    else:
      skip("not POSIX — the double close is in osproc's POSIX close(Process)")

  test "closeMergedProcess releases both pipes and is safe to repeat":
    when defined(posix):
      let p = spawnMerged()
      check readMarkerAndReap(p)
      let merged = cint(p.outputHandle)
      let input = cint(p.inputHandle)
      closeMergedProcess(p)
      check not isOpen(merged)
      check not isOpen(input)
      let victimOut = placeVictimAt(merged)
      let victimIn = placeVictimAt(input)
      closeMergedProcess(p)
      check isOpen(victimOut)
      check isOpen(victimIn)
      discard posix.close(victimOut)
      discard posix.close(victimIn)
    else:
      skip("not POSIX — the double close is in osproc's POSIX close(Process)")

  test "closeMergedProcess releases a child whose output was never read":
    when defined(posix):
      let p = spawnMerged()
      discard p.waitForExit()
      let merged = cint(p.outputHandle)
      let input = cint(p.inputHandle)
      closeMergedProcess(p)
      check not isOpen(merged)
      check not isOpen(input)
    else:
      skip("not POSIX — the double close is in osproc's POSIX close(Process)")
