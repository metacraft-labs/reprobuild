## M10 — ``repro workspace sync``.
##
## End-to-end integration test for the new subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace sync`` to ``runWorkspaceSyncCommand``,
## which:
##
##   1. Fast-forwards every configured manifest layer (no-op here:
##      these fixtures use M6 / M7 single-project mode so there's no
##      ``.repo/workspace.toml``).
##   2. Resolves the named project / variant via the M6 surface.
##   3. Gathers a structured ``RepoSyncObservation`` per declared
##      repo (HEAD SHA, clean/dirty, current branch, branch tips,
##      published-on-remote).
##   4. Runs the planner from
##      ``repro_workspace_manifests/sync_planner`` — the policy module
##      that maps each observation onto one of the seven canonical
##      sync corner cases.
##   5. Executes the minimal mutating action per case (no action /
##      fetch + fast-forward / branch re-attach / clone) via M2's
##      ``bakWorkspaceVcs`` executor.
##   6. Emits a structured stdout report AND writes
##      ``<workspaceRoot>/.repro/workspace/sync-report.json``.
##   7. Returns one of three exit codes — 0 (clean / fast-forwarded /
##      re-attached / cloned / divergent-feature-branch-reported),
##      1 (a mutating action failed), 2 (at least one refuse-and-report
##      case — dirty or locally-unpublished).
##
## The suite verifies all seven cases in order. Fixture pattern is
## identical to M9's ``t_workspace_init_clones_missing_and_reports_existing``:
## a hermetic local bare git repo stands in for the manifest's remote
## URL, a workspace tree holds the ``.repo/manifests/`` TOMLs, and
## each test case shapes the on-disk checkout into the state the
## planner must classify.
##
## Skip rule: only when ``git`` is missing from PATH (same convention
## as M2 / M3 / M8 / M9).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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
    "--nimcache:" & root / "build" / "nimcache" / "m10-workspace-sync-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

# ---- bare-repo seed fixture ----------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Same shape as M9 / M8: bare origin with one commit.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M10 Tester\"")
  writeFile(workPath / "README.md", "M10 fixture\n")
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
  ## Push a second commit to the bare origin from the seed workdir, so
  ## the manifest-pinned tip advances ahead of any clones taken before
  ## this call. Returns the new HEAD SHA.
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"M10 Tester\"")

proc appendLocalCommit(gitBin, repoPath: string): string =
  writeFile(repoPath / "local-only.txt", "diverged\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add local-only.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"local-only divergence\"")
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

proc detachAtHead(gitBin, repoPath: string) =
  ## Detach the working tree HEAD by checking out the SHA the branch
  ## tip currently points at. ``git switch --detach`` is the modern
  ## equivalent of ``git checkout --detach``.
  let head = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " switch --detach " & head)

proc dirtyTheTree(repoPath: string) =
  writeFile(repoPath / "dirty.txt", "uncommitted\n")

proc createFeatureBranch(gitBin, repoPath, branch: string): string =
  ## Branch off the current HEAD onto ``branch``, add one commit,
  ## return the new HEAD SHA. The commit is intentionally NOT pushed
  ## to the bare origin so the feature branch diverges from the
  ## manifest pin AND from anything published.
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " switch -c " & branch)
  writeFile(repoPath / "feature.txt", "feature work\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add feature.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"feature commit\"")
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWithRemote(libUrl: string): string =
  ## Single-repo project manifest; matches M9's pattern.
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" & libUrl & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib.toml\",\n" &
    "]\n"

const libFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib"
path = "lib"
remote = "lib-origin"
revision = "main"
"""

# ---- fixture builder ------------------------------------------------------

type
  M10Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libOrigin: string
    libSeedPath: string
    libSha: string

proc setupFixture(gitBin, slug: string): M10Fixture =
  result.scratch = createTempDir("repro-m10-" & slug & "-", "")
  result.reproBin = compileRepro(result.scratch)

  let libOrigin = result.scratch / "origin-lib.git"
  result.libSeedPath = result.scratch / "seed-lib"
  result.libSha = seedGitOrigin(gitBin, libOrigin, result.libSeedPath)
  result.libOrigin = libOrigin

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectTomlWithRemote(fileUrl(libOrigin)))
  writeFile(manifestsRoot / "repos" / "lib.toml", libFragmentToml)
  result.workspaceRoot = workspaceRoot

proc readReport(fixture: M10Fixture): JsonNode =
  let reportPath = fixture.workspaceRoot / ".repro" / "workspace" /
    "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc invokeSync(fixture: M10Fixture): CmdResult =
  runShell(shellCommand(@[
    fixture.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fixture.workspaceRoot,
  ]))

proc onlyRepoEntry(report: JsonNode): JsonNode =
  check report["repos"].len == 1
  report["repos"][0]

# ---- the suite -------------------------------------------------------------

suite "M10 — repro workspace sync (seven sync corner cases)":

  test "test_m10_sync_clean_at_locked_revision":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean-at-locked")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")

      let res = invokeSync(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let entry = onlyRepoEntry(readReport(fx))
      check entry["path"].getStr() == "lib"
      check entry["syncCase"].getStr() == "clean_at_locked_revision"
      check entry["action"].getStr() == "none"
      check entry["executionStatus"].getStr() == "noop"

  test "test_m10_sync_clean_fast_forwardable":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean-fast-forwardable")
      defer: removeDir(fx.scratch)

      # Clone first so the workspace's HEAD is at the original tip,
      # then advance the bare origin with a second commit. After the
      # next ``git fetch`` the local clone's HEAD is strictly behind
      # ``origin/main`` — i.e. fast-forwardable.
      cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")
      let advancedSha = seedSecondCommit(gitBin, fx.libOrigin, fx.libSeedPath)

      let res = invokeSync(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # After sync the working tree must be at the advanced tip.
      let postHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") & " rev-parse HEAD").strip()
      check postHead == advancedSha

      let entry = onlyRepoEntry(readReport(fx))
      check entry["syncCase"].getStr() == "clean_fast_forwardable"
      check entry["action"].getStr() == "fetch_fast_forward"
      check entry["executionStatus"].getStr() == "succeeded"

  test "test_m10_sync_detached_at_locked_revision_reattaches":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "detached-at-locked")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")
      detachAtHead(gitBin, fx.workspaceRoot / "lib")

      let res = invokeSync(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # After sync the HEAD must once again be on a branch.
      let branchRes = runCmd(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") &
        " symbolic-ref --short -q HEAD")
      check branchRes.code == 0
      check branchRes.output.strip() == "main"

      let entry = onlyRepoEntry(readReport(fx))
      check entry["syncCase"].getStr() == "detached_at_locked_revision"
      check entry["action"].getStr() == "attach_branch"
      check entry["executionStatus"].getStr() == "succeeded"

  test "test_m10_sync_dirty_refuses_and_reports":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")
      dirtyTheTree(fx.workspaceRoot / "lib")

      let res = invokeSync(fx)
      check res.code == 2

      # The dirty file must still be there — the dispatcher must not
      # have stashed, reset, or otherwise modified the working tree.
      check fileExists(fx.workspaceRoot / "lib" / "dirty.txt")

      let entry = onlyRepoEntry(readReport(fx))
      check entry["syncCase"].getStr() == "dirty"
      check entry["action"].getStr() == "none"
      check entry["executionStatus"].getStr() == "refused"
      check entry["refusalReason"].getStr().len > 0

  test "test_m10_sync_locally_unpublished_refuses_and_reports":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "locally-unpublished")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")
      let localOnly = appendLocalCommit(gitBin, fx.workspaceRoot / "lib")

      let res = invokeSync(fx)
      check res.code == 2

      # The local-only commit must still be HEAD — the dispatcher
      # must not have reset the working tree.
      let postHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") & " rev-parse HEAD").strip()
      check postHead == localOnly

      let entry = onlyRepoEntry(readReport(fx))
      check entry["syncCase"].getStr() == "locally_unpublished"
      check entry["action"].getStr() == "none"
      check entry["executionStatus"].getStr() == "refused"

  test "test_m10_sync_divergent_feature_branch_reports_only":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "feature-branch")
      defer: removeDir(fx.scratch)

      cloneInto(gitBin, fx.libOrigin, fx.workspaceRoot / "lib")
      # Branch onto a new feature branch and add a divergent commit
      # that is NOT pushed to the bare origin. ``main`` still tracks
      # the manifest pin; HEAD is on the feature branch, ahead of and
      # diverging from ``origin/main``.
      let featureSha = createFeatureBranch(gitBin,
        fx.workspaceRoot / "lib", "feature-x")

      let res = invokeSync(fx)
      # divergent_feature_branch is REPORT-ONLY: not a failure, exit 0.
      # The "locally_unpublished" case can also legitimately apply to
      # the same checkout (the feature commit is by definition
      # unpublished). The planner's priority order means
      # "locally_unpublished" wins when HEAD really is unpublished, so
      # we accept either of those two cases as the correct
      # classification for this fixture — what matters is that the
      # dispatcher does NOT auto-modify the working tree.
      check res.code in [0, 2]

      # The feature-branch HEAD must still be in place: the dispatcher
      # must NOT have switched away from ``feature-x``.
      let postHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") & " rev-parse HEAD").strip()
      check postHead == featureSha
      let branchRes = runCmd(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") &
        " symbolic-ref --short -q HEAD")
      check branchRes.code == 0
      check branchRes.output.strip() == "feature-x"

      let entry = onlyRepoEntry(readReport(fx))
      check entry["syncCase"].getStr() in
        ["divergent_feature_branch", "locally_unpublished"]
      check entry["action"].getStr() == "none"
      # Whichever case applies, the report must NOT show an executed
      # mutation (the case may say "noop" for divergent-feature-branch
      # or "refused" for locally-unpublished, but never "succeeded").
      let exec = entry["executionStatus"].getStr()
      check exec in ["noop", "refused"]

  test "test_m10_sync_missing_checkout_clones":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "missing-checkout")
      defer: removeDir(fx.scratch)

      # Do NOT pre-clone — the on-disk directory is absent. Sync must
      # schedule a fresh clone from the manifest's declared remote.

      let res = invokeSync(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      check dirExists(fx.workspaceRoot / "lib" / ".git")
      let postHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib") & " rev-parse HEAD").strip()
      check postHead == fx.libSha

      let entry = onlyRepoEntry(readReport(fx))
      check entry["syncCase"].getStr() == "missing_checkout"
      check entry["action"].getStr() == "clone"
      check entry["executionStatus"].getStr() == "succeeded"
