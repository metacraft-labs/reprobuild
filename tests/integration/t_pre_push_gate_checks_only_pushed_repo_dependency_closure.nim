## RA-21 — the pre-push gate scopes its clean/published checks to the
## pushed repo's TRANSITIVE develop-set dependency closure, NOT the whole
## workspace.
##
## A develop-mode sibling is a git-submodule replacement: only the pushed
## repo's own dependency closure can break a teammate's build of it, so an
## unrelated dirty repo elsewhere in the workspace MUST NOT block the push
## (Workspace-And-Develop-Mode.md §"VCS Hook Integration").
##
## Topology: repo A declares ``depends = ["lib-b"]`` (so A's closure is
## {lib-a, lib-b}); lib-c is unrelated (no edge). All three start clean and
## published, and the workspace lock is current.
##
##   Part 1 — out-of-closure dirty does NOT block. Make lib-c DIRTY and
##            unpublished. Pushing lib-a (with lib-a + lib-b clean and
##            published) PASSES (exit 0) — lib-c's dirtiness is out of
##            scope. Under the OLD whole-workspace gate this would refuse
##            naming lib-c, so this assertion is falsifiable: revert the
##            scoping and Part 1 fails.
##
##   Part 2 — in-closure dirty DOES block. Make lib-b (in lib-a's closure)
##            dirty and unpublished. Pushing lib-a now FAILS (exit 2) with
##            a failure that NAMES lib-b. This proves the scope is the
##            closure (which includes lib-b), not just the pushed repo.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; no
## network. The manifest layer is a plain directory (not a publishable git
## repo), so the RA-21 loud-on-failure publish path is a benign skip here
## (covered by ``t_pre_push_refuses_when_lock_publish_fails``).
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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA21 Tester\"")
  writeFile(workPath / "README.md", "RA21 fixture\n")
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
    " config user.name \"RA21 Tester\"")

proc commitLocalChange(gitBin, repoPath, message: string): string =
  ## Commit a fresh change without pushing — the resulting HEAD is not
  ## reachable from any remote-tracking branch (unpublished).
  writeFile(repoPath / "local.txt", message & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add local.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m " & q(message))
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "]\n"

# lib-a depends on lib-b → A's closure is {lib-a, lib-b}. lib-c is
# unrelated (no edge) and therefore OUT of scope for a push of lib-a.
const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
depends = ["lib-b"]
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "main"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "lib-c-origin"
revision = "main"
"""

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra21-closure-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libA.name = "lib-a"
  result.libA.origin = result.scratch / "origin-lib-a.git"
  result.libA.seedPath = result.scratch / "seed-lib-a"
  result.libA.sha = seedGitOrigin(gitBin, result.libA.origin,
    result.libA.seedPath)
  result.libB.name = "lib-b"
  result.libB.origin = result.scratch / "origin-lib-b.git"
  result.libB.seedPath = result.scratch / "seed-lib-b"
  result.libB.sha = seedGitOrigin(gitBin, result.libB.origin,
    result.libB.seedPath)
  result.libC.name = "lib-c"
  result.libC.origin = result.scratch / "origin-lib-c.git"
  result.libC.seedPath = result.scratch / "seed-lib-c"
  result.libC.sha = seedGitOrigin(gitBin, result.libC.origin,
    result.libC.seedPath)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectTomlWith3Remotes(
      fileUrl(result.libA.origin),
      fileUrl(result.libB.origin),
      fileUrl(result.libC.origin)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedMetadataBranch(fx: Fixture; branch: string) =
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = branch)

proc writeRefsFile(path: string; localRef, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, localRef & " " & localSha & " " &
    "refs/heads/main " & zeroSha & "\n")

proc invokeWorkspaceLock(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeCheckPrePush(fx: Fixture; currentRepo, refsFile: string):
    CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
    "--json",
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "check-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

suite "RA-21 — pre-push gate scoped to the pushed repo's dependency closure":

  test "t_pre_push_gate_checks_only_pushed_repo_dependency_closure":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "scope")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Lock all three at their published SHAs so the lock is current.
      let lockRes = invokeWorkspaceLock(fx)
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/main", fx.libA.sha)

      # ---- Part 1: out-of-closure dirty does NOT block -------------------
      # lib-c is unrelated to lib-a. Make it dirty AND give it an
      # unpublished commit — the WORST case for the old whole-workspace
      # gate. Pushing lib-a must still PASS.
      discard commitLocalChange(gitBin, fx.workspaceRoot / "lib-c",
        "unpublished out-of-closure commit")
      writeFile(fx.workspaceRoot / "lib-c" / "scratch.txt",
        "uncommitted out-of-closure\n")

      let pass = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      if pass.code != 0:
        checkpoint("Part 1 output: " & pass.output)
      # Falsifiable: the old whole-workspace gate refuses (exit 2) naming
      # lib-c here.
      check pass.code == 0
      let passReport = readReport(fx)
      check passReport["exitCode"].getInt() == 0
      check passReport["failures"].len == 0
      # lib-c must NOT appear in any failure — it is out of scope.
      for failure in passReport["failures"]:
        check failure["repo"].getStr() != "lib-c"

      # ---- Part 2: in-closure dirty DOES block, naming the dep ----------
      # lib-b IS in lib-a's closure. Make it dirty (and unpublished, to be
      # thorough). The gate must now FAIL and name lib-b.
      writeFile(fx.workspaceRoot / "lib-b" / "scratch.txt",
        "uncommitted in-closure\n")

      let blocked = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-a",
        refsFile = refsFile)
      check blocked.code == 2
      let blockedReport = readReport(fx)
      check blockedReport["exitCode"].getInt() == 2
      check blockedReport["failures"].len >= 1
      # The first (short-circuiting) failure names the in-closure dep lib-b.
      let failure = blockedReport["failures"][0]
      check failure["property"].getStr() == "dirty"
      check failure["repo"].getStr() == "lib-b"
      # And lib-c (out of scope) is never the named offender.
      for f in blockedReport["failures"]:
        check f["repo"].getStr() != "lib-c"
