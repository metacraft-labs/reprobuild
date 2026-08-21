## Platform-And-Microarchitecture-Constraints PMC-2 — a v3 artifact is REFUSED
## on a v2 host, and the refusal NAMES THE SHORTFALL.
##
## This is the milestone's reason for existing. Before it, an arm requiring
## instructions the host lacks resolved happily; the failure arrived later as
## ``SIGILL`` inside somebody else's build, with nothing pointing back at the
## selection that caused it. A resolution-time refusal is only half the fix —
## the other half is that the message says what the host would need, because a
## generic "no matching arm" here puts the reader back where PMC-1 started:
## looking for a missing build that is, in fact, sitting in the catalog.
##
## So this test asserts on message CONTENT, not merely on failure:
##
##   1. ``resolveBuiltinPackage`` reports the distinct
##      ``breMicroarchFloorNotSatisfied``, not the generic
##      ``brePlatformNotSupported``;
##   2. the detail contains the milestone's own sentence, "needs x86-64-v3,
##      host provides x86-64-v2";
##   3. it does NOT contain the pre-PMC-2 "no platform slice for cpu=..."
##      phrasing, which would be actively misleading — there IS a slice;
##   4. ``describeMicroarchShortfall`` produces that sentence exactly, so the
##      wording is pinned in one place rather than asserted loosely;
##   5. when several arms are out of reach, the shortfall names the LOWEST
##      floor among them — the least the host would have to provide — because
##      that is the actionable number;
##   6. the refusal is a refusal: nothing resolves, so there is no arm to trap
##      on later;
##   7. the host-level OVERRIDE (``REPRO_HOST_MICROARCH_LEVEL``) reaches the
##      resolution entry point through its DEFAULTED ``hostLevel`` parameter —
##      the call in that block deliberately does not pass one. This is PMC-2's
##      second deliverable exercised end to end, and it is the mechanism
##      PMC-4 needs for "a build must be able to target a floor below the
##      builder": a v3 machine talked down to v2 is refused the v3 artifact.
##
## Falsifiable: delete the ``refusedForLevel`` branch in
## ``resolveBuiltinPackage`` and (1), (2) and (3) fail together — the failure
## degrades to the generic message. Change ``describeMicroarchShortfall`` to
## report the host's level as the requirement (or vice versa) and (2), (4) and
## (5) fail.
##
## Hermetic: synthetic catalog, synthetic host target through the defaulted
## ``hostCpu`` / ``hostOs`` / ``hostLevel`` parameters. No v2 or v3 hardware.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/packages_schema
import repro_home_apply/package_catalog

const V3Url = "https://example.invalid/demo-2.0.0-linux-x86-64-v3.tar.gz"
const V3Sha =
  "3333333333333333333333333333333333333333333333333333333333333333"
const V4Url = "https://example.invalid/demo-2.0.0-linux-x86-64-v4.tar.gz"
const V4Sha =
  "4444444444444444444444444444444444444444444444444444444444444444"

proc v3OnlyCatalog(): seq[VersionedProvisioning] =
  @[
    initVersionedProvisioning(
      version = "2.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = @[
        initPlatformBinary(cpu = pcX86_64, os = poLinux, url = V3Url,
          sha256 = V3Sha, cpu_level = mlX86_64_v3)
      ])
  ]

proc v3AndV4Catalog(): seq[VersionedProvisioning] =
  ## Declared HIGHEST first, so an implementation that reports "the last
  ## unreachable floor it saw" instead of the lowest is caught.
  @[
    initVersionedProvisioning(
      version = "2.0.0",
      archive_format = afTarGz,
      install_method = imExtract,
      bin_relpath = @["bin/demo"],
      platforms = @[
        initPlatformBinary(cpu = pcX86_64, os = poLinux, url = V4Url,
          sha256 = V4Sha, cpu_level = mlX86_64_v4),
        initPlatformBinary(cpu = pcX86_64, os = poLinux, url = V3Url,
          sha256 = V3Sha, cpu_level = mlX86_64_v3)
      ])
  ]

suite "PMC-2 — a v3 artifact is refused on a v2 host, naming the shortfall":

  test "t_v3_artifact_refused_on_a_v2_host":
    let cat = v3OnlyCatalog()

    # ---- (1)(2)(3) the diagnostic ---------------------------------------
    block refusedWithShortfall:
      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v2)
      check not r.found
      check r.error == breMicroarchFloorNotSatisfied
      check r.errorDetail.contains(
        "needs x86-64-v3, host provides x86-64-v2")
      # The package and version are named too: a shortfall with no subject
      # is not actionable in a build resolving dozens of packages.
      check r.errorDetail.contains("'demo'")
      check r.errorDetail.contains("'2.0.0'")
      # NOT the pre-PMC-2 phrasing. A slice for this (cpu, os) exists; saying
      # it does not would send the reader to look for a build that is there.
      check not r.errorDetail.contains("no platform slice for cpu=")

    # ---- (4) the wording is pinned in one place -------------------------
    block wordingPinned:
      let sel = selectPlatformBinaryEx(cat[0],
        initPlatformTarget(pcX86_64, mlX86_64_v2), poLinux)
      check not sel.found
      check sel.refusedForLevel
      check sel.requiredLevel == mlX86_64_v3
      check sel.hostLevel == mlX86_64_v2
      check describeMicroarchShortfall(sel) ==
        "needs x86-64-v3, host provides x86-64-v2"

    # ---- (5) several out of reach: the LOWEST is named -------------------
    block lowestUnreachableFloorIsNamed:
      let both = v3AndV4Catalog()
      let r = resolveBuiltinPackage("demo", both, "", pcX86_64, poLinux,
        mlX86_64_v2)
      check not r.found
      check r.error == breMicroarchFloorNotSatisfied
      check r.errorDetail.contains(
        "needs x86-64-v3, host provides x86-64-v2")
      check not r.errorDetail.contains("needs x86-64-v4")

      # And on a v3 host the v3 arm becomes reachable while v4 stays out —
      # the same catalog, one step up, resolves rather than refusing.
      let onV3 = resolveBuiltinPackage("demo", both, "", pcX86_64, poLinux,
        mlX86_64_v3)
      check onV3.found
      check onV3.resolution.urlUsed == V3Url
      check onV3.resolution.builtinCpuLevel == mlX86_64_v3

    # ---- (6) refusal means nothing resolved -----------------------------
    block nothingResolved:
      let r = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux,
        mlX86_64_v2)
      check r.resolution.urlUsed == ""
      check r.resolution.builtinVersion == ""
      check r.resolution.builtinCpuLevel == mlNone

    # ---- (7) the override reaches the DEFAULTED parameter ---------------
    #
    # PMC-2's second deliverable is host target detection plus a way to
    # override it, and the milestone's reason for the override is that "a
    # build must be able to target a floor below the builder" (PMC-4 depends
    # on it). This block exercises it end to end on the DEFAULT path — note
    # that ``hostLevel`` is NOT passed — so it covers the seam itself and not
    # merely the arithmetic behind it.
    block hostLevelOverrideDrivesTheDefault:
      putEnv(HostMicroarchLevelEnvVar, "x86-64-v2")
      defer: delEnv(HostMicroarchLevelEnvVar)

      check detectHostMicroarchLevel(pcX86_64) == mlX86_64_v2
      check detectHostTarget().level == mlX86_64_v2

      # Talked DOWN to v2: the v3 artifact is refused, through the default.
      let down = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux)
      check not down.found
      check down.error == breMicroarchFloorNotSatisfied
      check down.errorDetail.contains(
        "needs x86-64-v3, host provides x86-64-v2")

      # Raised to v3: the same call, same catalog, now resolves.
      putEnv(HostMicroarchLevelEnvVar, "v3")
      let up = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux)
      check up.found
      check up.resolution.urlUsed == V3Url

      # An unreadable value is REFUSED, not quietly defaulted. Silently
      # falling back to the baseline would turn a typo in a runner label
      # into a fleet that believes it is v1 and stops using every optimised
      # artifact — a performance regression with no error anywhere.
      putEnv(HostMicroarchLevelEnvVar, "avx512")
      expect ValueError:
        discard detectHostMicroarchLevel(pcX86_64)

      # With no override the family baseline applies: x86_64 provides v1 by
      # definition, and a family with no psABI level ladder provides none.
      delEnv(HostMicroarchLevelEnvVar)
      check detectHostMicroarchLevel(pcX86_64) == mlX86_64_v1
      check detectHostMicroarchLevel(pcAArch64) == mlNone
      check baselineMicroarchLevel(pcX86_64) == mlX86_64_v1
      check baselineMicroarchLevel(pcAny) == mlNone
      # And on the baseline the v3 artifact is still out of reach, which is
      # the conservative-floor default this milestone chose deliberately.
      let baseline = resolveBuiltinPackage("demo", cat, "", pcX86_64, poLinux)
      check not baseline.found
      check baseline.error == breMicroarchFloorNotSatisfied
