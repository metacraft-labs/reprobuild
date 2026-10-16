## t_build_write_report_on_lowered_provider_routes — ``repro build
## --write-report`` writes the full build report when a PREBUILT provider
## serves the build, not only when the per-project provider is compiled.
##
## What this test owns
## -------------------
## The PERSIST axis on the two lowered-graph routes ``executeBuildTarget``
## dispatches to before it ever compiles a per-project provider:
##
##   * Tier 2b ``standardDirect`` — a ``repro.nim`` with no ``build:`` block,
##     whose graph the shipped ``repro-standard-provider`` derives from the
##     language convention (here: Nim's ``.nimble`` + ``src/<bin>.nim``);
##   * Tier 2a ``trycompileDirect`` — a directory carrying the
##     ``trycompile.rbsz`` envelope CMake's Reprobuild generator writes, whose
##     graph the shipped ``repro-cmake-trycompile-provider`` emits.
##
## Both used to execute the real graph, log it, and return from
## ``executeBuildTarget`` BEFORE the one ``writeBuildReport`` call, so the
## flag was accepted, the build exited 0, and no document was written
## anywhere (reprobuild-pm issue 2026-09-30, "write-report writes no document
## on the lowered-graph arms"). ``CLI/build.md`` §"Reports from lowered or
## prebuilt provider routes" settles what has to be there instead: the same
## ``reprobuild.build.report.v1`` document, carrying the ACTUAL prebuilt
## binary and its content identity, the actual refresh record, and no
## invented compile fingerprint.
##
## The cases pin, per route:
##
##   * ``--write-report=PATH`` writes PATH with the schema id, the real
##     action results, the trace / RunQuota authority / statistics members,
##     and a provider record naming the binary that actually ran;
##   * bare ``--write-report`` writes ``<outDir>/build-report.json`` and says
##     where on the ``buildReport:`` line;
##   * ``--no-write-report`` beats ``--write-report`` and writes nothing;
##   * no option writes nothing on success (the report is opt-in);
##   * (Tier 2a) a FAILING build given ``--write-report`` writes both the full
##     report and the failure report.
##
## Every case also asserts the routing log line (``standardDirect:`` /
## ``trycompileDirect:``). Without it a regression that sent the fixture down
## the compiled-provider path would make the report appear and the test pass
## while the lowered arm stayed broken.
##
## Mocks: none. Each case drives the real built ``repro`` CLI, which
## dispatches the real prebuilt provider binaries shipped beside it in
## ``build/bin``; the ``trycompile.rbsz`` envelope is encoded by the
## production encoder rather than hand-written bytes.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_cmake_trycompile

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

let reproBin = getEnv("REPROBUILD_REPRO",
  repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt))
# The prebuilt providers resolve from the ENGINE's directory
# (``siblingStandardProviderPath(parentDir(publicCliPath))``), so they are
# looked for beside the binary under test, not at a fixed checkout path.
let binDir = reproBin.parentDir
let standardProviderBin = binDir /
  addFileExt("repro-standard-provider", ExeExt)
let tryCompileProviderBin = binDir /
  addFileExt("repro-cmake-trycompile-provider", ExeExt)

const
  ReportSchemaId = "reprobuild.build.report.v1"

  # Copied from reprobuild-examples' ``nim/binary``: no ``build:`` block and
  # a ``uses: "nim"`` the standard provider has a convention for, which is
  # exactly what makes ``standardBuildEligible`` true.
  NimFixture = """
import repro_project_dsl

package writeReportStandardProbe:
  uses:
    "nim >=2.2 <3.0"

  executable write_report_probe:
    discard
"""
  NimbleFixture = """
version = "0.1.0"
author = "Reprobuild Tests"
description = "standard-direct --write-report probe"
license = "MIT"
srcDir = "src"
bin = @["write_report_probe"]

requires "nim >= 2.2.0"
"""
  NimSourceFixture = "echo \"write-report probe\"\n"

  # The CMake generator writes a ``reprobuild.nim`` beside the envelope. On
  # the Tier 2a route it is never compiled — the envelope is the graph — but
  # it is the module the target names, so it has to exist.
  TryCompileModuleFixture = """
import repro_project_dsl

package writeReportTryCompileProbe:
  discard
"""

type BuildRun = object
  exitCode: int
  output: string

proc runBuild(project: string; extra: openArray[string]): BuildRun =
  var command = quoteShell(reproBin) & " build"
  for arg in extra:
    command.add(" " & quoteShell(arg))
  # ``--measure=all`` so the trace is populated and the report's ``trace``
  # member carries the scheduler's real events rather than an empty list.
  # ``--log=actions`` so the ``standardDirect:`` / ``action:`` /
  # ``buildReport:`` lines the cases cross-check are printed; the direct-mode
  # default is quiet when stdout is not a terminal.
  for arg in ["--tool-provisioning=path", "--daemon=off", "--no-runquota",
      "--progress=quiet", "--measure=all", "--log=actions"]:
    command.add(" " & quoteShell(arg))
  let res = execCmdEx(command, workingDir = project)
  BuildRun(exitCode: res.exitCode, output: res.output)

proc explain(run: BuildRun): string =
  "exit=" & $run.exitCode & "\n--- output ---\n" & run.output

proc logValue(run: BuildRun; prefix: string): string =
  ## The value of the LAST ``prefix`` line in the merged output. Last, because
  ## a line is re-emitted per engine pass and the final one is the one the
  ## report describes.
  for line in run.output.splitLines():
    if line.startsWith(prefix):
      result = line[prefix.len .. ^1].strip()

proc checkReportBody(report: JsonNode; route, providerBinary: string;
                     run: BuildRun) =
  ## The members ``CLI/build.md`` §"Persist" and §"Reports from lowered or
  ## prebuilt provider routes" require of every full report, checked against
  ## what the SAME invocation logged so a fabricated value cannot pass.
  check report{"schemaId"}.getStr == ReportSchemaId
  check report{"providerRoute"}.getStr == route
  # The actual binary that ran, not a compile output path.
  check sameFile(report{"providerBinary"}.getStr, providerBinary)
  check report{"providerBinary"}.getStr == run.logValue("providerBinary: ")
  check report{"providerArtifact"}.getStr == run.logValue("providerArtifact: ")
  # A prebuilt provider has a content identity, and it is the digest of the
  # bytes that ran — non-empty, hex, and not the "missing" sentinel the
  # digest helper returns for an absent file.
  let digest = report{"providerBinaryContentDigest"}.getStr
  check digest.len >= 32
  check digest != "missing"
  # No invented compile record: there was no per-project provider compile.
  check not report.hasKey("providerFingerprint")
  check not report.hasKey("providerCompileOutput")
  check not report.hasKey("providerCompileActions")
  # The real refresh record: the snapshot it persisted, and the invocation
  # count it logged.
  let snapshot = report{"providerSnapshot"}.getStr
  check snapshot.len > 0
  check snapshot == run.logValue("providerGraphSnapshot: ")
  check fileExists(snapshot)
  check $report{"providerInvocations"}.getInt ==
    run.logValue("providerInvocations: ")
  for key in ["trace", "runQuota", "stats", "targetResolution",
      "workspaceVcs", "cmakeRegenerationActions"]:
    checkpoint("report member " & key)
    check report.hasKey(key)
  check report{"trace"}.kind == JArray
  check report{"trace"}.len > 0
  # ``--no-runquota`` was passed, so the authority is the local gate.
  check report{"runQuota"}{"bypassed"}.getBool
  # No workspace-VCS query ran during this build: the report says the
  # observation is UNAVAILABLE rather than letting ``[]`` read as "observed,
  # and empty".
  check report{"workspaceVcsObserved"}.kind == JBool
  check not report{"workspaceVcsObserved"}.getBool
  check report{"targetResolutionObserved"}.getBool

proc actionStatuses(report: JsonNode): seq[(string, string)] =
  for item in report{"actions"}:
    result.add((item{"id"}.getStr, item{"status"}.getStr))

# ---------------------------------------------------------------- Tier 2b

let standardProject = createTempDir("repro-write-report-standard-", "")
writeFile(standardProject / "repro.nim", NimFixture)
writeFile(standardProject / "write_report_probe.nimble", NimbleFixture)
createDir(standardProject / "src")
writeFile(standardProject / "src" / "write_report_probe.nim", NimSourceFixture)
let standardScratch = createTempDir("repro-write-report-standard-out-", "")
# The recipe itself is compiled by a Nim the engine provisions unless told
# otherwise, and there is no provisioned Nim archive for every host
# (aarch64-macos has none). The engine's own remedy is to name the compiler;
# the fixture already requires ``nim`` on PATH for its convention, so that is
# the one named. A value the caller set is left alone.
if getEnv("REPRO_NIM_COMPILER").len == 0 and findExe("nim").len > 0:
  putEnv("REPRO_NIM_COMPILER", findExe("nim"))

proc standardUnavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if not fileExists(standardProviderBin):
    return "needs " & standardProviderBin & " beside the CLI (run `just build`)"
  if findExe("nim").len == 0:
    return "needs `nim` on PATH: the Nim convention compiles with it under " &
      "--tool-provisioning=path"
  ""

suite "repro build --write-report on the standard-direct route":

  test "--write-report=PATH writes the full report naming the prebuilt provider":
    let why = standardUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let reportPath = standardScratch / "explicit" / "report.json"
      let run = runBuild(standardProject,
        [standardProject, "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode == 0
      check "standardDirect: dispatching" in run.output
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        checkReportBody(report, "tier2b-standard-direct",
          standardProviderBin, run)
        # The artifact id the route dispatched is the namespace plus the
        # binary's content digest; the report's digest must be that one.
        check report{"providerArtifact"}.getStr ==
          "repro-standard-provider.v1." &
            report{"providerBinaryContentDigest"}.getStr
        let statuses = actionStatuses(report)
        checkpoint($statuses)
        check statuses.len > 0
        for (id, status) in statuses:
          check id.len > 0
          check status in ["asSucceeded", "asCacheHit", "asUpToDate"]
          # The report lists what the engine logged, action for action.
          check ("action: " & id & " status=" & status) in run.output
        check run.logValue("buildReport: ") == reportPath

  test "bare --write-report writes <outDir>/build-report.json":
    let why = standardUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let run = runBuild(standardProject, [standardProject, "--write-report"])
      checkpoint(explain(run))
      check run.exitCode == 0
      check "standardDirect: dispatching" in run.output
      let reportPath = run.logValue("buildReport: ")
      check reportPath.endsWith(DirSep & "build-report.json")
      check (DirSep & ".repro" & DirSep & "build" & DirSep) in reportPath
      # ``outDir`` is the directory that also holds the engine cache.
      check dirExists(reportPath.parentDir / "build-engine-cache")
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        check report{"schemaId"}.getStr == ReportSchemaId
        check report{"actions"}.len > 0

  test "--no-write-report beats --write-report and no option writes nothing":
    let why = standardUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let suppressedPath = standardScratch / "suppressed" / "report.json"
      let suppressed = runBuild(standardProject, [standardProject,
        "--write-report=" & suppressedPath, "--no-write-report"])
      checkpoint(explain(suppressed))
      check suppressed.exitCode == 0
      check "standardDirect: dispatching" in suppressed.output
      check not fileExists(suppressedPath)
      check "buildReport: " notin suppressed.output
      # The conventional path is found from a run that wrote it, then removed,
      # so its absence after an option-less run means "not written", not
      # "written somewhere else".
      let probe = runBuild(standardProject, [standardProject, "--write-report"])
      let conventional = probe.logValue("buildReport: ")
      # ``check`` + guard rather than ``require``: ``require`` ends the whole
      # program, which would hide the Tier 2a suite's verdict behind this one.
      check conventional.len > 0
      if conventional.len > 0:
        removeFile(conventional)
        let silent = runBuild(standardProject, [standardProject])
        checkpoint(explain(silent))
        check silent.exitCode == 0
        check "standardDirect: dispatching" in silent.output
        check not fileExists(conventional)
        check "buildReport: " notin silent.output

# ---------------------------------------------------------------- Tier 2a

proc writeTryCompileProject(root, command: string) =
  ## A one-action envelope. The action is INLINE (``inlineArgv``), which is
  ## how CMake's generator emits a plain command, so it needs no
  ## ``.repro-tool-profile`` sidecar. ``sh`` is resolved from PATH rather
  ## than ``/bin/sh``, because on macOS the system shell is a SIP binary the
  ## monitor cannot observe.
  let meta = TryCompileMetadata(
    actions: @[TryCompileActionDef(id: "write-report-probe",
      inline: true,
      inlineArgv: @[findExe("sh"), "-c", command],
      inlineCwd: root,
      outputs: @[root / "probe-output.txt"],
      cacheable: false)],
    targets: @[TryCompileTargetDef(name: "all",
      actionIds: @["write-report-probe"])],
    defaultTargetName: "all")
  writeFile(root / "reprobuild.nim", TryCompileModuleFixture)
  writeFile(root / "trycompile.rbsz",
    cast[string](encodeTryCompileMetadata(meta)))

let tryCompileProject = createTempDir("repro-write-report-trycompile-", "")
writeTryCompileProject(tryCompileProject,
  "printf ok > " & quoteShell(tryCompileProject / "probe-output.txt"))
let failingProject = createTempDir("repro-write-report-trycompile-fail-", "")
writeTryCompileProject(failingProject, "echo probe-failed >&2; exit 3")
let tryCompileScratch = createTempDir("repro-write-report-trycompile-out-", "")

proc tryCompileUnavailable(): string =
  if not fileExists(reproBin):
    return "needs " & reproBin & " (run `just build`)"
  if not fileExists(tryCompileProviderBin):
    return "needs " & tryCompileProviderBin &
      " beside the CLI (run `just build`)"
  if findExe("sh").len == 0:
    return "needs `sh` on PATH for the fixture's inline action"
  ""

suite "repro build --write-report on the trycompile-direct route":

  test "--write-report=PATH writes the full report naming the prebuilt provider":
    let why = tryCompileUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let reportPath = tryCompileScratch / "explicit" / "report.json"
      let run = runBuild(tryCompileProject,
        [tryCompileProject & "#all", "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode == 0
      check "trycompileDirect: dispatching" in run.output
      check fileExists(tryCompileProject / "probe-output.txt")
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        checkReportBody(report, "tier2a-trycompile-direct",
          tryCompileProviderBin, run)
        check report{"providerArtifact"}.getStr ==
          TryCompileProviderArtifactId
        # One action, succeeded, and it is the action the engine logged. Its id
        # is compared with the log rather than spelled here: a single-action
        # target is keyed under its public alias (``all``), and which name
        # wins is the lowering's business, not this test's.
        let statuses = actionStatuses(report)
        checkpoint($statuses)
        check statuses.len == 1
        for (id, status) in statuses:
          check status == "asSucceeded"
          check ("action: " & id & " status=" & status) in run.output
        check run.logValue("buildReport: ") == reportPath

  test "bare --write-report writes <outDir>/build-report.json":
    let why = tryCompileUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let run = runBuild(tryCompileProject,
        [tryCompileProject & "#all", "--write-report"])
      checkpoint(explain(run))
      check run.exitCode == 0
      check "trycompileDirect: dispatching" in run.output
      let reportPath = run.logValue("buildReport: ")
      check reportPath.endsWith(DirSep & "build-report.json")
      check dirExists(reportPath.parentDir / "build-engine-cache")
      check fileExists(reportPath)
      if fileExists(reportPath):
        check parseFile(reportPath){"schemaId"}.getStr == ReportSchemaId

  test "--no-write-report beats --write-report and no option writes nothing":
    let why = tryCompileUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let suppressedPath = tryCompileScratch / "suppressed" / "report.json"
      let suppressed = runBuild(tryCompileProject, [tryCompileProject & "#all",
        "--write-report=" & suppressedPath, "--no-write-report"])
      checkpoint(explain(suppressed))
      check suppressed.exitCode == 0
      check "trycompileDirect: dispatching" in suppressed.output
      check not fileExists(suppressedPath)
      check "buildReport: " notin suppressed.output
      let probe = runBuild(tryCompileProject,
        [tryCompileProject & "#all", "--write-report"])
      let conventional = probe.logValue("buildReport: ")
      check conventional.len > 0
      if conventional.len > 0:
        removeFile(conventional)
        let silent = runBuild(tryCompileProject, [tryCompileProject & "#all"])
        checkpoint(explain(silent))
        check silent.exitCode == 0
        check "trycompileDirect: dispatching" in silent.output
        check not fileExists(conventional)
        check "buildReport: " notin silent.output

  test "a failing build given --write-report writes both documents":
    # CLI/build.md §"Persist": a failing build given --write-report writes
    # the full report AND the failure report.
    let why = tryCompileUnavailable()
    if why.len > 0:
      skip(why)
    else:
      let reportPath = tryCompileScratch / "failing" / "report.json"
      let run = runBuild(failingProject,
        [failingProject & "#all", "--write-report=" & reportPath])
      checkpoint(explain(run))
      check run.exitCode != 0
      check "trycompileDirect: dispatching" in run.output
      check fileExists(reportPath)
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        check report{"schemaId"}.getStr == ReportSchemaId
        let statuses = actionStatuses(report)
        checkpoint($statuses)
        check statuses.len == 1
        for (id, status) in statuses:
          check status == "asFailed"
          check ("action: " & id & " status=" & status) in run.output
      let failurePath = run.logValue("buildFailureReport: ")
      check failurePath.len > 0
      check fileExists(failurePath)

for dir in [standardProject, standardScratch, tryCompileProject,
    failingProject, tryCompileScratch]:
  try:
    removeDir(dir)
  except OSError:
    discard
