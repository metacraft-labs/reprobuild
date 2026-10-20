## §13.3 — the `pre-commit` lock refresh stands down only while a rebase /
## cherry-pick / `am` is IN PROGRESS, never on the first ordinary commit after
## one finished (Unified-Locking-And-Hooks.md §13.3).
##
## A finished rebase leaves no `rebase-merge/` or `rebase-apply/` behind, but
## the last HEAD reflog entry still reads `rebase (finish): returning to
## refs/heads/feature`. `probeGitOperationInProgress` falls back to that
## reflog tail for the post-* hooks (the am-backend rewind fires
## `post-checkout` before its state directory exists). `pre-commit` fires only
## while a commit is being formed, when every replayed commit already finds
## the state paths, so for this hook the fallback could only misfire: the
## refresh logged `skipped-git-operation-in-progress (HEAD reflog: rebase
## (finish) …)` and that one commit skipped the `repro.lock` re-pin and the
## `flake.lock` refresh.
##
## The case: lib-a tracks a committed `repro.lock` in an initialised workspace,
## with the managed hooks installed by the real `repro hooks ensure --vcs`. A
## `feature` branch one commit ahead is rebased onto a moved `main` (git does
## not fire `pre-commit` for the replayed commit), then an ordinary commit is
## made.
##
##   1. Precondition, asserted so the case cannot pass vacuously: no rebase
##      state path exists and the HEAD reflog tail is `rebase (finish)`.
##   2. The commit succeeds, the hook RAN (the log gained a `repro-lock`
##      line), and that line is the refresh's verdict (`up-to-date` or
##      `re-pinned`), never `skipped-git-operation-in-progress`.
##
## Falsifiability: against `runPreCommitLockCommand` passing the default
## `consultReflog = true` to `managedHookStandDown`, step 2's line reads
## `repro-lock skipped-git-operation-in-progress: … (HEAD reflog: rebase
## (finish): returning to refs/heads/feature)`.
##
## NO MOCKS: real repositories, the real hooks, a real `git rebase`. Skip
## rule: `git` or `ssh-keygen` missing (the shared fixture signs a registry
## key with it).

import repro_test_support/reasoned_skip
import std/[os, osproc, strutils, unittest]

include pre_commit_gate_fixture

proc reproLockLogLines(fx: StoreFixture): seq[string] =
  for line in fx.gateLog.splitLines():
    if " repro-lock " in line:
      result.add(line)

suite "§13.3 — the pre-commit lock refresh after a finished rebase":

  test "t_pre_commit_lock_refresh_runs_after_a_finished_rebase":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test commits in real " &
        "repositories with the managed hooks installed")
    else:
      let fx = setupStoreFixture("", "lock-refresh-after-rebase",
        committedLock = true)
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      check fileExists(fx.libAPath / "repro.lock")

      discard fx.mustGit("checkout", "-q", "-b", "feature")
      writeFile(fx.libAPath / "f.txt", "feature\n")
      discard fx.mustGit("add", "f.txt")
      discard fx.mustGit("commit", "-q", "-m", "feature")
      discard fx.mustGit("checkout", "-q", "main")
      writeFile(fx.libAPath / "main.txt", "moved base\n")
      discard fx.mustGit("add", "main.txt")
      discard fx.mustGit("commit", "-q", "-m", "moved base")
      discard fx.mustGit("checkout", "-q", "feature")

      let rebase = fx.git("rebase", "main")
      checkpoint("rebase:\n" & rebase.output)
      check rebase.code == 0

      # ---- 1. the rebase is FINISHED, but the reflog tail still says so --
      for name in ["rebase-merge", "rebase-apply"]:
        check not dirExists(gitOut(fx.libAPath, "rev-parse", "--path-format=" &
          "absolute", "--git-path", name))
      let tail = gitOut(fx.libAPath, "reflog", "show", "--format=%gs", "-1",
        "HEAD")
      checkpoint("HEAD reflog tail: " & tail)
      check tail.startsWith("rebase (finish)")

      # ---- 2. an ordinary commit is refreshed like any other -------------
      let before = fx.reproLockLogLines.len
      writeFile(fx.libAPath / "g.txt", "after the rebase\n")
      discard fx.mustGit("add", "g.txt")
      let c = fx.commit("-q", "-m", "after the rebase")
      checkpoint("commit:\n" & c.output)
      checkpoint("pre-commit-lock.log:\n" & fx.gateLog)
      check c.code == 0
      let lines = fx.reproLockLogLines
      check lines.len == before + 1
      if lines.len > before:
        let verdict = lines[^1]
        check "skipped-git-operation-in-progress" notin verdict
        check "a git operation is in progress" notin verdict
        check "repro-lock up-to-date" in verdict or
          "repro-lock re-pinned" in verdict
