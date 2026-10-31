## HL-10 — a FAILURE of the lock-update node (as opposed to a refusal)
## withholds the certificate and nothing else (Unified-Locking-And-Hooks.md
## §13.7.3 item 2, §13.7.6 third obligation; Interactive-UX Principle 2).
##
## Fixture: ``lock_update_node_fixture.nim``. lib-b advances and is
## published, so the node's ``repro.lock`` re-pin moves FORWARD — the
## preconditions accept the content and nothing is refused — but ``app``'s
## index is locked (a ``.git/index.lock`` another git process would hold),
## so the node rewrites the lock and cannot stage it. Then:
##
##   1. ``repro test`` reports the lock as written but not staged and ends
##      with "no certificate — the lock-update node failed"; the tests still
##      run; the exit code is the tests' own (0); nothing is issued;
##   2. with a member made to fail, the failing run exits exactly as
##      ``repro test --no-certify`` does, and not 0;
##   3. a second passing run, with the lock now current but still unstaged
##      and the index still locked, withholds as well: the node has nothing
##      to write but must still stage the lock an earlier run wrote;
##   4. once the index lock is gone, the next run stages that lock itself
##      (no manual `git add`) and issues for the content that carries it
##      (the positive control: the failure, not the state, withheld the
##      certificate).
##
## Falsifiability: ignore ``notStaged`` in ``lockUpdateNodeRefused`` and step
## 1 issues a certificate for a working tree whose index does not hold the
## lock the tests saw; let the node's failure fail the build and step 1's
## exit code is not 0; drop ``stageCurrentUnstagedLocks`` and step 3 issues
## (nothing to write, so nothing staged) and step 4 leaves the index stale.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider and engine; the index lock is the file git itself creates.
## Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./lock_update_node_fixture

suite "HL-10 — a lock-update node failure withholds only the certificate":

  test "t_lock_update_node_failure_withholds_only_the_certificate":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-fail")
      defer: removeDir(fx.cf.sib.scratch)
      let advanced = fx.cf.sib.advance("lib-b")
      let lockBefore = fx.lockText()
      check advanced notin lockBefore
      let indexLock = fx.app / ".git" / "index.lock"
      writeFile(indexLock, "")

      # ---- 1. failed: tests run, exit 0, no certificate --------------------
      let ranBefore = fx.executedOutputs().len
      let failed = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("failed run:\n" & failed.output)
      check failed.code == 0
      check "no certificate — the lock-update node failed" in failed.output
      check "REFUSED" notin failed.output
      check fx.executedOutputs().len > ranBefore
      check fx.storedCount() == 0
      # The index was never written: the lock git holds is the committed one.
      check fileExists(indexLock)

      # ---- 2. the exit code is the tests' own ------------------------------
      writeFile(fx.app / "src" / "unit_a.txt", "FAIL on purpose\n")
      let failingFailed = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("failing, node failed:\n" & failingFailed.output)
      let failingPlain = fx.reproIn(["test", "--no-certify",
        "--tool-provisioning=path"])
      checkpoint("failing, --no-certify:\n" & failingPlain.output)
      check failingFailed.code != 0
      check failingFailed.code == failingPlain.code
      check fx.storedCount() == 0
      writeFile(fx.app / "src" / "unit_a.txt", "unit_a v1\n")

      # ---- 3. the lock is current but unstaged: still no certificate -------
      # The first run rewrote the lock and could not stage it, so the lock is
      # current in the working tree and the node has nothing left to WRITE.
      # It must still stage it (HL-10 "stages what it wrote"); with the index
      # still locked it cannot, so this run withholds too. Before the node
      # checked for a current-but-unstaged lock, this run issued a
      # certificate for a working tree whose index lacked the tested lock.
      let stillLocked = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("still locked, nothing to write:\n" & stillLocked.output)
      check stillLocked.code == 0
      check "is current but not staged, and could NOT be staged" in
        stillLocked.output
      check "no certificate — the lock-update node failed" in
        stillLocked.output
      check fx.storedCount() == 0

      # ---- 4. positive control: the index frees up, and it issues ----------
      # No manual `git add`: the node stages the lock an earlier run wrote,
      # and the same run issues for the content that carries it (the
      # failure, not the state, withheld the certificate).
      check "then run the tests again" in failed.output
      removeFile(indexLock)
      let issued = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("unlocked run:\n" & issued.output)
      check issued.code == 0
      check "the lock-update node failed" notin issued.output
      check "is current but was not staged (an earlier run refreshed it); " &
        "staged it" in issued.output
      check advanced in fx.lockText()
      check fx.stagedLock() == fx.lockText()
      check fx.certificatesFor(fx.contentNow(), "test").len == 1
