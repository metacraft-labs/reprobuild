## M2 tests for the `repro watch --ct-incremental` decision seam.
##
## These exercise the pure `watchTestEdgeDecision` seam that the watch loop
## calls on every filesystem-change cycle — deterministically, with no live
## filesystem watcher and no `sleep`. Each test copies the m0 fixture source
## into a fresh temp dir, `record()`s a baseline (the watch loop's cycle-1
## behaviour), edits the temp source, and then drives the seam exactly as the
## ``cycle > 1`` watch hook does.
##
## Two of the four M2 tests live here (the skip/re-run pair) plus the seam's
## fail-safe behaviour; the flag-parsing pair lives in
## ``libs/repro_cli_support/tests/t_watch_ct_incremental_flags.nim`` where the
## real ``repro watch`` argument parser is reachable.

import std/[unittest, os, strutils, times]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"

var tempCounter = 0

proc makeSourceRoot(): string =
  ## Fresh temp dir with the fixture source copied to the path the trace's
  ## recorded source path resolves under.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_ct_m2_" & $stamp & "_" & $tempCounter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc sourceFileOf(root: string): string =
  root / relSourcePath

proc editFunctionBody(root, funcName, newBody: string) =
  ## Replace the single-line body of `funcName` in the temp source.
  let path = sourceFileOf(root)
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

const testId = "fixture::three_funcs"

proc recordBaseline(root: string): string =
  ## Mimic the watch loop's cycle-1 record(): build a cache on disk over the
  ## fixture trace + the temp source, persist it, and return the cache path the
  ## seam reads.
  let cachePath = root / "cache.json"
  var cache = initCache(cachePath)
  doAssert record(cache, testId, threeFuncsTrace, root).isOk
  doAssert saveCache(cache).isOk
  cachePath

suite "M2: watch decision seam":

  test "watch_skips_test_edge_when_executed_funcs_unchanged":
    ## record() a baseline, then change an UNexecuted function (unused_c).
    ## The seam must decide to SKIP — function-level precision through the
    ## watch hook, not just file-level.
    let root = makeSourceRoot()
    let cachePath = recordBaseline(root)
    editFunctionBody(root, "unused_c", "777 + 777")
    let decision = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check decision.action == weaSkip
    check decision.testId == testId
    check decision.reason == "unchanged"
    check decision.changedFuncs.len == 0

  test "watch_reruns_test_edge_when_executed_func_changed":
    ## record() a baseline, then change an EXECUTED function (used_a). The seam
    ## must decide to RE-RUN and name the changed function.
    let root = makeSourceRoot()
    let cachePath = recordBaseline(root)
    editFunctionBody(root, "used_a", "42 + 99")
    let decision = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check decision.action == weaRun
    check decision.testId == testId
    check "used_a" in decision.changedFuncs
    check decision.reason.startsWith("changed:")
    check "used_a" in decision.reason

  test "watch_reruns_when_no_cache_entry_yet":
    ## A test edge absent from the cache (first ever cycle, no baseline) ⇒ run
    ## fresh, never skip. (Defends the cycle>1-without-record corner.)
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"  # never written
    let decision = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check decision.action == weaRun
    check decision.reason == "fresh"

  test "watch_reruns_fail_safe_on_unreadable_cache":
    ## A malformed cache file must force a re-run (fail-safe), never a silent
    ## skip — losing the cache can't cause a test that should run to be skipped.
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"
    writeFile(cachePath, "{ this is not valid json")
    let decision = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check decision.action == weaRun
    check decision.reason.startsWith("error:")
