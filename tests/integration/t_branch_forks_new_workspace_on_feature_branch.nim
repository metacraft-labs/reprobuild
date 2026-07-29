## M27 — ``repro branch <name> <path>`` FORKS the workspace onto a
## new feature branch in a fresh directory.
##
## The optional second positional is the whole mode switch: with it, the
## command materializes a NEW workspace at ``<path>`` and starts ``<branch>``
## there, cut from the CURRENT workspace's committed HEADs — including commits
## that exist only locally and were never pushed — while leaving the current
## workspace untouched. See ``reprobuild-specs/CLI/branch.md`` §"Fork form"
## and the M27 milestone in
## ``reprobuild-specs/Workspace-Management.milestones.org``.
##
## Sub-cases:
##
##   1. ``test_m27_fork_materializes_new_workspace_on_branch`` — happy path.
##      Exit 0, ``mode = "fork"``; every member repo AND the workspace root
##      repo land on the branch; metadata records the branch +
##      ``feature_started``; the SOURCE workspace is provably unchanged
##      (still on its old branch, no new branch, no ``.repro`` churn).
##   2. ``test_m27_fork_cuts_from_local_only_commit`` — a commit that exists
##      ONLY in the source checkout (never pushed) is the branch point in the
##      fork. Falsifies "the fork just clones the remote tip".
##   3. ``test_m27_fork_leaves_uncommitted_work_behind_by_default`` — a dirty
##      source is NOT refused (unlike the in-place form) and its uncommitted
##      changes do NOT appear in the fork.
##   4. ``test_m27_fork_include_changes_copies_uncommitted_work`` — with
##      ``--include-changes`` both a tracked modification and an untracked new
##      file are copied into the fork, and the SOURCE still has them (copy,
##      never move).
##   5. ``test_m27_fork_refuses_non_empty_destination`` — exit 2, and the
##      pre-existing file in the destination is left byte-identical.
##   6. ``test_m27_fork_refuses_cwd_or_ancestor_destination`` — exit 2; the
##      run directory is not turned into a workspace.
##   7. ``test_m27_fork_refuses_when_branch_exists_on_remote`` — exit 2 with
##      the ``init`` + ``checkout`` remedy named; nothing is materialized.
##   8. ``test_m27_fork_rerun_is_idempotent`` — re-running the identical
##      command against the finished fork converges (exit 0) rather than
##      colliding, per the resumable/no-rollback contract.
##   9. ``test_m27_workspace_branch_alias_forks_identically`` — the namespaced
##      spelling ``repro workspace branch <name> <path>`` is the SAME command.
##  10. ``test_m27_include_changes_requires_the_fork_form`` — the flag is a
##      usage error in place (nothing to copy into).
##
## Real components (NO mocks): the real ``git`` binary, real bare repos on the
## real filesystem, and the real engine-built ``build/bin/repro`` spawned as a
## subprocess. The only substitution is local bare repos + ``file://`` URLs
## standing in for network remotes, which keeps the test hermetic (no network)
## — the same convention every workspace integration test uses.
##
## Falsifiability:
##   - If the fork cut from the remote tip instead of the source HEAD, case 2
##     fails (the local-only commit would be absent).
##   - If the workspace ROOT repo were left unbranched, case 1's root-branch
##     assertion fails.
##   - If the source workspace were mutated (switched/stashed), case 1's
##     source-untouched assertions and case 4's source-still-dirty assertion
##     fail.
##   - If ``--include-changes`` were a no-op, case 4 fails; if it leaked by
##     default, case 3 fails.
##   - If the destination guards regressed, cases 5/6 would materialize a
##     workspace and their "untouched" assertions fail.
##
## Skip rule: ``git`` missing on PATH (same convention as M9–M16).

import std/[json, options, os, osproc, strutils, tempfiles, unittest]

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

# Test-Fixtures-In-Build-Graph M1: ``repro`` is a build-graph artifact
# (``reprobuild.apps.repro`` → ``build/bin/repro``, built by ``just bootstrap``
# / the apps collection before tests run). Assert it exists and use it instead
# of recompiling ``apps/repro/repro.nim`` at test runtime.
proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc gitConfig(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"M27 Tester\"")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Bare origin + a seeded working clone pushed to it. Returns the HEAD SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  gitConfig(gitBin, workPath)
  writeFile(workPath / "README.md", "M27 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(fileUrl(originPath)))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedBareWithFiles(gitBin, scratch, barePath: string;
                       files: openArray[(string, string)]) =
  ## Build a bare repo whose tip carries the given files (used for the ROOT
  ## workspace repo, which must carry the membership manifests).
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  gitConfig(gitBin, workPath)
  for entry in files:
    let absPath = workPath / entry[0]
    createDir(absPath.splitPath.head)
    writeFile(absPath, entry[1])
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

proc currentBranch(gitBin, repoPath: string): string =
  let res = runCmd(q(gitBin) & " -C " & q(repoPath) &
    " symbolic-ref --short -q HEAD")
  if res.code != 0: "" else: res.output.strip()

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc localBranchExists(gitBin, repoPath, branch: string): bool =
  runCmd(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse --verify --quiet refs/heads/" & branch).code == 0

proc projectTomlWith2Remotes(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/lib-a.toml\",\n" &
  "  \"repos/lib-b.toml\",\n" &
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

type
  M27Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string      ## the SOURCE workspace (a clone of rootBare)
    rootBare: string
    libAOrigin: string
    libBOrigin: string

proc setupFixture(gitBin, slug: string): M27Fixture =
  ## A source workspace that is a real clone of a root workspace repo, so the
  ## fork has an ``origin`` to clone from — the shape `repro workspace init`
  ## produces and the shape the fork form requires.
  result.scratch = createTempDir("repro-m27-fork-" & slug & "-", "")
  result.reproBin = reproBinary()

  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libBOrigin = result.scratch / "origin-lib-b.git"
  discard seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")
  discard seedGitOrigin(gitBin, result.libBOrigin,
    result.scratch / "seed-lib-b")

  # The ROOT workspace repo carries the membership manifests at its top level
  # (the native layout: projects/ + repos/ at the workspace root).
  result.rootBare = result.scratch / "origin-repro-workspace.git"
  seedBareWithFiles(gitBin, result.scratch, result.rootBare, [
    ("projects/lib-a.toml", projectTomlWith2Remotes(
      fileUrl(result.libAOrigin), fileUrl(result.libBOrigin))),
    ("repos/lib-a.toml", libAFragmentToml),
    ("repos/lib-b.toml", libBFragmentToml),
  ])

  # Materialize the SOURCE workspace: clone the root repo, then the members.
  result.workspaceRoot = result.scratch / "source-workspace"
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.rootBare)) &
    " " & q(result.workspaceRoot))
  gitConfig(gitBin, result.workspaceRoot)
  for (name, origin) in [("lib-a", result.libAOrigin),
                         ("lib-b", result.libBOrigin)]:
    discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
      q(result.workspaceRoot / name))
    gitConfig(gitBin, result.workspaceRoot / name)
  writeWorkspaceBranch(result.workspaceRoot, project = "lib-a", branch = "main")

proc invokeFork(fx: M27Fixture; branch, path: string;
                extra: seq[string] = @[]; cwd = ""): CmdResult =
  var argv = @[fx.reproBin, "branch", "--report", branch, path,
               "--workspace-root=" & fx.workspaceRoot]
  for e in extra:
    argv.add(e)
  if cwd.len > 0:
    runShell(shellCommand(argv), cwd = cwd)
  else:
    runShell(shellCommand(argv))

proc readForkReport(root: string): JsonNode =
  let reportPath = root / ".repro" / "build" / "reports" / "branch-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc entryByPath(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  newJNull()

suite "M27 — repro branch <name> <path> forks a new workspace":

  test "test_m27_fork_materializes_new_workspace_on_branch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "happy")
      defer: removeDirEventually(fx.scratch)

      let srcShaA = headSha(gitBin, fx.workspaceRoot / "lib-a")
      let srcShaB = headSha(gitBin, fx.workspaceRoot / "lib-b")
      let forkPath = fx.scratch / "feature-workspace"

      let res = invokeFork(fx, "feature-x", forkPath)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The new workspace exists with both members checked out ON the branch,
      # at exactly the source's committed HEADs.
      check dirExists(forkPath / ".git")
      for (name, sha) in [("lib-a", srcShaA), ("lib-b", srcShaB)]:
        check dirExists(forkPath / name / ".git")
        check currentBranch(gitBin, forkPath / name) == "feature-x"
        check headSha(gitBin, forkPath / name) == sha

      # The workspace ROOT repo is branched too (membership edits on a feature
      # branch stay on the feature branch).
      check currentBranch(gitBin, forkPath) == "feature-x"

      # Metadata in the NEW workspace records branch + feature mark.
      let recorded = readWorkspaceBranch(forkPath)
      check recorded.isSome
      check recorded.get() == "feature-x"
      check readWorkspaceFeatureStarted(forkPath)

      # Report shape.
      let report = readForkReport(forkPath)
      check report["exitCode"].getInt() == 0
      check report["form"].getStr() == "fork"
      check report["branch"].getStr() == "feature-x"
      check report["sourceWorkspaceRoot"].getStr() == fx.workspaceRoot
      check report["workspaceRoot"].getStr() == forkPath
      check entryByPath(report, "lib-a")["outcome"].getStr() == "branched"
      check entryByPath(report, ".")["outcome"].getStr() == "branched"

      # The SOURCE workspace is untouched: still on main, no feature branch,
      # and its recorded metadata is unchanged.
      check currentBranch(gitBin, fx.workspaceRoot / "lib-a") == "main"
      check currentBranch(gitBin, fx.workspaceRoot / "lib-b") == "main"
      check not localBranchExists(gitBin, fx.workspaceRoot / "lib-a",
        "feature-x")
      check not localBranchExists(gitBin, fx.workspaceRoot, "feature-x")
      let srcRecorded = readWorkspaceBranch(fx.workspaceRoot)
      check srcRecorded.isSome
      check srcRecorded.get() == "main"

      # The operator is pointed at the new directory + the readiness check.
      check res.output.contains(forkPath)
      check res.output.contains("repro health")

  test "test_m27_fork_cuts_from_local_only_commit":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "localonly")
      defer: removeDirEventually(fx.scratch)

      # A commit that exists ONLY in the source checkout — never pushed, so a
      # fresh clone of the origin cannot possibly have it.
      let libA = fx.workspaceRoot / "lib-a"
      writeFile(libA / "local-only.txt", "unpublished work\n")
      discard requireGit(q(gitBin) & " -C " & q(libA) & " add local-only.txt")
      discard requireGit(q(gitBin) & " -C " & q(libA) &
        " commit -m \"local only\"")
      let localSha = headSha(gitBin, libA)

      let forkPath = fx.scratch / "feature-workspace"
      let res = invokeFork(fx, "feature-local", forkPath)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # The fork branched AT the unpublished commit and carries its content.
      check headSha(gitBin, forkPath / "lib-a") == localSha
      check fileExists(forkPath / "lib-a" / "local-only.txt")
      check currentBranch(gitBin, forkPath / "lib-a") == "feature-local"

  test "test_m27_fork_leaves_uncommitted_work_behind_by_default":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDirEventually(fx.scratch)

      let libA = fx.workspaceRoot / "lib-a"
      writeFile(libA / "README.md", "M27 fixture\nUNCOMMITTED EDIT\n")
      writeFile(libA / "scratch-note.txt", "untracked\n")

      let forkPath = fx.scratch / "feature-workspace"
      let res = invokeFork(fx, "feature-clean", forkPath)
      if res.code != 0:
        checkpoint("output: " & res.output)
      # A dirty source is NOT a refusal in the fork form.
      check res.code == 0

      # ...but its uncommitted work did not travel.
      check not readFile(forkPath / "lib-a" / "README.md").contains(
        "UNCOMMITTED EDIT")
      check not fileExists(forkPath / "lib-a" / "scratch-note.txt")
      # The source keeps it.
      check readFile(libA / "README.md").contains("UNCOMMITTED EDIT")
      check fileExists(libA / "scratch-note.txt")

  test "test_m27_fork_include_changes_copies_uncommitted_work":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "carry")
      defer: removeDirEventually(fx.scratch)

      let libA = fx.workspaceRoot / "lib-a"
      writeFile(libA / "README.md", "M27 fixture\nCARRIED EDIT\n")
      writeFile(libA / "new-feature.txt", "brand new file\n")

      let forkPath = fx.scratch / "feature-workspace"
      let res = invokeFork(fx, "feature-carry", forkPath,
        extra = @["--include-changes"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      # Tracked modification AND untracked new file both landed.
      check readFile(forkPath / "lib-a" / "README.md").contains("CARRIED EDIT")
      check fileExists(forkPath / "lib-a" / "new-feature.txt")
      check readFile(forkPath / "lib-a" / "new-feature.txt") ==
        "brand new file\n"

      # Copy, never move: the SOURCE still has its changes.
      check readFile(libA / "README.md").contains("CARRIED EDIT")
      check fileExists(libA / "new-feature.txt")

      let report = readForkReport(forkPath)
      check report["includeChanges"].getBool()
      check entryByPath(report, "lib-a")["outcome"].getStr() ==
        "branched_with_changes"
      # The clean repo is plain ``branched``.
      check entryByPath(report, "lib-b")["outcome"].getStr() == "branched"

  test "test_m27_fork_refuses_non_empty_destination":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "nonempty")
      defer: removeDirEventually(fx.scratch)

      let forkPath = fx.scratch / "occupied"
      createDir(forkPath)
      writeFile(forkPath / "keep.txt", "pre-existing\n")

      let res = invokeFork(fx, "feature-x", forkPath)
      check res.code == 2

      # Nothing was materialized into it and the existing file is intact.
      check readFile(forkPath / "keep.txt") == "pre-existing\n"
      check not dirExists(forkPath / ".git")
      check not dirExists(forkPath / "lib-a")

      # The refusal is reported against the SOURCE workspace (the destination
      # must not be conjured into existence just to hold a report).
      let report = readForkReport(fx.workspaceRoot)
      check report["exitCode"].getInt() == 2
      check report["repos"][0]["outcome"].getStr() == "destination_refused"

  test "test_m27_fork_refuses_cwd_or_ancestor_destination":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "ancestor")
      defer: removeDirEventually(fx.scratch)

      let runDir = fx.scratch / "run-here"
      createDir(runDir)

      # Destination IS the current directory → the upward-walk trap guard.
      let res = invokeFork(fx, "feature-x", runDir, cwd = runDir)
      check res.code == 2
      check not dirExists(runDir / ".repro")
      check not dirExists(runDir / "lib-a")

  test "test_m27_fork_refuses_when_branch_exists_on_remote":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "remotebranch")
      defer: removeDirEventually(fx.scratch)

      # Publish the branch on lib-a's origin: `start` means START, so the
      # command must refuse rather than silently adopt it.
      let libA = fx.workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " -C " & q(libA) &
        " push origin main:refs/heads/feature-taken")

      let forkPath = fx.scratch / "feature-workspace"
      let res = invokeFork(fx, "feature-taken", forkPath)
      check res.code == 2
      check not dirExists(forkPath)

      let report = readForkReport(fx.workspaceRoot)
      check report["exitCode"].getInt() == 2
      let entry = entryByPath(report, "lib-a")
      check entry["outcome"].getStr() == "branch_exists_on_remote"
      # The remedy names the init + checkout path.
      check entry["diagnostic"].getStr().contains("repro checkout")

  test "test_m27_fork_rerun_is_idempotent":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "rerun")
      defer: removeDirEventually(fx.scratch)

      let forkPath = fx.scratch / "feature-workspace"
      let first = invokeFork(fx, "feature-again", forkPath)
      if first.code != 0:
        checkpoint("first: " & first.output)
      check first.code == 0
      let shaAfterFirst = headSha(gitBin, forkPath / "lib-a")

      # Re-running the identical command converges instead of colliding: the
      # branch is already at the requested SHA everywhere.
      let second = invokeFork(fx, "feature-again", forkPath)
      if second.code != 0:
        checkpoint("second: " & second.output)
      check second.code == 0
      check headSha(gitBin, forkPath / "lib-a") == shaAfterFirst
      check currentBranch(gitBin, forkPath / "lib-a") == "feature-again"

  test "test_m27_workspace_branch_alias_forks_identically":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "alias")
      defer: removeDirEventually(fx.scratch)

      let srcSha = headSha(gitBin, fx.workspaceRoot / "lib-a")
      let forkPath = fx.scratch / "feature-workspace"
      # The namespaced spelling must behave exactly like the top-level verb.
      let res = runShell(shellCommand(@[
        fx.reproBin, "workspace", "branch", "--report", "feature-alias", forkPath,
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      check currentBranch(gitBin, forkPath / "lib-a") == "feature-alias"
      check headSha(gitBin, forkPath / "lib-a") == srcSha
      check currentBranch(gitBin, forkPath) == "feature-alias"
      check readForkReport(forkPath)["form"].getStr() == "fork"

  test "test_m27_include_changes_requires_the_fork_form":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "usage")
      defer: removeDirEventually(fx.scratch)

      # No <path> → in place, where there is nothing to copy INTO.
      let res = runShell(shellCommand(@[
        fx.reproBin, "branch", "--report", "feature-x",
        "--include-changes",
        "--workspace-root=" & fx.workspaceRoot,
      ]))
      check res.code != 0
      check res.output.contains("--include-changes")
