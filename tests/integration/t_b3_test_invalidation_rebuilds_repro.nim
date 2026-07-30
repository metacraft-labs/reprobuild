## Bootstrap-And-Self-Build B3: an e2e test that depends on
## ``./build/bin/repro`` wires the engine-built CLI into its execute edge.
##
## The selected target is ``t_show_conventions_cli``: it spawns
## ``./build/bin/repro show-conventions`` and therefore carries
## ``requiresReproBinary = true`` in ``repro_tests.nim``. The engine-level
## arm builds the direct execute-edge selector and verifies that the
## scheduler runs both ``reprobuild.apps.repro`` and the execute edge.

import std/[json, os, osproc, strtabs, strutils, unittest]
import repro_test_support

const RepoMarker = "repro.nim"
const TargetTest = "t_show_conventions_cli"
const TargetSource = "libs/repro_core/tests/t_show_conventions_cli.nim"
const ExecuteActionId = "reprobuild.test_execute." & TargetTest

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

proc runBuildTarget(reproBin, repoRoot, selector: string):
    tuple[output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--tool-provisioning=path",
    "--daemon=off",
    "--write-report",
    "--log=actions",
    "--progress=quiet",
  ]
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
      let selector = ".#" & ExecuteActionId
      let (output, exitCode) = runBuildTarget(reproBin, repoRoot, selector)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0

      let reportPath = valueAfter(output, "buildReport:")
      check reportPath.len > 0
      check fileExists(reportPath)

      if reportPath.len > 0 and fileExists(reportPath):
        let report = parseFile(reportPath)
        let actions = reportActions(report)
        var reproAppAction, executeAction: JsonNode = nil
        for action in actions:
          let id = action{"id"}.getStr()
          if id == "reprobuild.apps.repro":
            reproAppAction = action
          elif id == ExecuteActionId:
            executeAction = action

        check reproAppAction != nil
        check executeAction != nil

        if reproAppAction != nil:
          checkpoint("reprobuild.apps.repro status=" &
            fieldForCheckpoint(reproAppAction, "status") & " launched=" &
            fieldForCheckpoint(reproAppAction, "launched") &
            " cacheDecision=" &
            fieldForCheckpoint(reproAppAction, "cacheDecision"))
          check reproAppAction{"status"}.getStr() == "asSucceeded"
          check reproAppAction{"launched"}.getBool()
          check reproAppAction{"cacheDecision"}.getStr() == "cdNotCacheable"

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
