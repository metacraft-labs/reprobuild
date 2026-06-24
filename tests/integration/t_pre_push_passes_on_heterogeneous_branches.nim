## RA-3 — ``repro check --mode=pre-push`` publication gate, no
## branch-name enforcement.
##
## repo-workspaces removed the gate's branch-mismatch stage (commits
## ``b5a823a`` / ``ff76825``): heterogeneous per-class branch policies
## are first-class (product repos on ``dev``, spec repos on ``latest``,
## infra on ``live``), and the lock pins commit SHAs so the published
## state is reproducible regardless of which branch each repo is on.
##
## This test sets up three sibling repos on DIFFERENT branches
## (``dev`` / ``latest`` / ``live``) that are all clean, published and
## locked, then pushes from ``lib-c`` (on ``live``) while the recorded
## workspace metadata branch is ``dev``. Under the OLD code the
## branch-mismatch stage compared the pushed branch (``live``) against
## the active workspace branch (``dev``) and refused with exit 2; under
## RA-3 the gate ignores branch names entirely and PASSES (exit 0).
##
## Falsifiability: with the branch-mismatch stage present this test sees
## exit 2 + a ``branch-mismatch`` failure; with the stage removed it
## sees exit 0 and zero failures.
##
## Skip rule: ``git`` missing on PATH (same convention as M9-M17).

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
                   branch: string): string =
  ## Bare origin with one commit on ``branch`` (the default branch of
  ## the bare repo is set to ``branch`` so a clone checks it out).
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA3 Tester\"")
  writeFile(workPath / "README.md", "RA3 fixture\n")
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
    " config user.name \"RA3 Tester\"")

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  ## Heterogeneous per-repo revisions: ``dev`` / ``latest`` / ``live``.
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"lib-a\"\n" &
    "default_revision = \"dev\"\n" &
    "trunk = \"dev\"\n\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-c-origin\"\nfetch = \"" & libCUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-a.toml\",\n" &
    "  \"repos/lib-b.toml\",\n" &
    "  \"repos/lib-c.toml\",\n" &
    "]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "dev"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "lib-b-origin"
revision = "latest"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "lib-c-origin"
revision = "live"
"""

type
  RepoSeed = object
    name: string
    branch: string
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
  result.scratch = createTempDir("repro-ra3-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libA.name = "lib-a"
  result.libA.branch = "dev"
  result.libA.origin = result.scratch / "origin-lib-a.git"
  result.libA.seedPath = result.scratch / "seed-lib-a"
  result.libA.sha = seedGitOrigin(gitBin, result.libA.origin,
    result.libA.seedPath, "dev")

  result.libB.name = "lib-b"
  result.libB.branch = "latest"
  result.libB.origin = result.scratch / "origin-lib-b.git"
  result.libB.seedPath = result.scratch / "seed-lib-b"
  result.libB.sha = seedGitOrigin(gitBin, result.libB.origin,
    result.libB.seedPath, "latest")

  result.libC.name = "lib-c"
  result.libC.branch = "live"
  result.libC.origin = result.scratch / "origin-lib-c.git"
  result.libC.seedPath = result.scratch / "seed-lib-c"
  result.libC.sha = seedGitOrigin(gitBin, result.libC.origin,
    result.libC.seedPath, "live")

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
  ## Each clone checks out its origin's default branch, so the three
  ## siblings end up on ``dev`` / ``latest`` / ``live`` respectively.
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc currentBranch(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD").strip()

proc seedMetadataBranch(fx: Fixture; branch: string) =
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = branch)

proc writeRefsFile(path: string; localRef, localSha: string) =
  let zeroSha = "0000000000000000000000000000000000000000"
  writeFile(path, localRef & " " & localSha & " " &
    "refs/heads/live " & zeroSha & "\n")

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

suite "RA-3 — pre-push gate: no branch-name enforcement":

  test "t_pre_push_passes_on_heterogeneous_branches":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "heterogeneous")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)

      # The three siblings are genuinely on different branches.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "dev"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == "latest"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-c") == "live"

      # Record the workspace metadata branch as ``dev`` (the product
      # default). The push will come from lib-c, which is on ``live`` —
      # under the OLD branch-mismatch stage this is a refusal.
      seedMetadataBranch(fx, "dev")

      # Seed the workspace lock so the gate finds it already-current
      # (all three siblings clean + published at their locked SHAs).
      let lockRes = invokeWorkspaceLock(fx)
      if lockRes.code != 0:
        checkpoint("workspace lock output: " & lockRes.output)
      check lockRes.code == 0

      # Push lib-c on branch ``live`` while the active workspace branch
      # is ``dev``.
      let refsFile = fx.scratch / "pushed-refs.txt"
      writeRefsFile(refsFile, "refs/heads/live", fx.libC.sha)

      let res = invokeCheckPrePush(fx,
        currentRepo = fx.workspaceRoot / "lib-c",
        refsFile = refsFile)
      if res.code != 0:
        checkpoint("output: " & res.output)
      # RA-3: the gate must PASS despite the branch mismatch.
      check res.code == 0

      let report = readReport(fx)
      check report["mode"].getStr() == "pre-push"
      check report["exitCode"].getInt() == 0
      check report["failures"].len == 0
      # The branch fields are still observed (informational), proving
      # the mismatch is real but no longer gates.
      check report["pushedBranch"].getStr() == "live"
      check report["activeBranch"].getStr() == "dev"
      # No failure carries the retired ``branch-mismatch`` property.
      for failure in report["failures"]:
        check failure["property"].getStr() != "branch-mismatch"
