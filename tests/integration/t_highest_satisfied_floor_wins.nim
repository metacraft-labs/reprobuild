## Platform-And-Microarchitecture-Constraints PMC-2 — selection picks the
## HIGHEST floor the host satisfies, not merely A floor it satisfies.
##
## "Refuses what it cannot run" and "picks the best it can run" are different
## properties, and the first passes trivially if selection is broken toward the
## floor: an implementation that always returns the v1 arm never resolves
## anything a host cannot run, and is useless. This test is the second
## property, on its own.
##
## Asserted here, over a catalog carrying v1, v2 and v3 arms for one
## (family, os):
##
##   1. a v3 host takes v3; a v2 host takes v2; a v1 host takes v1 — the
##      highest SATISFIED floor at each step of the chain;
##   2. a v4 host takes v3, the best available rather than nothing: the
##      ordering is "host >= floor", not "host == floor";
##   3. the answer does not depend on the order the arms are DECLARED in. The
##      pre-PMC-2 selector returned the first arm it saw in the first matching
##      tier, so an implementation that kept that shape and merely filtered
##      would pass (1) for one declaration order and fail it for the reverse;
##   4. a host that has declared no level takes NOTHING here, because every
##      arm declares a floor — the levelless-fallback rule must not sneak in
##      as a way to always have an answer;
##   5. an unsatisfiable arm cannot win by being more specific. With a v4 arm
##      at the exact (family, os) tier and a levelless arm at the ``pcAny``
##      tier, a v2 host takes the levelless one: the FILTER runs before the
##      preference order, which is what "filter to arms the host satisfies,
##      then take the highest floor" means.
##
## Falsifiable: change ``selectPlatformBinaryEx``'s tie-break from
## ``ord(pb.cpu_level) > ord(result.binary.cpu_level)`` to ``<`` and (1), (2)
## and (3) fail — selection breaks toward the floor. Move the
## ``satisfiesFloor`` check after the tier comparison and (5) fails.
##
## Hermetic: synthetic catalog, synthetic host levels through the defaulted
## parameters. No v2/v3/v4 hardware.

import std/[algorithm, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

const V1Url = "https://example.invalid/demo-3.0.0-linux-v1.tar.gz"
const V2Url = "https://example.invalid/demo-3.0.0-linux-v2.tar.gz"
const V3Url = "https://example.invalid/demo-3.0.0-linux-v3.tar.gz"
const AnyUrl = "https://example.invalid/demo-3.0.0-portable.tar.gz"
const Sha =
  "abababababababababababababababababababababababababababababababab"

proc arm(url: string; level: MicroarchLevel;
         cpu = pcX86_64; os = poLinux): PlatformBinary =
  initPlatformBinary(cpu = cpu, os = os, url = url, sha256 = Sha,
    cpu_level = level)

proc catalogWith(arms: seq[PlatformBinary]): seq[VersionedProvisioning] =
  @[
    initVersionedProvisioning(
      version = "3.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = arms)
  ]

suite "PMC-2 — the highest satisfied floor wins":

  test "t_highest_satisfied_floor_wins":
    let ascending = @[
      arm(V1Url, mlX86_64_v1),
      arm(V2Url, mlX86_64_v2),
      arm(V3Url, mlX86_64_v3)]
    var descending = ascending
    descending.reverse()

    # ---- (1)(2)(3) highest satisfied floor, in both declaration orders ---
    for order in [ascending, descending]:
      let cat = catalogWith(order)
      for expectation in [
          (host: mlX86_64_v1, url: V1Url, level: mlX86_64_v1),
          (host: mlX86_64_v2, url: V2Url, level: mlX86_64_v2),
          (host: mlX86_64_v3, url: V3Url, level: mlX86_64_v3),
          (host: mlX86_64_v4, url: V3Url, level: mlX86_64_v3)]:
        checkpoint "host provides " & describeMicroarchLevel(expectation.host)
        let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
          expectation.host)
        check r.found
        check r.resolution.urlUsed == expectation.url
        check r.resolution.builtinCpuLevel == expectation.level

    # ---- (4) an unstated host level takes nothing when every arm has a
    #          floor. There is no "levelless fallback" rule.
    block unstatedHostTakesNothing:
      let r = resolveBuiltinPackage("demo", catalogWith(ascending), "",
        pcX86_64, poLinux, mlNone)
      check not r.found
      check r.error == breMicroarchFloorNotSatisfied

    # ---- (5) the filter runs BEFORE the preference order ------------------
    block filterBeforePreference:
      # The v4 arm sits in the exact (family, os) tier — the tier the
      # pre-PMC-2 selector consulted first and returned from unconditionally.
      # The portable arm sits three tiers down. A v2 host must still take the
      # portable one, because the v4 arm is not merely less preferred, it is
      # unrunnable.
      let mixed = catalogWith(@[
        arm(V3Url, mlX86_64_v4),
        arm(AnyUrl, mlNone, cpu = pcAny, os = poAny)])
      let onV2 = resolveBuiltinPackage("demo", mixed, "", pcX86_64, poLinux,
        mlX86_64_v2)
      check onV2.found
      check onV2.resolution.urlUsed == AnyUrl
      check onV2.resolution.builtinCpuLevel == mlNone

      # On a v4 host the exact-tier arm wins again — the tier order is
      # intact for candidates that survive the filter, so (5) is about
      # reachability and not about having demoted the preference order.
      let onV4 = resolveBuiltinPackage("demo", mixed, "", pcX86_64, poLinux,
        mlX86_64_v4)
      check onV4.found
      check onV4.resolution.urlUsed == V3Url
      check onV4.resolution.builtinCpuLevel == mlX86_64_v4
