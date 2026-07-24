## Regression: a relative ``--results-dir`` must not make the runner's
## hermetic GIT_CONFIG_GLOBAL relative to a child test's ``git -C`` target.
##
## Before the fix, the runner exported ``results/hermetic-gitconfig``. Git
## resolves a relative GIT_CONFIG_GLOBAL after applying ``-C``, so a test that
## operated on a temporary repository silently lost the runner's identity and
## signing policy. The real-hooks integration tests then inherited host Git
## behavior or failed commits. This fixture asks Git for the exact identity
## from a directory other than the runner cwd and therefore fails on the old
## runner without weakening any Git-facing test.

import std/[json, os, osproc, strutils, tempfiles, unittest]

proc repoRoot(): string =
  var candidate = currentSourcePath().parentDir
  while candidate.parentDir != candidate:
    if fileExists(candidate / "repro.nim") and
        fileExists(candidate / "repro_tests.nim"):
      return candidate
    candidate = candidate.parentDir
  raise newException(IOError, "cannot find reprobuild repository root")

suite "repro test runner uses an absolute hermetic Git config path":
  test "relative results dir survives git -C in an opaque child":
    when defined(windows):
      skip()
    else:
      if findExe("git").len == 0:
        skip()
      else:
        let root = repoRoot()
        let runner = root / "build" / "bin" / "repro_test_runner"
        require fileExists(runner)

        let scratch = createTempDir("runner-git-config-", "")
        defer: removeDir(scratch)
        let binDir = scratch / "bin"
        let gitTarget = scratch / "git-target"
        createDir(binDir)
        createDir(gitTarget)

        let fixture = binDir / "test_git_config_from_other_cwd"
        writeFile(fixture,
          "#!/bin/sh\n" &
          "set -eu\n" &
          "test \"$(git -C \"$REPRO_GIT_FIXTURE_TARGET\" config --global user.name)\" = \"Reprobuild Test\"\n" &
          "test \"$(git -C \"$REPRO_GIT_FIXTURE_TARGET\" config --global commit.gpgsign)\" = \"false\"\n")
        setFilePermissions(fixture, {fpUserRead, fpUserWrite, fpUserExec})

        let previousTarget = getEnv("REPRO_GIT_FIXTURE_TARGET")
        let hadTarget = existsEnv("REPRO_GIT_FIXTURE_TARGET")
        putEnv("REPRO_GIT_FIXTURE_TARGET", gitTarget)
        defer:
          if hadTarget:
            putEnv("REPRO_GIT_FIXTURE_TARGET", previousTarget)
          else:
            delEnv("REPRO_GIT_FIXTURE_TARGET")

        let summary = scratch / "summary.json"
        let command = quoteShell(runner) &
          " --no-build --threads=1 --quiet" &
          " --bin-dir=" & quoteShell(binDir) &
          " --summary-json=" & quoteShell(summary) &
          " --results-dir=results"
        let execution = execCmdEx(command, workingDir = scratch)
        if execution.exitCode != 0:
          checkpoint(execution.output)
        check execution.exitCode == 0
        check fileExists(scratch / "results" / "hermetic-gitconfig")
        require fileExists(summary)
        let report = parseFile(summary)
        check report{"summary"}{"total"}.getInt(-1) == 1
        check report{"summary"}{"passed"}.getInt(-1) == 1
        check report{"summary"}{"failed"}.getInt(-1) == 0
