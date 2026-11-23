## t_build_ending_in_runquota_deadlock_writes_its_reports — a ``repro build``
## that ends in a RunQuota static-capacity deadlock is a failed build, and it
## leaves the same documents behind as any other failed build.
##
## What this test owns
## -------------------
## ``CLI/build.md`` §"Persist": "a failing build given ``--write-report``
## writes both" the full report and the failure report. A lease that the
## daemon can never admit (the request exceeds the host's static budget) is
## re-offered until the denial deadline expires and then ends the build in a
## ``static-capacity deadlock`` (``docs/runquota-policy.md``). That outcome
## used to be raised out of the build engine in place of its result, so the
## CLI printed the deadlock and wrote neither document, on every route:
##
##   * an action of the build graph itself (here: the Tier 2a
##     ``trycompile.rbsz`` route, whose graph is the envelope, so nothing
##     else runs before it);
##   * the CMake regeneration edge, which runs in an engine pass of its own
##     before the graph exists;
##   * the project-interface extraction edge, the first edge of a ``repro.nim``
##     project.
##
## Each case asserts, against the SAME invocation's output, that the deadlock
## is still reported as a deadlock (the action's stderr names it and the
## budget it exceeded, and its reason says so), that the failure report names
## the deadlocked action, and that ``--write-report`` writes the full report
## with that action in it. The command was never started, so its output file
## must not exist.
##
## Mocks: none. The real built ``repro`` CLI (``--daemon=off``) against a real
## ``runquotad`` started with a 64 MiB machine memory budget, below the
## 128 MiB every action requests by default. ``REPRO_RUNQUOTA_DENIAL_TIMEOUT``
## is shortened so the deadlock is reached in milliseconds rather than the
## default 30 s; the deadline only decides when the deadlock is declared, not
## whether. The CMake ``provider.meta`` is hand-written with the keys
## ``cmakeRegenerationMetadataForModule`` reads: the regeneration edge is
## denied its lease before it would launch, so no CMake is needed.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support
import repro_test_support/reasoned_skip
import repro_cmake_trycompile

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))
let tryCompileProviderBin = reproBin.parentDir /
  addFileExt("repro-cmake-trycompile-provider", ExeExt)

const
  ReportSchemaId = "reprobuild.build.report.v1"
  FailureSchemaId = "reprobuild.build.failure-report.v1"
  DeadlockText = "static-capacity deadlock"
  BudgetText = "memory budget"
  DeadlockReason = "runquota static-capacity deadlock"
  TinyMemoryBudget = "67108864" # 64 MiB

  TryCompileModuleFixture = """
import repro_project_dsl

package deadlockTryCompileProbe:
  discard
"""

  RecipeFixture = """
import repro_project_dsl

package deadlockRecipeProbe:
  uses:
    "nim >=2.2 <3.0"

  executable deadlockProbe:
    build:
      discard nim.c(source = "src/deadlockProbe.nim", binary = "deadlockProbe")
"""

type BuildRun = object
  exitCode: int
  output: string

proc explain(run: BuildRun): string =
  "exit=" & $run.exitCode & "\n--- output ---\n" & run.output

proc logValue(run: BuildRun; prefix: string): string =
  for line in run.output.splitLines():
    if line.startsWith(prefix):
      result = line[prefix.len .. ^1].strip()

proc outDirOf(project: string): string =
  project / ".repro" / "build" / "repro"

proc writeTryCompileProject(root: string) =
  ## A one-action envelope whose inline command would write
  ## ``probe-output.txt``; it must never get to.
  let meta = TryCompileMetadata(
    actions: @[TryCompileActionDef(id: "deadlock-probe",
      inline: true,
      inlineArgv: @[findExe("sh"), "-c",
        "printf ran > " & quoteShell(root / "probe-output.txt")],
      inlineCwd: root,
      outputs: @[root / "probe-output.txt"],
      cacheable: false)],
    targets: @[TryCompileTargetDef(name: "all",
      actionIds: @["deadlock-probe"])],
    defaultTargetName: "all")
  writeFile(root / "reprobuild.nim", TryCompileModuleFixture)
  writeFile(root / "trycompile.rbsz",
    cast[string](encodeTryCompileMetadata(meta)))

proc writeCmakeProviderMeta(root: string) =
  ## The generator's metadata, as far as the regeneration edge reads it. No
  ## ``provider.last`` exists, so the generated state is not fresh and the
  ## edge has to run.
  createDir(root / "CMakeFiles" / "reprobuild")
  writeFile(root / "CMakeFiles" / "reprobuild" / "provider.meta",
    "generator=Reprobuild\n" &
    "source_dir=" & root & "\n" &
    "binary_dir=" & root & "\n" &
    "cmake_command=" & findExe("sh") & "\n")

let daemonBin =
  try: requireRunQuotaDaemonBin(repoRoot())
  except OSError: ""

proc unavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if not fileExists(tryCompileProviderBin):
    return "needs " & tryCompileProviderBin & " beside the CLI (run `just build`)"
  if daemonBin.len == 0:
    return "needs runquotad (set RUNQUOTAD_BIN or build ../runquota)"
  if findExe("sh").len == 0:
    return "needs `sh` on PATH for the fixture's inline action"
  ""

var daemon: Process = nil
var socketPath = ""

proc startTightDaemon() =
  socketPath = runquotaSocketEndpoint("rq-deadlock-" & $getCurrentProcessId())
  if fileExists(socketPath):
    removeFile(socketPath)
  daemon = startProcess(daemonBin, args = [
    "--socket", socketPath,
    "--memory-bytes", TinyMemoryBudget], options = {poParentStreams})
  putEnv("RUNQUOTA_SOCKET", socketPath)
  for _ in 0 ..< 400:
    if fileExists(socketPath) or not daemon.running:
      break
    sleep(25)
  if not daemon.running:
    raise newException(OSError, "runquotad exited before it listened")

proc stopDaemon() =
  if daemon != nil:
    daemon.terminate()
    discard daemon.waitForExit()
    daemon.close()
    daemon = nil
  if socketPath.len > 0 and fileExists(socketPath):
    removeFile(socketPath)

proc runBuild(project: string; extra: openArray[string]): BuildRun =
  var command = quoteShell(reproBin) & " build"
  for arg in ["--tool-provisioning=path", "--daemon=off", "--progress=quiet",
      "--log=actions"]:
    command.add(" " & quoteShell(arg))
  for arg in extra:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command, workingDir = project)
  BuildRun(exitCode: res.exitCode, output: res.output)

proc checkDeadlockedAction(item: JsonNode) =
  ## One action the deadlock stopped, as either document records it.
  checkpoint($item)
  check item{"status"}.getStr == "asFailed"
  check item{"reason"}.getStr == DeadlockReason
  check item{"stderr"}.getStr.contains(DeadlockText)
  check item{"stderr"}.getStr.contains(BudgetText)

proc checkFailureReport(run: BuildRun; expectedId: string) =
  let failurePath = run.logValue("buildFailureReport: ")
  check failurePath.len > 0
  check fileExists(failurePath)
  if fileExists(failurePath):
    let node = parseFile(failurePath)
    check node{"schemaId"}.getStr == FailureSchemaId
    check node{"counts"}{"failed"}.getInt == 1
    check node{"failedActions"}.len == 1
    if node{"failedActions"}.len == 1:
      let failed = node{"failedActions"}[0]
      if expectedId.len > 0:
        check failed{"id"}.getStr == expectedId
      checkDeadlockedAction(failed)

let scratch = createTempDir("repro-rq-deadlock-", "")
putEnv("REPRO_RUNQUOTA_DENIAL_TIMEOUT", "1")
# The recipe-compiling route provisions Nim unless told otherwise; the edge
# never launches here, but naming the compiler keeps provisioning out of it.
if getEnv("REPRO_NIM_COMPILER").len == 0 and findExe("nim").len > 0:
  putEnv("REPRO_NIM_COMPILER", findExe("nim"))

suite "a build that ends in a RunQuota static-capacity deadlock":

  setup:
    if unavailable().len == 0:
      startTightDaemon()

  teardown:
    stopDaemon()

  test "a deadlocked graph action: --write-report writes both documents":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let project = scratch / "graph"
      createDir(project)
      writeTryCompileProject(project)
      let reportPath = scratch / "graph-report.json"
      let run = runBuild(project, [project & "#all",
        "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode != 0
      check "trycompileDirect: dispatching" in run.output
      check run.output.contains(DeadlockText)
      check not fileExists(project / "probe-output.txt")
      check run.logValue("buildReport: ") == reportPath
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        check report{"schemaId"}.getStr == ReportSchemaId
        check report{"actions"}.len == 1
        if report{"actions"}.len == 1:
          checkDeadlockedAction(report{"actions"}[0])
        # The lease was requested from the daemon: no bypass.
        check not report{"runQuota"}{"bypassed"}.getBool
      checkFailureReport(run, "")

  test "a deadlocked graph action writes its failure report unasked":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let project = scratch / "graph-unasked"
      createDir(project)
      writeTryCompileProject(project)
      let run = runBuild(project, [project & "#all"])
      checkpoint(explain(run))
      check run.exitCode != 0
      check run.output.contains(DeadlockText)
      checkFailureReport(run, "")
      check not fileExists(outDirOf(project) / "build-report.json")

  test "a deadlocked CMake regeneration edge writes both documents":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let project = scratch / "cmake"
      createDir(project)
      writeTryCompileProject(project)
      writeCmakeProviderMeta(project)
      let reportPath = scratch / "cmake-report.json"
      let run = runBuild(project, [project & "#all",
        "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode != 0
      check "cmakeRegenerationAction: __repro_cmake_regenerate " &
        "status=asFailed" in run.output
      check run.output.contains(DeadlockText)
      # The regeneration edge failed, so the graph was never dispatched.
      check "trycompileDirect: dispatching" notin run.output
      check not fileExists(project / "probe-output.txt")
      check run.logValue("buildReport: ") == reportPath
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        check report{"schemaId"}.getStr == ReportSchemaId
        check report{"providerRoute"}.getStr == "not-reached"
        check report{"providerNotReached"}{"stage"}.getStr ==
          "cmake-regeneration"
        check report{"actions"}.len == 0
        check report{"cmakeRegenerationActions"}.len == 1
        if report{"cmakeRegenerationActions"}.len == 1:
          let item = report{"cmakeRegenerationActions"}[0]
          check item{"id"}.getStr == "__repro_cmake_regenerate"
          checkDeadlockedAction(item)
      checkFailureReport(run, "__repro_cmake_regenerate")

  test "a deadlocked interface extraction edge writes both documents":
    let why = unavailable()
    if why.len > 0:
      skip(why)
    else:
      let project = scratch / "recipe"
      createDir(project / "src")
      writeFile(project / "repro.nim", RecipeFixture)
      writeFile(project / "src" / "deadlockProbe.nim", "echo \"probe\"\n")
      let reportPath = scratch / "recipe-report.json"
      let run = runBuild(project, [project, "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode != 0
      check run.output.contains(DeadlockText)
      check run.logValue("buildReport: ") == reportPath
      check fileExists(reportPath)
      var extractId = ""
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        check report{"schemaId"}.getStr == ReportSchemaId
        check report{"providerRoute"}.getStr == "not-reached"
        check report{"providerNotReached"}{"stage"}.getStr ==
          "interface-extraction"
        check report{"actions"}.len == 0
        check report{"interfaceExtractActions"}.len == 1
        if report{"interfaceExtractActions"}.len == 1:
          let item = report{"interfaceExtractActions"}[0]
          extractId = item{"id"}.getStr
          check extractId.startsWith("__repro_interface_extract-")
          # The extraction record carries no streams (``interfaceExtractActionJson``);
          # the failure report below checks the deadlock text.
          check item{"status"}.getStr == "asFailed"
          check item{"reason"}.getStr == DeadlockReason
      checkFailureReport(run, extractId)

try:
  removeDir(scratch)
except OSError:
  discard
