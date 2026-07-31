## PS-1 / PS-2 — a workspace's ACTIVE PROJECT SET resolves as the UNION of
## every project in it (Workspace-And-Develop-Mode.md §"Multi-Project
## Workspaces"), and that union is what the membership commands act on.
##
## Fixture (hermetic, local ``git init --bare`` upstreams):
##   * project ``alpha`` declares ``alpha-only`` + ``shared``;
##   * project ``beta``  declares ``beta-only``  + ``shared``;
##   * ``shared`` is declared through the SAME repo fragment by both, so the
##     two declarations are identical — the union must carry it ONCE.
## The recorded active set is ``[alpha, beta]``.
##
## Asserted:
##   1. ``repro workspace list`` (no positional) reports the union —
##      ``alpha-only``, ``beta-only`` and exactly one ``shared`` line.
##   2. ``repro workspace list alpha`` (EXPLICIT project) still reports only
##      alpha's repos: an explicit argument is a single-project query, not a
##      workspace membership question.
##   3. ``repro workspace sync`` clones the missing repo of the NON-PRIMARY
##      project (``beta-only``), which is the concrete regression this
##      milestone fixes — before PS-2 the participating set was the primary
##      project's repos alone.
##
## Falsifiability (confirmed by hand, then reverted): dropping the
## ``extendWithActiveProjectSet`` call in ``resolveWorkspaceListProject``
## makes assertion 1 fail (``beta-only`` absent); dropping it in
## ``resolveWorkspaceProjectShared`` leaves ``beta-only`` uncloned in
## assertion 3.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

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
  ## One hermetic upstream with a single commit on ``main``.
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"PS Tester\"")
  writeFile(workPath / "README.md", "project-set fixture\n")
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

proc projectFile(name: string; remotes: string;
                 includes: openArray[string]): string =
  var body = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" & remotes & "includes = [\n"
  for inc in includes:
    body.add("  \"" & inc & "\",\n")
  body.add("]\n")
  body

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-ps-union-", "")
  result.reproBin = reproBinary()
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")

  var urls: seq[tuple[name, url: string]]
  for name in ["alpha-only", "beta-only", "shared"]:
    let origin = result.scratch / ("origin-" & name & ".git")
    seedOrigin(gitBin, origin, result.scratch / ("seed-" & name))
    urls.add((name, fileUrl(origin)))
    writeFile(workspaceRoot / "repos" / (name & ".toml"),
      repoFragment(name, name & "-origin"))

  var remotes = ""
  for u in urls:
    remotes.add(remoteBlock(u.name & "-origin", u.url))

  writeFile(workspaceRoot / "projects" / "alpha.toml",
    projectFile("alpha", remotes,
      ["repos/alpha-only.toml", "repos/shared.toml"]))
  writeFile(workspaceRoot / "projects" / "beta.toml",
    projectFile("beta", remotes,
      ["repos/beta-only.toml", "repos/shared.toml"]))

  # The recorded ACTIVE PROJECT SET: alpha (primary) + beta.
  writeWorkspaceProjects(workspaceRoot, @["alpha", "beta"])
  result.workspaceRoot = workspaceRoot

proc listRepoNames(output: string): seq[string] =
  ## The repo lines of ``workspace list`` are
  ## ``workspace list: <path> name=... remote=...``; the header line is
  ## ``workspace list: project=<name>``.
  for line in output.splitLines():
    let t = line.strip()
    if t.startsWith("workspace list: ") and not t.contains("project="):
      let rest = t["workspace list: ".len .. ^1]
      result.add(rest.split(' ')[0])

suite "PS-1/PS-2 — active project set resolves as a union":

  test "t_workspace_project_set_unions_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      let listed = runShell(shellCommand(@[fx.reproBin, "workspace", "list",
        "--workspace-root=" & fx.workspaceRoot]))
      if listed.code != 0:
        checkpoint("list output: " & listed.output)
      check listed.code == 0

      let names = listRepoNames(listed.output)
      check "alpha-only" in names
      check "beta-only" in names
      # The repo BOTH projects declare appears exactly once — dedup identity
      # is the checkout path, and two identical declarations are one repo.
      check names.count("shared") == 1
      check names.len == 3

      # An EXPLICIT project argument is a single-project query.
      let listedAlpha = runShell(shellCommand(@[fx.reproBin, "workspace",
        "list", "alpha", "--workspace-root=" & fx.workspaceRoot]))
      check listedAlpha.code == 0
      let alphaNames = listRepoNames(listedAlpha.output)
      check "alpha-only" in alphaNames
      check "shared" in alphaNames
      check "beta-only" notin alphaNames

  test "t_workspace_project_set_visible_to_list_and_sync":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # Nothing is checked out yet; a whole-workspace sync must create the
      # repos of EVERY project in the set, including the non-primary one.
      let synced = runShell(shellCommand(@[fx.reproBin, "workspace", "sync",
        "--workspace-root=" & fx.workspaceRoot]))
      if synced.code notin [0, 2]:
        checkpoint("sync output: " & synced.output)
      check synced.code in [0, 2]

      check dirExists(fx.workspaceRoot / "alpha-only" / ".git")
      check dirExists(fx.workspaceRoot / "shared" / ".git")
      # The load-bearing assertion: a repo that ONLY the non-primary project
      # declares is part of the workspace and gets checked out.
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")
