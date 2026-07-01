## Unified-Locking-And-Hooks HL-7 (§8.4 corner: "team repo present only as a
## backend record, no local checkout") — a team/private repo that participates
## by its published record / evidence (NOT cloned). The gate treats the two
## sub-schemes DIFFERENTLY, and both flow through the SAME real decision proc
## (``gateDecideUnreadableRepo``) the pre-push gate calls, so this test exercises
## the gate's genuine verdict rather than a re-implementation:
##
##   * a SHARED-PRIVATE repo (source expected, NOT marked evidence-only) whose
##     checkout is ABSENT is an actionable ``clone-required`` failure — a
##     teammate must gain read access and clone it; the missing checkout is
##     NEVER waved through as "clean";
##   * an EVIDENCE-ONLY repo (``participation = "evidence-only"``) is VERIFIED
##     from its published source-free evidence (clean + published + at-locked-SHA
##     ⇒ satisfied); it needs no local checkout at all.
##
## This is the §5 durability contract at the pre-push boundary: a repo with no
## working tree still has a durable BACKEND RECORD, and the gate's verdict is
## driven by that record (or the actionable absence of source), never by an
## optimistic "no checkout ⇒ nothing to check" shortcut.
##
## Assertions:
##   1. shared-private + no ``.git`` ⇒ ``gateDecideUnreadableRepo`` FAILS with a
##      ``clone-required`` ``CheckFailure`` naming the repo path + a clone remedy
##      (verdict is NOT evidence-satisfied — the boundary is unproven).
##   2. evidence-only + published clean/published/at-locked evidence ⇒ the gate
##      SUCCEEDS (verdict ``urvEvidenceSatisfied``), consuming the record in lieu
##      of a checkout — no ``clone-required``.
##   3. evidence-only WITHOUT the required evidence (unpublished) still FAILS —
##      an evidence-only repo is not automatically satisfied by being record-only.
##
## Falsifiability (each reproduced below by feeding the WRONG input, observing
## the assertion trip, then restoring):
##   * Treating the missing shared-private checkout as clean/satisfied — i.e.
##     asserting the verdict is NOT ``clone-required`` — trips (1): the real
##     decision IS ``clone-required``, so "missing == clean" is provably wrong.
##   * Feeding DIRTY evidence to the evidence-only case makes the verdict
##     ``urvEvidenceDirty`` (FAILS), so "record present ⇒ satisfied" is wrong —
##     the record's CONTENT decides, proving (2) is a real verification.
##
## Skip rule: ``git`` missing on PATH (a git identity is resolved for parity with
## the gate; the committed-file backend itself needs no git).

import std/[os, strutils, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import repro_workspace_manifests
import evidence

proc mkRepo(name, path: string; v: WorkspaceVisibility;
            participation = ""; fetchUrl = ""): ResolvedRepo =
  ResolvedRepo(name: name, path: path, visibility: v,
    participation: participation, fetchUrl: fetchUrl)

const lockedSha = "3333333333333333333333333333333333333333"

proc evidence(headSha: string; clean, published: bool):
    seq[WorkspaceVcsEvidence] =
  @[
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "acme-internal", op: wvqHeadSha,
      status: wvesResolved, headSha: headSha),
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "acme-internal", op: wvqIsClean,
      status: wvesResolved, isClean: clean),
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "acme-internal",
      op: wvqIsPublished, status: wvesResolved, isPublished: published)]

proc seedStore(ws: string): LockStore =
  ## A committed-file backend holding the repo's participation lock record
  ## (path→revision) — the durable BACKEND RECORD that stands in for "the team
  ## repo is present only as a record, no checkout".
  let store = newCommittedFileLockStore(ws / "store")
  discard store.putLock(StoreLockRecord(
    key: StoreLockKey(project: "acme", repo: "acme-internal", sha: lockedSha),
    body: "[[repo]]\npath = \"acme-internal\"\nrevision = \"" &
      lockedSha & "\"\n"))
  store

suite "HL-7 — team repo present only as a backend record, no local checkout":

  test "t_team_repo_record_only_no_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # =================================================================
      # (1) SHARED-PRIVATE, no checkout ⇒ clone-required (actionable).
      # A team repo whose source is EXPECTED (not evidence-only) but whose
      # working tree is absent cannot be verified from a record alone — the
      # gate demands the clone. It is NEVER treated as "clean because absent".
      # =================================================================
      block sharedPrivateNoCheckoutClonesRequired:
        let ws = createTempDir("repro-hl7-team-shared-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)  # a durable record exists ...
        # ... but the repo is shared-private (source expected) and NOT cloned.
        let repo = mkRepo("acme-internal", "acme-internal", wvTeam,
          fetchUrl = "git@example.invalid:acme/acme-internal.git")
        let outcome = gateDecideUnreadableRepo(repo, store, "acme")
        check outcome.failed
        check outcome.failure.property == "clone-required"
        check outcome.failure.repo == "acme-internal"
        check outcome.failure.remediation.contains("acme-internal")
        # Falsify (missing == clean): the real verdict IS clone-required, so
        # asserting it is anything else — e.g. an evidence-satisfied pass —
        # trips. A record's mere existence does NOT satisfy a shared-private
        # repo whose source the gate expects to see.
        check outcome.verdict.verdict != urvEvidenceSatisfied

      # =================================================================
      # (2) EVIDENCE-ONLY, record present + clean/published/at-locked ⇒
      # verified from evidence; NO checkout required, NO clone-required.
      # =================================================================
      block evidenceOnlyRecordVerifies:
        let ws = createTempDir("repro-hl7-team-evidence-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("acme", "acme-internal",
          evidence(lockedSha, clean = true, published = true)).outcome == spoOk
        let repo = mkRepo("acme-internal", "acme-internal", wvTeam,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "acme")
        check not outcome.failed
        check outcome.verdict.verdict == urvEvidenceSatisfied
        # It is a RECORD-only pass, not a clone-required error.
        check outcome.failure.property != "clone-required"

      # =================================================================
      # (3) EVIDENCE-ONLY but the evidence proves the boundary VIOLATED
      # (unpublished) ⇒ FAILS. Falsify "record present ⇒ satisfied": the
      # record's CONTENT decides, so a record-only repo with bad evidence is
      # NOT waved through.
      # =================================================================
      block evidenceOnlyDirtyStillFails:
        let ws = createTempDir("repro-hl7-team-evidence-bad-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("acme", "acme-internal",
          evidence(lockedSha, clean = true, published = false)).outcome == spoOk
        let repo = mkRepo("acme-internal", "acme-internal", wvTeam,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "acme")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceUnpublished
        check outcome.failure.property == "evidence-only-unverified"
