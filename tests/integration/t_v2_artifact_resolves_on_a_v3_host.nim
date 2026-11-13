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
## GM4b: selection runs over ``tarball`` realization records through
## ``realization_selection.selectTarballRecord`` (arm choice by
## ``packages_schema.selectArm``), the selection recipes and profiles share.
##
## Falsifiable: change ``satisfiesFloor`` to ``ord(hostLevel) == ord(floor)``
## (equality, the pre-PMC-2 shape of every other axis) and (1) fails for the v3
## and v4 hosts. Change it to ``true`` and (2), (3) and (4) fail.
##
## Hermetic: the records are built in this file and the target is passed
## explicitly (``pmc_selection_support.selectFor`` / ``targetOf``), so no
## v2/v3 hardware is involved and the test runs identically on any machine.

import std/[strutils, unittest]

import repro_home_apply/package_catalog
import ./pmc_selection_support

const V2Url = "https://example.invalid/demo-1.0.0-linux-x86-64-v2.tar.gz"
const V2Sha =
  "1111111111111111111111111111111111111111111111111111111111111111"

proc v2Only(): seq[InterfaceTarballProvisioning] =
  @[tarballRecord(V2Url, V2Sha, level = "x86-64-v2")]

suite "PMC-2 — a v2 artifact resolves on a v3 host":

  test "t_v2_artifact_resolves_on_a_v3_host":
    let records = v2Only()

    # ---- (1) the ordering: v2 <= v3, v2 <= v4, v2 <= v2 -----------------
    for provided in [mlX86_64_v2, mlX86_64_v3, mlX86_64_v4]:
      let r = selectFor(records, pcX86_64, poLinux, provided)
      checkpoint "host provides " & describeMicroarchLevel(provided)
      check r.choice.status == kcSelected
      check r.record.url == V2Url
      check r.record.detail.version == "1.0.0"
      # The selected record's own floor is carried forward into the archive
      # realizer's input and the resolved-target string a lock records.
      let archive = archiveRealizationOf("demo", r.record)
      check archive.builtinCpuLevel == mlX86_64_v2
      check archive.resolvedTarget == "x86-64-v2"

    # ---- (2) below the floor: refused -----------------------------------
    block belowFloor:
      let r = selectFor(records, pcX86_64, poLinux, mlX86_64_v1)
      check r.choice.status == kcCapabilityShortfall
      check r.choice.detail.contains(
        "needs x86-64-v2, host provides x86-64-v1")

    # ---- (3) a host that stated nothing is not treated as v1 ------------
    block unstatedHost:
      let r = selectFor(records, pcX86_64, poLinux, mlNone)
      check r.choice.status == kcCapabilityShortfall
      check r.choice.detail.contains(
        "needs x86-64-v2, host provides no declared microarchitecture level")

    # ---- (4) refusal is distinguishable from a missing arm --------------
    block refusalIsNotAMiss:
      let refused = selectArm([tarballArm(records[0]).arm],
        initPlatformTarget(pcX86_64, mlX86_64_v1), poLinux)
      check refused.index < 0
      check refused.selection.refusedForLevel
      check refused.selection.requiredLevel == mlX86_64_v2
      check describeMicroarchShortfall(refused.selection) ==
        "needs x86-64-v2, host provides x86-64-v1"

      # A genuinely absent arm is the OTHER outcome and must not be
      # mislabelled as a microarchitecture shortfall: there is no Windows
      # record at all here, at any level.
      let absent = selectArm([tarballArm(records[0]).arm],
        initPlatformTarget(pcX86_64, mlX86_64_v4), poWindows)
      check absent.index < 0
      check not absent.selection.refusedForLevel
      check describeMicroarchShortfall(absent.selection) == ""

      let windowsMiss = selectFor(records, pcX86_64, poWindows, mlX86_64_v4)
      check windowsMiss.choice.status == kcNoneForTarget
