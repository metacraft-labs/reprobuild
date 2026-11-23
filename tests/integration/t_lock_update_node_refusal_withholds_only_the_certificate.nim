## HL-10 — a refusal of the lock-update node withholds the certificate and
## nothing else (Unified-Locking-And-Hooks.md §13.3 "A pin never moves
## backward silently", §13.7.3 item 2, §13.7.6 third obligation;
## Interactive-UX Principle 2).
##
## Fixture: ``lock_update_node_fixture.nim``. lib-b advances and the lock is
## refreshed and committed, then the lib-b checkout is reset one commit back,
## so it is BEHIND its pin. Then:
##
##   1. ``repro test`` refuses in the node with the hook's refusal text
##      (sibling, relation and distance, both revisions, the forward command,
##      the deliberate-downgrade rerun with ``--allow-pin-regression``),
##      writes and stages nothing, still runs the tests, exits 0 as the tests
##      do, and issues no certificate;
##   2. the exit code is the tests' own: with a member made to fail, the
##      refusing run exits exactly as ``repro test --no-certify`` does, and
##      not 0;
##   3. with ``REPRO_ALLOW_PIN_REGRESSION=lib-b`` the run re-pins backward,
##      prints both revisions, stages the lock and issues for the content
##      that carries it;
##   4. after restoring the committed lock, ``--allow-pin-regression=lib-b``
##      does the same from the command line.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider and engine. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./lock_update_node_fixture

suite "HL-10 — a lock-update refusal withholds only the certificate":

  test "t_lock_update_node_refusal_withholds_only_the_certificate":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-refuse")
      defer: removeDir(fx.cf.sib.scratch)
      let ws = fx.cf.sib.ws
      let libB = ws / "lib-b"
      let pinned = fx.cf.sib.advance("lib-b")
      fx.cf.sib.refreshAndPublishLock()
      check pinned in fx.lockText()
      discard fx.cf.sib.git(libB, "reset -q --hard HEAD~1")
      let observed = fx.cf.sib.headOf(libB)
      check observed != pinned
      let lockBefore = fx.lockText()
      let indexBefore = fx.indexEntries()

      # ---- 1. refused: nothing written, tests run, no certificate ----------
      let ranBefore = fx.executedOutputs().len
      let refused = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("refused run:\n" & refused.output)
      check refused.code == 0
      check "REFUSED: this lock update would move 1 pinned sibling " &
        "revision(s) BACKWARD" in refused.output
      check "repro.lock sibling 'lib-b': behind by 1 commit(s)" in
        refused.output
      check ("pinned " & pinned & ", observed " & observed) in refused.output
      check "--allow-pin-regression=lib-b" in refused.output
      check "no certificate — the lock-update node refused" in refused.output
      check fx.lockText() == lockBefore
      check fx.indexEntries() == indexBefore
      check fx.executedOutputs().len > ranBefore
      check fx.storedCount() == 0

      # ---- 2. the exit code is the tests' own ------------------------------
      writeFile(fx.app / "src" / "unit_a.txt", "FAIL on purpose\n")
      let failingRefused = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("failing, refused:\n" & failingRefused.output)
      let failingPlain = fx.reproIn(["test", "--no-certify",
        "--tool-provisioning=path"])
      checkpoint("failing, --no-certify:\n" & failingPlain.output)
      check failingRefused.code != 0
      check failingRefused.code == failingPlain.code
      check "REFUSED: this lock update" in failingRefused.output
      writeFile(fx.app / "src" / "unit_a.txt", "unit_a v1\n")
      check fx.lockText() == lockBefore
      check fx.storedCount() == 0

      # ---- 3. the environment variable allows the downgrade ----------------
      let allowed = fx.reproInEnv(["test", "--tool-provisioning=path"],
        [(name: "REPRO_ALLOW_PIN_REGRESSION", value: "lib-b")])
      checkpoint("allowed by the variable:\n" & allowed.output)
      check allowed.code == 0
      check ("allowed pin regression (REPRO_ALLOW_PIN_REGRESSION): " &
        "repro.lock sibling 'lib-b' moved BACKWARD from " & pinned & " to " &
        observed) in allowed.output
      check observed in fx.lockText()
      check pinned notin fx.lockText()
      check fx.stagedLock() == fx.lockText()
      check fx.certificatesFor(fx.contentNow(), "test").len == 1

      # ---- 4. the command-line flag allows it too --------------------------
      discard fx.mustGitApp("checkout", "HEAD", "--", "repro.lock")
      check fx.lockText() == lockBefore
      let flagged = fx.reproIn(["test", "--allow-pin-regression=lib-b",
        "--tool-provisioning=path"])
      checkpoint("allowed by the flag:\n" & flagged.output)
      check flagged.code == 0
      check ("allowed pin regression (--allow-pin-regression): " &
        "repro.lock sibling 'lib-b' moved BACKWARD from " & pinned & " to " &
        observed) in flagged.output
      check observed in fx.lockText()
      check fx.stagedLock() == fx.lockText()
      # The same content as step 3, so its certificate is already there; the
      # run issues again (the node changed the lock, so the no-op is not
      # consulted) and the store keeps both signatures.
      check fx.certificatesFor(fx.contentNow(), "test").len >= 1
      check "repro test: issued test-certificate.v1 for 'test'" in
        flagged.output
