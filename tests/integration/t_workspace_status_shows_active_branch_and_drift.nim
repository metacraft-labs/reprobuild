## M12 — ``repro workspace status``.
##
## Integration test for the read-only status subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace status`` to ``runWorkspaceStatusCommand``,
## which:
##
##   1. Resolves the named project / variant via the M6 surface (or
##      composes layers via M8 when ``.repro/workspace.toml`` is
##      present). The single-project / M6 path is exercised here.
##   2. For every declared repo, gathers the live M4 evidence triple
##      (head-sha, is-clean, is-published).
##   3. Resolves the latest lock via Git history over the per-repo lock
##      subtree (RA-1; no index) and compares each live HEAD against the
##      most-recently-locked SHA — ``at-lock``, ``drifted-from-lock``,
##      or ``no-lock-recorded``.
##   4. Emits ``<workspaceRoot>/.repro/build/reports/status-report.json``
##      plus a structured stdout summary; exits 0.
##
## Fixture pattern matches M9 / M10 / M11: hermetic local bare git
## repos stand in for the manifest's remote URLs, the workspace tree
## holds the ``projects/`` / ``repos/`` TOMLs, and the test compiles ``repro``
## once per ``setupFixture`` into the scratch directory.
##
## Skip rule: only when ``git`` is missing from PATH (same convention
## as M2 / M3 / M8 / M9 / M10 / M11).

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
  ## Bare origin with one commit; mirrors M9 / M10 / M11's seed pattern.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M12 Tester\"")
  writeFile(workPath / "README.md", "M12 fixture\n")
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
    " config user.name \"M12 Tester\"")

proc advanceCommit(gitBin, repoPath: string): string =
  ## Add one local commit to a clean checkout and return the new HEAD.
  writeFile(repoPath / "advance.txt", "advance\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add advance.txt")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m \"advance\"")
  result = requireGit(q(gitBin) & " -C " & q(repoPath) &
    " rev-parse HEAD").strip()

proc dirtyTheTree(repoPath: string) =
  writeFile(repoPath / "dirty.txt", "uncommitted\n")

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  ## Project manifest declaring three repos. The project name matches
  ## ``lib-a`` so the M11 lock writer (which M12 status reads from)
  ## anchors lock files at ``locks/lib-a/lib-a-<short>.toml``
  ## deterministically.
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

  M12Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M12Fixture =
  result.scratch = createTempDir("repro-m12-status-" & slug & "-", "")
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
  # This suite asserts a manifest lock RECORD exists, which only happens in a
  # workspace that declares a manifest-backed route (Unified-Locking-And-Hooks.md
  # §10, "No implicit team route": a workspace that never declares one is
  # public-only and writes only `repro.lock`). Make `.repro/manifests` a real git
  # checkout so the route is DECLARED rather than inferred from a path — the gate
  # previously synthesized the store unconditionally, handing this fixture a lock
  # record it had never asked for.
  let lockStore = workspaceRoot / ".repro" / "manifests"
  createDir(lockStore)
  discard requireGit(q(gitBin) & " init -b main " & q(lockStore))
  discard requireGit(q(gitBin) & " -C " & q(lockStore) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(lockStore) &
    " config user.name \"Lock Store Tester\"")
  writeFile(lockStore / ".gitkeep", "")
  discard requireGit(q(gitBin) & " -C " & q(lockStore) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(lockStore) &
    " commit -m \"seed lock store\"")
  result.workspaceRoot = workspaceRoot

proc cloneAll(gitBin: string; fx: M12Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc invokeLock(fx: M12Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeStatus(fx: M12Fixture; extra: openArray[string] = []): CmdResult =
  var argv = @[
    fx.reproBin, "workspace", "status", "--write-report", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc readReport(fx: M12Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "status-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc findRepo(report: JsonNode; path: string): JsonNode =
  for entry in report["repos"]:
    if entry["path"].getStr() == path:
      return entry
  return nil

# ---- the suite -------------------------------------------------------------

suite "M12 — repro workspace status (active branch + drift)":

  test "test_m12_status_at_lock_when_no_drift":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "at-lock")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      check invokeLock(fx).code == 0

      let res = invokeStatus(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["project"].getStr() == "lib-a"
      check report["hasLockIndex"].getBool() == true

      # Every repo must be at-lock with the right HEAD.
      check report["repos"].len == 3
      for entry in report["repos"]:
        check entry["lockState"].getStr() == "at-lock"
        check entry["checkoutState"].getStr() == "clean"
        check entry["headSha"].getStr() == entry["lockedRevision"].getStr()

      check report["summary"]["atLock"].getInt() == 3
      check report["summary"]["drifted"].getInt() == 0
      check report["summary"]["clean"].getInt() == 3
      check report["summary"]["dirty"].getInt() == 0
      check report["summary"]["missing"].getInt() == 0
      check report["summary"]["noLockRecorded"].getInt() == 0

      # Active branch heuristic: every cloned repo reports 'main' as
      # its current branch (seed pushes on 'main'), so the workspace
      # active-branch fallback picks the first repo's branch.
      check report["activeBranch"].getStr() == "main"

  test "test_m12_status_drifted_when_head_advanced_past_lock":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "drifted")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      check invokeLock(fx).code == 0

      # Advance lib-b past its locked SHA with a fresh local commit.
      # The working tree stays clean (commit is fully staged); only
      # the SHA moves.
      let advancedSha = advanceCommit(gitBin, fx.workspaceRoot / "lib-b")
      check advancedSha != fx.libB.sha

      let res = invokeStatus(fx)
      check res.code == 0

      let report = readReport(fx)
      let libAEntry = findRepo(report, "lib-a")
      let libBEntry = findRepo(report, "lib-b")
      let libCEntry = findRepo(report, "lib-c")
      check not libAEntry.isNil
      check not libBEntry.isNil
      check not libCEntry.isNil

      check libAEntry["lockState"].getStr() == "at-lock"
      check libBEntry["lockState"].getStr() == "drifted-from-lock"
      check libCEntry["lockState"].getStr() == "at-lock"

      # The drifted repo's recorded HEAD must be the advanced commit,
      # and the lockedRevision must STILL be the original locked SHA
      # — that's the diff the status command must surface.
      check libBEntry["headSha"].getStr() == advancedSha
      check libBEntry["lockedRevision"].getStr() == fx.libB.sha

      check report["summary"]["drifted"].getInt() == 1
      check report["summary"]["atLock"].getInt() == 2

  test "test_m12_status_dirty_checkout_flagged":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      check invokeLock(fx).code == 0

      dirtyTheTree(fx.workspaceRoot / "lib-b")

      let res = invokeStatus(fx)
      # Status is read-only — exit 0 even with dirty repos.
      check res.code == 0

      let report = readReport(fx)
      let libBEntry = findRepo(report, "lib-b")
      check not libBEntry.isNil
      check libBEntry["checkoutState"].getStr() == "dirty"
      check libBEntry["isClean"].getBool() == false

      check report["summary"]["dirty"].getInt() == 1
      check report["summary"]["clean"].getInt() == 2

  test "test_m12_status_missing_checkout_reported":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "missing")
      defer: removeDir(fx.scratch)

      # Only clone two of the three repos; lib-c is intentionally
      # missing.
      cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
      cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")

      let res = invokeStatus(fx)
      check res.code == 0

      let report = readReport(fx)
      let libCEntry = findRepo(report, "lib-c")
      check not libCEntry.isNil
      check libCEntry["checkoutState"].getStr() == "missing"

      check report["summary"]["missing"].getInt() == 1

  test "test_m12_status_no_lock_recorded_runs_without_error":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-lock")
      defer: removeDir(fx.scratch)

      # Skip the lock step entirely; the index file should not exist.
      cloneAll(gitBin, fx)

      let res = invokeStatus(fx)
      check res.code == 0

      let report = readReport(fx)
      check report["hasLockIndex"].getBool() == false
      check report["summary"]["noLockRecorded"].getInt() == 3
      check report["summary"]["drifted"].getInt() == 0
      check report["summary"]["atLock"].getInt() == 0

      # Every repo must surface as no-lock-recorded — there was no
      # lock under the per-repo subtree to compare against.
      for entry in report["repos"]:
        check entry["lockState"].getStr() == "no-lock-recorded"
        check entry["lockedRevision"].getStr().len == 0

  test "test_m12_status_extended_queries":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "extended-queries")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      check invokeLock(fx).code == 0

      # 1. Create a stash in lib-b
      writeFile(fx.workspaceRoot / "lib-b" / "stash.txt", "stash-me\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " add stash.txt")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " stash")

      # 2. Ahead commit on main in lib-b
      writeFile(fx.workspaceRoot / "lib-b" / "ahead.txt", "ahead-content\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " add ahead.txt")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " commit -m ahead")

      # 3. Behind commit on origin in lib-b
      writeFile(fx.scratch / "seed-lib-b" / "behind.txt", "behind-content\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.scratch / "seed-lib-b") & " add behind.txt")
      discard requireGit(q(gitBin) & " -C " & q(fx.scratch / "seed-lib-b") & " commit -m behind")
      discard requireGit(q(gitBin) & " -C " & q(fx.scratch / "seed-lib-b") & " push origin main")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " fetch")

      # 4. Unmerged branch in lib-b
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " checkout -b feature")
      writeFile(fx.workspaceRoot / "lib-b" & "/feature.txt", "feature-content\n")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " commit -m feature")
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-b") & " checkout main")

      # 5. Untracked and modified files in lib-b
      writeFile(fx.workspaceRoot / "lib-b" & "/untracked.txt", "untracked-content\n")
      writeFile(fx.workspaceRoot / "lib-b" & "/README.md", "README modified\n")

      # Run full status
      let res = invokeStatus(fx)
      check res.code == 0
      
      # Verify text output fields are present
      check "modified=1 untracked=1" in res.output
      check "stashes=1" in res.output
      check "ahead=1 behind=1" in res.output
      check "unmerged=feature" in res.output

      # Verify JSON output
      let report = readReport(fx)
      let libBEntry = findRepo(report, "lib-b")
      check not libBEntry.isNil
      check libBEntry["modifiedCount"].getInt() == 1
      check libBEntry["untrackedCount"].getInt() == 1
      check libBEntry["stashCount"].getInt() == 1
      check libBEntry["aheadCount"].getInt() == 1
      check libBEntry["behindCount"].getInt() == 1
      check libBEntry["unmergedBranches"].len == 1
      check libBEntry["unmergedBranches"][0].getStr() == "feature"

      # Run with selective flag (only stashes)
      let resStashes = invokeStatus(fx, ["--stashes"])
      check resStashes.code == 0
      check "stashes=1" in resStashes.output
      check "modified=" notin resStashes.output
      check "ahead=" notin resStashes.output
      check "unmerged=" notin resStashes.output

      # Verify JSON output under selective flag
      let reportStashes = readReport(fx)
      let libBStashEntry = findRepo(reportStashes, "lib-b")
      check libBStashEntry["stashCount"].getInt() == 1
      check libBStashEntry["modifiedCount"].getInt() == 0
      check libBStashEntry["aheadCount"].getInt() == 0
      check libBStashEntry["unmergedBranches"].len == 0

  test "test_m12_status_ambiguous_trunk_ref_does_not_leak_git_warning":
    ## Regression: when the trunk ref name resolves ambiguously — e.g. a repo
    ## that also has a *tag* named `main` alongside the `main` branch — then
    ## `git branch --no-merged main` prints
    ##   "warning: refname 'main' is ambiguous."
    ## on stderr. runGit merges stderr into stdout (execCmdEx), so that
    ## diagnostic previously leaked into `unmergedBranches` and surfaced as a
    ## bogus `unmerged=warning: refname 'main' is ambiguous.` field. The parser
    ## must reject the diagnostic (a real branch name has no whitespace/':')
    ## while still reporting the genuine unmerged branch.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # NB: keep "ambiguous" out of the fixture slug — it lands in the temp
      # workspace path, which appears in status output and would false-match.
      let fx = setupFixture(gitBin, "tag-shadows-trunk")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      check invokeLock(fx).code == 0

      let libB = fx.workspaceRoot / "lib-b"
      # A genuine unmerged branch that MUST still be reported.
      discard requireGit(q(gitBin) & " -C " & q(libB) & " checkout -b feature")
      writeFile(libB / "feature.txt", "feature-content\n")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " add feature.txt")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " commit -m feature")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " checkout main")
      # Make bare `main` ambiguous: a tag named `main` next to the branch.
      discard requireGit(q(gitBin) & " -C " & q(libB) & " tag main")

      let res = invokeStatus(fx)
      check res.code == 0

      # The genuine branch survives; the git "refname ... is ambiguous" warning
      # must NOT leak into the unmerged field (the pre-fix symptom was
      # `unmerged=warning: refname 'main' is ambiguous.`).
      check "unmerged=feature" in res.output
      check "unmerged=warning" notin res.output

      let report = readReport(fx)
      let libBEntry = findRepo(report, "lib-b")
      check not libBEntry.isNil
      check libBEntry["unmergedBranches"].len == 1
      for b in libBEntry["unmergedBranches"]:
        let s = b.getStr()
        check s == "feature"
        check ' ' notin s
        check ':' notin s

  test "test_m12_status_active_branch_is_trunk_when_repos_diverge":
    ## Regression: with no recorded `[workspace].branch` and repos on DIFFERENT
    ## branches, the active-branch header must NOT report an arbitrary (first)
    ## repo's branch. A mixed-branch workspace has no single active branch (and
    ## `repro branch` would say `<none recorded>`), so the heuristic defers to
    ## the manifest trunk instead of the first repo's divergent branch.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "divergent-branches")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      # Put the FIRST repo (lib-a) on a non-trunk branch; lib-b/lib-c stay on
      # `main`. Pre-fix, the heuristic returned lib-a's branch (`feature-x`);
      # post-fix, divergence defers to the trunk (`main`).
      discard requireGit(q(gitBin) & " -C " & q(fx.workspaceRoot / "lib-a") &
        " checkout -b feature-x")

      let res = invokeStatus(fx)
      check res.code == 0

      let report = readReport(fx)
      check report["activeBranch"].getStr() == "main"
      # The header (first line) carries the workspace-level branch.
      check "project=lib-a branch=main" in res.output
      # ...while lib-a's own per-repo line still honestly shows its branch.
      check "lib-a clean branch=feature-x" in res.output

  test "test_m12_status_file_details_lists_paths_with_xy_codes":
    ## `--file-details` surfaces each changed path with its porcelain `XY`
    ## status (the staged-vs-unstaged granularity `repo status` has, which the
    ## coarse modified/untracked counts lack). It is additive: an opt-in that
    ## augments — the default fields stay — rather than narrowing the output.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "file-details")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      check invokeLock(fx).code == 0

      let libB = fx.workspaceRoot / "lib-b"
      # Staged addition (X=A), unstaged modification (Y=M), and an untracked
      # file (??) — three distinct porcelain codes the counts cannot express.
      writeFile(libB / "added.txt", "new\n")
      discard requireGit(q(gitBin) & " -C " & q(libB) & " add added.txt")
      writeFile(libB / "README.md", "changed\n")   # committed file, NOT staged
      writeFile(libB / "untracked.txt", "loose\n")

      # Default status: file details are NOT included (opt-in).
      check invokeStatus(fx).code == 0
      check findRepo(readReport(fx), "lib-b")["fileDetails"].len == 0

      # With --file-details: the per-file XY list appears AND the default
      # fields remain present (additive, not narrowing).
      let res = invokeStatus(fx, ["--file-details"])
      check res.code == 0
      check "modified=2 untracked=1" in res.output   # coarse counts still there
      check "A  added.txt" in res.output             # staged add
      check " M README.md" in res.output             # unstaged modification
      check "?? untracked.txt" in res.output         # untracked

      let libBEntry = findRepo(readReport(fx), "lib-b")
      check libBEntry["fileDetails"].len == 3
      var codes, paths: seq[string]
      for fd in libBEntry["fileDetails"]:
        codes.add(fd["code"].getStr())
        paths.add(fd["path"].getStr())
      check "A " in codes    # staged add (X column)
      check " M" in codes    # unstaged modification (leading space preserved)
      check "??" in codes    # untracked
      check "added.txt" in paths
      check "README.md" in paths
      check "untracked.txt" in paths
