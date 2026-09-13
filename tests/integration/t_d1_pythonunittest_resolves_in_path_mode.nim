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
##          ``status == "asSucceeded"``, ``launched == true``, and
##          ``cacheDecision == "cdNotCacheable"``.

import std/[json, os, osproc, strtabs, strutils, unittest]
import repro_test_support

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

suite "Deferred-Item D1: pythonUnittest resolves in path mode":

  test "structural: repro.nim declares uses: \"python3\" and the test source exists":
    let repoRoot = findRepoRoot()
    let reproNim = repoRoot / "repro.nim"
    check fileExists(reproNim)

    # COMPUTED OVER CODE, NOT OVER PROSE — mode: COMMENTS BLANKED, LITERALS
    # KEPT. The needle below IS a string literal (``"python3"``, quotes
    # included), so ``nimSourceCodeOnly`` would blank exactly what is being
    # searched for and the positive assertion would pass on nothing.
    # ``nimSourceCommentsBlanked`` is the mode a literal needle requires.
    #
    # ONE READER PER MODE, never a shared one. A text that keeps literals is
    # the right reader for a literal needle and the WRONG reader for a code
    # needle, because a ``checkpoint``/``debugEcho`` argument spelling the
    # code satisfies it exactly as a comment does. The wrapper scan below is
    # therefore split in two rather than sharing this one.
    #
    # MEASURED (DA-8): the ``"python3"`` entry was deleted from the ``uses:``
    # block of ``repro.nim`` and this case stayed GREEN, because the twelve
    # lines of ``#`` comment that INTRODUCE that entry themselves write
    # ``executableName = "python3"`` and the words ``Deferred-Item D1``. The
    # audit was reading its own rationale.
    let reproNimLiterals = nimSourceCommentsBlanked(readFile(reproNim))

    # The ``uses:`` block must declare ``"python3"`` — that is the
    # constraint the path-mode resolver iterates when building the
    # ``python3 | python3`` profile entry. Without it the resolver's
    # profile table has no key matching the python execute edges'
    # recorded ``executableName = "python3"``.
    #
    # Graded as a whole LINE inside the ``uses:`` block rather than as a
    # substring anywhere in the file: ``"python3"`` also occurs as an
    # argument to unrelated calls, so a bare ``in`` would survive the entry's
    # deletion on the strength of one of those.
    var sawPython3Use = false
    for line in reproNimLiterals.splitLines():
      if line.strip() == "\"python3\"":
        sawPython3Use = true
    check sawPython3Use

    # DELIBERATELY OVER RAW TEXT, and not part of the soundness argument
    # above. This one grades the feature TAG the implementation comments
    # carry, which only exists in prose — blanking comments would delete its
    # subject. Keep it separate from the code assertions so it is never
    # mistaken for one.
    check "Deferred-Item D1" in readFile(reproNim)

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
    # TWO READERS, ONE PER MODE, because this scan's three needles are not
    # all the same kind of thing. The wrapper is a live instance of the
    # hazard in both directions: its own doc comment explains that the edge
    # is "non-cacheable by default", one rewording away from spelling the
    # needle.
    #
    #   * ``packageName = "python3"`` / ``executableName = "python3"`` carry
    #     a string LITERAL. Code-only text blanks it, so those two must read
    #     the literal-keeping text.
    #   * ``cacheable = false`` is pure CODE — an assignment of a keyword,
    #     never quoted. Over literal-keeping text it is satisfied by any
    #     string that happens to spell it.
    #
    # MEASURED (DA-8, review bypass): with the single shared
    # comments-blanked reader this file used to have, flipping the wrapper's
    # real default to ``cacheable = true`` and adding
    # ``debugEcho "…default policy was cacheable = false"`` left the case
    # ``[OK]``. The literal was doing the work. Over ``wrapperCode`` that
    # same bypass reddens, because ``nimSourceCodeOnly`` blanks the
    # ``debugEcho`` argument along with the comments.
    let wrapperLiterals = nimSourceCommentsBlanked(readFile(wrapper))
    let wrapperCode = nimSourceCodeOnly(readFile(wrapper))
    check "packageName = \"python3\"" in wrapperLiterals
    check "executableName = \"python3\"" in wrapperLiterals
    check "cacheable = false" in wrapperCode

    checkpoint("D1 python structural assertion: OK")

  test "behavioural: engine lowers + executes the pythonUnittest.run edge end-to-end":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" /
      addFileExt("repro", ExeExt)
    let runquotad = requireRunQuotaDaemonBin(repoRoot)

    check fileExists(reproBin)
    check fileExists(runquotad)
    if fileExists(reproBin) and fileExists(runquotad):
      let selector = ".#" & ExecuteActionId
      let cmd = @[
        reproBin.quoteShell,
        "build",
        selector,
        "--tool-provisioning=path",
        "--daemon=off",
        "--write-report",
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
        let cache = pyAction{"cacheDecision"}.getStr()
        let reason = pyAction{"reason"}.getStr()
        checkpoint(ExecuteActionId & " status=" & status &
          " launched=" & $launched & " cacheDecision=" & cache &
          " reason=" & reason)
        check status == "asSucceeded"
        check launched
        check cache == "cdNotCacheable"
        check "exit=0" in reason
