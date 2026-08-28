## Platform-And-Microarchitecture-Constraints PMC-3 — compatibility is
## ``required ⊆ provided``, and one missing feature refuses.
##
## PMC-2 made the CPU axis an ORDER. That is enough for the psABI levels,
## which form a linear chain, and not enough for anything else: AVX-512 is not
## a level, it is a FAMILY of extensions that real silicon carries in subsets.
## Ice Lake has ``avx512vnni`` and ``avx512vbmi``; Zen 4 has ``avx512bf16``;
## neither is "above" the other and no psABI level names any of them. A ladder
## cannot say "this build needs avx512vl and avx512vnni", so an artifact that
## needs exactly that either lies about its requirement or goes unexpressed —
## and an unexpressed requirement is the ``SIGILL`` this campaign exists to
## prevent, arriving in someone else's build far from its cause.
##
## So this file pins the SET semantics, in both directions:
##
##   1. a required set that is a subset of what the host provides SELECTS,
##      including when the host provides strictly more;
##   2. removing ONE feature from the host refuses — not "some features are
##      missing" but that single one is enough;
##   3. the level and feature axes are ONE comparison, not two that agree:
##      ``satisfiesFloor`` is asserted equal to the subset test on the expanded
##      sets over the whole 5×5 level matrix, and PMC-2's two asymmetric
##      ``mlNone`` rules are re-derived from the sets rather than restated;
##   4. an arm declaring BOTH a level and extra features requires their UNION;
##   5. among arms the host CAN run, the most demanding one wins — "refuses
##      what it cannot run" and "picks the best it can run" are different
##      properties and the first passes trivially if selection is broken
##      toward the floor;
##   6. incomparable requirements (v3+avx512f vs v3+avx512vnni, both
##      satisfiable) tie and fall to first-declared rather than inventing a
##      preference between two optimised builds;
##   7. HOST FEATURE DETECTION — PMC-3's first deliverable: the declaration
##      variable, the real ``cpuid`` probe behind ``auto``, and the
##      DEFAULT-PARAMETER seam that carries either into selection without
##      selection ever reading the environment itself;
##   8. the standard library is still in the levelless AND featureless class,
##      and every registered catalog still round-trips byte-identically through
##      ``serializeAsCode`` — the "emit a new field only when non-default" rule
##      PMC-2 established, extended to ``cpu_features``.
##
## Falsifiable — each of these was applied, the failure observed, the source
## restored: change ``satisfiesFeatures``'s ``<=`` to ``==`` and (1) fails on
## every strict-superset host. Drop the ``cpu_features`` term from
## ``requiredFeatures`` and (2) and (4) fail. Invert the same-tier capability
## comparison in ``selectPlatformBinaryEx`` and (5) fails. Disable the
## validator's feature-family check and (4) fails; revert the duplicate-slice
## key to (cpu, os, level) and (5)'s fixture fails validation. Stub
## ``resolveBuiltinPackage``'s ``hostFeatures`` default to ``{}`` and (7)
## fails while everything else here still passes — which is what makes (7)
## cover the seam rather than the arithmetic behind it. Emit ``cpu_features``
## unconditionally in ``serializePlatformBinary`` and (8) fails on every
## registered catalog.
##
## Hermetic: synthetic catalogs, synthetic host targets through the defaulted
## ``hostCpu`` / ``hostOs`` / ``hostLevel`` / ``hostFeatures`` parameters. No
## AVX-512 hardware, and — as (3) shows by construction — no host probing at
## all.

import std/[options, os, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry
import repro_home_apply/package_catalog

const Sha =
  "5555555555555555555555555555555555555555555555555555555555555555"

proc arm(tag: string; level = mlNone;
         features: set[CpuFeature] = {}): PlatformBinary =
  ## A distinguishable x86_64/linux arm. The URL carries a tag so a mismatch
  ## reports WHICH arm was picked rather than merely "not equal".
  initPlatformBinary(cpu = pcX86_64, os = poLinux,
    url = "https://example.invalid/" & tag & ".tar.gz",
    sha256 = Sha, cpu_level = level, cpu_features = features)

proc fixture(arms: seq[PlatformBinary]): seq[VersionedProvisioning] =
  @[
    initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = arms)
  ]

proc host(level = mlNone; features: set[CpuFeature] = {}): PlatformTarget =
  initPlatformTarget(pcX86_64, level, features)

const AllLevels = [mlNone, mlX86_64_v1, mlX86_64_v2, mlX86_64_v3, mlX86_64_v4]

suite "PMC-3 — required features are a subset of host features":

  test "t_required_features_are_a_subset_of_host_features":

    # ---- (1) subset selects, including a strict superset host -----------
    block subsetSelects:
      # The shape no level can express: v3 plus two AVX-512 extensions.
      let cat = fixture(@[arm("avx512-slice", mlX86_64_v3,
        {cfAvx512f, cfAvx512vl})])

      # Exactly satisfied.
      let exact = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v3, {cfAvx512f, cfAvx512vl})
      check exact.found
      check exact.resolution.urlUsed ==
        "https://example.invalid/avx512-slice.tar.gz"
      check exact.resolution.builtinCpuLevel == mlX86_64_v3
      check exact.resolution.builtinCpuFeatures == {cfAvx512f, cfAvx512vl}

      # Strictly MORE than required. A subset test must accept this; an
      # equality test would not, and equality is the shape every other axis
      # in this schema has, so it is the plausible wrong implementation.
      let superset = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v4, {cfAvx512Vnni, cfAvx512Bf16, cfSha})
      check superset.found
      check superset.resolution.urlUsed ==
        "https://example.invalid/avx512-slice.tar.gz"

      # A host stating the same capability WITHOUT the level shorthand:
      # v3's set spelled out, plus the two extensions. Same answer, because
      # the comparison is on the expanded sets and nothing downstream can
      # tell which spelling produced them.
      let spelledOut = resolveBuiltinPackage("demo", cat, "", pcX86_64,
        poLinux, mlNone, X86_64_V3_Features + {cfAvx512f, cfAvx512vl})
      check spelledOut.found
      check spelledOut.resolution.urlUsed ==
        "https://example.invalid/avx512-slice.tar.gz"

    # ---- (2) ONE missing feature refuses --------------------------------
    block oneMissingFeatureRefuses:
      let cat = fixture(@[arm("avx512-slice", mlX86_64_v3,
        {cfAvx512f, cfAvx512vl})])

      # Drop exactly one of the two required extensions. Everything else the
      # arm asks for is present.
      let short = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v3, {cfAvx512f})
      check not short.found
      check short.error == breMicroarchFloorNotSatisfied
      check short.resolution.urlUsed == ""

      # And the shortfall is that one feature, not a vague "some".
      let sel = selectPlatformBinaryEx(cat[0], host(mlX86_64_v3,
        {cfAvx512f}), poLinux)
      check not sel.found
      check sel.refusedForLevel
      check sel.missingFeatures == {cfAvx512vl}
      check sel.requiredFeatures == X86_64_V3_Features +
        {cfAvx512f, cfAvx512vl}

      # Drop the other one instead: symmetric, and it proves the check is
      # not keyed on one privileged member of the set.
      let otherSel = selectPlatformBinaryEx(cat[0], host(mlX86_64_v3,
        {cfAvx512vl}), poLinux)
      check otherSel.missingFeatures == {cfAvx512f}

      # A host below the LEVEL half of the same requirement is short of the
      # level's features too — one requirement, not two checks.
      let belowLevel = selectPlatformBinaryEx(cat[0], host(mlX86_64_v2,
        {cfAvx512f, cfAvx512vl}), poLinux)
      check not belowLevel.found
      check belowLevel.missingFeatures ==
        X86_64_V3_Features - X86_64_V2_Features

    # ---- (3) the two axes really are ONE comparison ----------------------
    #
    # ``satisfiesFloor`` is PMC-2's level ordering. PMC-3 re-implemented it as
    # the subset test on the EXPANDED sets rather than leaving an ``ord``
    # comparison beside it. This block asserts the identity over the whole
    # matrix, which is what turns "they agree" from a coincidence maintained
    # by hand into a property of ``featuresForLevel``.
    block oneComparison:
      for hostLevel in AllLevels:
        for floor in AllLevels:
          check satisfiesFloor(hostLevel, floor) ==
            satisfiesFeatures(featuresForLevel(hostLevel),
                              featuresForLevel(floor))
          # And PMC-2's ordinal rule, re-derived from the sets: for two REAL
          # levels the psABI sets are strictly nested, so subset and >= are
          # the same relation.
          if hostLevel != mlNone and floor != mlNone:
            check satisfiesFloor(hostLevel, floor) ==
              (ord(hostLevel) >= ord(floor))

      # PMC-2's two asymmetric ``mlNone`` rules, as consequences of the sets
      # rather than as special cases restated in a second place.
      check featuresForLevel(mlNone) == {}
      for hostLevel in AllLevels:
        # "no floor is satisfied everywhere, including on a host that has
        # stated nothing" — because {} is a subset of everything.
        check satisfiesFloor(hostLevel, mlNone)
      for floor in AllLevels:
        # "an unstated host satisfies no declared floor" — because a real
        # level expands to a non-empty set and nothing is a subset of {}.
        check satisfiesFloor(mlNone, floor) == (floor == mlNone)

      # The nesting the whole reduction rests on. If a future psABI revision
      # broke it, the level ORDER would stop being the subset relation and
      # this test — not a user's SIGILL — would say so.
      check X86_64_V1_Features < X86_64_V2_Features
      check X86_64_V2_Features < X86_64_V3_Features
      check X86_64_V3_Features < X86_64_V4_Features

    # ---- (4) level + features on one arm means the UNION -----------------
    block levelPlusFeaturesIsUnion:
      let both = arm("both", mlX86_64_v2, {cfAvx512f})
      check requiredFeatures(both) == X86_64_V2_Features + {cfAvx512f}

      # Neither half alone satisfies it.
      let cat = fixture(@[both])
      check not selectPlatformBinaryEx(cat[0],
        host(mlX86_64_v2), poLinux).found
      check not selectPlatformBinaryEx(cat[0],
        host(mlNone, {cfAvx512f}), poLinux).found
      check selectPlatformBinaryEx(cat[0],
        host(mlX86_64_v2, {cfAvx512f}), poLinux).found

      # The combination is LEGAL — the validator must not reject the shape
      # the milestone exists for.
      check validateVersionedProvisioning(fixture(@[both])[0]).len == 0

      # Restating what the level already implies is redundant, not wrong:
      # still zero errors, but a warning, because an author who believes the
      # two fields are alternatives rather than a union is one edit away
      # from a real mistake.
      let redundant = arm("redundant", mlX86_64_v3, {cfAvx, cfAvx512f})
      var warnings: seq[string] = @[]
      check validatePlatformBinaryEx(redundant, 0, warnings).len == 0
      check warnings.len == 1
      check warnings[0].contains("already implied by cpu_level x86-64-v3")
      check warnings[0].contains("avx")
      # ...and it names ONLY the redundant member.
      check not warnings[0].contains("avx512f")

      # A feature from another family is a CONTRADICTION, exactly as a
      # cpu_level from another family is: never selectable, and at the point
      # of failure indistinguishable from a missing arm.
      let alien = initPlatformBinary(cpu = pcAArch64, os = poLinux,
        url = "https://example.invalid/alien.tar.gz", sha256 = Sha,
        cpu_features = {cfAvx})
      let alienErrors = validatePlatformBinary(alien, 0)
      check alienErrors.len == 1
      check alienErrors[0].contains("cpu_features avx")
      check alienErrors[0].contains("belong to cpu family x86_64")

      # And the same rule for ``pcAny``, which is load-bearing rather than
      # tidy: a host whose family is unrecognised provides {} under the
      # subset check, so a capability-carrying ``pcAny`` arm would be
      # REFUSED on it — while PMC-1's rule is that an unrecognised family
      # fails OPEN. Forbidding the combination at authoring time is what
      # keeps the campaign's two opposite failure directions from meeting.
      let anyWithFeatures = initPlatformBinary(cpu = pcAny, os = poLinux,
        url = "https://example.invalid/anyfeat.tar.gz", sha256 = Sha,
        cpu_features = {cfAvx2})
      check validatePlatformBinary(anyWithFeatures, 0).len == 1

    # ---- (5) among what it CAN run, the most demanding arm wins ----------
    block bestSatisfiableWins:
      # Declared LEAST demanding first, so an implementation that simply
      # takes the first survivor is caught.
      let cat = fixture(@[
        arm("plain", mlX86_64_v3),
        arm("avx512f", mlX86_64_v3, {cfAvx512f}),
        arm("avx512f-vl", mlX86_64_v3, {cfAvx512f, cfAvx512vl})])

      # Three slices at ONE (cpu, os, cpu_level) differing only in features is
      # exactly the shape the feature axis exists to express, so the
      # duplicate-slice uniqueness key must separate them. Without this the
      # validator rejects the fixture before selection ever sees it — the
      # same trap PMC-2 hit when the key omitted ``cpu_level``, and it reads
      # like housekeeping right up until it makes the feature axis unusable.
      check validateVersionedProvisioning(cat[0]).len == 0

      # A host with neither extension can run only the plain arm.
      let plainHost = selectPlatformBinaryEx(cat[0], host(mlX86_64_v3),
        poLinux)
      check plainHost.found
      check plainHost.binary.url == "https://example.invalid/plain.tar.gz"

      # One extension: the middle arm becomes reachable and outranks plain.
      let oneExt = selectPlatformBinaryEx(cat[0],
        host(mlX86_64_v3, {cfAvx512f}), poLinux)
      check oneExt.binary.url == "https://example.invalid/avx512f.tar.gz"

      # Both: the most demanding one.
      let bothExt = selectPlatformBinaryEx(cat[0],
        host(mlX86_64_v3, {cfAvx512f, cfAvx512vl}), poLinux)
      check bothExt.binary.url ==
        "https://example.invalid/avx512f-vl.tar.gz"

      # Filtering happens BEFORE ranking: an unsatisfiable arm must be
      # invisible, not merely outranked. Below v3 nothing here is reachable
      # even though the demanding arms are the "most specific".
      let belowAll = selectPlatformBinaryEx(cat[0], host(mlX86_64_v2),
        poLinux)
      check not belowAll.found
      check belowAll.refusedForLevel

    # ---- (6) incomparable requirements tie, first declared wins ----------
    block incomparableRequirementsTie:
      # Neither requirement contains the other and both are satisfied. There
      # is nothing in the model that says which optimised build is better,
      # so the answer is the declaration order — an invented preference here
      # would be a silent policy decision.
      let forward = fixture(@[
        arm("vnni", mlX86_64_v3, {cfAvx512Vnni}),
        arm("bf16", mlX86_64_v3, {cfAvx512Bf16})])
      let backward = fixture(@[
        arm("bf16", mlX86_64_v3, {cfAvx512Bf16}),
        arm("vnni", mlX86_64_v3, {cfAvx512Vnni})])
      let rich = host(mlX86_64_v3, {cfAvx512Vnni, cfAvx512Bf16})
      check selectPlatformBinaryEx(forward[0], rich, poLinux).binary.url ==
        "https://example.invalid/vnni.tar.gz"
      check selectPlatformBinaryEx(backward[0], rich, poLinux).binary.url ==
        "https://example.invalid/bf16.tar.gz"
      check armCapabilityRank(forward[0].platforms[0]) ==
        armCapabilityRank(forward[0].platforms[1])

    # ---- (7) host FEATURE DETECTION, and the seam it comes through -------
    #
    # PMC-3's first deliverable. Three things are pinned, and the third is
    # the one the campaign's testability note cares about:
    #
    #   * the DECLARATION path — ``REPRO_HOST_CPU_FEATURES`` as a list, with
    #     an unreadable value REFUSED rather than defaulted, because a
    #     dropped feature would silently change which artifacts this machine
    #     accepts with no error anywhere (the rule
    #     ``REPRO_HOST_MICROARCH_LEVEL`` already follows);
    #   * the PROBE path — ``auto`` runs real ``cpuid``. Asserted against the
    #     one thing that is true of every amd64 chip by definition: it
    #     provides at least the ``x86-64-v1`` baseline. That is a real
    #     assertion on real silicon and it is still host-independent;
    #   * the DEFAULT-PARAMETER seam — the env var reaches
    #     ``resolveBuiltinPackage`` through its defaulted ``hostFeatures``,
    #     which the call in that block deliberately does not pass. Without
    #     this the parameter could be plumbed correctly and the default
    #     wired to nothing, and every other block here would still pass.
    #
    # Why the probe is NOT the default is a policy decision rather than an
    # omission, and it is asserted too: an unset variable declares NOTHING,
    # so the conservative floor PMC-2 chose survives PMC-3 on a machine that
    # can demonstrably run more.
    block hostFeatureDetection:
      let v3PlusVl = fixture(@[arm("needs-vl", mlX86_64_v3, {cfAvx512vl})])

      # No override: declare nothing. The v1 baseline plus nothing does not
      # satisfy a v3+avx512vl arm even on a machine that could run it.
      delEnv(HostCpuFeaturesEnvVar)
      check detectHostCpuFeatures(pcX86_64) == {}
      check detectHostTarget().features == {}

      # The probe, run explicitly. Every amd64 CPU implements x86-64-v1 by
      # definition — that is why ``baselineMicroarchLevel`` can answer v1
      # without probing — so this is a non-vacuous check that the cpuid path
      # actually read something.
      when defined(amd64):
        let probed = probeHostCpuFeatures()
        check probed != {}
        check satisfiesFeatures(probed, X86_64_V1_Features)
        # The OS-state gate: AVX is only reported when the OS enabled the
        # register state for it, so AVX without OSXSAVE is a combination
        # this probe must never produce.
        if cfAvx in probed:
          check cfOsxsave in probed
        # ...and the AVX-512 family is gated behind AVX for the same reason.
        if cfAvx512f in probed:
          check cfAvx in probed

      # ``auto`` routes the probe through the declaration variable.
      putEnv(HostCpuFeaturesEnvVar, "auto")
      when defined(amd64):
        check detectHostCpuFeatures(pcX86_64) == probeHostCpuFeatures()
      # A probe request for a family that is not the compiled one answers
      # {} rather than handing this machine's x86 features to an aarch64
      # resolution — the same reason ``detectHostMicroarchLevel`` depends on
      # the family.
      check detectHostCpuFeatures(pcAArch64) == {}

      # An explicit list, in the psABI spellings, separator-insensitive.
      putEnv(HostCpuFeaturesEnvVar, "avx512vl, avx512vnni")
      check detectHostCpuFeatures(pcX86_64) == {cfAvx512vl, cfAvx512Vnni}
      putEnv(HostCpuFeaturesEnvVar, "avx512vl+avx512vnni")
      check detectHostCpuFeatures(pcX86_64) == {cfAvx512vl, cfAvx512Vnni}

      # THE SEAM: no ``hostFeatures`` argument here. The declaration has to
      # reach selection through the default-parameter expression, and it is
      # ADDITIVE on top of the level rather than a replacement — this call
      # says v3 through one variable and avx512vl through another.
      putEnv(HostMicroarchLevelEnvVar, "v3")
      putEnv(HostCpuFeaturesEnvVar, "avx512vl")
      let viaDefaults = resolveBuiltinPackage("demo", v3PlusVl, "",
        pcX86_64, poLinux)
      check viaDefaults.found
      check viaDefaults.resolution.urlUsed ==
        "https://example.invalid/needs-vl.tar.gz"

      # Talked DOWN by dropping the feature half: the level alone is not
      # enough, and the same call now refuses. This is the "target a floor
      # below the builder" property PMC-2 built and PMC-4 depends on,
      # extended to the feature axis.
      delEnv(HostCpuFeaturesEnvVar)
      let talkedDown = resolveBuiltinPackage("demo", v3PlusVl, "",
        pcX86_64, poLinux)
      check not talkedDown.found
      check talkedDown.error == breMicroarchFloorNotSatisfied
      check talkedDown.errorDetail.contains("missing cpu features: avx512vl")

      # An unreadable value is REFUSED, not quietly defaulted.
      putEnv(HostCpuFeaturesEnvVar, "avx512vl,not-a-real-feature")
      expect ValueError:
        discard detectHostCpuFeatures(pcX86_64)
      # ...and so is a feature belonging to another family, which could
      # never be satisfied and would present as an unexplained refusal far
      # from the variable that caused it.
      putEnv(HostCpuFeaturesEnvVar, "avx2")
      expect ValueError:
        discard detectHostCpuFeatures(pcAArch64)

      delEnv(HostCpuFeaturesEnvVar)
      delEnv(HostMicroarchLevelEnvVar)

      # The token vocabulary itself: canonical psABI spellings round-trip,
      # separators are folded, and the aliases real sources use are
      # enumerated rather than guessed at.
      for f in CpuFeature:
        let round = parseCpuFeatureToken($f)
        check round.ok
        check round.feature == f
      check parseCpuFeatureToken("SSE4.1") == (true, cfSse4_1)
      check parseCpuFeatureToken("sse4_1") == (true, cfSse4_1)
      check parseCpuFeatureToken("cmpxchg16b") == (true, cfCx16)
      check parseCpuFeatureToken("lahf_lm") == (true, cfLahfSahf)
      check not parseCpuFeatureToken("avx1024").ok
      let bad = parseCpuFeatureSet("avx2, nope, avx512f")
      check not bad.ok
      check bad.badToken == "nope"
      check parseCpuFeatureSet("").features == {}

    # ---- (8) the stdlib premise, and the serialization rule --------------
    #
    # Every claim PMC-3 makes about "nothing that exists today changes" rests
    # on the standard library declaring no capability at all. PMC-2 asserted
    # that for ``cpu_level``; this asserts it for ``cpu_features`` and, in the
    # same pass, that the "emit only when non-default" serialization rule
    # holds — a serializer that emitted an empty ``cpu_features: {}`` would
    # rewrite all 259 checked-in catalogs and break the harvester's
    # idempotent-harvest property.
    block stdlibIsStillFeatureless:
      var toolsSeen = 0
      var armsSeen = 0
      for tool in RegisteredTools:
        let catOpt = getCatalog(tool)
        if catOpt.isNone:
          continue
        let cat = catOpt.get
        if cat.len == 0:
          continue
        inc toolsSeen
        for vp in cat:
          for pb in vp.platforms:
            inc armsSeen
            if pb.cpu_features != {}:
              checkpoint tool & " " & vp.version & " declares cpu_features " &
                describeCpuFeatures(pb.cpu_features) &
                " — this test's premise no longer holds for it"
            check pb.cpu_features == {}
            check requiredFeatures(pb) == {}
            check armCapabilityRank(pb) == 0
          # The serialized form must mention neither capability field.
          let code = serializeAsCode(vp)
          if code.contains("cpu_features"):
            checkpoint tool & " " & vp.version &
              " serializes a cpu_features field"
          check not code.contains("cpu_features")
          check not code.contains("cpu_level")
      check toolsSeen > 0
      check armsSeen > 0

      # The rule stated positively, so the block cannot pass by the
      # serializer having simply lost the ability to emit the field.
      let declaring = arm("declaring", mlX86_64_v3, {cfAvx512f, cfAvx512vl})
      let declaredCode = serializeAsCode(fixture(@[declaring])[0])
      check declaredCode.contains(
        "cpu_features: {cfAvx512f, cfAvx512vl}")
      check declaredCode.contains("cpu_level: mlX86_64_v3")
      # Enum order, not declaration order, so a re-harvest of an unchanged
      # catalog is byte-stable.
      let reversed = arm("declaring", mlX86_64_v3, {cfAvx512vl, cfAvx512f})
      check serializeAsCode(fixture(@[reversed])[0]) == declaredCode
