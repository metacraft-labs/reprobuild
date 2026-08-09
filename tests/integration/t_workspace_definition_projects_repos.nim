## WV-3 / WV-4 — the DEFINITION axis: `repro workspace projects` and
## `repro workspace repos`.
##
## These verbs author the manifest repo — `projects/*.toml`, `repos/*.toml`,
## and the `includes` edges between them — and their effect is shared with
## everyone who syncs. That is a different axis from MEMBERSHIP (`enable` /
## `disable`, covered by `t_workspace_membership_enable_disable`). See
## CLI/workspace.md §"The Two Axes".
##
## Fixture (hermetic): a workspace root that is itself the manifest repo (a
## real `git init` checkout with a local bare upstream, matching the native
## `<org>/repro-workspace` layout), carrying projects `alpha` and `beta`.
##
## Asserted:
##   1. `projects add <existing>` is an ERROR naming `enable` — this spelling
##      changed meaning rather than disappearing, so it cannot fail as an
##      unknown subcommand and needs an explicit guard.
##   2. `projects remove` refuses while the project is ENABLED here, because
##      removing the definition under a live membership record leaves a set
##      entry nothing can resolve.
##   3. `projects list` marks every defined project enabled/disabled, and the
##      selector flags narrow it.
##   4. `repos add <repo> --project=A --project=B` declares ONE fragment and
##      wires an include edge into BOTH projects — the shape that keeps two
##      projects from conflicting over a checkout path.
##   5. `repos remove` drops the include edges but KEEPS the fragment (a
##      reusable declaration); `--delete-fragment` is refused while any
##      project still includes it.
##
## No mocks: the manifest edits are asserted by reading the resulting TOML back
## through the real strict reader, and the commits land in a real git repo.

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

proc projectFile(name: string; includes: openArray[string]): string =
  var body = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & name & "\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"acme\"\nfetch = \"https://git.example.invalid/acme\"\n\n" &
    "includes = [\n"
  for inc in includes:
    body.add("  \"" & inc & "\",\n")
  body.add("]\n")
  body

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-wv34-" & slug & "-", "")
  result.reproBin = reproBinary()
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "alpha.toml",
    projectFile("alpha", []))
  writeFile(workspaceRoot / "projects" / "beta.toml",
    projectFile("beta", []))

  # The manifest verbs commit, so the root has to be a real checkout.
  discard requireGit(q(gitBin) & " init -b main " & q(workspaceRoot))
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " config user.name \"WV Tester\"")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workspaceRoot) &
    " commit -m fixture")
  result.workspaceRoot = workspaceRoot

proc runRepro(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

proc includesOf(fx: Fixture; project: string): seq[string] =
  readProjectManifest(
    fx.workspaceRoot / "projects" / (project & ".toml")).includes

suite "WV-3/WV-4 — workspace definition (projects / repos authoring)":

  test "t_workspace_projects_add_rejects_existing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "exists")
      defer: removeDir(fx.scratch)

      let refused = runRepro(fx, ["ws", "projects", "add", "alpha"])
      check refused.code == 1
      check refused.output.contains("already exists")
      # The muscle-memory case fails LOUDLY and names the verb that does what
      # the operator most likely meant.
      check refused.output.contains("repro ws enable alpha")

      # ...and a genuinely new name is created, not enabled.
      let created = runRepro(fx, ["ws", "projects", "add", "gamma",
        "-m", "Gamma project"])
      if created.code != 0:
        checkpoint("output: " & created.output)
      check created.code == 0
      check fileExists(fx.workspaceRoot / "projects" / "gamma.toml")
      check fileExists(fx.workspaceRoot / "projects" / "gamma.md")
      check readWorkspaceProjects(fx.workspaceRoot).len == 0

  test "t_workspace_projects_remove_refuses_while_enabled":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "remove")
      defer: removeDir(fx.scratch)

      writeWorkspaceProjects(fx.workspaceRoot, @["alpha"])
      let refused = runRepro(fx, ["ws", "projects", "remove", "alpha"])
      check refused.code == 2
      check refused.output.contains("repro ws disable alpha")
      check fileExists(fx.workspaceRoot / "projects" / "alpha.toml")

      # A project nobody is standing on removes cleanly.
      let removed = runRepro(fx, ["ws", "projects", "remove", "beta"])
      if removed.code != 0:
        checkpoint("output: " & removed.output)
      check removed.code == 0
      check not fileExists(fx.workspaceRoot / "projects" / "beta.toml")

  test "t_workspace_projects_list_marks_enabled":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "list")
      defer: removeDir(fx.scratch)

      writeWorkspaceProjects(fx.workspaceRoot, @["alpha"])
      let all = runRepro(fx, ["ws", "projects", "list"])
      check all.code == 0
      check all.output.contains("alpha\tenabled")
      check all.output.contains("beta\tdisabled")

      let enabled = runRepro(fx, ["ws", "projects", "list", "--enabled"])
      check enabled.output.contains("alpha")
      check not enabled.output.contains("beta")

      let disabled = runRepro(fx, ["ws", "projects", "list", "--disabled"])
      check disabled.output.contains("beta")
      check not disabled.output.contains("alpha")

  test "t_workspace_repos_add_multi_project":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "multi")
      defer: removeDir(fx.scratch)

      let res = runRepro(fx, ["ws", "repos", "add", "lib-x",
        "--project=alpha", "--project=beta",
        "--remote=https://git.example.invalid/acme/lib-x.git",
        "-m", "Shared library."])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # ONE fragment, TWO include edges. Declaring it once is what stops the
      # two projects from disagreeing about the checkout path later.
      check fileExists(fx.workspaceRoot / "repos" / "lib-x.toml")
      check "repos/lib-x.toml" in includesOf(fx, "alpha")
      check "repos/lib-x.toml" in includesOf(fx, "beta")
      check readRepoFragment(
        fx.workspaceRoot / "repos" / "lib-x.toml").repo.path == "lib-x"

      # A contradicting re-declaration is refused rather than silently
      # re-pointing a repo other projects already depend on.
      let conflicting = runRepro(fx, ["ws", "repos", "add", "lib-x",
        "--project=alpha",
        "--remote=https://git.example.invalid/acme/lib-x.git",
        "--path=somewhere/else"])
      check conflicting.code == 1
      check conflicting.output.contains("path")

  test "t_workspace_repos_remove_keeps_fragment_by_default":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "reporemove")
      defer: removeDir(fx.scratch)

      check runRepro(fx, ["ws", "repos", "add", "lib-y",
        "--project=alpha", "--project=beta",
        "--remote=https://git.example.invalid/acme/lib-y.git"]).code == 0

      # --delete-fragment is refused while another project still includes it.
      let refused = runRepro(fx, ["ws", "repos", "remove", "lib-y",
        "--project=alpha", "--delete-fragment"])
      check refused.code == 2
      check fileExists(fx.workspaceRoot / "repos" / "lib-y.toml")
      check "repos/lib-y.toml" notin includesOf(fx, "alpha")
      check "repos/lib-y.toml" in includesOf(fx, "beta")

      # With no --project it stops declaring the repo everywhere, and the
      # fragment survives as a reusable declaration.
      let removed = runRepro(fx, ["ws", "repos", "remove", "lib-y"])
      if removed.code != 0:
        checkpoint("output: " & removed.output)
      check removed.code == 0
      check "repos/lib-y.toml" notin includesOf(fx, "beta")
      check fileExists(fx.workspaceRoot / "repos" / "lib-y.toml")

      # Now that nothing includes it, deleting it is allowed.
      let deleted = runRepro(fx, ["ws", "repos", "remove", "lib-y",
        "--delete-fragment"])
      if deleted.code != 0:
        checkpoint("output: " & deleted.output)
      check deleted.code == 0
      check not fileExists(fx.workspaceRoot / "repos" / "lib-y.toml")
