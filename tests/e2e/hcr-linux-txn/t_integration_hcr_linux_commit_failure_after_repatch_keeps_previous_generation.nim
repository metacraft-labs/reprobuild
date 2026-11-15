## HLX-M3 verification gate
## `integration_hcr_linux_commit_failure_after_repatch_keeps_previous_generation`.
##
## Issue: `reprobuild-pm/issues/2026-11-12-transaction-rollback-restores-
## generation-0-silently-reverting-earlier-committed-patches.md`.
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §11.2 ("a patch either
## applies to every function in the set or to none"; "a failed patch never
## leaves the target running partially-new code") and §4.5 (re-patching, the
## claim retained across generations, superseded bodies retained);
## `Failure-Semantics.md` "HCR Failures" ("the running process remains on the
## previous code version"); `Validation-Criteria.md` ("patch failure leaves the
## process in a known state").
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M3.
##
## THE PROPERTY. When reload N+1 fails during commit after publishing some of
## its sites, the process is back on reload N EVERYWHERE: every function in
## the set returns its generation-N value, and the text is byte-identical to
## the snapshot taken right after generation N committed. A rollback that
## restored each published site's ORIGINAL word instead would leave the
## published sites on generation 0 and the untouched ones on generation N — a
## mixture no build ever produced, which the IDE is told is "the previous
## version" (`hcr/patchFailed`: "No code is live and nothing was swapped").
##
## The site table must agree with the text, or the NEXT reload is refused:
## every site stays live at generation N, its claim is still held (taken once
## at the first publication and retained across generations, §4.5), its
## recorded published word is generation N's and equals the live window, and
## no claim is released by the rollback. The rolled-back generation-N+1 bodies
## are RETAINED (a thread may have entered one before the restore landed, and
## under tier 1 nothing proves otherwise), so they stay counted in the site's
## retained-body count and stay mapped; the bodies that were never published
## are unmapped. Finally, a further re-patch of the same set succeeds — the
## pre-state the rollback left is an admissible one.
##
## HOW THE FAILURE IS INDUCED. The same production-branch lever
## `t_integration_hcr_linux_commit_failure_rolls_back_published_sites.nim`
## uses: `repro_hcr_lx_commit_fault_site` names the site whose text
## replacement is refused, and the refusal is delivered as the step's
## `-EACCES` result, so the code path taken is the production failure branch.
## The lever is test-only; the agent never sets it.
##
## `allowed_mocks: none`. Real patchable victims in a real process, real GCC
## with the real patchable profile, real bodies from a real relocatable
## object, the production transaction through the no-mock probe shim, and
## `/proc/self/maps` for the page accounting.
##
## THE CLAIM MAP. Like the other HLX-M3 gates in this directory the fixture is
## built without the recorder's claim map (`m3_fixture.nim`), so the
## provider's claim calls take the bridge's no-map path. "The claim is still
## held" is therefore asserted on the PROVIDER's side — the site table's
## `claimed` flag and the transaction's released-claim count, both read
## through the probe shim — and the map's own count is the recorder's
## downstream arm (`codetracer-native-recorder` `tests/reprobuild-hcr/`).
##
## ------------------------------------------------------------------------
## DISCRIMINATION, measured by this file:
##
##   * each victim has THREE distinct candidate states — original, generation
##     1, generation 2 — with three distinct return values, so "returns the
##     generation-1 value" cannot be satisfied by either wrong rollback target;
##   * the positive control (no fault) commits generation 2 and every
##     function's text then DIFFERS from the generation-1 snapshot, so the
##     comparison is not an instrument that can only say "identical";
##   * the N = 1 and N = 2 arms publish and then restore re-patched sites
##     (`published` and `restored` both 1), which is the case the issue is
##     about; N = 0 is the degenerate arm with nothing to restore;
##   * the falsifier build (`REPRO_HCR_HLX_M3_FALSIFY_ROLLBACK_TO_ORIGINAL_WORD`)
##     restores the ORIGINAL word and changes nothing else, and the N = 2 arm
##     MUST then leave two functions on their original values and text while
##     the third stays on generation 1 — and the follow-up re-patch is then
##     refused `entry-modified-externally`, because the site table and the
##     window disagree.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip

when defined(linux) and defined(amd64):
  import m3_fixture

  const PageSize = 4096

  # Each generation hands every victim a different body (see
  # `run_repatch_commit_fault` in `hcr_lx_m3_txn.c`).
  const
    Gen1Values = [ValueA, ValueB, ValueC]
    Gen2Values = [ValueB, ValueC, ValueA]
    Gen3Values = [ValueC, ValueA, ValueB]
    OriginalValues = [OriginalA, OriginalB, OriginalC]

  suite "integration_hcr_linux_commit_failure_after_repatch_keeps_previous_generation":
    setup:
      let repoRoot = getCurrentDir()

    test "a generation-2 re-patch of a committed three-function set commits":
      # THE POSITIVE CONTROL, run first. If the second generation could not
      # commit at all, the failure arms below would be measuring nothing.
      let bodies = buildPatchBodies(repoRoot)
      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let run = runArm(fixture, "repatch-commit", bodies, ["-1"])

      check run["gen1Rc"].getInt() == 0
      check run["gen2PrepareRc"].getInt() == 0
      check run["gen2CommitRc"].getInt() == 0
      check run["txn"]["publishedCount"].getInt() == 3
      check run["txn"]["rolledBack"].getInt() == 0
      for i, fn in run["functions"].getElems():
        checkpoint("function: " & fn["name"].getStr())
        check fn["gen1Value"].getInt() == Gen1Values[i]
        check fn["value"].getInt() == Gen2Values[i]
        # The instrument can say "different": generation 2's text is not
        # generation 1's, and neither is the pristine text.
        check fn["after"].getStr() != fn["gen1Text"].getStr()
        check fn["after"].getStr() != fn["pristine"].getStr()
        check fn["gen1Text"].getStr() != fn["pristine"].getStr()
        check fn["generation"].getInt() == 2
        check fn["claimed"].getInt() == 1
        check fn["gen3Value"].getInt() == Gen3Values[i]
        check fn["gen3Generation"].getInt() == 3
      check run["gen3CommitRc"].getInt() == 0

    test "a generation-2 commit failing after N of 3 leaves every function on generation 1, for N = 0, 1 and 2":
      let bodies = buildPatchBodies(repoRoot)
      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      var restoredRepatchedSites = 0

      for fault in 0 .. 2:
        checkpoint("generation-2 fault at site " & $fault)
        let run = runArm(fixture, "repatch-commit", bodies, [$fault])

        # Generation 1 committed, and generation 2's prepare fully succeeded,
        # or this arm is measuring something other than a commit failure.
        check run["gen1Rc"].getInt() == 0
        check run["gen2PrepareRc"].getInt() == 0
        check run["txn"]["prepareComplete"].getInt() == 1

        # The commit failed, by name, at the site the lever named, and rolled
        # back exactly the N sites it had published.
        check run["gen2CommitRc"].getInt() != 0
        check run["gen2CommitRefusal"].getStr() == "text-protection-failed"
        check run["txn"]["failedSite"].getInt() == fault
        check run["txn"]["commitComplete"].getInt() == 0
        check run["txn"]["rolledBack"].getInt() == 1
        check run["txn"]["publishedCount"].getInt() == fault
        check run["txn"]["restoredCount"].getInt() == fault
        # No claim is released: every site was claimed before this transaction
        # and is still patched after it.
        check run["txn"]["releasedClaimCount"].getInt() == 0

        for i, fn in run["functions"].getElems():
          checkpoint("  function: " & fn["name"].getStr())
          check fn["gen1Value"].getInt() == Gen1Values[i]
          check fn["gen1Generation"].getInt() == 1

          # THE ASSERTIONS THAT MATTER: generation 1's value — not the
          # original, not generation 2's — and generation 1's bytes.
          check fn["value"].getInt() == Gen1Values[i]
          check fn["value"].getInt() != OriginalValues[i]
          check fn["value"].getInt() != Gen2Values[i]
          check fn["after"].getStr() == fn["gen1Text"].getStr()
          check fn["after"].getStr() != fn["pristine"].getStr()

          # The site table agrees with the text: live, generation 1, claim
          # held, and the word it records is generation 1's and is the word
          # actually in the window.
          check fn["siteLive"].getInt() == 1
          check fn["generation"].getInt() == 1
          check fn["claimed"].getInt() == 1
          check fn["sitePublishedWord"].getStr() ==
            fn["gen1PublishedWord"].getStr()
          check fn["liveWord"].getStr() == fn["gen1PublishedWord"].getStr()
          check fn["liveWord"].getStr() != fn["originalWord"].getStr()

          # Exactly the sites before the fault were published and restored.
          let wasPublished = i < fault
          check fn["published"].getInt() == ord(wasPublished)
          check fn["restored"].getInt() == ord(wasPublished)
          if wasPublished:
            inc restoredRepatchedSites
          # Bodies are never freed once published: a restored site keeps its
          # generation-1 body AND the rolled-back generation-2 body.
          check fn["siteRetainedBodyCount"].getInt() ==
            (if wasPublished: 2 else: 1)

          # The pre-state is admissible: generation 3 re-patches the site.
          check fn["gen3Value"].getInt() == Gen3Values[i]
          check fn["gen3Generation"].getInt() == 2
          check fn["gen3Claimed"].getInt() == 1

        # Retained versus freed, answered by the kernel as well as by the
        # provider: the N published generation-2 bodies stay mapped, the
        # 3 - N that were never reachable are unmapped.
        check run["txn"]["retainedBodyCount"].getInt() == fault
        check run["txn"]["freedBodyCount"].getInt() == 3 - fault
        check run["anonExecAfterGen2"].getInt() -
          run["anonExecBeforeGen2"].getInt() == fault * PageSize

        check run["gen3PrepareRc"].getInt() == 0
        check run["gen3CommitRc"].getInt() == 0

      # The N = 1 and N = 2 arms restored 1 + 2 re-patched sites between them;
      # without these the gate would not have exercised the defect at all.
      check restoredRepatchedSites == 3

    test "the same arm goes RED against a provider whose rollback restores the ORIGINAL word":
      # DISCRIMINATION, measured. One property removed and nothing else: the
      # restore stores the site's ORIGINAL word instead of the word published
      # before the transaction, which is the behaviour the issue records.
      let bodies = buildPatchBodies(repoRoot)
      let healthy = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let falsified = buildFixture(repoRoot, "hcr_lx_m3_txn_rollback_to_original",
        ["REPRO_HCR_HLX_M3_FALSIFY_ROLLBACK_TO_ORIGINAL_WORD"])

      let green = runArm(healthy, "repatch-commit", bodies, ["2"])
      let red = runArm(falsified, "repatch-commit", bodies, ["2"])

      for i, fn in green["functions"].getElems():
        check fn["value"].getInt() == Gen1Values[i]
        check fn["after"].getStr() == fn["gen1Text"].getStr()
      check green["gen3PrepareRc"].getInt() == 0

      # Red: the two published sites dropped generation 1 and run the
      # original code; the third, never published, kept generation 1. That is
      # the mixed version the issue describes.
      let redFns = red["functions"].getElems()
      check red["txn"]["rolledBack"].getInt() == 1
      check red["txn"]["restoredCount"].getInt() == 2
      # Asked of each WINDOW, not of each 80-byte snapshot: the victims are
      # adjacent in `.text`, so victim_b's snapshot also spans victim_c's
      # window, which the falsifier leaves on generation 1.
      for i in 0 .. 1:
        check redFns[i]["value"].getInt() == OriginalValues[i]
        check redFns[i]["liveWord"].getStr() == redFns[i]["originalWord"].getStr()
        check redFns[i]["liveWord"].getStr() != redFns[i]["gen1PublishedWord"].getStr()
      check redFns[2]["value"].getInt() == Gen1Values[2]
      check redFns[2]["liveWord"].getStr() == redFns[2]["gen1PublishedWord"].getStr()
      # The whole snapshot of the first victim spans only restored windows, so
      # there the full-text comparison is sound as well.
      check redFns[0]["after"].getStr() == redFns[0]["pristine"].getStr()
      # And the next reload is refused at the first restored site, because the
      # window no longer holds the word the site table says was published.
      check red["gen3PrepareRefusal"].getStr() == "entry-modified-externally"

else:
  suite "integration_hcr_linux_commit_failure_after_repatch_keeps_previous_generation":
    test "linux/amd64 only":
      skip("the Linux ELF provider (repro_hcr_linux_x86_64.h) exists only " &
        "on linux/amd64; this gate has no other-platform arm")
