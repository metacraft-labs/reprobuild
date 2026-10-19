## Cross-Repo-Source-Consumption SC-4 — source-content fingerprint folding +
## invalidation, scoped to what the consumer reads.
##
## For a consumer action whose reads NOTHING observes (a recognised-format /
## depfile policy): a change to a develop-overridden sibling PRODUCER's SOURCE
## shifts its weak fingerprint (so it rebuilds); in lock-pinned mode a
## refreshed producer pin shifts the key and an unchanged pin does not.
## Assertions (1)-(4) below.
##
## For a MONITORED consumer action (or a built-in one), the owner's 2026-10-12
## decision recorded in §4.3: the producer's source identity is NOT folded —
## its reads under the producer root key it, so a sibling edit or a lock
## refresh leaves its weak fingerprint where it was and only an action that
## read the changed files misses. What it is handed without reading — the
## producer's realized directories (``--path:`` roots, ``bin``/lib dirs) — is
## folded instead, so a directory that appears or moves still misses it.
## Assertions (5)-(7). Before that decision this test asserted (1)-(4) for the
## monitored action, which is what made a ``repro lock refresh`` of one Nim
## library miss every test compile in reprobuild.
##
## In every case an action consuming NO cross-repo producer keeps its cache key
## byte-for-byte.
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
##   5. Monitored consumer, scoped rule: the fold shifts its fingerprint off the
##      un-folded baseline (the producer's realized directories are on its
##      command line), and the shifted key is the SAME for the develop binding
##      before and after the sibling source edit of (3), and for lock pins A and
##      B of (4) — neither a source edit nor a lock refresh moves it.
##   6. Monitored consumer, channel: a different realized directory for the
##      producer (a fetched producer at a new revision-keyed path) DOES move
##      its key — the directory is the only thing that tells the new content
##      from the old, which is still on disk unchanged.
##   7. A built-in action naming the producer reads only its declared inputs,
##      so it follows the monitored rule.
##
## Falsifiability (reproduced by the implementation agent): commenting out the
## ``foldProducerSourceIdentities(scheduledActions)`` call at the CLI splice seam
## (``repro_cli_support``), or clearing ``producerSourceBindings`` before the
## fold, collapses assertions (1)/(3)/(4) to the assertion-(0) no-op — the
## consumer fingerprint no longer shifts on a producer source change, so a stale
## consumer would be served from cache. Reverting restores the shift. Folding
## the source identity into every action again (the pre-2026-10-12 rule) fails
## (5); dropping the channel fold fails (5)'s first check and (6).
##
## Hermetic: the consumer workspace + the sibling checkout live in a fresh
## tempdir; nothing touches $HOME and no network / git / repro binary is needed.

import std/[options, os, times, unittest]

import repro_cli_support
import repro_core
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

proc mkAction(id: string; refs: seq[string];
              policy = dgRecognizedFormat;
              kind = bakProcess): BuildAction =
  ## A minimal ``BuildAction`` with a deterministic non-empty weak fingerprint
  ## and the given tool-identity refs — the shape the CLI hands the SC-4 fold.
  ## The default is an action whose reads nothing observes (a depfile policy),
  ## the case that still carries the producer's source identity.
  BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: kind,
    id: id,
    cacheable: true,
    dependencyPolicy: DependencyGatheringPolicy(kind: policy),
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

    # ---- (5)-(7) the scoped rule (§4.3, owner decision 2026-10-12): a
    # MONITORED consumer is keyed on what it reads, so the producer's source
    # identity is not folded into it — only the realized directories it is
    # handed. Same producer, same bindings as (1)-(4).
    let monitoredOrig = mkAction("consumer.monitored", @["sh", producerName],
      policy = dgAutomaticMonitor)
    let monitoredControl = mkAction("consumer.monitored-control", @["sh"],
      policy = dgAutomaticMonitor)
    let builtinOrig = mkAction("consumer.builtin", @[producerName],
      kind = bakStamp)
    check monitoredOrig.readsAreKeyed
    check builtinOrig.readsAreKeyed
    check not consumerOrig.readsAreKeyed

    proc foldScoped(binding: ResolvedPackageBinding;
                    nimSrc: string): tuple[monitored, builtin: ContentDigest] =
      producerSourceBindings.clear()
      producerSourceBindings[producerName] = binding
      producerMaterializedAuxPaths.clear()
      producerMaterializedAuxPaths[producerName] =
        ProducerAuxPaths(nimPathDirs: @[nimSrc])
      var acts = @[monitoredOrig, monitoredControl, builtinOrig]
      foldProducerSourceIdentities(acts)
      check acts[1].weakFingerprint == monitoredControl.weakFingerprint
      (monitored: acts[0].weakFingerprint, builtin: acts[2].weakFingerprint)

    let siblingSrc = siblingCheckout / "src"
    let scopedDev = foldScoped(devBinding.overrideBinding, siblingSrc)
    # (5) the producer's directories ARE on its command line: the key moves off
    # the un-folded baseline...
    check scopedDev.monitored != monitoredOrig.weakFingerprint
    # ...but not with the producer's source identity: the sibling edit of (3),
    # and lock pins A and B of (4), all give the SAME key.
    let scopedDevEdited = foldScoped(devBinding2.overrideBinding, siblingSrc)
    let scopedLockA = foldScoped(
      lockPinnedSourceBinding(producerName, lockBindingA.lockedDep), siblingSrc)
    let scopedLockB = foldScoped(
      lockPinnedSourceBinding(producerName, lockBindingB.lockedDep), siblingSrc)
    check scopedDevEdited.monitored == scopedDev.monitored
    check scopedLockA.monitored == scopedDev.monitored
    check scopedLockB.monitored == scopedDev.monitored
    # (6) a different realized directory — a fetched producer's revision-keyed
    # checkout — moves the key.
    let scopedMoved = foldScoped(
      lockPinnedSourceBinding(producerName, lockBindingB.lockedDep),
      scratch / "fetched" / siblingRevB / "src")
    check scopedMoved.monitored != scopedLockB.monitored
    # (7) a built-in action follows the monitored rule.
    check scopedDev.builtin != builtinOrig.weakFingerprint
    check scopedLockB.builtin == scopedDev.builtin
    check scopedMoved.builtin != scopedDev.builtin

    # Reset the shared sinks so no state leaks to other tests in the same binary.
    producerSourceBindings.clear()
    producerMaterializedAuxPaths.clear()
