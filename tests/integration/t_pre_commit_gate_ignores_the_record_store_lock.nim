## TC-8g — in a project whose lock lives in an out-of-tree record store, the
## pre-commit certificate gate passes on the certificate alone and never
## evaluates the lock record (operator decision D8, 2026-10-09).
##
## The workspace declares the record-store route (``.repro/manifests`` is a
## git checkout), and the per-repo lock subtree the store would be read from
## is made UNREADABLE: ``locks`` is replaced by a regular file, so any lookup
## of a lock record under it fails and would be reported as unverifiable.
## Under ``gate_mode = required`` (recorded in lib-a's committed ``repro.lock``, TC-9d):
##
##   1. a covered index commits, and nothing printed mentions "advisory",
##      "could-not-ask" or "unverifiable" — there is no lock half;
##   2. control: the production verifier evaluating the COMMIT just made
##      (which a push gate does, keyed by commit) through that same store
##      reports the coverage unverifiable, so the stub really is a store that
##      fails when read.
##
## NO MOCKS beyond the deliberately broken store directory. Skip rule:
## ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, unittest]

include pre_commit_gate_fixture

suite "TC-8g — the pre-commit gate ignores the record-store lock":

  test "t_pre_commit_gate_ignores_the_record_store_lock":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let fx = setupStoreFixture(
        requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "tc8g-d8",
        recordStore = true)
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      let locks = fx.workspaceRoot / ".repro" / "manifests" / "locks"
      if dirExists(locks):
        removeDir(locks)
      writeFile(locks, "not a directory: a lock-record read must fail\n")

      # ---- 1. covered: commits, with no lock half ------------------------
      writeFile(fx.libAPath / "a.txt", "alpha\n")
      discard fx.mustGit("add", "a.txt")
      fx.certify(fx.indexContentId)
      let before = fx.head
      let res = fx.commit("-m", "covered, record-store project")
      checkpoint(res.output)
      check res.code == 0
      check fx.head != before
      check fx.gateLogLines("covered") == 1
      let lowered = res.output.toLowerAscii
      check "advisory" notin lowered
      check "could-not-ask" notin lowered
      check "could not ask" notin lowered
      check "unverifiable" notin lowered
      check "could not be established" notin lowered

      # ---- 2. control: evaluated as a commit, the broken store is read ----
      let state = commitUnderEvaluation(fx.libAPath, fx.head)
      let lookup = findCertificatesInLocalStore(state)
      check lookup.found.len == 1
      let verdict = evaluateReprobuildCoverage(lookup.found, state,
        @[currentPlatformTag()], @["t-unit"],
        readRegisteredKeyStoreChecked(registeredKeyStorePath(fx.workspaceRoot)),
        recordStoreLockSource(lockRecordsDirFor(
          fx.workspaceRoot / ".repro" / "manifests", "lib-a", "lib-a")))
      checkpoint("as a commit: " & describeCoverageVerdict(verdict))
      check verdict.outcome == voUnverifiable
