## t_e2e_watch_via_adapter — Incremental-Test-Runner M0b-2/M0b-3 verification:
## ``repro watch --ct-incremental`` decides skip/re-run THROUGH the engine-free
## ``reprobuild-ct-test-runner`` adapter, with reprobuild's former vendored
## engine copy (``libs/repro_ct_incremental``) DELETED.
##
## What this test exercises (the cutover call path)
## ------------------------------------------------
## ``repro_cli_support``'s ``repro watch --ct-incremental`` loop calls the pure
## ``watchTestEdgeDecision(testId, traceDir, sourceRoot, cachePath)`` seam on each
## rebuild cycle and acts on the returned ``WatchEdgeDecision`` (``weaSkip`` ⇒
## report "skipped (unchanged)" and keep watching; otherwise re-run + ``record``).
## Before M0b-2 that seam came from reprobuild's vendored ``repro_ct_incremental``;
## after the cutover it comes from the ADAPTER (Nim module
## ``ct_incremental_adapter``), backed by codetracer's CANONICAL engine
## (``codetracer/src/ct_test/incremental``).
##
## This test imports the seam EXACTLY as ``repro_cli_support`` does (``import
## ct_incremental_adapter``) — so it goes through reprobuild's OWN ``config.nims``
## wiring (the adapter sibling path + ``wireCodetracerEngine``). It then drives
## the seam over codetracer's committed ``m0_three_funcs`` fixture, reproducing
## the watch hook's cycle-1 ``record`` + cycle>1 ``watchTestEdgeDecision`` flow:
##
##   * an UNCHANGED source ⇒ ``weaSkip`` (the watch loop skips the rebuild);
##   * editing an EXECUTED function (``used_a``) ⇒ ``weaRun`` naming it (re-run);
##   * editing a NON-executed function (``unused_c``) ⇒ ``weaSkip``;
##   * a malformed cache ⇒ ``weaRun`` fail-safe (``error:``), never a silent skip;
##   * the engine's own ``decide`` is cross-checked so the verdict is PROVEN to be
##     codetracer's engine deciding (not a constant), and ``record``/``saveCache``/
##     ``loadCache`` (re-exported through the adapter) round-trip the cache.
##
## This is the strongest level runnable here: it drives the full decision call
## path the watch loop uses, with the vendored lib gone, against a real recorded
## cache. The full LIVE ``repro watch`` loop (filesystem watcher + a live
## recorder re-tracing the edge each cycle) needs a host with a recorder and is
## gated the same way the campaign gates live recorder runs; this test asserts
## everything BELOW that live boundary — the decision, the cache round-trip, and
## that the adapter (not a vendored copy) is what reprobuild resolves.
##
## NOT FAKED: the decisions come from codetracer's engine over a real on-disk
## cache materialized by the engine's own ``record``. If the cutover wiring were
## wrong (adapter unresolved, engine unresolved, vendored copy still shadowing),
## this file would not compile.

import std/[unittest, os, strutils, times]

# Imported EXACTLY as ``repro_cli_support`` imports it after the M0b-2 cutover.
# The adapter exposes ``watchTestEdgeDecision`` + ``WatchEdgeDecision`` /
# ``weaSkip`` / ``weaRun`` and re-exports codetracer's canonical engine
# (``initCache`` / ``record`` / ``saveCache`` / ``loadCache`` / ``decide`` / the
# ``IncrementalDecision*`` kinds).
import ct_incremental_adapter

# ---------------------------------------------------------------------------
# Locate codetracer's committed m0_three_funcs fixture. Resolution mirrors
# reprobuild's config.nims: CODETRACER_CT_TEST_SRC env, else the sibling
# checkout next to the reprobuild repo root.
# ---------------------------------------------------------------------------
proc ctTestSrcDir(): string =
  let env = getEnv("CODETRACER_CT_TEST_SRC")
  if env.len > 0:
    return env
  # tests/<this file> -> repro_cli_support -> libs -> reprobuild root -> ws root
  let reproRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  reproRoot.parentDir / "codetracer" / "src" / "ct_test"

let
  fixturesDir = ctTestSrcDir() / "incremental" / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"
  testId = "fixture::three_funcs"

# Fail loudly (never skip) if the codetracer sibling/fixture is absent. The
# build would already have failed to import the engine, but this pinpoints a
# missing fixture distinctly.
doAssert dirExists(threeFuncsTrace),
  "codetracer m0_three_funcs trace fixture not found at " & threeFuncsTrace &
  " (set CODETRACER_CT_TEST_SRC or check out the codetracer sibling)"

var counter = 0

proc makeSourceRoot(): string =
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_watch_adapter_" & $stamp & "_" & $counter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc editFunctionBody(root, funcName, newBody: string) =
  let path = root / relSourcePath
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

proc recordBaseline(root: string): string =
  ## Mimic the watch loop's cycle-1 record(): build + persist a cache on disk
  ## over the fixture trace + temp source via the engine re-exported through the
  ## adapter, returning the cache path the seam reads on later cycles.
  let cachePath = root / "cache.json"
  var cache = initCache(cachePath)
  doAssert record(cache, testId, threeFuncsTrace, root).isOk
  doAssert saveCache(cache).isOk
  cachePath

suite "M0b — repro watch --ct-incremental decides via the adapter (vendored lib deleted)":

  test "unchanged_source_skips (watch hook skips the rebuild)":
    let root = makeSourceRoot()
    let cachePath = recordBaseline(root)
    let d = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check d.action == weaSkip
    check d.reason == "unchanged"
    check d.testId == testId
    # Proven to be codetracer's engine deciding, not a constant.
    check decide(testId, threeFuncsTrace, root, loadCache(cachePath).value).kind ==
      idSkipUnchanged

  test "changed_executed_function_reruns_naming_it (watch hook re-runs)":
    let root = makeSourceRoot()
    let cachePath = recordBaseline(root)
    editFunctionBody(root, "used_a", "42 + 99")
    let d = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check d.action == weaRun
    check "used_a" in d.changedFuncs
    check d.reason.startsWith("changed:")
    check "used_a" in d.reason
    let ed = decide(testId, threeFuncsTrace, root, loadCache(cachePath).value)
    check ed.kind == idRerunChanged
    check d.changedFuncs == ed.changedFuncs

  test "changed_unexecuted_function_skips (function-level precision through the seam)":
    let root = makeSourceRoot()
    let cachePath = recordBaseline(root)
    editFunctionBody(root, "unused_c", "777 + 777")
    let d = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check d.action == weaSkip
    check d.reason == "unchanged"

  test "no_cache_entry_runs_fresh (never skip without a baseline)":
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"  # never written
    let d = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check d.action == weaRun
    check d.reason == "fresh"

  test "malformed_cache_is_failsafe_run (never a silent skip)":
    let root = makeSourceRoot()
    let cachePath = root / "cache.json"
    writeFile(cachePath, "{ this is not valid json")
    let d = watchTestEdgeDecision(testId, threeFuncsTrace, root, cachePath)
    check d.action == weaRun
    check d.reason.startsWith("error:")

suite "M0b-3 — no reprobuild engine copy remains":

  test "vendored repro_ct_incremental library is deleted":
    # Static check: the former vendored engine copy must be GONE. The watch
    # decision now flows through the adapter -> codetracer's canonical engine.
    let reproRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    let vendored = reproRoot / "libs" / "repro_ct_incremental"
    check not dirExists(vendored)

  test "the canonical engine is the one in scope (codetracer, via the adapter)":
    # ``initCache`` / ``record`` / ``decide`` are reachable ONLY because the
    # adapter re-exports codetracer's engine; a vendored-copy import is gone.
    # A round-trip through the on-disk cache exercises the real engine path.
    let root = makeSourceRoot()
    let cachePath = recordBaseline(root)
    let loaded = loadCache(cachePath)
    check loaded.isOk
    check decide(testId, threeFuncsTrace, root, loaded.value).kind ==
      idSkipUnchanged
