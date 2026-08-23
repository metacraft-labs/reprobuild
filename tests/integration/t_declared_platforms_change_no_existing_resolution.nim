## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on") — adding the
## ``platforms:`` field moves NOTHING for the catalog entries that do not
## declare one.
##
## Every one of the ~262 stdlib packages gained a defaulted field. PMC-1's
## acceptance criterion is that a representative slice of the real catalog
## resolves byte-identically before and after. The expected values below were
## MEASURED on the tree immediately before the change (commit 7fabac63) and
## are pinned here as literals, so this test compares against the actual prior
## behaviour rather than against whatever the code now happens to do.
##
## The slice covers the three shapes the milestone names:
##
##   * a Windows-only entry — ``innounp`` (one ``pcAny``/``poWindows``
##     ``PlatformBinary``);
##   * a multi-arm entry — ``gh`` (x86_64/aarch64 Windows plus an x86_64 Linux
##     slice carrying per-platform ``archive_format`` and ``bin_relpath``
##     overrides), resolved on BOTH a windows and a linux host so the arm
##     SELECTION is pinned and not just one arm's contents;
##   * a nix-only entry — ``atk`` (a single ``nixPackage`` arm, no built-in
##     catalog at all).
##
## Assertions:
##   1. ``innounp`` on x86_64-windows resolves to the same version, URL,
##      digest, archive format, install method, bin relpath and executable
##      name it did before.
##   2. ``gh`` on x86_64-windows and on x86_64-linux each resolve to their own
##      pre-existing slice, overrides included.
##   3. None of these packages reports a DECLARED availability, so the new
##      gate is not merely satisfied for them — it is not armed at all. This
##      is the assertion that would trip if the default were changed from
##      "undeclared" to "inferred from the arms that exist", which would gate
##      resolution on a guess.
##   4. ``innounp`` on a linux host still fails with the OLD
##      ``EAdapterChainExhausted`` — an undeclared package's failure mode is
##      unchanged, including its message.
##   5. ``atk`` (nix-only, not in the built-in registry) still fails with
##      ``EAdapterChainExhausted`` naming the built-in registry miss. A
##      nix-only entry is the case most at risk from an inferred default,
##      since it declares no platform anywhere.
##
## Falsifiable: change the resolver to gate on an inference over whichever
## provisioning arms exist, instead of on an explicit declaration, and
## assertion (3) trips — ``availability.declared`` becomes true for every
## registered package.
##
## MEASURED, not assumed: that mutation was applied against PMC-1's
## ``inferredPackagePlatforms`` / ``effectivePackagePlatforms`` helpers
## (``declaredPackagePlatforms`` rewritten to return the effective set with
## ``declared = true``) and only (3) tripped. (4) and (5) held, and the reason
## is worth recording because it is an argument about the inference itself:
## ``innounp`` has NO DSL provisioning arms at all — its Windows-only-ness
## lives in a harvested ``VersionedProvisioning`` catalog, which an
## arm-walking inference does not read — and ``atk``'s single ``nixPackage``
## arm contributes ``any``. So both infer "available everywhere" and the
## mutated gate stays silent for them. The inference is blind to exactly the
## shape the milestone's own findings cite (``packages/innounp.nim:98``),
## which is a second, independent reason not to gate resolution on it;
## assertion (3) is therefore the load-bearing one, and (4)/(5) pin the
## failure MESSAGES rather than the gate.
##
## (Those two helpers have since been deleted — no caller, no coverage, and
## the blindness recorded above. The measurement stands; a future PMC-5 lint
## should be written against a source that can see the harvested catalogs.)
##
## Hermetic: synthetic host targets throughout; the Scoop probe is pointed at
## a nonexistent root; no network, no PATH dependence (the chains under test
## exclude ``cakPath``).

import std/[options, os, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
# ``atk`` is not part of the built-in catalog registry, so its recipe module
# is imported directly to put the package in the registry for assertion (3).
import repro_dsl_stdlib/packages/atk
import repro_home_apply/package_catalog

suite "PMC-1 — declaring platforms: changes no existing resolution":

  test "t_declared_platforms_change_no_existing_resolution":
    let sandbox = getTempDir() / "pmc1-no-such-scoop-root"
    putEnv("SCOOP", sandbox)
    putEnv("REPRO_TEST_SCOOP_OVERRIDE", sandbox / "no-such-scoop.exe")
    defer:
      delEnv("SCOOP")
      delEnv("REPRO_TEST_SCOOP_OVERRIDE")

    var cat = openProductionCatalog()

    # ---- (1) Windows-only entry: innounp --------------------------------
    block windowsOnlyEntry:
      let r = chainResolvePackage(cat, "innounp", chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
      check r.adapter == cakBuiltin
      check r.resolvedVersion == "2.67.9"
      check r.builtinVersion == "2.67.9"
      check r.urlUsed == "https://raw.githubusercontent.com/jrathlev/" &
        "InnoUnpacker-Windows-GUI/refs/heads/master/innounp-2/bin/innounp-2.zip"
      check r.digestAlgorithm == "sha256"
      check r.digestValue ==
        "1439f8d9e24b19e7d0b31b9c427ba4533387522a370c39280f17d3371eb7febf"
      check r.archiveFormat == afZip
      check r.installMethod == imExtract
      check r.binRelpath == @["innounp.exe"]
      check r.executableName == "innounp.exe"
      check r.extractPath == ""

    # ---- (2) multi-arm entry: gh, on both hosts -------------------------
    block multiArmEntryWindows:
      let r = chainResolvePackage(cat, "gh", chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poWindows)
      check r.adapter == cakBuiltin
      check r.resolvedVersion == "2.93.0"
      check r.urlUsed == "https://github.com/cli/cli/releases/download/" &
        "v2.93.0/gh_2.93.0_windows_amd64.zip"
      check r.digestAlgorithm == "sha256"
      check r.digestValue ==
        "77aa01ed7317295ad550de0ad04f3f276b1ef0e9272e3d002ac28dd99853d211"
      check r.archiveFormat == afZip
      check r.installMethod == imExtract
      check r.binRelpath == @["bin\\gh.exe"]
      check r.executableName == "gh.exe"

    block multiArmEntryLinux:
      let r = chainResolvePackage(cat, "gh", chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poLinux)
      check r.adapter == cakBuiltin
      check r.resolvedVersion == "2.93.0"
      check r.urlUsed == "https://github.com/cli/cli/releases/download/" &
        "v2.93.0/gh_2.93.0_linux_amd64.tar.gz"
      check r.digestAlgorithm == "sha256"
      check r.digestValue ==
        "02d1290eba130e0b896f3709ffff22e1c75a51475ddb70476a85abc6b5807af0"
      # The per-platform overrides still fire.
      check r.archiveFormat == afTarGz
      check r.installMethod == imExtract
      check r.binRelpath == @["gh_2.93.0_linux_amd64/bin/gh"]
      check r.executableName == "gh"

    # ---- (3) none of the slice declares availability --------------------
    block noneDeclared:
      # PMC-5 note: ``innounp`` USED to be this block's Windows-only
      # specimen. PMC-5 declares it (it genuinely cannot exist off Windows),
      # so it moved to the `declaredWindowsOnlyEntry` block below. ``python3``
      # replaces it here: its catalog is Windows-only too, but only because
      # just the Windows slice was harvested, so it stays deliberately
      # UNDECLARED and is the right specimen for "the gate must not fire".
      for name in ["python3", "gh", "atk", "jdk", "cmake"]:
        let availability = packageAvailability(name)
        check not availability.declared
        # And an undeclared package is available on every host, including
        # ones no arm covers — the gate must not fire for it.
        check availability.isAvailableOn(pcX86_64, poLinux)
        check availability.isAvailableOn(pcAArch64, poMacos)

    # ---- (4) an UNDECLARED windows-only catalog on linux: unchanged -----
    # The property this block pins is that a package nobody declared keeps its
    # pre-PMC-1 failure exactly. The specimen changed from ``innounp`` to
    # ``python3`` when PMC-5 declared innounp; the property did not.
    block undeclaredWindowsOnlyEntryOnLinux:
      var raised = false
      try:
        discard chainResolvePackage(cat, "python3",
          chain = @[cakBuiltin, cakNix], hostCpu = pcX86_64, hostOs = poLinux)
      except EPackageUnavailableOnPlatform as err:
        checkpoint "undeclared package gained a platform gate: " & err.msg
        check false
      except EAdapterChainExhausted as err:
        raised = true
        check err.packageId == "python3"
        check err.msg.contains("adapter chain exhausted")
      check raised

    # ---- (4b) PMC-5: a DECLARED windows-only entry now fails with a reason
    # The counterpart, and the reason the specimen above had to move. This is
    # the behaviour change PMC-5 exists to make, asserted here rather than
    # left as an unexplained edit to the block above.
    block declaredWindowsOnlyEntry:
      var raised = false
      try:
        discard chainResolvePackage(cat, "innounp",
          chain = @[cakBuiltin, cakNix], hostCpu = pcX86_64, hostOs = poLinux)
      except EPackageUnavailableOnPlatform as err:
        raised = true
        check err.packageId == "innounp"
        # Named, not merely refused -- PMC-1's whole point.
        check err.msg.contains("windows")
      except EAdapterChainExhausted:
        checkpoint "innounp is declared but still exhausted the chain; the " &
          "PMC-5 declaration is not reaching the gate"
        check false
      check raised

    # ---- (5) nix-only entry: the OLD failure, unchanged -----------------
    block nixOnlyEntry:
      var raised = false
      try:
        discard chainResolvePackage(cat, "atk",
          chain = @[cakNix, cakBuiltin], hostCpu = pcX86_64, hostOs = poLinux)
      except EPackageUnavailableOnPlatform as err:
        checkpoint "nix-only package gained a platform gate: " & err.msg
        check false
      except EAdapterChainExhausted as err:
        raised = true
        check err.packageId == "atk"
        check err.msg.contains("no built-in catalog registered for 'atk'")
      check raised
