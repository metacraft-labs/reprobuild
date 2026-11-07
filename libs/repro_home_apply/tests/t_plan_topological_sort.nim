## The exported Kahn utility retains deterministic ties and cycle detection.
## Four synthetic legacy dependency maps preserve its original concrete order
## cases. Production home ordering has no extractor edges: each tarball's
## common provisioning graph owns those dependencies, checked separately here.
## No mocks or network: only metadata selection and explicit graph callbacks.

import std/[algorithm, os, tables, unittest]
from repro_core/paths import extendedPath
import repro_test_support

import repro_home_apply/plan
import repro_home_apply/package_catalog
from repro_tool_profiles import installationToolRoles

let windowsTarget = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)
let defaultExtractorDeps = profileExtractorDeps(windowsTarget,
  DefaultSelectionPolicy)

# Explicit synthetic historical graph, testing the utility independently of
# today's provisioning policy. These edges no longer come from home planning.
let legacyExtractorDeps: ExtractorDepsCallback = proc(p: PlannedPackage): seq[string] =
  case p.packageId
  of "erlang": @["7zip"]
  of "meson": @["lessmsi"]
  of "swift": @["wix3", "lessmsi"]
  of "fpc": @["innounp"]
  else: @[]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

let
  ReprobuildRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
  M71ReferenceHome =
    workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
      "m71-home-profile-walkthrough" / "home.nim"

proc pkg(id: string; version = ""): PlannedPackage =
  ## Synthetic ``PlannedPackage`` factory. The fields the topo sort
  ## cares about are ``packageId`` and ``requestedVersion``; the
  ## activity / predicate fields are inert here.
  PlannedPackage(packageId: id, fromActivity: "default", predicateText: "",
    requestedVersion: version)

proc orderOf(packages: seq[PlannedPackage]): seq[string] =
  for p in packages: result.add(p.packageId)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M0 — plan.nim topological sort over realize ops":

  test "test_m0_topo_sort_7zip_before_erlang":
    # erlang uses imInstallerNsis → needs 7z.exe → depends on the
    # ``7zip`` catalog package. 7zip alphabetically PRECEDES erlang
    # already, so the pre-M0 alphabetical sort happened to produce
    # the right order for this case — the topo sort must agree.
    let inputs = @[pkg("erlang", "28.5"), pkg("7zip", "26.01")]
    let sorted = topologicallySortPackages(inputs, legacyExtractorDeps)
    check orderOf(sorted) == @["7zip", "erlang"]

  test "test_m0_topo_sort_lessmsi_before_meson":
    # meson uses imInstallerMsi → needs lessmsi.exe → depends on
    # ``lessmsi``. The pre-M0 alphabetical sort would have placed
    # lessmsi before meson anyway (l < m), so this is structurally
    # the same case as test 1 — the topo sort must agree.
    let inputs = @[pkg("meson", "1.11.0"), pkg("lessmsi", "")]
    let sorted = topologicallySortPackages(inputs, legacyExtractorDeps)
    check orderOf(sorted) == @["lessmsi", "meson"]

  test "test_m0_topo_sort_wix3_and_lessmsi_before_swift":
    # swift uses imInstallerNsisBundle → needs BOTH dark.exe (from
    # wix3) AND lessmsi.exe (from lessmsi). Both must precede swift.
    # Order between wix3 and lessmsi: alphabetical (lessmsi < wix3).
    let inputs = @[pkg("swift", "6.3.1"), pkg("wix3"), pkg("lessmsi")]
    let sorted = topologicallySortPackages(inputs, legacyExtractorDeps)
    let order = orderOf(sorted)
    # Both extractors precede swift.
    check order.find("lessmsi") < order.find("swift")
    check order.find("wix3") < order.find("swift")
    # Alphabetical tiebreak between the two extractors.
    check order == @["lessmsi", "wix3", "swift"]

  test "test_m0_topo_sort_innounp_before_fpc":
    # fpc uses imInstallerInnoSetup → needs innounp.exe → depends on
    # ``innounp``. innounp alphabetically PRECEDES fpc (f < i is
    # false; i > f so innounp > fpc alphabetically — the pre-M0
    # alphabetical sort would have ordered fpc FIRST, which is the
    # bug. The topo sort must reverse the order).
    let inputs = @[pkg("fpc", "3.2.2"), pkg("innounp", "")]
    let sorted = topologicallySortPackages(inputs, legacyExtractorDeps)
    check orderOf(sorted) == @["innounp", "fpc"]
    # Sanity: confirm the pre-M0 alphabetical sort would have ordered
    # them the WRONG way around.
    var alphabetical = @[pkg("fpc", "3.2.2"), pkg("innounp", "")]
    alphabetical.sort(proc(a, b: PlannedPackage): int =
      cmp(a.packageId, b.packageId))
    check orderOf(alphabetical) == @["fpc", "innounp"]
    # Topo sort produced a DIFFERENT order — proving the fix is
    # real for this case (test 4 is the load-bearing one for the
    # M11 LIVE-smoke regression).

  test "test_m0_topo_sort_cycle_fails_closed":
    # The utility also rejects caller-supplied dependency cycles:
    # ``a`` depends on ``b`` and ``b`` depends on ``a``.
    let inputs = @[pkg("synthetic-a"), pkg("synthetic-b")]
    let depMap = {
      "synthetic-a": @["synthetic-b"],
      "synthetic-b": @["synthetic-a"],
    }.toTable
    let cyclicDeps: ExtractorDepsCallback = proc (p: PlannedPackage):
        seq[string] =
      if p.packageId in depMap: depMap[p.packageId] else: @[]
    var raised = false
    var participants: seq[string] = @[]
    try:
      discard topologicallySortPackages(inputs, cyclicDeps)
    except EPlanCycleDetected as e:
      raised = true
      participants = e.cycleParticipants
    check raised
    # The exception carries BOTH cycle participants (the algorithm
    # cannot decide a winner so neither one drained).
    check "synthetic-a" in participants
    check "synthetic-b" in participants

  test "test_m0_topo_sort_m71_reference_profile_stable":
    # The M71 reference profile (24 packages) has NONE of the four
    # extractor catalog packages (7zip / lessmsi / wix3 / innounp)
    # bundled — every extractor edge therefore points outside the
    # plan and gets silently dropped. The topo sort must reduce to
    # the alphabetical tiebreak, byte-identical to the pre-M0
    # alphabetical sort.
    #
    # We exercise the contract by feeding ``topologicallySortPackages``
    # a synthetic ``PlannedPackage`` list mirroring the M71 reference
    # profile's package set. This is hermetic AND avoids depending on
    # the intent-layer parser's support for the M71 file's
    # ``package("dotnet-sdk", "...")`` string-id form (the profile is
    # designed to be compiled via the M83 macro library; the M60 text
    # parser does not accept string-form ids).
    #
    # Sanity check: the reference file exists at the documented path
    # (mirrors the M71 e2e gate's path-existence assertion).
    check fileExists(extendedPath(M71ReferenceHome))

    # The 24-package set in document order — copied from the reference
    # home.nim. Versions are inert for the historical graph callback.
    let m71Packages = @[
      pkg("cmake", "4.3.3"),
      pkg("ninja", "1.13.2"),
      pkg("meson", "1.11.0"),
      pkg("git", "2.54.0"),
      pkg("gh", "2.93.0"),
      pkg("just", "1.51.0"),
      pkg("node", "24.16.0"),
      pkg("python3", "3.14.5"),
      pkg("nim", "2.2.10"),
      pkg("gcc", "15.2.0"),
      pkg("jdk", "21.0.5"),
      pkg("maven", "3.9.16"),
      pkg("gradle", "9.5.1"),
      pkg("ghc", "9.12.1"),
      pkg("cabal", "3.16.1.0"),
      pkg("erlang", "28.5"),
      pkg("elixir", "1.19.5"),
      pkg("swift", "6.3.1"),
      pkg("zig", "0.16.0"),
      pkg("dotnet-sdk", "10.0.300"),
      pkg("crystal", "1.20.2"),
      pkg("php", "8.5.6"),
      pkg("composer", "2.10.0"),
      pkg("ruby", "4.0.5-1"),
    ]
    check m71Packages.len == 24

    let sorted = topologicallySortPackages(m71Packages, legacyExtractorDeps)
    let actual = orderOf(sorted)

    # The pre-M0 alphabetical sort over the same input set — this is
    # the byte-identical reference order we MUST preserve.
    var expected: seq[string] = @[]
    for p in m71Packages: expected.add(p.packageId)
    expected.sort(cmp[string])

    check actual == expected

    # Spot-check: extractor consumers appear in the plan but their
    # extractors do not — proving the "edge points outside the
    # plan → silently dropped" branch is what kept the order stable.
    check "erlang" in actual          # imInstallerNsis consumer
    check "meson" in actual           # imInstallerMsi consumer
    check "swift" in actual           # imInstallerNsisBundle consumer
    check "git" in actual             # afSevenZipSfx consumer
    check "gcc" in actual             # afSevenZip consumer
    check "7zip" notin actual         # provider — NOT in the plan
    check "lessmsi" notin actual      # provider — NOT in the plan
    check "wix3" notin actual         # provider — NOT in the plan
    check "innounp" notin actual      # provider — NOT in the plan

  test "production profile order is independent of installer helper packages":
    let inputs = @[pkg("swift"), pkg("wix3"), pkg("lessmsi"),
      pkg("fpc"), pkg("innounp"), pkg("erlang"), pkg("7zip"), pkg("meson")]
    for entry in inputs:
      check defaultExtractorDeps(entry).len == 0
    check orderOf(topologicallySortPackages(inputs, defaultExtractorDeps)) ==
      @["7zip", "erlang", "fpc", "innounp", "lessmsi", "meson", "swift", "wix3"]
    # The helper requirements remain on the actual common provisioning path;
    # removing home-ordering edges must not discard installation dependencies.
    for (packageId, roles, legacyProviders) in [
        ("erlang", @["7z"], @["7zip"]),
        ("meson", @["lessmsi"], @["lessmsi"]),
        ("swift", @["7z", "lessmsi", "wix3"], @["wix3", "lessmsi"]),
        ("fpc", @["innounp"], @["innounp"])]:
      let resolution = resolveProfilePackage(packageId, windowsTarget, @[rkTarball])
      checkpoint(packageId)
      check installationToolRoles(resolution.selection.tarball) == roles
      check extractorDependencies(packageId, resolution.archive) == legacyProviders
