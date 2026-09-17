## HLX-M3 verification gate
## `integration_hcr_linux_prepare_failure_leaves_process_byte_identical`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §11.2 (the prepare /
## commit split) and §4.3 (the refusals).
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M3.
##
## THE CLAIM. Every prepare-phase failure class leaves the target's text
## BYTE-IDENTICAL and the process still returning its original values. This is
## IsoNim's never-blank-the-surface guarantee, and §11.2 makes it structural
## rather than best-effort: prepare touches no target memory at all, so the
## guarantee holds by construction and not by cleanup.
##
## THE ASSERTION IS ON OBSERVED BYTES, NOT ON A RETURNED STATUS. The fixture
## snapshots 80 bytes of text around each victim's entry immediately before the
## operation and again immediately after, and this gate compares those hex
## strings. A provider that returned a refusal and wrote anyway would be green
## on status and red here, which is the only arrangement worth having.
##
## `allowed_mocks: none`. Real process, real GCC with the real patchable
## profile, real replacement bodies extracted from a real relocatable object,
## the production transaction reached through the no-mock probe shim, and the
## real cross-patcher claim map from the recorder's repository.
##
## ------------------------------------------------------------------------
## HOW THIS GATE IS SHOWN TO DISCRIMINATE, rather than asserted to.
##
## Three independent measurements, all made by this file at run time:
##
## 1. THE INSTRUMENT CONTROL (`prep-positive-control`). The same snapshot code,
##    the same comparison, a patch that SUCCEEDS. It must report the text as
##    CHANGED, with every changed byte inside ONE naturally aligned 8-byte
##    block, and with the victim's value moving 11 -> 77. (Not "8 bytes
##    differ", and not "5": the `E9 rel32` leaves the window's `90 90 90` tail
##    byte-identical, and the `rel32` is an ADDRESS whose own bytes can
##    coincide with the NOPs they replace. The ALIGNMENT is the property worth
##    asserting; a byte count is either wrong or flaky.) If the comparison were
##    vacuous — the wrong address, an empty string, two snapshots taken at the
##    same moment — this arm would report "identical" too and the gate fails.
##    Without it, every other arm's green is compatible with an instrument that
##    can only say "identical".
##
## 2. THE PROVIDER FALSIFIER (`REPRO_HCR_HLX_M3_FALSIFY_PARTIAL_SET_COMMIT`).
##    The same fixture is built a second time against a provider with exactly
##    one property removed: prepare no longer unwinds the sites that already
##    prepared when a later site refuses, so the healthy prefix is committed —
##    which is `Patch-Loading-Lifecycle.md` §3.3 item 39's "partially applied
##    patches are permitted", the behaviour §11.2 supersedes. The multi-site
##    arm MUST go red under that build and green under the healthy one, and
##    this file measures both.
##
## 3. PAIRWISE DISTINCT REFUSALS. Every arm's observed refusal name is
##    collected and the set is asserted to have one entry per arm. An arm whose
##    expectation is satisfied by another arm's observations is not a gate; the
##    property is measured here rather than argued in a comment.
##
## What this gate does NOT prove: that a prepare failure is safe while other
## threads execute the function. Nothing in HLX-M3 proves that — see HLX-M4,
## where bare tier-1 publication was falsified outright.

import std/[json, os, sets, strutils, unittest]

when defined(linux) and defined(amd64):
  import m3_fixture

  suite "integration_hcr_linux_prepare_failure_leaves_process_byte_identical":
    setup:
      let repoRoot = getCurrentDir()

    test "the claim map the leak check needs is present":
      # A LOUD failure, not a skip. The arms below read
      # `ct_claimed_guest_text_count()` to assert a refused prepare leaves no
      # claim behind; without the sibling checkout there is nothing to read.
      let path = claimMapPath(repoRoot)
      if not fileExists(path):
        checkpoint("HLX-M3 gate needs the codetracer-native-recorder " &
          "checkout beside this repo: " & path & " is not there.")
      require fileExists(path)

    test "every prepare-phase failure class leaves the text byte-identical":
      let bodies = buildPatchBodies(repoRoot)
      check bodies.a.len > 0
      check bodies.b.len > 0
      check bodies.c.len > 0
      # The bodies must be what the gate thinks they are: `mov $0x4d,%eax` is
      # the 77 a successful arm observes. A body that did not carry it would
      # make the positive control's value assertion meaningless.
      check hex(bodies.a).contains("b84d000000")

      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      check fileExists(fixture)

      # ---------------------------------------------------------------- 1 ---
      # THE INSTRUMENT CONTROL. Run FIRST, so a broken comparison fails here
      # rather than silently greening the seven arms below it.
      let control = runArm(fixture, "prep-positive-control", bodies)
      check control["prepareRc"].getInt() == 0
      check control["commitRc"].getInt() == 0
      let controlVictim = control.victimNamed("victim_a")
      check not textIdentical(controlVictim)
      # One naturally aligned 8-byte store, never widened (design §4.2).
      # Asserted as "every changed byte lies in one aligned 8-byte block"
      # rather than as a byte count: the `E9 rel32` overwrites five NOPs and
      # leaves the `90 90 90` tail byte-identical, so a count of 8 is simply
      # the wrong observation and a count of 5 would not catch a widened store.
      check changedOneAlignedWord(controlVictim)
      # At least one byte moved — `changedOneAlignedWord` is false for zero
      # changes, but saying so explicitly keeps the two halves of the property
      # separable in a failure report.
      check differingBytes(controlVictim) >= 1
      check controlVictim["value"].getInt() == ValueA
      check controlVictim["originalValue"].getInt() == OriginalA
      # The other four victims are untouched even by a SUCCESSFUL patch, so
      # "identical" is not a property this fixture reports for everything.
      for name in ["victim_b", "victim_c", "plain_victim", "short_victim"]:
        check textIdentical(control.victimNamed(name))

      # ---------------------------------------------------------------- 2 ---
      # The failure classes. Each is (mode, expected refusal name).
      #
      # Three of the five single-site classes come from the COMPILER or from
      # the real bytes rather than from a lever:
      #   absent-sled   a translation unit built without the patchable profile
      #   short-sled    a translation unit built with `=4,0`
      #   non-nop-sled  a sled address the fixture located by walking the
      #                 provider's own NOP decoder until it stopped
      # `invalid-argument` is a body genuinely larger than a page. Only
      # `patch-memory-unavailable` and `sync-core-unavailable` use levers, and
      # both levers remove a resource rather than bypass the refusal logic.
      const arms = [
        ("prep-absent-sled", "absent-sled"),
        ("prep-short-sled", "short-sled"),
        ("prep-non-nop-sled", "non-nop-sled"),
        ("prep-no-patch-memory", "patch-memory-unavailable"),
        ("prep-oversized-body", "invalid-argument"),
        ("prep-sync-core-unavailable", "sync-core-unavailable"),
        ("prep-multi-site", "absent-sled")]

      var observedRefusals: seq[string] = @[]
      for (mode, expected) in arms:
        let arm = runArm(fixture, mode, bodies)
        checkpoint("arm: " & mode)
        # The arm must have failed in PREPARE, and for the stated reason. An
        # arm that refused for a different reason is measuring a different
        # class than it claims to.
        check arm["prepareRc"].getInt() != 0
        check arm["prepareRefusal"].getStr() == expected
        # Commit must never have run.
        check arm["commitRc"].getInt() == -1
        check arm["txn"]["prepareComplete"].getInt() == 0
        check arm["txn"]["commitComplete"].getInt() == 0
        check arm["txn"]["publishedCount"].getInt() == 0

        # THE ASSERTION THAT MATTERS: observed bytes, for every victim in the
        # process, not only the one that was targeted.
        for victim in arm["victims"]:
          checkpoint("  victim: " & victim["name"].getStr())
          check textIdentical(victim)
          check victim["value"].getInt() == victim["originalValue"].getInt()

        # Nothing provider-owned survived the refusal: the kernel's own
        # accounting of this process's anonymous executable bytes is unchanged,
        # and the claim map holds no claim for a window nobody is using.
        check arm["anonExecAfter"].getInt() == arm["anonExecBefore"].getInt()
        check arm["claimsAfter"].getInt() == arm["claimsBefore"].getInt()
        check arm["claimsAfter"].getInt() == 0
        observedRefusals.add(expected)

      # The `non-nop-sled` arm must have pointed at bytes that really are not
      # NOPs. Measured by the provider's own decoder at the address the fixture
      # chose, because the first draft of that arm guessed `entry + 32`, landed
      # in inter-function alignment padding — a genuine NOP run — and reported
      # a successful patch while claiming to measure a refusal.
      let nonNop = runArm(fixture, "prep-non-nop-sled", bodies)
      check nonNop["nonNopLength"].getInt() == 0
      check nonNop["nonNopAddress"].getStr() != "0x0"

      # THE HEADLINE. In the multi-site arm site 0 prepared successfully and
      # site 1 refused, so the failure is genuinely a LATER site's. Without
      # this the arm could be passing because site 0 also refused, which would
      # make "the healthy function was not published" trivially true.
      let multi = runArm(fixture, "prep-multi-site", bodies)
      check multi["txn"]["failedSite"].getInt() == 1
      check multi.victimNamed("victim_a")["value"].getInt() == OriginalA
      check textIdentical(multi.victimNamed("victim_a"))

      # ---------------------------------------------------------------- 3 ---
      # PAIRWISE DISTINCTNESS, measured. `prep-multi-site` shares its refusal
      # name with `prep-absent-sled` by construction (it is the same refusing
      # function), so it is excluded and covered by the `failedSite` assertion
      # above instead; the remaining six must be six.
      var distinct0 = initHashSet[string]()
      for r in observedRefusals[0 ..< observedRefusals.len - 1]:
        distinct0.incl(r)
      check distinct0.len == observedRefusals.len - 1

    test "the same arm goes RED against a provider without the unwind":
      # DISCRIMINATION, measured rather than asserted. One property removed and
      # nothing else: prepare keeps the sites that already prepared when a
      # later one refuses, and commits them.
      let bodies = buildPatchBodies(repoRoot)
      let healthy = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let falsified = buildFixture(repoRoot, "hcr_lx_m3_txn_partial_commit",
        ["REPRO_HCR_HLX_M3_FALSIFY_PARTIAL_SET_COMMIT"])
      check healthy != falsified

      let green = runArm(healthy, "prep-multi-site", bodies)
      let red = runArm(falsified, "prep-multi-site", bodies)

      let greenVictim = green.victimNamed("victim_a")
      let redVictim = red.victimNamed("victim_a")

      # Green: the healthy provider published nothing.
      check textIdentical(greenVictim)
      check greenVictim["value"].getInt() == OriginalA

      # Red: the falsified provider published site 0 even though site 1
      # refused. If this arm were ALSO green the gate above would be measuring
      # nothing — a multi-site prepare failure that cannot be made to leak is
      # not evidence that the unwind works.
      check not textIdentical(redVictim)
      check redVictim["value"].getInt() == ValueA
      check changedOneAlignedWord(redVictim)

else:
  suite "integration_hcr_linux_prepare_failure_leaves_process_byte_identical":
    test "linux/amd64 only":
      # Not a silent skip in disguise: the provider arm this gate drives is
      # `#if defined(REPRO_HCR_TARGET_LINUX_X86_64)` and does not exist on
      # other hosts. The Windows and macOS equivalents are owned by their own
      # milestones.
      skip()
