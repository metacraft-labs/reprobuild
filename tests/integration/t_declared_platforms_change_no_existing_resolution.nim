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
##   4. an UNDECLARED Windows-only entry on a linux target fails as a missing
##      realization (``EMissingRealization``), never as a platform gate — an
##      undeclared package's failure mode is the generic one.
##   5. ``atk`` (nix-only) is not gated either: it resolves through its
##      ``nixPackage`` on linux, and with an archive-only policy fails as a
##      missing realization naming the absent tarball kind.
##
## GM4b note on (1)/(2) and the specimens of (4)/(5): resolution is now
## ``realization_selection`` over the canonical definitions; the former
## ``<tool>Catalog`` records are ``tarball`` realizations of their packages.
## The literals of (1) and the URLs/digests of (2) are unchanged. Two things
## measurably moved, both by GM4b's documented catalog merge (same URL in
## both representations -> the in-package statement is the single record):
## gh's Windows executable is spelled ``bin/gh.exe`` (was ``bin\gh.exe``),
## and gh's Linux record realizes ``bin/gh`` with ``stripComponents = 1``
## instead of the catalog's unflattened ``gh_2.93.0_linux_amd64/bin/gh``.
## ``python3`` gained a resolvable Linux realization (its in-package
## python-build-standalone archive, which the old catalog-only path never
## consulted), so the undeclared Windows-only specimen of (4) is now ``php``;
## and ``atk``'s ``nixPackage`` now selects (the old chain's nix step was a
## placeholder that always skipped).
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
## Hermetic: synthetic targets throughout (``realizationTargetFor``); no
## host inventory is supplied, so no PATH or Scoop dependence; no network.

import std/[options, strutils, unittest]

import repro_dsl_stdlib/packages_schema
# ``atk`` is not part of the engine's package registry, so its recipe module
# is imported directly to put the package in the registry for (3) and (5).
import repro_dsl_stdlib/packages/atk
import repro_home_apply/package_catalog

let windows = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)
let linux = realizationTargetFor(pcX86_64, poLinux, mlX86_64_v1)

proc archiveOn(name: string; target: RealizationTarget): ArchiveRealization =
  let r = resolveProfilePackage(name, target, @[rkTarball])
  check r.selection.kind == rkTarball
  archiveRealizationOf(name, r.selection.tarball)

suite "PMC-1 — declaring platforms: changes no existing resolution":

  test "t_declared_platforms_change_no_existing_resolution":

    # ---- (1) Windows-only entry: innounp --------------------------------
    block windowsOnlyEntry:
      let r = archiveOn("innounp", windows)
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

    # ---- (2) multi-arm entry: gh, on both targets -----------------------
    block multiArmEntryWindows:
      let r = archiveOn("gh", windows)
      check r.resolvedVersion == "2.93.0"
      check r.urlUsed == "https://github.com/cli/cli/releases/download/" &
        "v2.93.0/gh_2.93.0_windows_amd64.zip"
      check r.digestAlgorithm == "sha256"
      check r.digestValue ==
        "77aa01ed7317295ad550de0ad04f3f276b1ef0e9272e3d002ac28dd99853d211"
      check r.archiveFormat == afZip
      check r.installMethod == imExtract
      check r.binRelpath == @["bin/gh.exe"]
      check r.executableName == "gh.exe"

    block multiArmEntryLinux:
      let resolution = resolveProfilePackage("gh", linux, @[rkTarball])
      let record = resolution.selection.tarball
      check record.url == "https://github.com/cli/cli/releases/download/" &
        "v2.93.0/gh_2.93.0_linux_amd64.tar.gz"
      check record.sha256 ==
        "02d1290eba130e0b896f3709ffff22e1c75a51475ddb70476a85abc6b5807af0"
      check record.detail.version == "2.93.0"
      # The per-platform shape still fires: a tar.gz with one directory
      # stripped, realized by the `uses:` provisioning edge.
      check record.archiveType == "tar.gz"
      check record.stripComponents == 1
      check record.executablePath == "bin/gh"
      check resolution.archiveRoute == arExtract

    # ---- (3) none of the slice declares availability --------------------
    block noneDeclared:
      # ``python3`` and ``php`` carry Windows-only harvested archives and stay
      # deliberately UNDECLARED: the right specimens for "the gate must not
      # fire".
      for name in ["python3", "php", "gh", "atk", "jdk", "cmake"]:
        let availability = packageAvailability(name)
        check not availability.declared
        # And an undeclared package is available on every target, including
        # ones no realization covers — the gate must not fire for it.
        check availability.isAvailableOn(pcX86_64, poLinux)
        check availability.isAvailableOn(pcAArch64, poMacos)

    # ---- (4) an UNDECLARED windows-only entry on linux: the generic miss -
    block undeclaredWindowsOnlyEntryOnLinux:
      var raised = false
      try:
        discard resolveProfilePackage("php", linux, @[rkTarball, rkNix])
      except EPlatformUnavailable as err:
        checkpoint "undeclared package gained a platform gate: " & err.msg
        check false
      except EMissingRealization as err:
        raised = true
        check err.packageName == "php"
        check err.definitionKnown
        check err.msg.contains("no realization of package 'php'")
        check err.msg.contains("x86_64-linux")
      check raised

    # ---- (4b) PMC-5: a DECLARED windows-only entry fails with a reason ---
    block declaredWindowsOnlyEntry:
      var raised = false
      try:
        discard resolveProfilePackage("innounp", linux, @[rkTarball, rkNix])
      except EPlatformUnavailable as err:
        raised = true
        check err.packageName == "innounp"
        # Named, not merely refused -- PMC-1's whole point.
        check err.msg.contains("windows")
      except EMissingRealization:
        checkpoint "innounp is declared but reached the policy; the " &
          "declaration is not reaching the gate"
        check false
      check raised

    # ---- (5) nix-only entry: not gated ----------------------------------
    block nixOnlyEntry:
      let viaNix = resolveProfilePackage("atk", linux, @[rkNix, rkTarball])
      check viaNix.selection.kind == rkNix
      var raised = false
      try:
        discard resolveProfilePackage("atk", linux, @[rkTarball])
      except EPlatformUnavailable as err:
        checkpoint "nix-only package gained a platform gate: " & err.msg
        check false
      except EMissingRealization as err:
        raised = true
        check err.packageName == "atk"
        check err.msg.contains("no tarball realization declared")
      check raised
