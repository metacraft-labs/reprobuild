## Platform-And-Microarchitecture-Constraints PMC-3 — a level and its feature
## set are the SAME statement.
##
## The milestone's argument for keeping levels is that they are "named
## shorthands for common sets, which is what the psABI levels already are".
## That is only true if the shorthand cannot disagree with what it abbreviates.
## The moment an arm declaring ``x86-64-v3`` and an arm declaring v3's
## twenty-five features can select differently on one host, the level has
## stopped being sugar and become a SECOND SOURCE OF TRUTH — and a second
## source of truth about which instructions a binary may execute is a SIGILL
## with extra steps.
##
## The normalisation direction is what makes this hold, and it is asserted
## here rather than merely documented. PMC-3 normalises **level → set**:
## ``featuresForLevel`` is total and exact, ``requiredFeatures`` /
## ``providedFeatures`` expand both sides, and ``selectPlatformBinaryEx``
## performs ONE subset test on the results. The inverse direction was
## deliberately not built — most feature sets correspond to no level, so
## set → level would have to round DOWN and would discard exactly the sharp
## requirement being checked.
##
## Asserted here:
##
##   1. over the full matrix of {four levels} × {every host level} × {every
##      host spelled as an explicit feature set}, a catalog whose single arm
##      declares ``cpu_level: L`` and a catalog whose single arm declares
##      ``cpu_features: featuresForLevel(L)`` produce the SAME resolution —
##      the same found/refused verdict, the same URL, and the same missing
##      set;
##   2. the same over the resolution ENTRY POINT, not just the selector, so
##      the equivalence is what a caller observes and not an internal detail;
##   3. an arm declaring BOTH (level L and L's own set) is equivalent to
##      either alone — the union of a set with itself;
##   4. the two spellings are indistinguishable to the RANKING step as well as
##      the filter step: put them in one catalog and neither can outrank the
##      other, so which one is selected is decided by declaration order, as it
##      would be for two identical arms;
##   5. the equivalence is structural — ``requiredFeatures`` maps both
##      spellings onto one value, so there is no second code path that could
##      drift;
##   6. and the inverse reduction really is absent, stated as a property of
##      the vocabulary: there exist sets naming no level, which is why
##      set → level could not have been the direction.
##
## Falsifiable: removing the ``featuresForLevel`` term from
## ``requiredFeatures`` fails (1) on every level and reports which host it
## disagreed on; removing the ``cpu_features`` term fails it too.
##
## What this test deliberately does NOT catch, stated because the omission
## looks like a gap and is in fact the property: **changing what a level
## CONTAINS.** Dropping ``avx2`` from ``featuresForLevel(mlX86_64_v3)`` leaves
## every assertion here passing — measured, not assumed — because both
## spellings read the same table, so they go on agreeing about a v3 that has
## become something else. That is exactly what "the level is sugar, not a
## second source of truth" means: this file pins the RELATIONSHIP, and the
## table's contents are pinned where they are observable, by
## ``t_missing_features_are_named_in_the_diagnostic``'s exact missing-feature
## list. A version of this test that also pinned the contents would be
## asserting ``featuresForLevel`` against a transcription of itself.
##
## Hermetic: synthetic catalogs, synthetic hosts through the defaulted
## parameters.

import std/[strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

const Url = "https://example.invalid/demo-1.0.0.tar.gz"
const Sha =
  "7777777777777777777777777777777777777777777777777777777777777777"

proc catalogWith(level: MicroarchLevel;
                 features: set[CpuFeature]): seq[VersionedProvisioning] =
  ## One catalog, one version, one arm — identical in EVERY field except how
  ## the capability requirement is spelled. Same URL and same digest on
  ## purpose: if the two spellings select alike, the resolutions must be
  ## indistinguishable rather than merely both-successful.
  @[
    initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = @[
        initPlatformBinary(cpu = pcX86_64, os = poLinux, url = Url,
          sha256 = Sha, cpu_level = level, cpu_features = features)
      ])
  ]

const RealLevels = [mlX86_64_v1, mlX86_64_v2, mlX86_64_v3, mlX86_64_v4]
const AllLevels = [mlNone, mlX86_64_v1, mlX86_64_v2, mlX86_64_v3,
                   mlX86_64_v4]

## Feature sets a host might state that do NOT correspond to any level —
## exactly the reason the feature axis exists. Included in the host matrix so
## the equivalence is checked against hosts the level ladder cannot describe.
const OffLadderHostFeatures = [
  X86_64_V3_Features + {cfAvx512f, cfAvx512vl},
  X86_64_V2_Features + {cfAvx512f},
  X86_64_V3_Features + {cfAvx512Vnni, cfAvx512Bf16},
  X86_64_V1_Features + {cfAes, cfSha},
  X86_64_V4_Features + {cfAvx512Vnni},
]

suite "PMC-3 — a level and its feature set select alike":

  test "t_level_and_its_equivalent_feature_set_select_alike":

    # ---- the host matrix -------------------------------------------------
    #
    # Every host stated as a level, every host stated as that level's set
    # spelled out (no level at all), and five hosts that no level can
    # describe. If the shorthand and the expansion can ever disagree, one of
    # these coordinates finds it.
    var hosts: seq[tuple[label: string; target: PlatformTarget]] = @[]
    for hl in AllLevels:
      hosts.add((describeMicroarchLevel(hl) & "-as-level",
                 initPlatformTarget(pcX86_64, hl)))
      hosts.add((describeMicroarchLevel(hl) & "-as-features",
                 initPlatformTarget(pcX86_64, mlNone,
                                    featuresForLevel(hl))))
    for i, fs in OffLadderHostFeatures:
      hosts.add(("off-ladder-" & $i,
                 initPlatformTarget(pcX86_64, mlNone, fs)))

    # ---- (1) + (2) + (3) the equivalence ---------------------------------
    for level in RealLevels:
      let asLevel = catalogWith(level, {})
      let asFeatures = catalogWith(mlNone, featuresForLevel(level))
      let asBoth = catalogWith(level, featuresForLevel(level))

      # (5) structural: one value, not two that agree.
      check requiredFeatures(asLevel[0].platforms[0]) ==
        requiredFeatures(asFeatures[0].platforms[0])
      check requiredFeatures(asBoth[0].platforms[0]) ==
        requiredFeatures(asLevel[0].platforms[0])
      check armCapabilityRank(asLevel[0].platforms[0]) ==
        armCapabilityRank(asFeatures[0].platforms[0])

      # All three spellings are well-formed. (Declaring both is legal and
      # means the union; here the union is with itself, so the validator
      # emits the redundancy WARNING and no error.)
      check validateVersionedProvisioning(asLevel[0]).len == 0
      check validateVersionedProvisioning(asFeatures[0]).len == 0
      check validateVersionedProvisioning(asBoth[0]).len == 0

      for h in hosts:
        let label = describeMicroarchLevel(level) & " on " & h.label

        # (1) the selector.
        let selL = selectPlatformBinaryEx(asLevel[0], h.target, poLinux)
        let selF = selectPlatformBinaryEx(asFeatures[0], h.target, poLinux)
        let selB = selectPlatformBinaryEx(asBoth[0], h.target, poLinux)
        if selL.found != selF.found:
          checkpoint label & ": level arm " &
            (if selL.found: "selected" else: "refused") &
            " but feature arm " &
            (if selF.found: "selected" else: "refused") &
            " — the shorthand and its expansion disagree"
        check selL.found == selF.found
        check selL.found == selB.found
        check selL.binary.url == selF.binary.url
        if not selL.found:
          if selL.missingFeatures != selF.missingFeatures:
            checkpoint label & ": level arm missing {" &
              describeCpuFeatures(selL.missingFeatures) &
              "}, feature arm missing {" &
              describeCpuFeatures(selF.missingFeatures) & "}"
          check selL.missingFeatures == selF.missingFeatures
          check selL.missingFeatures == selB.missingFeatures
          check selL.refusedForLevel == selF.refusedForLevel
          # The FEATURE list is identical; only the level SUMMARY can
          # differ, because the feature-only arm has no level to name. That
          # is a rendering difference, not a selection one, and it is the
          # honest one — an arm that never mentioned v3 should not be
          # reported as needing v3.
          check describeFeatureShortfall(selL) ==
            describeFeatureShortfall(selF)

        # (2) the resolution entry point, which is what a caller sees.
        let resL = resolveBuiltinPackage("demo", asLevel, "", pcX86_64,
          poLinux, h.target.level, h.target.features)
        let resF = resolveBuiltinPackage("demo", asFeatures, "", pcX86_64,
          poLinux, h.target.level, h.target.features)
        check resL.found == resF.found
        check resL.error == resF.error
        check resL.resolution.urlUsed == resF.resolution.urlUsed
        check resL.resolution.digestValue == resF.resolution.digestValue

    # ---- (4) indistinguishable to the RANKING step too --------------------
    #
    # Filtering alike is half the property. If one spelling ranked higher
    # than the other, a catalog carrying both would prefer one — and which
    # one it preferred would be an observable difference between a shorthand
    # and its expansion.
    block rankingCannotTellThemApart:
      let level = mlX86_64_v3
      let levelArm = initPlatformBinary(cpu = pcX86_64, os = poLinux,
        url = "https://example.invalid/as-level.tar.gz", sha256 = Sha,
        cpu_level = level)
      let featureArm = initPlatformBinary(cpu = pcX86_64, os = poLinux,
        url = "https://example.invalid/as-features.tar.gz", sha256 = Sha,
        cpu_features = featuresForLevel(level))
      proc twoArms(arms: seq[PlatformBinary]): VersionedProvisioning =
        initVersionedProvisioning(
          version = "1.0.0", archive_format = afTarGz,
          install_method = imExtract, bin_relpath = @["bin/demo"],
          platforms = arms)

      let v3Host = initPlatformTarget(pcX86_64, mlX86_64_v3)
      # Declaration order decides, exactly as it would for two arms that are
      # identical — which, on the axis selection reads, these are.
      check selectPlatformBinaryEx(twoArms(@[levelArm, featureArm]),
        v3Host, poLinux).binary.url ==
        "https://example.invalid/as-level.tar.gz"
      check selectPlatformBinaryEx(twoArms(@[featureArm, levelArm]),
        v3Host, poLinux).binary.url ==
        "https://example.invalid/as-features.tar.gz"

      # The validator agrees they are different DECLARATIONS (the
      # uniqueness key separates them, so a catalog may carry both) while
      # selection cannot tell them apart. Those are the right two answers:
      # authoring is about what was written, selection about what it means.
      check validateVersionedProvisioning(
        twoArms(@[levelArm, featureArm])).len == 0

    # ---- (6) the inverse reduction is absent, and had to be --------------
    block noSetToLevelReduction:
      # A set that is a strict superset of v3 and a strict subset of v4:
      # every level is either too weak to describe it or too strong. Any
      # set → level normalisation would have to round to v3 and DISCARD the
      # AVX-512 requirement — the exact failure the milestone exists to
      # prevent, reintroduced by the normalisation meant to unify the axes.
      let sharp = X86_64_V3_Features + {cfAvx512f}
      check X86_64_V3_Features < sharp
      check sharp < X86_64_V4_Features
      for level in AllLevels:
        check featuresForLevel(level) != sharp

      # An arm requiring it is refused on a plain v3 host, which is only
      # possible because nothing rounded it down.
      let cat = catalogWith(mlNone, sharp)
      let sel = selectPlatformBinaryEx(cat[0],
        initPlatformTarget(pcX86_64, mlX86_64_v3), poLinux)
      check not sel.found
      check sel.missingFeatures == {cfAvx512f}
      check describeFeatureShortfall(sel) == "missing cpu features: avx512f"

      # And the vocabulary itself carries features no level names, which is
      # the structural reason the inverse is not a function.
      var unnamedByAnyLevel: set[CpuFeature] = {}
      for f in CpuFeature:
        if f notin X86_64_V4_Features:
          unnamedByAnyLevel.incl(f)
      check unnamedByAnyLevel != {}
      check cfAvx512Vnni in unnamedByAnyLevel
      check describeCpuFeatures(unnamedByAnyLevel).contains("avx512vnni")
