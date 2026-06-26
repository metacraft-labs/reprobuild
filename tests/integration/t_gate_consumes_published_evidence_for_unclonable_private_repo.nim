## Workspace-Manifest-Optional MO-5 — the pre-push gate / ``repro check``
## CONSUMES a private repo's PUBLISHED source-free evidence in lieu of a
## clonable sibling, instead of refusing because the repo is unreadable.
##
## We exercise ``gateDecideUnreadableRepo`` — the EXACT proc the gate
## (``executeCheckPrePush``) calls for every private repo whose source is not
## present locally — so this test drives the gate's real decision, not a
## re-implementation.
##
## Topology (the gate-running teammate's view):
##   * ``secret`` — an EVIDENCE-ONLY private repo. Its source is NOT clonable
##     here; only its participation lock record (path→revision) and its
##     source-free ``WorkspaceVcsEvidence`` (head-sha / clean / published) live
##     in the store. The owner published both from a clean, published checkout
##     at the locked SHA.
##   * ``shared`` — a SHARED-private repo (NOT evidence-only). Its source is
##     also missing locally, but it is EXPECTED to be cloned.
##
## Assertions:
##   1. For ``secret`` the gate SUCCEEDS (not ``failed``) by consuming the
##      published evidence — verdict ``urvEvidenceSatisfied`` — and emits a
##      notice. (Falsifiable: with no published evidence, or with dirty /
##      unpublished / sha-mismatched evidence, the verdict flips to a failure.)
##   2. For ``shared`` the gate produces the actionable ``clone-required``
##      failure — the shared-vs-evidence-only diagnostic distinction.
##   3. SECURITY: a DIRTY evidence-only repo, an UNPUBLISHED one, and a
##      SHA-MISMATCHED one each still FAIL (evidence-only never silently passes
##      a broken boundary).
##
## Skip rule: ``git`` missing on PATH (the committed-file backend itself needs
## no git, but we resolve a git identity for parity with the gate).

import std/[os, strutils, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import repro_workspace_manifests
import evidence

proc mkRepo(name, path: string; v: WorkspaceVisibility;
            participation = ""; fetchUrl = ""): ResolvedRepo =
  ResolvedRepo(name: name, path: path, visibility: v,
    participation: participation, fetchUrl: fetchUrl)

const lockedSha = "1111111111111111111111111111111111111111"

proc evidence(headSha: string; clean, published: bool):
    seq[WorkspaceVcsEvidence] =
  ## A source-free evidence triple as the OWNER would publish it.
  @[
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "secret", op: wvqHeadSha,
      status: wvesResolved, headSha: headSha),
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "secret", op: wvqIsClean,
      status: wvesResolved, isClean: clean),
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "secret", op: wvqIsPublished,
      status: wvesResolved, isPublished: published)]

proc seedStore(ws: string): LockStore =
  ## A committed-file backend with the evidence-only repo's MO-4 participation
  ## lock record (path→revision) already recorded — the locked SHA the gate
  ## verifies the published head-sha against.
  let store = newCommittedFileLockStore(ws / "store")
  let rec = StoreLockRecord(
    key: StoreLockKey(project: "demo", repo: "secret", sha: lockedSha),
    body: "[[repo]]\npath = \"secret\"\nrevision = \"" & lockedSha & "\"\n")
  discard store.putLock(rec)
  store

suite "MO-5 — gate consumes published evidence for an unclonable private repo":

  test "t_gate_consumes_published_evidence_for_unclonable_private_repo":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # ---- 1. evidence-only repo: gate SUCCEEDS by consuming evidence -----
      block evidenceSatisfied:
        let ws = createTempDir("repro-mo5-gate-ok-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        # Owner published clean + published evidence at the locked SHA.
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = true, published = true)).outcome == spoOk

        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        # The gate did NOT refuse — it consumed the evidence.
        check not outcome.failed
        check outcome.verdict.verdict == urvEvidenceSatisfied
        check outcome.verdict.lockedSha == lockedSha
        check outcome.notice.len > 0
        check "evidence" in outcome.notice

      # ---- 2. shared-private repo: actionable clone-required error -------
      block sharedCloneRequired:
        let ws = createTempDir("repro-mo5-gate-shared-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        # A SHARED-private repo (no evidence-only marker). Even though a store
        # exists, the gate must demand a clone — its source is expected present.
        let repo = mkRepo("shared", "shared", wvTeam,
          participation = "", fetchUrl = "ssh://git@example.invalid/shared.git")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.failure.property == "clone-required"
        check "clone" in outcome.failure.remediation
        # The diagnostic clearly distinguishes shared from evidence-only.
        check "not evidence-only" in outcome.failure.evidence

      # ---- 3. SECURITY: a broken evidence-only boundary still FAILS -------
      block dirtyStillFails:
        let ws = createTempDir("repro-mo5-gate-dirty-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = false, published = true)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceDirty
        check outcome.failure.property == "evidence-only-unverified"

      block unpublishedStillFails:
        let ws = createTempDir("repro-mo5-gate-unpub-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = true, published = false)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceUnpublished

      block shaMismatchStillFails:
        let ws = createTempDir("repro-mo5-gate-sha-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        # Clean + published, but at a DIFFERENT head than the locked SHA.
        check store.putEvidence("demo", "secret",
          evidence("2222222222222222222222222222222222222222",
            clean = true, published = true)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceShaMismatch

      block evidenceMissingStillFails:
        let ws = createTempDir("repro-mo5-gate-missing-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        # Locked, but the owner never published any evidence.
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceMissing
