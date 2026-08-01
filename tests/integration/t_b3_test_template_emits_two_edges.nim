## Bootstrap-And-Self-Build B3: each ``TestSpec`` entry expands into
## both a build edge and an execute edge in the engine graph.
##
## The live engine arm uses ``repro graph`` against representative direct
## execute-edge selectors. This avoids rebuilding the whole ``.#test-builds``
## collection inside one integration test while still verifying that the
## selected closure contains the test binary build edge and the matching
## ``reprobuild.test_execute.<stem>`` action.

import std/[json, os, osproc, sequtils, sets, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

const SampleStems = [
  "t_dsl_outputs_statement_basic_accepted",
  "t_dsl_outputs_typed_multiple_interfaces",
  "t_engine_action_create_dyndep",
]

const KnownReproBinaryConsumers = [
  "tests/integration/t_b1_apps_action_cache_hit.nim",
  "tests/integration/t_b1_repro_build_apps_byte_equivalent.nim",
  "tests/integration/t_b2_helper_invalidation.nim",
  "tests/integration/t_b2_helpers_built_by_engine.nim",
  "libs/repro_core/tests/t_show_conventions_cli.nim",
]

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

proc countOccurrences(haystack, needle: string): int =
  if needle.len == 0:
    return 0
  var idx = 0
  while true:
    let hit = haystack.find(needle, idx)
    if hit < 0: break
    inc result
    idx = hit + needle.len

proc actionOutputs(action: JsonNode): JsonNode =
  result = action{"outputs"}
  if result.isNil or result.kind == JNull:
    result = action{"evidence"}{"declaredOutputs"}
  if result.isNil or result.kind == JNull:
    result = newJArray()

proc graphJsonFor(reproBin, repoRoot, selector: string):
    tuple[doc: JsonNode; output: string; exitCode: int] =
  let args = @[
    reproBin.quoteShell,
    "graph",
    selector,
    "--tool-provisioning=path",
    "--format=json",
  ]
  let (output, exitCode) = runWithRunquotaOnPath(args.join(" "), repoRoot)
  if exitCode == 0:
    try:
      return (parseJson(output), output, exitCode)
    except JsonParsingError:
      return (nil, output, 1)
  (nil, output, exitCode)

suite "Bootstrap-And-Self-Build B3: test template emits two edges":

  test "structural: repro.nim + repro_tests.nim declare two-edge emission per TestSpec":
    let repoRoot = findRepoRoot()
    let reproNim = repoRoot / "repro.nim"
    let reproTests = repoRoot / "repro_tests.nim"
    check fileExists(reproNim)
    check fileExists(reproTests)

    let reproNimText = readFile(reproNim)
    let reproTestsText = readFile(reproTests)

    check "buildNimUnittest.build(" in reproNimText
    check "edge.testBinary.run(" in reproNimText
    let buildIdx = reproNimText.find("buildNimUnittest.build(")
    let execIdx = reproNimText.find("edge.testBinary.run(")
    check buildIdx >= 0
    check execIdx >= 0
    check execIdx > buildIdx

    check "reprobuild.test_execute." in reproNimText
    check "reproTestExecuteId" in reproNimText
    check "collect(\"test\", reprobuildTestExecuteActions" in reproNimText
    check "collect(\"test-builds\", reprobuildTestBuildActions" in reproNimText
    check "reprobuildTestBuildActions" in reproNimText
    check "reprobuildTestExecuteActions" in reproNimText
    check "spec.requiresReproBinary" in reproNimText
    check "requiredBinaries" in reproNimText
    check "reproBinaryPath" in reproNimText
    check "build/bin/repro" in reproNimText
    check "Bootstrap-And-Self-Build B3" in reproNimText

    check "requiresReproBinary*: bool" in reproTestsText
    check "requiresReproBinary:" in reproTestsText
    let sourceCount = countOccurrences(reproTestsText, "source:")
    checkpoint("repro_tests.nim source rows: " & $sourceCount)
    check sourceCount >= 520

    let trueCount = countOccurrences(reproTestsText,
      "requiresReproBinary: true")
    checkpoint("repro_tests.nim requiresReproBinary: true count: " &
      $trueCount)
    check trueCount >= 5

    var unflagged: seq[string] = @[]
    for source in KnownReproBinaryConsumers:
      let marker = "source: \"" & source & "\""
      let pos = reproTestsText.find(marker)
      if pos < 0:
        checkpoint("known consumer not in table: " & source)
        unflagged.add(source)
        continue
      let limit = min(reproTestsText.len, pos + 400)
      let slice = reproTestsText[pos ..< limit]
      if "requiresReproBinary: true" notin slice:
        unflagged.add(source)
    if unflagged.len > 0:
      checkpoint("known repro-binary consumers missing the flag: " &
        unflagged.join(", "))
    check unflagged.len == 0

  test "engine: direct execute-edge graphs contain build and execute edges":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    check fileExists(reproBin)

    if fileExists(reproBin):
      var missingBuild = initHashSet[string]()
      var missingExecute = initHashSet[string]()

      for stem in SampleStems:
        let selector = ".#reprobuild.test_execute." & stem
        let (graph, output, exitCode) =
          graphJsonFor(reproBin, repoRoot, selector)
        checkpoint(selector & " graph exit=" & $exitCode)
        if exitCode != 0:
          checkpoint(output)
        check exitCode == 0
        check graph != nil

        var sawBuild = false
        var sawExecute = false
        if graph != nil:
          let actions = graph{"actions"}
          check not actions.isNil
          if not actions.isNil:
            for action in actions:
              let id = action{"id"}.getStr()
              if id == "reprobuild.test_execute." & stem:
                sawExecute = true
              for outputPath in actionOutputs(action):
                if outputPath.getStr() == "build/test-bin/" & stem:
                  sawBuild = true

        if not sawBuild:
          missingBuild.incl(stem)
        if not sawExecute:
          missingExecute.incl(stem)

      checkpoint("missing build stems: " & $toSeq(missingBuild))
      checkpoint("missing execute stems: " & $toSeq(missingExecute))
      check missingBuild.len == 0
      check missingExecute.len == 0
