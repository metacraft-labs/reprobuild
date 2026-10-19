## Bootstrap-And-Self-Build B3: an e2e test that depends on
## ``./build/bin/repro`` wires the engine-built CLI into its execute edge.
##
## The selected target is ``t_show_conventions_cli``: it spawns
## ``./build/bin/repro show-conventions`` and therefore carries
## ``requiresReproBinary = true`` in ``repro_tests.nim``. The engine-level
## arm builds the direct execute-edge selector and verifies that the
## scheduler RUNS both ``reprobuild.apps.repro`` and the execute edge.
##
## "Runs" is the whole claim, and it needs the two edges to be invalid to mean
## anything: ``scripts/run_tests.sh`` builds ``.#apps`` before any test starts,
## which leaves ``reprobuild.apps.repro`` a cache hit and ``launched = false``
## in the run-wide cache, and the case would fail saying nothing about the
## wiring it exists to check. The arm therefore invalidates exactly those two
## edges with the engine's selective rebuild — ``--hard-rebuild --only`` with
## one pattern per edge (``Edge-Determinism-And-Soft-Rebuild.md`` §4.3/§4.5)
## — and shares the run-wide root for everything else.
##
## It used to bring a private, empty ``--action-cache-root`` instead. That made
## the two edges cold, and with them the recipe compile and interface
## extraction of ``repro.nim``, the engine binary and every other edge in the
## closure: ~15 minutes per run spent re-establishing facts the case does not
## assert. The engine binary (``reprobuild.apps.reprobuild``) is deliberately
## NOT forced. A plain ``--only reprobuild.apps.repro`` would force it — that
## spelling is a substring match, and the engine's id, like most of the apps',
## contains it — so the app edge is named by the anchored glob
## ``reprobuild.apps.rep?o``, which matches that one id and nothing else.
##
## ``reprobuild.apps.repro`` IS CACHEABLE, and the report must say so. This arm
## used to assert ``cdNotCacheable`` for it, from a period when every compile
## edge in ``repro.nim`` carried ``cacheable = false``. That retreat was
## reversed on 2026-08-19 — see the HISTORY note in ``repro.nim`` and
## ``reprobuild-specs/Compiles-Are-Normal-Edges.md`` — and ``nim.c`` defaults
## ``cacheable = true`` with no override on this edge, so ``cdNotCacheable``
## became unreachable by construction. A cacheable edge the rebuild verb
## invalidated, and that succeeded AND launched, is a cache MISS, which is
## what the arm asserts. The same build without the verb, against the same
## root, reports ``cdHit`` and no launch — that is the control that shows the
## assertion is reading the engine's real decision rather than a constant.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_test_support

const RepoMarker = "repro.nim"
const TargetTest = "t_show_conventions_cli"
const TargetSource = "libs/repro_core/tests/t_show_conventions_cli.nim"
const ExecuteActionId = "reprobuild.test_execute." & TargetTest
const ReproAppActionId = "reprobuild.apps.repro"
const ReproAppForcePattern = "reprobuild.apps.rep?o"
  ## ``ReproAppActionId`` as an ANCHORED glob. ``--only`` treats a pattern
  ## without ``*``/``?`` as a substring, and ``reprobuild.apps.repro`` is a
  ## substring of the engine's id (``reprobuild.apps.reprobuild``) and of most
  ## other apps' ids; this spelling matches exactly the one edge.

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

proc fieldForCheckpoint(action: JsonNode; name: string): string =
  let field = action{name}
  if field.isNil or field.kind == JNull:
    return "<missing>"
  if field.kind == JString:
    return field.getStr()
  $field

proc countOccurrences(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var idx = 0
  while true:
    let hit = haystack.find(needle, idx)
    if hit < 0: break
    inc result
    idx = hit + needle.len

proc specSlice(reproTestsText, source: string): string =
  let marker = "source: \"" & source & "\""
  let pos = reproTestsText.find(marker)
  if pos < 0:
    return ""
  let limit = min(reproTestsText.len, pos + 400)
  reproTestsText[pos ..< limit]

proc runBuildTarget(reproBin, repoRoot, selector: string;
                    forcePatterns: openArray[string];
                    reportPath: string): tuple[output: string; exitCode: int] =
  ## THE REPORT IS SCOPED TO THE CASE. A bare ``--write-report`` lands on
  ## ``<outDir>/build-report.json``, and ``outDir`` collapses to ONE directory
  ## for every selector this suite drives: ``outputDirForTarget``
  ## (``libs/repro_cli_support/src/repro_cli_support.nim``) takes
  ## ``outputName`` from ``resolveProjectFile(".")`` =
  ## ``splitFile("repro.nim").name`` = ``repro``, and ``scripts/run_tests.sh``
  ## sets no ``REPROBUILD_WORK_ROOT``.
  ##
  ## NO ``--action-cache-root``: the build uses the run-wide root, and the
  ## edges this case asserts about are forced; see the module header.
  var args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--tool-provisioning=path",
    "--daemon=off",
    "--hard-rebuild"]
  for pattern in forcePatterns:
    args.add("--only=" & pattern.quoteShell)
  args.add(@[
    "--write-report=" & reportPath.quoteShell,
    "--log=actions",
    "--progress=quiet"])
  runWithRunquotaOnPath(args.join(" "), repoRoot)

suite "Bootstrap-And-Self-Build B3: repro binary input wiring":

  test "structural: requiresReproBinary input-wiring has consumers":
    let repoRoot = findRepoRoot()
    let reproTests = repoRoot / "repro_tests.nim"
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproTests)
    check fileExists(reproNim)

    let reproTestsText = readFile(reproTests)
    let reproNimText = readFile(reproNim)

    check "requiresReproBinary*: bool" in reproTestsText
    let trueCount = countOccurrences(reproTestsText,
      "requiresReproBinary: true")
    let falseCount = countOccurrences(reproTestsText,
      "requiresReproBinary: false")
    checkpoint("requiresReproBinary: true=" & $trueCount &
      " false=" & $falseCount)
    check trueCount >= 5
    check falseCount >= 100

    let targetSpec = specSlice(reproTestsText, TargetSource)
    check targetSpec.len > 0
    check "requiresReproBinary: true" in targetSpec

    check "spec.requiresReproBinary" in reproNimText
    check "requiredBinaries" in reproNimText
    check "build/bin/repro" in reproNimText

  test "engine: selected e2e execute edge builds repro and runs the test":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = requireRunQuotaDaemonBin(repoRoot)

    check fileExists(reproBin)
    check fileExists(runquotad)

    if fileExists(reproBin) and fileExists(runquotad):
      let reportDir = createTempDir("repro-b3-invalidation-report-", "")
      defer: removeDir(reportDir)
      let reportPath = reportDir / "build-report.json"
      let selector = ".#" & ExecuteActionId
      let (output, exitCode) = runBuildTarget(reproBin, repoRoot, selector,
        [ReproAppForcePattern, ExecuteActionId], reportPath)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0

      # The engine must still ANNOUNCE a report — unchanged. Only the file
      # that is parsed changed.
      let announced = valueAfter(output, "buildReport:")
      check announced.len > 0
      check fileExists(reportPath)

      if announced.len > 0 and fileExists(reportPath):
        let report = parseFile(reportPath)
        let actions = reportActions(report)
        var reproAppAction, executeAction: JsonNode = nil
        for action in actions:
          let id = action{"id"}.getStr()
          if id == ReproAppActionId:
            reproAppAction = action
          elif id == ExecuteActionId:
            executeAction = action

        check not reproAppAction.isNil
        check not executeAction.isNil

        if reproAppAction != nil:
          checkpoint("reprobuild.apps.repro status=" &
            fieldForCheckpoint(reproAppAction, "status") & " launched=" &
            fieldForCheckpoint(reproAppAction, "launched") &
            " cacheDecision=" &
            fieldForCheckpoint(reproAppAction, "cacheDecision"))
          check reproAppAction{"status"}.getStr() == "asSucceeded"
          check reproAppAction{"launched"}.getBool()
          check reproAppAction{"cacheDecision"}.getStr() == "cdMiss"

        if executeAction != nil:
          checkpoint(ExecuteActionId & " status=" &
            fieldForCheckpoint(executeAction, "status") & " launched=" &
            fieldForCheckpoint(executeAction, "launched") &
            " cacheDecision=" &
            fieldForCheckpoint(executeAction, "cacheDecision") &
            " reason=" & fieldForCheckpoint(executeAction, "reason"))
          check executeAction{"status"}.getStr() == "asSucceeded"
          check executeAction{"launched"}.getBool()
          check "exit=0" in executeAction{"reason"}.getStr()
