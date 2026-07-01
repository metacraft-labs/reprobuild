## Unified-Locking-And-Hooks HL-6 (§7.3) — the pre-push gate CONSUMES an
## evidence-only repo's published source-free evidence in lieu of a clone, AND
## the HL-3 (§6 Decision 2) loud-vs-warn policy applies to the evidence READ of
## an UNREACHABLE backend.
##
## Both halves drive the EXACT procs the real gate (``executeCheckPrePush``,
## stage 5) calls — ``gateDecideUnreadableRepo`` for the consume and
## ``decideEvidenceReadTierPolicy`` for the tier split — so the test exercises
## the gate's real decision, not a re-implementation.
##
## Part A — consume in lieu of a clone:
##   * clean + published + at-locked-SHA ⇒ the gate SUCCEEDS (verdict
##     ``urvEvidenceSatisfied``, decision ``ergdSatisfied``);
##   * dirty / unpublished / sha-mismatch / evidence-missing ⇒ the gate FAILS.
##
## Part B — HL-3 tier policy on the evidence READ of an unreachable backend
## (no published evidence to read, ``urvEvidenceMissing``; or no store,
## ``urvEvidenceNoBackend``):
##   * TEAM tier (shared — teammates depend on it) ⇒ REFUSE (``ergdRefuse``);
##   * PERSONAL tier (the user's own backend) ⇒ WARN but ALLOW
##     (``ergdWarnAllow``).
##
## Part C — the tier policy applies ONLY to an unreachable READ: an evidence-
## PROVEN violation (dirty) at the PERSONAL tier still REFUSES (``ergdRefuse``)
## — the personal warn must never wave a broken boundary through.
##
## Falsifiability (reproduced by the review): applying the WRONG tier policy to
## the evidence read — treating a team unreachable read as a personal WARN, or a
## personal unreachable read as a team REFUSE — flips the decision and trips the
## ``ergdRefuse`` / ``ergdWarnAllow`` assertions. Waving a dirty personal repo
## through (returning ``ergdWarnAllow`` for a proven violation) trips Part C.
##
## Skip rule: ``git`` missing on PATH (the committed-file backend needs no git,
## but a git identity is resolved for parity with the gate).

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
  @[
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "secret", op: wvqHeadSha,
      status: wvesResolved, headSha: headSha),
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "secret", op: wvqIsClean,
      status: wvesResolved, isClean: clean),
    WorkspaceVcsEvidence(vcsKind: wvkGit, path: "secret", op: wvqIsPublished,
      status: wvesResolved, isPublished: published)]

proc seedStore(ws: string): LockStore =
  ## A committed-file backend holding the evidence-only repo's participation
  ## lock record (path→revision) — the locked SHA the gate verifies against.
  let store = newCommittedFileLockStore(ws / "store")
  discard store.putLock(StoreLockRecord(
    key: StoreLockKey(project: "demo", repo: "secret", sha: lockedSha),
    body: "[[repo]]\npath = \"secret\"\nrevision = \"" & lockedSha & "\"\n"))
  store

suite "HL-6 — pre-push consumes evidence and applies tier unreachable policy":

  test "t_pre_push_consumes_evidence_and_applies_tier_unreachable_policy":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      # =================================================================
      # Part A — consume published evidence in lieu of a clone.
      # =================================================================
      block satisfiedPasses:
        let ws = createTempDir("repro-hl6-consume-ok-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = true, published = true)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check not outcome.failed
        check outcome.verdict.verdict == urvEvidenceSatisfied
        # A satisfied boundary is ``ergdSatisfied`` for EVERY tier.
        check decideEvidenceReadTierPolicy(outcome, wvPersonal) == ergdSatisfied
        check decideEvidenceReadTierPolicy(outcome, wvTeam) == ergdSatisfied

      block dirtyFails:
        let ws = createTempDir("repro-hl6-consume-dirty-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = false, published = true)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceDirty

      block unpublishedFails:
        let ws = createTempDir("repro-hl6-consume-unpub-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = true, published = false)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceUnpublished

      block shaMismatchFails:
        let ws = createTempDir("repro-hl6-consume-sha-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence("2222222222222222222222222222222222222222",
            clean = true, published = true)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceShaMismatch

      # =================================================================
      # Part B — HL-3 tier policy on an UNREACHABLE evidence READ (the
      # backend holds no published evidence to read).
      # =================================================================
      block teamUnreachableRefuses:
        let ws = createTempDir("repro-hl6-team-unreachable-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)  # locked, but NO evidence published
        let repo = mkRepo("secret", "secret", wvTeam,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        # The read could not obtain evidence (backend unreachable for the read).
        check outcome.verdict.verdict == urvEvidenceMissing
        # TEAM tier (shared) ⇒ REFUSE.
        check decideEvidenceReadTierPolicy(outcome, wvTeam) == ergdRefuse
        check decideEvidenceReadTierPolicy(outcome, wvOrg) == ergdRefuse
        check decideEvidenceReadTierPolicy(outcome, wvPublic) == ergdRefuse

      block personalUnreachableWarns:
        let ws = createTempDir("repro-hl6-personal-unreachable-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)  # locked, but NO evidence published
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceMissing
        # PERSONAL tier (the user's own backend) ⇒ WARN but ALLOW.
        check decideEvidenceReadTierPolicy(outcome, wvPersonal) == ergdWarnAllow

      block noBackendTierSplit:
        # No store at all (``store == nil``) ⇒ ``urvEvidenceNoBackend`` — also an
        # unreachable READ. The SAME tier split applies.
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, nil, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceNoBackend
        check decideEvidenceReadTierPolicy(outcome, wvPersonal) == ergdWarnAllow
        check decideEvidenceReadTierPolicy(outcome, wvTeam) == ergdRefuse

      # =================================================================
      # Part C — the personal WARN applies ONLY to an unreachable READ: an
      # evidence-PROVEN violation (dirty) at the personal tier still REFUSES.
      # =================================================================
      block personalDirtyStillRefuses:
        let ws = createTempDir("repro-hl6-personal-dirty-", "")
        defer: removeDir(ws)
        let store = seedStore(ws)
        check store.putEvidence("demo", "secret",
          evidence(lockedSha, clean = false, published = true)).outcome == spoOk
        let repo = mkRepo("secret", "secret", wvPersonal,
          participation = "evidence-only")
        let outcome = gateDecideUnreadableRepo(repo, store, "demo")
        check outcome.failed
        check outcome.verdict.verdict == urvEvidenceDirty
        # A PROVEN violation is NOT an unreachable read — REFUSE even at personal.
        check decideEvidenceReadTierPolicy(outcome, wvPersonal) == ergdRefuse
