## M19 — post-commit lock refresh (best-effort).
##
## The M17-installed post-commit hook dispatches into
## ``repro hooks dispatch post-commit --repo-root <repo>`` which routes
## to the M19 ``runPostCommitLockCommand`` wrapper. The wrapper exists
## to keep the strict M11 ``runWorkspaceLockCommand`` contract intact
## (exit codes 0 / 1 / 2) while implementing the post-commit policy:
## EVERY failure is captured into the per-workspace log + JSON report
## and the process exits 0 so the originating commit never sees a
## non-zero hook status.
##
## This suite exercises the five M19 invariants:
##
##   1. Happy path — clean workspace → per-repo lock TOML written
##      (RA-1: no index) + exit 0. M19b: the JSON report says what
##      happened to that record — ``written-local-only`` for this
##      fixture's upstream-less store — and NEVER a bare ``ok``.
##   2. Dirty workspace → strict M11 would have refused with exit 2;
##      post-commit downgrades to exit 0 with
##      ``outcome = "no-lock-dirty-siblings"`` and writes NO lock file.
##   3. No ``.repro/workspace.toml`` → wrapper logs
##      ``outcome = "skipped-no-workspace"`` + exit 0 without touching
##      the (missing) manifest layer.
##   4. Lock writer fails (manifests/ directory made non-writable) →
##      wrapper logs ``outcome = "no-lock-failed"`` with a diagnostic + exit 0.
##   5. Two consecutive invocations → log file has TWO lines, JSON
##      report carries the second (latest) invocation only.
##
## M19b adds the publication invariants. Post-commit is local-only by
## design (Workspace-Manifests.md § "Lock publication (commit + push)":
## the publish table's post-commit row is "writes yes / publishes **no —
## local only**"), so it can never itself publish. What it MUST NOT do is
## call a local write a success — that is precisely how a workspace logged
## an unbroken run of ``ok wrote <path>`` for two weeks while every one of
## those records sat untracked on one disk and CI reported the commits as
## unlocked. The regression cases here are:
##
##   6. Publishable store (a real clone with an upstream), record not yet
##      upstream → ``written-pending-publish`` / ``publication = "pending"``.
##      The report must NOT contain the tag ``ok`` or ``published``.
##   7. Same store, record actually committed + pushed → ``published``.
##      This is the ONLY outcome that reads as success, and it is earned by
##      the record's presence in the store's upstream, not by a write.
##   8. A backlog of pending records anchored to ALREADY-PUSHED commits
##      (the two-week starvation, reproduced) → counted as ``stranded`` and
##      announced on stderr. Pushes went out without their locks.
##   9. The two "no lock at all" branches (dirty siblings / writer failure)
##      announce themselves on stderr too, still exiting 0.
##
## Skip rule: ``git`` missing on PATH (same convention as M9 / M10 /
## M11 / M17 / M18).

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

when defined(posix):
  import std/posix

import repro_test_support
import repro_workspace_manifests

# ---- helpers --------------------------------------------------------------

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

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Seed one origin + working checkout and return the seed commit's SHA.
  ##
  ## The seed content is keyed on ``workPath``'s own directory name, and that
  ## is load-bearing rather than decorative. A commit SHA is a hash of (tree,
  ## message, author, committer, timestamps) — nothing else. This fixture seeds
  ## three repos back to back with the same author, the same committer and, if
  ## the content is the same too, the same tree; three such commits that land
  ## in one clock second are therefore BYTE-IDENTICAL objects with ONE SHA.
  ##
  ## That is not a theoretical hazard. With a constant README this collided on
  ## every single one of 20 consecutive fixture builds, and it made the suite
  ## flaky: a case asserting that a sibling's stale revision is gone from a
  ## lock record read a DIFFERENT repo's entry that happened to carry the same
  ## SHA. Distinct trees make distinct SHAs a property of the fixture rather
  ## than of how fast the machine ran.
  let seedTag = workPath.lastPathPart
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M19 Tester\"")
  writeFile(workPath / "README.md", "M19 fixture: " & seedTag & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m " & q("seed " & seedTag))
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
    " config user.name \"M19 Tester\"")

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

type
  RepoSeed = object
    name: string
    origin: string
    seedPath: string
    sha: string

  M19Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M19Fixture =
  result.scratch = createTempDir("repro-m19-" & slug & "-", "")
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

proc cloneAll(gitBin: string; fx: M19Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc seedWorkspaceToml(fx: M19Fixture) =
  ## Single-project metadata-only workspace.toml so the post-commit
  ## wrapper finds a project name to resolve.
  writeWorkspaceBranch(fx.workspaceRoot,
    project = "lib-a", branch = "main")

proc invokePostCommit(fx: M19Fixture; currentRepo: string): CmdResult =
  ## Exact argv the M17 hook dispatcher uses.
  runShell(shellCommand(@[
    fx.reproBin, "hooks", "dispatch", "post-commit",
    "--repo-root", currentRepo, "--",
  ]))

proc readPostCommitReport(fx: M19Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "post-commit-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc lockStoreRoot(fx: M19Fixture): string =
  fx.workspaceRoot / ".repro" / "manifests"

proc makeLockStorePublishable(gitBin: string; fx: M19Fixture) =
  ## M19b — give the fixture's lock store a real upstream.
  ##
  ## ``setupFixture`` leaves the store as a standalone ``git init`` with no
  ## remote, which is a store nothing can EVER be published to
  ## (``lpoNotPublishable``). That is a legitimate configuration and the suite
  ## covers it, but it cannot exhibit the defect: the interesting failure is a
  ## store that CAN publish and simply never does. Adding an upstream is what
  ## separates "will never be published" from "has not been published".
  let store = lockStoreRoot(fx)
  let origin = fx.scratch / "origin-lock-store.git"
  discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
  discard requireGit(q(gitBin) & " -C " & q(store) &
    " remote add origin " & q(origin))
  discard requireGit(q(gitBin) & " -C " & q(store) & " push -u origin main")

proc publishLockStore(gitBin: string; fx: M19Fixture) =
  ## Do by hand what the pre-push gate's ``publishWorkspaceLock`` does: commit
  ## the ``locks/`` subtree and push it. ``-f`` mirrors the publisher, which
  ## forces its own generated records past any ignore rules.
  let store = lockStoreRoot(fx)
  discard requireGit(q(gitBin) & " -C " & q(store) & " add -f -- locks")
  discard requireGit(q(gitBin) & " -C " & q(store) &
    " commit -m \"Publish workspace lock entries\"")
  discard requireGit(q(gitBin) & " -C " & q(store) & " push origin main")

proc commitInRepo(gitBin: string; fx: M19Fixture;
                  repoDir, fileName: string): string =
  ## Add one unpushed commit to ``<workspace>/<repoDir>`` and return its SHA.
  ## Post-commit's real trigger: a commit that has NOT reached its remote yet.
  let repoPath = fx.workspaceRoot / repoDir
  writeFile(repoPath / fileName, fileName & "\n")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add " & q(fileName))
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " commit -m " & q("commit " & fileName))
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc commitInLibA(gitBin: string; fx: M19Fixture; fileName: string): string =
  commitInRepo(gitBin, fx, "lib-a", fileName)

proc readPostCommitLog(fx: M19Fixture): string =
  let logPath = fx.workspaceRoot / ".repro" / "workspace" /
    "post-commit-lock.log"
  if not fileExists(logPath):
    return ""
  readFile(logPath)

proc lockedRevision(recordBody, repoName: string): string =
  ## The ``revision`` carried by ONE named ``[[repo]]`` entry of a
  ## ``reprobuild.workspace.lock.v1`` record, or ``""`` when the record does
  ## not mention that repo at all.
  ##
  ## Asserting on the record as one flat string cannot tell lib-a's
  ## coordinates from lib-c's — a whole-file ``contains`` answers "some repo
  ## in here is pinned at this SHA", which is not what any of these cases
  ## mean to say. Reading the entry by name says it exactly, and reports the
  ## revision it did find when it disagrees.
  var currentRepo = ""
  for rawLine in recordBody.splitLines():
    let line = rawLine.strip()
    if line == "[[repo]]":
      currentRepo = ""
    elif line.startsWith("name = "):
      currentRepo = line[len("name = ") .. ^1].strip(chars = {'"'})
    elif line.startsWith("revision = ") and currentRepo == repoName:
      return line[len("revision = ") .. ^1].strip(chars = {'"'})
  ""

# ---- the suite -------------------------------------------------------------

suite "M19 — repro hooks dispatch post-commit (best-effort lock)":

  test "test_m19_fixture_seeds_three_distinguishable_repos":
    ## Every case below reasons about WHICH repo a lock record pins at WHICH
    ## revision, so the three seeded repos have to be distinguishable by their
    ## SHAs. They were not.
    ##
    ## ``setupFixture`` seeds lib-a, lib-b and lib-c back to back, and a commit
    ## SHA is a hash of tree + message + author + committer + timestamps. With
    ## identical content, identical messages and one shared identity, the only
    ## remaining input is the one-second-resolution timestamp — so three seeds
    ## created inside the same second hashed to ONE commit object. Measured on
    ## this fixture, that happened in 20 of 20 consecutive builds.
    ##
    ## The damage was a flaky suite, not a cosmetic one: with lib-c's revision
    ## coincidentally equal to lib-a's original head, a case asserting that
    ## lib-a's superseded revision no longer appears in a refreshed lock record
    ## failed on lib-c's entry — a correct record read as a broken one, 4 runs
    ## in 10. This case pins the fixture property that stops it.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "distinct-seeds")
      defer: removeDir(fx.scratch)
      checkpoint("lib-a=" & fx.libA.sha & " lib-b=" & fx.libB.sha &
        " lib-c=" & fx.libC.sha)
      check fx.libA.sha.len == 40
      check fx.libA.sha != fx.libB.sha
      check fx.libA.sha != fx.libC.sha
      check fx.libB.sha != fx.libC.sha

  test "test_m19_post_commit_writes_lock_when_workspace_clean":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      if res.code != 0:
        checkpoint("output: " & res.output)
      # Best-effort contract: ALWAYS exit 0.
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["exitCode"].getInt() == 0
      # M19b: this fixture's store is a standalone `git init` with no remote,
      # so the record it just wrote can never be published to anyone. That is
      # reported as such. It is emphatically NOT "ok".
      check report["outcome"].getStr() == "written-local-only"
      check report["publication"].getStr() == "local-only"
      check report["lockWritten"].getBool()
      check report["project"].getStr() == "lib-a"
      check report["triggerRepo"].getStr() == "lib-a"
      check report["triggerSha"].getStr() == fx.libA.sha

      # RA-1: per-repo lock path ``locks/<project>/<repo>/<sha>.toml``,
      # no index written.
      let lockPath = report["lockFilePath"].getStr()
      check lockPath.len > 0
      check fileExists(lockPath)
      check lockPath == fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "lib-a" / (fx.libA.sha & ".toml")

      check report["indexFilePath"].getStr() == ""
      check not fileExists(fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "index.toml")

      # Log file has exactly one line, and that line states the record was
      # not published rather than implying it was.
      let logBody = readPostCommitLog(fx)
      check logBody.contains(" written-local-only ")
      check logBody.contains("NOT published")
      check not logBody.contains(" ok ")
      check logBody.splitLines().filterIt(it.len > 0).len == 1

  test "test_m19_post_commit_succeeds_when_workspace_dirty":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      # lib-b is dirty even though the operator just committed in lib-a.
      # Strict M11 ``workspace lock`` would refuse with exit 2; post-commit
      # must downgrade to exit 0 + ``outcome = "skipped-dirty"`` and NOT
      # write a lock file.
      writeFile(fx.workspaceRoot / "lib-b" / "scratch.txt",
        "uncommitted\n")

      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["exitCode"].getInt() == 0
      check report["outcome"].getStr() == "no-lock-dirty-siblings"
      check not report["lockWritten"].getBool()
      check report["publication"].getStr() == "no-record"
      # No lock file path recorded — the wrapper never reached the
      # writer phase.
      check report["lockFilePath"].getStr() == ""
      let lockDir = fx.workspaceRoot / ".repro" / "manifests" / "locks"
      check (not dirExists(lockDir)) or
        (toSeq(walkDirRec(lockDir, yieldFilter = {pcFile})).len == 0)

      # Log file carries exactly one line naming the offending sibling AND
      # stating that no lock exists — the old ``skipped-dirty`` wording
      # described the wrapper's control flow, not the outcome the operator
      # cares about.
      let logBody = readPostCommitLog(fx)
      check logBody.contains("no-lock-dirty-siblings")
      check logBody.contains("NO lock written")
      check logBody.contains("lib-b")

      # M19b mode 2 is LOUD: git relays post-commit's stderr, so the operator
      # learns at the terminal that this commit produced no lock. The two-week
      # starvation happened because this branch said nothing anywhere the
      # operator would look, while the blocking sibling rotated between repos.
      check res.output.contains("repro post-commit:")
      check res.output.contains("lib-b")

  test "test_m19_post_commit_succeeds_when_no_workspace_toml":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-workspace")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      # No seedWorkspaceToml call AND no resolved manifest checkout — the
      # workspace is genuinely uninitialized (RA-10 canonical marker
      # [Workspace-RepoWorkspaces-Alignment.milestones.org RA-10; hooksRoot
      # discovery walks up for a ``.repro/`` dir]: a bare ``.repro/`` with no
      # ``workspace.toml`` and no resolved ``projects/*.toml`` is NOT a
      # workspace). The wrapper must find that ``.repro/`` root and skip
      # silently, writing a ``skipped-no-workspace`` report. (``setupFixture``
      # seeds the flat ``projects/lib-a.toml`` membership manifest; RA-10 treats
      # a single resolvable project as an initialized workspace, so we strip it
      # here to model the genuine non-workspace case this test is about.)
      removeDir(fx.workspaceRoot / "projects")
      # Native RA-10 marker: the post-commit workspace-root discovery keys on a
      # ``.repro/`` directory. Without seedWorkspaceToml (which would create it)
      # there is none, so create the bare marker the "non-workspace" case models.
      createDir(fx.workspaceRoot / ".repro")

      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["exitCode"].getInt() == 0
      check report["outcome"].getStr() == "skipped-no-workspace"
      check report["lockFilePath"].getStr() == ""
      check report["project"].getStr() == ""

      let logBody = readPostCommitLog(fx)
      check logBody.contains("skipped-no-workspace")

  test "test_m19_post_commit_succeeds_when_lock_writer_fails":
    let gitBin = findExe("git")
    let isRoot =
      when defined(posix): geteuid() == 0
      else: false
    if gitBin.len == 0:
      skip()
    elif isRoot:
      # Root bypasses POSIX write permissions; the chmod-based fault
      # injection only fires for unprivileged users.
      skip()
    elif defined(windows):
      # Nim's ``setFilePermissions`` on Windows maps to ``_chmod``,
      # which only flips the read-only attribute on FILES and has no
      # effect on directories. A directory whose write bit is "removed"
      # remains fully writable to the current user, so the fault
      # injection this test relies on cannot fire. Proper fault
      # injection on Windows would require ACL changes via ``icacls``
      # or P/Invoke — out of scope for the M19 contract test, which is
      # about post-commit's downgrade behaviour, not about how we
      # provoke the underlying IO failure.
      skip()
    else:
      let fx = setupFixture(gitBin, "writer-fails")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      # Make the lock-store directory (``.repro/manifests``) read-only so the
      # lock writer cannot create the ``locks/lib-a/`` subdirectory. In the
      # native layout membership lives flat at the workspace root, so the
      # git-checkout lock store at ``.repro/manifests`` is created here (rather
      # than by ``setupFixture``) purely to inject the write fault. Strict M11
      # would propagate the OSError as exit 1; post-commit downgrades.
      let manifestsRoot = fx.workspaceRoot / ".repro" / "manifests"
      createDir(manifestsRoot)
      var perms = getFilePermissions(manifestsRoot)
      perms.excl(fpUserWrite)
      perms.excl(fpGroupWrite)
      perms.excl(fpOthersWrite)
      setFilePermissions(manifestsRoot, perms)
      defer:
        # Restore so the temp-dir teardown can rm -rf it.
        var restored = getFilePermissions(manifestsRoot)
        restored.incl(fpUserWrite)
        setFilePermissions(manifestsRoot, restored)

      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["exitCode"].getInt() == 0
      check report["outcome"].getStr() == "no-lock-failed"
      check not report["lockWritten"].getBool()
      check report["diagnostic"].getStr().len > 0

      let logBody = readPostCommitLog(fx)
      check logBody.contains("no-lock-failed")
      check logBody.contains("NO lock written")

      # M19b mode 3 is LOUD. One workspace ran this branch 68 times
      # (``repo '<x>' has no on-disk checkout``) and produced zero locks, every
      # run exiting 0 without a word at the terminal.
      check res.output.contains("repro post-commit:")

  test "test_m19_post_commit_log_file_appended_on_each_run":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "append")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      let firstRes = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check firstRes.code == 0
      let firstReport = readPostCommitReport(fx)
      check firstReport["outcome"].getStr() == "written-local-only"
      let firstTimestamp = firstReport["timestamp"].getStr()

      # Second run with a brand-new commit in lib-a so the trigger SHA
      # changes and a different lock filename is produced. The log file
      # must carry BOTH entries while the JSON report reflects only the
      # latest invocation.
      let libAPath = fx.workspaceRoot / "lib-a"
      writeFile(libAPath / "second.txt", "second commit\n")
      discard requireGit(q(gitBin) & " -C " & q(libAPath) & " add second.txt")
      discard requireGit(q(gitBin) & " -C " & q(libAPath) &
        " commit -m second")
      let secondSha = requireGit(q(gitBin) & " -C " & q(libAPath) &
        " rev-parse HEAD").strip()

      let secondRes = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check secondRes.code == 0
      let secondReport = readPostCommitReport(fx)
      check secondReport["outcome"].getStr() == "written-local-only"
      check secondReport["triggerSha"].getStr() == secondSha
      # ``post-commit-report.json`` is overwrite-not-append: the latest
      # invocation's SHA replaces the previous run's.
      check secondReport["triggerSha"].getStr() != fx.libA.sha
      let secondTimestamp = secondReport["timestamp"].getStr()

      # Log file is append-only: TWO non-empty lines, with the two distinct
      # timestamps from the two runs.
      let logBody = readPostCommitLog(fx)
      let lines = logBody.splitLines().filterIt(it.len > 0)
      check lines.len == 2
      check lines[0].startsWith(firstTimestamp)
      check lines[1].startsWith(secondTimestamp)
      for line in lines:
        check line.contains(" written-local-only ")

suite "M19b — post-commit reports publication, not just the write":

  test "test_m19b_unpublished_lock_is_never_reported_as_success":
    ## THE regression test. A post-commit run that produces no PUBLISHED lock
    ## must not report success — in the report, in the log, or in its wording.
    ##
    ## Reverting the wrapper to ``outcome = "ok"`` / ``diagnostic = "wrote
    ## <path>"`` fails this test on every one of the assertions below.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "pending")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)
      makeLockStorePublishable(gitBin, fx)

      # The commit post-commit fires on has not been pushed yet — this is the
      # ordinary case, and the resulting record is legitimately PENDING.
      let sha = commitInLibA(gitBin, fx, "pending.txt")

      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["exitCode"].getInt() == 0
      check report["triggerSha"].getStr() == sha

      # The record exists on disk...
      check report["lockWritten"].getBool()
      let lockPath = report["lockFilePath"].getStr()
      check fileExists(lockPath)

      # ...and that is ALL it does. The report says so.
      check report["outcome"].getStr() == "written-pending-publish"
      check report["publication"].getStr() == "pending"
      check report["outcome"].getStr() != "ok"
      check report["outcome"].getStr() != "published"
      check report["diagnostic"].getStr().contains("NOT published")

      # The store's upstream really does not have it — the report is not
      # merely asserting a label, it matches the git state.
      let store = lockStoreRoot(fx)
      let relPath = relativePath(lockPath, store)
      check runCmd(q(gitBin) & " -C " & q(store) & " cat-file -e " &
        q("origin/main:" & relPath.replace('\\', '/'))).code != 0

      let logBody = readPostCommitLog(fx)
      check logBody.contains(" written-pending-publish ")
      check logBody.contains("NOT published")
      check not logBody.contains(" ok ")

      # Pending-with-no-backlog is the DESIGNED steady state (post-commit is
      # local-only; pre-push publishes), so it is honest in the log without
      # shouting at the terminal on every single commit.
      check report["strandedRecords"].getInt() == 0
      check not res.output.contains("repro post-commit:")

  test "test_m19b_published_is_earned_by_reaching_the_upstream":
    ## The one outcome that reads as success, and what it costs to get it.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "published")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)
      makeLockStorePublishable(gitBin, fx)
      discard commitInLibA(gitBin, fx, "published.txt")

      # First run writes the record; nothing has published it.
      check invokePostCommit(fx, fx.workspaceRoot / "lib-a").code == 0
      check readPostCommitReport(fx)["outcome"].getStr() ==
        "written-pending-publish"

      # Publish it the way the pre-push gate would, then re-run post-commit at
      # the same SHA (the idempotent re-lock path).
      publishLockStore(gitBin, fx)
      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["outcome"].getStr() == "published"
      check report["publication"].getStr() == "published"
      check report["pendingRecords"].getInt() == 0
      check report["strandedRecords"].getInt() == 0
      # Read the tag FIELD of the latest log line rather than searching the
      # whole file: the first run's ``... — NOT published (...)`` also contains
      # the word, and a substring match would pass on it.
      let lastLine = readPostCommitLog(fx).splitLines()
        .filterIt(it.len > 0)[^1]
      check lastLine.split(' ')[1] == "published"
      # A genuinely published record is the one thing worth staying quiet about.
      check not res.output.contains("repro post-commit:")

  test "test_m19b_records_stranded_behind_pushed_commits_are_loud":
    ## The two-week starvation, reproduced. A lock record whose trigger commit
    ## has ALREADY been pushed is not "publication has not happened yet" — it
    ## is proof that a push went out and left its lock behind. That is not the
    ## designed steady state and it does not get to be quiet.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "stranded")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)
      makeLockStorePublishable(gitBin, fx)

      # Commit, lock, push the commit — and never publish the lock. Exactly
      # the sequence that left 20 untracked records in one workspace's store.
      discard commitInLibA(gitBin, fx, "stranded-one.txt")
      check invokePostCommit(fx, fx.workspaceRoot / "lib-a").code == 0
      discard requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") & " push origin main")

      # The next commit's post-commit run can now SEE the stranded predecessor.
      discard commitInLibA(gitBin, fx, "stranded-two.txt")
      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-a")
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["outcome"].getStr() == "written-pending-publish"
      check report["pendingRecords"].getInt() >= 2
      check report["strandedRecords"].getInt() >= 1
      check report["diagnostic"].getStr().contains("ALREADY-PUSHED")

      # Loud at the terminal, and still exit 0 — a post-commit hook that
      # blocked commits would be a worse defect than the one it reports.
      check res.output.contains("repro post-commit:")
      check res.output.contains("ALREADY-PUSHED")

  test "test_ra30_lock_is_anchored_at_the_repo_whose_commit_fired_the_hook":
    ## RA-30 — the anchor is the addressing scheme, not a label.
    ##
    ## A consumer resolves a lock at ``locks/<project>/<repo>/<sha>`` for the
    ## COMMIT UNDER TEST: the `clone-siblings` CI action probes exactly that
    ## path for the pushed repo and fails the job when it is absent. So a lock
    ## written for a lib-b commit but filed under lib-a is not "filed
    ## differently" — it is unreachable, keyed by a SHA (lib-a's HEAD) that no
    ## consumer of lib-b will ever look up.
    ##
    ## Every case above this one dispatches from lib-a, which is BOTH the
    ## project name and the fallback anchor, so they cannot tell a resolved
    ## anchor from a defaulted one. This one dispatches from lib-b.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "anchor")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      let libBSha = commitInRepo(gitBin, fx, "lib-b", "in-lib-b.txt")
      check libBSha != fx.libA.sha

      let res = invokePostCommit(fx, fx.workspaceRoot / "lib-b")
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["lockWritten"].getBool()
      # The trigger is the committed repo and ITS new commit — not the
      # project-named repo and not lib-a's untouched HEAD.
      check report["triggerRepo"].getStr() == "lib-b"
      check report["triggerSha"].getStr() == libBSha

      let lockPath = report["lockFilePath"].getStr()
      check lockPath == fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "lib-b" / (libBSha & ".toml")
      check fileExists(lockPath)

      # ...and nothing was filed under the project anchor. Before RA-30 this
      # exact run wrote ``locks/lib-a/lib-a/<lib-a HEAD>.toml``: a record whose
      # name claimed a commit the hook never saw.
      check not dirExists(fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "lib-a")

      # The body is still the whole workspace — only the ADDRESS changed.
      # Each revision is read out of its OWN ``[[repo]]`` entry: "lib-c is
      # pinned at lib-c's head" is the claim, and a whole-file substring
      # search cannot make it.
      let body = readFile(lockPath)
      check lockedRevision(body, "lib-b") == libBSha
      check lockedRevision(body, "lib-a") == fx.libA.sha
      check lockedRevision(body, "lib-c") == fx.libC.sha

  test "test_ra30_undeclared_triggering_repo_writes_no_lock_and_says_so":
    ## The other half of the same decision. When the hook fires in a checkout
    ## the project does not declare, there is no anchor that any consumer of
    ## that checkout could resolve, so there is no lock worth writing. The old
    ## fallback wrote one anyway, under the project anchor's name and SHA.
    ##
    ## Refusing is the honest answer, and post-commit's contract still holds:
    ## it says what did not happen, at the terminal, and exits 0.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "undeclared")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      # The lock store itself is a git checkout inside the workspace, and it
      # is emphatically not a declared project repo.
      let undeclared = lockStoreRoot(fx)
      let res = invokePostCommit(fx, undeclared)
      check res.code == 0

      let report = readPostCommitReport(fx)
      check report["outcome"].getStr() == "no-lock-failed"
      check not report["lockWritten"].getBool()
      check report["diagnostic"].getStr().contains("is not declared in project")
      check report["diagnostic"].getStr().contains("NO lock written")
      check res.output.contains("repro post-commit:")

      check not dirExists(fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "lib-a")

  test "test_ra31_gate_supersedes_its_own_unpublished_draft":
    ## RA-31 — an untracked file at the lock path is a draft, not history.
    ##
    ## Two hooks legitimately address the same key. post-commit writes
    ## ``locks/<p>/<repo>/<sha>`` when a commit lands; the pre-push gate writes
    ## the SAME key when that commit is pushed. The key is (trigger repo,
    ## trigger sha), so a sibling committing in between does not move it — but
    ## it does move the coordinates the record carries.
    ##
    ## The immutability rule was testing ``fileExists``, so the second write
    ## found the first one's uncommitted draft, saw the sibling had moved, and
    ## refused. In the real workspace that refusal surfaced as a REFUSED PUSH:
    ##   lock-failure — immutable lock record already exists at
    ##   'locks/app/lib/<libSha>.toml' with different repository coordinates
    ##   (changed paths: app, other)
    ## The draft was strictly less complete than the record being written.
    ## Superseding it is what "refresh the lock" means.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "ra31-draft")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)

      let libBSha = commitInRepo(gitBin, fx, "lib-b", "in-lib-b.txt")
      check invokePostCommit(fx, fx.workspaceRoot / "lib-b").code == 0
      let lockPath = fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "lib-b" / (libBSha & ".toml")
      check fileExists(lockPath)
      # The draft records lib-a at its ORIGINAL head, because that is where
      # lib-a stood when the lib-b commit fired the hook.
      check lockedRevision(readFile(lockPath), "lib-a") == fx.libA.sha
      # It is a draft precisely because nothing has committed it.
      check runCmd(q(gitBin) & " -C " & q(lockStoreRoot(fx)) &
        " ls-files --error-unmatch -- " &
        q("locks/lib-a/lib-b/" & libBSha & ".toml")).code != 0

      # A sibling moves. lib-b's HEAD does not, so the key does not either.
      let libASha = commitInRepo(gitBin, fx, "lib-a", "in-lib-a.txt")
      check libASha != fx.libA.sha

      let second = invokePostCommit(fx, fx.workspaceRoot / "lib-b")
      if second.code != 0:
        checkpoint("output: " & second.output)
      check second.code == 0
      let report = readPostCommitReport(fx)
      # Before RA-31 this was `no-lock-failed`, with the immutability refusal
      # as its diagnostic, and the record still carried the stale lib-a SHA.
      check report["lockWritten"].getBool()
      check report["triggerRepo"].getStr() == "lib-b"
      check report["triggerSha"].getStr() == libBSha
      check not report["diagnostic"].getStr().contains("immutable lock record")
      let refreshed = readFile(lockPath)
      # lib-a's OWN entry now names lib-a's new head...
      check lockedRevision(refreshed, "lib-a") == libASha
      # ...and the superseded revision survives nowhere in the record. This
      # second check is the regression proper — before RA-31 the refreshed
      # record still carried the pre-refresh SHA — and it is deliberately
      # kept as a whole-record statement: no entry, lib-a's or anyone's, may
      # still point at the stale commit.
      check not refreshed.contains("revision = \"" & fx.libA.sha & "\"")

  test "test_ra31_a_published_record_is_still_immutable":
    ## The other half: RA-31 narrows the rule, it does not remove it. Once the
    ## record is TRACKED it is history, and history is what must not be
    ## rewritten — the refusal must survive verbatim.
    ##
    ## Identical to the case above except that the lock store is committed and
    ## pushed in between, which is the only difference that should matter.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "ra31-published")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      seedWorkspaceToml(fx)
      makeLockStorePublishable(gitBin, fx)

      let libBSha = commitInRepo(gitBin, fx, "lib-b", "in-lib-b.txt")
      check invokePostCommit(fx, fx.workspaceRoot / "lib-b").code == 0
      let lockPath = fx.workspaceRoot / ".repro" / "manifests" /
        "locks" / "lib-a" / "lib-b" / (libBSha & ".toml")
      check fileExists(lockPath)
      let publishedBody = readFile(lockPath)

      # Publish it: now git tracks the record, so it is history.
      publishLockStore(gitBin, fx)
      check runCmd(q(gitBin) & " -C " & q(lockStoreRoot(fx)) &
        " ls-files --error-unmatch -- " &
        q("locks/lib-a/lib-b/" & libBSha & ".toml")).code == 0

      let libASha = commitInRepo(gitBin, fx, "lib-a", "in-lib-a.txt")
      check libASha != fx.libA.sha

      let second = invokePostCommit(fx, fx.workspaceRoot / "lib-b")
      # post-commit never blocks a commit, so the refusal arrives as a report,
      # not as an exit code.
      check second.code == 0
      let report = readPostCommitReport(fx)
      check not report["lockWritten"].getBool()
      check report["diagnostic"].getStr().contains(
        "immutable lock record already exists")
      # And the published bytes are untouched.
      check readFile(lockPath) == publishedBody
