## NF-2 (Workspace-And-Develop-Mode.md §"Reproducibility And `repro check`",
## inherited through Unified-Locking-And-Hooks.md §13.6) — **a dirty sibling
## leaves the lock alone, and the commit still succeeds**.
##
##   > if a develop-mode dependency has uncommitted modifications, the project
##   > lock file must not be updated
##
## …because "a develop-mode dependency that is dirty or only locally committed
## means the effective build state is not properly lockable for other people
## yet". `flake.lock` is a project lock file under §13.6, so it inherits this
## verbatim and NF-2 invents no second rule.
##
## ## The half of the policy that is easiest to get wrong
##
## It does **not** refuse the commit. The refresh is skipped, the lock stays as
## it was, and the pre-push gate refuses the *push* because the lock no longer
## matches the siblings (that gate is NF-3). Refusing the commit would be new
## behaviour this policy does not ask for, and it would reject work that is
## already correct — the developer's own commit is not what is unlockable.
##
## So this case asserts BOTH halves, and the second is not decoration: an
## implementation that refuses the commit satisfies "the lock is unchanged"
## perfectly.
##
## ## What is asserted
##
##   1. `git commit` in the flake's repo SUCCEEDS (exit 0) with a dirty
##      develop-mode sibling, and the commit really exists afterwards;
##   2. the post-commit hook exits 0 — it is best-effort and must never fail a
##      commit;
##   3. `flake.lock` is BYTE-identical, and its mtime is unchanged;
##   4. the skip is LOUD: it names the dirty sibling, says the lock was not
##      refreshed, and names the command that fixes it. A silent skip is
##      indistinguishable from a refresh that did nothing, which is §5's
##      failure verbatim.
##
## Note the sibling here is BOTH ahead of its pin and dirty. Ahead alone would
## be refreshed (that is the headline case); dirty alone would have nothing to
## refresh, and a case with nothing to do cannot witness a refusal.
##
## ## Mutation (from the milestone): record the revision anyway ⇒ RED
##
## Assert (3) fails: `flake.lock` names the dirty sibling's HEAD, which is a
## pin describing content nobody else can obtain — the checkout at that
## revision does not contain the uncommitted work that was actually built.
##
## Test-double policy: NO mocks, doubles or fakes. See the header of
## `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, times, unittest]

import nf2_flake_lock_fixture

suite "NF-2: a dirty sibling leaves the lock alone":

  test "t_a_dirty_sibling_leaves_the_lock_alone":
    if not nf2Prerequisites("t_a_dirty_sibling_leaves_the_lock_alone"):
      skip()
    else:
      let fx = setupNf2Fixture("dirty")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      # Ahead of its pin AND dirty: there is something to record, and it must
      # not be recorded.
      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      dirtySibling(fx, "alpha")
      check gitIn(fx, siblingDir(fx, "alpha"), "status --porcelain").strip().len > 0

      let before = readFile(lockPath(fx))
      sleep(1100)
      let mtimeBefore = getLastModificationTime(lockPath(fx))

      # ---- (1) the commit itself SUCCEEDS. --------------------------------
      writeFile(fx.app / "work.txt", "work made against a dirty sibling\n")
      discard requireCmd(q(fx.gitBin) & " -C " & q(fx.app) & " add -A")
      let commit = run(q(fx.gitBin) & " -C " & q(fx.app) &
        " commit -m " & q("work against a dirty sibling"))
      if commit.code != 0:
        checkpoint("commit output:\n" & commit.output)
      check commit.code == 0
      check gitIn(fx, fx.app, "log -1 --pretty=%s").strip() ==
        "work against a dirty sibling"

      # ---- (2) the hook ran, and declined. --------------------------------
      # A pre-commit hook that can abort a commit makes (1) a real assertion:
      # `git commit` above would have exited non-zero had the hook refused.
      # This states the other half — that it RAN, so "the lock is untouched"
      # below is a decision rather than a no-show.
      check lastFlakeLogLine(fx).len > 0

      # ---- (3) the lock is untouched. -------------------------------------
      let after = readFile(lockPath(fx))
      if after != before:
        checkpoint("log:\n" & preCommitLog(fx))
      check after == before
      # …and the commit carries the OLD pin rather than a refreshed one.
      check lockInCommit(fx) == before
      check getLastModificationTime(lockPath(fx)) == mtimeBefore
      # Stated positively as well: the dirty sibling's HEAD is NOWHERE in the
      # lock. This is the assertion the "record it anyway" mutation fails, and
      # it names the exact thing that must not have been filed.
      check newAlpha notin after
      check fx.seedSha[0] in nodeText(after, "alpha-src")

      # ---- (4) the skip is loud, and names a runnable remedy. -------------
      let log = lastFlakeLogLine(fx)
      check log.contains("skipped-dirty-sibling")
      check log.contains("alpha")
      check log.contains("NOT refreshed")
      check log.contains("repro flake refresh-lock")

      # ---- the operator verb agrees, and says so on stderr. ---------------
      let direct = run(q(fx.repro) &
        " flake refresh-lock --all --tool-provisioning=path", cwd = fx.app)
      check direct.code == 0
      check direct.output.contains("skipped-dirty-sibling")
      check readFile(lockPath(fx)) == before
      check getLastModificationTime(lockPath(fx)) == mtimeBefore

      # ---- …and once the sibling is clean, the pin IS recorded. -----------
      # Without this the case could be satisfied by a refresh that never works
      # at all, which is the same shape of defect from the other side.
      discard requireCmd(q(fx.gitBin) & " -C " &
        q(siblingDir(fx, "alpha")) & " checkout -- marker.txt")
      let recovered = run(q(fx.repro) &
        " flake refresh-lock --all --tool-provisioning=path", cwd = fx.app)
      check recovered.code == 0
      check readFile(lockPath(fx)).contains(newAlpha)
