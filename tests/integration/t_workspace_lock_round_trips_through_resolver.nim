## M11 — ``repro workspace lock``.
##
## End-to-end integration test for the new subcommand. The CLI
## dispatcher in ``libs/repro_cli_support/src/repro_cli_support.nim``
## routes ``repro workspace lock`` to ``runWorkspaceLockCommand``,
## which:
##
##   1. Resolves the named project / variant via the M6 surface (or
##      composes layers via M8 when ``.repo/workspace.toml`` is
##      present). The fixtures here exercise the single-project /
##      M6 path: ``.repo/manifests/projects/<project>.toml``.
##   2. Picks the manifest layer that will OWN the lock file. With no
##      composer overlay this falls through to
##      ``<workspaceRoot>/.repo/manifests/``.
##   3. For every declared repo, gathers the live HEAD SHA via the M2
##      ``headShaQuery`` adapter plus the clean/dirty and
##      current-branch observations.
##   4. Refuses-and-reports on any dirty checkout (exit code 2);
##      otherwise builds the in-memory ``WorkspaceLockFile`` and the
##      matching index entry, writes both files, and emits the
##      structured JSON report at
##      ``<workspaceRoot>/.repro/workspace/lock-report.json``.
##
## The round-trip property: the lock TOML must read back through the
## M5 strict reader (``readLock``) and reproduce the same
## ``(name, path, remote, revision)`` tuples the live workspace
## carries — that's what "round_trips_through_resolver" means here.
##
## Fixture pattern matches M9 / M10: one or more hermetic local bare
## git repos stand in for the manifest's remote URLs; a workspace tree
## holds the ``.repo/manifests/`` TOMLs. Three repos in the project
## (per the milestone spec for "round_trips_through_resolver") so the
## per-repo iteration is exercised.
##
## Skip rule: only when ``git`` is missing from PATH (same convention
## as M2 / M3 / M8 / M9 / M10).

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

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
  ## Bare origin with one commit; mirrors M9 / M10's seed pattern.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M11 Tester\"")
  writeFile(workPath / "README.md", "M11 fixture\n")
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
    " config user.name \"M11 Tester\"")

proc dirtyTheTree(repoPath: string) =
  writeFile(repoPath / "dirty.txt", "uncommitted\n")

# ---- manifest TOML strings ------------------------------------------------

proc projectTomlWith3Remotes(libAUrl, libBUrl, libCUrl: string): string =
  ## Project manifest declaring three repos. The project name matches
  ## ``lib-a`` (the trigger anchor) so the lock filename uses
  ## ``lib-a-<short>.toml`` deterministically. We pick "lib-a" as the
  ## project name so the M11 ``pickTriggerRepo`` heuristic
  ## ("repo whose name matches the project name") finds it without an
  ## explicit ``--trigger-repo`` flag.
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

  M11Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libA: RepoSeed
    libB: RepoSeed
    libC: RepoSeed

proc setupFixture(gitBin, slug: string): M11Fixture =
  result.scratch = createTempDir("repro-m11-" & slug & "-", "")
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

proc cloneAll(gitBin: string; fx: M11Fixture) =
  cloneInto(gitBin, fx.libA.origin, fx.workspaceRoot / "lib-a")
  cloneInto(gitBin, fx.libB.origin, fx.workspaceRoot / "lib-b")
  cloneInto(gitBin, fx.libC.origin, fx.workspaceRoot / "lib-c")

proc invokeLock(fx: M11Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock", "lib-a",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: M11Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "lock-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite -------------------------------------------------------------

suite "M11 — repro workspace lock (round-trips through resolver)":

  test "test_m11_lock_clean_workspace_round_trips_through_resolver":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "clean-round-trip")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)

      let res = invokeLock(fx)
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0

      let report = readReport(fx)
      check report["exitCode"].getInt() == 0
      check report["project"].getStr() == "lib-a"
      check report["triggerRepo"].getStr() == "lib-a"
      check report["triggerSha"].getStr() == fx.libA.sha
      check report["repos"].len == 3

      # Lock file lives at the canonical path under the manifest layer
      # the dispatcher picks for single-project mode.
      let lockPath = report["lockFilePath"].getStr()
      check fileExists(lockPath)
      check lockPath.startsWith(
        fx.workspaceRoot / ".repo" / "manifests" / "locks" / "lib-a" / "lib-a-")
      check lockPath.endsWith(".toml")

      let indexPath = report["indexFilePath"].getStr()
      check fileExists(indexPath)
      check indexPath == fx.workspaceRoot / ".repo" / "manifests" /
        "locks" / "lib-a" / "index.toml"

      # Round-trip the lock TOML through the M5 strict reader and
      # confirm it reproduces the same (name, path, remote, revision)
      # tuples the live resolver would produce.
      let parsed = readLock(lockPath)
      check parsed.lock.project == "lib-a"
      check parsed.repo.len == 3

      var byName = initTable[string, LockedRepo]()
      for r in parsed.repo:
        byName[r.name] = r

      check byName["lib-a"].path == "lib-a"
      check byName["lib-a"].remote == "lib-a-origin"
      check byName["lib-a"].revision == fx.libA.sha
      check byName["lib-b"].path == "lib-b"
      check byName["lib-b"].remote == "lib-b-origin"
      check byName["lib-b"].revision == fx.libB.sha
      check byName["lib-c"].path == "lib-c"
      check byName["lib-c"].remote == "lib-c-origin"
      check byName["lib-c"].revision == fx.libC.sha

      # The index TOML must carry a single entry pointing at the lock
      # file we just wrote.
      let index = readLockIndex(indexPath)
      check index.entry.len == 1
      check index.entry[0].trigger_repo == "lib-a"
      check index.entry[0].trigger_sha == fx.libA.sha
      check index.entry[0].lock_file ==
        "locks/lib-a/" & extractFilename(lockPath)

  test "test_m11_lock_idempotent_when_rerun_at_same_sha":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "idempotent")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)

      let firstRes = invokeLock(fx)
      check firstRes.code == 0
      let firstReport = readReport(fx)
      let lockPath = firstReport["lockFilePath"].getStr()
      let indexPath = firstReport["indexFilePath"].getStr()
      check fileExists(lockPath)
      let firstLockBody = readFile(lockPath)
      let firstIndexBody = readFile(indexPath)

      # Re-run with no workspace mutation. The lock and index file
      # paths must match (same trigger SHA → same filename), the
      # index entry must be replaced rather than appended (still one
      # entry), and the round-trip-stable repo tuples must remain.
      let secondRes = invokeLock(fx)
      check secondRes.code == 0
      let secondReport = readReport(fx)
      check secondReport["lockFilePath"].getStr() == lockPath
      check secondReport["indexFilePath"].getStr() == indexPath
      check secondReport["replacedExistingEntry"].getBool() == true

      # The lock body bytes are identical aside from the created_at
      # timestamp (which the writer regenerates on every invocation).
      # We verify the substantive content by checking the index still
      # has exactly one entry and the round-tripped repo tuples are
      # unchanged.
      let index = readLockIndex(indexPath)
      check index.entry.len == 1
      check index.entry[0].trigger_repo == "lib-a"
      check index.entry[0].trigger_sha == fx.libA.sha

      let parsed = readLock(lockPath)
      check parsed.repo.len == 3
      var revs = initTable[string, string]()
      for r in parsed.repo: revs[r.name] = r.revision
      check revs["lib-a"] == fx.libA.sha
      check revs["lib-b"] == fx.libB.sha
      check revs["lib-c"] == fx.libC.sha

      # The lock body must still parse and emit non-empty bytes (sanity).
      check firstLockBody.len > 0
      check firstIndexBody.len > 0
      check readFile(lockPath).len > 0

  test "test_m11_lock_dirty_workspace_refuses":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "dirty")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)
      dirtyTheTree(fx.workspaceRoot / "lib-b")

      let res = invokeLock(fx)
      # Dirty workspace policy: refuse-and-report, exit code 2.
      check res.code == 2

      let report = readReport(fx)
      check report["exitCode"].getInt() == 2
      check report["dirty"].len == 1
      check report["dirty"][0]["path"].getStr() == "lib-b"
      # The lock file path is intentionally empty on refuse so the
      # caller knows no file was written.
      check report["lockFilePath"].getStr().len == 0

      # No lock file or index should be on disk for this run.
      let locksDir = fx.workspaceRoot / ".repo" / "manifests" / "locks"
      if dirExists(locksDir):
        # Allow the directory to exist if some other code created it;
        # what matters is that no lock_file or index_file was written
        # by this refused invocation.
        check not fileExists(locksDir / "lib-a" / "index.toml")

      # Dirty file must remain on disk — the lock command must not
      # have touched the working tree.
      check fileExists(fx.workspaceRoot / "lib-b" / "dirty.txt")

  test "test_m11_lock_index_updated_for_new_sha":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "new-sha")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)

      let firstRes = invokeLock(fx)
      check firstRes.code == 0
      let firstReport = readReport(fx)
      let firstLockPath = firstReport["lockFilePath"].getStr()

      # Advance the trigger repo (lib-a) by adding a local commit
      # directly inside the workspace checkout. This new SHA is
      # already local (committed), so the working tree is still
      # clean.
      writeFile(fx.workspaceRoot / "lib-a" / "advance.txt", "advance\n")
      discard requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") & " add advance.txt")
      discard requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") &
        " commit -m \"advance the trigger\"")
      let newSha = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-a") & " rev-parse HEAD").strip()
      check newSha != fx.libA.sha

      let secondRes = invokeLock(fx)
      check secondRes.code == 0
      let secondReport = readReport(fx)
      let secondLockPath = secondReport["lockFilePath"].getStr()
      check secondLockPath != firstLockPath
      check fileExists(secondLockPath)
      check fileExists(firstLockPath) # first lock still on disk
      check secondReport["replacedExistingEntry"].getBool() == false
      check secondReport["triggerSha"].getStr() == newSha

      let indexPath = secondReport["indexFilePath"].getStr()
      let index = readLockIndex(indexPath)
      check index.entry.len == 2

      var triggerShas: seq[string]
      for e in index.entry: triggerShas.add(e.trigger_sha)
      check fx.libA.sha in triggerShas
      check newSha in triggerShas

  test "test_m11_lock_report_json_well_formed":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "json-report")
      defer: removeDir(fx.scratch)

      cloneAll(gitBin, fx)

      let res = invokeLock(fx)
      check res.code == 0

      let report = readReport(fx)
      # Every key the renderer / downstream consumers depend on must
      # be present and well-typed.
      check report.kind == JObject
      check report.hasKey("project")
      check report.hasKey("workspaceRoot")
      check report.hasKey("manifestLayerRoot")
      check report.hasKey("lockFilePath")
      check report.hasKey("indexFilePath")
      check report.hasKey("triggerRepo")
      check report.hasKey("triggerSha")
      check report.hasKey("createdAt")
      check report.hasKey("workspaceBranch")
      check report.hasKey("replacedExistingEntry")
      check report.hasKey("repos")
      check report.hasKey("dirty")
      check report.hasKey("exitCode")

      check report["repos"].kind == JArray
      check report["dirty"].kind == JArray
      check report["exitCode"].getInt() == 0

      # ``createdAt`` must follow the RFC-3339 / Z-suffixed form the
      # spec uses (e.g. ``2026-06-02T10:14:33Z``).
      let createdAt = report["createdAt"].getStr()
      check createdAt.endsWith("Z")
      check createdAt.len >= 20

      # ``triggerSha`` must be a full SHA-1 hex (40 chars), as the
      # spec example shows.
      check report["triggerSha"].getStr().len == 40

      # Per-repo entries have the documented shape.
      for entry in report["repos"]:
        check entry.hasKey("name")
        check entry.hasKey("path")
        check entry.hasKey("remote")
        check entry.hasKey("revision")
        check entry.hasKey("branch")
        check entry["revision"].getStr().len == 40
