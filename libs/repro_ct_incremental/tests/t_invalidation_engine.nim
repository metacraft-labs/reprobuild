## M1 tests for the deep-hash invalidation engine.
##
## These are the six automated tests specified for M1 in
## `docs/Trace-Based-Incremental-Testing.milestones.org`. They genuinely
## manipulate source and cache state: each test copies the m0 fixture source
## into a fresh temp dir, `record()`s against it, then edits the temp source
## and `decide()`s — exercising the real extraction + hashing + decision path,
## never asserting constants.
##
## The trace used for `record()` is the committed m0 fixture trace (main/used_a
## /used_b executed; unused_c not). The source the engine hashes against is the
## per-test temp copy, so edits to the temp source drive the decisions.

import std/[unittest, os, strutils, times]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  # The trace records the source path as
  # `/fixtures/m0_three_funcs/src/three_funcs.rb`; the engine strips the
  # leading slash and resolves it under `sourceRoot`, so the temp source must
  # live at `<sourceRoot>/fixtures/m0_three_funcs/src/three_funcs.rb`.
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"

var tempCounter = 0

proc makeSourceRoot(): string =
  ## Create a fresh temp dir and copy the fixture source into it at the path the
  ## trace expects. Returns the sourceRoot. The suffix combines a process-time
  ## stamp with a monotonic counter so repeated calls within the same suite get
  ## distinct roots.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_ct_m1_" & $stamp & "_" & $tempCounter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc sourceFileOf(root: string): string =
  root / relSourcePath

proc editFunctionBody(root, funcName, newBody: string) =
  ## Replace the single-line body of `funcName` in the temp source. The fixture
  ## functions are `def <name>\n  <body>\nend`, so we replace the body line that
  ## follows the matching `def`.
  let path = sourceFileOf(root)
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

proc deleteFunction(root, funcName: string) =
  ## Remove the `def <name> ... end` block (three lines for the fixture's
  ## single-statement functions) from the temp source entirely.
  let path = sourceFileOf(root)
  var lines = readFile(path).split('\n')
  var outLines: seq[string]
  var i = 0
  while i < lines.len:
    if lines[i].strip() == "def " & funcName:
      # Skip until and including the matching `end` at the def's indentation.
      i += 1
      while i < lines.len and lines[i].strip() != "end":
        i += 1
      if i < lines.len: i += 1  # skip the `end`
      continue
    outLines.add lines[i]
    i += 1
  writeFile(path, outLines.join("\n"))

const testId = "fixture::three_funcs"

suite "M1: deep-hash invalidation engine":

  test "unchanged_source_skips":
    ## record() then decide() with identical source ⇒ idSkipUnchanged.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk
    let d = decide(testId, threeFuncsTrace, root, cache)
    check d.kind == idSkipUnchanged

  test "changing_an_executed_function_reruns":
    ## After record(), edit used_a's body ⇒ idRerunChanged listing used_a.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk
    editFunctionBody(root, "used_a", "42 + 99")
    let d = decide(testId, threeFuncsTrace, root, cache)
    check d.kind == idRerunChanged
    check "used_a" in d.changedFuncs
    # Function-level precision: only used_a changed, not the siblings.
    check d.changedFuncs == @["used_a"]

  test "changing_an_unexecuted_function_skips":
    ## After record(), edit unused_c (never executed) ⇒ idSkipUnchanged.
    ## Proves function-level (not file-level) precision: the edit is in the same
    ## file as the executed functions but to a function the test never ran.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk
    editFunctionBody(root, "unused_c", "777 + 777")
    let d = decide(testId, threeFuncsTrace, root, cache)
    check d.kind == idSkipUnchanged

  test "new_test_without_cache_runs_fresh":
    ## decide() for a test absent from the cache ⇒ idRunFresh.
    let root = makeSourceRoot()
    let cache = initCache(root / "cache.json")
    let d = decide("never::recorded", threeFuncsTrace, root, cache)
    check d.kind == idRunFresh

  test "deep_hash_is_order_independent_and_stable":
    ## deepHash is identical regardless of dep input order and stable across
    ## calls; a different set of shallow hashes yields a different deep hash.
    let a = @[("alpha", "1111"), ("beta", "2222"), ("gamma", "3333")]
    let b = @[("gamma", "3333"), ("alpha", "1111"), ("beta", "2222")]
    check deepHash(a) == deepHash(b)         # order-independent
    check deepHash(a) == deepHash(a)         # stable across calls
    # Sensitivity: changing one shallow hash changes the deep hash.
    let c = @[("alpha", "1111"), ("beta", "9999"), ("gamma", "3333")]
    check deepHash(a) != deepHash(c)

  test "removed_executed_function_reruns":
    ## If a dep function is deleted from source after record(), decide() ⇒
    ## idRerunChanged (missing-dep treated as changed, never silently skipped).
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk
    deleteFunction(root, "used_b")
    let d = decide(testId, threeFuncsTrace, root, cache)
    check d.kind == idRerunChanged
    check "used_b" in d.changedFuncs

  test "cache_roundtrips_through_json":
    ## save/load preserves the cache so decisions survive a process restart.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk
    check saveCache(cache).isOk
    let loaded = loadCache(root / "cache.json")
    check loaded.isOk
    let d = decide(testId, threeFuncsTrace, root, loaded.value)
    check d.kind == idSkipUnchanged
    # And an edit is still detected after a reload.
    editFunctionBody(root, "used_a", "0 + 0")
    let d2 = decide(testId, threeFuncsTrace, root, loaded.value)
    check d2.kind == idRerunChanged
    check "used_a" in d2.changedFuncs
