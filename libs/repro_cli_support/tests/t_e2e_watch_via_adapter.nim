## t_e2e_watch_via_adapter — Incremental-Test-Runner verification:
## ``repro watch --ct-incremental`` decides skip/re-run THROUGH the engine-free
## ``reprobuild-ct-test-runner`` adapter, which reaches codetracer's CANONICAL
## engine by EXECUTING the ``ct`` binary (``ct test --incremental
## --watch-decide`` / ``--watch-record``) — reprobuild's former vendored engine
## copy (``libs/repro_ct_incremental``) is DELETED and reprobuild no longer
## compiles codetracer's engine at all.
##
## What this test exercises (the cutover call path)
## ------------------------------------------------
## ``repro_cli_support``'s ``repro watch --ct-incremental`` loop calls
## ``watchTestEdgeDecision(testId, traceDir, sourceRoot, cachePath)`` each cycle
## and acts on the returned ``WatchEdgeDecision`` (``weaSkip`` ⇒ "skipped
## (unchanged)"; otherwise re-run + ``recordWatchTestEdge``). This test imports
## the seam EXACTLY as ``repro_cli_support`` does (``import ct_incremental_adapter``)
## — so it goes through reprobuild's OWN ``config.nims`` wiring — and verifies
## the seam in two complementary layers:
##
##   1. ALWAYS (standalone, no codetracer): drive the seam against a FAKE ``ct``
##      (a tiny script via ``$CT_BIN``) emitting each engine outcome, asserting
##      the adapter execs ct, parses its JSON, and maps it to the
##      ``WatchEdgeDecision`` contract — including the fail-safe that any ct
##      failure is a re-run, NEVER a silent skip. This is reprobuild's own
##      responsibility (the seam wiring); the decision logic itself is owned and
##      tested by codetracer.
##   2. WHEN ``$CT_BIN`` points at a REAL ``ct`` (CI builds it in the codetracer
##      sibling): a genuine end-to-end over codetracer's committed
##      ``m0_three_funcs`` fixture — ``recordWatchTestEdge`` builds the cache via
##      ``ct --watch-record``, then ``watchTestEdgeDecision`` decides via
##      ``ct --watch-decide`` — asserting an unchanged source skips, editing an
##      executed function re-runs naming it, and editing a non-executed function
##      skips. This proves the real engine decides through the subprocess seam.

import std/[unittest, os, strutils, times]

# Imported EXACTLY as ``repro_cli_support`` imports it. The adapter exposes
# ``watchTestEdgeDecision`` / ``recordWatchTestEdge`` / ``defaultCachePath`` +
# the ``WatchEdgeDecision`` / ``weaSkip`` / ``weaRun`` value contract, and
# compiles against std only (no codetracer engine source).
import ct_incremental_adapter

# ---------------------------------------------------------------------------
# Layer 1 — fake ct: scripts each engine outcome so the adapter's exec+parse+map
# is asserted standalone (no codetracer, no real engine).
# ---------------------------------------------------------------------------

let fakeCt = getTempDir() / "repro_watch_fake_ct.sh"

proc installFakeCt() =
  writeFile(fakeCt,
    "#!/bin/sh\nprintf '%s\\n' \"$CT_FAKE_OUT\"\nexit ${CT_FAKE_CODE:-0}\n")
  inclFilePermissions(fakeCt, {fpUserExec, fpGroupExec, fpOthersExec})
  putEnv("CT_BIN", fakeCt)

proc fakeDecide(output: string; code = 0): WatchEdgeDecision =
  putEnv("CT_FAKE_OUT", output); putEnv("CT_FAKE_CODE", $code)
  watchTestEdgeDecision("t::id", "/trace", "/root", "/cache.json")

suite "repro watch seam — adapter exec/parse/map (fake ct)":

  setup:
    installFakeCt()
  teardown:
    delEnv("CT_BIN"); delEnv("CT_FAKE_OUT"); delEnv("CT_FAKE_CODE")

  test "unchanged_source_skips":
    let d = fakeDecide("""{"status":"skip","reason":"unchanged","changedFuncs":[]}""")
    check d.action == weaSkip
    check d.reason == "unchanged"
    check d.testId == "t::id"

  test "changed_executed_function_reruns_naming_it":
    let d = fakeDecide(
      """{"status":"run","reason":"changed: used_a","changedFuncs":["used_a"]}""")
    check d.action == weaRun
    check "used_a" in d.changedFuncs
    check d.reason.startsWith("changed:")

  test "no_cache_entry_runs_fresh":
    let d = fakeDecide("""{"status":"run","reason":"fresh","changedFuncs":[]}""")
    check d.action == weaRun
    check d.reason == "fresh"

  test "ct_failure_is_failsafe_run (never a silent skip)":
    let d = fakeDecide("""{"status":"skip"}""", code = 1)
    check d.action == weaRun
    check d.reason.startsWith("error:")

  test "recordWatchTestEdge maps ok and error":
    putEnv("CT_FAKE_OUT", """{"ok":true,"error":""}"""); putEnv("CT_FAKE_CODE", "0")
    check recordWatchTestEdge("t::id", "/trace", "/root", "/cache.json").ok
    putEnv("CT_FAKE_OUT", """{"ok":false,"error":"trace missing"}""")
    let r = recordWatchTestEdge("t::id", "/trace", "/root", "/cache.json")
    check not r.ok
    check r.error == "trace missing"

suite "no reprobuild engine copy remains":

  test "vendored repro_ct_incremental library is deleted":
    # The former vendored engine copy must be GONE — the watch decision now
    # flows through the adapter -> codetracer's `ct` binary.
    let reproRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    check not dirExists(reproRoot / "libs" / "repro_ct_incremental")

  test "adapter compiles without codetracer's engine in reprobuild's build":
    # Reaching this line proves reprobuild built `import ct_incremental_adapter`
    # with NO engine source/trace-format-nim/results/zstd on the path — the whole
    # point of the subprocess cutover. defaultCachePath is the pure helper.
    check defaultCachePath("/proj") == "/proj" / ".ct-incremental" / "cache.json"

# ---------------------------------------------------------------------------
# Layer 2 — real ct end-to-end over codetracer's m0_three_funcs fixture, gated
# on a built `ct` ($CT_BIN). Resolution mirrors reprobuild's config.nims:
# CODETRACER_CT_TEST_SRC env, else the codetracer sibling next to the repo.
# ---------------------------------------------------------------------------

proc realCt(): string =
  let b = getEnv("CT_BIN")
  if b.len > 0 and fileExists(b): b else: ""

proc ctTestSrcDir(): string =
  let env = getEnv("CODETRACER_CT_TEST_SRC")
  if env.len > 0: return env
  let reproRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  reproRoot.parentDir / "codetracer" / "src" / "ct_test"

let
  threeFuncsFixture = ctTestSrcDir() / "incremental" / "fixtures" / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"
  realTestId = "fixture::three_funcs"

var counter = 0
proc makeSourceRoot(): string =
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("repro_watch_realct_" & $stamp & "_" & $counter)
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

suite "repro watch seam — real ct end-to-end (gated on $CT_BIN)":

  test "unchanged skips / changed-executed re-runs / changed-unexecuted skips":
    if realCt().len == 0:
      # No built ct on this host: the genuine end-to-end can't run. The fake-ct
      # suite above already asserts the seam's exec/parse/map + fail-safe; CI sets
      # CT_BIN to the ct built in the codetracer sibling, where this runs for real.
      skip()
    elif not dirExists(threeFuncsTrace):
      checkpoint("CT_BIN set but m0_three_funcs fixture missing at " & threeFuncsTrace)
      fail()
    else:
      let root = makeSourceRoot()
      let cachePath = defaultCachePath(root)
      # cycle 1: record the baseline via `ct --watch-record`.
      check recordWatchTestEdge(realTestId, threeFuncsTrace, root, cachePath).ok
      # unchanged ⇒ skip
      let d0 = watchTestEdgeDecision(realTestId, threeFuncsTrace, root, cachePath)
      check d0.action == weaSkip
      check d0.reason == "unchanged"
      # edit an EXECUTED function ⇒ re-run naming it
      editFunctionBody(root, "used_a", "42 + 99")
      let d1 = watchTestEdgeDecision(realTestId, threeFuncsTrace, root, cachePath)
      check d1.action == weaRun
      check "used_a" in d1.changedFuncs
      # a fresh root with a NON-executed function edited ⇒ skip
      let root2 = makeSourceRoot()
      let cache2 = defaultCachePath(root2)
      check recordWatchTestEdge(realTestId, threeFuncsTrace, root2, cache2).ok
      editFunctionBody(root2, "unused_c", "777 + 777")
      let d2 = watchTestEdgeDecision(realTestId, threeFuncsTrace, root2, cache2)
      check d2.action == weaSkip
