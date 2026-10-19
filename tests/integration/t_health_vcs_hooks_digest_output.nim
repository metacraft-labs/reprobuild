## Verification for issue reprobuild-pm/issues/2026-09-20-health-vcs-hooks-output-unreadable.md
##
## With many missing hooks (> 5):
##   - In text mode (default), the `vcs-hooks` line must be a digest showing
##     the count, up to 5 examples, and `(+N more)`. It must not contain all
##     entries on one line.
##   - In verbose mode (`--verbose` or `-v`), the text output contains the full list.
##   - In `--json` mode, the `detail` field contains the full list of all missing hooks.

import std/[json, os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip
import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "multi-repo"
default_revision = "main"
trunk = "main"

[[remote]]
name = "origin-a"
fetch = "ORIGIN_A_URL"

[[remote]]
name = "origin-b"
fetch = "ORIGIN_B_URL"

includes = [
  "repos/lib-a.toml",
  "repos/lib-b.toml",
]
"""

const libAToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "origin-a"
revision = "main"
"""

const libBToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "origin-b"
revision = "main"
"""

proc seedOrigin(gitBin, originPath, seedPath, name: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " config user.name \"Digest Tester\"")
  writeFile(seedPath / "README.md", name & " fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " remote add origin " &
    q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")

type
  Fixture = object
    scratch: string
    workspaceRoot: string
    reproBin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-health-digest-" & slug & "-", "")
  result.reproBin = reproBinary()

  let originA = result.scratch / "origin-lib-a.git"
  let originB = result.scratch / "origin-lib-b.git"
  seedOrigin(gitBin, originA, result.scratch / "seed-lib-a", "lib-a")
  seedOrigin(gitBin, originB, result.scratch / "seed-lib-b", "lib-b")

  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  createDir(result.workspaceRoot / ".repro")
  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")

  writeFile(result.workspaceRoot / "projects" / "multi-repo.toml",
    projectToml.replace("ORIGIN_A_URL", fileUrl(originA))
               .replace("ORIGIN_B_URL", fileUrl(originB)))
  writeFile(result.workspaceRoot / "repos" / "lib-a.toml", libAToml)
  writeFile(result.workspaceRoot / "repos" / "lib-b.toml", libBToml)

  let repoAPath = result.workspaceRoot / "lib-a"
  let repoBPath = result.workspaceRoot / "lib-b"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originA)) & " " &
    q(repoAPath))
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originB)) & " " &
    q(repoBPath))

proc findVcsHooksLine(output: string): string =
  for line in output.splitLines():
    if line.strip().startsWith("vcs-hooks"):
      return line
  ""

proc findCheck(report: JsonNode; name: string): JsonNode =
  for entry in report["checks"]:
    if entry["name"].getStr() == name:
      return entry
  nil

suite "health vcs-hooks digest output for large lists":

  test "digest in text mode, full list in verbose and json modes":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git not on PATH")
    else:
      let fx = setupFixture(gitBin, "missing-hooks")
      defer: removeDir(fx.scratch)

      # 1. Default text mode: should print a digest showing count, up to 5 examples,
      # and (+N more), not all 10 entries on one line.
      let textRes = runShell(shellCommand(
        @[fx.reproBin, "health", "multi-repo",
          "--workspace-root=" & fx.workspaceRoot],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("health text output:\n" & textRes.output)

      let line = findVcsHooksLine(textRes.output)
      check line.len > 0
      check "10 managed hook(s) missing across 2 participating repo(s)" in line
      check "lib-a/pre-commit" in line
      check "lib-a/pre-push" in line
      check "lib-a/post-commit" in line
      check "lib-a/post-merge" in line
      check "lib-a/post-checkout" in line
      check "(+5 more)" in line
      # The 6th..10th hooks belong to lib-b and must not be on this single digested line
      check "lib-b/post-checkout" notin line

      # 2. Verbose mode (--verbose): should print the full list without (+N more)
      let verboseRes = runShell(shellCommand(
        @[fx.reproBin, "health", "multi-repo", "--verbose",
          "--workspace-root=" & fx.workspaceRoot],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("health --verbose output:\n" & verboseRes.output)

      let verboseLine = findVcsHooksLine(verboseRes.output)
      check verboseLine.len > 0
      check "10 managed hook(s) missing across 2 participating repo(s)" in verboseLine
      check "(+5 more)" notin verboseLine
      check "lib-a/pre-commit" in verboseLine
      check "lib-b/post-checkout" in verboseLine
      check "lib-b/pre-commit" in verboseLine

      # 3. Short verbose flag (-v): should behave identically to --verbose
      let shortVerboseRes = runShell(shellCommand(
        @[fx.reproBin, "health", "multi-repo", "-v",
          "--workspace-root=" & fx.workspaceRoot],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("health -v output:\n" & shortVerboseRes.output)

      let shortVerboseLine = findVcsHooksLine(shortVerboseRes.output)
      check shortVerboseLine.len > 0
      check "(+5 more)" notin shortVerboseLine
      check "lib-b/post-checkout" in shortVerboseLine

      # 4. JSON mode (--json): detail field should contain the full list
      let jsonRes = runShell(shellCommand(
        @[fx.reproBin, "health", "multi-repo", "--json",
          "--workspace-root=" & fx.workspaceRoot],
        @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
      checkpoint("health --json output:\n" & jsonRes.output)

      let report = parseJson(jsonRes.output)
      let row = findCheck(report, "vcs-hooks")
      check not row.isNil
      check row["status"].getStr() == "fail"
      let detail = row["detail"].getStr()
      check "10 managed hook(s) missing across 2 participating repo(s)" in detail
      check "(+5 more)" notin detail
      check "lib-a/pre-commit" in detail
      check "lib-b/post-checkout" in detail
