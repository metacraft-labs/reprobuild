## **`REPRO_SKIP_LOCK_REFRESH` makes one commit leave `repro.lock` alone, and
## the re-pin it suppresses names the variable when it does run.**
##
## Issue: reprobuild-pm `issues/2026-09-27-pre-commit-hook-repins-flake-lock-
## at-a-sibling-head-and-drops-narhash.md`. The opt-out covers BOTH commit-time
## lock writers of the managed pre-commit hook — the `flake.lock` refresh
## (`t_skip_lock_refresh_leaves_the_flake_lock_alone`) and the `repro.lock`
## sibling re-pin (§13.3), which this case pins.
##
## ## What is asserted
##
##   1. with a sibling advanced, `REPRO_SKIP_LOCK_REFRESH=1 git commit` leaves
##      `repro.lock` out of the commit and byte-identical on disk;
##   2. the hook says it skipped and names `repro.lock` as the lock it would
##      have touched;
##   3. the next commit without the variable re-pins as before, and its
##      stderr announcement now names the variable, so the opt-out is
##      discoverable at the moment it is wanted.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## of real git repositories, the real `./build/bin/repro`, and a real
## `.git/hooks/pre-commit` fired by a real `git commit`. NO MOCKS. The hook
## file is written by hand rather than by `repro hooks ensure --vcs` for the
## reason `t_commit_repins_committed_lock_siblings` gives: it names the built
## binary by absolute path, so a dev-shell `repro` on PATH cannot stand in for
## the one under test. Its body is the managed body's dispatch line.

import std/[os, strutils, unittest]
import ./committed_lock_siblings_fixture
import repro_test_support/reasoned_skip

proc installPreCommit(fx: SiblingFixture) =
  let hook = fx.app / ".git" / "hooks" / "pre-commit"
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/usr/bin/env sh\nset -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\nREPRO_STATUS=0\n" &
    q(fx.repro) & " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\nexit $REPRO_STATUS\n")
  var perms = getFilePermissions(hook)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(hook, perms)

proc commitInApp(fx: SiblingFixture; label: string):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(q(fx.gitBin) & " -C " & q(fx.app) & " commit -m " & q(label))

proc filesInHead(fx: SiblingFixture): string =
  fx.git(fx.app, "show --name-only --format= HEAD")

suite "REPRO_SKIP_LOCK_REFRESH: one commit leaves repro.lock alone":

  test "t_skip_lock_refresh_leaves_the_repro_lock_alone":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var fx = setupSiblingFixture("skip-repin")
      defer: removeDir(fx.scratch)
      fx.refreshAndPublishLock()
      let before = readFile(fx.app / "repro.lock")
      fx.installPreCommit()
      let libBNext = fx.advance("lib-b")

      # ---- (1) nothing written, nothing staged --------------------------
      putEnv("REPRO_SKIP_LOCK_REFRESH", "1")
      let skipped = fx.commitInApp("no-pin-change")
      delEnv("REPRO_SKIP_LOCK_REFRESH")
      checkpoint(skipped.output)
      check skipped.code == 0
      check "repro.lock" notin fx.filesInHead()
      check readFile(fx.app / "repro.lock") == before
      check fx.git(fx.app, "status --porcelain").strip().len == 0

      # ---- (2) said ------------------------------------------------------
      var notice = ""
      for line in skipped.output.splitLines():
        if line.startsWith("repro pre-commit:") and
            line.contains("REPRO_SKIP_LOCK_REFRESH"):
          notice = line
      checkpoint("notice: " & notice)
      check notice.len > 0
      check notice.contains("repro.lock")

      # ---- (3) the next commit re-pins, and names the opt-out ------------
      let next = fx.commitInApp("records-the-pin")
      checkpoint(next.output)
      check next.code == 0
      check "repro.lock" in fx.filesInHead()
      check libBNext in fx.git(fx.app, "show HEAD:repro.lock")
      var announcement = ""
      for line in next.output.splitLines():
        if line.startsWith("repro pre-commit:") and
            line.contains("re-pinned"):
          announcement = line
      checkpoint("announcement: " & announcement)
      check announcement.contains("lib-b")
      check announcement.contains("REPRO_SKIP_LOCK_REFRESH")
