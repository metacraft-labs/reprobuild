## Bootstrap-And-Self-Build B3: an e2e test that depends on
## ``./build/bin/repro`` wires the engine-built CLI into its execute edge.
##
## The selected target is ``t_show_conventions_cli``: it spawns
## ``./build/bin/repro show-conventions`` and therefore carries
## ``requiresReproBinary = true`` in ``repro_tests.nim``. The engine-level
## arm proves the wiring in two halves, neither of which replaces the
## binary the running suite executes:
##
##   1. GRAPH. ``repro graph`` over the direct execute-edge selector must
##      show the execute edge DEPENDING on ``reprobuild.apps.repro`` and
##      reading ``build/bin/repro`` as an input, with the app edge as the
##      producer of that path. That is the wiring itself: it is what makes
##      the scheduler build (or cache-hit) the CLI before running the test,
##      and what makes a relinked CLI invalidate the test.
##   2. RUN. Invalidate only the test (``--hard-rebuild --only`` naming the
##      execute edge, ``Edge-Determinism-And-Soft-Rebuild.md`` §4.3/§4.5 --
##      the forced stand-in for "the test's source changed") and build the
##      selector. The execute edge must be a launched cache MISS that exits
##      0; the app edge must be in the same closure, up to date, and NOT launch
##      (``cdHit``). The live ``build/bin/repro`` must be the same file, with
##      the same mtime, afterwards.
##
## WHY THE APP EDGE IS NO LONGER FORCED. This arm used to force
## ``reprobuild.apps.repro`` as well (``--only=reprobuild.apps.rep?o``) and
## assert it launched. Its output is the repository's own
## ``build/bin/repro``, so every run relinked the live thin client while the
## rest of the suite was executing it -- the same hazard that, through
## ``just bootstrap``, produced ``.../build/bin/reprobuild (deleted)``
## failures in full run 41. A forced edge launching and missing the cache
## is generic ``--hard-rebuild`` behaviour, gated with the selective-rebuild
## tests; what is specific to THIS recipe is the dependency edge, and the
## graph proves that without writing anything.
##
## ``reprobuild.apps.repro`` IS CACHEABLE (``nim.c`` defaults
## ``cacheable = true`` with no override on this edge; see the HISTORY note
## in ``repro.nim`` and ``reprobuild-specs/Compiles-Are-Normal-Edges.md``),
## so ``cdHit`` is the decision the run half expects for it.
## ``scripts/run_tests.sh`` builds ``.#apps`` before any test starts, which is
## what makes it a hit; run standalone on a tree whose apps are stale, the
## engine would relink it as an ordinary dependency, and the case says so by
## failing the unchanged-binary check rather than passing silently. The
## forced execute edge launching beside an app edge that does NOT launch is
## also the control that shows the report fields are the engine's real
## per-edge decisions rather than constants.
##
## No mocks: the real recipe, the real engine and the run-wide action cache.

import std/[json, os, osproc, sequtils, strtabs, strutils, tempfiles, times, unittest]
import repro_test_support

const RepoMarker = "repro.nim"
const TargetTest = "t_show_conventions_cli"
const TargetSource = "libs/repro_core/tests/t_show_conventions_cli.nim"
const ExecuteActionId = "reprobuild.test_execute." & TargetTest
const ReproAppActionId = "reprobuild.apps.repro"

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
  ## NO ``--action-cache-root``: the build uses the run-wide root, and only
  ## the execute edge is forced; see the module header for why the app edge
  ## must not be.
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

proc graphJsonFor(reproBin, repoRoot, selector: string):
    tuple[doc: JsonNode; output: string; exitCode: int] =
  ## ``repro graph`` lowers and prints the selected closure; it schedules
  ## and writes nothing under ``build/``.
  let args = @[
    reproBin.quoteShell,
    "graph",
    selector,
    "--tool-provisioning=path",
    "--format=json"]
  let (output, exitCode) = runWithRunquotaOnPath(args.join(" "), repoRoot)
  if exitCode == 0:
    try:
      return (parseJson(output), output, exitCode)
    except JsonParsingError:
      return (nil, output, 1)
  (nil, output, exitCode)

proc stringsOf(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node:
    if item.kind == JString:
      result.add(item.getStr())

proc namesReproCli(path: string): bool =
  ## A graph path for the thin client, whichever base it is spelled against
  ## (absolute input paths, ``cwd``-relative output paths).
  path.replace('\\', '/').endsWith("build/bin/" & addFileExt("repro", ExeExt))

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

      # 1. GRAPH: the execute edge depends on the app edge and reads its
      #    output. Nothing is scheduled.
      let (graph, graphOutput, graphExit) =
        graphJsonFor(reproBin, repoRoot, selector)
      checkpoint("graph exit=" & $graphExit)
      if graphExit != 0:
        checkpoint(graphOutput)
      check graphExit == 0
      check not graph.isNil
      if graph != nil:
        var graphApp, graphExecute: JsonNode = nil
        for action in reportActions(graph):
          let id = action{"id"}.getStr()
          if id == ReproAppActionId: graphApp = action
          elif id == ExecuteActionId: graphExecute = action
        check not graphApp.isNil
        check not graphExecute.isNil
        if graphApp != nil and graphExecute != nil:
          let deps = stringsOf(graphExecute{"deps"})
          let inputs = stringsOf(graphExecute{"inputs"})
          let appOutputs = stringsOf(graphApp{"outputs"})
          checkpoint(ExecuteActionId & " deps=" & $deps)
          checkpoint(ExecuteActionId & " build/bin inputs=" &
            $inputs.filterIt("build/bin/" in it.replace('\\', '/')))
          checkpoint(ReproAppActionId & " outputs=" & $appOutputs)
          check ReproAppActionId in deps
          check inputs.anyIt(namesReproCli(it))
          check appOutputs.anyIt(namesReproCli(it))

      # 2. RUN: only the test is invalidated. The live CLI must come through
      #    untouched -- same file, same mtime.
      let beforeInfo = getFileInfo(reproBin)
      let reportDir = createTempDir("repro-b3-invalidation-report-", "")
      defer: removeDir(reportDir)
      let reportPath = reportDir / "build-report.json"
      let (output, exitCode) = runBuildTarget(reproBin, repoRoot, selector,
        [ExecuteActionId], reportPath)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0

      let afterInfo = getFileInfo(reproBin)
      checkpoint("build/bin/repro before: id=" & $beforeInfo.id.file &
        " mtime=" & $beforeInfo.lastWriteTime & "; after: id=" &
        $afterInfo.id.file & " mtime=" & $afterInfo.lastWriteTime)
      # If these move, the build relinked the binary every concurrently
      # running test executes. In a suite run `.#apps` is built first, so
      # this only fails on a tree whose apps are stale -- run `just build`.
      check afterInfo.id == beforeInfo.id
      check afterInfo.lastWriteTime == beforeInfo.lastWriteTime

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
          # A cache hit reports `asUpToDate`; `asSucceeded` would mean it ran.
          check reproAppAction{"status"}.getStr() == "asUpToDate"
          check not reproAppAction{"launched"}.getBool()
          check reproAppAction{"cacheDecision"}.getStr() == "cdHit"

        if executeAction != nil:
          checkpoint(ExecuteActionId & " status=" &
            fieldForCheckpoint(executeAction, "status") & " launched=" &
            fieldForCheckpoint(executeAction, "launched") &
            " cacheDecision=" &
            fieldForCheckpoint(executeAction, "cacheDecision") &
            " reason=" & fieldForCheckpoint(executeAction, "reason"))
          check executeAction{"status"}.getStr() == "asSucceeded"
          check executeAction{"launched"}.getBool()
          check executeAction{"cacheDecision"}.getStr() == "cdMiss"
          check "exit=0" in executeAction{"reason"}.getStr()
