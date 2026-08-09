## M28 — ``repro branch <name> --checkout`` marks the workspace as
## having a feature branch in progress.
##
## (Was M16 ``repro branch <name> --checkout``, removed in M28: creating a
## workspace-wide branch IS starting a feature, so the mark moved onto
## ``repro branch`` and the separate verb went away. ``--checkout`` adds the
## switch that ``start`` used to bundle.)
##
## Combines M14 ``repro branch <name>`` (create when missing) with M15
## ``repro switch <branch>`` (switch when present) and ALSO sets the
## ``[workspace].feature_started = true`` mark in
## ``<workspaceRoot>/.repro/workspace.toml`` — see
## ``reprobuild-specs/Workspace-And-Develop-Mode.md`` §"Branch
## Preservation Policy".
##
## The mark used to also suppress the sync planner's "clean fast-forwardable"
## arm on the marked branch. That arm is gone: sync is branch-relative, so a
## repo behind its OWN upstream fast-forwards whether or not the operator
## declared a feature started (declaring one cannot make a teammate's pushed
## commit unwanted). The mark is now workspace metadata that `repro branch` /
## `repro switch` write, preserve and report, with no planner consumer. What
## keeps the sub-cases below at rest is that a workspace-wide feature branch
## created locally has no published upstream yet, so there is nothing to
## fast-forward from.
##
## Sub-cases:
##
##   1. ``test_m16_start_creates_branch_when_missing`` — the branch is
##      absent on every repo. ``switch -b`` creates the branch
##      across the workspace via the M14 path, switches every repo to
##      it via the M15 path, and writes the started mark. Exit 0,
##      ``feature_started = true``, every repo on the new branch.
##   2. ``test_m16_start_switches_when_branch_already_exists`` — the
##      branch is present locally on every repo. ``switch -b``
##      delegates to the M15 ``checkout`` switch path and sets the
##      started mark. Exit 0, ``feature_started = true``.
##   3. ``test_m16_start_refuses_when_any_repo_dirty`` — one dirty
##      sibling. ``switch -b`` refuses with exit 2; no repo is
##      mutated; the metadata is left exactly as it was (no mark
##      written, no branch field updated).
##   4. ``test_m16_start_marks_metadata_so_sync_preserves_branch`` —
##      run ``branch <feature> --checkout`` to mark the workspace, push
##      an advancing commit on the manifest-pinned ``main`` branch so
##      the lock-equivalent (``origin/main``) is ahead, then run
##      ``repro workspace sync``. The feature branch must NOT be
##      reconciled back to the lock tip; the planner must emit
##      ``divergent_feature_branch`` (or refuse) and the executor must
##      NOT switch the working tree off the feature branch. This is the
##      manifest pin NOT dragging a feature branch across — the pin is
##      authoritative for the build input, never a sync target for a
##      checkout deliberately on another branch.
##   5. ``test_m16_start_is_idempotent_for_same_branch`` — running
##      ``branch <name> --checkout`` a second time on a workspace that
##      already has that branch active + marked is a clean no-op
##      (exit 0). Metadata stays byte-identical.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M15).

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
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M16 Tester\"")
  writeFile(workPath / "README.md", "M16 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, originPath, workPath: string;
                      branch = "main"): string =
  ## Push a second commit to the bare origin so the manifest pinned
  ## ``origin/main`` tip advances ahead of the clones taken earlier.
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
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
    " config user.name \"M16 Tester\"")

proc createLocalBranchAtHead(gitBin, repoPath, branchName: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " branch " & branchName)

proc dirtyTheTree(repoPath: string) =
  writeFile(repoPath / "dirty.txt", "uncommitted\n")

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0:
    return ""
  res.output.strip()

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

  M16Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M16Fixture =
  result.scratch = createTempDir("repro-m16-start-" & slug & "-", "")
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
  let manifestsRoot = workspaceRoot
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

proc cloneAll(gitBin: string; fx: M16Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedMetadataBranch(fx: M16Fixture; branch: string) =
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = branch)

proc invokeStart(fx: M16Fixture; name: string): CmdResult =
  # WV-5 — create-and-switch in place is `repro switch -b <name>`.
  runShell(shellCommand(@[
    fx.reproBin, "switch", "--write-report", name, "-b",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeSync(fx: M16Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "--write-report",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: M16Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "switch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc readSyncReport(fx: M16Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc repoEntryByName(report: JsonNode; name: string): JsonNode =
  for entry in report["repos"]:
    if entry["name"].getStr() == name:
      return entry
  newJNull()

# ---- the suite -------------------------------------------------------------

suite "M28/WV-5 — repro switch -b <name> marks feature branch":

  test "test_m28_start_creates_branch_when_missing":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "create")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Branch absent everywhere — CREATE path.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check not localBranchExists(gitBin,
          fx.workspaceRoot / name, "feature-create")

      let res = invokeStart(fx, "feature-create")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["branch"].getStr() == "feature-create"
      check report["recordedBranch"].getStr() == "feature-create"
      check report["featureStarted"].getBool() == true
      check report["repos"].len == 3

      # Every repo is on the new feature branch.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) ==
          "feature-create"
        check localBranchExists(gitBin,
          fx.workspaceRoot / name, "feature-create")

      # Metadata reflects branch + started mark.
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-create"
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true

      # The on-disk workspace.toml carries
      # ``feature_started = true`` under ``[workspace]``.
      let tomlPath = fx.workspaceRoot / ".repro" / "workspace.toml"
      let parsed = readWorkspaceLocal(tomlPath)
      check parsed.workspace.branch.isSome
      check parsed.workspace.branch.get() == "feature-create"
      check parsed.workspace.feature_started.isSome
      check parsed.workspace.feature_started.get() == true

  test "test_m28_start_switches_when_branch_already_exists":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "switch")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Branch present locally on every repo — SWITCH path.
      for name in ["lib-a", "lib-b", "lib-c"]:
        createLocalBranchAtHead(gitBin, fx.workspaceRoot / name,
          "feature-switch")

      let res = invokeStart(fx, "feature-switch")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["branch"].getStr() == "feature-switch"
      check report["recordedBranch"].getStr() == "feature-switch"
      check report["featureStarted"].getBool() == true
      check report["repos"].len == 3
      # Each repo's outcome should be the M15 ``switched`` tag.
      for entry in report["repos"]:
        check entry["outcome"].getStr() == "switched"

      # Every repo is on the requested branch.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) ==
          "feature-switch"

      # Metadata reflects branch + started mark.
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-switch"

  test "test_m28_start_converges_mixed_local_matrix":
    ## An earlier ``switch -b`` interrupted mid-create leaves the
    ## feature branch present (locally, at HEAD) on SOME repos and absent on
    ## the rest, with no remote branch involved. Re-running the identical
    ## command must CONVERGE that partial matrix — create the branch on the
    ## repos still missing it, switch every repo onto it, and set the mark —
    ## rather than refusing it as "mixed".
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "converge")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Purely-local partial matrix: branch present on lib-a and lib-b (at
      # HEAD), absent on lib-c. Never pushed, so no remote branch exists.
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-a",
        "feature-mixed")
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-b",
        "feature-mixed")
      check not localBranchExists(gitBin,
        fx.workspaceRoot / "lib-c", "feature-mixed")

      let res = invokeStart(fx, "feature-mixed")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      # CONVERGE (not "refused", not "create") — the distinguishing mode
      # for finishing a purely-local partial matrix.
      check report["branch"].getStr() == "feature-mixed"
      check report["recordedBranch"].getStr() == "feature-mixed"
      check report["featureStarted"].getBool() == true
      check report["repos"].len == 3

      # The branch now exists on every repo (freshly created on lib-c) and
      # every repo is switched onto it.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check localBranchExists(gitBin, fx.workspaceRoot / name,
          "feature-mixed")
        check currentBranch(gitBin, fx.workspaceRoot / name) ==
          "feature-mixed"

      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-mixed"

  test "test_m28_start_refuses_mixed_when_remote_branch_involved":
    ## When the mixed matrix involves a REMOTE branch — some repo already
    ## carries the branch on its remote while another lacks it entirely —
    ## the intent (adopt the remote branch vs. create fresh) is genuinely
    ## ambiguous, so ``start`` must still refuse cleanly (exit 2).
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "converge-remote")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # lib-a: branch present ONLY on its remote. lib-b/lib-c: absent
      # everywhere. Mixed WITH a remote → ambiguous → refuse.
      #
      # `start` probes the remote under the manifest's remote name
      # (``gitRemoteNameFor`` → "lib-a-origin"), but the fixture clone names
      # its remote "origin"; add the manifest-named remote (same bare repo)
      # so the probe resolves regardless of which name the resolver returns.
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " remote add lib-a-origin " & q(fileUrl(fx.libA.origin)))
      createLocalBranchAtHead(gitBin, fx.workspaceRoot / "lib-a",
        "feature-remote")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " push origin feature-remote")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " branch -D feature-remote")

      let res = invokeStart(fx, "feature-remote")
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["featureStarted"].getBool() == false

  test "test_m28_start_refuses_when_any_repo_dirty":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")
      # Pre-create the feature branch on every repo so the only
      # blocker is lib-b being dirty (this targets the SWITCH-side
      # refuse, which mirrors M15's policy).
      for name in ["lib-a", "lib-b", "lib-c"]:
        createLocalBranchAtHead(gitBin, fx.workspaceRoot / name,
          "feature-dirty")
      dirtyTheTree(fx.workspaceRoot / "lib-b")

      let res = invokeStart(fx, "feature-dirty")
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      # Metadata stayed as it was before — no started mark written.
      check report["recordedBranch"].getStr() == "main"
      check report["featureStarted"].getBool() == false
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == false

      let entryB = repoEntryByName(report, "lib-b")
      check entryB["outcome"].getStr() == "dirty_refused"
      check entryB["dirtyReason"].getStr().len > 0

      # No repo was switched: every repo is still on ``main``, and
      # the dirty file in lib-b is intact.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) == "main"
      check fileExists(fx.workspaceRoot / "lib-b" / "dirty.txt")

      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "main"

  test "test_m28_start_marks_metadata_so_sync_preserves_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "sync-preserves")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # Step 1: start the feature. Branch absent everywhere → CREATE.
      let startRes = invokeStart(fx, "feature-preserved")
      if startRes.code != 0:
        checkpoint("start output: " & startRes.output)
      check startRes.code == 0
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true

      # Step 2: advance the origin's ``main`` to put the lock-pinned
      # tip ahead of HEAD on the feature branch. The feature branch has
      # no published upstream of its own, so there is nothing to
      # fast-forward FROM, and the manifest's advanced ``main`` is not a
      # sync target for a checkout on another branch: sync must NO-OP.
      for seed in [fx.libA, fx.libB, fx.libC]:
        discard seedSecondCommit(gitBin, seed.origin, seed.seedPath)

      # Capture the HEAD on the feature branch BEFORE sync so we can
      # verify it does not move.
      var preHeads: Table[string, string]
      for name in ["lib-a", "lib-b", "lib-c"]:
        preHeads[name] = requireGit(q(gitBin) & " -C " &
          q(fx.workspaceRoot / name) & " rev-parse HEAD").strip()

      # Step 3: run sync. The marked feature branch must be preserved
      # — the planner should classify "divergent_feature_branch"
      # (report-only, exit 0) instead of "clean_fast_forwardable".
      let syncRes = invokeSync(fx)
      # The marked feature branch case is REPORT-ONLY: exit 0. We
      # also accept exit 2 (refuse-and-report) in case the planner's
      # ``locally_unpublished`` arm fires first — what matters is
      # that the executor does NOT switch the working tree off the
      # feature branch.
      check syncRes.code in [0, 2]

      # The feature branch is still active on every repo and HEAD
      # has not moved.
      for name in ["lib-a", "lib-b", "lib-c"]:
        check currentBranch(gitBin, fx.workspaceRoot / name) ==
          "feature-preserved"
        let postHead = requireGit(q(gitBin) & " -C " &
          q(fx.workspaceRoot / name) & " rev-parse HEAD").strip()
        check postHead == preHeads[name]

      # The sync report must NOT carry ``executionStatus = succeeded``
      # for ANY repo — succeeded would mean a fast-forward landed, and
      # the only candidate target here is the manifest's advanced
      # ``main``, which this checkout is not on.
      let syncReport = readSyncReport(fx)
      for entry in syncReport["repos"]:
        let exec = entry["executionStatus"].getStr()
        check exec in ["noop", "refused"]
        let syncCaseStr = entry["syncCase"].getStr()
        check syncCaseStr != "clean_fast_forwardable"

      # Metadata still carries the started mark after sync.
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true

  test "test_m28_start_is_idempotent_for_same_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "idempotent")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      seedMetadataBranch(fx, "main")

      # First invocation creates the branch + marks it.
      let firstRes = invokeStart(fx, "feature-idem")
      if firstRes.code != 0:
        checkpoint("first output: " & firstRes.output)
      check firstRes.code == 0
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true
      let firstReport = readReport(fx)

      let tomlPath = fx.workspaceRoot / ".repro" / "workspace.toml"
      let firstBytes = readFile(tomlPath)

      # Second invocation: every repo is already on the requested
      # branch, branch present locally on every repo → SWITCH path
      # (which inside M15 yields the ``already_on_branch`` no-op
      # outcome). Exit code stays 0; the started mark stays set;
      # the workspace.toml is byte-identical.
      let secondRes = invokeStart(fx, "feature-idem")
      if secondRes.code != 0:
        checkpoint("second output: " & secondRes.output)
      check secondRes.code == 0

      let secondReport = readReport(fx)
      check secondReport["exitCode"].getInt() == 0
      check secondReport["branch"].getStr() == "feature-idem"
      check secondReport["featureStarted"].getBool() == true
      check secondReport["recordedBranch"].getStr() == "feature-idem"
      for entry in secondReport["repos"]:
        # Every repo was already on the branch — the M15 inner helper
        # returns ``already_on_branch`` for each.
        check entry["outcome"].getStr() == "already_on_branch"

      # The metadata reads as before and the bytes round-trip
      # byte-identical (the serializer is deterministic and the
      # serializer-input is unchanged between calls).
      let secondBytes = readFile(tomlPath)
      check firstBytes == secondBytes
      check readWorkspaceFeatureStarted(fx.workspaceRoot) == true
      let recorded = readWorkspaceBranch(fx.workspaceRoot)
      check recorded.isSome
      check recorded.get() == "feature-idem"
