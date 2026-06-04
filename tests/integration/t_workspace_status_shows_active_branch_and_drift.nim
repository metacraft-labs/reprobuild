## M12 — ``repro workspace status``.
##
## Integration test for the read-only status subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace status`` to ``runWorkspaceStatusCommand``,
## which:
##
##   1. Resolves the named project / variant via the M6 surface (or
##      composes layers via M8 when ``.repo/workspace.toml`` is
##      present). The single-project / M6 path is exercised here.
##   2. For every declared repo, gathers the live M4 evidence triple
##      (head-sha, is-clean, is-published).
##   3. Loads the M11 lock-index (when present) and compares each
##      live HEAD against the most-recently-locked SHA — ``at-lock``,
##      ``drifted-from-lock``, or ``no-lock-recorded``.
##   4. Emits ``<workspaceRoot>/.repro/workspace/status-report.json``
##      plus a structured stdout summary; exits 0.
##
## Fixture pattern matches M9 / M10 / M11: hermetic local bare git
## repos stand in for the manifest's remote URLs, the workspace tree
## holds the ``.repo/manifests/`` TOMLs, and the test compiles ``repro``
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

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m12-workspace-status-repro",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

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
    fx.reproBin, "workspace", "status", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for x in extra: argv.add(x)
  runShell(shellCommand(argv))

proc readReport(fx: M12Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
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
      # M11 lock-index to compare against.
      for entry in report["repos"]:
        check entry["lockState"].getStr() == "no-lock-recorded"
        check entry["lockedRevision"].getStr().len == 0
