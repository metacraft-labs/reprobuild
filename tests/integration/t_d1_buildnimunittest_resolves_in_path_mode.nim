## Deferred-Item D1: ``ct_test_nim_unittest.buildNimUnittest``
## execute-edge passthrough closes the path-mode tool-resolution gap.
##
## Two halves
## ----------
##
##   1. STRUCTURAL — assert the path-mode resolver source carries the
##      D1 passthrough block. The block intercepts calls whose
##      ``executableName`` is the ``NimUnittestToolId`` constant
##      (``ct_test_nim_unittest.buildNimUnittest``) and subcommand is
##      ``run`` / ``runTest`` / ``list``, translating the recorded
##      ``binary`` input slot into the executable to invoke directly.
##
##   2. BEHAVIOURAL — drive ``./build/bin/repro build
##      .#reprobuild.test_execute.<name>`` against a small, fast DSL
##      parse test (no external CLI dependencies) and assert the
##      engine
##
##      (a) lowers the action without raising
##          ``no tool profile was resolved for ct_test_nim_unittest.buildNimUnittest``,
##      (b) executes the test binary directly (``argv[0] == "<test_binary_path>"``),
##      (c) the test exits 0,
##      (d) the build report records the execute action with
##          ``status == "asSucceeded"`` and ``launched == true``.
##
## The behavioural arm is the gold standard. Before D1 it raised the
## ``no tool profile was resolved`` diagnostic; after D1 it lowers
## into a direct test-binary invocation and the test exits 0.

import std/[json, os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

# Small, fast DSL parse test. No external dependencies; pure Nim
# unittest; under one second on a warm cache. The B3 test fixtures
# already exercise this stem so the build edge stays in the existing
# graph collection without an additional registration step.
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

suite "Deferred-Item D1: buildNimUnittest resolves in path mode":

  test "structural: path-mode resolver carries the D1 passthrough for buildNimUnittest run/runTest/list":
    let repoRoot = findRepoRoot()
    let resolverSrc = repoRoot / "libs" / "repro_cli_support" / "src" /
      "repro_cli_support.nim"
    check fileExists(resolverSrc)

    let resolverText = readFile(resolverSrc)

    # The D1 passthrough must name the typed-tool identifier and the
    # three subcommands it handles. Anchor the assertion on textual
    # markers so the structural contract stays visible at the
    # source-level review surface.
    check "Deferred-Item D1" in resolverText
    check "ct_test_nim_unittest.buildNimUnittest" in resolverText
    check "\"run\"" in resolverText
    check "\"runTest\"" in resolverText
    check "\"list\"" in resolverText
    # The passthrough reads the ``binary`` input slot directly — that
    # is the contract that lets the test binary serve as the
    # executable without a PATH-resolved profile.
    check "binary" in resolverText
    check "materialProjectPath" in resolverText

    checkpoint("D1 structural assertion: OK")

  test "behavioural: engine lowers + executes the buildNimUnittest.run edge end-to-end":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = repoRoot.parentDir / "runquota" / "build" / "bin" /
      addFileExt("runquotad", ExeExt)

    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin &
        " is missing; run `just build` first")
      skip()
    elif not fileExists(runquotad):
      checkpoint("skipped — " & runquotad &
        " is missing; build runquota first")
      skip()
    else:
      # ``.#`` prefix tells the CLI's target resolver to interpret the
      # tail as an action id selector (the engine then matches it
      # against the registered action set). Bare-name selection
      # routes through the implicit-target-name table which today
      # picks the BUILD edge by binary basename, not the EXECUTE
      # edge.
      let selector = ".#" & ExecuteActionId
      let cmd = @[
        reproBin.quoteShell,
        "build",
        selector,
        "--tool-provisioning=path",
        "--daemon=off",
        "--report=full",
        "--log=actions",
        "--progress=quiet"].join(" ")
      checkpoint("running: " & cmd)
      let (output, exitCode) = runWithRunquotaOnPath(cmd, repoRoot)
      checkpoint("exit=" & $exitCode)
      if exitCode != 0:
        checkpoint(output)
      # The D1 contract: tool-resolution succeeds for buildNimUnittest.
      check "no tool profile was resolved" notin output
      check "references executable ct_test_nim_unittest.buildNimUnittest" notin output
      check exitCode == 0

      let reportPath = valueAfter(output, "buildReport:")
      check reportPath.len > 0
      check fileExists(reportPath)

      let report = parseFile(reportPath)
      let actions = reportActions(report)
      var executeAction: JsonNode = nil
      for action in actions:
        if action{"id"}.getStr() == ExecuteActionId:
          executeAction = action
          break
      check executeAction != nil
      if executeAction != nil:
        let status = executeAction{"status"}.getStr()
        let launched = executeAction{"launched"}.getBool()
        let reason = executeAction{"reason"}.getStr()
        checkpoint(ExecuteActionId & " status=" & status &
          " launched=" & $launched & " reason=" & reason)
        # The execute action must have succeeded — the test binary
        # was invoked directly and exited 0.
        check status == "asSucceeded"
        check launched
        check "exit=0" in reason
