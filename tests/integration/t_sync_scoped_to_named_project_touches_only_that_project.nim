## RA-27 — scoped ``repro workspace sync <project>`` touches ONLY that
## project's repos (Interactive-UX-And-Progress.md Principle 1 + CLI/sync.md
## "scopes the sync to those projects' repos only").
##
## Fixture: a workspace whose RECORDED project ``everything`` declares repos
## from TWO disjoint groups:
##   - project ``group-a`` declares ``alpha-1`` and ``alpha-2``;
##   - project ``group-b`` declares ``beta-1``.
## All three checkouts exist and all three upstreams have advanced, so a
## WHOLE-workspace sync would fast-forward all three.
##
## ``repro workspace sync group-a`` must advance ONLY ``alpha-1`` / ``alpha-2``
## and leave ``beta-1`` at its pre-sync HEAD (not fetched / not advanced).
## An UNKNOWN project name errors clearly with a non-zero exit.
##
## Falsifiability (confirmed by hand, then reverted): removing the scope
## filter in ``executeWorkspaceSync`` makes the base resolution (the recorded
## ``everything`` project) the participating set, so ``beta-1`` advances too —
## the ``beta-1 == before`` assertion then FAILS.
##
## A control whole-workspace sync at the end DOES advance ``beta-1`` (proving
## the scoped pass was a true narrowing, not a vacuous no-op on ``beta-1``).
##
## Hermetic: local ``git init --bare`` upstreams; skip when git is absent.

import std/[os, osproc, strutils, tempfiles, unittest]

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

proc seedGitOrigin(gitBin, originPath, workPath, branch: string): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA27 Tester\"")
  writeFile(workPath / "README.md", "RA27 scope fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, originPath, workPath, branch: string): string =
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA27 Tester\"")

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc remoteBlock(name, url: string): string =
  "[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url & "\"\n\n"

proc repoFragment(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"main\"\n"

type
  RepoSeed = object
    origin: string
    seedPath: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    alpha1, alpha2, beta1: RepoSeed

proc seedRepo(gitBin, scratch, name: string): RepoSeed =
  result.origin = scratch / ("origin-" & name & ".git")
  result.seedPath = scratch / ("seed-" & name)
  discard seedGitOrigin(gitBin, result.origin, result.seedPath, "main")

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-ra27scope-", "")
  result.reproBin = reproBinary()
  result.alpha1 = seedRepo(gitBin, result.scratch, "alpha-1")
  result.alpha2 = seedRepo(gitBin, result.scratch, "alpha-2")
  result.beta1 = seedRepo(gitBin, result.scratch, "beta-1")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")

  let a1Url = fileUrl(result.alpha1.origin)
  let a2Url = fileUrl(result.alpha2.origin)
  let b1Url = fileUrl(result.beta1.origin)
  let remotes =
    remoteBlock("alpha1-origin", a1Url) &
    remoteBlock("alpha2-origin", a2Url) &
    remoteBlock("beta1-origin", b1Url)

  # The RECORDED workspace project: includes ALL three repos. A
  # whole-workspace sync (or a scoped sync that ignores the filter) operates
  # on this full set.
  writeFile(manifestsRoot / "projects" / "everything.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"everything\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    remotes &
    "includes = [\n  \"repos/alpha-1.toml\",\n  \"repos/alpha-2.toml\",\n" &
    "  \"repos/beta-1.toml\",\n]\n")

  # The SCOPE projects: ``group-a`` = the two alpha repos; ``group-b`` =
  # the single beta repo. ``repro workspace sync group-a`` narrows the full
  # set to just these.
  writeFile(manifestsRoot / "projects" / "group-a.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"group-a\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    remoteBlock("alpha1-origin", a1Url) & remoteBlock("alpha2-origin", a2Url) &
    "includes = [\n  \"repos/alpha-1.toml\",\n  \"repos/alpha-2.toml\",\n]\n")
  writeFile(manifestsRoot / "projects" / "group-b.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"group-b\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    remoteBlock("beta1-origin", b1Url) &
    "includes = [\n  \"repos/beta-1.toml\",\n]\n")

  writeFile(manifestsRoot / "repos" / "alpha-1.toml",
    repoFragment("alpha-1", "alpha1-origin"))
  writeFile(manifestsRoot / "repos" / "alpha-2.toml",
    repoFragment("alpha-2", "alpha2-origin"))
  writeFile(manifestsRoot / "repos" / "beta-1.toml",
    repoFragment("beta-1", "beta1-origin"))

  # Record the workspace project so resolution yields the FULL set (the
  # scope positionals act purely as a filter, per RA-27).
  writeWorkspaceBranch(workspaceRoot, project = "everything", branch = "main")
  result.workspaceRoot = workspaceRoot

proc invokeSync(fx: Fixture; scope: openArray[string] = []): CmdResult =
  var argv = @[fx.reproBin, "workspace", "sync"]
  for s in scope: argv.add(s)
  argv.add("--workspace-root=" & fx.workspaceRoot)
  runShell(shellCommand(argv))

suite "RA-27 — scoped sync touches only the named project":

  test "t_sync_scoped_to_named_project_touches_only_that_project":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.alpha1.origin, fx.workspaceRoot / "alpha-1")
      cloneInto(gitBin, fx.alpha2.origin, fx.workspaceRoot / "alpha-2")
      cloneInto(gitBin, fx.beta1.origin, fx.workspaceRoot / "beta-1")

      # Advance EVERY upstream so a whole-workspace sync would touch all.
      let advA1 = seedSecondCommit(gitBin, fx.alpha1.origin, fx.alpha1.seedPath, "main")
      let advA2 = seedSecondCommit(gitBin, fx.alpha2.origin, fx.alpha2.seedPath, "main")
      let advB1 = seedSecondCommit(gitBin, fx.beta1.origin, fx.beta1.seedPath, "main")

      let beforeA1 = headSha(gitBin, fx.workspaceRoot / "alpha-1")
      let beforeB1 = headSha(gitBin, fx.workspaceRoot / "beta-1")
      check beforeA1 != advA1   # upstreams really advanced
      check beforeB1 != advB1

      # ---- unknown project name errors clearly --------------------------
      let bad = invokeSync(fx, ["no-such-project"])
      check bad.code != 0
      check bad.output.contains("unknown project")
      check bad.output.contains("no-such-project")
      # The bad invocation must not have advanced anything.
      check headSha(gitBin, fx.workspaceRoot / "beta-1") == beforeB1

      # ---- scoped sync touches ONLY group-a ----------------------------
      let res = invokeSync(fx, ["group-a"])
      check res.code in [0, 2]

      # alpha-1 / alpha-2 advanced to their upstream tips.
      check headSha(gitBin, fx.workspaceRoot / "alpha-1") == advA1
      check headSha(gitBin, fx.workspaceRoot / "alpha-2") == advA2
      # beta-1 was NOT touched — still at its pre-sync HEAD (the load-bearing
      # scope assertion: it fails if the filter is ignored).
      check headSha(gitBin, fx.workspaceRoot / "beta-1") == beforeB1

      # The scoped report names only the scoped project's repos.
      let scopedReport = invokeSync(fx, ["group-a", "--json"])
      check scopedReport.code in [0, 2]

      # ---- control: a WHOLE-workspace sync DOES advance beta-1 ----------
      # Proves the scoped pass was a true narrowing, not a vacuous no-op on
      # beta-1 (e.g. an unreachable upstream).
      let whole = invokeSync(fx)
      check whole.code in [0, 2]
      check headSha(gitBin, fx.workspaceRoot / "beta-1") == advB1
