## Bootstrap-And-Self-Build B2: touching one helper's source invalidates that
## helper's action-cache entry and only that one; the other helper edges stay
## cache-hit.
##
## WHAT THIS CASE USED TO ASSERT, AND WHY IT CANNOT.
## The helper binaries are compiled by ``nim.c`` edges in ``repro.nim``. Until
## 2026-08-19 those edges carried ``cacheable = false``, and this case asserted
## ``cdNotCacheable`` for every one of them. That retreat has since been
## reversed deliberately: every compile edge in ``repro.nim`` is back on
## ``defaultDependencyPolicy()`` — monitored, complete evidence, cacheable. See
## the HISTORY note above the ``repro-install-mirror-publish`` edge in
## ``repro.nim`` and ``reprobuild-specs/Compiles-Are-Normal-Edges.md``, whose
## IM-5 paragraph records the classification gap that had made monitored Nim
## binaries unpublishable and states that "monitored pipelines now publish and
## hit the cache". ``nim.c`` defaults ``cacheable = true`` and no helper edge
## here overrides it, so ``cdNotCacheable`` is unreachable for these actions by
## construction: the assertion could only ever fail.
##
## WHAT REPLACES IT. The property the file is named for, which is strictly more
## than the retired assertion claimed — a cacheable edge owes a REAL decision in
## both directions, where ``cdNotCacheable`` only ever said the cache was never
## consulted. ``.#test-helpers`` is driven twice:
##
##   1. Warm the action cache. Whether the engine compiles the helpers here or
##      reuses entries an earlier build published does not matter and is not
##      asserted; what matters is that entries exist afterwards.
##
##   2. Bump the mtime of ``live_endpoint_helper.nim`` and re-run. Under the
##      default ``ffpTimestamp`` action-cache policy a new mtime IS a changed
##      input, so the report must then show
##
##        * ``reprobuild.test_helpers.live_endpoint_helper`` — ``cdMiss``,
##          ``launched``, ``asSucceeded``, ``exit=0``: a real miss caused by a
##          real input change, and the edge re-ran;
##        * every other ``reprobuild.test_helpers.*`` edge — ``cdHit`` and NOT
##          launched: the invalidation is confined to the edge whose input
##          moved, with no spurious rebuilds.
##
## Only the file's mtime is touched; its bytes are left alone, and
## ``scripts/bootstrap_guard.sh`` excludes ``tests/`` from the freshness scan
## that decides whether ``just bootstrap`` relinks the apps.

import std/[json, os, osproc, sequtils, strtabs, strutils, tempfiles, times,
  unittest]
import repro_test_support

const RepoMarker = "repro.nim"

const RequiredHelperNames = [
  "live_endpoint_helper",
  "fake_protocol_daemon_helper",
  "harness_apply_lock_holder",
]

const TouchedHelper = "live_endpoint_helper"
const TouchedSource =
  "tests/fixtures/local-daemons-control-plane/live-endpoint-helper/" &
  "live_endpoint_helper.nim"

const ActionIdPrefix = "reprobuild.test_helpers."

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runWithRunquotaOnPath(cmd, repoRoot: string): tuple[output: string;
    exitCode: int] =
  let runquota = requireRunQuotaCliBin(repoRoot)
  let runquotad = requireRunQuotaDaemonBin(repoRoot)
  let runquotaBin = runquota.parentDir
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
  env["RUNQUOTA_BIN"] = runquota
  env["RUNQUOTAD_BIN"] = runquotad
  env["PATH"] = runquotaBin & $PathSep & oldPath
  execCmdEx(cmd, env = env, workingDir = repoRoot)

proc valueAfter(output, prefix: string): string =
  for line in output.splitLines:
    if line.startsWith(prefix):
      return line[prefix.len .. ^1].strip()
  ""

proc reportActions(report: JsonNode): JsonNode =
  result = report{"actions"}
  if result.isNil or result.kind == JNull:
    result = newJArray()

proc runBuildHelpers(reproBin, repoRoot, reportPath: string):
    tuple[output: string; exitCode: int] =
  ## THE DESTINATION IS NAMED, not defaulted. A bare ``--write-report`` lands
  ## on ``<outDir>/build-report.json``, and ``outDir`` collapses to ONE
  ## directory for every selector this suite drives: ``outputDirForTarget``
  ## (``libs/repro_cli_support/src/repro_cli_support.nim:1103``) takes
  ## ``outputName`` from ``resolveProjectFile(".")`` =
  ## ``splitFile("repro.nim").name`` = ``repro`` (same file, 726-729), and
  ## ``scripts/run_tests.sh`` sets no ``REPROBUILD_WORK_ROOT`` so the
  ## worktree-scoped branch never fires. ``.#test-helpers``, ``.#apps`` and
  ## every ``.#reprobuild.*`` selector therefore shared
  ## ``<repoRoot>/.repro/build/repro/build-report.json``. This case is on
  ## ``ExclusiveStems``, so nothing was concurrent with it — but that is a
  ## property of the schedule, not of the case, and the pool-resident
  ## ``t_b2_helpers_built_by_engine`` drives the SAME collection.
  let args = @[
    reproBin.quoteShell,
    "build",
    ".#test-helpers",
    "--tool-provisioning=path",
    "--daemon=off",
    "--write-report=" & reportPath.quoteShell,
    "--log=actions",
    "--progress=quiet",
  ]
  runWithRunquotaOnPath(args.join(" "), repoRoot)

proc touchFile(path: string) =
  ## Bump the mtime so the engine's recorded input fingerprint no longer
  ## matches. ``ffpTimestamp`` is the default action-cache policy, so this is a
  ## changed input; the file's bytes are untouched.
  setLastModificationTime(path, getTime())

suite "Bootstrap-And-Self-Build B2: helper invalidation":

  test "touching one helper source invalidates only that helper":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = requireRunQuotaDaemonBin(repoRoot)
    let touchedAbs = repoRoot / TouchedSource
    let touchedId = ActionIdPrefix & TouchedHelper

    check fileExists(reproBin)
    check fileExists(runquotad)
    check fileExists(touchedAbs)

    if fileExists(reproBin) and fileExists(runquotad) and
        fileExists(touchedAbs):
      # Pass 1 — warm the cache. No assertion is read from this report; the
      # only thing it has to do is leave an entry behind for every helper edge.
      let reportDir = createTempDir("repro-b2-helpers-report-", "")
      defer: removeDir(reportDir)
      let reportPath = reportDir / "build-report.json"

      let (firstOut, firstExit) =
        runBuildHelpers(reproBin, repoRoot, reportDir / "warmup-report.json")
      checkpoint("first exit=" & $firstExit)
      if firstExit != 0:
        checkpoint(firstOut)
      check firstExit == 0

      if firstExit == 0:
        touchFile(touchedAbs)
        checkpoint("touched: " & touchedAbs)

        let (output, exitCode) =
          runBuildHelpers(reproBin, repoRoot, reportPath)
        checkpoint("second exit=" & $exitCode)
        if exitCode != 0:
          checkpoint(output)
        check exitCode == 0

        # The engine must still ANNOUNCE a report — unchanged. Only the file
        # that is parsed changed: this case's own, never the shared default.
        let announced = valueAfter(output, "buildReport:")
        check announced.len > 0
        check fileExists(reportPath)

        if announced.len > 0 and fileExists(reportPath):
          let report = parseFile(reportPath)
          let actions = reportActions(report)
          var helperActions: seq[JsonNode] = @[]
          for action in actions:
            let id = action{"id"}.getStr()
            if id.startsWith(ActionIdPrefix):
              helperActions.add(action)

          checkpoint("found " & $helperActions.len &
            " " & ActionIdPrefix & "* actions in build report")
          check helperActions.len >= RequiredHelperNames.len

          let helperIds = helperActions.mapIt(it{"id"}.getStr())
          for name in RequiredHelperNames:
            check ActionIdPrefix & name in helperIds
          check touchedId in helperIds

          for action in helperActions:
            let id = action{"id"}.getStr()
            let status = action{"status"}.getStr()
            let launched = action{"launched"}.getBool()
            let cache = action{"cacheDecision"}.getStr()
            let reason = action{"reason"}.getStr()
            checkpoint(id & " status=" & status &
              " launched=" & $launched &
              " cacheDecision=" & cache &
              " reason=" & reason)
            if id == touchedId:
              # The one edge whose input moved: a genuine miss that re-ran.
              check status == "asSucceeded"
              check launched
              check cache == "cdMiss"
              check "exit=0" in reason
            else:
              # Everything else: a genuine hit that did NOT re-run. This is the
              # half that makes the miss above meaningful — an engine that
              # rebuilt everything would satisfy the first branch too.
              check status == "asUpToDate"
              check not launched
              check cache == "cdHit"
