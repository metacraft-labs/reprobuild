## t_just_test_hot_cache_is_no_op_build —
## Test-Edges-And-Parallel-Runner M1 verification.
##
## After a clean ``just test``, a second ``just test`` must do zero work —
## the action cache hits everywhere, for the ``nim c`` BUILD edges and for
## the test-run EXECUTE edges alike. Spec basis:
## Test-Edges-And-Parallel-Runner.milestones.org §Introduction, initiative
## goal (1) ("Make each reprobuild test program a first-class build edge in
## the DSL so it benefits from action-cache reuse, incremental
## invalidation, named selection, and watch") and
## Incremental-Invalidation.md §"Validation Criteria" ("a warm re-run of an
## unchanged graph still executes zero actions").
##
## MOCK POLICY — NO MOCKS. Both cases spawn the real graph-built
## ``build/bin/repro`` against this repository's real ``repro.nim``, with
## an isolated action-cache root so the cold pass is genuinely cold.
##
## WHY THERE ARE TWO CASES
## -----------------------
## Until 2026-08-23 this file held ONE case, gated on
## ``REPRO_M1_LONG_TEST=1``, which meant the invariant was unguarded in
## every run anybody actually did. It also only ever looked at the
## ``nim-c-*`` BUILD actions — so even when it did run, the EXECUTE edges
## were outside its window, and a defect that made every test-run edge a
## permanent cache miss (a zero-output edge could never be skipped; see
## ``libs/repro_build_engine/tests/t_zero_output_edge_is_cacheable.nim``)
## went unnoticed for months. Both holes are closed here:
##
## * ``single test target`` runs BY DEFAULT. It drives one edge pair — the
##   cheapest test in the repo, whose own body is a handful of ``check``s —
##   so the cost is the graph load plus one small ``nim c``, not a 1345-edge
##   suite compile. It asserts on the EXECUTE edge as well as the BUILD
##   edge. This is the guard.
## * ``full :test aggregate`` stays gated on ``REPRO_M1_LONG_TEST=1``. Its
##   cold pass compiles the entire suite (several minutes to hours); no
##   amount of care makes that a default-on test. It is a periodic sweep,
##   and it is not what protects the invariant.
##
## To run the long form manually::
##
##   REPRO_M1_LONG_TEST=1 ./build/test-bin/t_just_test_hot_cache_is_no_op_build

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

const RepoRootMarker = "repro.nim"
const LongTestEnv = "REPRO_M1_LONG_TEST"

## The cheapest declared test edge in the repository: ``ct_test_interface``
## is a handful of type declarations, so its ``nim c`` is seconds and its
## run is milliseconds. The selector names the EXECUTE edge explicitly
## (`ct_test_nim_unittest.run` registers no implicit name for it — the
## BUILD edge owns the basename), which pulls in its BUILD edge as a
## dependency. Both therefore appear in the report.
const CheapTestTarget =
  ".#reprobuild.test_execute.t_smoke_ct_test_interface"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc findReport(workRoot, repoRoot: string): string =
  for path in walkDirRec(workRoot):
    if path.endsWith("build-report.json"):
      return path
  let inRepo = repoRoot / ".repro" / "build"
  if dirExists(inRepo):
    for path in walkDirRec(inRepo):
      if path.endsWith("build-report.json"):
        return path
  ""

type ActionKind = enum
  akBuildEdge      ## ``nim c`` of a test binary
  akExecuteEdge    ## running that test binary — declares NO outputs

proc classify(id: string): Option[ActionKind] =
  ## Spec-Implementation M4 reshaped ``buildNimUnittest.build`` to record a
  ## ``PublicCliCall`` against the ``nim`` profile directly, so the BUILD
  ## edge's action id is ``nim-c-<hash>``. The EXECUTE edge's id is the
  ## explicit ``actionId`` ``repro.nim`` assigns
  ## (``reproTestExecuteId``/``pythonTestExecuteId``).
  if id.startsWith("nim-c-"):
    some(akBuildEdge)
  elif id.startsWith("reprobuild.test_execute.") or
      id.startsWith("reprobuild.python_test."):
    some(akExecuteEdge)
  else:
    none(ActionKind)

type HotCacheTally = object
  actions: array[ActionKind, int]
  launched: array[ActionKind, int]
  misses: array[ActionKind, int]
  offenders: seq[string]

proc tally(reportPath: string): HotCacheTally =
  let payload = parseJson(readFile(reportPath))
  let actions =
    if payload.hasKey("actions"): payload["actions"] else: newJArray()
  for entry in actions:
    let id = entry{"id"}.getStr("")
    let kind = classify(id)
    if kind.isNone:
      continue
    let k = kind.get()
    inc result.actions[k]
    let launched = entry{"launched"}.getBool(false) or
      entry{"wouldLaunch"}.getBool(false)
    let decision = entry{"cacheDecision"}.getStr("")
    let missed = decision == "cdMiss" or decision == "miss"
    if launched:
      inc result.launched[k]
    if missed:
      inc result.misses[k]
    if launched or missed:
      result.offenders.add(id & " launched=" & $launched &
        " decision=" & decision & " reason=" & entry{"reason"}.getStr(""))

proc runHotCacheCheck(target: string) =
  let repoRoot = findRepoRoot()
  let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  # A hard check, not a skip: this test's TestSpec carries
  # ``requiresReproBinary: true``, so the engine builds the CLI before the
  # execute edge runs. If it is absent, something upstream is wrong and
  # quietly passing would hide it.
  check fileExists(reproBin)
  if not fileExists(reproBin):
    return

  let tempRoot = createTempDir("repro-m1-hot-cache-", "")
  defer: removeDir(tempRoot)
  let workRoot = tempRoot / "work"
  # An isolated action-cache root is what makes the cold pass genuinely
  # cold. Inheriting the developer's ~/.cache/repro/action-cache would make
  # the "cold" pass a warm one and the whole assertion vacuous — and would
  # also write this test's records into a store it does not own.
  let actionCacheRoot = tempRoot / "action-cache"
  createDir(workRoot)

  proc runBuild(extraFlags: openArray[string]): tuple[output: string;
      exitCode: int] =
    var args = @[
      quoteShell(reproBin), "build", quoteShell(target),
      "--write-report",
      "--no-runquota",
      "--work-root=" & quoteShell(workRoot),
      "--action-cache-root=" & quoteShell(actionCacheRoot),
      "--progress=quiet",
      "--log=quiet",
    ]
    for f in extraFlags:
      args.add(f)
    execCmdEx(args.join(" "), workingDir = repoRoot)

  # Cold: actions execute and populate the action cache.
  let cold = runBuild([])
  checkpoint("cold build exit=" & $cold.exitCode)
  if cold.exitCode != 0:
    checkpoint(cold.output)
  check cold.exitCode == 0

  let coldReport = findReport(workRoot, repoRoot)
  check fileExists(coldReport)
  if not fileExists(coldReport):
    return
  let coldTally = tally(coldReport)
  checkpoint("cold: build edges=" & $coldTally.actions[akBuildEdge] &
    " execute edges=" & $coldTally.actions[akExecuteEdge])
  # Denominators. Without these the "zero misses" assertions below are
  # satisfiable by a report with no test actions in it at all.
  check coldTally.actions[akBuildEdge] > 0
  check coldTally.actions[akExecuteEdge] > 0
  # The cold pass must actually have run the tests; if it did not, the hot
  # pass proves nothing.
  check coldTally.launched[akExecuteEdge] == coldTally.actions[akExecuteEdge]

  # Hot: the same target, nothing touched. Every action — build AND
  # execute — must be reused.
  let hot = runBuild([])
  checkpoint("hot build exit=" & $hot.exitCode)
  if hot.exitCode != 0:
    checkpoint(hot.output)
  check hot.exitCode == 0

  let hotReport = findReport(workRoot, repoRoot)
  check fileExists(hotReport)
  if not fileExists(hotReport):
    return
  let hotTally = tally(hotReport)
  checkpoint("hot: build edges=" & $hotTally.actions[akBuildEdge] &
    " launched=" & $hotTally.launched[akBuildEdge] &
    " misses=" & $hotTally.misses[akBuildEdge])
  checkpoint("hot: execute edges=" & $hotTally.actions[akExecuteEdge] &
    " launched=" & $hotTally.launched[akExecuteEdge] &
    " misses=" & $hotTally.misses[akExecuteEdge])
  for offender in hotTally.offenders:
    checkpoint("  re-ran on hot pass: " & offender)

  check hotTally.actions[akBuildEdge] == coldTally.actions[akBuildEdge]
  check hotTally.actions[akExecuteEdge] == coldTally.actions[akExecuteEdge]
  check hotTally.launched[akBuildEdge] == 0
  check hotTally.misses[akBuildEdge] == 0
  # The property this file exists for, and the one that was unguarded: a
  # test edge whose inputs are unchanged must hit the action cache and not
  # re-run. A test run declares no outputs; that is not a reason to re-run
  # it.
  check hotTally.launched[akExecuteEdge] == 0
  check hotTally.misses[akExecuteEdge] == 0

suite "t_just_test_hot_cache_is_no_op_build":

  test "second build of a single test target re-runs nothing":
    runHotCacheCheck(CheapTestTarget)

  test "second build of the :test aggregate is fully cache-hit (gated by REPRO_M1_LONG_TEST)":
    if getEnv(LongTestEnv) != "1":
      checkpoint("skipped — set " & LongTestEnv &
        "=1 to run the long-form full-suite sweep. The invariant itself is " &
        "guarded by the single-target case above, which always runs.")
      skip()
    else:
      runHotCacheCheck("test")
