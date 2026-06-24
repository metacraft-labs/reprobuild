## RA-23 — ``repro workspace sync`` clones newly-declared dependencies.
##
## ``repro sync`` must behave like ``git submodule update --init
## --recursive``: in addition to UPDATING existing checkouts to their
## locked/declared revision, it CLONES any develop-mode dependency that is
## declared in the resolved manifest but not yet present on disk — e.g. a
## repo a teammate added. Cloning reuses RA-5c's parallel clone/fetch path
## (the ``vcs/fetch`` pool + the RA-5 shared object cache). An unreadable /
## private new repo is REPORTED + SKIPPED, not fatal.
##
## This test models "a teammate added repos B and C":
##   - ``lib-a`` is already CHECKED OUT and fast-forwardable to its upstream.
##   - ``lib-b`` is DECLARED (reachable local bare origin) but NOT present —
##     sync must CLONE it and converge it to the declared revision.
##   - ``lib-c`` is DECLARED with an UNREADABLE origin (the bare repo does
##     not exist) — sync must REPORT + SKIP it without aborting.
##
## Assertions:
##   - lib-b's working tree + ``.git`` now exist and HEAD is the declared
##     revision (sync cloned the newly-declared dependency).
##   - lib-a was still updated to its own upstream tip (no regression to the
##     existing update path).
##   - The per-repo summary names lib-b as newly-cloned (``action == clone``,
##     ``executionStatus == cloned``, ``syncCase == missing_checkout``).
##   - lib-c is reported (``executionStatus == skipped`` with a reason) and
##     sync did NOT hard-fail because of it; lib-a and lib-b still succeed.
##
## Falsifiability: if sync only UPDATED existing checkouts (the pre-RA-23
## behavior), lib-b would stay uncloned (its working tree absent) and its
## report entry would not be ``cloned`` — every B assertion below would fail.
## Confirmed by hand: disabling the clone-missing branch leaves B uncloned.
##
## Hermetic: local ``git init --bare`` origins, no network. Skip: ``git``
## missing on PATH.

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

proc seedGitOrigin(gitBin, originPath, workPath, branch: string): string =
  ## Create a bare origin on ``branch`` with one commit, returning the SHA.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA23 Tester\"")
  writeFile(workPath / "README.md", "RA23 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedSecondCommit(gitBin, originPath, workPath, branch: string): string =
  writeFile(workPath / "next.txt", "second\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add next.txt")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m \"second commit\"")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"RA23 Tester\"")

proc headSha(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

# ---- manifest TOML --------------------------------------------------------

proc projectToml(aUrl, bUrl, cUrl: string): string =
  ## A project that declares lib-a (present), lib-b (reachable, NOT present)
  ## and lib-c (unreadable origin, NOT present). This is the post-pull state
  ## a teammate's manifest edit leaves behind.
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"dev\"\n" &
    "trunk = \"dev\"\n\n" &
    "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
    "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
    "[[remote]]\nname = \"c-origin\"\nfetch = \"" & cUrl & "\"\n\n" &
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
remote = "a-origin"
revision = "dev"
"""

const libBFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-b"
path = "lib-b"
remote = "b-origin"
revision = "dev"
"""

const libCFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-c"
path = "lib-c"
remote = "c-origin"
revision = "dev"
"""

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    aOrigin, aSeed: string
    bOrigin, bSeed: string
    cOriginMissing: string

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-ra23sync-", "")
  result.reproBin = reproBinary()

  result.aOrigin = result.scratch / "origin-lib-a.git"
  result.aSeed = result.scratch / "seed-lib-a"
  discard seedGitOrigin(gitBin, result.aOrigin, result.aSeed, "dev")

  result.bOrigin = result.scratch / "origin-lib-b.git"
  let bSeed = result.scratch / "seed-lib-b"
  result.bSeed = bSeed
  discard seedGitOrigin(gitBin, result.bOrigin, bSeed, "dev")

  # lib-c's origin path is DECLARED but never created — an unreadable repo.
  result.cOriginMissing = result.scratch / "origin-lib-c-does-not-exist.git"

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "projects" / "myproject.toml",
    projectToml(
      fileUrl(result.aOrigin), fileUrl(result.bOrigin),
      fileUrl(result.cOriginMissing)))
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-b.toml", libBFragmentToml)
  writeFile(manifestsRoot / "repos" / "lib-c.toml", libCFragmentToml)
  result.workspaceRoot = workspaceRoot

proc invokeSync(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
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

suite "RA-23 — sync clones newly-declared dependencies":

  test "t_sync_clones_newly_declared_dependency_after_pull":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin)
      defer: removeDir(fx.scratch)

      # Only lib-a is checked out. lib-b and lib-c are declared-but-missing,
      # exactly as a teammate's manifest edit leaves the workspace after a
      # pull.
      cloneInto(gitBin, fx.aOrigin, fx.workspaceRoot / "lib-a")
      check dirExists(fx.workspaceRoot / "lib-a" / ".git")
      check not dirExists(fx.workspaceRoot / "lib-b")
      check not dirExists(fx.workspaceRoot / "lib-c")

      # Advance lib-a's upstream so the existing-update path has real work.
      let advancedA = seedSecondCommit(gitBin, fx.aOrigin, fx.aSeed, "dev")
      # Record lib-b's declared (origin) tip so we can prove convergence.
      let bDeclaredSha = headSha(gitBin, fx.bSeed)

      let res = invokeSync(fx)
      if res.code notin [0, 2]:
        checkpoint("sync output: " & res.output)
      # An unreadable NEW repo must NOT make the whole sync fail fatally
      # (exit 1). 0 (all converged) or 2 (an unrelated report-only refusal)
      # are acceptable; 1 (fatal failure) is NOT.
      check res.code != 1
      check res.code in [0, 2]

      # --- lib-b: the newly-declared dependency was CLONED + converged. ---
      check dirExists(fx.workspaceRoot / "lib-b")
      check dirExists(fx.workspaceRoot / "lib-b" / ".git")
      check headSha(gitBin, fx.workspaceRoot / "lib-b") == bDeclaredSha

      # --- lib-a: existing checkout still updated (no regression). ---
      check headSha(gitBin, fx.workspaceRoot / "lib-a") == advancedA

      let report = readReport(fx)

      # The summary names lib-b as NEWLY-CLONED, distinct from an update.
      let bEntry = repoEntry(report, "lib-b")
      check bEntry["syncCase"].getStr() == "missing_checkout"
      check bEntry["action"].getStr() == "clone"
      check bEntry["executionStatus"].getStr() == "cloned"

      # lib-a is reported as an ordinary fast-forward update (NOT a clone).
      let aEntry = repoEntry(report, "lib-a")
      check aEntry["syncCase"].getStr() == "clean_fast_forwardable"
      check aEntry["action"].getStr() == "fetch_fast_forward"
      check aEntry["executionStatus"].getStr() == "succeeded"

      # --- lib-c: the unreadable new repo is REPORTED + SKIPPED, not fatal. ---
      check not dirExists(fx.workspaceRoot / "lib-c" / ".git")
      let cEntry = repoEntry(report, "lib-c")
      check cEntry["syncCase"].getStr() == "missing_checkout"
      check cEntry["action"].getStr() == "clone"
      check cEntry["executionStatus"].getStr() == "skipped"
      # A reason is attached so the operator knows WHY it was skipped.
      check cEntry["executionDiagnostic"].getStr().len > 0
