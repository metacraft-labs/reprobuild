## PS-4 — a project set that would not resolve is REFUSED before anything is
## mutated (Workspace-And-Develop-Mode.md §"Union Rules").
##
## Two projects may declare the same checkout path only when they agree about
## it. A path is one working tree, so a disagreement about its revision (or
## name / fetch URL / VCS) cannot be resolved by picking a winner without
## making the workspace's build inputs depend on the order projects happened
## to be added in. Reprobuild refuses instead, and refuses EARLY: no metadata
## is written and no working tree is touched.
##
## Fixture (hermetic, no network needed — the refusal happens during manifest
## resolution): project ``alpha`` declares ``shared`` at revision ``main``;
## project ``gamma`` declares the SAME path ``shared`` at revision
## ``other-branch``, plus a repo of its own (``gamma-only``).
##
## Asserted:
##   1. ``projects add gamma`` exits non-zero and names the conflicting path,
##      both projects, and the differing field.
##   2. The active set is UNCHANGED (still ``[alpha]``).
##   3. Nothing was checked out — ``gamma-only`` is absent, so the refusal
##      happened before the materialization phase.
##
## Falsifiability (confirmed by hand, then reverted): moving the validation
## after ``writeWorkspaceProjects`` makes assertion 2 fail — the set is
## recorded even though it cannot resolve, leaving a workspace whose every
## subsequent command errors.

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
  writeFile(workPath / "README.md", "conflict fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

proc remoteBlock(name, url: string): string =
  "[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url & "\"\n\n"

proc repoFragment(fragmentName, repoName, remote, revision: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & repoName & "\"\n" &
  "path = \"" & repoName & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"" & revision & "\"\n"

proc projectFile(name, remotes: string; includes: openArray[string]): string =
  var body = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" & remotes & "includes = [\n"
  for inc in includes:
    body.add("  \"" & inc & "\",\n")
  body.add("]\n")
  body

suite "PS-4 — a conflicting project set is refused before mutation":

  test "t_workspace_project_set_conflict_refused":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ps4-conflict-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      var remotes = ""
      for name in ["shared", "gamma-only"]:
        let origin = scratch / ("origin-" & name & ".git")
        seedOrigin(gitBin, origin, scratch / ("seed-" & name))
        remotes.add(remoteBlock(name & "-origin", fileUrl(origin)))

      # Same PATH, different REVISION — declared through two fragments so the
      # disagreement is a genuine manifest-level conflict.
      writeFile(workspaceRoot / "repos" / "shared-main.toml",
        repoFragment("shared-main", "shared", "shared-origin", "main"))
      writeFile(workspaceRoot / "repos" / "shared-other.toml",
        repoFragment("shared-other", "shared", "shared-origin",
          "other-branch"))
      writeFile(workspaceRoot / "repos" / "gamma-only.toml",
        repoFragment("gamma-only", "gamma-only", "gamma-only-origin", "main"))

      writeFile(workspaceRoot / "projects" / "alpha.toml",
        projectFile("alpha", remotes, ["repos/shared-main.toml"]))
      writeFile(workspaceRoot / "projects" / "gamma.toml",
        projectFile("gamma", remotes,
          ["repos/shared-other.toml", "repos/gamma-only.toml"]))

      writeWorkspaceProjects(workspaceRoot, @["alpha"])

      let refused = runShell(shellCommand(@[reproBin, "workspace",
        "enable", "gamma", "--workspace-root=" & workspaceRoot]))
      check refused.code != 0
      check refused.output.contains("shared")
      check refused.output.contains("alpha")
      check refused.output.contains("gamma")
      check refused.output.contains("revision")

      # The active set is untouched: a refused enable leaves the workspace
      # exactly as it was.
      let listed = runShell(shellCommand(@[reproBin, "workspace", "projects",
        "list", "--enabled", "--workspace-root=" & workspaceRoot]))
      check listed.code == 0
      var active: seq[string]
      for line in listed.output.splitLines():
        let t = line.strip()
        if t.len > 0: active.add(t.split('\t')[0])
      check active == @["alpha"]

      # ...and no working tree was created, so the refusal preceded the
      # materialization phase.
      check not dirExists(workspaceRoot / "gamma-only")
      check not dirExists(workspaceRoot / "shared")

  test "t_workspace_project_set_unresolvable_manifest_is_not_a_conflict":
    # A project that cannot be resolved YET is not a disagreement. The RA-6
    # fresh-clone bootstrap records the default project set before any
    # manifest checkout exists, so membership is still recorded — only the
    # clone phase is skipped, with the reason reported.
    let scratch = createTempDir("repro-ps4-unresolved-", "")
    defer: removeDir(scratch)
    let reproBin = reproBinary()
    let workspaceRoot = scratch / "workspace"
    createDir(workspaceRoot / "projects")
    # A project file the strict reader cannot resolve (no manifest data yet).
    writeFile(workspaceRoot / "projects" / "delta.toml",
      "schema = \"reprobuild.workspace.project.v1\"\n\n" &
      "[project]\nname = \"delta\"\ndefault_revision = \"main\"\n" &
      "trunk = \"main\"\n\nincludes = [\n]\n")

    let added = runShell(shellCommand(@[reproBin, "workspace",
      "enable", "delta", "--workspace-root=" & workspaceRoot]))
    if added.code != 0:
      checkpoint("add output: " & added.output)
    check added.code == 0

    let listed = runShell(shellCommand(@[reproBin, "workspace", "projects",
      "list", "--enabled", "--workspace-root=" & workspaceRoot]))
    var active: seq[string]
    for line in listed.output.splitLines():
      let t = line.strip()
      if t.len > 0: active.add(t.split('\t')[0])
    check active == @["delta"]
