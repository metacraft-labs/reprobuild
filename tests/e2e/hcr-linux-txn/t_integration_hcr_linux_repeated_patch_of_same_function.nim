## HLX-M3 verification gate
## `integration_hcr_linux_repeated_patch_of_same_function`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §4.5 (re-patching an
## already-patched function) and §11.2 (the saved original word).
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M3.
##
## WHY THIS EXISTS. Hot reloading is iterative by definition: the second reload
## of a session almost always targets a function the first reload already
## patched, and the published window then holds `E9 rel32 90 90 90` rather than
## NOPs. A provider without §4.5's second admissible pre-state refuses every
## reload after the first — it works exactly once, which no reload workflow
## would tolerate. This gate is `Home-Demo-Screencast` H5/H6's live-edit loop
## tested from below.
##
## THREE CLAIMS, all asserted on observed bytes:
##
##   1. Generations 2 and 3 succeed and the function returns the NEWEST value.
##      Each generation moves exactly the eight bytes of the publication
##      window and nothing else, and the superseded bodies are still there —
##      proved by CALLING each generation's body at the address the provider
##      reported and observing the value it still returns. A freed page would
##      fault; a reused one would answer something else.
##
##   2. A window whose bytes were altered behind the provider's back is
##      REFUSED (`entry-modified-externally`), never overwritten. The
##      modification is a real store of a real executable word performed by
##      something that is not the provider.
##
##   3. Rollback after generation 3 restores the ORIGINAL unpatched bytes, not
##      generation 2's. §4.5 is explicit: a rolled-back site returns to
##      unpatched code rather than to an older patch whose body may since have
##      been superseded.
##
## `allowed_mocks: none`. Real process, real GCC with the real patchable
## profile, real bodies from a real relocatable object, the production
## transaction through the no-mock probe shim, the real claim map.
##
## ------------------------------------------------------------------------
## DISCRIMINATION, measured by this file:
##
##   * claim 1 is discriminated by the byte comparison itself — the three
##     generations must produce three DIFFERENT published words at the SAME
##     window, so an instrument that could only say "identical" fails here;
##   * claim 3 is discriminated by a falsifier build
##     (`REPRO_HCR_HLX_M3_FALSIFY_ROLLBACK_TO_PREVIOUS_GENERATION`) in which
##     rollback restores the previous generation's word instead of the
##     original. That arm MUST end with the victim returning generation 2's
##     value and the text NOT matching the pristine snapshot. Note that the
##     falsifier is INVISIBLE at generation 1, where the two words coincide —
##     which is exactly why the re-patch gate is the one that has to carry it.

import std/[json, os, strutils, unittest]

when defined(linux) and defined(amd64):
  import m3_fixture

  suite "integration_hcr_linux_repeated_patch_of_same_function":
    setup:
      let repoRoot = getCurrentDir()

    test "the claim map the rollback assertion needs is present":
      let path = claimMapPath(repoRoot)
      if not fileExists(path):
        checkpoint("HLX-M3 gate needs the codetracer-native-recorder " &
          "checkout beside this repo: " & path & " is not there.")
      require fileExists(path)

    test "three generations, retained bodies, rollback to the ORIGINAL":
      let bodies = buildPatchBodies(repoRoot)
      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let run = runArm(fixture, "repeat", bodies)

      let gens = run["generations"]
      check gens.len == 3

      # Claim 1a: each generation succeeded and returned its own value.
      check gens[0]["value"].getInt() == ValueA
      check gens[1]["value"].getInt() == ValueB
      check gens[2]["value"].getInt() == ValueC

      # Claim 1b: three DIFFERENT published words at the SAME window. Equal
      # words would mean the later generations were no-ops wearing a success
      # report; a differing window would mean the site was re-planned rather
      # than re-patched.
      let w0 = gens[0]["publishedWord"].getStr()
      let w1 = gens[1]["publishedWord"].getStr()
      let w2 = gens[2]["publishedWord"].getStr()
      check w0 != w1
      check w1 != w2
      check w0 != w2

      # Claim 1c: the bodies are distinct pages and every one of them is still
      # live. This is retention OBSERVED — the gate calls each generation's
      # body through the address the provider reported.
      let d0 = gens[0]["dispatch"].getStr()
      let d1 = gens[1]["dispatch"].getStr()
      let d2 = gens[2]["dispatch"].getStr()
      check d0 != d1
      check d1 != d2
      check d0 != d2
      check gens[0]["retainedBodyValue"].getInt() == ValueA
      check gens[1]["retainedBodyValue"].getInt() == ValueB
      check gens[2]["retainedBodyValue"].getInt() == ValueC

      # Claim 1d: the store was never widened. Every byte each generation
      # changed relative to the pristine snapshot lies inside ONE naturally
      # aligned 8-byte block — the publication window. A byte COUNT would be
      # the wrong observation here (`E9 rel32` leaves the `90 90 90` tail
      # alone) and would not catch a widened store either way.
      let pristine = run["pristineText"].getStr()
      let entry = parseHexInt(run["window"].getStr()[2 .. ^1]).uint64
      discard entry
      for g in gens:
        let text = g["text"].getStr()
        check text.len == pristine.len
        var differingIndices: seq[int] = @[]
        var i = 0
        while i < text.len:
          if text[i ..< i + 2] != pristine[i ..< i + 2]:
            differingIndices.add(i div 2)
          i += 2
        # Between one and eight bytes, not "five": the published word's own
        # bytes can COINCIDE with the NOP sled they replace. Generation 3's
        # `rel32` happens to contain a 0x90 in this fixture, so only four
        # positions differ from the pristine window — a lower bound of five
        # would have made this gate flaky on the displacement, which is an
        # address and therefore not something a gate may depend on.
        check differingIndices.len >= 1
        check differingIndices.len <= 8
        # The fixture's snapshot starts 16 bytes before the entry, and the
        # entry is 16-byte aligned, so snapshot index and target address agree
        # modulo 8 and the alignment question can be asked of the indices.
        let blockBase = differingIndices[0] and not 7
        for idx in differingIndices:
          check (idx and not 7) == blockBase

      # `oldCodeRetained` is now an observation: one saved original word plus
      # one retained body per generation. Before HLX-M3 this field was the
      # literal `true` in the C agent's format string.
      check run["oldCodeRetained"].getInt() == 1
      check run["retainedRegionCount"].getInt() == 4

      # Claim 3: rollback lands on the ORIGINAL, byte for byte.
      check run["rollbackRc"].getInt() == 0
      check run["rolledBackText"].getStr() == pristine
      check run["valueAfterRollback"].getInt() == OriginalA
      # And it is not merely equal to the original by accident: generation 2's
      # text is a state this rollback could plausibly have landed on, and did
      # not.
      check run["rolledBackText"].getStr() != gens[1]["text"].getStr()
      # §4.5: the claim is retained across generations and RELEASED on
      # rollback, and the site is retired so a later patch re-plans from an
      # all-NOP window.
      check run["claimsAfterRollback"].getInt() == 0
      check run["siteLiveAfterRollback"].getInt() == 0

    test "a window modified behind the provider's back is REFUSED":
      let bodies = buildPatchBodies(repoRoot)
      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let run = runArm(fixture, "repeat-external", bodies)

      # §4.5: the window matches neither admissible pre-state, so the second
      # generation is refused by NAME.
      check run["refusal"].getStr() == "entry-modified-externally"
      check run["rc"].getInt() != 0
      # NEVER OVERWRITTEN — the bytes the external writer left are the bytes
      # that are still there.
      check run["before"].getStr() == run["after"].getStr()
      # And the process runs what the external writer left: the modification
      # put the original all-NOP word back, so the victim returns 11.
      check run["value"].getInt() == OriginalA

    test "rollback goes RED against a provider that restores generation N-1":
      # DISCRIMINATION, measured. One property removed and nothing else:
      # rollback restores `previous_word` instead of `original_word`, which is
      # precisely what §4.5 forbids.
      let bodies = buildPatchBodies(repoRoot)
      let healthy = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let falsified = buildFixture(repoRoot, "hcr_lx_m3_txn_prev_gen",
        ["REPRO_HCR_HLX_M3_FALSIFY_ROLLBACK_TO_PREVIOUS_GENERATION"])

      let green = runArm(healthy, "repeat", bodies)
      let red = runArm(falsified, "repeat", bodies)

      check green["rolledBackText"].getStr() == green["pristineText"].getStr()
      check green["valueAfterRollback"].getInt() == OriginalA

      # The falsified provider lands on generation 2 — the value and the bytes
      # both say so. If this arm were also green the assertion above would be
      # measuring nothing, because a rollback that cannot be made to land
      # anywhere else is not evidence that it lands on the original.
      check red["rolledBackText"].getStr() != red["pristineText"].getStr()
      check red["valueAfterRollback"].getInt() == ValueB
      check red["rolledBackText"].getStr() ==
        red["generations"][1]["text"].getStr()

else:
  suite "integration_hcr_linux_repeated_patch_of_same_function":
    test "linux/amd64 only":
      skip()
