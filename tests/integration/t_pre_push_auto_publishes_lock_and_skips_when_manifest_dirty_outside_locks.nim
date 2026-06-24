## RA-7 — lock publication (commit + push) with the dirty-outside-``locks/``
## guard.
##
## ``publishWorkspaceLock`` is the publication mechanism the pre-push gate
## (and explicit ``repro workspace lock``) call after writing a lock: it
## stages everything under ``locks/``, REFUSES if the manifest repo is
## dirty outside ``locks/`` (unstaging what it staged), commits, and pushes
## to the manifest repo's upstream.
##
## This test exercises that mechanism directly against a hermetic manifest
## repo with a local bare upstream:
##
##   1. Clean-outside-``locks/``: a freshly-written lock under ``locks/`` is
##      committed AND pushed; the upstream (bare) receives the lock commit
##      (assert the lock blob is reachable from the pushed branch in the
##      bare repo).
##   2. Dirty-outside-``locks/``: an unrelated tracked file is modified, a
##      new lock is written, publish REFUSES — no new commit, nothing
##      pushed, the staged ``locks/`` entry is unstaged, and the dirty file
##      is left byte-for-byte untouched.
##
## Falsifiable: the clean case asserts the bare upstream's commit count
## advanced and the lock path is present in the pushed tree; the dirty case
## asserts the commit count did NOT advance, the index has nothing staged,
## and the dirty file content is unchanged. Hermetic: only local
## ``git init`` / ``git init --bare`` repos; no network.
##
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import git_tool
import repro_cli_support

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc commitCount(gitBin, repo, rev: string): int =
  let res = run(q(gitBin) & " -C " & q(repo) &
    " rev-list --count " & rev)
  if res.code != 0:
    return -1
  res.output.strip().parseInt()

proc seedManifestRepo(gitBin, scratch: string;
                      branch = "latest"): tuple[bare, work: string] =
  ## A bare upstream and a working checkout configured to track it, with
  ## an initial non-lock commit so the manifest repo is "clean".
  let bare = scratch / "manifest.git"
  let work = scratch / "manifest"
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " & q(bare))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(work))
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " config user.name \"RA-7 Tester\"")
  writeFile(work / "manifest.toml", "schema = \"manifest\"\n")
  discard requireGit(q(gitBin) & " -C " & q(work) & " add manifest.toml")
  discard requireGit(q(gitBin) & " -C " & q(work) & " commit -m seed")
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " remote add origin " & q(bare))
  discard requireGit(q(gitBin) & " -C " & q(work) &
    " push -u origin " & branch)
  (bare: bare, work: work)

proc writeLock(work, project, repo, sha, body: string) =
  let dir = work / "locks" / project / repo
  createDir(dir)
  writeFile(dir / (sha & ".toml"), body)

suite "RA-7 — lock publication (commit + push) and dirty-outside-locks guard":

  test "t_pre_push_auto_publishes_lock_and_skips_when_manifest_dirty_outside_locks":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-ra7-publish-", "")
      defer: removeDir(scratch)
      let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
      let (bare, work) = seedManifestRepo(gitBin, scratch)

      let baseCount = commitCount(gitBin, bare, "refs/heads/latest")
      check baseCount >= 1

      # ---- (1) clean-outside-locks → commit AND push ---------------------
      writeLock(work, "demo", "demo",
        "1111111111111111111111111111111111111111",
        "[lock]\nproject = \"demo\"\n")
      let pub1 = publishWorkspaceLock(identity, work)
      check pub1.outcome == lpoPublished

      # The local manifest branch advanced by exactly one commit.
      check commitCount(gitBin, work, "HEAD") == baseCount + 1
      # The bare upstream RECEIVED the lock commit (falsifiable: count grew).
      check commitCount(gitBin, bare, "refs/heads/latest") == baseCount + 1
      # The pushed tree in the bare actually contains the lock path.
      let lsRes = run(q(gitBin) & " -C " & q(bare) &
        " ls-tree -r --name-only refs/heads/latest")
      check lsRes.code == 0
      check "locks/demo/demo/1111111111111111111111111111111111111111.toml" in
        lsRes.output
      let afterPushCount = commitCount(gitBin, bare, "refs/heads/latest")

      # ---- (2) dirty-outside-locks → REFUSE ------------------------------
      # Modify an unrelated tracked file, then write a NEW lock.
      let dirtyPath = work / "manifest.toml"
      let dirtyBefore = "schema = \"manifest\"\nDIRTY-EDIT\n"
      writeFile(dirtyPath, dirtyBefore)
      writeLock(work, "demo", "demo",
        "2222222222222222222222222222222222222222",
        "[lock]\nproject = \"demo\"\n")

      let pub2 = publishWorkspaceLock(identity, work)
      check pub2.outcome == lpoRefusedDirty

      # No new commit locally, nothing pushed to the bare.
      check commitCount(gitBin, work, "HEAD") == baseCount + 1
      check commitCount(gitBin, bare, "refs/heads/latest") == afterPushCount

      # The staged locks/ entry was UNSTAGED (index has nothing staged).
      let staged = run(q(gitBin) & " -C " & q(work) &
        " diff --cached --name-only")
      check staged.code == 0
      check staged.output.strip().len == 0

      # The dirty file is left byte-for-byte untouched.
      check readFile(dirtyPath) == dirtyBefore

      # And the new lock file is still on disk (publish never deletes it).
      check fileExists(work / "locks" / "demo" / "demo" /
        "2222222222222222222222222222222222222222.toml")
