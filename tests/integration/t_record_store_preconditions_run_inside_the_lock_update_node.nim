## HL-10 — a RECORD-STORE project whose lock-update node will write: the
## issuance preconditions (the reused pre-push gate, which in a record-store
## workspace resolves — and may write — the lock record) run inside the node's
## executor, after the node wrote and before any test command, and the
## certificate binds the refreshed content (Unified-Locking-And-Hooks.md
## §13.7.3 item 3, §13.7.5 "Out-of-tree lock backends", §13.7.6;
## Test-Certificates.md §"The lock is refreshed by the certifying run",
## TC-8d "one tested state").
##
## Until this test only committed-lock projects exercised that path. The
## preconditions are deferred into the executor exactly when the would-write
## predicate says the node will rewrite a lock, so this drives that case.
##
## Fixture: ``lock_update_node_fixture.nim`` (app → lib-b → lib-c, a committed
## ``repro.lock`` in app pinning them, the managed hooks), with the workspace
## additionally DECLARING a manifest-backed lock route
## (``seedManifestLockStore``), which makes app a record-store project for the
## gate. Steps:
##
##   1. lib-b advances, so the would-write predicate is non-empty and the
##      preconditions are deferred into the executor.
##   2. ``repro test``: the node re-pins and stages ``repro.lock``; the test
##      command saw the refreshed lock; exactly one certificate is issued, for
##      the working tree that carries it; the production verifier, given the
##      record-store lock source, finds it covering that content; the exit
##      code is 0.
##   3. The gate the executor ran resolved app's lock record: the record store
##      holds a record for app's HEAD, and it names lib-b's NEW revision —
##      the state observed after the node, not before it.
##   4. ``git commit -a`` through the installed hooks leaves ``repro.lock``
##      byte-identical: the managed refresh finds nothing to do.
##
## Falsifiability: take the preconditions before the node in this case →
## step 2's certificate is for content without the refreshed lock (or none is
## issued: "repo not at the locked revision"); a gate inside the executor that
## cannot resolve the record store → no certificate, and step 3 finds no
## record.
##
## NO MOCKS: real repositories and manifest, a real git record store, the
## built ``repro``, the real provider, engine and monitor, real
## ``git commit``, the production verifier. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_tool_profiles
import ./lock_update_node_fixture

suite "HL-10 — record-store preconditions inside the lock-update node":

  test "t_record_store_preconditions_run_inside_the_lock_update_node":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      var fx = setupLockUpdateFixture("hl10-records")
      defer: removeDir(fx.cf.sib.scratch)
      seedManifestLockStore(fx.cf.sib.gitBin, fx.cf.sib.ws)
      fx.ensureHooks()
      let recordsDir = lockRecordsDirFor(
        fx.cf.sib.ws / ".repro" / "manifests", "app", "app")

      # ---- 1. lib-b moves: the node will write ---------------------------
      let libBNext = fx.cf.sib.advance("lib-b")
      let planned = planCommitTimeLockWriters(fx.cf.sib.ws, fx.app,
        tpmPathOnly, PinRegressionAllowance())
      check planned.wouldWrite.len == 1
      check planned.refused.len == 0

      # ---- 2. the certifying run -----------------------------------------
      let before = fx.lockText()
      let run = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test:\n" & run.output)
      check run.code == 0
      check "repro lock-update: " in run.output
      let after = fx.lockText()
      check after != before
      check libBNext in after
      check fx.stagedLock() == after
      check fx.lockSeenByTests() == after
      let content = fx.contentNow()
      let certs = fx.certificatesFor(content, "test")
      check certs.len == 1
      if certs.len == 1:
        check certs[0].vcs.content == content
        let keys = readRegisteredKeyStoreChecked(
          registeredKeyStorePath(fx.cf.sib.ws))
        let found = @[FoundCertificate(name: "issued",
          read: CertificateReadResult(status: crsOk, cert: certs[0]))]
        let verdict = evaluateReprobuildCoverage(found,
          workingTreeUnderEvaluation(fx.app, "app"),
          @[currentPlatformTag()], @["test"], keys,
          recordStoreLockSource(recordsDir))
        checkpoint("verdict: " & $verdict)
        check verdict.outcome == voCovered

      # ---- 3. the record the executor's gate resolved --------------------
      let head = fx.cf.sib.headOf(fx.app)
      let record = resolveLockAtCommit(recordsDir, head)
      checkpoint("record: " & $record)
      check record.status == lacPresent
      if record.status == lacPresent:
        check libBNext in readFile(record.path)

      # ---- 4. the commit: nothing left to re-pin --------------------------
      let commit = fx.gitApp("commit", "-a", "-m", "after the move")
      checkpoint("git commit:\n" & commit.output)
      check commit.code == 0
      check fx.lockText() == after
      check fx.headContent() == content
