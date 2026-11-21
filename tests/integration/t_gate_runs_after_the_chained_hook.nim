## HL-10 — the certificate gate runs after the chained user hook
## (Unified-Locking-And-Hooks.md §13.7.3 item 5, §13.7.6 sixth obligation;
## test-certificates Standard §5.1; TC-8g).
##
## Fixture: ``lock_update_node_fixture.nim`` with a ``required`` policy for
## ``test`` and the managed hooks installed. ``repro test`` certifies a
## working-tree edit (its lock-update node runs first and finds nothing to
## do). Then:
##
##   1. with a chained ``pre-commit.repro-local`` hook that appends to a
##      tracked file and stages it (a formatter), ``git commit -a`` records
##      content no certificate covers, and the gate, which runs after the
##      chained hook, refuses it. HEAD does not move;
##   2. control: with the chained hook removed and the formatter's change
##      undone, the same commit is covered and goes through.
##
## This reddens if the gate runs before the chained hook, for instance when
## it is moved back into the managed refresh's body. The dispatcher order
## itself is TC-8g's (``t_pre_commit_gate_judges_the_index_being_committed``
## case 5); this test pins it for content certified through the lock-update
## node.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, real
## ``git commit`` through the installed hooks. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import ./lock_update_node_fixture

suite "HL-10 — the gate runs after the chained hook":

  test "t_gate_runs_after_the_chained_hook":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-chained", requireTest = true)
      defer: removeDir(fx.cf.sib.scratch)
      fx.ensureHooks()
      writeFile(fx.app / "README.md", "app fixture, edited\n")
      let tested = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test:\n" & tested.output)
      check tested.code == 0
      let content = fx.contentNow()
      check fx.certificatesFor(content, "test").len == 1

      # ---- 1. a chained hook restages a rewritten file ---------------------
      let local = fx.app / ".git" / "hooks" / "pre-commit.repro-local"
      check not fileExists(local)
      writeFile(local, "#!/bin/sh\n" &
        "# a formatter: normalises README.md and restages it\n" &
        "printf 'formatted\\n' >> README.md\n" &
        "git add README.md\n")
      setFilePermissions(local, {fpUserRead, fpUserWrite, fpUserExec})
      let head0 = fx.cf.sib.headOf(fx.app)
      let refused = fx.gitApp("commit", "-a", "-m", "formatted")
      checkpoint("git commit with the chained hook:\n" & refused.output)
      check refused.code != 0
      check fx.cf.sib.headOf(fx.app) == head0
      check "no trusted certificate covers" in refused.output
      check "formatted" in readFile(fx.app / "README.md")

      # ---- 2. control: without it, the certified content commits -----------
      removeFile(local)
      writeFile(fx.app / "README.md", "app fixture, edited\n")
      check fx.contentNow() == content
      let committed = fx.gitApp("commit", "-a", "-m", "certified")
      checkpoint("git commit without it:\n" & committed.output)
      check committed.code == 0
      check fx.headContent() == content
