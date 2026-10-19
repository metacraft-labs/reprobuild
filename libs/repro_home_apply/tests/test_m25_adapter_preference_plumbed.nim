## M2.5 (Realize-Closure-And-Catalog-Expansion) → GM4b hermetic gate for the
## `adapterPreference:` end-to-end plumbing. The DSL parser is covered by
## `test_m25_adapter_preference_parse.nim`; this gate asserts the block —
## since GM4b the profile's SELECTION POLICY (Provisioning-Contributions.md
## §"Selection policy") — reaches the resolver the preview and the realize
## step share, and that the fallback is the single default policy.
##
## Contract, restated for GM4b:
##
##   1. ``selectionPolicyFor`` maps a profile's `adapterPreference` table to
##      the policy for a target OS: present + OS key set → that entry
##      (`builtin` read as `tarball`); OS key missing, table empty, or entry
##      `[]` → `DefaultSelectionPolicy`, which is the SAME on every OS (the
##      per-platform default chains are gone).
##   2. `previewPackageResolutions(…, ctx)` walks the context's policy in
##      order: the preview's `steps` record the customised order.
##   3. The default policy (no block) walks tarball first on every target.
##   4. Per-OS isolation: a `linux:` entry does not affect a Windows target.
##   5. `buildPlan` copies `Profile.adapterPreference` into the `ApplyPlan`.
##
## Hermetic: the preview cases resolve for an x86_64-windows target that is
## NOT this machine, so the host's PATH and Scoop are never consulted, and
## selection reads static metadata only (no network). No mocks.

import std/[os, strutils, tables, unittest]
from repro_core/paths import extendedPath
from repro_test_support import testCaseScratchSlug

import repro_home_intent
import repro_home_apply/plan
import repro_home_apply/realize
import repro_home_apply/package_catalog

# Per-case private scratch — the cases of one binary run as CONCURRENT
# PROCESSES (``<binary> --run "<suite>::<case>"``, one process each), so a
# fixed path here is shared mutable state between them. The concrete hazard
# in this file: four cases call ``resetDir(FixtureRoot)``, which RECURSIVELY
# deletes the whole tree, while ``test_m25_apply_plan_*`` write
# ``FixtureRoot/apply-plan-*/home.nim`` and then read it back through
# ``loadProfile``. A reset landing inside that write-then-read span removes
# the profile the other case is about to load. Same treatment its sibling
# ``t_adapter_chain`` already carries.
#
# UNLIKE the other three files fixed alongside this one, this hazard was NOT
# reproduced: 65 runs of this binary under the per-case runner (40 at
# ``--threads=12``, 25 more at ``--threads=16`` under 32 CPU spinners) came
# back clean, because the vulnerable span is a few milliseconds wide. The
# change is therefore prophylactic — justified by the structure above, not by
# a red run.
let FixtureRoot = "build/test-tmp/t-m25-adapter-pref-plumbed-" &
  testCaseScratchSlug()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc isolateProdCatalog() =
  ## Sandbox the production catalog the same way `t_preview_chain.nim`
  ## does so no Scoop probe ever sees the host's real Scoop install.
  let sandboxRoot = FixtureRoot / "fake-scoop-root"
  resetDir(sandboxRoot)
  putEnv("SCOOP", sandboxRoot)
  putEnv("REPRO_TEST_SCOOP_OVERRIDE",
    FixtureRoot / "no-such-scoop-binary.exe")
  delEnv("REPRO_TEST_PACKAGE_SOURCE")
  delEnv("REPRO_TEST_PACKAGE_SCOOP")

proc windowsContext(ap: OrderedTable[string, seq[string]]):
    ProfileResolutionContext =
  profileResolutionContext(ap, "windows", "x86_64", isHost = false)

proc jdkPreview(ap: OrderedTable[string, seq[string]]): PackagePreview =
  resetDir(FixtureRoot)
  isolateProdCatalog()
  let planned = @[PlannedPackage(packageId: "jdk",
    requestedVersion: "21.0.5", fromActivity: "test")]
  let previews = previewPackageResolutions(planned, windowsContext(ap))
  check previews.len == 1
  previews[0]

# ---------------------------------------------------------------------------
# Tests: selectionPolicyFor — adapterPreference → selection policy
# ---------------------------------------------------------------------------

suite "M2.5/GM4b — selectionPolicyFor selects the per-OS policy":

  test "test_m25_adapter_preference_empty_table_falls_back_windows":
    let p = selectionPolicyFor(initOrderedTable[string, seq[string]](),
      poWindows)
    check p.policy == DefaultSelectionPolicy
    check p.source == "default"

  test "test_m25_adapter_preference_empty_table_falls_back_linux":
    let p = selectionPolicyFor(initOrderedTable[string, seq[string]](),
      poLinux)
    check p.policy == DefaultSelectionPolicy

  test "test_m25_adapter_preference_empty_table_falls_back_darwin":
    let p = selectionPolicyFor(initOrderedTable[string, seq[string]](),
      poMacos)
    check p.policy == DefaultSelectionPolicy

  test "test_m25_adapter_preference_present_entry_used_verbatim":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["scoop", "builtin", "path"]
    let p = selectionPolicyFor(ap, poWindows)
    # `builtin` is the former spelling of `tarball`.
    check p.policy == @[rkScoop, rkTarball, rkPath]
    check p.source == "adapterPreference.windows"

  test "test_m25_adapter_preference_partial_missing_os_falls_back":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["scoop", "builtin", "path"]
    check selectionPolicyFor(ap, poLinux).policy == DefaultSelectionPolicy
    check selectionPolicyFor(ap, poMacos).policy == DefaultSelectionPolicy
    check selectionPolicyFor(ap, poWindows).policy ==
      @[rkScoop, rkTarball, rkPath]

  test "test_m25_adapter_preference_empty_chain_list_falls_back":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @[]
    let p = selectionPolicyFor(ap, poWindows)
    check p.policy == DefaultSelectionPolicy
    check p.source == "default"

  test "test_m25_adapter_preference_three_adapter_chain_full_override":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["path", "scoop", "builtin"]
    ap["linux"]   = @["tarball", "nix", "path"]
    ap["darwin"]  = @["path"]
    check selectionPolicyFor(ap, poWindows).policy ==
      @[rkPath, rkScoop, rkTarball]
    check selectionPolicyFor(ap, poLinux).policy ==
      @[rkTarball, rkNix, rkPath]
    check selectionPolicyFor(ap, poMacos).policy == @[rkPath]

# ---------------------------------------------------------------------------
# Tests: previewPackageResolutions walks the context's policy
# ---------------------------------------------------------------------------

suite "M2.5/GM4b — previewPackageResolutions honours the policy":

  test "test_m25_preview_uses_custom_chain_order":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["scoop", "builtin", "path"]
    let p = jdkPreview(ap)
    check p.kind == ppkRealize
    check p.resolved
    check p.steps.len == 2
    # FIRST step is scoop — the override reached the resolver. jdk
    # declares no scoopApp, so it declines.
    check p.steps[0].kind == rkScoop
    check not p.steps[0].selected
    check p.steps[1].kind == rkTarball
    check p.steps[1].selected

  test "test_m25_preview_default_fallback_preserves_m65_default":
    let p = jdkPreview(initOrderedTable[string, seq[string]]())
    check p.kind == ppkRealize
    check p.steps.len == 1
    check p.steps[0].kind == rkTarball
    check p.steps[0].selected

  test "test_m25_preview_empty_chain_falls_back_to_platform_default":
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @[]
    let p = jdkPreview(ap)
    check p.steps[0].kind == rkTarball

  test "test_m25_preview_chain_order_path_first":
    # path first: the target is not this machine, so PATH is not
    # consulted and the walk proceeds to the archive. The trace's FIRST
    # step is path either way, proving the order is honoured.
    var ap = initOrderedTable[string, seq[string]]()
    ap["windows"] = @["path", "builtin"]
    let p = jdkPreview(ap)
    check p.kind == ppkRealize
    check p.steps.len == 2
    check p.steps[0].kind == rkPath
    check not p.steps[0].selected
    check "host only" in p.steps[0].reason
    check p.steps[1].kind == rkTarball

  test "test_m25_preview_other_os_entry_does_not_apply":
    var ap = initOrderedTable[string, seq[string]]()
    ap["linux"] = @["nix", "path"]
    let p = jdkPreview(ap)
    check p.steps[0].kind == rkTarball

# ---------------------------------------------------------------------------
# Tests: end-to-end profile -> ApplyPlan -> chain selection
# ---------------------------------------------------------------------------

suite "M2.5/GM4b — Profile.adapterPreference plumbs through ApplyPlan":

  test "test_m25_apply_plan_copies_adapter_preference_from_profile":
    # `buildPlan` must carry `Profile.adapterPreference` over to
    # `ApplyPlan.adapterPreference` so the pipeline builds the resolution
    # context for preview and realize from it.
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
    # No block: the default policy, the same on every OS.
    for os in [poWindows, poLinux, poMacos]:
      check selectionPolicyFor(applyPlan.adapterPreference, os).policy ==
        DefaultSelectionPolicy
