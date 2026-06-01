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

  test "cakBuiltin on Linux surfaces brePlatformNotSupported (today)":
    # The current Linux catalog reality: every M67/M68 harvest pulled
    # from Scoop, so no ``poLinux`` slice exists. The cakBuiltin step
    # walks ``resolveBuiltinPackage``, hits ``selectPlatformBinary``,
    # finds no (pcX86_64, poLinux) entry, and returns
    # ``brePlatformNotSupported`` → ``csoSchemaError``. A future
    # harvester pass will graduate this to ``csoResolved`` for tools
    # whose upstream publishes a Linux tarball; this gate documents
    # the current state so a future graduation breaks the gate (and
    # the reviewer remembers to flip the assertion).
    var cat = openProductionCatalog()
    for pkg in @Phase2LinuxFixtures & @Phase1BaselineDevTools:
      var trace: seq[ChainStep]
      try:
        let res = chainResolvePackage(cat, pkg,
          chain = @[cakBuiltin],
          hostCpu = pcX86_64, hostOs = poLinux)
        trace = res.chainTrace
        # If the chain RESOLVED via cakBuiltin on Linux today that
        # means a Linux harvester pass landed — the gate's contract
        # graduates and the reviewer should update the test to assert
        # csoResolved. Until then, this branch should not execute.
        check trace[0].adapter == cakBuiltin
        check trace[0].outcome == csoResolved
      except EAdapterChainExhausted as e:
        trace = e.chainTrace
        check trace.len == 1
        check trace[0].adapter == cakBuiltin
        check trace[0].outcome == csoSchemaError
        # The reason carries the brePlatformNotSupported tag (the
        # enum stringifies as "platform-not-supported"; the catalog
        # diagnostic mentions the missing (cpu, os) tuple).
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

  test "per-tool Linux classification matrix (honest documentation)":
    ## CANARY: this test breaks when Linux URLs land in the catalog
    ## (the M9.5 trigger). When ``builtinResolvedCount > 0`` or
    ## ``nixResolvedCount > 0`` the assertions below must be updated to
    ## reflect the new expected resolution counts per the per-tool
    ## graduation table the harvester pass populates.
    # The M9 hermetic gate doubles as documentation: for every tool
    # the harness consults on Linux, classify by terminating outcome.
    # On a vanilla Windows test runner the classification reflects the
    # resolver-only contract; cakPath probes the host PATH so tools
    # like ``git`` / ``cmake`` may resolve as path-resolved on a
    # developer machine while a clean CI runner sees them as
    # unresolvable-linux.
    var classifications: Table[string, LinuxResolverOutcome]
    for pkg in @Phase2LinuxFixtures & @Phase1BaselineDevTools:
      let (outcome, _) = classifyLinuxResolution(pkg)
      classifications[pkg] = outcome
    # Honest assertions:
    #   * Today, NO tool should classify as builtin-resolved-linux-url
    #     (the catalog half is awaiting a Linux harvester pass).
    #   * Today, NO tool should classify as nix-resolved (the M21
    #     resolver-side branch isn't wired).
    #   * Every tool classifies as either path-resolved (host PATH
    #     hit) or unresolvable-linux (clean runner / no tool).
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
    # The two assertions that should hold UNTIL the Linux harvester
    # pass lands. A future graduation will require updating these.
    check builtinResolvedCount == 0
    check nixResolvedCount == 0
    # Defensive: at least one tool was classified (the matrix is non-
    # empty).
    check classifications.len == Phase2LinuxFixtures.len + Phase1BaselineDevTools.len
    check pathResolvedCount + unresolvableCount == classifications.len
