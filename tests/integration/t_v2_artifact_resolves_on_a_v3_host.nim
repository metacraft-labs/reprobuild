## Platform-And-Microarchitecture-Constraints PMC-2 (Package-Model.md
## §"The CPU axis, which is where a flat string breaks first") — compatibility
## on the microarchitecture axis is an ORDERING, not an equality.
##
## The flat ``PlatformCpu`` enum could only ask "is the host x86_64?". The psABI
## levels form a linear chain, so the question an artifact actually needs asked
## is "does the host reach the FLOOR I require?" — and a v2 artifact on a v3
## host is the case that distinguishes the two: equality says no, ordering says
## yes, and ordering is right, because v3 is a superset of v2.
##
## Asserted here:
##   1. a v2 arm resolves on a v3 host, and on a v4 host, and on a v2 host;
##   2. it does NOT resolve on a v1 host, so (1) is not passing because the
##      floor is being ignored — the single most likely way to "pass" this
##      milestone without implementing it;
##   3. it does not resolve on a host that has declared NO level. An unstated
##      host level is "unknown", not "v1": guessing upward here is the SIGILL
##      hazard the milestone exists to remove;
##   4. the selection is reported as a floor refusal, not as a missing arm, so
##      the caller can say WHICH of the two happened.
##
## Falsifiable: change ``satisfiesFloor`` to ``ord(hostLevel) == ord(floor)``
## (equality, the pre-PMC-2 shape of every other axis) and (1) fails for the v3
## and v4 hosts. Change it to ``true`` and (2), (3) and (4) fail.
##
## Hermetic: the catalog is built in this file and the host target is passed
## through ``resolveBuiltinPackage``'s DEFAULTED ``hostCpu`` / ``hostOs`` /
## ``hostLevel`` parameters, so no v2/v3 hardware is involved and the test runs
## identically on any machine. That seam is a stated requirement of the
## campaign, and this test is one of the things that would stop compiling if it
## were replaced by an ambient lookup.

import std/[strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

const V2Url = "https://example.invalid/demo-1.0.0-linux-x86-64-v2.tar.gz"
const V2Sha =
  "1111111111111111111111111111111111111111111111111111111111111111"

proc v2OnlyCatalog(): seq[VersionedProvisioning] =
  @[
    initVersionedProvisioning(
      version = "1.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = @[
        initPlatformBinary(cpu = pcX86_64, os = poLinux, url = V2Url,
          sha256 = V2Sha, cpu_level = mlX86_64_v2)
      ])
  ]

suite "PMC-2 — a v2 artifact resolves on a v3 host":

  test "t_v2_artifact_resolves_on_a_v3_host":
    let cat = v2OnlyCatalog()

    # ---- (1) the ordering: v2 <= v3, v2 <= v4, v2 <= v2 -----------------
    for provided in [mlX86_64_v2, mlX86_64_v3, mlX86_64_v4]:
      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        provided)
      checkpoint "host provides " & describeMicroarchLevel(provided)
      check r.found
      check r.error == breOk
      check r.resolution.urlUsed == V2Url
      check r.resolution.builtinVersion == "1.0.0"
      # The resolved arm's own floor is carried forward. PMC-4 reads this
      # field for the lock identity and the cache key; PMC-2 only records it.
      check r.resolution.builtinCpuLevel == mlX86_64_v2

    # ---- (2) below the floor: refused -----------------------------------
    block belowFloor:
      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v1)
      check not r.found
      check r.error == breMicroarchFloorNotSatisfied
      check r.errorDetail.contains(
        "needs x86-64-v2, host provides x86-64-v1")

    # ---- (3) a host that stated nothing is not treated as v1 ------------
    block unstatedHost:
      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlNone)
      check not r.found
      check r.error == breMicroarchFloorNotSatisfied
      check r.errorDetail.contains(
        "needs x86-64-v2, host provides no declared microarchitecture level")

    # ---- (4) refusal is distinguishable from a missing arm --------------
    block refusalIsNotAMiss:
      let refused = selectPlatformBinaryEx(cat[0],
        initPlatformTarget(pcX86_64, mlX86_64_v1), poLinux)
      check not refused.found
      check refused.refusedForLevel
      check refused.requiredLevel == mlX86_64_v2
      check describeMicroarchShortfall(refused) ==
        "needs x86-64-v2, host provides x86-64-v1"

      # A genuinely absent arm is the OTHER outcome and must not be
      # mislabelled as a microarchitecture shortfall: there is no Windows
      # slice at all here, at any level.
      let absent = selectPlatformBinaryEx(cat[0],
        initPlatformTarget(pcX86_64, mlX86_64_v4), poWindows)
      check not absent.found
      check not absent.refusedForLevel
      check describeMicroarchShortfall(absent) == ""

      let windowsMiss = resolveBuiltinPackage("demo", cat, "", pcX86_64,
        poWindows, mlX86_64_v4)
      check not windowsMiss.found
      check windowsMiss.error == brePlatformNotSupported
