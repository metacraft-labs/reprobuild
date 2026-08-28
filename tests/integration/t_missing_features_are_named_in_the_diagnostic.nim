## Platform-And-Microarchitecture-Constraints PMC-3 — the refusal NAMES the
## missing features.
##
## The milestone states this acceptance criterion in the negative, and the
## negative is the point: *"a generic 'no matching arm' here puts us back
## exactly where PMC-1 started."* PMC-1's whole finding was that a resolution
## failure described the one situation the resolver could not distinguish from
## the real one, and sent the reader to a remedy that could not be followed.
## A feature shortfall reported as a failed match repeats that exactly — worse,
## in fact, because the artifact IS in the catalog and the reader can see it
## there.
##
## PMC-2's sentence ("needs x86-64-v3, host provides x86-64-v2") is not enough
## on its own for the case PMC-3 exists for. No psABI level names ``avx512vl``,
## so an arm requiring ``x86-64-v3 + avx512f + avx512vl`` refused on a v3 host
## has NO level shortfall at all — PMC-2's sentence would read "needs
## x86-64-v3, host provides x86-64-v3", which is not merely uninformative but
## actively contradicts the refusal.
##
## Asserted here:
##
##   1. the diagnostic names each missing feature, by its psABI spelling;
##   2. it names ONLY the missing ones — a feature the host already has is not
##      the reader's problem and listing it buries the line that is;
##   3. a PURE feature shortfall (no level involved anywhere) still produces a
##      named, non-empty refusal, which is the case PMC-2's renderer cannot
##      express;
##   4. a shortfall with a level names BOTH — the level summary, which matches
##      this org's runner labels, and the exact feature list;
##   5. the pre-PMC-2 "no platform slice for cpu=" phrasing does NOT appear;
##   6. the wording is pinned in one place (``describeFeatureShortfall`` /
##      ``describeCapabilityShortfall``) rather than asserted loosely against a
##      substring of a longer sentence;
##   7. the shortfall survives the adapter chain into the
##      ``EAdapterChainExhausted`` message a user actually reads — a refusal
##      that is correct at the frame that computes it and lost one frame later
##      has closed nothing;
##   8. among several unreachable arms the NEAREST is named — the smallest gap
##      the reader could actually close, which is PMC-2's "lowest floor" rule
##      generalised.
##
## Falsifiable: make ``describeFeatureShortfall`` return "" and (1)(3)(4)(6)
## fail. Make it list ``requiredFeatures`` instead of ``missingFeatures`` and
## (2) fails. Change ``selectPlatformBinaryEx`` to keep the LAST refused arm
## rather than the nearest and (8) fails.
##
## Hermetic: synthetic catalog, synthetic host through the defaulted
## parameters. No AVX-512 hardware.

import std/[options, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

const Sha =
  "6666666666666666666666666666666666666666666666666666666666666666"

proc arm(tag: string; level = mlNone;
         features: set[CpuFeature] = {}): PlatformBinary =
  initPlatformBinary(cpu = pcX86_64, os = poLinux,
    url = "https://example.invalid/" & tag & ".tar.gz",
    sha256 = Sha, cpu_level = level, cpu_features = features)

proc fixture(arms: seq[PlatformBinary]): seq[VersionedProvisioning] =
  @[
    initVersionedProvisioning(
      version = "3.1.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = arms)
  ]

proc host(level = mlNone; features: set[CpuFeature] = {}): PlatformTarget =
  initPlatformTarget(pcX86_64, level, features)

suite "PMC-3 — missing features are named in the diagnostic":

  test "t_missing_features_are_named_in_the_diagnostic":

    # ---- (1)(2)(3)(5)(6) a PURE feature shortfall ------------------------
    #
    # The arm needs v3 plus two AVX-512 extensions; the host IS v3 and has one
    # of them. There is no level shortfall — both sides are x86-64-v3 — so
    # everything the reader gets has to come from the feature list.
    block pureFeatureShortfall:
      let cat = fixture(@[arm("avx512", mlX86_64_v3,
        {cfAvx512f, cfAvx512vl, cfAvx512Vnni})])
      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v3, {cfAvx512f})

      check not r.found
      check r.error == breMicroarchFloorNotSatisfied

      # (6) the wording lives in one place.
      let sel = selectPlatformBinaryEx(cat[0],
        host(mlX86_64_v3, {cfAvx512f}), poLinux)
      check not sel.found
      check sel.refusedForLevel
      check sel.missingFeatures == {cfAvx512vl, cfAvx512Vnni}
      check sel.providedFeatures == X86_64_V3_Features + {cfAvx512f}
      check describeFeatureShortfall(sel) ==
        "missing cpu features: avx512vl, avx512vnni"
      # (3) PMC-2's renderer cannot express this case and stays silent
      # rather than emitting "needs x86-64-v3, host provides x86-64-v3" —
      # a line that would contradict the refusal it is explaining.
      check describeMicroarchShortfall(sel) == ""
      check describeCapabilityShortfall(sel) ==
        "missing cpu features: avx512vl, avx512vnni"

      # (1) each missing feature, by name, in what the user reads.
      check r.errorDetail.contains(describeCapabilityShortfall(sel))
      check r.errorDetail.contains("avx512vl")
      check r.errorDetail.contains("avx512vnni")
      # (2) and NOT the one the host already provides. No other feature
      # name has "avx512f" as a prefix except "avx512fp16", which this
      # fixture does not mention, so the substring test is exact here.
      check not describeCapabilityShortfall(sel).contains("avx512f")

      # (5) not the pre-PMC-2 phrasing. There IS a slice for this (cpu, os);
      # saying there is not sends the reader to look for a build that is
      # sitting in the catalog they are reading.
      check not r.errorDetail.contains("no platform slice for cpu=")
      check not r.errorDetail.contains("host provides x86-64-v3")

      # The package and version are still named — a shortfall with no
      # subject is not actionable in a build resolving dozens of packages.
      check r.errorDetail.contains("'demo'")
      check r.errorDetail.contains("'3.1.0'")

    # ---- (4) a shortfall with a level names BOTH halves -------------------
    block levelAndFeaturesTogether:
      let cat = fixture(@[arm("avx512", mlX86_64_v3, {cfAvx512f})])
      let sel = selectPlatformBinaryEx(cat[0], host(mlX86_64_v2), poLinux)
      check not sel.found

      # PMC-2's sentence, byte for byte — it is the actionable summary, it
      # is the vocabulary this org's runner labels use, and PMC-2 pins it.
      check describeMicroarchShortfall(sel) ==
        "needs x86-64-v3, host provides x86-64-v2"
      # ...plus every feature the host lacks, which is v3-minus-v2 AND the
      # AVX-512 extension no level names.
      check sel.missingFeatures ==
        (X86_64_V3_Features - X86_64_V2_Features) + {cfAvx512f}
      let combined = describeCapabilityShortfall(sel)
      check combined.startsWith("needs x86-64-v3, host provides x86-64-v2 (")
      check combined.contains("missing cpu features: ")
      check combined.contains("avx512f")
      check combined.contains("avx2")
      # Enum order, so the list is stable across runs and platforms.
      check combined.endsWith(
        "(missing cpu features: avx, avx2, bmi1, bmi2, f16c, fma, lzcnt, " &
        "movbe, osxsave, avx512f)")

    # ---- (7) the chain carries the new axis without changing flow --------
    #
    # ``hostFeatures`` is a fourth DEFAULTED parameter on
    # ``chainResolvePackage``, and the thing worth pinning about it is that
    # supplying one changes NOTHING for the standard library — every stdlib
    # arm requires ``{}``, and ``{} ⊆ anything``, so a host declaring an
    # exotic feature set must resolve exactly as a host declaring none. If it
    # did not, PMC-3 would have moved every existing package by adding a
    # field nobody uses.
    #
    # (The shortfall text's own trip through ``ChainStep.reason`` into
    # ``EAdapterChainExhausted`` is PMC-2's plumbing and is pinned by
    # ``t_platform_refusal_surfaces_through_realize_and_plan``; PMC-3 changed
    # only what that string SAYS, which the blocks above assert directly.)
    block chainCarriesTheAxisWithoutChangingFlow:
      var prod = openProductionCatalog()
      let plain = chainResolvePackage(prod, "gh", chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poLinux, hostLevel = mlX86_64_v3)
      let withFeatures = chainResolvePackage(prod, "gh",
        chain = @[cakBuiltin], hostCpu = pcX86_64, hostOs = poLinux,
        hostLevel = mlX86_64_v3,
        hostFeatures = {cfAvx512f, cfAvx512vl, cfAvx512Vnni, cfSha})
      check plain.adapter == cakBuiltin
      check plain.urlUsed.len > 0
      check withFeatures.urlUsed == plain.urlUsed
      check withFeatures.digestValue == plain.digestValue
      check withFeatures.resolvedVersion == plain.resolvedVersion
      check withFeatures.builtinCpuLevel == mlNone
      check withFeatures.builtinCpuFeatures == {}
      # And a host that declares nothing at all reaches the same arm, which
      # is the levelless/featureless guarantee stated on the entry point.
      let bare = chainResolvePackage(prod, "gh", chain = @[cakBuiltin],
        hostCpu = pcX86_64, hostOs = poLinux, hostLevel = mlNone,
        hostFeatures = {})
      check bare.urlUsed == plain.urlUsed

    # ---- (8) among several out of reach, the NEAREST is named -------------
    block nearestUnreachableArmIsNamed:
      # Declared FURTHEST first, so an implementation reporting "the last
      # unreachable arm it saw" is caught. The host is v3 with nothing extra.
      let cat = fixture(@[
        arm("far", mlX86_64_v4, {cfAvx512Vnni, cfAvx512Bf16, cfAvx512Fp16}),
        arm("near", mlX86_64_v3, {cfAvx512f}),
        arm("middle", mlX86_64_v4)])
      let sel = selectPlatformBinaryEx(cat[0], host(mlX86_64_v3), poLinux)
      check not sel.found
      check sel.refusedForLevel
      # One feature away, versus five and eight.
      check sel.missingFeatures == {cfAvx512f}
      check sel.requiredLevel == mlX86_64_v3
      # The arm declares v3 and the host IS v3, so nothing of the LEVEL is
      # missing and the level half stays silent — the only shortfall is the
      # extension, and that is all the reader is told.
      check describeMicroarchShortfall(sel) == ""
      check describeCapabilityShortfall(sel) ==
        "missing cpu features: avx512f"

      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v3)
      check not r.found
      check r.errorDetail.contains("missing cpu features: avx512f.")
      check not r.errorDetail.contains("avx512bf16")
      check not r.errorDetail.contains("avx512fp16")

      # PMC-2's level-only case is the same rule: nested floors against a
      # fixed host give nested missing-sets, so "fewest missing" IS "lowest
      # floor" and PMC-2's diagnostic is unchanged by the generalisation.
      let levelsOnly = fixture(@[
        arm("v4", mlX86_64_v4),
        arm("v3", mlX86_64_v3)])
      let levelSel = selectPlatformBinaryEx(levelsOnly[0],
        host(mlX86_64_v2), poLinux)
      check levelSel.requiredLevel == mlX86_64_v3
      check describeMicroarchShortfall(levelSel) ==
        "needs x86-64-v3, host provides x86-64-v2"

    # ---- a host that stated nothing keeps PMC-2's honest phrasing ---------
    block unstatedHost:
      let cat = fixture(@[arm("v3", mlX86_64_v3)])
      let sel = selectPlatformBinaryEx(cat[0], host(), poLinux)
      check not sel.found
      check sel.providedFeatures == {}
      check describeMicroarchShortfall(sel) ==
        "needs x86-64-v3, host provides no declared microarchitecture level"
      # It still names the features, because "declare your level" and "get a
      # better host" are different remedies and the list distinguishes them:
      # a reader who recognises every name as something their CPU has knows
      # the answer is the declaration.
      check describeFeatureShortfall(sel).startsWith("missing cpu features: ")
      check sel.missingFeatures == X86_64_V3_Features
