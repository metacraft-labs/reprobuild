## M5 tests for the robustness / correctness guards of the Trace-Based-
## Incremental-Testing engine. The unifying invariant under test:
##
##   *Never skip a test that should run.*
##
## The only `IncrementalDecision` kind that skips is `idSkipUnchanged`. Every
## other condition — a fresh test, a changed executed function, a
## non-deterministic test, a missing/unreadable trace, an unreadable source
## file, an extraction/hashing error, or a stale/foreign cache schema — must
## resolve to a *re-run*. These tests drive each of those adverse conditions
## through the real engine and assert the decision is a re-run (and, where the
## milestone calls for it, that the fail-safe is distinguishable).
##
## Like the M1/M2 suites, each test copies the committed m0 fixture source into
## a fresh temp dir and `record()`s against the committed m0 trace, then
## perturbs source/trace/cache and `decide()`s — exercising the real extraction
## + hashing + decision + cache-versioning path, never asserting constants.
##
## ----------------------------------------------------------------------------
## Note on `full_suite_has_no_regressions` (M5 deliverable 5)
## ----------------------------------------------------------------------------
## The whole-project `repro.nim` / `.#test` build is BLOCKED by an unrelated,
## pre-existing compile error — `undeclared identifier: 'Executable'` in
## `repro_project_dsl/macros_b.nim`, introduced by commit `2dbd9111`. That is
## NOT a regression of this campaign and must NOT be "fixed" here. So this file
## scopes the no-regression guard to what the feature actually touches:
##   (a) `noflag_watch_decision_is_legacy_default` below asserts, in code, that
##       with the `--ct-incremental` flag ABSENT the parsed watch state is the
##       legacy default (the no-flag path is byte-for-byte the old behaviour);
##       the same assertion against the real `repro watch` argument parser lives
##       in `repro_cli_support/tests/t_watch_ct_incremental_flags.nim`.
##   (b) The campaign's full no-regression evidence is the GREEN run of ALL
##       M0–M4 lib tests + that cli-support flag test + the standalone
##       `nim check libs/repro_cli_support/src/repro_cli_support.nim` (exit 0),
##       which the implementation agent runs as part of M5 verification.

import std/[unittest, os, strutils, times, json, tables]
import repro_ct_incremental

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  # The trace records the source path as
  # `/fixtures/m0_three_funcs/src/three_funcs.rb`; the engine strips the leading
  # slash and resolves it under `sourceRoot`.
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"

var tempCounter = 0

proc makeTempRoot(tag: string): string =
  ## A fresh, empty temp dir (no fixture copied). Used for cache-only tests.
  inc tempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_ct_m5_" & tag & "_" & $stamp & "_" & $tempCounter)
  createDir(root)
  root

proc makeSourceRoot(): string =
  ## Fresh temp dir with the fixture source copied to the path the trace's
  ## recorded source path resolves under.
  let root = makeTempRoot("src")
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc sourceFileOf(root: string): string =
  root / relSourcePath

const testId = "fixture::three_funcs"

suite "M5: robustness and correctness guards":

  test "nondeterministic_test_always_reruns":
    ## A test marked non-deterministic must re-run even when its source is
    ## byte-identical to what was recorded (spec §16.7). We record a baseline,
    ## leave the source untouched (so a deterministic test would SKIP — proven by
    ## the control assertion), then mark it non-deterministic and confirm decide
    ## flips to a dedicated non-deterministic re-run.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk

    # Control: identical source ⇒ a *deterministic* test skips.
    let control = decide(testId, threeFuncsTrace, root, cache)
    check control.kind == idSkipUnchanged
    check (not control.isRerun)

    # Now mark it non-deterministic via the separate API and re-decide.
    check markNonDeterministic(cache, testId).isOk
    let d = decide(testId, threeFuncsTrace, root, cache)
    check d.kind == idRerunNonDeterministic
    check d.isRerun

    # And the marking is honoured straight from record() too (the other API).
    var cache2 = initCache(root / "cache2.json")
    check record(cache2, testId, threeFuncsTrace, root,
                 deterministic = false).isOk
    let d2 = decide(testId, threeFuncsTrace, root, cache2)
    check d2.kind == idRerunNonDeterministic
    check d2.isRerun

    # The marking survives a save/load round-trip (persisted in the cache JSON).
    check saveCache(cache2).isOk
    let reloaded = loadCache(root / "cache2.json")
    check reloaded.isOk
    let d3 = decide(testId, threeFuncsTrace, root, reloaded.value)
    check d3.kind == idRerunNonDeterministic

    # markNonDeterministic on an unknown test is an Err (cannot mark a test that
    # was never recorded) — never a silent no-op that could be mistaken for OK.
    check markNonDeterministic(cache, "never::recorded").isErr

  test "missing_trace_falls_back_to_rerun":
    ## decide against a cached test whose trace dir is missing/unreadable must
    ## fail safe to a re-run (a distinguishable `idRerunFailSafe`), never a skip
    ## and never a crash — even though the source is byte-identical.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk

    # A trace dir that does not exist at all. As of M8 backend detection runs
    # before the (now backend-specific) readability probe, so a missing dir is
    # caught by `detectBackend` ("trace dir not found"); the decision is still a
    # distinguishable fail-safe re-run, never a skip.
    let goneTrace = root / "no_such_trace_dir"
    check (not dirExists(goneTrace))
    let dMissingDir = decide(testId, goneTrace, root, cache)
    check dMissingDir.kind == idRerunFailSafe
    check dMissingDir.isRerun
    check "trace dir not found" in dMissingDir.reason

    # A trace dir that exists but carries no recognisable trace shape (here only
    # `trace_paths.json`, no `trace.json` and no native signal). As of M8 this is
    # caught by `detectBackend` ("unrecognised/empty trace shape") — still a
    # fail-safe re-run, never a skip. (When the dir DOES detect as a source trace
    # but a required file is unreadable, the source readability probe still
    # reports "missing trace file"; that branch is exercised by the native
    # counterpart in t_native_decision.nim's native_missing_calltrace_file_fails_safe.)
    let partialTrace = makeTempRoot("partialtrace")
    writeFile(partialTrace / TracePathsFile, "[]")
    # (no trace.json)
    let dMissingFile = decide(testId, partialTrace, root, cache)
    check dMissingFile.kind == idRerunFailSafe
    check dMissingFile.isRerun
    check "unrecognised/empty trace shape" in dMissingFile.reason

  test "unreadable_source_falls_back_to_rerun":
    ## A dependency whose source file is missing/unreadable must re-run. The
    ## engine maps the unreadable source to the reserved "missing" shallow hash,
    ## which differs from the recorded hash ⇒ `idRerunChanged` naming the dep.
    ## This proves an extraction/read error is itself a re-run, never a skip.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk

    # Delete the source file entirely (the trace's deps still reference it).
    removeFile(sourceFileOf(root))
    check (not fileExists(sourceFileOf(root)))
    let d = decide(testId, threeFuncsTrace, root, cache)
    check d.kind == idRerunChanged
    check d.isRerun
    # Every executed function (main/used_a/used_b) became "missing" ⇒ all listed.
    check "used_a" in d.changedFuncs
    check "used_b" in d.changedFuncs
    check "main" in d.changedFuncs

  test "stale_cache_schema_is_ignored_and_reruns":
    ## A cache file written by a different/older schema `version` must be IGNORED
    ## (treated as empty) so every test re-runs — never mis-parsed or partially
    ## trusted. We write a v1-shaped file with a real, well-formed entry for the
    ## test, then load it: the load must succeed with an EMPTY cache, and a
    ## subsequent decide ⇒ `idRunFresh` (re-run), not a skip.
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"

    # First, build a genuinely-valid current-schema cache so we know the entry
    # WOULD otherwise skip — this isolates the version check as the cause.
    block:
      var good = initCache(cachePath)
      check record(good, testId, threeFuncsTrace, root).isOk
      check saveCache(good).isOk
      let okLoad = loadCache(cachePath)
      check okLoad.isOk
      check decide(testId, threeFuncsTrace, root, okLoad.value).kind ==
        idSkipUnchanged  # control: a CURRENT-schema cache skips.

    # Now rewrite the same file with an OLD version number but otherwise the
    # exact same valid entry shape. loadCache must ignore it ⇒ empty cache.
    let staleRoot = parseJson(readFile(cachePath))
    staleRoot["version"] = newJInt(CacheVersion - 1)
    writeFile(cachePath, staleRoot.pretty())
    let staleLoad = loadCache(cachePath)
    check staleLoad.isOk                 # stale schema is Ok(empty), not Err.
    let staleCount = staleLoad.value.entries.len
    check staleCount == 0
    let d = decide(testId, threeFuncsTrace, root, staleLoad.value)
    check d.kind == idRunFresh           # everything re-runs.
    check d.isRerun

    # A FUTURE/newer version is likewise ignored (not partially trusted).
    let futureRoot = parseJson(readFile(cachePath))
    futureRoot["version"] = newJInt(CacheVersion + 100)
    writeFile(cachePath, futureRoot.pretty())
    let futureLoad = loadCache(cachePath)
    check futureLoad.isOk
    let futureCount = futureLoad.value.entries.len
    check futureCount == 0

    # A file missing the version key entirely is also ignored (defensive).
    let noVersion = parseJson(readFile(cachePath))
    noVersion.delete("version")
    writeFile(cachePath, noVersion.pretty())
    let noVersionLoad = loadCache(cachePath)
    check noVersionLoad.isOk
    let noVersionCount = noVersionLoad.value.entries.len
    check noVersionCount == 0

  test "independent_watched_edges_keep_separate_cache_entries":
    ## Two different test ids in the SAME cache file never collide: they key by
    ## test id, coexist, and are invalidated independently. This covers the M5
    ## "independent watched edges" deliverable.
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"
    var cache = initCache(cachePath)
    const edgeA = "edge::a"
    const edgeB = "edge::b"
    # Record both edges against the same trace/source into ONE cache file.
    check record(cache, edgeA, threeFuncsTrace, root).isOk
    check record(cache, edgeB, threeFuncsTrace, root).isOk
    check saveCache(cache).isOk

    # Both coexist and both skip when nothing changed.
    let loaded = loadCache(cachePath)
    check loaded.isOk
    let loadedCount = loaded.value.entries.len
    check loadedCount == 2
    check decide(edgeA, threeFuncsTrace, root, loaded.value).kind ==
      idSkipUnchanged
    check decide(edgeB, threeFuncsTrace, root, loaded.value).kind ==
      idSkipUnchanged

    # Mark ONLY edge A non-deterministic and persist — edge B must be unaffected.
    var cache2 = loaded.value
    check markNonDeterministic(cache2, edgeA).isOk
    check saveCache(cache2).isOk
    let loaded2 = loadCache(cachePath)
    check loaded2.isOk
    # A re-runs (non-deterministic); B still skips — independent invalidation.
    check decide(edgeA, threeFuncsTrace, root, loaded2.value).kind ==
      idRerunNonDeterministic
    check decide(edgeB, threeFuncsTrace, root, loaded2.value).kind ==
      idSkipUnchanged

  test "noflag_watch_decision_is_legacy_default":
    ## full_suite_has_no_regressions, part (a): with the `--ct-incremental` flag
    ## absent, the watch decision/path is the legacy one. We assert this in code
    ## here via the parser seam's default; the real `repro watch` argument loop's
    ## no-flag behaviour is asserted in
    ## `repro_cli_support/tests/t_watch_ct_incremental_flags.nim`, which is also
    ## run as part of M5 verification (see this file's header note about the
    ## unrelated pre-existing `Executable` error that blocks the whole-project
    ## `.#test`).
    ##
    ## The engine-level invariant of the no-flag path: the incremental decision
    ## machinery is NEVER consulted unless a flag enabled it. We model that here
    ## by confirming a default `WatchCtIncrementalGate` is disabled, and that a
    ## disabled gate yields the legacy "run" verdict regardless of cache state.
    var gate = WatchCtIncrementalGate()
    check (not gate.enabled)             # legacy default: feature OFF.
    # A disabled gate must never skip — it always defers to the legacy run path.
    let root = makeSourceRoot()
    var cache = initCache(root / "cache.json")
    check record(cache, testId, threeFuncsTrace, root).isOk
    check saveCache(cache).isOk
    # Even though a fresh, unchanged cache WOULD skip when enabled, a disabled
    # gate must return the legacy run verdict.
    let v = gatedWatchDecision(gate, testId, threeFuncsTrace, root,
                               root / "cache.json")
    check v.action == weaRun
    check v.reason == "ct-incremental-disabled"
