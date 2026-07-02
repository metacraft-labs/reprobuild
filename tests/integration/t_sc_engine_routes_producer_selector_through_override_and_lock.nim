## Cross-Repo-Source-Consumption SC-1 — the engine "resolve package binding"
## hook routes a cross-repo PRODUCER selector through the develop-override map
## first, then the committed ``repro.lock`` ``LockedDep``.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.1 (call-site wiring) + §2 (the
## gap: ``resolvePackageWithOverrides`` / the M21 resolver contract never
## called outside a test; the engine has no "resolve package binding" hook).
## Milestone: ``Cross-Repo-Source-Consumption.milestones.org`` §SC-1.
##
## This test drives the SC-1 entry point ``resolveProducerBinding`` (defined in
## ``repro_cli_support``) directly, hermetically, against a tempdir consumer
## workspace root carrying a committed ``repro.lock`` + a
## ``.repro/develop-overrides.toml``:
##
##   1. **develop wins.** With a develop override registering producer
##      ``prod`` -> a sibling checkout that EXISTS on disk, the hook resolves to
##      ``pbkDevelopOverride`` with ``localPathAbsolute`` == the sibling
##      checkout (NOT the lock coordinates) and a non-empty ``contentIdentity``
##      (the fold input SC-4 consumes). This is the "resolvePackageWithOverrides
##      is called from the seam, not just a test" deliverable, exercised for a
##      cross-repo producer selector.
##   2. **lock-pinned fallthrough.** With the override REMOVED (no overrides
##      file), the SAME selector resolves to ``pbkLockPinned`` carrying the
##      committed ``LockedDep``'s VCS ``Coordinates`` (url + pinned revision) +
##      ``integrity`` — the mode-agnostic §5 fallthrough.
##   3. **host tool untouched.** A plain host tool selector (``gcc``) that is
##      neither overridden nor a ``LockedDep`` resolves to ``pbkNotProducer`` —
##      the "byte-identical for every non-producer ref" property (§4.1/§10),
##      asserted negatively: the SC-1 branch does NOT claim it.
##   4. **seam is wired, not test-only.** ``mkToolIdentityResolver`` built with
##      the consumer workspace root records the producer decision in the
##      observability sink ``lastResolvedProducerBinding`` when its closure
##      resolves a producer ref — proving the hook fires from the engine-facing
##      resolver closure, not merely from this test's direct call.
##
## Falsifiability (reproduced by the implementation agent): stubbing the hook to
## SKIP the override consultation (routing straight to the lock) makes assertion
## (1) resolve to ``pbkLockPinned`` instead of ``pbkDevelopOverride`` — the
## override's ``localPathAbsolute`` assertion then trips. Reverting restores
## green.
##
## Hermetic: the consumer workspace + the sibling checkout live in a fresh
## tempdir; nothing touches $HOME and no network / git is required.

import std/[options, os, unittest]

import repro_cli_support
import repro_lock
import repro_workspace_manifests
import repro_tool_profiles
import repro_build_engine

const
  producerName = "prod"
  siblingUrl = "https://vcs.invalid/prod.git"
  siblingRev = "0123456789abcdef0123456789abcdef01234567"
  siblingIntegrity = "git-sha1:0123456789abcdef0123456789abcdef01234567"

proc writeLock(workspaceRoot: string; withProducerDep: bool) =
  ## Write a valid v2 committed ``repro.lock`` at the workspace root. When
  ## ``withProducerDep`` is true the lock pins ``prod`` as a VCS ``LockedDep``
  ## (coordinates + integrity) so the lock-pinned fallthrough has something to
  ## resolve.
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("sc1-fixture"))
  if withProducerDep:
    ld.deps.add(LockedDep(
      name: producerName,
      path: "../prod",
      coordinates: Coordinates(kind: ckVcs, url: siblingUrl,
        gitRef: "main", revision: siblingRev),
      integrity: siblingIntegrity,
      visibility: "public"))
  writeFile(committedLockPath(workspaceRoot),
    serializeLockedDependencies(ld))

proc writeOverride(workspaceRoot, siblingCheckout: string) =
  ## Register a develop override mapping ``prod`` -> the sibling checkout via
  ## the M20 writer, so the resolver reads the exact on-disk shape the CLI
  ## ``repro develop`` command produces.
  let file = newDevelopOverrides().addOverride(DevelopOverrideEntry(
    package: producerName,
    local_path: siblingCheckout,
    state: "editable",
    created_at: "2026-07-01T00:00:00Z"))
  writeDevelopOverridesFile(workspaceRoot, file)

suite "SC-1: engine routes producer selector through override + lock":

  test "t_sc_engine_routes_producer_selector_through_override_and_lock":
    let scratch = getTempDir() / "sc1-" & $getCurrentProcessId()
    removeDir(scratch)
    createDir(scratch)
    defer: removeDir(scratch)

    # Consumer workspace root (absolute — required by the override resolver).
    let workspace = absolutePath(scratch / "consumer")
    createDir(workspace)

    # The sibling producer checkout the develop override points at. It only
    # needs to EXIST on disk for the override to resolve (SC-1 is the
    # resolution seam; SC-2 loads its repro.nim). Use an absolute path so the
    # resolved ``localPathAbsolute`` is deterministic.
    let siblingCheckout = absolutePath(scratch / "prod")
    createDir(siblingCheckout)
    writeFile(siblingCheckout / "repro.nim", "package prod:\n  discard\n")

    # ---- (1) develop mode wins: override -> localPathAbsolute. ----
    writeLock(workspace, withProducerDep = true)
    writeOverride(workspace, siblingCheckout)

    let devBinding = resolveProducerBinding(producerName, workspace)
    check devBinding.kind == pbkDevelopOverride
    check devBinding.selector == producerName
    # The override resolves to the sibling checkout, NOT the lock coordinates.
    check devBinding.localPathAbsolute == normalizedPath(siblingCheckout)
    # A non-empty content identity is what SC-4 folds into the consumer's
    # action fingerprint (the never-called ``foldOverridesIntoFingerprint``).
    check devBinding.contentIdentity.len > 0
    # The retained override binding is the ``rpbkOverride`` shape SC-4 feeds to
    # the fold without re-resolving.
    check devBinding.overrideBinding.kind == rpbkOverride

    # ---- (2) lock-pinned fallthrough: remove the override. ----
    removeFile(developOverridesPath(workspace))
    check not fileExists(developOverridesPath(workspace))

    let lockBinding = resolveProducerBinding(producerName, workspace)
    check lockBinding.kind == pbkLockPinned
    check lockBinding.selector == producerName
    check lockBinding.lockedDep.name == producerName
    check lockBinding.lockedDep.coordinates.kind == ckVcs
    check lockBinding.lockedDep.coordinates.url == siblingUrl
    check lockBinding.lockedDep.coordinates.revision == siblingRev
    check lockBinding.lockedDep.integrity == siblingIntegrity

    # ---- (3) host tool is untouched: not overridden, not a LockedDep. ----
    let hostBinding = resolveProducerBinding("gcc", workspace)
    check hostBinding.kind == pbkNotProducer
    check hostBinding.selector == "gcc"

    # A workspace that pins NO producer at all resolves every ref to
    # ``pbkNotProducer`` (the additive / byte-identical guarantee): rewrite the
    # lock with no deps and re-check the producer selector itself.
    writeLock(workspace, withProducerDep = false)
    let noProducer = resolveProducerBinding(producerName, workspace)
    check noProducer.kind == pbkNotProducer

    # ---- (4) the seam is wired into the engine-facing resolver closure, not
    # only reachable from this test's direct call. Build the resolver the way
    # the CLI build path does (with the consumer workspace root) and drive its
    # closure over the producer ref; the SC-1 branch must record the decision
    # in the observability sink. Re-arm the override so the closure resolves a
    # producer (develop mode), matching assertion (1).
    writeLock(workspace, withProducerDep = true)
    writeOverride(workspace, siblingCheckout)

    lastResolvedProducerBinding =
      ProducerBinding(selector: "", kind: pbkNotProducer)  # reset sink
    let resolver = mkToolIdentityResolver(
      PathOnlyBuildIdentity(projectName: "consumer"), workspace)
    # The closure returns ``none`` for materialization (SC-2 lands the bin dir
    # splice); SC-1's contract is that it ROUTED the ref through the hook.
    let materialized = resolver(producerName, dkBuild)
    check materialized.isNone
    check lastResolvedProducerBinding.kind == pbkDevelopOverride
    check lastResolvedProducerBinding.selector == producerName
    check lastResolvedProducerBinding.localPathAbsolute ==
      normalizedPath(siblingCheckout)

    # And a plain host ref through the SAME closure does NOT get claimed as a
    # producer (the sink is unchanged from the prior producer resolution).
    lastResolvedProducerBinding =
      ProducerBinding(selector: "sentinel", kind: pbkNotProducer)
    let hostMaterialized = resolver("gcc", dkBuild)
    check hostMaterialized.isNone
    check lastResolvedProducerBinding.selector == "sentinel"  # untouched
