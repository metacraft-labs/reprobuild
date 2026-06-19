## M4 tests: larger program, transitive dependencies, multiple tests, pruning.
##
## These are the four automated tests specified for M4 in
## `docs/Trace-Based-Incremental-Testing.milestones.org`. They drive ALL THREE
## fixture tests (`test_a`, `test_b`, `test_c` of `m4_large_python`) through a
## single `IncrementalCache`, then edit the temp source or mutate the live test
## set and assert the per-test decision — exercising the real
## extraction + hashing + decision + pruning path, never asserting constants.
##
## The traces used for `record()` are the committed `m4_large_python` per-test
## fixture traces. The source the engine hashes against is a per-test temp copy
## of `src/library.py`, so edits to the temp source drive the decisions.

import std/[unittest, os, strutils, times, tables, algorithm]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  largeFixture = fixturesDir / "m4_large_python"
  # The trace records the source path as
  # `/fixtures/m4_large_python/src/library.py`; the engine strips the leading
  # slash and resolves it under `sourceRoot`, so the temp source must live at
  # `<sourceRoot>/fixtures/m4_large_python/src/library.py`.
  relSourcePath = "fixtures/m4_large_python/src/library.py"

# The three fixture tests and their trace directories. The cache keys are the
# test ids; the values are the committed per-test trace dirs.
const
  testIdA = "m4::test_a"
  testIdB = "m4::test_b"
  testIdC = "m4::test_c"

let
  traceA = largeFixture / "trace_a"
  traceB = largeFixture / "trace_b"
  traceC = largeFixture / "trace_c"

# testId -> trace dir, used by the "record all tests" helper.
let allTests = {testIdA: traceA, testIdB: traceB, testIdC: traceC}

var tempCounter = 0

proc makeSourceRoot(): string =
  ## Create a fresh temp dir and copy the fixture source into it at the path the
  ## traces expect. Returns the sourceRoot. A process-time stamp plus a
  ## monotonic counter give distinct roots across calls in the same suite.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_ct_m4_" & $stamp & "_" & $tempCounter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(largeFixture / "src" / "library.py", dst)
  root

proc sourceFileOf(root: string): string =
  root / relSourcePath

proc editFunctionBody(root, funcName, newBody: string) =
  ## Replace the single-line body of `funcName` in the temp source. Every
  ## fixture function is `def <name>(x):\n    <body>`, so we replace the body
  ## line that immediately follows the matching `def` (Python 4-space indent).
  let path = sourceFileOf(root)
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].startsWith("def " & funcName & "("):
      doAssert i + 1 < lines.len
      lines[i + 1] = "    " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

proc recordAll(cache: var IncrementalCache; root: string) =
  ## Record every fixture test into the shared cache against the current source
  ## under `root`. This is the small helper that drives >=3 tests through one
  ## cache (M4 deliverable 2).
  for (testId, traceDir) in allTests:
    let r = record(cache, testId, traceDir, root)
    doAssert r.isOk, "record failed for " & testId & ": " & r.error

proc executedNames(traceDir: string): seq[string] =
  ## The sorted executed-function names a trace encodes (independent re-read of
  ## the committed trace, used to assert the fixture's per-test sets are exactly
  ## what the README documents — guarding against a drifted/edited trace).
  let r = readExecutedFunctions(traceDir)
  doAssert r.isOk, "trace read failed: " & traceDir
  for fn in r.value: result.add fn.name
  result.sort()

suite "M4: larger program, transitive deps, multiple tests, pruning":

  test "fixture_executed_sets_match_readme":
    ## Guard: the committed traces encode exactly the documented per-test sets.
    ## (If a trace drifts, the precision assertions below would be meaningless.)
    check executedNames(traceA) ==
      @["helper_one", "leaf_a_only", "leaf_deep", "leaf_shared", "mid_a", "run_a"]
    check executedNames(traceB) ==
      @["helper_two", "leaf_b_only", "leaf_shared", "mid_b", "run_b"]
    check executedNames(traceC) ==
      @["compute", "helper_three", "mid_c", "run_c", "transform", "validate"]
    # Sanity: dead_code / unused_helper are in NO test's executed set.
    for tr in [traceA, traceB, traceC]:
      check "dead_code" notin executedNames(tr)
      check "unused_helper" notin executedNames(tr)

  test "all_tests_skip_when_source_unchanged":
    ## Baseline: record all three, then decide with identical source — every
    ## test skips. This is the "unchanged transitive dependency graph ⇒ skip"
    ## case across the whole multi-test fixture (no false re-runs).
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    recordAll(cache, root)
    check decide(testIdA, traceA, root, cache).kind == idSkipUnchanged
    check decide(testIdB, traceB, root, cache).kind == idSkipUnchanged
    check decide(testIdC, traceC, root, cache).kind == idSkipUnchanged

  test "editing_shared_leaf_reruns_only_dependent_tests":
    ## Edit `leaf_shared`, executed by test_a AND test_b but NOT test_c.
    ## ⇒ A and B re-run (idRerunChanged, listing leaf_shared); C skips.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    recordAll(cache, root)
    editFunctionBody(root, "leaf_shared", "return x + 1000")

    let dA = decide(testIdA, traceA, root, cache)
    let dB = decide(testIdB, traceB, root, cache)
    let dC = decide(testIdC, traceC, root, cache)
    check dA.kind == idRerunChanged
    check "leaf_shared" in dA.changedFuncs
    check dA.changedFuncs == @["leaf_shared"]  # precision: only the leaf
    check dB.kind == idRerunChanged
    check "leaf_shared" in dB.changedFuncs
    check dB.changedFuncs == @["leaf_shared"]
    check dC.kind == idSkipUnchanged           # C never executed leaf_shared

  test "editing_disjoint_function_skips_unrelated_tests":
    ## Edit `leaf_a_only`, executed by ONLY test_a. ⇒ A re-runs; B and C skip.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    recordAll(cache, root)
    editFunctionBody(root, "leaf_a_only", "return x * 5")

    let dA = decide(testIdA, traceA, root, cache)
    let dB = decide(testIdB, traceB, root, cache)
    let dC = decide(testIdC, traceC, root, cache)
    check dA.kind == idRerunChanged
    check dA.changedFuncs == @["leaf_a_only"]
    check dB.kind == idSkipUnchanged
    check dC.kind == idSkipUnchanged

  test "transitive_callee_change_reruns_caller_test":
    ## test_a executed `run_a -> mid_a -> helper_one -> leaf_deep` (depth 4).
    ## `leaf_deep` IS in test_a's recorded executed set (runtime deps are
    ## transitive by construction), so editing it re-runs test_a — and ONLY
    ## test_a, since no other test executed leaf_deep.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    recordAll(cache, root)

    # Confirm the precondition the test name claims: leaf_deep is in test_a's
    # dependency set (not inferred statically — it is in the recorded trace).
    check "leaf_deep" in executedNames(traceA)
    check "leaf_deep" notin executedNames(traceB)
    check "leaf_deep" notin executedNames(traceC)

    editFunctionBody(root, "leaf_deep", "return x * x * x")

    let dA = decide(testIdA, traceA, root, cache)
    check dA.kind == idRerunChanged
    check "leaf_deep" in dA.changedFuncs
    check dA.changedFuncs == @["leaf_deep"]
    check decide(testIdB, traceB, root, cache).kind == idSkipUnchanged
    check decide(testIdC, traceC, root, cache).kind == idSkipUnchanged

  test "editing_dead_code_reruns_nothing":
    ## Editing a function executed by NO test re-runs nothing — proves the
    ## defined-but-never-executed functions are absent from every dep set.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    recordAll(cache, root)
    editFunctionBody(root, "dead_code", "return x + 12345")
    check decide(testIdA, traceA, root, cache).kind == idSkipUnchanged
    check decide(testIdB, traceB, root, cache).kind == idSkipUnchanged
    check decide(testIdC, traceC, root, cache).kind == idSkipUnchanged

  test "removed_test_is_pruned_from_cache":
    ## Record all three tests, then prune with only A and B live. C's entry is
    ## removed from BOTH the in-memory and persisted cache, and a subsequent
    ## decide for C ⇒ idRunFresh (no entry ⇒ run-and-record). A and B survive.
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"
    var cache = initCache(cachePath)
    recordAll(cache, root)
    check saveCache(cache).isOk

    # Before pruning: all three present, and C would skip (unchanged source).
    check cache.entries.hasKey(testIdC)
    check decide(testIdC, traceC, root, cache).kind == idSkipUnchanged

    let removed = pruneCache(cache, [testIdA, testIdB])
    check removed == @[testIdC]                 # exactly C was pruned
    check not cache.entries.hasKey(testIdC)     # gone from memory
    check cache.entries.hasKey(testIdA)         # survivors untouched
    check cache.entries.hasKey(testIdB)

    # Gone from the PERSISTED cache too (pruneCache saved it).
    let reloaded = loadCache(cachePath)
    check reloaded.isOk
    check not reloaded.value.entries.hasKey(testIdC)
    check reloaded.value.entries.hasKey(testIdA)
    check reloaded.value.entries.hasKey(testIdB)

    # A subsequent decide for the pruned test runs fresh; survivors still skip.
    check decide(testIdC, traceC, root, cache).kind == idRunFresh
    check decide(testIdA, traceA, root, cache).kind == idSkipUnchanged
    check decide(testIdB, traceB, root, cache).kind == idSkipUnchanged

    # Pruning is idempotent: re-pruning with the same live set removes nothing.
    check pruneCache(cache, [testIdA, testIdB]) == newSeq[string]()
