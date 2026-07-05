## Bootstrap-And-Self-Build B3: a direct test execute-edge selector builds
## the selected test binary and runs that test through the engine.
##
## The self-hosted Nim compile half is deliberately non-cacheable today:
## compiler executions may produce incomplete io-mon evidence, so the graph
## reports ``cdNotCacheable`` and runs the compile edge instead of publishing
## an unsafe cache entry. The execute edge remains the behavioral proof here:
## the engine lowers the selected ``reprobuild.test_execute.<stem>`` action,
## runs it, and records a successful result.

import std/[json, os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"
const TargetTest = "t_dsl_outputs_statement_basic_accepted"
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
  let runquotaBin = repoRoot.parentDir / "runquota" / "build" / "bin"
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  let oldPath = env.getOrDefault("PATH")
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

proc runBuildTarget(reproBin, repoRoot, selector: string):
    tuple[output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--tool-provisioning=path",
    "--daemon=off",
    "--report=full",
    "--log=actions",
    "--progress=quiet",
  ]
  runWithRunquotaOnPath(args.join(" "), repoRoot)

suite "Bootstrap-And-Self-Build B3: test execute edge":

  test "structural: test and test-build collections are registered":
    let repoRoot = findRepoRoot()
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproNim)

    let reproNimText = readFile(reproNim)
    check "collect(\"test\", reprobuildTestExecuteActions" in reproNimText
    check "collect(\"test-builds\", reprobuildTestBuildActions" in
      reproNimText
    check "edge.testBinary.run(" in reproNimText
    check "cacheable = false" in reproNimText

  test "engine: direct execute-edge selector runs the selected test":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

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
        var buildAction, executeAction: JsonNode = nil
        for action in actions:
          if action{"id"}.getStr() == ExecuteActionId:
            executeAction = action
          let evidence = action{"evidence"}
          if not evidence.isNil and evidence.kind == JObject:
            let outputs = evidence{"declaredOutputs"}
            if not outputs.isNil and outputs.kind == JArray:
              for outPath in outputs:
                if outPath.getStr() == "build/test-bin/" & TargetTest:
                  buildAction = action

        check buildAction != nil
        check executeAction != nil

        if buildAction != nil:
          checkpoint(buildAction{"id"}.getStr() & " status=" &
            buildAction{"status"}.getStr() & " launched=" &
            $buildAction{"launched"}.getBool() & " cacheDecision=" &
            buildAction{"cacheDecision"}.getStr())
          check buildAction{"status"}.getStr() == "asSucceeded"
          check buildAction{"launched"}.getBool()
          check buildAction{"cacheDecision"}.getStr() == "cdNotCacheable"

        if executeAction != nil:
          checkpoint(ExecuteActionId & " status=" &
            executeAction{"status"}.getStr() & " launched=" &
            $executeAction{"launched"}.getBool() & " cacheDecision=" &
            executeAction{"cacheDecision"}.getStr() & " reason=" &
            executeAction{"reason"}.getStr())
          check executeAction{"status"}.getStr() == "asSucceeded"
          check executeAction{"launched"}.getBool()
          check "exit=0" in executeAction{"reason"}.getStr()
