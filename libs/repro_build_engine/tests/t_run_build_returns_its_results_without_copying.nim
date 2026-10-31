## t_run_build_returns_its_results_without_copying — handing the finished
## ``BuildRunResult`` back to the caller must not copy it.
##
## The defect (reprobuild-pm
## ``issues/2026-10-18-full-suite-run-dies-at-the-build-action-payload-cache-policy-case.md``):
## the engine building ``.#test-builds`` kept growing after its builds were
## done. Once the report writer stopped building the whole report in memory,
## one step of the growth was left, and it was here. ``runBuild`` ended with
## ``result = runResult``, and ``runResult`` is captured by the closures
## ``runBuild`` defines, so the compiler cannot move out of it: the assignment
## deep-copied every ``ActionResult`` and every evidence path in it. Measured
## on a warm ``repro build --write-report .#test-builds``: the engine went
## from 5.9 GB to 10.3 GB in three seconds after the last action finished,
## before the report's first byte.
##
## What this test owns
## -------------------
## The peak RSS while ``runBuild`` runs stays near the size of what it
## returns, rather than reaching twice that. The results are made large with
## stdout (200 actions each print 1 MiB) because stdout lands in
## ``ActionResult`` unchanged, which makes its size known. Process RSS is
## measured rather than Nim's ``getMaxMem``, because the engine's worker
## threads allocate from heaps of their own.
##
## Fixtures, not fakes
## -------------------
## Real actions run through the real engine and a real shell. Nothing is
## mocked.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_test_support/reasoned_skip

proc procStatusKiB(field: string): int =
  ## A ``kB`` field of ``/proc/self/status`` (``VmRSS``, ``VmHWM``).
  for line in readFile("/proc/self/status").splitLines():
    if line.startsWith(field & ":"):
      return parseInt(line[field.len + 1 .. ^1].strip().split()[0])
  raise newException(ValueError, field & " not in /proc/self/status")

proc resetPeakRss(): bool =
  ## Reset ``VmHWM`` to the current RSS (``proc(5)``, ``clear_refs`` value
  ## 5), so the peak read afterwards belongs to the code under test.
  try:
    writeFile("/proc/self/clear_refs", "5")
    true
  except IOError:
    false

suite "runBuild hands back its results without copying them":
  test "peak RSS stays near the size of the results, not twice it":
    when not defined(linux):
      skip("peak RSS is read from /proc/self/status, which only Linux has")
    else:
      const actionCount = 200
      const stdoutBytes = 1024 * 1024
      let tempRoot = createTempDir("repro-run-build-no-copy-", "")
      defer: removeDir(tempRoot)
      var actions: seq[BuildAction]
      for i in 0 ..< actionCount:
        # ``head -c`` of a ``yes`` stream: a fixed number of bytes, from a
        # process whose output the engine captures like any other.
        actions.add(action("print-" & $i,
          @["sh", "-c", "yes " & $i & " | head -c " & $stdoutBytes],
          cwd = tempRoot,
          cacheable = false,
          governingLockIdentity = lockIdentityOutsideSolvedGraph()))
      var config = defaultBuildEngineConfig(tempRoot / "cache")
      config.bypassRunQuota = true
      config.maxParallelism = 4
      config.stdoutLimit = 2 * stdoutBytes
      let buildGraph = graph(actions)
      let exactPeak = resetPeakRss()
      let rssBefore = procStatusKiB("VmRSS")
      let peakBefore = procStatusKiB("VmHWM")
      let buildResult = runBuild(buildGraph, config)
      let peakAfter = procStatusKiB("VmHWM")
      var stdoutTotal = 0
      for item in buildResult.results:
        check item.status == asSucceeded
        check item.stdout.len == stdoutBytes
        stdoutTotal += item.stdout.len
      check buildResult.results.len == actionCount
      let resultsKiB = stdoutTotal div 1024
      let baseline = if exactPeak: rssBefore else: max(rssBefore, peakBefore)
      let growthKiB = max(0, peakAfter - baseline)
      checkpoint "results " & $resultsKiB & " KiB of stdout; RSS before " &
        $rssBefore & " KiB; peak " & $peakAfter & " KiB; growth " &
        $growthKiB & " KiB (exact peak reset: " & $exactPeak & ")"
      echo "results=", resultsKiB, "KiB growth=", growthKiB, "KiB"
      # Holding the results once, plus the engine's own transient buffers,
      # measured 1.4x ``resultsKiB`` (282-287 MiB for 200 MiB); with the copy
      # it measured 2.3x (458 MiB). The bound sits between the two, so load
      # on the host does not redden it and a whole second copy still does.
      check growthKiB < resultsKiB * 9 div 5
