## NF-2 (Nix-Flake-Coexistence.md §3.1 "Rule"; Unified-Locking-And-Hooks.md
## §13.3) — **a commit that moves no sibling does not touch the lock**.
##
##   > A pre-commit refresh writes the sibling pins from observed local state,
##   > and **only when they actually change**. Most commits do not move a
##   > sibling, so most commits do not touch `repro.lock`; the diff noise that
##   > would otherwise argue against commit-time refresh does not arise.
##
## ## Why the MTIME is asserted and not only the bytes
##
## An unconditional serializer that happens to round-trip produces identical
## bytes and is still wrong: it opens the file for writing on every commit, so
## every `git commit --amend` and every rebase step touches a tracked file. On
## a rebase that is a lock-churn event across the whole replayed range, and it
## is invisible to a content comparison. mtime is the only observation that
## separates "was not rewritten" from "was rewritten to the same thing".
##
## ## Both entry points are asserted
##
## The commit hook applies a cheap pre-filter — no flake input's sibling has
## moved off its pin, so nothing can need refreshing — and returns before
## resolving the develop set at all (`repro develop --list --all` costs minutes
## against this workspace's lock set, and a hook that spends that on the
## BLOCKING half of every commit is a hook people uninstall). The operator verb
## `repro flake refresh-lock` has no such shortcut: it resolves the override set
## properly and reaches the "nothing to write" decision on the merits. Both are
## asserted, because a no-op that is only a no-op because a shortcut fired is
## not the property this case is about.
##
## ## …and the commit is asserted to carry the lock UNCHANGED
##
## The pre-commit placement adds a way to get this wrong that post-commit did
## not have: a hook that stages `flake.lock` unconditionally would put an
## unchanged blob into every commit's index. Harmless for the tree, but it
## makes `git commit` on a repo with no staged changes succeed where it should
## have said "nothing to commit", so the staging is asserted NOT to happen when
## nothing moved.
##
## ## Mutation (from the milestone): rewrite unconditionally ⇒ RED
##
## Writing the refreshed text even when it equals what is already there fails
## the mtime assertion below. Note what else that mutation does, which is why
## the milestone pairs it with this case: it makes **every rebase a lock-churn
## event**, rewriting a tracked file once per replayed commit.
##
## Test-double policy: NO mocks, doubles or fakes. See the header of
## `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, times, unittest]

import nf2_flake_lock_fixture

suite "NF-2: a commit that moves no sibling does not touch the lock":

  test "t_a_commit_that_moves_no_sibling_does_not_touch_the_lock":
    if not nf2Prerequisites(
        "t_a_commit_that_moves_no_sibling_does_not_touch_the_lock"):
      skip()
    else:
      let fx = setupNf2Fixture("no-move")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # The starting state is the one every ordinary commit is made in: the
      # lock already names exactly what each sibling checkout is sitting at.
      for i, name in Nf2FlakeInputRepos:
        check headOf(fx, siblingDir(fx, name)) == fx.seedSha[i]

      let before = readFile(lockPath(fx))
      # A second of separation so a rewrite-to-identical-content is visible as
      # a touch even on a filesystem with one-second timestamp resolution.
      sleep(1100)
      let mtimeBefore = getLastModificationTime(lockPath(fx))

      let commit = tryCommitInApp(fx, "an ordinary commit that moves nothing")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output)
      check commit.code == 0

      # ---- the hook path --------------------------------------------------
      check readFile(lockPath(fx)) == before
      if getLastModificationTime(lockPath(fx)) != mtimeBefore:
        checkpoint("log:\n" & preCommitLog(fx))
      check getLastModificationTime(lockPath(fx)) == mtimeBefore
      check lastFlakeLogLine(fx).contains("flake-lock up-to-date")
      # Positively: the hook decided not to write, rather than not having run.
      # An empty log would satisfy the two assertions above for the wrong
      # reason, and that is exactly the vacuous green this campaign is about.
      check lastFlakeLogLine(fx).len > 0
      check not lastFlakeLogLine(fx).contains("staged into this commit")
      # The commit carries the SAME lock it inherited: nothing was staged.
      check lockInCommit(fx) == before
      check lockInCommit(fx, "HEAD~1") == before

      # ---- the operator verb, which resolves the override set for real ----
      # No shortcut here: this reaches the "nothing to write" decision after
      # binding every input to its develop-set checkout and reading every
      # sibling's HEAD. An unconditional writer has nothing left to hide
      # behind.
      let direct = run(q(fx.repro) &
        " flake refresh-lock --all --tool-provisioning=path", cwd = fx.app)
      if direct.code != 0:
        checkpoint("refresh-lock output:\n" & direct.output)
      check direct.code == 0
      check direct.output.contains("up-to-date")
      check readFile(lockPath(fx)) == before
      check getLastModificationTime(lockPath(fx)) == mtimeBefore

      # ---- and repeating it changes nothing either ------------------------
      for i in 1 .. 3:
        let more = tryCommitInApp(fx, "another commit " & $i)
        check more.code == 0
      check readFile(lockPath(fx)) == before
      check getLastModificationTime(lockPath(fx)) == mtimeBefore
      check lockInCommit(fx) == before
