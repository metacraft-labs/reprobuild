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
##   1. Happy path — clean workspace → lock TOML + index written +
##      JSON report carries ``outcome = "ok"`` + exit 0.
##   2. Dirty workspace → strict M11 would have refused with exit 2;
##      post-commit downgrades to ``outcome = "skipped-dirty"`` + exit 0
##      and writes NO lock file.
##   3. No ``.repo/workspace.toml`` → wrapper logs
##      ``outcome = "skipped-no-workspace"`` + exit 0 without touching
##      the (missing) manifest layer.
##   4. Lock writer fails (manifests/ directory made non-writable) →
##      wrapper logs ``outcome = "failed"`` with a diagnostic + exit 0.
##   5. Two consecutive invocations → log file has TWO lines, JSON
##      report carries the second (latest) invocation only.
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

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m19-postcommit-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M19 Tester\"")
  writeFile(workPath / "README.md", "M19 fixture\n")
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

proc readPostCommitLog(fx: M19Fixture): string =
  let logPath = fx.workspaceRoot / ".repro" / "workspace" /
    "post-commit-lock.log"
  if not fileExists(logPath):
    return ""
  readFile(logPath)

# ---- the suite -------------------------------------------------------------

suite "M19 — repro hooks dispatch post-commit (best-effort lock)":

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
      check report["outcome"].getStr() == "ok"
      check report["project"].getStr() == "lib-a"
      check report["triggerRepo"].getStr() == "lib-a"
      check report["triggerSha"].getStr() == fx.libA.sha

      let lockPath = report["lockFilePath"].getStr()
      check lockPath.len > 0
      check fileExists(lockPath)
      check lockPath.startsWith(
        fx.workspaceRoot / ".repo" / "manifests" / "locks" / "lib-a" / "lib-a-")

      let indexPath = report["indexFilePath"].getStr()
      check fileExists(indexPath)

      # Log file has exactly one ``ok`` line.
      let logBody = readPostCommitLog(fx)
      check logBody.contains(" ok ")
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
      check report["outcome"].getStr() == "skipped-dirty"
      # No lock file path recorded — the wrapper never reached the
      # writer phase.
      check report["lockFilePath"].getStr() == ""
      let lockDir = fx.workspaceRoot / ".repo" / "manifests" / "locks"
      check (not dirExists(lockDir)) or
        (toSeq(walkDirRec(lockDir, yieldFilter = {pcFile})).len == 0)

      # Log file carries exactly one ``skipped-dirty`` line naming the
      # offending sibling so the operator can find it.
      let logBody = readPostCommitLog(fx)
      check logBody.contains("skipped-dirty")
      check logBody.contains("lib-b")

  test "test_m19_post_commit_succeeds_when_no_workspace_toml":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-workspace")
      defer: removeDir(fx.scratch)
      cloneAll(gitBin, fx)
      # No seedWorkspaceToml call — the wrapper must skip silently.

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

      # Make the manifest-layer directory read-only so the lock writer
      # cannot create the ``locks/lib-a/`` subdirectory. Strict M11
      # would propagate the OSError as exit 1; post-commit downgrades.
      let manifestsRoot = fx.workspaceRoot / ".repo" / "manifests"
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
      check report["outcome"].getStr() == "failed"
      check report["diagnostic"].getStr().len > 0

      let logBody = readPostCommitLog(fx)
      check logBody.contains("failed")

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
      check firstReport["outcome"].getStr() == "ok"
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
      check secondReport["outcome"].getStr() == "ok"
      check secondReport["triggerSha"].getStr() == secondSha
      # ``post-commit-report.json`` is overwrite-not-append: the latest
      # invocation's SHA replaces the previous run's.
      check secondReport["triggerSha"].getStr() != fx.libA.sha
      let secondTimestamp = secondReport["timestamp"].getStr()

      # Log file is append-only: TWO non-empty lines, both ``ok``, with
      # the two distinct timestamps from the two runs.
      let logBody = readPostCommitLog(fx)
      let lines = logBody.splitLines().filterIt(it.len > 0)
      check lines.len == 2
      check lines[0].startsWith(firstTimestamp)
      check lines[1].startsWith(secondTimestamp)
      for line in lines:
        check line.contains(" ok ")
