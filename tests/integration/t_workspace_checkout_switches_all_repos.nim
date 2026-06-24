## M15 — ``repro checkout <branch>`` workspace-wide switch.
##
## Drives the compiled ``repro`` binary against a hermetic three-repo
## workspace. Sub-cases (every one is its own ``test_m15_*`` block):
##
##   1. ``test_m15_checkout_switches_all_repos_to_existing_local_branch``
##      Every repo has the branch locally — all three switch to it, the
##      M13 metadata's ``[workspace].branch`` is updated to the new
##      name, exit 0.
##   2. ``test_m15_checkout_creates_tracking_branch_when_missing_locally``
##      One repo has the branch only on ``origin`` — the fetch +
##      tracking + switch chain runs and that repo lands on the branch
##      alongside the others, exit 0.
##   3. ``test_m15_checkout_refuses_when_branch_missing_in_any_repo``
##      One repo's working tree lacks the branch locally AND remotely
##      — exit 2, no mutation, M13 metadata untouched.
##   4. ``test_m15_checkout_refuses_when_any_repo_dirty``
##      One dirty sibling — exit 2, no repo mutated, dirty file
##      preserved, M13 metadata untouched.
##   5. ``test_m15_checkout_records_new_branch_in_metadata``
##      Verifies ``[workspace].branch`` is updated after a successful
##      checkout, both via the M13 reader and the on-disk
##      ``workspace.toml``.
##   6. ``test_m15_checkout_idempotent_when_already_on_branch``
##      Running checkout to the branch every repo is already on is a
##      no-op success, exit 0, no actions scheduled.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M14).

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

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Seed an origin bare repo and a corresponding work-tree on the
  ## named primary branch. Returns the HEAD SHA on that branch.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M15 Tester\"")
  writeFile(workPath / "README.md", "M15 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedRemoteBranch(gitBin, originPath, seedPath, branch: string) =
  ## Push ``branch`` to the named origin from its seed work-tree. The
  ## branch is created off the current HEAD if it does not already
  ## exist. Used by the "branch only on origin" fixture variant.
  let branchExists = runCmd(q(gitBin) & " -C " & q(seedPath) &
    " rev-parse --verify --quiet refs/heads/" & branch).code == 0
  if not branchExists:
    discard requireGit(q(gitBin) & " -C " & q(seedPath) &
      " branch " & branch)
  discard requireGit(q(gitBin) & " -C " & q(seedPath) &
    " push origin " & branch)

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"M15 Tester\"")

proc createLocalBranchAtHead(gitBin, repoPath, branchName: string) =
  ## ``git branch <name>`` — creates a new branch from current HEAD
  ## without switching to it. Used to set up the "local branch
  ## already exists" classification.
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " branch " & branchName)

proc switchTo(gitBin, repoPath, branchName: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " switch " & branchName)

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

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0:
    return ""
  res.output.strip()

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

  M15Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M15Fixture =
  result.scratch = createTempDir("repro-m15-checkout-" & slug & "-", "")
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

proc cloneAll(gitBin: string; fx: M15Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedMetadataBranch(fx: M15Fixture; branch: string) =
  ## M15 expects a project resolvable via the M14 dispatch rules. A
  ## metadata-only workspace.toml supplying ``project = "lib-a"`` is
  ## the cheapest way to satisfy ``resolveCheckoutProject`` without
  ## going through ``workspace init``.
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = branch)

proc invokeCheckout(fx: M15Fixture; name: string): CmdResult =
  # RA-9: ``checkout`` switches working trees, so it is a destructive
  # multi-repo command and refuses in a non-interactive context (the
  # natural state here) without ``--yes``. These cases exercise the
  # post-confirmation switch outcomes, so they opt out with ``--yes``;
  # the dedicated RA-9 suite covers the non-TTY refuse path.
  runShell(shellCommand(@[
    fx.reproBin, "checkout", name, "--yes",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: M15Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "checkout-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntryByName(report: JsonNode; name: string): JsonNode =
  for entry in report["repos"]:
    if entry["name"].getStr() == name:
      return entry
  newJNull()

# ---- the suite -------------------------------------------------------------

suite "M15 — repro checkout <branch> switches all repos":

  test "test_m15_checkout_switches_all_repos_to_existing_local_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "all-local")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # In every repo, pre-create the branch we will switch TO.
      # Without this the switch would refuse for lack of either a
      # local OR a remote branch.
      for name in ["lib-a", "lib-b", "lib-c"]:
        createLocalBranchAtHead(gitBin, fx.workspaceRoot / name,
          "feature-x")

      let res = invokeCheckout(fx, "feature-x")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["branch"].getStr() == "feature-x"
      check report["recordedBranch"].getStr() == "feature-x"
      check report["repos"].len == 3
      for entry in report["repos"]:
        check entry["outcome"].getStr() == "switched"
        check entry["newBranch"].getStr() == "feature-x"
        check entry["previousBranch"].getStr() == "main"
        check entry["localHadBranch"].getBool() == true

      # Every repo is now on the new branch.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "feature-x"

      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-x"

  test "test_m15_checkout_creates_tracking_branch_when_missing_locally":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "fetch-and-track")
      defer: removeDir(fx.scratch)

      # Seed ``feature-remote`` on the lib-b origin BEFORE cloning so
      # the clones pick up only ``main`` (DWIM-able remote-only ref
      # for lib-b).
      seedRemoteBranch(gitBin, fx.libB.origin, fx.libB.seedPath,
        "feature-remote")
      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # lib-a and lib-c need the branch locally (no fetch chain). lib-b
      # is the fetch-and-track case: branch absent locally, present on
      # origin.
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-a",
        "feature-remote")
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-c",
        "feature-remote")
      check not localBranchExists(gitBin,
        fx.workspaceRoot / "lib-b", "feature-remote")

      let res = invokeCheckout(fx, "feature-remote")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["branch"].getStr() == "feature-remote"
      check report["recordedBranch"].getStr() == "feature-remote"

      let entryA = repoEntryByName(report, "lib-a")
      let entryB = repoEntryByName(report, "lib-b")
      let entryC = repoEntryByName(report, "lib-c")
      check entryA["outcome"].getStr() == "switched"
      check entryC["outcome"].getStr() == "switched"
      check entryB["outcome"].getStr() == "fetched_and_switched"
      check entryB["remoteHadBranch"].getBool() == true
      check entryB["localHadBranch"].getBool() == false

      # All three repos now sit on the new branch on disk.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) ==
          "feature-remote"
      # lib-b's branch is now a local one (tracking the remote).
      check localBranchExists(gitBin,
        fx.workspaceRoot / "lib-b", "feature-remote")

      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-remote"

  test "test_m15_checkout_refuses_when_branch_missing_in_any_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "missing-branch")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # lib-a + lib-c have the branch locally; lib-b does NOT (and the
      # origin does not carry it either) — refuse-and-report.
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-a",
        "feature-gap")
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-c",
        "feature-gap")

      let res = invokeCheckout(fx, "feature-gap")
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["branch"].getStr() == "feature-gap"
      check report["recordedBranch"].getStr() == "main"

      let entryA = repoEntryByName(report, "lib-a")
      let entryB = repoEntryByName(report, "lib-b")
      let entryC = repoEntryByName(report, "lib-c")
      check entryB["outcome"].getStr() == "branch_missing_refused"
      check entryB["diagnostic"].getStr().len > 0
      check entryB["remoteHadBranch"].getBool() == false
      check entryB["localHadBranch"].getBool() == false
      # The ready siblings report ``ready_local`` (not ``switched``)
      # — refuse-and-report mutated nothing.
      check entryA["outcome"].getStr() == "ready_local"
      check entryC["outcome"].getStr() == "ready_local"

      # No repo was actually switched.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "main"

      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"

  test "test_m15_checkout_refuses_when_any_repo_dirty":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Every repo has the destination branch locally — the only
      # blocker is lib-b being dirty.
      for name in ["lib-a", "lib-b", "lib-c"]:
        createLocalBranchAtHead(gitBin, fx.workspaceRoot / name,
          "feature-y")
      dirtyTheTree(fx.workspaceRoot / "lib-b")

      let res = invokeCheckout(fx, "feature-y")
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["recordedBranch"].getStr() == "main"

      let entryB = repoEntryByName(report, "lib-b")
      check entryB["outcome"].getStr() == "dirty_refused"
      check entryB["dirtyReason"].getStr().len > 0

      # Clean siblings report ``ready_local`` (nothing was scheduled).
      let entryA = repoEntryByName(report, "lib-a")
      let entryC = repoEntryByName(report, "lib-c")
      check entryA["outcome"].getStr() == "ready_local"
      check entryC["outcome"].getStr() == "ready_local"

      # No repo was switched: current branch is still ``main``
      # everywhere, and the dirty file is intact in lib-b.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "main"
      check fileExists(fx.workspaceRoot / "lib-b" / "dirty.txt")

      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"

  test "test_m15_checkout_records_new_branch_in_metadata":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "metadata")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")
      for name in ["lib-a", "lib-b", "lib-c"]:
        createLocalBranchAtHead(gitBin, fx.workspaceRoot / name,
          "feature-meta")

      let res = invokeCheckout(fx, "feature-meta")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # M13 reader sees the new value.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-meta"

      # The on-disk workspace.toml carries the new value under
      # ``[workspace].branch`` (still a metadata-only file — we did
      # not promote it to composer mode).
      let tomlPath = fx.workspaceRoot / ".repo" / "workspace.toml"
      let parsed = readWorkspaceLocal(tomlPath)
      check parsed.workspace.project == "lib-a"
      check parsed.workspace.branch.isSome
      check parsed.workspace.branch.get() == "feature-meta"
      check parsed.manifest.len == 0
      check isCompositionalWorkspaceToml(fx.workspaceRoot) == false

      # JSON report exposes the same value via ``recordedBranch``.
      let report = readReport(fx)
      check report["branch"].getStr() == "feature-meta"
      check report["recordedBranch"].getStr() == "feature-meta"
      check report["exitCode"].getInt() == 0

  test "test_m15_checkout_idempotent_when_already_on_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "idempotent")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")
      # No new branch is created — every repo stays on ``main``.
      # ``repro checkout main`` should be a clean no-op.

      let res = invokeCheckout(fx, "main")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["branch"].getStr() == "main"
      check report["recordedBranch"].getStr() == "main"
      for entry in report["repos"]:
        check entry["outcome"].getStr() == "already_on_branch"
        check entry["previousBranch"].getStr() == "main"
        check entry["newBranch"].getStr() == "main"

      # Every repo is still on ``main`` (and there's still no
      # branch-level surprise).
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "main"

      # Metadata remains ``main`` — the writer is called either way,
      # the value is unchanged.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"
