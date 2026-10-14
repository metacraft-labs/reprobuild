## TC-8g — the pre-commit certificate gate stands down during a replay
## (rebase, cherry-pick, ``am``), as every managed commit-path hook does
## (``managedHookStandDown``), and logs that it did.
##
## Under ``gate_mode = required``, three uncovered commits (made with
## ``--no-verify``) are replayed by ``git rebase --exec 'git commit --amend
## --no-edit'`` onto a moved base: a multi-commit rebase in which git fires
## ``pre-commit`` once per replayed commit, with the rebase in flight.
##
##   1. The rebase completes, all three commits are replayed, and the log has
##      one "stood-down" line per replayed commit. The test asserts the log
##      lines because "did not refuse" is also what a gate that never ran
##      looks like.
##   2. Control: the very same ``git commit --amend --no-edit`` right after
##      the rebase finished is refused, so the gate was armed during the
##      rebase — and the finished rebase (whose reflog tail still reads
##      ``rebase (finish)``) does not make the next ordinary commit escape.
##   3. A cherry-pick stopped on a conflict: the resolving ``git commit``
##      runs with ``CHERRY_PICK_HEAD`` present, and stands down too.
##
## Falsifiability: removing the stand-down makes the first ``--exec`` step
## fail and the rebase stop; consulting the reflog tail (as the post-* hooks
## do) makes case 2 pass unjudged (observed in the first run of this test).
##
## NO MOCKS: real repositories, the real hooks, real ``git rebase``. Skip
## rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, unittest]

include pre_commit_gate_fixture

suite "TC-8g — the pre-commit gate stands down during a replay":

  test "t_pre_commit_gate_stands_down_during_replay":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test commits in real " &
        "repositories under a required certificate policy")
    else:
      let fx = setupStoreFixture(
        requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "tc8g-replay")
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      let base = fx.head
      discard fx.mustGit("checkout", "-q", "-b", "feature")
      for i in 1 .. 3:
        writeFile(fx.libAPath / ("f" & $i & ".txt"), "feature " & $i & "\n")
        discard fx.mustGit("add", "f" & $i & ".txt")
        discard fx.mustGit("commit", "-q", "--no-verify", "-m", "f" & $i)
      discard fx.mustGit("checkout", "-q", "main")
      writeFile(fx.libAPath / "main.txt", "moved base\n")
      discard fx.mustGit("add", "main.txt")
      discard fx.mustGit("commit", "-q", "--no-verify", "-m", "moved base")
      discard fx.mustGit("checkout", "-q", "feature")
      check fx.gateLogLines("stood-down") == 0

      # ---- 1. the replay completes, and the stand-down is logged ----------
      let rebase = fx.git("rebase", "--exec",
        "git commit --amend --no-edit -q", "main")
      checkpoint("rebase:\n" & rebase.output)
      check rebase.code == 0
      check not dirExists(fx.libAPath / ".git" / "rebase-merge")
      check gitOut(fx.libAPath, "rev-list", "--count", "main..feature") == "3"
      check gitOut(fx.libAPath, "merge-base", "main", "feature") ==
        gitOut(fx.libAPath, "rev-parse", "main")
      check gitOut(fx.libAPath, "merge-base", "main", "feature") != base
      check fx.gateLogLines("stood-down") == 3
      check "a git operation is in progress" in fx.gateLog
      check "REFUSED" notin rebase.output

      # ---- 2. control: outside a replay, the same amend is refused --------
      let amend = fx.commit("--amend", "--no-edit")
      checkpoint("amend outside a replay:\n" & amend.output)
      check amend.code != 0
      check "REFUSED (commit_gate = required)" in amend.output
      check fx.gateLogLines("refused not-covered") == 1

      # ---- 3. a cherry-pick that stopped on a conflict --------------------
      # The pick's own `git commit` (after the conflict is resolved) fires
      # `pre-commit` with CHERRY_PICK_HEAD present: a replay, so it stands
      # down too.
      discard fx.mustGit("checkout", "-q", "-b", "other", "main~1")
      writeFile(fx.libAPath / "main.txt", "a conflicting base\n")
      discard fx.mustGit("add", "main.txt")
      discard fx.mustGit("commit", "-q", "--no-verify", "-m", "conflicting")
      discard fx.mustGit("checkout", "-q", "feature")
      let pick = fx.git("cherry-pick", "other")
      checkpoint("cherry-pick:\n" & pick.output)
      check pick.code != 0                       # stopped on the conflict
      check fileExists(fx.libAPath / ".git" / "CHERRY_PICK_HEAD")
      writeFile(fx.libAPath / "main.txt", "resolved\n")
      discard fx.mustGit("add", "main.txt")
      let picked = fx.commit("--no-edit")
      checkpoint("resolved pick:\n" & picked.output)
      check picked.code == 0
      check not fileExists(fx.libAPath / ".git" / "CHERRY_PICK_HEAD")
      check fx.gateLogLines("stood-down") == 4
      check "CHERRY_PICK_HEAD" in fx.gateLog
