## HL-10 (push half) — the lock-only diagnostic claims nothing when the pushed
## tree differs from certified content in any file the commit-time lock
## writers do not manage (Test-Certificates.md §"Gate integration — push
## requirement"; Unified-Locking-And-Hooks.md §13.7.6).
##
## Fixture: ``lock_only_push_fixture.nim``. Two pushes, each refused with the
## plain uncovered diagnostic:
##
##   1. certified C1; then README.md AND ``repro.lock`` change and are pushed.
##      A lock difference is present, but not alone: no cause, no "differs
##      from the pushed tree only in".
##   2. certified C2; then README.md alone changes and is pushed: no cause.
##
## Control (inside the test): the same certified C2 with only ``repro.lock``
## rewritten IS named, so the absence above is the search declining, not the
## search never running.
##
## Falsifiability: accept any difference that INCLUDES a lock file as
## lock-only → step 1 fails (verified 2026-11-22 against the in-process
## search, by mutating ``isManagedLockOnlyDifference`` to ``anyIt``); drop
## the managed-path test entirely → step 2 fails.
##
## NO MOCKS: real repositories, the built ``repro``, the production store
## writer and verifier. Skip rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[json, os, osproc, strutils, unittest]

include lock_only_push_fixture

suite "HL-10 — a non-lock push difference makes no lock-only claim":

  test "t_push_with_a_non_lock_change_makes_no_lock_only_claim":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      let fx = setupLockOnlyFixture("hl10-non-lock")
      defer: removeDir(fx.scratch)

      # ---- 1. a lock change and a README change -------------------------
      writeFile(fx.libAPath / "b.txt", "b\n")
      let (c1, _) = fx.certifyWorkingTree()
      fx.relockPolicy()
      writeFile(fx.libAPath / "README.md", "TC-8c fixture, edited\n")
      let p1 = fx.commitAll("lock and readme")
      fx.publish()
      let both = checkPrePush(fx, p1)
      checkpoint("lock + readme:\n" & both.output)
      check both.code == 2
      check failureProperties(both.report) == @["certificate-coverage"]
      let bothEvidence = failureField(both.report, "certificate-coverage",
        "evidence")
      check bothEvidence.startsWith("uncovered: ")
      check lockOnlyCauseMarker notin bothEvidence
      check "differs from the pushed tree only in" notin bothEvidence
      check c1 notin bothEvidence
      check not failureField(both.report, "certificate-coverage",
        "remediation").startsWith("test the content you push")
      # The routine the gate calls, in-process: C1's tree is present and
      # compared, and declined because README.md differs too.
      let requires = @[PolicyRequirement(certificate: "t-unit",
        platforms: @[currentPlatformTag()])]
      let keys = readRegisteredKeyStoreChecked(
        registeredKeyStorePath(fx.workspaceRoot))
      let search = findLockOnlyCertifiedNeighbours(
        commitUnderEvaluation(fx.libAPath, p1), requires, keys,
        committedLockSource())
      checkpoint("in-process search: " & $search)
      check search.considered == 1
      check search.problems.len == 0
      check search.neighbours.len == 0

      # ---- 2. a README change alone --------------------------------------
      writeFile(fx.libAPath / "c.txt", "c\n")
      let (c2, _) = fx.certifyWorkingTree()
      writeFile(fx.libAPath / "README.md", "TC-8c fixture, edited again\n")
      let p2 = fx.commitAll("readme only")
      fx.publish()
      let readme = checkPrePush(fx, p2)
      checkpoint("readme only:\n" & readme.output)
      check readme.code == 2
      let readmeEvidence = failureField(readme.report, "certificate-coverage",
        "evidence")
      check readmeEvidence.startsWith("uncovered: ")
      check lockOnlyCauseMarker notin readmeEvidence
      check c2 notin readmeEvidence

      # ---- control: C2 with only the lock rewritten IS named ------------
      discard gitOut(fx.libAPath, "reset", "-q", "--hard", "HEAD~1")
      writeFile(fx.libAPath / "c.txt", "c\n")
      writeFile(fx.libAPath / "repro.lock", policyLock(requiredPolicy(
        @["t-unit"], @[currentPlatformTag()])))
      let p3 = fx.commitAll("lock only")
      discard gitOut(fx.libAPath, "push", "-q", "--force", "origin", "main")
      discard gitOut(fx.libAPath, "fetch", "-q", "origin")
      let lockOnly = checkPrePush(fx, p3)
      checkpoint("control, lock only:\n" & lockOnly.output)
      check lockOnly.code == 2
      check ("certified content " & c2) in failureField(lockOnly.report,
        "certificate-coverage", "evidence")
