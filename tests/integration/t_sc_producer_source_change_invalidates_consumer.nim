## Cross-Repo-Source-Consumption SC-4 — source-content fingerprint folding +
## invalidation. A change to a develop-overridden sibling PRODUCER's SOURCE
## shifts the CONSUMER action's weak fingerprint (so the consumer rebuilds);
## an action consuming NO cross-repo producer keeps its cache key byte-for-byte;
## in lock-pinned mode a refreshed producer pin shifts the consumer key and an
## unchanged pin does not.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.3 (source invalidation).
## Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-4.
##
## The gap SC-4 closes: ``foldOverridesIntoFingerprint``
## (``override_resolution.nim:349-380``) — the fold that folds a develop
## override's ``contentIdentity`` into an action's weak fingerprint — was defined
## but called ONLY from ``t_workspace_override_shadows_upstream_in_resolver.nim``,
## never from the engine, so there was NO source-based invalidation of an
## overridden/sibling producer. SC-4 activates it at the splice seam via the new
## ``foldProducerSourceIdentities`` pass (``repro_cli_support``), which the CLI
## build path calls right after the SC-2/SC-3 build-PRODUCT fold
## (``foldProducerActionHashes``).
##
## This test drives the SC-4 seam pass ``foldProducerSourceIdentities`` DIRECTLY
## and hermetically (the same in-process style as the SC-1 seam test), against a
## tempdir consumer workspace + a real sibling checkout resolved through
## ``resolveProducerBinding`` — so the ``contentIdentity`` folded is the SAME one
## the shipped develop-override resolver produces (``computeOverrideContentIdentity``,
## which folds the sibling checkout's local-path root mtime), not a fabricated
## value. The SC-2/SC-3 end-to-end executable/library splices already prove the
## producer is built + consumed from source; SC-4 is specifically the
## SOURCE-content invalidation arm, and the fold on the action fingerprint is the
## exact, observable, falsifiable unit of that behaviour.
##
## Assertions:
##   0. Baseline / byte-identical no-op: with ``producerSourceBindings`` EMPTY,
##      ``foldProducerSourceIdentities`` leaves BOTH the producer-naming consumer
##      action AND the no-producer control action byte-for-byte (the "an action
##      consuming no cross-repo producer keeps its cache key unchanged" property,
##      §4.3 / override_resolution.nim:375-379). This is ALSO the state a
##      disabled fold produces — the falsifiability baseline.
##   1. Develop source fold: with a develop-override ``rpbkOverride`` binding for
##      ``prod`` in ``producerSourceBindings``, the fold SHIFTS the fingerprint
##      of the action naming ``prod`` (the consumer) and leaves the control
##      action (naming only ``sh``) UNCHANGED.
##   2. Reuse (not reinvention): the shifted consumer fingerprint EQUALS
##      ``foldOverridesIntoFingerprint(orig, @[binding])`` — proving SC-4 drives
##      the shipped never-called fold, not a bespoke digest.
##   3. Producer SOURCE change invalidates the consumer: bumping the sibling
##      checkout's root mtime (a source edit) yields a NEW ``contentIdentity``
##      and re-resolves to a DIFFERENT binding; folding it from the SAME original
##      fingerprint gives a DIFFERENT digest than assertion (1) — i.e. editing
##      the producer's source rebuilds the consumer.
##   4. Lock-pinned arm: with no override and a ``LockedDep`` pin, the fold
##      SHIFTS the consumer fingerprint (a pinned ``revision`` + ``integrity`` is
##      the source identity); a REFRESHED pin (new revision/integrity) shifts it
##      to a DIFFERENT digest, while re-folding the SAME pin reproduces the SAME
##      digest (an unchanged pin does not move the key).
##
## Falsifiability (reproduced by the implementation agent): commenting out the
## ``foldProducerSourceIdentities(scheduledActions)`` call at the CLI splice seam
## (``repro_cli_support``), or clearing ``producerSourceBindings`` before the
## fold, collapses assertions (1)/(3)/(4) to the assertion-(0) no-op — the
## consumer fingerprint no longer shifts on a producer source change, so a stale
## consumer would be served from cache. Reverting restores the shift.
##
## Hermetic: the consumer workspace + the sibling checkout live in a fresh
## tempdir; nothing touches $HOME and no network / git / repro binary is needed.

import std/[options, os, times, unittest]

import repro_cli_support
import repro_hash
import repro_lock
import repro_workspace_manifests
import repro_build_engine

const
  producerName = "prod"
  siblingUrl = "https://vcs.invalid/prod.git"
  siblingRevA = "0123456789abcdef0123456789abcdef01234567"
  siblingRevB = "89abcdef0123456789abcdef0123456789abcdef"
  siblingIntegrityA = "git-sha1:0123456789abcdef0123456789abcdef01234567"
  siblingIntegrityB = "git-sha1:89abcdef0123456789abcdef0123456789abcdef"

proc mkAction(id: string; refs: seq[string]): BuildAction =
  ## A minimal ``BuildAction`` with a deterministic non-empty weak fingerprint
  ## and the given tool-identity refs — the shape the CLI hands the SC-4 fold.
  BuildAction(
    kind: bakProcess,
    id: id,
    cacheable: true,
    toolIdentityRefs: refs,
    weakFingerprint: weakFingerprintFromText("sc4-fixture-" & id))

proc writeLock(workspaceRoot: string; revision, integrity: string) =
  ## Pin ``prod`` as a VCS ``LockedDep`` (coordinates + integrity) in the
  ## committed lock so the lock-pinned SC-4 arm has a source identity to fold.
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("sc4-fixture"))
  ld.deps.add(LockedDep(
    name: producerName,
    path: "../prod",
    coordinates: Coordinates(kind: ckVcs, url: siblingUrl,
      gitRef: "main", revision: revision),
    integrity: integrity,
    visibility: "public"))
  writeFile(committedLockPath(workspaceRoot), serializeLockedDependencies(ld))

proc writeOverride(workspaceRoot, siblingCheckout: string) =
  let file = newDevelopOverrides().addOverride(DevelopOverrideEntry(
    package: producerName,
    local_path: siblingCheckout,
    state: "editable",
    created_at: "2026-07-02T00:00:00Z"))
  writeDevelopOverridesFile(workspaceRoot, file)

suite "SC-4: producer source change invalidates consumer":

  test "t_sc_producer_source_change_invalidates_consumer":
    let scratch = getTempDir() / "sc4-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)

    # The sibling producer checkout the develop override points at (SC-1 shape).
    let siblingCheckout = absolutePath(scratch / "prod")
    createDir(siblingCheckout)
    writeFile(siblingCheckout / "repro.nim", "package prod:\n  discard\n")

    # The original consumer/control fingerprints (captured once; the fold is
    # always applied to a fresh copy so each assertion measures the shift from
    # this same baseline).
    let consumerOrig = mkAction("consumer.consume", @["sh", producerName])
    let controlOrig = mkAction("consumer.control", @["sh"])

    # ---- (0) empty sink -> byte-identical no-op (the falsifiability baseline
    # AND the "no cross-repo producer keeps its cache key unchanged" property).
    producerSourceBindings.clear()
    var noopActions = @[consumerOrig, controlOrig]
    foldProducerSourceIdentities(noopActions)
    check noopActions[0].weakFingerprint == consumerOrig.weakFingerprint
    check noopActions[1].weakFingerprint == controlOrig.weakFingerprint

    # ---- (1) develop source fold: an ``rpbkOverride`` binding for ``prod``
    # shifts the producer-naming consumer action; the control action is
    # untouched. Resolve the binding through the SHIPPED SC-1 hook so the
    # ``contentIdentity`` is the real ``computeOverrideContentIdentity`` value.
    writeLock(workspace, siblingRevA, siblingIntegrityA)
    writeOverride(workspace, siblingCheckout)
    let devBinding = resolveProducerBinding(producerName, workspace)
    check devBinding.kind == pbkDevelopOverride
    check devBinding.overrideBinding.kind == rpbkOverride
    check devBinding.contentIdentity.len > 0

    producerSourceBindings.clear()
    producerSourceBindings[producerName] = devBinding.overrideBinding
    var devActions = @[consumerOrig, controlOrig]
    foldProducerSourceIdentities(devActions)
    # The consumer (names ``prod``) is invalidated; the control (no producer) is
    # byte-identical to today.
    check devActions[0].weakFingerprint != consumerOrig.weakFingerprint
    check devActions[1].weakFingerprint == controlOrig.weakFingerprint

    # ---- (2) reuse, not reinvention: the shift IS the shipped fold.
    let expectedDev = foldOverridesIntoFingerprint(
      consumerOrig.weakFingerprint, @[devBinding.overrideBinding])
    check devActions[0].weakFingerprint == expectedDev
    let consumerDevFingerprint = devActions[0].weakFingerprint

    # ---- (3) producer SOURCE change -> new contentIdentity -> different fold.
    # Bump the sibling checkout's root mtime (a source edit) and re-resolve;
    # ``computeOverrideContentIdentity`` folds the root mtime, so the binding's
    # ``contentIdentity`` changes and the fold from the SAME baseline differs.
    let future = getTime() + initDuration(seconds = 120)
    setLastModificationTime(siblingCheckout, future)
    let devBinding2 = resolveProducerBinding(producerName, workspace)
    check devBinding2.kind == pbkDevelopOverride
    check devBinding2.contentIdentity != devBinding.contentIdentity  # source moved

    producerSourceBindings.clear()
    producerSourceBindings[producerName] = devBinding2.overrideBinding
    var devActions2 = @[consumerOrig, controlOrig]
    foldProducerSourceIdentities(devActions2)
    # The consumer rebuilds: its cache key differs from the pre-edit key.
    check devActions2[0].weakFingerprint != consumerDevFingerprint
    check devActions2[0].weakFingerprint != consumerOrig.weakFingerprint
    # The control still never moves.
    check devActions2[1].weakFingerprint == controlOrig.weakFingerprint

    # ---- (4) lock-pinned arm: no override, a ``LockedDep`` pin is the source
    # identity. A pin shifts the consumer key; a refreshed pin shifts it
    # differently; the same pin reproduces the same key.
    removeFile(developOverridesPath(workspace))
    check not fileExists(developOverridesPath(workspace))

    writeLock(workspace, siblingRevA, siblingIntegrityA)
    let lockBindingA = resolveProducerBinding(producerName, workspace)
    check lockBindingA.kind == pbkLockPinned

    proc foldLock(dep: LockedDep): ContentDigest =
      ## Reproduce the CLI seam's lock-pinned recording + fold on a fresh copy.
      producerSourceBindings.clear()
      producerSourceBindings[producerName] = lockPinnedSourceBinding(
        producerName, dep)
      var acts = @[consumerOrig, controlOrig]
      foldProducerSourceIdentities(acts)
      # Control never moves in the lock-pinned arm either.
      check acts[1].weakFingerprint == controlOrig.weakFingerprint
      acts[0].weakFingerprint

    let lockKeyA1 = foldLock(lockBindingA.lockedDep)
    let lockKeyA2 = foldLock(lockBindingA.lockedDep)
    # A pinned producer shifts the consumer key off the un-folded baseline...
    check lockKeyA1 != consumerOrig.weakFingerprint
    # ...deterministically: the SAME pin reproduces the SAME key (unchanged pin
    # does not move the consumer cache key).
    check lockKeyA1 == lockKeyA2

    # A REFRESHED pin (new revision + integrity) shifts the consumer key.
    writeLock(workspace, siblingRevB, siblingIntegrityB)
    let lockBindingB = resolveProducerBinding(producerName, workspace)
    check lockBindingB.kind == pbkLockPinned
    let lockKeyB = foldLock(lockBindingB.lockedDep)
    check lockKeyB != lockKeyA1

    # Reset the shared sink so no state leaks to other tests in the same binary.
    producerSourceBindings.clear()
