## M1 (Realize-Layer-Plumbing-Closures) hermetic gate for the realize-
## side ``requestedVersion`` plumbing. Pre-M1 ``realizePlannedPackages``
## dropped ``PlannedPackage.requestedVersion`` on the floor when
## invoking ``realizeViaProductionCatalog`` — only the ``chain``
## parameter was threaded (M2.5 of the predecessor campaign). The M2.5
## review explicitly called this out as a "pre-existing M69-shaped bug
## NOT introduced by M2.5". M1 fixes it: the realize side now threads
## the pinned version through to ``chainResolvePackage`` so
## ``package(jdk, "21.0.5")`` resolves the pinned slice rather than
## silently falling back to the catalog HEAD.
##
## Contract:
##
##   1. ``test_m1_realize_threads_requested_version_to_chain_resolve``
##      — pinned ``package(jdk, "21.0.5")``; the chain-resolver test
##      seam records ``version == "21.0.5"`` (NOT the empty string).
##
##   2. ``test_m1_realize_unversioned_package_resolves_default`` —
##      bare ``package(jdk)``; the chain-resolver test seam records
##      ``version == ""`` and the synthetic resolution picks the
##      catalog default. Regression-gate for the unpinned-package
##      case the M71 reference profile relies on.
##
##   3. ``test_m1_realize_unknown_version_fails_closed`` —
##      ``package(jdk, "9.9.9-nonexistent")``; the realize side fails
##      closed with a structured ``EApplyRealizeFailed`` wrapping
##      ``EVersionNotInCatalog`` (the pre-validate path fires before
##      the chain runs, per M69's contract).
##
## Hermetic: a chain-resolver stub installed via ``chainResolveOverride``
## captures the version arg + returns a synthetic ``cakPath``-shaped
## resolution. The unknown-version test does NOT install the stub —
## it lets the production ``lookupCatalogSlice`` raise
## ``EVersionNotInCatalog`` against the real M65 jdk slice list (a
## READ operation; no network).

import std/[os, unittest]
from repro_core/paths import extendedPath

import repro_local_store

import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog
import repro_home_apply/errors
import repro_dsl_stdlib/packages_schema

const
  FixtureRoot = "build/test-tmp/t-m1-realize-requested-version"

# ---------------------------------------------------------------------------
# Shared spy + stub plumbing (mirrors t_realize_honors_adapter_preference)
# ---------------------------------------------------------------------------

var seenVersions: seq[string] = @[]
var seenPackages: seq[string] = @[]

proc resetSpy() =
  seenVersions.setLen(0)
  seenPackages.setLen(0)

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc writeStubExe(path: string) =
  createDir(extendedPath(parentDir(path)))
  let body =
    when defined(windows): "@echo m1-stub\n"
    else: "#!/bin/sh\necho m1-stub\n"
  writeFile(extendedPath(path), body)

proc stubChainResolve(stubExePath: string): ChainResolveCallback =
  result = proc (cat: var ProductionCatalog;
                 packageId: string;
                 chain: seq[CatalogAdapterKind];
                 version: string;
                 hostCpu: PlatformCpu;
                 hostOs: PlatformOs): CatalogResolution =
    seenPackages.add(packageId)
    seenVersions.add(version)
    var trace: seq[ChainStep] = @[
      ChainStep(adapter: cakPath, outcome: csoResolved,
        reason: "stub fixture for m1 test")
    ]
    return CatalogResolution(
      packageId: packageId,
      adapter: cakPath,
      sourcePath: stubExePath,
      resolvedVersion: version,
      cacheHit: false,
      chainTrace: trace)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M1 — realize side threads requestedVersion to chainResolvePackage":

  test "test_m1_realize_threads_requested_version_to_chain_resolve":
    let fixtureDir = FixtureRoot / "explicit-pin"
    let storeDir = fixtureDir / "store"
    let stubExe = fixtureDir / "bin" / "m1-stub.cmd"
    resetDir(fixtureDir)
    resetDir(storeDir)
    writeStubExe(stubExe)
    resetSpy()

    chainResolveOverride = stubChainResolve(stubExe)
    defer: chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    # Use a registered tool (so the useChain gate fires) with an explicit
    # version pin. We use "jdk" — present in the M65 registry per the M71
    # reference profile.
    let packages = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "21.0.5", fromActivity: "test")]
    let realized = realizePlannedPackages(store, packages)

    check realized.len == 1
    # The version pin reached the chain resolver — not "".
    check seenPackages == @["jdk"]
    check seenVersions.len == 1
    check seenVersions[0] == "21.0.5"

  test "test_m1_realize_unversioned_package_resolves_default":
    let fixtureDir = FixtureRoot / "unpinned"
    let storeDir = fixtureDir / "store"
    let stubExe = fixtureDir / "bin" / "m1-stub.cmd"
    resetDir(fixtureDir)
    resetDir(storeDir)
    writeStubExe(stubExe)
    resetSpy()

    chainResolveOverride = stubChainResolve(stubExe)
    defer: chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    # Bare package() — no version. The realize side passes
    # ``requestedVersion = ""`` through (the chain resolver then
    # resolves the catalog default at its own layer).
    let packages = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "", fromActivity: "test")]
    let realized = realizePlannedPackages(store, packages)

    check realized.len == 1
    # The empty version reached the chain resolver — proving the
    # threading is symmetric in BOTH directions (versioned AND
    # unversioned, not just versioned).
    check seenPackages == @["jdk"]
    check seenVersions.len == 1
    check seenVersions[0] == ""

  test "test_m1_realize_unknown_version_fails_closed":
    let fixtureDir = FixtureRoot / "unknown-version"
    let storeDir = fixtureDir / "store"
    resetDir(fixtureDir)
    resetDir(storeDir)
    resetSpy()

    # We do NOT install the chain-resolver override here — we WANT the
    # pre-validate path (``lookupCatalogSlice``) to fire against the
    # real M65 catalog (a READ; no network). It must raise
    # ``EVersionNotInCatalog`` for a clearly-bogus pin, which the
    # realize-side dispatcher converts into ``EApplyRealizeFailed``.
    chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    let packages = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "9.9.9-nonexistent", fromActivity: "test")]
    expect EApplyRealizeFailed:
      discard realizePlannedPackages(store, packages)
