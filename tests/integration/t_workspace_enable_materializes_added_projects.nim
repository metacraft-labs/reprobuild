## PS-3 — ``repro workspace enable <p>`` MATERIALIZES what it records.
##
## The pilot command this replaces (the ``repo-workspaces``
## ``workspace`` CLI) layered the project's manifest AND checked its repos
## out. Recording membership without working trees leaves the workspace in a
## state no other command can act on, so recording and materializing are one
## operation (CLI/workspace.md §``repro workspace enable``).
##
## Fixture (hermetic, local ``git init --bare`` upstreams): projects ``alpha``
## (repo ``alpha-only``) and ``beta`` (repo ``beta-only``); the workspace
## starts with the active set ``[alpha]`` and ``alpha-only`` checked out.
##
## Asserted:
##   1. ``enable beta`` records ``[alpha, beta]`` AND clones
##      ``beta-only`` into the workspace.
##   2. ``enable beta --no-sync`` records membership only — the repo is
##      NOT on disk afterwards (the scripted-bootstrap / offline escape
##      hatch).
##   3. Re-running ``enable beta`` on that same workspace is the REPAIR
##      path: membership is already correct and idempotent, and the missing
##      checkout is created.
##
## Falsifiability (confirmed by hand, then reverted): removing the
## materialization call from ``runWorkspaceEnableCommand`` leaves
## ``beta-only`` absent in assertions 1 and 3 — which is exactly the bug this
## milestone fixes.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

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

proc enableProjects(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin, "workspace", "enable"]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

proc activeSet(fx: Fixture): seq[string] =
  let listed = runShell(shellCommand(@[fx.reproBin, "workspace", "projects",
    "list", "--enabled", "--workspace-root=" & fx.workspaceRoot]))
  for line in listed.output.splitLines():
    let t = line.strip()
    if t.len > 0:
      # `projects list` now emits `<name>\t<enabled|disabled>`; the active set
      # is the name column of the `--enabled` rows.
      result.add(t.split('\t')[0])

suite "PS-3/WV-2 — enable materializes what it records":

  test "t_workspace_enable_materializes_added_projects":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clone")
      defer: removeDir(fx.scratch)

      check not dirExists(fx.workspaceRoot / "beta-only")

      let added = enableProjects(fx, ["beta"])
      if added.code notin [0, 2]:
        checkpoint("add output: " & added.output)
      check added.code in [0, 2]

      check activeSet(fx) == @["alpha", "beta"]
      # The point of the milestone: the repos the enlarged set introduces are
      # on disk when the command returns.
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")
      # Repos already present are left alone (still a valid checkout).
      check dirExists(fx.workspaceRoot / "alpha-only" / ".git")

  test "t_workspace_enable_no_sync_records_only":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "nosync")
      defer: removeDir(fx.scratch)

      let added = enableProjects(fx, ["beta", "--no-sync"])
      if added.code != 0:
        checkpoint("add --no-sync output: " & added.output)
      check added.code == 0
      check activeSet(fx) == @["alpha", "beta"]
      # Membership recorded, nothing checked out.
      check not dirExists(fx.workspaceRoot / "beta-only")

      # Re-running WITHOUT --no-sync is the repair path for exactly this
      # partially-materialized state.
      let repaired = enableProjects(fx, ["beta"])
      check repaired.code in [0, 2]
      check activeSet(fx) == @["alpha", "beta"]
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")


proc workspaceFiles(fx: Fixture): seq[tuple[path, contents: string]] =
  # Include git metadata as well: preview must not fetch or refresh ignores.
  for path in walkDirRec(fx.workspaceRoot):
    result.add((relativePath(path, fx.workspaceRoot), readFile(path)))
  result.sort(proc(a, b: tuple[path, contents: string]): int = cmp(a.path, b.path))

suite "workspace enable dry-run":
  test "preview preserves workspace bytes and plans the prospective membership":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "dry-run")
    defer: removeDir(fx.scratch)
    discard requireGit(q(gitBin) & " init -b main " & q(fx.workspaceRoot))
    for existingIndex in [false, true]:
      if existingIndex:
        writeFile(fx.workspaceRoot / "workspace-projects.md", "preserved index\n")
      let before = workspaceFiles(fx)
      let preview = enableProjects(fx, ["beta", "--dry-run", "--write-report"])
      checkpoint(preview.output)
      check preview.code == 0
      check "alpha\n" in preview.output
      check "beta\n" in preview.output
      check "[clone] beta-only" in preview.output
      check "[update] alpha-only" notin preview.output
      check workspaceFiles(fx) == before
      check activeSet(fx) == @["alpha"]
      check not dirExists(fx.workspaceRoot / "beta-only")
    let applied = enableProjects(fx, ["beta", "--jobs=1"])
    checkpoint(applied.output)
    check applied.code == 0
    check activeSet(fx) == @["alpha", "beta"]
    check dirExists(fx.workspaceRoot / "beta-only" / ".git")

  test "no-sync preview preserves membership and generated files":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "dry-nosync")
    defer: removeDir(fx.scratch)
    let before = workspaceFiles(fx)
    let preview = enableProjects(fx, ["beta", "--no-sync", "--dry-run"])
    checkpoint(preview.output)
    check preview.code == 0
    check "beta" in preview.output
    check "[clone]" notin preview.output
    check workspaceFiles(fx) == before
    let hadDefault = existsEnv("REPRO_DEFAULT_PROJECTS")
    let savedDefault = getEnv("REPRO_DEFAULT_PROJECTS")
    putEnv("REPRO_DEFAULT_PROJECTS", "beta")
    defer:
      if hadDefault: putEnv("REPRO_DEFAULT_PROJECTS", savedDefault)
      else: delEnv("REPRO_DEFAULT_PROJECTS")
    let defaultPreview = enableProjects(fx, ["--default", "--dry-run"])
    checkpoint(defaultPreview.output)
    check defaultPreview.code == 0
    check "[clone] beta-only" in defaultPreview.output
    check workspaceFiles(fx) == before

  test "preview refuses undefined names and conflicting prospective sets":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "dry-refusal")
    defer: removeDir(fx.scratch)
    let beforeUndefined = workspaceFiles(fx)
    let undefined = enableProjects(fx, ["unknown", "--dry-run"])
    check undefined.code == 2
    check "no such project: unknown" in undefined.output
    check workspaceFiles(fx) == beforeUndefined
    let fragment = fx.workspaceRoot / "repos" / "beta-only.toml"
    writeFile(fragment, readFile(fragment).replace("path = \"beta-only\"",
      "path = \"alpha-only\""))
    let beforeConflict = workspaceFiles(fx)
    let conflict = enableProjects(fx, ["beta", "--dry-run"])
    checkpoint(conflict.output)
    check conflict.code == 1
    check "refusing to record" in conflict.output
    check "alpha-only" in conflict.output
    check workspaceFiles(fx) == beforeConflict


  test "preview does not create initial membership or bootstrap metadata":
    let gitBin = findExe("git")
    require gitBin.len > 0
    let fx = setupFixture(gitBin, "dry-initial")
    defer: removeDir(fx.scratch)
    removeFile(workspaceStatePath(fx.workspaceRoot))
    let before = workspaceFiles(fx)
    let preview = enableProjects(fx, ["beta", "--dry-run"])
    checkpoint(preview.output)
    check preview.code == 0
    check "[clone] beta-only" in preview.output
    check workspaceFiles(fx) == before
    removeDir(fx.workspaceRoot / "projects")
    removeDir(fx.workspaceRoot / "repos")
    let beforeBootstrap = workspaceFiles(fx)
    let bootstrap = enableProjects(fx, ["beta", "--dry-run"])
    checkpoint(bootstrap.output)
    check bootstrap.code == 0
    check "could not resolve" in bootstrap.output
    check "recorded membership" notin bootstrap.output
    check workspaceFiles(fx) == beforeBootstrap
