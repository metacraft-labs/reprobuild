## NF-2 (Nix-Flake-Coexistence.md §4 "History rewriting";
## Unified-Locking-And-Hooks.md §13.3) — **re-firing the hook over an unchanged
## sibling set produces a byte-identical lock**.
##
##   > `commit --amend` and rebase re-fire pre-commit over revisions that
##   > already exist. The refresh must be idempotent for unchanged siblings, so
##   > replaying history does not churn the lock.
##
## This is the one decision NF-2 was asked to make rather than inherit, so the
## decision is stated here in full, next to the case that pins it.
##
## ## What git actually does, measured on this host with git 2.50
##
## The spec sentence above says "`commit --amend` and rebase re-fire
## pre-commit". Half of that is true, and the half that is not changes what
## this case has to assert. A hook that appended one line per firing was
## installed and every history-rewriting operation was run through it:
##
##   | operation                                     | pre-commit fires |
##   |-----------------------------------------------|------------------|
##   | `git rebase <upstream>`, 3 commits replayed   | **no** (0 times) |
##   | `git cherry-pick <commit>`                    | **no**           |
##   | `git am <patch>`                              | **no**           |
##   | `git merge --no-ff` (a merge commit)          | **no**           |
##   | `git rebase -i` stopping at an `edit` step    | **no**           |
##   | `git rebase --continue`                       | **no**           |
##   | `git commit --amend`                          | **YES**          |
##   | `git commit --amend` *while a rebase is stopped* | **YES**, with `rebase-merge` present |
##
## Git runs `pre-commit` only for a commit a HUMAN asked for. Replayed commits
## do not run it at all. This is a real difference from `post-commit`, which
## fires once per replayed commit — the exposure the M19 stand-down exists for.
##
## ## The decision, in the two shapes that remain
##
##   1. **`git commit --amend`** fires the hook normally, with nothing in
##      flight. The refresh therefore runs in full, and it is a no-op because
##      THE WRITE IS CONDITIONAL ON THE BYTES: the refreshed document is
##      compared with what is on disk, and when they are equal the file is not
##      opened for writing at all. Not "written with the same content" — not
##      written. Byte- AND mtime-identical.
##
##      Running in full rather than standing down is deliberate: an amend that
##      ALSO moved a sibling must still record the move. An amend is not a
##      replay of somebody else's history; it is the current commit, still
##      being formed.
##
##   2. **A commit made while a rebase is stopped** (the `edit` step of an
##      interactive rebase) stands the hook down entirely. That is not new
##      machinery — `runPostCommitLockCommand` already refuses to act while
##      `managedHookStandDown` reports an operation in flight, because "writing
##      a lock into a working tree its owner has not finished with is how a
##      hook breaks somebody else's rebase" — and at pre-commit the stakes are
##      higher, because this hook also STAGES what it writes, into a commit the
##      sequencer is about to rewrite.
##
##      The table above shows this is the ONLY reachable in-flight firing, so
##      it is the case the stand-down is asserted through. Asserting it via a
##      plain rebase would assert nothing: the hook never runs there.
##
## ### Alternatives considered, and why they were rejected
##
##   * **Refresh unconditionally and let git notice nothing changed.** git does
##     notice nothing changed — but the file is still rewritten, so its mtime
##     moves on every amend. Every build system watching the tree sees a
##     modified input, and `direnv`'s `watch_file` on `flake.lock` (the
##     mechanism §2b's failure list is about) re-evaluates the flake.
##   * **Skip the refresh whenever HEAD's parent already carries a lock.**
##     Rejected because it is a heuristic about history shape, not about the
##     observation being recorded, and it gets the genuinely interesting case
##     wrong: an amend that ALSO moved a sibling must still record the move.
##   * **Refuse to run during any history rewrite, including `--amend`.** An
##     amend is how a developer fixes the commit they just made, including
##     after moving a sibling; refusing there would leave the lock stale
##     exactly when the developer thought they were correcting it.
##
## ## What is asserted
##
##   1. a refresh that DID move a pin is the baseline (idempotence over a
##      no-op refresh would be vacuous);
##   2. `git commit --amend` fires the hook (positively: the log gained a
##      line) and leaves the lock byte- AND mtime-identical, with the amended
##      commit still carrying it;
##   3. a real `git rebase` replaying three commits: the rebase succeeds, the
##      hook fires ZERO times (asserted, so a future git that starts firing it
##      makes this case speak rather than pass), the lock is byte- and
##      mtime-identical, and every replayed commit still carries it;
##   4. a `git commit --amend` while an interactive rebase is STOPPED: the hook
##      fires, RECOGNISES the operation in flight, declines, and leaves the
##      lock alone;
##   5. the operator verb, run repeatedly, is idempotent too.
##
## Test-double policy: NO mocks, doubles or fakes. Real `git commit --amend`,
## a real `git rebase`, a real interactive rebase stopped at an `edit` step,
## and the real hook fired by git itself.

import std/[os, strutils, times, unittest]

import nf2_flake_lock_fixture

proc logLines(fx: Nf2Fixture): int =
  for line in preCommitLog(fx).splitLines():
    if line.strip().len > 0: inc result

suite "NF-2: amend and rebase are idempotent":

  test "t_amend_and_rebase_are_idempotent":
    if not nf2Prerequisites("t_amend_and_rebase_are_idempotent"):
      skip()
    else:
      let fx = setupNf2Fixture("idempotent")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # ---- (1) a baseline that actually moved a pin. ----------------------
      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      let first = tryCommitInApp(fx, "first")
      if first.code != 0:
        checkpoint("git commit failed:\n" & first.output)
      check first.code == 0
      let refreshed = readFile(lockPath(fx))
      check refreshed.contains(newAlpha)
      # The commit carries it, so there is nothing dirty for the amend below
      # to pick up and nothing to attribute a later change to.
      check lockInCommit(fx) == refreshed
      check gitIn(fx, fx.app, "status --porcelain").strip() == ""
      # A second of separation so a rewrite-to-identical-content is visible as
      # a touch even at one-second timestamp resolution.
      sleep(1100)
      let mtimeBaseline = getLastModificationTime(lockPath(fx))

      # ---- (2) `git commit --amend`. --------------------------------------
      let linesBeforeAmend = logLines(fx)
      writeFile(fx.app / "amended.txt", "amended\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      let amend = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q --amend -m " & q("first (amended)"))
      if amend.code != 0:
        checkpoint("amend failed:\n" & amend.output)
      check amend.code == 0
      # The hook RAN. Without this, "the lock is unchanged" is satisfied just
      # as well by a hook that was never invoked, which is the vacuous green
      # this campaign exists to prevent.
      check logLines(fx) > linesBeforeAmend
      check lastFlakeLogLine(fx).contains("up-to-date")
      if readFile(lockPath(fx)) != refreshed:
        checkpoint("the amend churned the lock; log:\n" & preCommitLog(fx))
      check readFile(lockPath(fx)) == refreshed
      check getLastModificationTime(lockPath(fx)) == mtimeBaseline
      check lockInCommit(fx) == refreshed

      # ---- (3) a real rebase, replaying three commits. --------------------
      let baseBranch = gitIn(fx, fx.app,
        "rev-parse --abbrev-ref HEAD").strip()
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
        " checkout -q -b side")
      for i in 1 .. 3:
        check tryCommitInApp(fx, "side " & $i).code == 0
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
        " checkout -q " & baseBranch)
      check tryCommitInApp(fx, "base moved").code == 0
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) &
        " checkout -q side")

      let linesBeforeRebase = logLines(fx)
      let rebase = run(q(fx.gitBin) & " -C " & q(fx.app) & " rebase " &
        q(baseBranch))
      if rebase.code != 0:
        checkpoint("rebase output:\n" & rebase.output)
      check rebase.code == 0
      # Git does not run `pre-commit` for a replayed commit — measured, and
      # asserted here so a future git that changes that is caught by this case
      # rather than silently altering what "idempotent" is proving.
      if logLines(fx) != linesBeforeRebase:
        checkpoint("git fired pre-commit during a rebase (it did not on git " &
          "2.50). The idempotence below is now about the refresh declining " &
          "rather than about git not asking. Log gained:\n" &
          preCommitLog(fx).splitLines()[linesBeforeRebase .. ^1].join("\n"))
      check logLines(fx) == linesBeforeRebase
      check readFile(lockPath(fx)) == refreshed
      check getLastModificationTime(lockPath(fx)) == mtimeBaseline
      # Every replayed commit still carries the same lock: the replay did not
      # rewrite it into any of the three new revisions either.
      for rev in ["HEAD", "HEAD~1", "HEAD~2"]:
        check lockInCommit(fx, rev) == refreshed

      # ---- (4) a commit while an interactive rebase is STOPPED. -----------
      # The one reachable in-flight firing (see the table in the header), and
      # therefore the only place the stand-down can be observed at all.
      let linesBeforeStop = logLines(fx)
      let stopped = run("GIT_SEQUENCE_EDITOR=" &
        q("sed -i 1s/^pick/edit/") & " " & q(fx.gitBin) & " -C " &
        q(fx.app) & " rebase -i HEAD~2", cwd = fx.app)
      if stopped.code != 0:
        checkpoint("could not stop an interactive rebase at an `edit` step; " &
          "output:\n" & stopped.output)
      check stopped.code == 0
      check dirExists(fx.app / ".git" / "rebase-merge")
      # A sibling moves WHILE the rebase is stopped, so the refresh would have
      # something to record if it did not stand down — otherwise "the lock is
      # unchanged" would again be true for the wrong reason.
      let newGamma = moveSibling(fx, "gamma", "revision 2")
      writeFile(fx.app / "during-rebase.txt", "edited mid-rebase\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      let midRebase = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -q --amend --no-edit")
      if midRebase.code != 0:
        checkpoint("the mid-rebase commit failed:\n" & midRebase.output)
      check midRebase.code == 0
      check logLines(fx) > linesBeforeStop
      let standDownLine = lastFlakeLogLine(fx)
      if not standDownLine.contains("skipped-git-operation-in-progress"):
        checkpoint("expected a stand-down, got: " & standDownLine)
      check standDownLine.contains("skipped-git-operation-in-progress")
      check standDownLine.contains("rebase-merge")
      check readFile(lockPath(fx)) == refreshed
      check getLastModificationTime(lockPath(fx)) == mtimeBaseline
      check newGamma notin readFile(lockPath(fx))
      discard requireCmd("GIT_EDITOR=true " & q(fx.gitBin) & " -C " &
        q(fx.app) & " rebase --continue")

      # ---- (5) the operator verb, repeated. -------------------------------
      # `gamma` moved in (4) and was deliberately not recorded, so restore the
      # starting state first: this arm is about repetition, not about the
      # stand-down, and a pending change would make it assert the opposite.
      discard requireCmd(q(fx.gitBin) & " -C " & q(siblingDir(fx, "gamma")) &
        " reset -q --hard HEAD~1")
      var previous = readFile(lockPath(fx))
      for i in 1 .. 3:
        let direct = run(q(fx.repro) &
          " flake refresh-lock --all --tool-provisioning=path", cwd = fx.app)
        if direct.code != 0:
          checkpoint("refresh-lock output:\n" & direct.output)
        check direct.code == 0
        check readFile(lockPath(fx)) == previous
        previous = readFile(lockPath(fx))
      check readFile(lockPath(fx)) == refreshed
      check getLastModificationTime(lockPath(fx)) == mtimeBaseline
