## Bootstrap-And-Self-Build B3: a direct test execute-edge selector builds
## the selected test binary and runs that test through the engine.
##
## The compile half is CACHEABLE, and the report must say so. This header used
## to claim the opposite — "the self-hosted Nim compile half is deliberately
## non-cacheable today ... so the graph reports ``cdNotCacheable``" — and the
## engine arm asserted that decision. Both were superseded on 2026-08-19, when
## the ``cacheable = false`` retreat was reversed for every compile edge in
## ``repro.nim``; see the HISTORY note there and
## ``reprobuild-specs/Compiles-Are-Normal-Edges.md``, which records that the
## blocker (raw ``SYS_getrandom`` graded as a Level-2 evidence loss) was "a
## classification gap, not a monitoring one" and that monitored pipelines now
## publish and hit the cache. ``buildNimUnittest.build`` defaults
## ``cacheable = true`` and ``repro.nim`` passes no override, so
## ``cdNotCacheable`` is unreachable for this edge by construction.
##
## What the engine arm asserts instead is what the surrounding assertions
## already imply: the test-build edge SUCCEEDED and LAUNCHED, and a monitored,
## cacheable edge that launches on a cold cache is a cache MISS. The run is
## scoped to this case's own ``--action-cache-root``, so "cold" is a property
## of the case rather than of where it happens to fall in the suite's order.
## The execute edge remains the behavioral proof: the engine lowers the
## selected ``reprobuild.test_execute.<stem>`` action, runs it, and records a
## successful result.

import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]
import repro_test_support

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
  # The graph-built test binary must carry its own Darwin runtime linkage.
  # Do not let the parent shell or the outer test runner hide a missing
  # LC_RPATH on the nested execute edge.
  env.del("DYLD_LIBRARY_PATH")
  env.del("DYLD_FALLBACK_LIBRARY_PATH")
  execCmdEx(cmd, env = env, workingDir = repoRoot)

when defined(macosx):
  proc resolvedClingoLibDirs(): seq[string] =
    ## Resolve the same non-hardcoded Clingo directories the project graph
    ## consumes. Nix exposes the package through either the dedicated variable
    ## or a -L token; the test must follow that declaration rather than name a
    ## store hash of its own.
    let explicit = getEnv("CLINGO_LIB")
    if explicit.len > 0 and fileExists(explicit / "libclingo.dylib"):
      result.add(explicit)
    for token in getEnv("NIX_LDFLAGS").splitWhitespace:
      if token.startsWith("-L") and token.len > 2:
        let libDir = token[2 .. ^1]
        if fileExists(libDir / "libclingo.dylib") and libDir notin result:
          result.add(libDir)

  proc machoRpaths(binary: string): tuple[paths: seq[string]; output: string;
      exitCode: int] =
    let inspected = execCmdEx("/usr/bin/otool -l " & binary.quoteShell)
    result.output = inspected.output
    result.exitCode = inspected.exitCode
    var expectRpath = false
    for line in inspected.output.splitLines:
      let fields = line.strip().splitWhitespace()
      if fields == @["cmd", "LC_RPATH"]:
        expectRpath = true
      elif expectRpath and fields.len >= 2 and fields[0] == "path":
        result.paths.add(fields[1])
        expectRpath = false

  proc runWithoutDarwinLoaderOverrides(binary, workingDir: string):
      tuple[output: string; exitCode: int] =
    var env = newStringTable()
    for key, value in envPairs():
      env[key] = value
    env.del("DYLD_LIBRARY_PATH")
    env.del("DYLD_FALLBACK_LIBRARY_PATH")
    execCmdEx(binary.quoteShell, env = env, workingDir = workingDir)

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

proc runBuildTarget(reproBin, repoRoot, selector, cacheRoot,
                    reportPath: string): tuple[output: string; exitCode: int] =
  ## THE REPORT NEEDED THE SAME SCOPING THE CACHE ROOT GOT. A bare
  ## ``--write-report`` lands on ``<outDir>/build-report.json``, and ``outDir``
  ## collapses to ONE directory for every selector this suite drives:
  ## ``outputDirForTarget`` (``libs/repro_cli_support/src/
  ## repro_cli_support.nim:1103``) takes ``outputName`` from
  ## ``resolveProjectFile(".")`` = ``splitFile("repro.nim").name`` = ``repro``
  ## (same file, 726-729), and ``scripts/run_tests.sh`` sets no
  ## ``REPROBUILD_WORK_ROOT``. The private cache root below stopped this case
  ## and ``t_d1_buildnimunittest_resolves_in_path_mode`` deciding each other's
  ## CACHE outcome; it never stopped either reading the other's REPORT.
  let args = @[
    reproBin.quoteShell,
    "build",
    selector,
    "--tool-provisioning=path",
    "--daemon=off",
    "--action-cache-root=" & cacheRoot.quoteShell,
    "--write-report=" & reportPath.quoteShell,
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

    # This used to be a bare ``check "cacheable = false" in reproNimText``,
    # written when every compile edge in the file carried that argument. Since
    # 2026-08-19 they do not, and the only survivors are the Windows DLL-copy
    # edges and the opt-in-layer ``.live`` execute variant — lines with nothing
    # to do with this case, which made the assertion pass while saying nothing.
    # Assert the contract the engine arm below reads from the build report:
    # the test-build edge passes NO ``cacheable`` argument, so it takes
    # ``buildNimUnittest``'s ``cacheable = true`` default.
    let buildCallStart = reproNimText.find("let edge = buildNimUnittest.build(")
    check buildCallStart >= 0
    if buildCallStart >= 0:
      let buildCallEnd = reproNimText.find(
        "reprobuildTestBuildActions.add(edge.action)", buildCallStart)
      check buildCallEnd > buildCallStart
      if buildCallEnd > buildCallStart:
        check "cacheable" notin reproNimText[buildCallStart ..< buildCallEnd]

    # Both dlopen-only runtimes belong on graph-built test binaries. Keep the
    # Clingo names in the shared test-runtime list (not only the shipping repro
    # list), and retain the POSIX gate so Windows still emits no Unix rpaths.
    let testRuntimeStart = reproNimText.find("let testRuntimePassL")
    let testRuntimeEnd = reproNimText.find("proc findNixStoreSourceDir",
                                           testRuntimeStart)
    check testRuntimeStart >= 0
    check testRuntimeEnd > testRuntimeStart
    if testRuntimeStart >= 0 and testRuntimeEnd > testRuntimeStart:
      let testRuntimeBlock = reproNimText[testRuntimeStart ..< testRuntimeEnd]
      check "\"libclingo.so\"" in testRuntimeBlock
      check "\"libclingo.dylib\"" in testRuntimeBlock
      check "\"libzstd.so.1\"" in testRuntimeBlock
      check "\"libzstd.dylib\"" in testRuntimeBlock
    let runtimeResolverStart = reproNimText.find(
      "proc nixRuntimePassLForLibraries")
    check runtimeResolverStart >= 0
    if runtimeResolverStart >= 0 and testRuntimeStart > runtimeResolverStart:
      let resolverBlock = reproNimText[runtimeResolverStart ..< testRuntimeStart]
      check "when defined(posix):" in resolverBlock
      check "when defined(macosx):" in resolverBlock
      check "else:" in resolverBlock
      check "@[]" in resolverBlock

  test "engine: direct execute-edge selector runs the selected test":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = requireRunQuotaDaemonBin(repoRoot)

    check fileExists(reproBin)
    check fileExists(runquotad)

    if fileExists(reproBin) and fileExists(runquotad):
      # TEST ISOLATION. This case asserts a COLD execution of
      # ``reprobuild.test_execute.t_dsl_outputs_statement_basic_accepted``, and
      # so does ``t_d1_buildnimunittest_resolves_in_path_mode`` — the same
      # action id, from a second binary, in the same suite. With both sharing
      # the run-wide ``REPROBUILD_ACTION_CACHE_ROOT`` that
      # ``scripts/run_tests.sh`` exports, whichever ran first warmed the other:
      # measured, ``t_d1`` first passes 2/2 cold and this case then reads
      # ``status=asUpToDate launched=false cacheDecision=cdHit
      # reason=no-declared-outputs``. Neither test is wrong about what it
      # asserts; they were simply not scoped. A private cache root per case is
      # the remedy already used by
      # ``t_local_daemons_control_plane_m11``/``buildCommand``.
      let cacheRoot = createTempDir("repro-b3-execute-cache-", "")
      defer: removeDir(cacheRoot)
      let reportDir = createTempDir("repro-b3-execute-report-", "")
      defer: removeDir(reportDir)
      let reportPath = reportDir / "build-report.json"
      let selector = ".#" & ExecuteActionId
      let (output, exitCode) = runBuildTarget(reproBin, repoRoot, selector,
                                              cacheRoot, reportPath)
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
            fieldForCheckpoint(buildAction, "status") & " launched=" &
            fieldForCheckpoint(buildAction, "launched") &
            " cacheDecision=" &
            fieldForCheckpoint(buildAction, "cacheDecision"))
          check buildAction{"status"}.getStr() == "asSucceeded"
          check buildAction{"launched"}.getBool()
          check buildAction{"cacheDecision"}.getStr() == "cdMiss"

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

      when defined(macosx):
        # The nested execute above already ran with both DYLD overrides
        # absent. Inspect the exact graph output and prove its LC_RPATH comes
        # from the resolved Clingo package rather than a hardcoded store path.
        let targetBinary = repoRoot / "build" / "test-bin" / TargetTest
        let expectedClingoDirs = resolvedClingoLibDirs()
        check expectedClingoDirs.len > 0
        let loadCommands = machoRpaths(targetBinary)
        checkpoint(loadCommands.output)
        check loadCommands.exitCode == 0
        for libDir in expectedClingoDirs:
          check libDir in loadCommands.paths

        var clingoRpaths: seq[string] = @[]
        for rpath in loadCommands.paths:
          if fileExists(rpath / "libclingo.dylib"):
            clingoRpaths.add(rpath)
        check clingoRpaths.len > 0

        # RED mutation: delete every Clingo LC_RPATH from a private copy while
        # preserving the @rpath loader name. With no ambient DYLD fallback the
        # copy must fail before Nim main; this proves the positive execute-edge
        # result depends on the declarative link fix itself.
        let mutationRoot = createTempDir("repro-b3-clingo-rpath-", "")
        defer: removeDir(mutationRoot)
        let mutatedBinary = mutationRoot / TargetTest
        copyFile(targetBinary, mutatedBinary)
        setFilePermissions(mutatedBinary, getFilePermissions(targetBinary))
        for rpath in clingoRpaths:
          let removed = execCmdEx(
            "/usr/bin/install_name_tool -delete_rpath " & rpath.quoteShell &
            " " & mutatedBinary.quoteShell)
          checkpoint(removed.output)
          check removed.exitCode == 0
        let mutatedCommands = machoRpaths(mutatedBinary)
        check mutatedCommands.exitCode == 0
        for rpath in mutatedCommands.paths:
          check not fileExists(rpath / "libclingo.dylib")
        let loaderStrings = execCmdEx(
          "/usr/bin/strings " & mutatedBinary.quoteShell)
        check loaderStrings.exitCode == 0
        check "@rpath/libclingo.dylib" in loaderStrings.output

        let rejected = runWithoutDarwinLoaderOverrides(mutatedBinary,
                                                        mutationRoot)
        checkpoint(rejected.output)
        check rejected.exitCode != 0
        check "could not load: @rpath/libclingo.dylib" in rejected.output
