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
## GM4b: selection runs over ``tarball`` realization records through
## ``realization_selection`` (``selectTarballRecord`` for one kind,
## ``selectRealization`` for the whole request) — the selection a recipe's
## ``uses:`` and a home profile share.
##
## So this test asserts on message CONTENT, not merely on failure:
##
##   1. the tarball kind reports the distinct ``kcCapabilityShortfall``, not
##      the generic ``kcNoneForTarget``;
##   2. the detail contains the milestone's own sentence, "needs x86-64-v3,
##      host provides x86-64-v2", and the full selection failure names the
##      package and the target;
##   3. it does NOT contain the "no tarball realization for ..." phrasing,
##      which would be actively misleading — there IS a record;
##   4. ``describeMicroarchShortfall`` produces that sentence exactly, so the
##      wording is pinned in one place rather than asserted loosely;
##   5. when several records are out of reach, the shortfall names the LOWEST
##      floor among them — the least the host would have to provide;
##   6. the refusal is a refusal: nothing is selected;
##   7. the host-level OVERRIDE (``REPRO_HOST_MICROARCH_LEVEL``) reaches the
##      profile's realization target (``profileRealizationTarget`` for the
##      host reads ``hostTarget()``), so a v3 machine talked down to v2 is
##      refused the v3 artifact — PMC-4's "target a floor below the builder".
##
## Falsifiable: drop the ``refusedForLevel`` branch in ``selectTarballRecord``
## (report ``kcNoneForTarget`` instead) and (1), (2) and (3) fail together.
## Change ``describeMicroarchShortfall`` to report the host's level as the
## requirement (or vice versa) and (2), (4) and (5) fail.
##
## Hermetic: synthetic records, explicit synthetic targets. No v2 or v3
## hardware.

import std/[os, strutils, unittest]

import repro_home_apply/package_catalog
import ./pmc_selection_support

const V3Url = "https://example.invalid/demo-2.0.0-linux-x86-64-v3.tar.gz"
const V3Sha =
  "3333333333333333333333333333333333333333333333333333333333333333"
const V4Url = "https://example.invalid/demo-2.0.0-linux-x86-64-v4.tar.gz"
const V4Sha =
  "4444444444444444444444444444444444444444444444444444444444444444"

proc v3Only(): seq[InterfaceTarballProvisioning] =
  @[tarballRecord(V3Url, V3Sha, level = "x86-64-v3", version = "2.0.0")]

proc v3AndV4(): seq[InterfaceTarballProvisioning] =
  ## Declared HIGHEST first, so an implementation that reports "the last
  ## unreachable floor it saw" instead of the lowest is caught.
  @[tarballRecord(V4Url, V4Sha, level = "x86-64-v4", version = "2.0.0"),
    tarballRecord(V3Url, V3Sha, level = "x86-64-v3", version = "2.0.0")]

suite "PMC-2 — a v3 artifact is refused on a v2 host, naming the shortfall":

  test "t_v3_artifact_refused_on_a_v2_host":
    let records = v3Only()

    # ---- (1)(2)(3) the diagnostic ---------------------------------------
    block refusedWithShortfall:
      let r = selectFor(records, pcX86_64, poLinux, mlX86_64_v2)
      check r.choice.status == kcCapabilityShortfall
      check r.choice.status != kcNoneForTarget
      check r.choice.detail.contains(
        "needs x86-64-v3, host provides x86-64-v2")
      # NOT the "nothing for this target" phrasing: a record exists.
      check not r.choice.detail.contains("no tarball realization for")
      # The refused record's version is named too.
      check r.choice.detail.contains("(version 2.0.0)")
      # The full selection names the subject: a shortfall with no package
      # and no target is not actionable in a profile resolving dozens.
      var raised = false
      try:
        discard resolveDemo(records, targetOf(pcX86_64, poLinux,
          mlX86_64_v2))
      except EMissingRealization as err:
        raised = true
        check err.msg.contains("'demo'")
        check err.msg.contains("x86_64-linux")
        check err.msg.contains("(version 2.0.0)")
        check err.msg.contains("needs x86-64-v3, host provides x86-64-v2")
        check err.steps.len == 1
        check err.steps[0].capabilityShortfall
      check raised

    # ---- (4) the wording is pinned in one place -------------------------
    block wordingPinned:
      let sel = selectArm([tarballArm(records[0]).arm],
        initPlatformTarget(pcX86_64, mlX86_64_v2), poLinux)
      check sel.index < 0
      check sel.selection.refusedForLevel
      check sel.selection.requiredLevel == mlX86_64_v3
      check sel.selection.hostLevel == mlX86_64_v2
      check describeMicroarchShortfall(sel.selection) ==
        "needs x86-64-v3, host provides x86-64-v2"

    # ---- (5) several out of reach: the LOWEST is named -------------------
    block lowestUnreachableFloorIsNamed:
      let both = v3AndV4()
      let r = selectFor(both, pcX86_64, poLinux, mlX86_64_v2)
      check r.choice.status == kcCapabilityShortfall
      check r.choice.detail.contains(
        "needs x86-64-v3, host provides x86-64-v2")
      check not r.choice.detail.contains("needs x86-64-v4")

      # And on a v3 host the v3 record becomes reachable while v4 stays out.
      let onV3 = selectFor(both, pcX86_64, poLinux, mlX86_64_v3)
      check onV3.choice.status == kcSelected
      check onV3.record.url == V3Url
      check archiveRealizationOf("demo", onV3.record).builtinCpuLevel ==
        mlX86_64_v3

    # ---- (6) refusal means nothing selected -----------------------------
    block nothingResolved:
      let r = selectFor(records, pcX86_64, poLinux, mlX86_64_v2)
      check r.choice.index < 0
      check r.record.url == ""

    # ---- (7) the override reaches the profile's host target ------------
    block hostLevelOverrideDrivesTheDefault:
      putEnv(HostMicroarchLevelEnvVar, "x86-64-v2")
      defer: delEnv(HostMicroarchLevelEnvVar)

      check detectHostMicroarchLevel(pcX86_64) == mlX86_64_v2
      check detectHostTarget().level == mlX86_64_v2

      # The host target a profile resolves for, on an x86_64 host. (On
      # another host family the target is still named x86_64 here, and
      # ``profileRealizationTarget`` keeps the family's baseline — so the
      # override assertions below only apply to an x86_64 machine.)
      let hostTargetNow = profileRealizationTarget("linux", "x86_64", true)
      if detectHostCpu() == pcX86_64:
        check hostTargetNow.platform.level == mlX86_64_v2
        # Talked DOWN to v2: the v3 artifact is refused.
        let down = selectTarballRecord(records, hostTargetNow)
        check down.status == kcCapabilityShortfall
        check down.detail.contains("needs x86-64-v3, host provides x86-64-v2")
        # Raised to v3: the same records now select.
        putEnv(HostMicroarchLevelEnvVar, "v3")
        let up = selectTarballRecord(records,
          profileRealizationTarget("linux", "x86_64", true))
        check up.status == kcSelected
      else:
        # A non-x86_64 host names an x86_64 target at its baseline, NOT at
        # the host's declared level: the override describes this machine,
        # which is not the target.
        check hostTargetNow.platform.level == mlX86_64_v1

      # An unreadable value is REFUSED, not quietly defaulted.
      putEnv(HostMicroarchLevelEnvVar, "avx512")
      expect ValueError:
        discard detectHostMicroarchLevel(pcX86_64)

      # With no override the family baseline applies.
      delEnv(HostMicroarchLevelEnvVar)
      check detectHostMicroarchLevel(pcX86_64) == mlX86_64_v1
      check detectHostMicroarchLevel(pcAArch64) == mlNone
      check baselineMicroarchLevel(pcX86_64) == mlX86_64_v1
      check baselineMicroarchLevel(pcAny) == mlNone
      # And on the baseline the v3 artifact is still out of reach.
      let baseline = selectFor(records, pcX86_64, poLinux, mlX86_64_v1)
      check baseline.choice.status == kcCapabilityShortfall
