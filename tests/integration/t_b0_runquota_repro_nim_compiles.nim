## Bootstrap-And-Self-Build B0: structural verifier for runquota's
## ``repro.nim``.
##
## Asserts:
##   1. ``../runquota/repro.nim`` exists and ``nim check`` succeeds
##      against it with the same ``--path:`` flags the reprobuild
##      ``config.nims`` adds (``libs/repro_project_dsl/src`` plus the
##      ct-test sibling). This proves the file parses cleanly under
##      the live project DSL macros.
##   2. The file declares the expected ``package`` / ``executable`` /
##      ``library`` shape — substrings ``package runquota:``,
##      ``executable runquota:``, ``executable runquotad:``, and
##      ``library runquota`` must be present. The substring check is
##      intentionally syntactic so a future macro change that breaks
##      one of the declarations is caught even if ``nim check``
##      papers over it.
##
## Skip-when-absent: if ``../runquota/`` does not exist next to the
## reprobuild checkout, the test reports a clear skip rather than a
## hard failure. CI environments that don't lay out the sibling are
## still considered passing for this milestone.

import std/[os, osproc, strtabs, strutils, unittest]

const RepoMarker = "repro.nim"

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

proc runquotaRepoPath(reprobuildRoot: string): string =
  reprobuildRoot.parentDir / "runquota"

proc nimCheckPathFlags(reprobuildRoot: string): seq[string] =
  ## Mirror the import paths that the runquota ``repro.nim`` needs to
  ## resolve: ``repro_project_dsl`` + ``repro_dsl_stdlib`` live under
  ## the reprobuild repo; ``ct_test_*`` adapters live in the
  ## ``ct-test`` sibling.
  result = @[]
  for lib in [
    "repro_project_dsl",
    "repro_dsl_stdlib",
  ]:
    let candidate = reprobuildRoot / "libs" / lib / "src"
    if dirExists(candidate):
      result.add("--path:" & candidate)
  let ctTestRoot = block:
    let fromEnv = getEnv("CT_TEST_SRC")
    if fromEnv.len > 0:
      fromEnv
    else:
      reprobuildRoot.parentDir / "ct-test"
  for ctLib in [
    "ct_test_interface",
    "ct_test_nim_unittest",
  ]:
    let candidate = ctTestRoot / "libs" / ctLib / "src"
    if dirExists(candidate):
      result.add("--path:" & candidate)

suite "Bootstrap-And-Self-Build B0: runquota repro.nim compiles":

  test "../runquota/repro.nim declares the expected shape":
    let reprobuildRoot = findRepoRoot()
    let runquotaRoot = runquotaRepoPath(reprobuildRoot)
    let runquotaRepro = runquotaRoot / "repro.nim"
    if not fileExists(runquotaRepro):
      checkpoint("skipped — " & runquotaRepro &
        " is missing (sibling runquota repo not present)")
      skip()
    else:
      let content = readFile(runquotaRepro)
      check "package runquota:" in content
      check "executable runquota:" in content
      check "executable runquotad:" in content
      check "library runquota" in content
      # Sanity-check the wrapper-script build action shape we expect
      # B0 to land. A typo here would silently pass ``nim check`` but
      # break the engine's build edge so we catch it structurally.
      check "scripts/build_apps.sh" in content
      check "build/bin/runquotad" in content

  test "nim check succeeds on ../runquota/repro.nim":
    let reprobuildRoot = findRepoRoot()
    let runquotaRoot = runquotaRepoPath(reprobuildRoot)
    let runquotaRepro = runquotaRoot / "repro.nim"
    if not fileExists(runquotaRepro):
      checkpoint("skipped — " & runquotaRepro &
        " is missing (sibling runquota repo not present)")
      skip()
    else:
      var parts = @["nim", "check", "--hints:off", "--warnings:off"]
      parts.add(nimCheckPathFlags(reprobuildRoot))
      parts.add(runquotaRepro.quoteShell)
      let cmd = parts.join(" ")
      checkpoint("running: " & cmd)
      # The runquota ``config.nims`` consults REPROBUILD_SRC to expose
      # the reprobuild project-DSL libs (and the transitive deps the
      # ``package`` macro expansion reaches into) on its
      # ``--path:`` list. The block is opt-in (no implicit
      # ``../reprobuild/`` fallback) so the regular runquota build
      # stays hermetic to its own ``libs/`` tree; we pass the env
      # explicitly here so ``nim check`` sees the full transitive
      # set.
      var env = newStringTable()
      for k, v in envPairs():
        env[k] = v
      env["REPROBUILD_SRC"] = reprobuildRoot
      let (output, exitCode) =
        execCmdEx(cmd, env = env)
      if exitCode != 0:
        checkpoint(output)
      check exitCode == 0
