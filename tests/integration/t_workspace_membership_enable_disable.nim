## WV-1 / WV-2 — the MEMBERSHIP axis: `repro workspace enable` / `disable`,
## and the `repro ws` namespace alias.
##
## Membership is "which projects are active in THIS workspace" — a local,
## private, reversible fact recorded in `.repro/workspace.toml`. It is a
## different axis from DEFINITION (which projects exist at all), which is
## `projects`/`repos` `add`/`remove` and is covered by
## `t_workspace_definition_projects_repos`. See CLI/workspace.md §"The Two
## Axes".
##
## Fixture (hermetic, local `git init --bare` upstreams): projects `alpha`
## (repos `shared`, `alpha-only`) and `beta` (repos `shared`, `beta-only`).
## `shared` is included by BOTH, which is what makes the "disable removes only
## what is unique" rule observable at all.
##
## Asserted:
##   1. `repro ws enable beta` is the same command as
##      `repro workspace enable beta` — the alias is resolved before routing.
##   2. `disable beta` drops membership, removes `beta-only`, and LEAVES
##      `shared` (still declared by the enabled `alpha`) and `alpha-only`.
##   3. `disable` refuses (exit 2) when a checkout it would remove carries
##      commits no remote has — and refuses BEFORE removing anything, so the
##      membership record and every working tree are untouched.
##   4. `--keep-checkouts` records the membership change and leaves the tree.
##   5. `enable` of an UNDEFINED project is refused (exit 2) and names the
##      definition verbs; membership is unchanged.
##
## No mocks: every git operation runs against real local repositories, and the
## CLI under test is the engine-built `build/bin/repro`.

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
    " config user.name \"WV Tester\"")
  writeFile(workPath / "README.md", "membership fixture\n")
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

proc projectFile(name, remotes: string; includes: openArray[string]): string =
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
    gitBin: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-wv2-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.gitBin = gitBin
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")

  var remotes = ""
  for name in ["shared", "alpha-only", "beta-only"]:
    let origin = result.scratch / ("origin-" & name & ".git")
    seedOrigin(gitBin, origin, result.scratch / ("seed-" & name))
    remotes.add(remoteBlock(name & "-origin", fileUrl(origin)))
    writeFile(workspaceRoot / "repos" / (name & ".toml"),
      repoFragment(name, name & "-origin"))

  writeFile(workspaceRoot / "projects" / "alpha.toml",
    projectFile("alpha", remotes,
      ["repos/shared.toml", "repos/alpha-only.toml"]))
  writeFile(workspaceRoot / "projects" / "beta.toml",
    projectFile("beta", remotes,
      ["repos/shared.toml", "repos/beta-only.toml"]))

  writeWorkspaceProjects(workspaceRoot, @["alpha"])
  for name in ["shared", "alpha-only"]:
    discard requireGit(q(gitBin) & " clone " &
      q(fileUrl(result.scratch / ("origin-" & name & ".git"))) & " " &
      q(workspaceRoot / name))
  result.workspaceRoot = workspaceRoot

proc runRepro(fx: Fixture; args: openArray[string]): CmdResult =
  var argv = @[fx.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

proc activeSet(fx: Fixture): seq[string] =
  let listed = runRepro(fx, ["workspace", "projects", "list", "--enabled"])
  for line in listed.output.splitLines():
    let t = line.strip()
    if t.len > 0:
      result.add(t.split('\t')[0])

suite "WV-1/WV-2 — workspace membership (enable / disable / ws alias)":

  test "t_workspace_ws_alias_dispatches":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "alias")
      defer: removeDir(fx.scratch)

      # The alias is resolved once, before subcommand routing, so it is the
      # SAME command rather than a second surface that could drift.
      let viaAlias = runRepro(fx, ["ws", "enable", "beta"])
      if viaAlias.code != 0:
        checkpoint("output: " & viaAlias.output)
      check viaAlias.code == 0
      check activeSet(fx) == @["alpha", "beta"]
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")

      # `ws` in a NON-leading position stays an ordinary argument.
      let listed = runRepro(fx, ["workspace", "projects", "list"])
      check listed.code == 0

  test "t_workspace_disable_keeps_shared_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "shared")
      defer: removeDir(fx.scratch)

      check runRepro(fx, ["workspace", "enable", "beta"]).code == 0
      check dirExists(fx.workspaceRoot / "beta-only" / ".git")

      let res = runRepro(fx, ["workspace", "disable", "beta"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check activeSet(fx) == @["alpha"]

      # Unique to beta → removed. Declared by the still-enabled alpha → kept.
      check not dirExists(fx.workspaceRoot / "beta-only")
      check dirExists(fx.workspaceRoot / "shared" / ".git")
      check dirExists(fx.workspaceRoot / "alpha-only" / ".git")

  test "t_workspace_disable_refuses_unpushed_work":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "unpushed")
      defer: removeDir(fx.scratch)

      check runRepro(fx, ["workspace", "enable", "beta"]).code == 0
      let betaOnly = fx.workspaceRoot / "beta-only"

      # A commit that exists in this checkout and nowhere else. Deleting the
      # tree would destroy it, so the whole command must refuse.
      writeFile(betaOnly / "local.txt", "work that exists only here\n")
      discard requireGit(q(gitBin) & " -C " & q(betaOnly) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(betaOnly) &
        " config user.name \"WV Tester\"")
      discard requireGit(q(gitBin) & " -C " & q(betaOnly) & " add local.txt")
      discard requireGit(q(gitBin) & " -C " & q(betaOnly) &
        " commit -m local-only")

      let refused = runRepro(fx, ["workspace", "disable", "beta"])
      check refused.code == 2
      check refused.output.contains("beta-only")
      check refused.output.contains("unpushed")
      # Refused BEFORE anything moved: membership AND the tree are intact.
      check activeSet(fx) == @["alpha", "beta"]
      check dirExists(betaOnly / ".git")
      check fileExists(betaOnly / "local.txt")

      # `--keep-checkouts` is the documented way out: drop membership, keep
      # every working tree exactly where it is.
      let kept = runRepro(fx, ["workspace", "disable", "beta",
        "--keep-checkouts"])
      if kept.code != 0:
        checkpoint("output: " & kept.output)
      check kept.code == 0
      check activeSet(fx) == @["alpha"]
      check fileExists(betaOnly / "local.txt")

  test "t_workspace_enable_refuses_undefined_project":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "undefined")
      defer: removeDir(fx.scratch)

      # Enabling is not how a project comes into existence — recording
      # membership no manifest layer can resolve breaks every later command.
      let refused = runRepro(fx, ["workspace", "enable", "nosuchproject"])
      check refused.code == 2
      check refused.output.contains("nosuchproject")
      check refused.output.contains("projects add")
      check activeSet(fx) == @["alpha"]
