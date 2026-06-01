## M9 — end-to-end gate for the Linux home-profile validation harness.
##
## The companion harness ``scripts/verify-m9-linux-home-profile-fixtures.sh``
## bootstraps a sandboxed home profile, runs ``repro home apply``, then
## runs every per-fixture validate-*.sh against the activated PATH.
## That harness exercises the LIVE path (downloads catalog artifacts
## once Linux URLs are published; gated behind ``REPRO_LIVE=1``).
##
## This Nim e2e is the HERMETIC counterpart: it exercises the
## resolver-level contract the harness depends on without touching the
## network or the sandboxed CAS. Specifically:
##
##   1. Every Phase-2-CLEAN package (ghc / cabal / crystal) and every
##      Phase-1 baseline-dev-tool (nim / just / gh / cmake / ninja)
##      walks the M65 ``LinuxDefaultChain = @[cakNix, cakBuiltin, cakPath]``
##      and surfaces the documented per-adapter outcome:
##        * cakNix returns ``csoAdapterUnavailable`` cleanly (the M21
##          realize-side branch isn't wired into the resolver yet —
##          parallel-agent territory, OUT OF SCOPE for M9).
##        * cakBuiltin finds the catalog entry but the ``poLinux``
##          slice is missing (every M67/M68 harvest pulled from Scoop,
##          which is Windows-only) — ``csoSchemaError`` with
##          ``brePlatformNotSupported``. The chain moves on.
##        * cakPath either resolves the tool (if it's on the test
##          runner's PATH) or surfaces ``csoToolNotFound``.
##
##      Net effect: on a test runner without these tools on PATH the
##      chain raises ``EAdapterChainExhausted``; on a runner with them
##      on PATH the resolution comes back as ``adapter == cakPath``.
##      The gate accepts both outcomes — the contract is that the chain
##      walked the three adapters in the expected order with the
##      expected per-adapter classification.
##
##   2. The M9 reference home.nim under
##      ``reprobuild-examples/m9-linux-home-profile/home.nim`` parses
##      cleanly and references every package the harness depends on.
##
##   3. The M9 reference home.nim does NOT list any NO-CATALOG package
##      (gnat / dune) — listing one would cause ``repro home apply``
##      to fail closed with ``EUnknownPackageId`` before any work
##      happens.
##
## **Why this gate runs on Windows.** The test asserts a per-tool
## classification AT THE RESOLVER LEVEL by explicitly threading
## ``hostOs = poLinux`` through ``chainResolvePackage``. The chain
## logic + per-adapter outcome is host-independent (modulo the
## ``when defined(windows)`` short-circuit in ``tryResolveNix`` which
## the gate accepts as either reason); the test is hermetic and runs
## anywhere ``run_tests.sh`` runs. The companion bash harness is the
## live-on-Linux gate.
##
## **What graduates this gate.** If a future Linux harvester pass adds
## ``poLinux`` slices to ghc / cabal / crystal / etc, the cakBuiltin
## arm will start returning ``csoResolved`` for those packages on a
## Linux test runner. The gate accepts both the current "fall through
## to path" outcome and the future "cakBuiltin resolves" outcome — the
## contract is the chain walks in the right order with the right
## per-adapter classification.

import std/[options, os, strutils, tables, unittest]

import repro_dsl_stdlib/catalog_registry
import repro_dsl_stdlib/packages_schema
import repro_home_apply/catalog_lookup
import repro_home_apply/package_catalog

const M9ReferenceHome =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir().parentDir() /
    "reprobuild-examples" / "m9-linux-home-profile" / "home.nim"
  ## The reprobuild repo lives at ``D:/metacraft/reprobuild`` and the
  ## reprobuild-examples sibling lives at ``D:/metacraft/reprobuild-examples``.
  ## Walk up 5 levels from ``tests/e2e/m9/t_e2e_*.nim`` to land on the
  ## metacraft root, then into reprobuild-examples.

# The Phase-2 graduation matrix the M9 harness keys off of. Keep this
# in sync with the ``graduation_table`` heredoc in
# scripts/verify-m9-linux-home-profile-fixtures.sh.
const
  Phase2LinuxFixtures = ["ghc", "cabal", "crystal"]
    ## Catalog entries present + the Linux upstream tarballs target
    ## glibc 2.17 (RHEL 7 / Ubuntu 14.04 floor). Awaiting a Linux
    ## harvester pass to add ``poLinux`` slices to the catalog; until
    ## then the chain falls through cakBuiltin (brePlatformNotSupported)
    ## to cakPath.

  Phase1BaselineDevTools = ["nim", "just", "gh", "cmake", "ninja", "git"]
    ## Cross-language baseline toolchain. Same Linux story: catalog
    ## entry present, Windows-URL only today, awaiting Linux harvester
    ## pass.

  Phase2NoCatalog = ["gnat", "dune"]
    ## No packages/<tool>.nim entry. The M9 reference home.nim MUST
    ## NOT list them (would cause apply to fail closed with
    ## EUnknownPackageId).

# Helper: classify the outcome of a chain walk for a given package on
# a Linux host. Returns one of:
#   "builtin-resolved-linux-url" — cakBuiltin returned csoResolved
#                                  (a Linux harvester pass landed)
#   "nix-resolved"               — cakNix returned csoResolved
#                                  (Nix resolver wired in)
#   "path-resolved"              — cakPath returned csoResolved
#                                  (tool already on the host PATH)
#   "unresolvable-linux"         — every adapter exhausted; the harness
#                                  reports the fixture as STILL-SKIPPED
type
  LinuxResolverOutcome = enum
    lroBuiltinResolvedLinuxUrl = "builtin-resolved-linux-url"
    lroNixResolved             = "nix-resolved"
    lroPathResolved            = "path-resolved"
    lroUnresolvableLinux       = "unresolvable-linux"

proc classifyLinuxResolution(packageId: string):
    tuple[outcome: LinuxResolverOutcome; trace: seq[ChainStep]] =
  ## Walk the Linux default chain with hostOs = poLinux and classify.
  var cat = openProductionCatalog()
  try:
    let res = chainResolvePackage(cat, packageId,
      chain = @[cakNix, cakBuiltin, cakPath],
      hostCpu = pcX86_64, hostOs = poLinux)
    case res.adapter
    of cakBuiltin: return (lroBuiltinResolvedLinuxUrl, res.chainTrace)
    of cakNix:     return (lroNixResolved, res.chainTrace)
    of cakPath:    return (lroPathResolved, res.chainTrace)
    else:
      # cakScoop should never resolve in a [nix, builtin, path] chain
      # because scoop isn't listed. Defensive.
      return (lroUnresolvableLinux, res.chainTrace)
  except EAdapterChainExhausted as e:
    return (lroUnresolvableLinux, e.chainTrace)

suite "M9 e2e: Linux home-profile resolver-contract":

  test "every Phase-2 Linux fixture package has a registered catalog":
    for pkg in Phase2LinuxFixtures:
      check isRegistered(pkg)
      let cat = getCatalog(pkg)
      check cat.isSome
      check cat.get.len > 0

  test "every Phase-1 baseline-dev-tool has a registered catalog":
    for pkg in Phase1BaselineDevTools:
      check isRegistered(pkg)
      let cat = getCatalog(pkg)
      check cat.isSome
      check cat.get.len > 0

  test "Linux chain walks [cakNix, cakBuiltin, cakPath] in order":
    # The contract: every chain trace's adapter sequence matches the
    # configured chain prefix up to (and including) the resolving
    # adapter (or every step on an exhausted chain).
    var cat = openProductionCatalog()
    for pkg in @Phase2LinuxFixtures & @Phase1BaselineDevTools:
      var trace: seq[ChainStep]
      try:
        let res = chainResolvePackage(cat, pkg,
          chain = @[cakNix, cakBuiltin, cakPath],
          hostCpu = pcX86_64, hostOs = poLinux)
        trace = res.chainTrace
      except EAdapterChainExhausted as e:
        trace = e.chainTrace
      # Always at least cakNix in the trace.
      check trace.len >= 1
      check trace[0].adapter == cakNix
      # cakNix is always csoAdapterUnavailable today (the M21 resolver-
      # side branch is not wired). Accept both "skipped on non-Windows"
      # and "skipped on Windows" reasons.
      check trace[0].outcome == csoAdapterUnavailable
      # If the chain didn't terminate at cakNix, the next step is cakBuiltin.
      if trace.len >= 2:
        check trace[1].adapter == cakBuiltin
      # If the chain reached cakPath, it's the third step.
      if trace.len >= 3:
        check trace[2].adapter == cakPath

  test "cakBuiltin on Linux: post-M9.5 graduated tools resolve; git skips":
    ## M9.5 graduated 8 of the 9 tools listed here: ghc + cabal + crystal
    ## (Phase-2 fixtures) and nim + just + gh + cmake + ninja (Phase-1
    ## baseline). The only baseline-tool that remains
    ## brePlatformNotSupported on Linux is ``git`` — Git-for-Windows
    ## publishes no Linux asset; the Linux story for git is the distro
    ## package manager (apt/dnf/pacman), which is M9.6+ territory per
    ## the M9.5 honest-scope decision.
    ##
    ## The per-tool assertions below replace the pre-M9.5 "all skip"
    ## branch. A reviewer adding more Linux slices in a future
    ## milestone should extend the expected-resolved set and shrink
    ## the expected-skip set accordingly.
    const Pkg9_5GraduatedOnLinux = [
      "ghc", "cabal", "crystal",
      "nim", "just", "gh", "cmake", "ninja",
    ]
    const Pkg9_5StillSkippedOnLinux = ["git"]
    var cat = openProductionCatalog()
    for pkg in Pkg9_5GraduatedOnLinux:
      var trace: seq[ChainStep]
      try:
        let res = chainResolvePackage(cat, pkg,
          chain = @[cakBuiltin],
          hostCpu = pcX86_64, hostOs = poLinux)
        trace = res.chainTrace
        check trace.len == 1
        check trace[0].adapter == cakBuiltin
        check trace[0].outcome == csoResolved
      except EAdapterChainExhausted as e:
        # Reaching this branch means a Linux slice that USED to resolve
        # via cakBuiltin no longer does — a regression. The chain
        # diagnostic in e.chainTrace should name the missing slice.
        check false  # graduate-then-skip regression
        trace = e.chainTrace
        echo "REGRESSION: '", pkg, "' was supposed to resolve via cakBuiltin"
        for step in trace:
          echo "  ", step.adapter, " -> ", step.outcome, ": ", step.reason
    for pkg in Pkg9_5StillSkippedOnLinux:
      var trace: seq[ChainStep]
      try:
        let res = chainResolvePackage(cat, pkg,
          chain = @[cakBuiltin],
          hostCpu = pcX86_64, hostOs = poLinux)
        trace = res.chainTrace
        # Should NOT resolve — but if it does, M9.6 graduated this tool;
        # the reviewer should move it into the GraduatedOnLinux list.
        check trace[0].outcome != csoResolved
      except EAdapterChainExhausted as e:
        trace = e.chainTrace
        check trace.len == 1
        check trace[0].adapter == cakBuiltin
        check trace[0].outcome == csoSchemaError
        # The reason carries the brePlatformNotSupported tag.
        check ("platform-not-supported" in trace[0].reason) or
              ("os=linux" in trace[0].reason)

  test "Phase-2 NO-CATALOG packages raise EUnknownPackageId":
    for pkg in Phase2NoCatalog:
      var raised = false
      try:
        discard lookupCatalogSlice(pkg)
      except EUnknownPackageId as err:
        raised = true
        check err.packageId == pkg
        check err.registered.len > 0
      check raised
      check not isRegistered(pkg)

  test "M9 reference home.nim exists at the documented path":
    check fileExists(M9ReferenceHome)
    let content = readFile(M9ReferenceHome)
    proc referenced(pkg: string): bool =
      content.contains("package(" & pkg & ",") or
      content.contains("package(`" & pkg & "`,") or
      content.contains("package(\"" & pkg & "\",")
    for pkg in Phase2LinuxFixtures:
      check referenced(pkg)
    for pkg in Phase1BaselineDevTools:
      check referenced(pkg)

  test "M9 reference home.nim does NOT list any NO-CATALOG package":
    let content = readFile(M9ReferenceHome)
    for pkg in Phase2NoCatalog:
      let blockedRef = content.contains("package(" & pkg & ",") or
                       content.contains("package(" & pkg & ")") or
                       content.contains("package(`" & pkg & "`") or
                       content.contains("package(\"" & pkg & "\"")
      check not blockedRef

  test "per-tool Linux classification matrix (post-M9.5)":
    ## M9.5 (post-graduation): the canary's pre-M9.5 assertion
    ## ``builtinResolvedCount == 0`` flipped to a fixed expected count
    ## reflecting the per-tool graduation table M9.5 populated.
    ##
    ## **Graduated via cakBuiltin (Linux URLs added):** ghc + cabal +
    ## crystal (Phase-2 fixtures) and nim + just + gh + cmake + ninja
    ## (Phase-1 baseline) — 8 tools. The remaining baseline-dev-tool
    ## ``git`` stays unresolvable-linux pending an apt/dnf/pacman
    ## harvester (M9.6 territory).
    ##
    ## A reviewer adding more Linux slices in a future milestone should
    ## bump ``ExpectedBuiltinResolvedOnLinux`` to match the new graduated
    ## count.
    const ExpectedBuiltinResolvedOnLinux = 8
    var classifications: Table[string, LinuxResolverOutcome]
    for pkg in @Phase2LinuxFixtures & @Phase1BaselineDevTools:
      let (outcome, _) = classifyLinuxResolution(pkg)
      classifications[pkg] = outcome
    var builtinResolvedCount = 0
    var nixResolvedCount = 0
    var pathResolvedCount = 0
    var unresolvableCount = 0
    for pkg, outcome in classifications.pairs:
      case outcome
      of lroBuiltinResolvedLinuxUrl: builtinResolvedCount.inc
      of lroNixResolved:             nixResolvedCount.inc
      of lroPathResolved:            pathResolvedCount.inc
      of lroUnresolvableLinux:       unresolvableCount.inc
    # Post-M9.5 graduation count.
    check builtinResolvedCount == ExpectedBuiltinResolvedOnLinux
    # Nix resolver-side branch is still M21 / parallel-agent territory.
    check nixResolvedCount == 0
    # Defensive: every tool was classified (the matrix is non-empty
    # and complete).
    check classifications.len == Phase2LinuxFixtures.len + Phase1BaselineDevTools.len
    # The remaining (classifications.len - builtinResolvedCount) tools
    # fall through to cakPath (host PATH hit) or terminate unresolvable.
    check builtinResolvedCount + pathResolvedCount + unresolvableCount ==
          classifications.len
    # Per-tool assertion: every Phase-2 fixture graduated.
    for pkg in Phase2LinuxFixtures:
      check classifications[pkg] == lroBuiltinResolvedLinuxUrl
    # Per-tool assertion: the 5 baseline tools that gained Linux slices
    # in M9.5 graduated.
    const Pkg9_5GraduatedBaseline = ["nim", "just", "gh", "cmake", "ninja"]
    for pkg in Pkg9_5GraduatedBaseline:
      check classifications[pkg] == lroBuiltinResolvedLinuxUrl
    # ``git`` is the only baseline tool that stayed unresolvable via
    # cakBuiltin. cakPath may resolve it on a developer machine (or
    # leave it unresolvable on a clean CI runner) — both outcomes
    # accepted.
    check classifications["git"] in
          {lroPathResolved, lroUnresolvableLinux}
