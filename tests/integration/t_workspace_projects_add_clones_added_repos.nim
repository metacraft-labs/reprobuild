## PS-3 — ``repro workspace projects add <p>`` MATERIALIZES what it records.
##
## The command this replaces (``workspace projects add`` from
## ``repo-workspaces``) layered the project's manifest AND checked its repos
## out. Recording membership without working trees leaves the workspace in a
## state no other command can act on, so recording and materializing are one
## operation (CLI/workspace.md §``repro workspace projects``).
##
## Fixture (hermetic, local ``git init --bare`` upstreams): projects ``alpha``
## (repo ``alpha-only``) and ``beta`` (repo ``beta-only``); the workspace
## starts with the active set ``[alpha]`` and ``alpha-only`` checked out.
##
## Asserted:
##   1. ``projects add beta`` records ``[alpha, beta]`` AND clones
##      ``beta-only`` into the workspace.
##   2. ``projects add beta --no-sync`` records membership only — the repo is
##      NOT on disk afterwards (the scripted-bootstrap / offline escape
##      hatch).
##   3. Re-running ``projects add beta`` on that same workspace is the REPAIR
##      path: membership is already correct and idempotent, and the missing
##      checkout is created.
##
## Falsifiability (confirmed by hand, then reverted): removing the
## materialization call from ``runWorkspaceProjectsCommand`` leaves
## ``beta-only`` absent in assertions 1 and 3 — which is exactly the bug this
## milestone fixes.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string): string =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.exitCode &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string) =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"PS Tester\"")
  writeFile(workPath / "README.md", "projects-add fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

proc remoteBlock(name, url: string): string =
  "[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url & "\"\n\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

proc projectFile(name, remotes, include1: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\nname = \"" & name & "\"\ndefault_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" & remotes &
  "includes = [\n  \"" & include1 & "\",\n]\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ps3-" & slug & "-", "")
  result.reproBin = reproBinary()
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")

  var remotes = ""
  for name in ["alpha-only", "beta-only"]:
    let origin = result.scratch / ("origin-" & name & ".git")
    seedOrigin(gitBin, origin, result.scratch / ("seed-" & name))
    remotes.add(remoteBlock(name & "-origin", fileUrl(origin)))
    writeFile(workspaceRoot / "repos" / (name & ".toml"),
      repoFragment(name, name & "-origin"))

  writeFile(workspaceRoot / "projects" / "alpha.toml",
    projectFile("alpha", remotes, "repos/alpha-only.toml"))
  writeFile(workspaceRoot / "projects" / "beta.toml",
    projectFile("beta", remotes, "repos/beta-only.toml"))

  # The workspace starts out participating in ``alpha`` only, with alpha's
  # repo already checked out.
  writeWorkspaceProjects(workspaceRoot, @["alpha"])
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(result.scratch / "origin-alpha-only.git")) & " " &
    q(workspaceRoot / "alpha-only"))
  result.workspaceRoot = workspaceRoot

proc projectsAdd(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin, "workspace", "projects", "add"]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

proc activeSet(fx: Fixture): seq[string] =
  let listed = runShell(shellCommand(@[fx.reproBin, "workspace", "projects",
    "list", "--workspace-root=" & fx.workspaceRoot]))
  for line in listed.output.splitLines():
    let t = line.strip()
    if t.len > 0:
      result.add(t)

suite "PS-3 — projects add materializes what it records":

  test "t_workspace_projects_add_clones_added_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clone")
      defer: removeDir(fx.scratch)

      check not dirExists(fx.workspaceRoot / "beta-only")

      let added = projectsAdd(fx, ["beta"])
      if added.code notin [0, 2]:
        checkpoint("add output: " & added.output)
      check added.code in [0, 2]

      check activeSet(fx) == @["alpha", "beta"]
      # The point of the milestone: the repos the enlarged set introduces are
      # on disk when the command returns.
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")
      # Repos already present are left alone (still a valid checkout).
      check dirExists(fx.workspaceRoot / "alpha-only" / ".git")

  test "t_workspace_projects_add_no_sync_records_only":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "nosync")
      defer: removeDir(fx.scratch)

      let added = projectsAdd(fx, ["beta", "--no-sync"])
      if added.code != 0:
        checkpoint("add --no-sync output: " & added.output)
      check added.code == 0
      check activeSet(fx) == @["alpha", "beta"]
      # Membership recorded, nothing checked out.
      check not dirExists(fx.workspaceRoot / "beta-only")

      # Re-running WITHOUT --no-sync is the repair path for exactly this
      # partially-materialized state.
      let repaired = projectsAdd(fx, ["beta"])
      check repaired.code in [0, 2]
      check activeSet(fx) == @["alpha", "beta"]
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")
