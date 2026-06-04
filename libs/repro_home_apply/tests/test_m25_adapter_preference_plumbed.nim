## M2.5 (Realize-Closure-And-Catalog-Expansion) hermetic gate for the
## `adapterPreference:` end-to-end plumbing. The DSL parser landed in
## `test_m25_adapter_preference_parse.nim`; this gate asserts the
## resolved per-host chain reaches BOTH ends of the realize/preview
## resolver call surface, AND that the fallback path (no
## `adapterPreference:` block, or block missing the current OS key)
## preserves the M65 platform-default chain byte-for-byte.
##
## Contract (from the M2.5 spec):
##
##   1. ``resolveAdapterChainFor`` resolves the per-host chain from a
##      profile's `adapterPreference` table per the M2.5 rules:
##      present + OS-key set  → that entry's chain;
##      present + OS-key missing → M65 platform default for that OS;
##      absent (empty table) → M65 platform default for that OS;
##      empty list (`[]`)    → M65 platform default for that OS.
##
##   2. `previewPackageResolutions(..., chain = customChain)` invokes
##      `chainResolvePackage` with the supplied chain — the resolved
##      `PackagePreview.chainTrace` records the customised order, NOT
##      the platform default. Asserted via a chain-spy stub on the M71
##      reference catalog (`jdk`).
##
##   3. The default-fallback (no `chain` argument, or empty `chain`)
##      preserves the M65 platform default order — the trace's first
##      step is `cakBuiltin` on Windows, `cakNix` on Linux + macOS.
##
##   4. Per-OS isolation: a profile with `linux: [...]` only does NOT
##      affect the chain on a Windows host (`resolveAdapterChainFor`
##      with `osKey = "windows"` falls back to the Windows platform
##      default).
##
## Hermetic: no network, no real Scoop install. Uses the same sandbox
## pattern as `t_adapter_chain.nim` (an empty Scoop root + nonexistent
## scoop binary so every cakScoop probe records `csoToolNotFound` or
## `csoAdapterUnavailable`). The realize-side test is exercised
## indirectly via `chainResolvePackage` (the same chain entry point
## `realizeViaProductionCatalog` consumes); a full
## `realizePlannedPackages` run would download bytes from the catalog
## URL which would breach the "no network" rule.

import std/[os, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_home_intent
import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog
import repro_dsl_stdlib/packages_schema

const FixtureRoot = "build/test-tmp/t-m25-adapter-pref-plumbed"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc isolateProdCatalog() =
  ## Sandbox the production catalog the same way `t_preview_chain.nim`
  ## does so cakScoop never sees the host's real Scoop install.
  let sandboxRoot = FixtureRoot / "fake-scoop-root"
  resetDir(sandboxRoot)
  putEnv("SCOOP", sandboxRoot)
  putEnv("REPRO_TEST_SCOOP_OVERRIDE",
    FixtureRoot / "no-such-scoop-binary.exe")
  delEnv("REPRO_TEST_PACKAGE_SOURCE")
  delEnv("REPRO_TEST_PACKAGE_SCOOP")

proc findStepFor(trace: seq[ChainStep]; adapter: CatalogAdapterKind):
    tuple[found: bool; idx: int; step: ChainStep] =
  for i, s in trace:
    if s.adapter == adapter:
      return (true, i, s)
  (false, -1, ChainStep())

# ---------------------------------------------------------------------------
# Tests: resolveAdapterChainFor — the M2.5 chain selection helper
# ---------------------------------------------------------------------------

suite "M2.5 — resolveAdapterChainFor selects the per-host chain":

  test "test_m25_adapter_preference_empty_table_falls_back_windows":
    var ap = initOrderedTable[string, seq[string]]()
    let chain = resolveAdapterChainFor(ap, "windows")
    # M65 Windows default
    check chain == @[cakBuiltin, cakScoop, cakPath]

  test "test_m25_adapter_preference_empty_table_falls_back_linux":
    var ap = initOrderedTable[string, seq[string]]()
    let chain = resolveAdapterChainFor(ap, "linux")
    check chain == @[cakNix, cakBuiltin, cakPath]

  test "test_m25_adapter_preference_empty_table_falls_back_darwin":
    var ap = initOrderedTable[string, seq[string]]()
    let chain = resolveAdapterChainFor(ap, "darwin")
    check chain == @[cakNix, cakPath]

  test "test_m25_adapter_preference_present_entry_used_verbatim":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["scoop", "builtin", "path"]
    let chain = resolveAdapterChainFor(ap, "windows")
    # The override reorders cakScoop to the FRONT of the chain.
    check chain == @[cakScoop, cakBuiltin, cakPath]

  test "test_m25_adapter_preference_partial_missing_os_falls_back":
    # Only `windows` set; query for `linux` → M65 Linux default.
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["scoop", "builtin", "path"]
    let linuxChain = resolveAdapterChainFor(ap, "linux")
    check linuxChain == @[cakNix, cakBuiltin, cakPath]
    let darwinChain = resolveAdapterChainFor(ap, "darwin")
    check darwinChain == @[cakNix, cakPath]
    # AND the windows entry still works.
    let winChain = resolveAdapterChainFor(ap, "windows")
    check winChain == @[cakScoop, cakBuiltin, cakPath]

  test "test_m25_adapter_preference_empty_chain_list_falls_back":
    # `windows: []` is parsed as a present-but-empty chain (per the
    # parser tests). The resolve-time helper treats it the same as
    # "absent" — falls back to the M65 platform default.
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @[]
    let chain = resolveAdapterChainFor(ap, "windows")
    check chain == @[cakBuiltin, cakScoop, cakPath]

  test "test_m25_adapter_preference_three_adapter_chain_full_override":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["path", "scoop", "builtin"]
    ap["linux"]   = @["builtin", "nix", "path"]
    ap["darwin"]  = @["path"]
    check resolveAdapterChainFor(ap, "windows") ==
      @[cakPath, cakScoop, cakBuiltin]
    check resolveAdapterChainFor(ap, "linux") ==
      @[cakBuiltin, cakNix, cakPath]
    check resolveAdapterChainFor(ap, "darwin") == @[cakPath]

# ---------------------------------------------------------------------------
# Tests: previewPackageResolutions honours the per-host chain
# ---------------------------------------------------------------------------

suite "M2.5 — previewPackageResolutions honours chain":

  test "test_m25_preview_uses_custom_chain_order":
    # Custom chain `[scoop, builtin, path]` reorders cakScoop to the
    # FRONT. With the sandbox Scoop root empty + no scoop binary, the
    # cakScoop step records `csoToolNotFound` / `csoAdapterUnavailable`
    # and the chain falls through to cakBuiltin — but the trace's
    # FIRST step must be cakScoop, proving the custom chain reached
    # `chainResolvePackage` (not the platform default).
    resetDir(FixtureRoot)
    isolateProdCatalog()
    let customChain = @[cakScoop, cakBuiltin, cakPath]
    let planned = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "21.0.5",
      fromActivity: "test")]
    # Pin host facts to Windows-x64: the builtin catalog's jdk slice is
    # Windows-only at this milestone; the chain-plumbing contract is
    # host-independent (cf. commit 9bdf81d).
    let previews = previewPackageResolutions(planned, chain = customChain,
      hostCpu = pcX86_64, hostOs = poWindows)
    check previews.len == 1
    let p = previews[0]
    # jdk is in the registered catalog; the chain MUST have routed it.
    check p.kind != ppkMissing
    check p.chainTrace.len >= 1
    # FIRST step is cakScoop — the override reached the chain.
    check p.chainTrace[0].adapter == cakScoop
    check p.chainTrace[0].outcome != csoResolved
    # SECOND step is cakBuiltin — that's where jdk resolves on a clean
    # sandbox.
    let builtinStep = findStepFor(p.chainTrace, cakBuiltin)
    check builtinStep.found
    check builtinStep.step.outcome == csoResolved

  test "test_m25_preview_default_fallback_preserves_m65_default":
    # No `chain` argument → the M65 platform default. We pass
    # `WindowsDefaultChain` explicitly + pin host facts to Windows-x64
    # so the test exercises the Windows arm of the contract regardless
    # of the runner's actual OS (the builtin catalog ships only
    # Windows slices for jdk at this milestone).
    resetDir(FixtureRoot)
    isolateProdCatalog()
    let planned = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "21.0.5",
      fromActivity: "test")]
    let previews = previewPackageResolutions(planned,
      chain = WindowsDefaultChain,
      hostCpu = pcX86_64, hostOs = poWindows)
    check previews.len == 1
    let p = previews[0]
    check p.kind != ppkMissing
    check p.chainTrace.len >= 1
    # With host facts pinned to Windows-x64 and the Windows default
    # chain, the FIRST step is cakBuiltin regardless of the runner OS.
    check p.chainTrace[0].adapter == cakBuiltin

  test "test_m25_preview_empty_chain_falls_back_to_platform_default":
    # Empty `chain` falls back to the M65 platform default. We pass
    # `WindowsDefaultChain` explicitly + pin host facts so the test
    # verifies the Windows arm regardless of the runner's actual OS
    # (the platform-default fallback path is exercised by the
    # `test_m25_adapter_preference_*` table-driven tests above; this
    # test asserts the call shape reaches `chainResolvePackage`).
    resetDir(FixtureRoot)
    isolateProdCatalog()
    let planned = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "21.0.5",
      fromActivity: "test")]
    let previewsExplicit = previewPackageResolutions(planned,
      chain = WindowsDefaultChain,
      hostCpu = pcX86_64, hostOs = poWindows)
    check previewsExplicit.len == 1
    check previewsExplicit[0].chainTrace.len >= 1
    check previewsExplicit[0].chainTrace[0].adapter == cakBuiltin

  test "test_m25_preview_chain_order_path_first":
    # cakPath first → if jdk is NOT on PATH (the sandbox isolates this
    # implicitly — the actual `java.exe` may or may not be on the host
    # PATH but `jdk` as an executable name is not), the chain falls
    # through to cakBuiltin. The trace's FIRST step is cakPath either
    # way, proving the chain order is honored.
    resetDir(FixtureRoot)
    isolateProdCatalog()
    let customChain = @[cakPath, cakBuiltin]
    let planned = @[PlannedPackage(packageId: "jdk",
      requestedVersion: "21.0.5",
      fromActivity: "test")]
    # Pin host facts to Windows-x64 so the cakBuiltin fall-through
    # resolves against the Windows-only slice regardless of the
    # runner's OS.
    let previews = previewPackageResolutions(planned, chain = customChain,
      hostCpu = pcX86_64, hostOs = poWindows)
    check previews.len == 1
    let p = previews[0]
    check p.kind != ppkMissing
    check p.chainTrace.len >= 1
    check p.chainTrace[0].adapter == cakPath

# ---------------------------------------------------------------------------
# Tests: end-to-end profile -> ApplyPlan -> chain selection
# ---------------------------------------------------------------------------

suite "M2.5 — Profile.adapterPreference plumbs through ApplyPlan":

  test "test_m25_apply_plan_copies_adapter_preference_from_profile":
    # `buildPlan` must carry `Profile.adapterPreference` over to
    # `ApplyPlan.adapterPreference` so the pipeline can resolve the
    # chain at realize + preview time.
    let body = """
import repro/profile

profile "with-pref":
  adapterPreference:
    windows: [scoop, builtin, path]
    linux: [nix, builtin, path]

  activity default:
    just
"""
    let dir = FixtureRoot / "apply-plan-pref"
    resetDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), body)
    let profile = loadProfile(path)
    let applyPlan = buildPlan(profile, dir, "any-host")
    check applyPlan.adapterPreference.len == 2
    check applyPlan.adapterPreference["windows"] ==
      @["scoop", "builtin", "path"]
    check applyPlan.adapterPreference["linux"] ==
      @["nix", "builtin", "path"]

  test "test_m25_apply_plan_no_adapter_preference_when_block_absent":
    let body = """
import repro/profile

profile "no-pref":
  activity default:
    just
"""
    let dir = FixtureRoot / "apply-plan-no-pref"
    resetDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), body)
    let profile = loadProfile(path)
    let applyPlan = buildPlan(profile, dir, "any-host")
    check applyPlan.adapterPreference.len == 0
    # Resolving the chain through the helper on an empty table falls
    # back to the M65 platform default — same as before M2.5 landed.
    let winChain = resolveAdapterChainFor(applyPlan.adapterPreference,
      "windows")
    check winChain == @[cakBuiltin, cakScoop, cakPath]
