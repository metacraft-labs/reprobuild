## PS-6 — the fork form of ``repro branch`` carries the SOURCE workspace's
## enabled PROJECT SET into the new workspace, and ``--projects`` overrides it.
##
## The defect this pins: the fork resolved its members through the source's
## project set (so the branch pass iterated every repo of every enabled
## project) but materialized the new workspace from the PRIMARY project alone.
## On a workspace with five enabled projects that meant ~113 of 152 repos were
## cloned and the other ~39 failed the branch pass with
## ``fork-branch target is not a git working tree`` — one line per repo, with
## no indication that the cause was membership rather than git. The run then
## reported ABORTED even though the branch had been created in the repos that
## did have a checkout.
##
## Asserted:
##   1. ``t_fork_inherits_the_enabled_project_set`` — a two-project source
##      workspace forks into a workspace holding BOTH projects' repos, each on
##      the branch, with ``[workspace] projects`` recording the same set.
##   2. ``t_fork_projects_flag_replaces_the_set`` — ``--projects=alpha`` forks
##      only alpha's repos; beta's repo is absent from the new workspace (not
##      merely unbranched) and the recorded set is exactly ``["alpha"]``.
##      Falsifies "the flag extends the inherited set".
##   3. ``t_fork_refuses_an_unresolvable_project_set`` — a project name that
##      does not exist is refused (exit 2) with nothing materialized.
##
## Falsifiability: case 1 fails if the fork materializes only the primary
## project — ``lib-b`` would have no checkout, which is exactly the original
## defect. Case 2 fails if ``--projects`` is ignored or treated as additive.
##
## Real components (NO mocks): the real ``git`` binary, real bare repos, the
## engine-built ``build/bin/repro`` as a subprocess. Local bares + ``file://``
## URLs stand in for network remotes, as in every workspace integration test.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"PS-6 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "PS-6 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(fileUrl(originPath)))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc projectToml(name, remoteName, remoteUrl, includePath: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"" & name & "\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"" & remoteName & "\"\nfetch = \"" & remoteUrl &
    "\"\n\n" &
  "includes = [\n  \"" & includePath & "\",\n]\n"

proc repoToml(name, remoteName: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remoteName & "\"\n" &
  "revision = \"main\"\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    rootBare: string

proc setupFixture(gitBin, slug: string): Fixture =
  ## A source workspace with TWO enabled projects, each contributing one repo.
  ## The source is a real clone of a root workspace repo so the fork has an
  ## ``origin`` to clone the membership manifests from.
  result.scratch = createTempDir("repro-ps6-fork-" & slug & "-", "")
  result.reproBin = reproBinary()

  let libAOrigin = result.scratch / "origin-lib-a.git"
  let libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, libAOrigin, result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, libBOrigin, result.scratch / "seed-lib-b")

  result.rootBare = result.scratch / "origin-repro-workspace.git"
  seedBareWithFiles(gitBin, result.scratch, result.rootBare, [
    ("projects/alpha.toml", projectToml("alpha", "lib-a-origin",
      fileUrl(libAOrigin), "repos/lib-a.toml")),
    ("projects/beta.toml", projectToml("beta", "lib-b-origin",
      fileUrl(libBOrigin), "repos/lib-b.toml")),
    ("repos/lib-a.toml", repoToml("lib-a", "lib-a-origin")),
    ("repos/lib-b.toml", repoToml("lib-b", "lib-b-origin")),
  ])

  result.workspaceRoot = result.scratch / "source-workspace"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.rootBare)) &
    " " & q(result.workspaceRoot))
  gitConfig(gitBin, result.workspaceRoot)
  for (name, origin) in [("lib-a", libAOrigin), ("lib-b", libBOrigin)]:
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
      q(result.workspaceRoot / name))
    gitConfig(gitBin, result.workspaceRoot / name)
  # BOTH projects enabled — the state the defect mishandled.
  writeWorkspaceProjects(result.workspaceRoot, @["alpha", "beta"])
  writeWorkspaceBranch(result.workspaceRoot, project = "alpha", branch = "main")

proc invokeFork(fx: Fixture; path: string;
                extra: seq[string] = @[]): CmdResult =
  var argv = @[fx.reproBin, "branch", "--write-report", path,
               "--workspace-root=" & fx.workspaceRoot]
  for e in extra:
    argv.add(e)
  runShell(shellCommand(argv))

suite "repro branch fork carries the workspace's project set":

  test "t_fork_inherits_the_enabled_project_set":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "inherit")
      defer: removeDirEventually(fx.scratch)
      let dest = fx.scratch / "feature-both"

      let res = invokeFork(fx, dest)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # Both projects' repos exist AND are on the branch. Before the fix
      # lib-b was never cloned, so this is the assertion that pins it.
      for name in ["lib-a", "lib-b"]:
        check dirExists(dest / name / ".git")
        check currentBranch(gitBin, dest / name) == "feature-both"
      check currentBranch(gitBin, dest) == "feature-both"

      # The new workspace records the SAME set, so a later `sync`/`enable`
      # there sees the membership the fork was actually cut with.
      check readWorkspaceProjects(dest) == @["alpha", "beta"]

      let report = parseFile(dest / ".repro" / "build" / "reports" /
        "branch-report.json")
      var reported: seq[string]
      for name in report["projects"]:
        reported.add(name.getStr())
      check reported == @["alpha", "beta"]

  test "t_fork_projects_flag_replaces_the_set":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "override")
      defer: removeDirEventually(fx.scratch)
      let dest = fx.scratch / "feature-alpha"

      let res = invokeFork(fx, dest, @["--projects=alpha"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check dirExists(dest / "lib-a" / ".git")
      check currentBranch(gitBin, dest / "lib-a") == "feature-alpha"
      # REPLACED, not extended: beta contributes nothing, so its repo is
      # absent entirely rather than present-but-unbranched.
      check not dirExists(dest / "lib-b")
      check readWorkspaceProjects(dest) == @["alpha"]

      # The source keeps both projects — a fork never edits its source.
      check readWorkspaceProjects(fx.workspaceRoot) == @["alpha", "beta"]

  test "t_fork_refuses_an_unresolvable_project_set":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "unresolvable")
      defer: removeDirEventually(fx.scratch)
      let dest = fx.scratch / "feature-bogus"

      let res = invokeFork(fx, dest, @["--projects=alpha,does-not-exist"])
      checkpoint("output: " & res.output)
      check res.code == 2
      # Refused before anything was created.
      check not dirExists(dest / "lib-a")
      check not dirExists(dest / ".git")
