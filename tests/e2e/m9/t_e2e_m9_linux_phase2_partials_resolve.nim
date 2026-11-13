## M9 → GM4b — end-to-end gate for the Linux home-profile validation
## harness.
##
## The companion harness ``scripts/verify-m9-linux-home-profile-fixtures.sh``
## bootstraps a sandboxed home profile, runs ``repro home apply``, then
## runs every per-fixture validate-*.sh against the activated PATH (LIVE,
## gated behind ``REPRO_LIVE=1``).
##
## This Nim e2e is the HERMETIC counterpart: the resolver-level contract
## the harness depends on, for an x86_64-linux target, without network or
## CAS. GM4b replaced the per-platform adapter chain with one selection
## policy (Provisioning-Contributions.md §"Profile Package References");
## the contract, restated:
##
##   1. Every Phase-2-CLEAN package (ghc / cabal / crystal) and every
##      Phase-1 baseline-dev-tool (nim / just / gh / cmake / ninja / git)
##      resolves under the DEFAULT policy (tarball, nix, scoop, path — the
##      same on every platform) and the policy steps are walked in that
##      order up to the selecting one.
##   2. The eight tools M9.5 gave Linux archives select their `tarball`
##      realization; `git` (Git for Windows publishes no Linux asset)
##      selects its `nixPackage` realization — the Nix contribution the
##      old chain listed but never wired.
##   3. The M9 reference home.nim parses and references every package the
##      harness depends on, and lists no NO-CATALOG package (gnat / dune):
##      those are unknown packages and would fail the apply closed.
##
## The target is NOT the machine running the test, so the host's PATH never
## stands in for a realization: the outcome is identical on any runner.
## No mocks.

import std/[os, strutils, tables, unittest]
import repro_test_support

import repro_dsl_stdlib/package_registry
import repro_home_apply/package_catalog

let
  ReprobuildRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()
  M9ReferenceHome =
    workspaceRootForRepo(ReprobuildRoot) / "reprobuild-examples" /
      "m9-linux-home-profile" / "home.nim"

# The Phase-2 graduation matrix the M9 harness keys off of. Keep this
# in sync with the ``graduation_table`` heredoc in
# scripts/verify-m9-linux-home-profile-fixtures.sh.
const
  Phase2LinuxFixtures = ["ghc", "cabal", "crystal"]
    ## Definitions with Linux archives since M9.5 (the upstream
    ## tarballs target glibc 2.17, the RHEL 7 / Ubuntu 14.04 floor).

  Phase1BaselineDevTools = ["nim", "just", "gh", "cmake", "ninja", "git"]
    ## Cross-language baseline toolchain. All but ``git`` gained Linux
    ## archives in M9.5; ``git`` resolves to its nixPackage.

  Phase2NoCatalog = ["gnat", "dune"]
    ## No packages/<tool>.nim definition. The M9 reference home.nim MUST
    ## NOT list them (the apply would fail closed: unknown package).

type
  LinuxResolverOutcome = enum
    lroTarball  = "tarball"
    lroNix      = "nix"
    lroPath     = "path"
    lroMissing  = "missing"

let linuxX64 = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)

proc classifyLinuxResolution(packageId: string):
    tuple[outcome: LinuxResolverOutcome; steps: seq[KindOutcome]] =
  ## Resolve for x86_64-linux under the default policy and classify.
  try:
    let res = resolveProfilePackage(packageId, linuxX64,
      DefaultSelectionPolicy)
    let outcome =
      case res.selection.kind
      of rkTarball: lroTarball
      of rkNix: lroNix
      of rkPath: lroPath
      of rkScoop: lroMissing  # scoop never serves a Linux target
    (outcome, res.selection.trace)
  except EMissingRealization as e:
    (lroMissing, e.steps)

suite "M9/GM4b e2e: Linux home-profile resolver contract":

  test "every Phase-2 Linux fixture package has a linked definition":
    for pkg in Phase2LinuxFixtures:
      checkpoint pkg
      check isLinkedPackage(pkg)

  test "every Phase-1 baseline-dev-tool has a linked definition":
    for pkg in Phase1BaselineDevTools:
      checkpoint pkg
      check isLinkedPackage(pkg)

  test "the default policy is walked in order up to the selecting kind":
    for pkg in @Phase2LinuxFixtures & @Phase1BaselineDevTools:
      checkpoint pkg
      let (_, steps) = classifyLinuxResolution(pkg)
      check steps.len >= 1
      for i, step in steps:
        check step.kind == DefaultSelectionPolicy[i]
        # Only the last step may have selected.
        if i < steps.len - 1:
          check not step.selected
      check steps[^1].selected

  test "Phase-2 NO-CATALOG packages are unknown packages":
    for pkg in Phase2NoCatalog:
      checkpoint pkg
      var raised = false
      try:
        discard resolveProfilePackage(pkg, linuxX64, DefaultSelectionPolicy)
      except EMissingRealization as err:
        raised = true
        check err.packageName == pkg
        check not err.definitionKnown
      check raised
      check not isLinkedPackage(pkg)

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

  test "per-tool Linux classification matrix (post-M9.5, GM4b)":
    ## M9.5 gave ghc + cabal + crystal (Phase-2) and nim + just + gh +
    ## cmake + ninja (Phase-1) Linux archives: 8 tools select a tarball.
    ## `git` has no Linux archive; GM4b's default policy reaches its
    ## nixPackage. A reviewer adding Linux archives should move tools
    ## between the two sets.
    const GraduatedOnLinux = ["ghc", "cabal", "crystal",
      "nim", "just", "gh", "cmake", "ninja"]
    var classifications: Table[string, LinuxResolverOutcome]
    for pkg in @Phase2LinuxFixtures & @Phase1BaselineDevTools:
      classifications[pkg] = classifyLinuxResolution(pkg).outcome
    check classifications.len ==
      Phase2LinuxFixtures.len + Phase1BaselineDevTools.len
    var tarballCount = 0
    for pkg, outcome in classifications.pairs:
      checkpoint pkg & " -> " & $outcome
      if outcome == lroTarball: inc tarballCount
    check tarballCount == GraduatedOnLinux.len
    for pkg in GraduatedOnLinux:
      check classifications[pkg] == lroTarball
    check classifications["git"] == lroNix
