## Bootstrap-And-Self-Build B3: a direct test execute-edge selector builds
## the selected test binary and runs that test through the engine.
##
## The self-hosted Nim compile half is deliberately non-cacheable today:
## compiler executions may produce incomplete io-mon evidence, so the graph
## reports ``cdNotCacheable`` and runs the compile edge instead of publishing
## an unsafe cache entry. The execute edge remains the behavioral proof here:
## the engine lowers the selected ``reprobuild.test_execute.<stem>`` action,
## runs it, and records a successful result.

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
            fieldForCheckpoint(buildAction, "status") & " launched=" &
            fieldForCheckpoint(buildAction, "launched") &
            " cacheDecision=" &
            fieldForCheckpoint(buildAction, "cacheDecision"))
          check buildAction{"status"}.getStr() == "asSucceeded"
          check buildAction{"launched"}.getBool()
          check buildAction{"cacheDecision"}.getStr() == "cdNotCacheable"

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
