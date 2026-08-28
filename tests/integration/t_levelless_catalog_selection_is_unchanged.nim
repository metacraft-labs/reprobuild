## Platform-And-Microarchitecture-Constraints PMC-2 — for an entry declaring no
## microarchitecture level, selection is the pre-PMC-2 four-step
## exact-then-``any`` order, EXACTLY.
##
## This is the compatibility guarantee for the entire existing standard
## library, and it is a strong claim rather than a spot check: every catalog
## that exists today declares no level, so if the degenerate case moved at all,
## every package moved. PMC-1 shipped
## ``t_declared_platforms_change_no_existing_resolution`` to pin a
## representative slice against measured pre-change values; this test pins the
## ALGORITHM, over the whole registry.
##
## Method: ``legacySelectPlatformBinary`` below is a verbatim transcription of
## the four sequential loops ``selectPlatformBinary`` contained before PMC-2
## (``packages_schema.nim``, the "1. exact match; 2. (pcAny, os); 3. (cpu,
## poAny); 4. (pcAny, poAny)" comment). It is deliberately a SECOND
## implementation rather than a call into the first: comparing the new selector
## against itself would assert nothing. Both are then run over the same inputs
## and required to agree on the arm, not merely on whether one was found.
##
## Asserted here:
##   1. over hand-built catalogs covering every combination of the four tiers,
##      in several declaration orders, across the full (cpu × os) host matrix,
##      the new selector returns the IDENTICAL ``PlatformBinary`` — including
##      the ``pcAny`` host, whose fail-open behaviour PMC-1 documented and
##      PMC-2 must not disturb, and including two arms at ONE coordinate,
##      which is the only levelless shape that ties and so the only one that
##      exercises the fourth step (first declared wins);
##   2. the answer is independent of the host's microarchitecture level. A
##      levelless catalog resolves the same on a v1 host, a v4 host and a host
##      that has stated nothing — which is what makes the whole existing
##      stdlib immune to whatever ``detectHostMicroarchLevel`` reports;
##   3. every arm in every REGISTERED stdlib catalog declares ``mlNone``, so
##      (1) and (2) actually cover the stdlib rather than covering a class it
##      turns out not to be in;
##   4. over every registered stdlib catalog, every version slice, and the full
##      host matrix, the two implementations agree arm for arm;
##   5. the pre-PMC-2 two-argument ``selectPlatformBinary`` overload is still
##      the same function it was, so callers that were never taught about
##      levels are unaffected.
##
## Falsifiable, and both mutations were run: swap the ``(pcAny, os)`` and
## ``(cpu, poAny)`` cases in ``armPreferenceTier`` (the pair a plausible
## refactor would confuse) and (1) and (4) fail, naming the two arms. Drop the
## ``ord(pb.cpu_level) > ord(result.binary.cpu_level)`` guard from the
## same-tier branch of ``selectPlatformBinaryEx`` — which makes the LAST
## declared arm win a tie instead of the first — and (1) fails on the
## duplicate-coordinate fixtures below. It fails on NOTHING ELSE in this file,
## which is why those fixtures are here.
##
## Hermetic: no network, no PATH, no host probing — the host matrix is
## synthetic and passed as parameters.

import std/[options, unittest]

import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/catalog_registry

proc legacySelectPlatformBinary(vp: VersionedProvisioning;
                                cpu: PlatformCpu; os: PlatformOs):
    tuple[found: bool; binary: PlatformBinary] =
  ## Verbatim transcription of the pre-PMC-2 ``selectPlatformBinary``:
  ##   1. exact match (cpu, os);
  ##   2. (pcAny, os) fallback;
  ##   3. (cpu, poAny) fallback;
  ##   4. (pcAny, poAny) fallback.
  for pb in vp.platforms:
    if pb.cpu == cpu and pb.os == os:
      return (true, pb)
  for pb in vp.platforms:
    if pb.cpu == pcAny and pb.os == os:
      return (true, pb)
  for pb in vp.platforms:
    if pb.cpu == cpu and pb.os == poAny:
      return (true, pb)
  for pb in vp.platforms:
    if pb.cpu == pcAny and pb.os == poAny:
      return (true, pb)
  (false, PlatformBinary())

const AllCpus = [pcAny, pcX86_64, pcAArch64, pcX86]
const AllOses = [poAny, poWindows, poLinux, poMacos]
const AllLevels = [mlNone, mlX86_64_v1, mlX86_64_v2, mlX86_64_v3, mlX86_64_v4]

proc namedArm(cpu: PlatformCpu; os: PlatformOs; tag: string): PlatformBinary =
  ## A distinguishable levelless arm. The URL carries a tag so a mismatch
  ## reports WHICH arm was picked instead of just "not equal".
  initPlatformBinary(cpu = cpu, os = os,
    url = "https://example.invalid/" & tag & ".tar.gz",
    sha256 = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd")

proc fixture(arms: seq[PlatformBinary]): VersionedProvisioning =
  initVersionedProvisioning(
    version = "1.0.0",
    archive_format = afTarGz,
    install_method = imExtract,
    bin_relpath = @["bin/demo"],
    platforms = arms)

proc agreesEverywhere(vp: VersionedProvisioning; label: string) =
  ## (1) + (2): the two implementations must agree for every host coordinate,
  ## at every declared host level.
  for cpu in AllCpus:
    for os in AllOses:
      let expected = legacySelectPlatformBinary(vp, cpu, os)
      for level in AllLevels:
        let actual = selectPlatformBinaryEx(vp,
          initPlatformTarget(cpu, level), os)
        if actual.found != expected.found or
           (expected.found and actual.binary != expected.binary):
          checkpoint label & ": host " & $cpu & "-" & $os & " level " &
            describeMicroarchLevel(level) & " — legacy picked " &
            (if expected.found: expected.binary.url else: "<none>") &
            ", PMC-2 picked " &
            (if actual.found: actual.binary.url else: "<none>")
        check actual.found == expected.found
        if expected.found:
          check actual.binary == expected.binary
        # A levelless catalog can never report a floor shortfall: there is
        # no floor to fall short of.
        check not actual.refusedForLevel
      # (5) the two-argument overload is unchanged.
      let legacyApi = selectPlatformBinary(vp, cpu, os)
      check legacyApi.found == expected.found
      if expected.found:
        check legacyApi.binary == expected.binary

suite "PMC-2 — levelless catalog selection is unchanged":

  test "t_levelless_catalog_selection_is_unchanged":

    # ---- (1) hand-built catalogs across every tier combination ----------
    block handBuilt:
      let exact = namedArm(pcX86_64, poWindows, "tier0-exact")
      let anyCpu = namedArm(pcAny, poWindows, "tier1-any-cpu")
      let anyOs = namedArm(pcX86_64, poAny, "tier2-any-os")
      let anyAny = namedArm(pcAny, poAny, "tier3-any-any")
      let otherCpu = namedArm(pcAArch64, poWindows, "other-cpu")
      let otherOs = namedArm(pcX86_64, poLinux, "other-os")

      # Every subset of the four tiers, in declaration order and reversed.
      # The reversal is what shows the answer does not depend on the order
      # the arms are DECLARED in: the legacy loops return the first arm of
      # the first non-empty tier, whereas the PMC-2 selector scans every arm
      # and keeps the best rank, and those two shapes agree only if the rank
      # scan is genuinely order-independent.
      let tiers = @[exact, anyCpu, anyOs, anyAny]
      for mask in 0 ..< (1 shl tiers.len):
        var arms: seq[PlatformBinary] = @[]
        for i in 0 ..< tiers.len:
          if (mask and (1 shl i)) != 0:
            arms.add(tiers[i])
        if arms.len == 0:
          continue
        agreesEverywhere(fixture(arms), "mask " & $mask)
        var reversed: seq[PlatformBinary] = @[]
        for i in countdown(arms.len - 1, 0):
          reversed.add(arms[i])
        agreesEverywhere(fixture(reversed), "mask " & $mask & " reversed")

      # And with non-matching arms interleaved, which is the shape a real
      # multi-OS catalog has.
      agreesEverywhere(fixture(@[otherOs, otherCpu, exact, anyAny]),
        "interleaved")
      agreesEverywhere(fixture(@[anyAny, otherCpu, anyOs, otherOs]),
        "interleaved-any-first")

      # TWO ARMS AT ONE COORDINATE — the only levelless shape that produces
      # a TIE, and therefore the only fixture that can exercise the
      # first-declared tie-break at all. Every tier above corresponds to
      # exactly one (cpu, os) pair, so the fixtures above rank each arm
      # differently and a tie-break inversion passes them untouched. Without
      # these four the header's own falsification claim is not true, and the
      # tie-break — the last of the four steps
      # ``t_levelless_catalog_selection_is_unchanged`` exists to pin — is
      # pinned by nothing.
      #
      # ``validateVersionedProvisioning`` rejects a duplicate (cpu, os) pair,
      # so this shape cannot reach selection from a checked-in catalog. That
      # is not a reason to leave it unpinned: ``selectPlatformBinary`` is a
      # total function that callers reach directly (four test modules do),
      # the four sequential loops answered "the first one" for it, and a
      # selector that quietly started answering "the last one" would be a
      # behaviour change on the one input where it is invisible to the
      # validator.
      let exactAgain = namedArm(pcX86_64, poWindows, "tier0-exact-second")
      let anyCpuAgain = namedArm(pcAny, poWindows, "tier1-any-cpu-second")
      let anyAnyAgain = namedArm(pcAny, poAny, "tier3-any-any-second")
      agreesEverywhere(fixture(@[exact, exactAgain]), "duplicate-exact")
      agreesEverywhere(fixture(@[exactAgain, exact]),
        "duplicate-exact-reversed")
      agreesEverywhere(fixture(@[anyAny, anyAnyAgain]), "duplicate-any-any")
      agreesEverywhere(fixture(@[anyCpu, anyCpuAgain, exact, anyAnyAgain,
        anyAny]), "duplicates-among-tiers")

    # ---- (3) + (4) the real registry ------------------------------------
    block realStdlibCatalogs:
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
            # (3) the stdlib really is in the levelless class.
            if pb.cpu_level != mlNone:
              checkpoint tool & " " & vp.version & " declares cpu_level " &
                describeMicroarchLevel(pb.cpu_level) &
                " — this test's premise no longer holds for it"
            check pb.cpu_level == mlNone
          # (4) arm-for-arm agreement across the host matrix.
          agreesEverywhere(vp, tool & "@" & vp.version)
      # Guard against the loop silently covering nothing (an unimported
      # registry, an empty HashSet) and reporting a vacuous pass.
      check toolsSeen > 0
      check armsSeen > 0
