## M14 — ``repro branch <name>`` refuse-and-collision policy.
##
## Drives the compiled ``repro`` binary against a hermetic three-repo
## workspace. Sub-cases:
##
##   1. **Clean workspace, fresh branch name** — every repo creates the
##      branch from its current HEAD via the M2 ``gitBranchCreate``
##      action, the M13 metadata's ``[workspace].branch`` is updated to
##      the new name, exit 0.
##   2. **One dirty sibling** — refuse with exit 2. The clean repos
##      MUST NOT receive the new branch (the operator's "fix the
##      blocker and re-run" loop is atomic). The dirty repo's working
##      tree is untouched.
##   3. **Branch-name collision at a different SHA** — exit 2. No repo
##      gets the branch. The collision is reported per-repo with the
##      existing SHA.
##   4. **Branch-name collision at the same HEAD** — idempotent
##      success path. The other repos still create the branch, the
##      collision repo reports ``already_at_head``, exit 0.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M13).

import std/[json, options, os, osproc, strutils, tables, tempfiles,
    unittest]

import repro_test_support
import repro_workspace_manifests

# ---- repro binary build ---------------------------------------------------

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

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m14-branch-refuse-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M14 Tester\"")
  writeFile(workPath / "README.md", "M14 fixture\n")
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
    " config user.name \"M14 Tester\"")

proc dirtyTheTree(repoPath: string) =
  writeFile(repoPath / "dirty.txt", "uncommitted\n")

proc branchSha(gitBin, repoPath, branchName: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse --verify --quiet refs/heads/" & branchName)
  if res.code != 0:
    return ""
  res.output.strip()

proc localBranchExists(gitBin, repoPath, branchName: string): bool =
  branchSha(gitBin, repoPath, branchName).len > 0

# ---- manifest TOML strings ------------------------------------------------

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

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
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

# ---- fixture builder ------------------------------------------------------

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  M14Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M14Fixture =
  result.scratch = createTempDir("repro-m14-refuse-" & slug & "-", "")
  result.reproBin = compileRepro(result.scratch)

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

proc cloneAll(gitBin: string; fx: M14Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedMetadataBranch(fx: M14Fixture; branch: string) =
  ## M14 expects a project resolvable in single-project mode. A
  ## metadata-only workspace.toml supplying ``project = "lib-a"``
  ## (and a recorded branch) is the cheapest way to satisfy
  ## ``resolveBranchProject`` without going through ``workspace
  ## init``. The recorded branch matches the seed origin's ``main``
  ## branch so the show form has a sensible default in every
  ## sub-case.
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = branch)

proc invokeBranch(fx: M14Fixture; name: string): CmdResult =
  if name.len == 0:
    runShell(shellCommand(@[
      fx.reproBin, "branch",
      "--workspace-root=" & fx.workspaceRoot,
    ]))
  else:
    runShell(shellCommand(@[
      fx.reproBin, "branch", name,
      "--workspace-root=" & fx.workspaceRoot,
    ]))

proc readReport(fx: M14Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "branch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntryByName(report: JsonNode; name: string): JsonNode =
  for entry in report["repos"]:
    if entry["name"].getStr() == name:
      return entry
  newJNull()

# ---- the suite -------------------------------------------------------------

suite "M14 — repro branch <name> refuses on any dirty sibling":

  test "test_m14_clean_workspace_creates_branch_across_all_repos":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      let res = invokeBranch(fx, "feature-x")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["form"].getStr() == "create"
      check report["branch"].getStr() == "feature-x"
      check report["recordedBranch"].getStr() == "feature-x"
      check report["repos"].len == 3
      for entry in report["repos"]:
        check entry["outcome"].getStr() == "created"

      # Every repo must now carry the new branch at HEAD.
      for name in ["lib-a", "lib-b", "lib-c"]:
        let repoPath = fx.workspaceRoot / name
        check localBranchExists(gitBin, repoPath, "feature-x")
        # The new branch points at HEAD (we did NOT switch — the
        # current branch should still be ``main`` in every repo).
        let head = requireGit(q(gitBin) & " -C " & q(repoPath) &
          " rev-parse HEAD").strip()
        check branchSha(gitBin, repoPath, "feature-x") == head
        let current = requireGit(q(gitBin) & " -C " & q(repoPath) &
          " symbolic-ref --short HEAD").strip()
        check current == "main"

      # M13 metadata must record the new branch.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-x"

  test "test_m14_one_dirty_sibling_refuses_and_no_repo_modified":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")
      dirtyTheTree(fx.workspaceRoot / "lib-b")

      let res = invokeBranch(fx, "feature-y")
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["form"].getStr() == "create"
      check report["branch"].getStr() == "feature-y"
      # Metadata MUST NOT have been touched — refuse-and-report
      # leaves the workspace exactly as it was.
      check report["recordedBranch"].getStr() == "main"

      # Per-repo classification: lib-a + lib-c are ``ready``; lib-b
      # is ``dirty_refused``.
      let entryB = repoEntryByName(report, "lib-b")
      check entryB.kind == JObject
      check entryB["outcome"].getStr() == "dirty_refused"
      check entryB["dirtyReason"].getStr().len > 0
      let entryA = repoEntryByName(report, "lib-a")
      let entryC = repoEntryByName(report, "lib-c")
      check entryA["outcome"].getStr() == "ready"
      check entryC["outcome"].getStr() == "ready"

      # No repo was actually mutated: the new branch must NOT exist
      # in any repo.
      for name in ["lib-a", "lib-b", "lib-c"]:
        let repoPath = fx.workspaceRoot / name
        check not localBranchExists(gitBin, repoPath, "feature-y")

      # Dirty file is intact — the command must not have touched
      # the working tree.
      check fileExists(fx.workspaceRoot / "lib-b" / "dirty.txt")

      # Metadata branch field still points at "main".
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"

  test "test_m14_branch_collision_at_different_sha_refuses":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "collision-diff")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # In lib-b, create the colliding branch at a *different*
      # commit so the collision is genuine. Easiest: make a second
      # commit on a side branch, leave HEAD on main, then point
      # ``feature-z`` at the side commit.
      let libB = fx.workspaceRoot / "lib-b"
      writeFile(libB / "side.txt", "side\n")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " add side.txt")
      discard requireGit(q(gitBin) & " -C " & q(libB) &
        " commit -m \"side-commit\"")
      let sideSha = requireGit(q(gitBin) & " -C " & q(libB) &
        " rev-parse HEAD").strip()
      # Reset HEAD back to the original (so main still points at the
      # seed commit). ``--keep`` is safe — index + working tree are
      # both consistent after the commit just landed.
      discard requireGit(q(gitBin) & " -C " & q(libB) &
        " reset --hard " & q(fx.libB.sha))
      # Now create the colliding branch pointing at the side commit.
      discard requireGit(q(gitBin) & " -C " & q(libB) &
        " branch feature-z " & q(sideSha))
      check branchSha(gitBin, libB, "feature-z") == sideSha
      check branchSha(gitBin, libB, "feature-z") != fx.libB.sha

      let res = invokeBranch(fx, "feature-z")
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      let entryB = repoEntryByName(report, "lib-b")
      check entryB["outcome"].getStr() == "collision_refused"
      check entryB["existingSha"].getStr() == sideSha
      check entryB["headSha"].getStr() == fx.libB.sha
      # The clean repos report ``ready`` (not ``created``) — refuse
      # means nothing was scheduled.
      let entryA = repoEntryByName(report, "lib-a")
      let entryC = repoEntryByName(report, "lib-c")
      check entryA["outcome"].getStr() == "ready"
      check entryC["outcome"].getStr() == "ready"

      # lib-a / lib-c must NOT have grown a new branch.
      check not localBranchExists(gitBin,
        fx.workspaceRoot / "lib-a", "feature-z")
      check not localBranchExists(gitBin,
        fx.workspaceRoot / "lib-c", "feature-z")
      # lib-b's pre-existing colliding branch is still on disk and
      # still points at sideSha — we didn't move it.
      check branchSha(gitBin, libB, "feature-z") == sideSha

      # Metadata unchanged.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"

  test "test_m14_branch_collision_at_head_is_idempotent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "collision-head")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # In lib-b, pre-create the branch already pointing at HEAD.
      # This is the idempotent re-run case: somebody already made
      # the branch in one repo, the operator now wants it propagated
      # to the rest of the workspace, and the existing branch should
      # be accepted as-is rather than refused.
      let libB = fx.workspaceRoot / "lib-b"
      discard requireGit(q(gitBin) & " -C " & q(libB) &
        " branch feature-w")
      check branchSha(gitBin, libB, "feature-w") == fx.libB.sha

      let res = invokeBranch(fx, "feature-w")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      let entryB = repoEntryByName(report, "lib-b")
      check entryB["outcome"].getStr() == "already_at_head"
      check entryB["existingSha"].getStr() == fx.libB.sha
      let entryA = repoEntryByName(report, "lib-a")
      let entryC = repoEntryByName(report, "lib-c")
      check entryA["outcome"].getStr() == "created"
      check entryC["outcome"].getStr() == "created"

      # Every repo now carries the branch.
      for name in ["lib-a", "lib-b", "lib-c"]:
        let repoPath = fx.workspaceRoot / name
        check localBranchExists(gitBin, repoPath, "feature-w")

      # Metadata records the new branch.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-w"
