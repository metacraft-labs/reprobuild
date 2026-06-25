## RA-29 — ``repro checkout`` per-repo stash-on-leave + restore-on-return.
##
## CLI/checkout.md's V1 surface "requires a clean workspace — commit,
## stash, or discard changes first". RA-29 makes the *stash* path automatic
## and COHERENT across the workspace: leaving a branch with uncommitted work
## in some repos stashes each dirty repo's WIP (keyed by the branch being
## left); returning to that branch RESTORES it. WIP is never lost on a
## task-switch (Workspace-And-Develop-Mode.md — switching tasks is the
## steady-state loop).
##
## Scenario (two repos, each with its OWN independent WIP):
##   - Workspace on branch ``main``; ``feature`` exists locally in every
##     repo. lib-a and lib-b each get a distinct uncommitted edit.
##   - ``repro checkout feature`` → both repos switch; each dirty repo's WIP
##     is stashed (working tree clean on ``feature``; the WIP files are gone).
##   - ``repro checkout main`` (return) → each repo's branch-keyed stash is
##     popped; the EXACT uncommitted content reappears in each repo.
##
## Assertions:
##   - After leaving ``main``: both repos are on ``feature`` AND their WIP
##     files are absent (stashed, not carried across). The report marks each
##     dirty repo ``stashedOnLeave``.
##   - After returning to ``main``: both repos are back on ``main`` AND each
##     repo's WIP file is back with its EXACT original content (independent
##     per repo). The report marks each restored repo ``restoredOnReturn``.
##
## Falsifiable: with no stash-on-leave the dirty switch would refuse (or
## carry the WIP across); with no restore-on-return the WIP would never
## reappear on the return checkout. Either regression fails the content
## round-trip assertions.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no
## network. Skip rule: ``git`` missing on PATH.

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA29 Tester\"")
  writeFile(workPath / "README.md", "RA29 stash fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA29 Tester\"")

proc createLocalBranchAtHead(gitBin, repoPath, branchName: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " branch " & branchName)

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0:
    return ""
  res.output.strip()

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra29-stash-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.libAOrigin, result.scratch / "seed-a")
  discard seedGitOrigin(gitBin, result.libBOrigin, result.scratch / "seed-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith2Remotes(
      fileUrl(result.libAOrigin), fileUrl(result.libBOrigin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeCheckout(fx: Fixture; name: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "checkout", name, "--yes",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "checkout-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntryByName(report: JsonNode; name: string): JsonNode =
  for entry in report["repos"]:
    if entry["name"].getStr() == name:
      return entry
  newJNull()

suite "RA-29 — checkout stashes and restores per-repo WIP":

  test "t_checkout_stashes_and_restores_per_repo_wip":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "roundtrip")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libAOrigin, fx.workspaceRoot / "lib-a")
      cloneInto(gitBin, fx.libBOrigin, fx.workspaceRoot / "lib-b")
      writeWorkspaceBranch(fx.workspaceRoot, project = "lib-a",
        branch = "main")

      # ``feature`` exists locally in both repos so the switch has a target.
      for name in ["lib-a", "lib-b"]:
        createLocalBranchAtHead(gitBin, fx.workspaceRoot / name, "feature")

      # Distinct uncommitted WIP per repo (independent content).
      let aWipPath = fx.workspaceRoot / "lib-a" / "wip-a.txt"
      let bWipPath = fx.workspaceRoot / "lib-b" / "wip-b.txt"
      let aWip = "lib-a work in progress :: alpha\n"
      let bWip = "lib-b work in progress :: bravo\n"
      writeFile(aWipPath, aWip)
      writeFile(bWipPath, bWip)

      # ---- Leave ``main``: stash both repos' WIP, switch to feature ------
      let leave = invokeCheckout(fx, "feature")
      if leave.code != 0:
        checkpoint("leave output: " & leave.output)
      check leave.code == 0

      let leaveReport = readReport(fx)
      check leaveReport["exitCode"].getInt() == 0
      check leaveReport["recordedBranch"].getStr() == "feature"

      let leaveA = repoEntryByName(leaveReport, "lib-a")
      let leaveB = repoEntryByName(leaveReport, "lib-b")
      check leaveA["outcome"].getStr() == "switched"
      check leaveB["outcome"].getStr() == "switched"
      # Each dirty repo was stashed-on-leave, independently.
      check leaveA["stashedOnLeave"].getBool() == true
      check leaveB["stashedOnLeave"].getBool() == true

      # On ``feature`` the trees are CLEAN — the WIP was stashed away, not
      # carried across the switch. (Falsifiable: no-stash → either the
      # switch refuses, or the WIP file is still present here.)
      for name in ["lib-a", "lib-b"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "feature"
      check not fileExists(aWipPath)
      check not fileExists(bWipPath)

      # ---- Return to ``main``: restore each repo's branch-keyed WIP ------
      let back = invokeCheckout(fx, "main")
      if back.code != 0:
        checkpoint("return output: " & back.output)
      check back.code == 0

      let backReport = readReport(fx)
      check backReport["exitCode"].getInt() == 0
      check backReport["recordedBranch"].getStr() == "main"

      let backA = repoEntryByName(backReport, "lib-a")
      let backB = repoEntryByName(backReport, "lib-b")
      check backA["outcome"].getStr() == "switched"
      check backB["outcome"].getStr() == "switched"
      # Each repo's stash was restored on return.
      check backA["restoredOnReturn"].getBool() == true
      check backB["restoredOnReturn"].getBool() == true

      # Both repos are back on ``main`` and the EXACT WIP content
      # round-tripped — independently per repo.
      for name in ["lib-a", "lib-b"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "main"
      check fileExists(aWipPath)
      check fileExists(bWipPath)
      check readFile(aWipPath) == aWip
      check readFile(bWipPath) == bWip
      # The repos did not cross-contaminate (lib-a's WIP only in lib-a).
      check not fileExists(fx.workspaceRoot / "lib-a" / "wip-b.txt")
      check not fileExists(fx.workspaceRoot / "lib-b" / "wip-a.txt")
