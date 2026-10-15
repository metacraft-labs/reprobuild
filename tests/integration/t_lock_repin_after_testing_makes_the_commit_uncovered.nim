## HL-10 — a sibling that moves AFTER the certifying run makes the commit
## uncovered, and the gate says why (Unified-Locking-And-Hooks.md §13.3
## ordering bullet, §13.7.3 item 4, §13.7.6 fourth obligation; TC-8g).
##
## Fixture: ``lock_update_node_fixture.nim`` with a ``required`` policy for
## ``test`` and the managed hooks installed.
##
##   1. ``repro test`` certifies a working-tree edit; nothing needed
##      re-pinning, so the lock is untouched.
##   2. lib-b advances; ``git commit -a`` fires the managed refresh, which
##      re-pins and stages ``repro.lock`` as decided on 2026-09-30, and the
##      certificate gate, running last, refuses the commit and names that
##      re-pin as the cause. HEAD does not move.
##   3. ``repro test`` again: the content now carries the re-pinned lock (the
##      refused attempt left it staged), so it is certified, and the same
##      ``git commit -a`` goes through, covered.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, real
## ``git commit`` through the installed hooks. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import ./lock_update_node_fixture

suite "HL-10 — a re-pin after testing leaves the commit uncovered":

  test "t_lock_repin_after_testing_makes_the_commit_uncovered":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-after", requireTest = true)
      defer: removeDir(fx.cf.sib.scratch)
      fx.ensureHooks()

      # ---- 1. certified, nothing to re-pin ---------------------------------
      writeFile(fx.app / "README.md", "app fixture, edited\n")
      let lockBefore = fx.lockText()
      let tested = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test:\n" & tested.output)
      check tested.code == 0
      check fx.lockText() == lockBefore
      let content = fx.contentNow()
      check fx.certificatesFor(content, "test").len == 1

      # ---- 2. lib-b moves; the commit-time re-pin makes it uncovered -------
      let head0 = fx.cf.sib.headOf(fx.app)
      let libBNext = fx.cf.sib.advance("lib-b")
      let refused = fx.gitApp("commit", "-a", "-m", "after the move")
      checkpoint("git commit:\n" & refused.output)
      check refused.code != 0
      check fx.cf.sib.headOf(fx.app) == head0
      check "no trusted certificate covers" in refused.output
      check repinCauseLine in refused.output
      # `commit -a` stages into a temporary index git discards on refusal, so
      # the re-pin survives in the working tree only.
      check libBNext in fx.lockText()

      # ---- 3. re-certify; the same commit is covered -----------------------
      let again = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test again:\n" & again.output)
      check again.code == 0
      let content2 = fx.contentNow()
      check content2 != content
      check fx.certificatesFor(content2, "test").len == 1
      let committed = fx.gitApp("commit", "-a", "-m", "after the move")
      checkpoint("git commit again:\n" & committed.output)
      check committed.code == 0
      check fx.headContent() == content2
      check repinCauseLine notin committed.output
