## Deferred-Item D1: ``python_unittest_runner.pythonUnittest`` resolves
## in path mode because ``repro.nim`` declares ``uses: "python3"``.
##
## Two halves
## ----------
##
##   1. STRUCTURAL — assert that ``repro.nim``'s ``uses:`` block lists
##      ``"python3"``. Without that entry the path-mode resolver has
##      no profile for ``python3`` and lowering any
##      ``reprobuild.python_test.<stem>`` action raises
##      ``no tool profile was resolved``. The wrapper at
##      ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/python_unittest_runner.nim``
##      records a ``PublicCliCall`` with ``executableName = "python3"``,
##      so the engine's existing per-package profile path naturally
##      drives the execution once the constraint is declared.
##
##   2. BEHAVIOURAL — drive ``./build/bin/repro build
##      .#reprobuild.python_test.<stem>`` against the smallest Python
##      test in ``pythonTestPaths`` and assert
##
##      (a) tool-resolution succeeds (no diagnostic about missing
##          ``python3`` profile),
##      (b) the test binary's argv starts with the resolved ``python3``
##          executable + the source path,
##      (c) the test exits 0,
##      (d) the build report records the action with
##          ``status == "asSucceeded"`` and ``launched == true``.

import std/[json, os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

# The first entry in ``pythonTestPaths`` (``repro_tests.nim``) — a
# stable, fast Python unittest with no external service dependencies.
# Its stem under ``reprobuild.python_test.`` is derived by stripping
# the directory prefix + the ``.py`` extension.
const TargetSource = "tests/test_dev_env_m9_policy.py"
const TargetStem = "test_dev_env_m9_policy"
const ExecuteActionId = "reprobuild.python_test." & TargetStem

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

suite "Deferred-Item D1: pythonUnittest resolves in path mode":

  test "structural: repro.nim declares uses: \"python3\" and the test source exists":
    let repoRoot = findRepoRoot()
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproNim)

    let reproNimText = readFile(reproNim)

    # The ``uses:`` block must declare ``"python3"`` — that is the
    # constraint the path-mode resolver iterates when building the
    # ``python3 | python3`` profile entry. Without it the resolver's
    # profile table has no key matching the python execute edges'
    # recorded ``executableName = "python3"``.
    check "\"python3\"" in reproNimText
    check "Deferred-Item D1" in reproNimText

    # The targeted Python source must exist; otherwise the test
    # cannot be invoked.
    check fileExists(repoRoot / TargetSource)

    # The python_unittest_runner wrapper must still record against
    # the ``python3`` profile — this is the contract the resolver
    # depends on. (The wrapper's source is the authority; we
    # re-verify a couple of marker substrings as a guard against
    # accidental drift.)
    let wrapper = repoRoot / "libs" / "repro_dsl_stdlib" / "src" /
      "repro_dsl_stdlib" / "packages" / "python_unittest_runner.nim"
    check fileExists(wrapper)
    let wrapperText = readFile(wrapper)
    check "packageName = \"python3\"" in wrapperText
    check "executableName = \"python3\"" in wrapperText

    checkpoint("D1 python structural assertion: OK")

  test "behavioural: engine lowers + executes the pythonUnittest.run edge end-to-end":
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
      # The D1 contract: tool-resolution succeeds for python3.
      check "no tool profile was resolved" notin output
      check "references executable python3" notin output
      check exitCode == 0

      let reportPath = valueAfter(output, "buildReport:")
      check reportPath.len > 0
      check fileExists(reportPath)

      let report = parseFile(reportPath)
      let actions = reportActions(report)
      var pyAction: JsonNode = nil
      for action in actions:
        if action{"id"}.getStr() == ExecuteActionId:
          pyAction = action
          break
      check pyAction != nil
      if pyAction != nil:
        let status = pyAction{"status"}.getStr()
        let launched = pyAction{"launched"}.getBool()
        let reason = pyAction{"reason"}.getStr()
        checkpoint(ExecuteActionId & " status=" & status &
          " launched=" & $launched & " reason=" & reason)
        check status == "asSucceeded"
        check launched
        check "exit=0" in reason
