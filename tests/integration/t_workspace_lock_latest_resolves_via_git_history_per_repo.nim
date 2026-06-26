## RA-1 — latest workspace lock resolves via Git history over the
## per-repo lock subtree, with NO shared index.
##
## The Workspace-Manifests RA-1 design (pilot ``418f109``) stores locks
## under a per-repo directory ``locks/<project>/<repo>/<sha>.toml`` and
## drops the committed ``index.toml``. The "latest published lock for
## repo X" lookup is therefore a Git-history query
## (``git log -1 -- locks/<project>/<repo>/``) rather than an index read.
##
## This test drives the ACTUAL resolver code path
## (``latestLockRelPathForRepoViaGit`` in ``repro_cli_support``):
##
##   1. Build a real git manifest repo.
##   2. Commit TWO locks under ``locks/<p>/A/`` (an older SHA, then a
##      newer SHA), as two distinct commits.
##   3. Adversarially bump the OLDER lock file's mtime to be *newer*
##      than the second so a naive filesystem-mtime sort would pick the
##      wrong file — only Git history yields the correct "latest".
##   4. Assert the resolver returns the second (latest-by-git-log) lock
##      and reads no ``index.toml`` (there is none on disk).
##
## Skip rule: only when ``git`` is missing from PATH.

import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_cli_support
import repro_workspace_manifests
import git_tool

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

proc minimalLockToml(project, repo, sha: string): string =
  ## A minimal but strict-reader-valid lock body. ``readLock`` requires
  ## a non-empty project + created_at and at least the per-repo identity
  ## tuple. The trigger SHA is recorded as repo ``A``'s revision.
  "schema = \"reprobuild.workspace.lock.v1\"\n\n" &
  "[lock]\n" &
  "project = \"" & project & "\"\n" &
  "created_at = \"2026-06-02T10:14:33Z\"\n\n" &
  "[[repo]]\n" &
  "name = \"" & repo & "\"\n" &
  "path = \"" & repo & "\"\n" &
  "remote = \"origin\"\n" &
  "revision = \"" & sha & "\"\n"

suite "RA-1 — latest lock resolves via git history (per-repo)":

  test "t_workspace_lock_latest_resolves_via_git_history_per_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra1-latest-", "")
      defer: removeDir(scratch)

      let project = "demo"
      let repo = "A"
      # Two SHAs for repo A. The values are arbitrary 40-char hex tokens
      # that double as the per-repo lock filenames (RA-1 keys the file by
      # the full trigger SHA).
      let shaOld = "1111111111111111111111111111111111111111"
      let shaNew = "2222222222222222222222222222222222222222"

      # --- build a real git manifest repo ---
      let manifestRoot = scratch / "manifests"
      createDir(manifestRoot)
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " init -q -b main")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " config user.name \"RA-1 Tester\"")

      let repoLockDir = manifestRoot / "locks" / project / repo
      createDir(repoLockDir)

      # Commit 1: the OLDER lock.
      let oldLockAbs = repoLockDir / (shaOld & ".toml")
      writeFile(oldLockAbs, minimalLockToml(project, repo, shaOld))
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " commit -q -m \"lock A @ old\"")

      # Commit 2: the NEWER lock (distinct commit → newer by git log).
      let newLockAbs = repoLockDir / (shaNew & ".toml")
      writeFile(newLockAbs, minimalLockToml(project, repo, shaNew))
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " add -A")
      discard requireGit(q(gitBin) & " -C " & q(manifestRoot) &
        " commit -q -m \"lock A @ new\"")

      # Adversarial filesystem ordering: make the OLDER lock's mtime the
      # newest on disk. A resolver that sorted by mtime (or by filename)
      # would now answer wrongly; only the git-history query is correct.
      let future = getTime() + initDuration(hours = 1)
      setLastModificationTime(oldLockAbs, future)

      # Guard: there is NO index.toml anywhere under locks/ — the
      # resolver must not depend on one.
      check not fileExists(manifestRoot / "locks" / project / "index.toml")
      check not fileExists(repoLockDir / "index.toml")

      # --- exercise the ACTUAL resolver code path ---
      let identity = ensureGitToolResolvable(tpmPathOnly, getEnv("PATH"))

      let latestRel = latestLockRelPathForRepoViaGit(
        identity, manifestRoot, project, repo)

      # The resolver returns the NEWEST lock by git log (commit 2), as a
      # manifest-layer-relative forward-slash path.
      check latestRel == "locks/" & project & "/" & repo & "/" &
        shaNew & ".toml"
      check latestRel != "locks/" & project & "/" & repo & "/" &
        shaOld & ".toml"

      # The trigger (repo, sha) decomposition of that path round-trips.
      let trigger = parseTriggerFromLockRelPath(latestRel)
      check trigger.repo == repo
      check trigger.sha == shaNew

      # Sanity: the resolved file exists and parses back to the new SHA.
      let latestAbs = manifestRoot / latestRel.replace('/', DirSep)
      check fileExists(latestAbs)
      let parsed = readLock(latestAbs)
      check parsed.repo.len == 1
      check parsed.repo[0].revision == shaNew

      # A repo with no lock subtree resolves to "" (no fallback, no
      # index read).
      check latestLockRelPathForRepoViaGit(
        identity, manifestRoot, project, "NoSuchRepo") == ""
