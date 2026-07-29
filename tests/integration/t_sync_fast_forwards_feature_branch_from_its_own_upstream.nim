## ``repro workspace sync`` is BRANCH-RELATIVE: the fast-forward target is
## the checked-out branch's OWN upstream, never the manifest's pinned
## revision.
##
## Spec: CLI/sync.md — "Branch-Aware Sync Policy" + "Conservative Divergence
## Handling". Syncing the trunk and syncing a feature branch are the SAME
## operation; only which ref is upstream differs. The lock stays authoritative
## for the BUILD input, but it is not the sync target for a checkout that is
## deliberately on another branch.
##
## The regression this pins down: the planner's fast-forward arm used to
## require ``remoteBranchTip == lockedTip`` — i.e. the tip of
## ``origin/<current branch>`` had to equal the tip the MANIFEST pinned. That
## holds only when the checked-out branch IS the manifest's branch, so a repo
## on a feature branch could never fast-forward from its own upstream and a
## teammate's pushed commits never arrived. The whole workspace silently
## stopped collaborating the moment anyone left the trunk.
##
## Four sibling repos, all pinned to ``dev`` by the manifest:
##
##   1. ``lib-a`` on ``feature/team``  — a TEAMMATE pushed one commit to
##      ``origin/feature/team``; the local checkout is strictly behind it and
##      clean. Sync MUST fast-forward it and materialize the teammate's file.
##      ``origin/feature/team`` is NOT ``origin/dev``, so this is exactly the
##      configuration the old rule could not act on.
##   2. ``lib-b`` on ``feature/mine`` — upstream advanced AND the operator has
##      one local unpublished commit, so the branch is DIVERGED. Sync must
##      refuse-and-report: HEAD unchanged, the local commit intact, and the
##      teammate's file absent.
##   3. ``lib-c`` on ``feature/idle`` — a non-manifest branch already AT its
##      own upstream tip. Nothing to fast-forward, so sync must leave it
##      exactly where it is (report-only) and must not invent an action.
##   4. ``lib-d`` on ``dev``          — the trunk case, where the current
##      branch and the manifest's revision coincide. It must still
##      fast-forward: the new rule is a generalization, not a replacement.
##
## Assertions:
##   - lib-a HEAD == the teammate's pushed SHA; ``teammate.txt`` exists with
##     the teammate's content; branch is still ``feature/team``.
##   - lib-a's report entry: ``syncCase = clean_fast_forwardable``,
##     ``executionStatus = succeeded``, and its recorded ``branch`` is
##     ``feature/team`` (not ``dev``) — the sync was keyed to the branch.
##   - lib-b HEAD == the local unpublished SHA; ``teammate.txt`` absent;
##     ``syncCase`` is ``locally_unpublished`` and ``action = none``.
##   - lib-c HEAD unchanged and ``action = none``.
##   - lib-d HEAD == its advanced ``origin/dev`` tip with
##     ``syncCase = clean_fast_forwardable``.
##   - Every repo's manifest revision is ``dev`` while three of the four are
##     on some other branch — proving the pins really do disagree with the
##     checkouts.
##
## Falsifiability:
##   - Under the OLD rule lib-a is classified ``divergent_feature_branch``
##     with ``action = none`` and its HEAD does not move, because
##     ``origin/feature/team`` != ``origin/dev``. This test asserts the
##     CONJUNCTION "branch != manifest revision" AND "HEAD advanced to the
##     branch's own upstream", which the old rule cannot satisfy for any
##     repo. lib-c is the control for the same condition with nothing to
##     fast-forward: same branch/pin disagreement, no movement, so a
##     hypothetical "fast-forward everything unconditionally" implementation
##     that ignored reachability would be caught by lib-b instead.
##   - If the guard had merely been widened to "any clean checkout", lib-b
##     would be force-updated and its local commit lost — asserted against
##     directly.
##   - If the branch-relative arm regressed to trunk-only, lib-d would still
##     pass but lib-a would not; if it regressed to feature-only, lib-d fails.
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

proc git(gitBin, repoPath, argv: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " " & argv)

proc seedTrunk(gitBin, originPath, workPath: string): string =
  ## A bare origin with a single ``dev`` commit plus a working seed clone we
  ## can push further branches from.
  discard requireGit(q(gitBin) & " init --bare -b dev " & q(originPath))
  discard requireGit(q(gitBin) & " init -b dev " & q(workPath))
  discard git(gitBin, workPath, "config user.email tester@example.invalid")
  discard git(gitBin, workPath, "config user.name \"Branch Sync Tester\"")
  writeFile(workPath / "README.md", "branch-relative sync fixture\n")
  discard git(gitBin, workPath, "add README.md")
  discard git(gitBin, workPath, "commit -m base")
  discard git(gitBin, workPath, "remote add origin " & q(originPath))
  discard git(gitBin, workPath, "push origin dev")
  git(gitBin, workPath, "rev-parse HEAD").strip()

proc publishBranch(gitBin, workPath, branch: string) =
  ## Create ``branch`` at the current tip in the seed clone and publish it, so
  ## a later workspace clone can check it out with an upstream configured.
  discard git(gitBin, workPath, "checkout -b " & branch)
  discard git(gitBin, workPath, "push -u origin " & branch)
  discard git(gitBin, workPath, "checkout dev")

proc pushCommitOn(gitBin, workPath, branch, file, content: string): string =
  ## Commit ``file`` on ``branch`` in the seed clone and publish it. This is
  ## the "teammate pushed" step: it advances ``origin/<branch>`` only.
  discard git(gitBin, workPath, "checkout " & branch)
  writeFile(workPath / file, content)
  discard git(gitBin, workPath, "add " & file)
  discard git(gitBin, workPath, "commit -m \"teammate work on " & branch & "\"")
  discard git(gitBin, workPath, "push origin " & branch)
  result = git(gitBin, workPath, "rev-parse HEAD").strip()
  discard git(gitBin, workPath, "checkout dev")

proc cloneOnBranch(gitBin, originPath, targetPath, branch: string) =
  ## Clone and check out ``branch`` so its upstream is
  ## ``origin/<branch>`` — the ref the branch-relative arm must follow.
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard git(gitBin, targetPath, "config user.email tester@example.invalid")
  discard git(gitBin, targetPath, "config user.name \"Branch Sync Tester\"")
  if branch != "dev":
    discard git(gitBin, targetPath, "checkout " & branch)

proc localCommit(gitBin, repoPath: string): string =
  ## A clean but UNPUBLISHED local commit — makes the branch diverge from its
  ## own upstream rather than merely lag behind it.
  writeFile(repoPath / "local-only.txt", "mine\n")
  discard git(gitBin, repoPath, "add local-only.txt")
  discard git(gitBin, repoPath, "commit -m \"local-only work\"")
  git(gitBin, repoPath, "rev-parse HEAD").strip()

proc currentBranch(gitBin, repoPath: string): string =
  git(gitBin, repoPath, "symbolic-ref --short -q HEAD").strip()

proc headSha(gitBin, repoPath: string): string =
  git(gitBin, repoPath, "rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl, cUrl, dUrl: string): string =
  ## Every repo is pinned to ``dev``. Three of the four checkouts will be on
  ## some other branch, which is the whole point: the pin and the checkout
  ## deliberately disagree.
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

proc repoToml(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"dev\"\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    origins: array[4, string]
    seeds: array[4, string]

const repoNames = ["lib-a", "lib-b", "lib-c", "lib-d"]
const remoteNames = ["a-origin", "b-origin", "c-origin", "d-origin"]

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-branchsync-", "")
  result.reproBin = reproBinary()
  for i, name in repoNames:
    result.origins[i] = result.scratch / ("origin-" & name & ".git")
    result.seeds[i] = result.scratch / ("seed-" & name)
    discard seedTrunk(gitBin, result.origins[i], result.seeds[i])
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(result.origins[0]), fileUrl(result.origins[1]),
      fileUrl(result.origins[2]), fileUrl(result.origins[3])))
  for i, name in repoNames:
    writeFile(workspaceRoot / "repos" / (name & ".toml"),
      repoToml(name, remoteNames[i]))
  result.workspaceRoot = workspaceRoot

proc invokeSync(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "--report", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
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

suite "sync is keyed to the branch's own upstream, not the manifest pin":

  test "t_sync_fast_forwards_feature_branch_from_its_own_upstream":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # Publish the three feature branches at the base commit, then clone
      # each repo onto the branch it will be synced on.
      publishBranch(gitBin, fx.seeds[0], "feature/team")
      publishBranch(gitBin, fx.seeds[1], "feature/mine")
      publishBranch(gitBin, fx.seeds[2], "feature/idle")

      let libA = fx.workspaceRoot / "lib-a"
      let libB = fx.workspaceRoot / "lib-b"
      let libC = fx.workspaceRoot / "lib-c"
      let libD = fx.workspaceRoot / "lib-d"
      cloneOnBranch(gitBin, fx.origins[0], libA, "feature/team")
      cloneOnBranch(gitBin, fx.origins[1], libB, "feature/mine")
      cloneOnBranch(gitBin, fx.origins[2], libC, "feature/idle")
      cloneOnBranch(gitBin, fx.origins[3], libD, "dev")

      check currentBranch(gitBin, libA) == "feature/team"
      check currentBranch(gitBin, libB) == "feature/mine"
      check currentBranch(gitBin, libC) == "feature/idle"
      check currentBranch(gitBin, libD) == "dev"

      # (1) A teammate pushes to lib-a's feature branch. ``origin/dev`` is
      # untouched, so the manifest's pin cannot describe this update.
      let teammateA = pushCommitOn(gitBin, fx.seeds[0], "feature/team",
        "teammate.txt", "from teammate\n")
      let devTipA = git(gitBin, fx.seeds[0], "rev-parse dev").strip()
      check teammateA != devTipA

      # (2) lib-b: upstream advanced AND the operator owns a local commit.
      discard pushCommitOn(gitBin, fx.seeds[1], "feature/mine",
        "teammate.txt", "from teammate\n")
      let divergedB = localCommit(gitBin, libB)

      # (3) lib-c: nothing pushed — already at its own upstream tip.
      let idleC = headSha(gitBin, libC)

      # (4) lib-d: the trunk case, upstream advanced on ``dev`` itself.
      let advancedD = pushCommitOn(gitBin, fx.seeds[3], "dev",
        "trunk.txt", "trunk moved\n")

      let res = invokeSync(fx)
      if res.code notin [0, 2]:
        checkpoint("sync output: " & res.output)
      # lib-b is refuse-and-report, which is exit 0 (report-only) or 2.
      check res.code in [0, 2]

      let report = readReport(fx)

      # ---- (1) the teammate case: the point of the whole change. --------
      check headSha(gitBin, libA) == teammateA
      check fileExists(libA / "teammate.txt")
      check readFile(libA / "teammate.txt") == "from teammate\n"
      # Still on the feature branch — sync followed the branch, it did not
      # realign the checkout to the manifest's ``dev``.
      check currentBranch(gitBin, libA) == "feature/team"
      let aEntry = repoEntry(report, "lib-a")
      check aEntry["syncCase"].getStr() == "clean_fast_forwardable"
      check aEntry["executionStatus"].getStr() == "succeeded"
      check aEntry["branch"].getStr() == "feature/team"

      # ---- (2) diverged: must NOT fast-forward. -------------------------
      check headSha(gitBin, libB) == divergedB
      check fileExists(libB / "local-only.txt")
      check not fileExists(libB / "teammate.txt")
      check currentBranch(gitBin, libB) == "feature/mine"
      let bEntry = repoEntry(report, "lib-b")
      check bEntry["syncCase"].getStr() == "locally_unpublished"
      check bEntry["action"].getStr() == "none"

      # ---- (3) non-manifest branch with nothing to do. ------------------
      check headSha(gitBin, libC) == idleC
      check currentBranch(gitBin, libC) == "feature/idle"
      check repoEntry(report, "lib-c")["action"].getStr() == "none"

      # ---- (4) the trunk case still fast-forwards. ----------------------
      check headSha(gitBin, libD) == advancedD
      check fileExists(libD / "trunk.txt")
      check currentBranch(gitBin, libD) == "dev"
      let dEntry = repoEntry(report, "lib-d")
      check dEntry["syncCase"].getStr() == "clean_fast_forwardable"
      check dEntry["executionStatus"].getStr() == "succeeded"
