## RA-3 — ``repro workspace sync`` is keyed to each repo's OWN upstream.
##
## repo-workspaces rebuilt sync around per-repo upstream tracking
## (commit ``c467c1a``): fetch + ``merge --ff-only @{u}`` on whatever
## branch each repo currently has checked out, rather than aligning
## every repo to one workspace-wide branch name.
##
## This test sets up four sibling repos:
##   - ``lib-a`` on ``dev``    — fast-forwardable to ``origin/dev``
##   - ``lib-b`` on ``latest`` — fast-forwardable to ``origin/latest``
##   - ``lib-c`` on ``live``   — fast-forwardable to ``origin/live``
##   - ``lib-d`` on ``feat``   — DIVERGENT (a local unpushed commit);
##                               must be skipped/reported, not
##                               force-updated.
##
## After sync the three on-branch repos must each be advanced to their
## OWN ``origin/<branch>`` tip, proving the fast-forward followed the
## repo's own upstream and not a single shared branch. The divergent
## repo must keep its local HEAD and current branch (no force update).
##
## Falsifiability: if sync forced a workspace-wide branch (e.g. only
## ``dev``), the ``latest`` / ``live`` repos would NOT advance to their
## own tips, or the merge would target the wrong ref and fail; if the
## divergent repo were force-updated its local commit would be lost.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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
    " config user.name \"RA3 Tester\"")
  writeFile(workPath / "README.md", "RA3 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, originPath, workPath, branch: string): string =
  ## Advance the bare origin's ``branch`` tip by one commit so clones
  ## taken before this call become fast-forwardable on that branch.
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
    " config user.name \"RA3 Tester\"")

proc appendLocalCommit(gitBin, repoPath: string): string =
  ## A clean, unpushed local commit — makes the repo divergent from its
  ## upstream so sync must NOT touch it.
  writeFile(repoPath / "local-only.txt", "diverged\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add local-only.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"local-only divergence\"")
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

proc currentBranch(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD").strip()

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl, cUrl, dUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"dev\"\n" &
    "trunk = \"dev\"\n\n" &
    "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
    "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
    "[[remote]]\nname = \"c-origin\"\nfetch = \"" & cUrl & "\"\n\n" &
    "[[remote]]\nname = \"d-origin\"\nfetch = \"" & dUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "  \"repos/lib-d.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "a-origin"
revision = "dev"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "b-origin"
revision = "latest"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "c-origin"
revision = "live"
"""

const libDFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-d"
path = "lib-d"
remote = "d-origin"
revision = "feat"
"""

type
  RepoSeed = object
    origin: string
    seedPath: string
    branch: string
    sha: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    a, b, c, d: RepoSeed

proc seedRepo(gitBin, scratch, name, branch: string): RepoSeed =
  result.branch = branch
  result.origin = scratch / ("origin-" & name & ".git")
  result.seedPath = scratch / ("seed-" & name)
  result.sha = seedGitOrigin(gitBin, result.origin, result.seedPath, branch)

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra3sync-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.a = seedRepo(gitBin, result.scratch, "lib-a", "dev")
  result.b = seedRepo(gitBin, result.scratch, "lib-b", "latest")
  result.c = seedRepo(gitBin, result.scratch, "lib-c", "live")
  result.d = seedRepo(gitBin, result.scratch, "lib-d", "feat")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(
      fileUrl(result.a.origin), fileUrl(result.b.origin),
      fileUrl(result.c.origin), fileUrl(result.d.origin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-d.toml", libDFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeSync(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntry(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  checkpoint("no sync-report entry for path " & path)
  fail()
  newJObject()

suite "RA-3 — sync fast-forwards each repo's own upstream":

  test "t_sync_ff_only_per_repo_upstream":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "per-repo")
      defer: removeDir(fx.scratch)

      # Clone all four at their original tips on their own branches.
      cloneInto(gitBin, fx.a.origin, fx.workspaceRoot / "lib-a")
      cloneInto(gitBin, fx.b.origin, fx.workspaceRoot / "lib-b")
      cloneInto(gitBin, fx.c.origin, fx.workspaceRoot / "lib-c")
      cloneInto(gitBin, fx.d.origin, fx.workspaceRoot / "lib-d")

      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "dev"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == "latest"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-c") == "live"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-d") == "feat"

      # Advance each of the three fast-forward repos' OWN upstream by one
      # commit (each on its own branch).
      let advancedA = seedSecondCommit(gitBin, fx.a.origin, fx.a.seedPath, "dev")
      let advancedB =
        seedSecondCommit(gitBin, fx.b.origin, fx.b.seedPath, "latest")
      let advancedC = seedSecondCommit(gitBin, fx.c.origin, fx.c.seedPath, "live")

      # Make lib-d divergent: a clean, unpushed local commit on ``feat``.
      let divergentSha = appendLocalCommit(gitBin, fx.workspaceRoot / "lib-d")

      let res = invokeSync(fx)
      if res.code notin [0, 2]:
        checkpoint("output: " & res.output)
      # divergent_feature_branch / locally_unpublished is report-only (0)
      # or refuse-and-report (2); both are acceptable overall exit codes.
      check res.code in [0, 2]

      # Each fast-forward repo advanced to its OWN upstream tip — proving
      # the merge followed ``origin/<its own branch>`` and not one shared
      # workspace branch.
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == advancedA
      check headSha(gitBin, fx.workspaceRoot / "lib-b") == advancedB
      check headSha(gitBin, fx.workspaceRoot / "lib-c") == advancedC
      # Branches are unchanged (no realignment to a single branch name).
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "dev"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == "latest"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-c") == "live"

      # The divergent repo was skipped: local HEAD and branch intact.
      check headSha(gitBin, fx.workspaceRoot / "lib-d") == divergentSha
      check currentBranch(gitBin, fx.workspaceRoot / "lib-d") == "feat"

      let report = readReport(fx)
      check repoEntry(report, "lib-a")["syncCase"].getStr() ==
        "clean_fast_forwardable"
      check repoEntry(report, "lib-a")["executionStatus"].getStr() ==
        "succeeded"
      check repoEntry(report, "lib-b")["syncCase"].getStr() ==
        "clean_fast_forwardable"
      check repoEntry(report, "lib-b")["executionStatus"].getStr() ==
        "succeeded"
      check repoEntry(report, "lib-c")["syncCase"].getStr() ==
        "clean_fast_forwardable"
      check repoEntry(report, "lib-c")["executionStatus"].getStr() ==
        "succeeded"
      # The divergent repo is reported, never force-updated.
      let dEntry = repoEntry(report, "lib-d")
      check dEntry["syncCase"].getStr() in
        ["divergent_feature_branch", "locally_unpublished"]
      check dEntry["action"].getStr() == "none"
      check dEntry["executionStatus"].getStr() in ["noop", "refused"]
