## The positive polarity: the `attestation` activity at the `mock` tier
## plans on an ordinary layout, and the plan carries the activity.
##
## ## Why this is a separate gate and not a case in the refusal gate
##
## A validator that refuses everything satisfies every negative test ever
## written against it. The refusal gate carries a control of its own — the
## same non-mock tier on the layout that can serve it — but that control
## holds the LAYOUT as the variable. This one holds the TIER: the layout
## is the plain, writable-root one the refusal gate watches a `tpm` tier
## be turned away from, and the only thing that changes is the tier.
##
## Between them the two gates pin all four corners of the rule, and each
## corner is reached through the real `repro infra plan` rather than
## inferred from the other three.
##
## ## What "allowed" has to mean here
##
## Not "exit 0". A profile whose activity call was deleted also exits 0,
## and so does one whose `attestationActivity` returns an empty spec. So
## the assertion is that the activity was BUILT and carries its
## contributions — the agent package and the unit name the daemon renders
## for itself — and that the plan the CLI wrote is a real plan with an
## id, rather than a refusal that happened to be quiet.
##
## ## Why the mock tier is exempt at all, stated once
##
## `mock` has no root of trust. It produces evidence a production policy
## is required to refuse, and it exists precisely so that every layer
## above it can be built and tested on a machine with no attestation
## hardware — which is every development machine. A rule that pinned it
## to an attestable layout would defeat the only purpose the tier has,
## and would make the whole verification stack untestable without
## hardware nobody in the org has.
##
## ## Mocking
##
## None. Real `repro` binary, real profile compile, real planner.

import std/[os, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/system/attestation
import repro_profile

import ./attestation_activity_harness

suite "the mock tier is allowed on a layout with no measured root":

  setup:
    let tmpRoot = createTempDir("attestation-activity-mock-", "")

  teardown:
    try: removeDir(tmpRoot)
    except CatchableError: discard

  test "mock on the plain layout plans, and the plan has an id":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      let (run, activityJson) =
        planFor(tmpRoot, "mockOnPlain", "uefi-ext4", "atMock")
      check "profile compilation failed" notin run.output
      check run.exitCode == 0
      # A real plan, not a quiet refusal: the CLI printed a plan id and
      # named the profile it planned.
      check "plan-id" in run.output
      var planId = ""
      for line in run.output.splitLines:
        let t = line.strip()
        if t.startsWith("plan-id"):
          let idx = t.find(':')
          if idx >= 0: planId = t[idx + 1 .. ^1].strip()
      check planId.len == 32

      # And the activity is in the profile's evaluation, with the
      # contributions enabling it makes.
      check activityJson.len > 0
      let spec = parseSystemActivityJson(activityJson)
      check spec.name == ActivityName
      check spec.systemPackages == @[AgentPackage]
      check spec.systemServices == @[UnitName]
      check spec.displayName.len > 0
      check spec.description.len > 0

  test "the SAME layout refuses the SAME activity at a tier that needs evidence":
    when not (defined(linux) or defined(macosx)):
      skip()
    else:
      # The discrimination, measured inside one gate rather than across
      # two: one word of the profile changes and the outcome inverts.
      let mockSrc = attestationProfileSource(
        "polarity", "uefi-ext4", "atMock", tmpRoot, tmpRoot / "a.json")
      let tpmSrc = attestationProfileSource(
        "polarity", "uefi-ext4", "atTpm", tmpRoot, tmpRoot / "a.json")
      var differing = 0
      let mockLines = mockSrc.splitLines
      let tpmLines = tpmSrc.splitLines
      check mockLines.len == tpmLines.len
      for i in 0 ..< mockLines.len:
        if mockLines[i] != tpmLines[i]: inc differing
      check differing == 1

      let (mockRun, mockJson) =
        planFor(tmpRoot, "polarityMock", "uefi-ext4", "atMock")
      let (tpmRun, tpmJson) =
        planFor(tmpRoot, "polarityTpm", "uefi-ext4", "atTpm")
      check mockRun.exitCode == 0
      check tpmRun.exitCode != 0
      check mockJson.len > 0
      check tpmJson == ""
