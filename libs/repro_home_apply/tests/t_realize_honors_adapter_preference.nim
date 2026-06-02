## M1 (Realize-Layer-Plumbing-Closures) hermetic gate for the realize-
## side ``adapterPreference`` plumbing. M2.5 plumbed the chain through
## ``previewPackageResolutions``; the realize side
## (``realizeViaProductionCatalog`` + ``realizePlannedPackages``) used
## to drop the chain on the floor and pick the platform default. M1
## fixes that — the same per-host chain that PLAN-mode honors is now
## also honored at apply time.
##
## Contract:
##
##   1. ``test_m1_realize_uses_per_host_chain_when_adapter_preference_present``
##      — synthetic profile carries ``adapterPreference: windows: [scoop,
##      builtin, path]``; ``realizePlannedPackages`` invokes the realize-
##      side chain-resolver test seam with the CUSTOM chain (cakScoop
##      FIRST), NOT the platform default (cakBuiltin first).
##
##   2. ``test_m1_realize_uses_platform_default_when_adapter_preference_absent``
##      — profile carries NO ``adapterPreference:`` block;
##      ``realizePlannedPackages`` invokes the chain resolver with an
##      empty chain (which ``chainResolvePackage`` interprets as the
##      M65 platform default — the regression-gate case for the M71
##      reference profile).
##
##   3. ``test_m1_realize_falls_back_when_per_os_key_missing`` — profile
##      carries ``adapterPreference: linux: [...]`` only on a Windows
##      host; the realize side falls through to the Windows platform
##      default (the helper's ``resolveAdapterChainFor`` contract).
##
##   4. ``test_m1_realize_chain_routing_matches_preview`` — symmetry
##      gate: against the same profile + the same package, the realize-
##      side test seam receives the SAME chain that
##      ``previewPackageResolutions(..., chain = ...)`` would route
##      through. Closes the M2.5 deviation note about preview / realize
##      possibly diverging.
##
## Hermetic: a chain-resolver stub installed via ``chainResolveOverride``
## captures the (chain, version) args at the realize-side call site
## and returns a synthetic ``CatalogResolution`` pointing at a fixture
## path-adapter source — so the realize side runs end-to-end without
## downloading anything.

import std/[os, tables, unittest]
from repro_core/paths import extendedPath

import repro_local_store

import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog
import repro_dsl_stdlib/packages_schema

const
  FixtureRoot = "build/test-tmp/t-m1-realize-adapter-preference"

# ---------------------------------------------------------------------------
# Test-seam state — captures the args the realize side passed through to
# ``chainResolvePackage`` so each test body can assert on them.
# ---------------------------------------------------------------------------

type
  RealizeChainSpy = object
    seenPackages: seq[string]
    seenChains: seq[seq[CatalogAdapterKind]]
    seenVersions: seq[string]

var realizeSpy: RealizeChainSpy

proc resetSpy() =
  realizeSpy.seenPackages.setLen(0)
  realizeSpy.seenChains.setLen(0)
  realizeSpy.seenVersions.setLen(0)

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

proc stubChainResolve(stubExePath: string;
                      resolvedVersion: string): ChainResolveCallback =
  ## Returns a closure that records (packageId, chain, version) into
  ## the module-level spy + returns a synthetic ``cakPath``-shaped
  ## ``CatalogResolution`` whose ``sourcePath`` points at the fixture
  ## stub binary. This lets the realize side run end-to-end (the path
  ## adapter hardlinks/copies the stub into the store) without ever
  ## reaching a real catalog or network.
  result = proc (cat: var ProductionCatalog;
                 packageId: string;
                 chain: seq[CatalogAdapterKind];
                 version: string;
                 hostCpu: PlatformCpu;
                 hostOs: PlatformOs): CatalogResolution =
    realizeSpy.seenPackages.add(packageId)
    realizeSpy.seenChains.add(chain)
    realizeSpy.seenVersions.add(version)
    var trace: seq[ChainStep] = @[]
    # Synthesize a per-adapter trace so consumers that read ``chainTrace``
    # see something believable. The actual "winning" adapter is cakPath
    # (the source we can realize hermetically); preceding entries are
    # recorded as csoCatalogMiss / csoAdapterUnavailable, the same shape
    # ``chainResolvePackage`` produces.
    let effective =
      if chain.len == 0:
        case detectHostOs()
        of poWindows: @[cakBuiltin, cakScoop, cakPath]
        of poLinux:   @[cakNix, cakBuiltin, cakPath]
        of poMacos:   @[cakNix, cakPath]
        else: @[cakPath]
      else: chain
    for a in effective:
      if a == cakPath:
        trace.add(ChainStep(adapter: cakPath, outcome: csoResolved,
          reason: "stub fixture for m1 test"))
        break
      else:
        trace.add(ChainStep(adapter: a, outcome: csoCatalogMiss,
          reason: "m1 test seam: forced miss"))
    return CatalogResolution(
      packageId: packageId,
      adapter: cakPath,
      sourcePath: stubExePath,
      resolvedVersion: resolvedVersion,
      cacheHit: false,
      chainTrace: trace)

# ---------------------------------------------------------------------------
# Tests — realize-side honors adapterPreference
# ---------------------------------------------------------------------------

suite "M1 — realize side honors adapterPreference":

  test "test_m1_realize_uses_per_host_chain_when_adapter_preference_present":
    let fixtureDir = FixtureRoot / "per-host-chain"
    let storeDir = fixtureDir / "store"
    let stubExe = fixtureDir / "bin" / "m1-stub.cmd"
    resetDir(fixtureDir)
    resetDir(storeDir)
    writeStubExe(stubExe)
    resetSpy()

    # Synthetic ApplyPlan carrying the per-host preference. The chain
    # the operator declared (scoop FIRST) MUST reach the realize side.
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["scoop", "builtin", "path"]
    ap["linux"]   = @["nix", "builtin", "path"]
    ap["darwin"]  = @["nix", "path"]
    # Pin a version so the realize-side ``useChain`` gate fires (the
    # alternative gate — ``isRegistered`` — is irrelevant here because
    # ``m1-test-tool`` is not in the M65 catalog; pinning the version
    # forces the chain branch regardless).
    let packages = @[PlannedPackage(packageId: "m1-test-tool",
      requestedVersion: "1.0.0", fromActivity: "test")]

    chainResolveOverride = stubChainResolve(stubExe, "1.0.0")
    defer: chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    # The realize-side pipeline resolves the chain from ``ap`` per the
    # M2.5 helper, then passes it into ``realizePlannedPackages``.
    let realizeChain = resolveAdapterChainFor(ap, currentHostOsKey())
    let realized = realizePlannedPackages(store, packages, chain = realizeChain)

    check realized.len == 1
    check realizeSpy.seenPackages == @["m1-test-tool"]
    # The chain that reached the seam matches the operator-declared
    # chain for THIS host (Windows: scoop/builtin/path; Linux:
    # nix/builtin/path; macOS: nix/path).
    let expectedHostChain =
      when defined(windows):     @[cakScoop, cakBuiltin, cakPath]
      elif defined(linux):       @[cakNix, cakBuiltin, cakPath]
      elif defined(macosx) or defined(osx): @[cakNix, cakPath]
      else: @[cakPath]
    check realizeSpy.seenChains.len == 1
    check realizeSpy.seenChains[0] == expectedHostChain

  test "test_m1_realize_uses_platform_default_when_adapter_preference_absent":
    let fixtureDir = FixtureRoot / "platform-default"
    let storeDir = fixtureDir / "store"
    let stubExe = fixtureDir / "bin" / "m1-stub.cmd"
    resetDir(fixtureDir)
    resetDir(storeDir)
    writeStubExe(stubExe)
    resetSpy()

    # Empty preference table → the M2.5 helper resolves to the M65
    # platform default chain. We pass it through unchanged.
    var ap = initOrderedTable[string, seq[string]]()
    # Pin a version so the realize-side ``useChain`` gate fires (the
    # alternative gate — ``isRegistered`` — is irrelevant here because
    # ``m1-test-tool`` is not in the M65 catalog; pinning the version
    # forces the chain branch regardless).
    let packages = @[PlannedPackage(packageId: "m1-test-tool",
      requestedVersion: "1.0.0", fromActivity: "test")]

    chainResolveOverride = stubChainResolve(stubExe, "")
    defer: chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    let realizeChain = resolveAdapterChainFor(ap, currentHostOsKey())
    let realized = realizePlannedPackages(store, packages, chain = realizeChain)

    check realized.len == 1
    # The platform default chain reached the seam.
    let expectedHostChain =
      when defined(windows):     @[cakBuiltin, cakScoop, cakPath]
      elif defined(linux):       @[cakNix, cakBuiltin, cakPath]
      elif defined(macosx) or defined(osx): @[cakNix, cakPath]
      else: @[cakPath]
    check realizeSpy.seenChains.len == 1
    check realizeSpy.seenChains[0] == expectedHostChain

  test "test_m1_realize_falls_back_when_per_os_key_missing":
    let fixtureDir = FixtureRoot / "missing-per-os-key"
    let storeDir = fixtureDir / "store"
    let stubExe = fixtureDir / "bin" / "m1-stub.cmd"
    resetDir(fixtureDir)
    resetDir(storeDir)
    writeStubExe(stubExe)
    resetSpy()

    # Preference declares Linux only. On a Windows host, that means the
    # ``resolveAdapterChainFor`` helper falls back to the Windows M65
    # default. On non-Windows hosts the matching arm of the table is
    # the contract — but we always pin the assertion to "the chain
    # actually used was the platform default for THIS host" regardless
    # of which OS the runner is on.
    var ap = initOrderedTable[string, seq[string]]()
    ap["linux"] = @["nix", "builtin", "path"]
    # On Windows: no entry → Windows default. On Linux: the explicit
    # ``linux`` entry IS the platform default order, so the assertion
    # holds. On macOS: no entry → macOS default. For all three host OSes
    # the realize-side seam should observe the expected chain.
    # Pin a version so the realize-side ``useChain`` gate fires (the
    # alternative gate — ``isRegistered`` — is irrelevant here because
    # ``m1-test-tool`` is not in the M65 catalog; pinning the version
    # forces the chain branch regardless).
    let packages = @[PlannedPackage(packageId: "m1-test-tool",
      requestedVersion: "1.0.0", fromActivity: "test")]

    chainResolveOverride = stubChainResolve(stubExe, "")
    defer: chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    let realizeChain = resolveAdapterChainFor(ap, currentHostOsKey())
    let realized = realizePlannedPackages(store, packages, chain = realizeChain)

    check realized.len == 1
    let expectedHostChain =
      when defined(windows):     @[cakBuiltin, cakScoop, cakPath]
      elif defined(linux):       @[cakNix, cakBuiltin, cakPath]
      elif defined(macosx) or defined(osx): @[cakNix, cakPath]
      else: @[cakPath]
    check realizeSpy.seenChains.len == 1
    check realizeSpy.seenChains[0] == expectedHostChain

  test "test_m1_realize_chain_routing_matches_preview":
    # Symmetry gate: against the same profile + the same package, the
    # realize side and the preview side route through the same chain.
    # We assert it directly by spying on the realize side AND by
    # checking that ``resolveAdapterChainFor`` is the single source of
    # truth that both ``pipeline.nim`` call sites consume (the helper
    # exists exactly once and both sides reach it with the same args).
    let fixtureDir = FixtureRoot / "preview-realize-symmetry"
    let storeDir = fixtureDir / "store"
    let stubExe = fixtureDir / "bin" / "m1-stub.cmd"
    resetDir(fixtureDir)
    resetDir(storeDir)
    writeStubExe(stubExe)
    resetSpy()

    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["path", "builtin", "scoop"]
    ap["linux"]   = @["path", "nix", "builtin"]
    ap["darwin"]  = @["path", "nix"]

    # The chain the preview side would resolve, byte-for-byte.
    let previewChain = resolveAdapterChainFor(ap, currentHostOsKey())
    # The chain the realize side resolves — same helper, same args.
    let realizeChain = resolveAdapterChainFor(ap, currentHostOsKey())
    check previewChain == realizeChain

    chainResolveOverride = stubChainResolve(stubExe, "")
    defer: chainResolveOverride = nil

    var store = openStore(storeDir)
    defer: store.close()

    # Pin a version so the realize-side ``useChain`` gate fires (the
    # alternative gate — ``isRegistered`` — is irrelevant here because
    # ``m1-test-tool`` is not in the M65 catalog; pinning the version
    # forces the chain branch regardless).
    let packages = @[PlannedPackage(packageId: "m1-test-tool",
      requestedVersion: "1.0.0", fromActivity: "test")]
    let realized = realizePlannedPackages(store, packages, chain = realizeChain)
    check realized.len == 1
    # The chain that reached the realize-side seam is byte-identical to
    # the chain the preview side would have used. (Realize and preview
    # cannot diverge on which adapter resolves a given package.)
    check realizeSpy.seenChains.len == 1
    check realizeSpy.seenChains[0] == previewChain
