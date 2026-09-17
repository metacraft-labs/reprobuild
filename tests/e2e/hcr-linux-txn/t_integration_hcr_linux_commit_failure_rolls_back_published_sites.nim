## HLX-M3 verification gate
## `integration_hcr_linux_commit_failure_rolls_back_published_sites`.
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §11.2 (commit as a
## sequence of single atomic stores, each individually reversible) and §4.5
## (rollback restores the ORIGINAL word; claims are released on rollback).
## Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M3.
##
## THE CLAIM. A commit that fails after N of M sites are published restores all
## N to their saved words, every function returns its original value, and no
## patch page or claim is leaked. §11.1's description of the pre-milestone
## state is the thing being removed: "an eight-operation commit sequence with
## no undo path; a failure mid-sequence ... leaves the target in whatever
## partial state it reached."
##
## WHAT IS AND IS NOT GUARANTEED, stated here because the milestone requires it
## be stated. Per-function atomicity is the tier-1 guarantee: each store is one
## naturally aligned 8-byte store and each is individually reversible from the
## word prepare saved. It does NOT make concurrent execution safe — HLX-M4
## measured bare tier-1 publication killing 18-21 of 24 twelve-thread
## processes — and it does NOT give set-wide atomicity: under tier 1 a thread
## may already have executed function A's new body by the time function B's
## commit fails. Rollback restores every published site; it cannot un-execute.
## Set-wide atomicity is HLX-M4's quiescence and is not claimed here. This gate
## is single-threaded for exactly that reason.
##
## HOW THE FAILURE IS INDUCED. `repro_hcr_lx_commit_fault_site` names the site
## index whose text-protection transient is refused, and the refusal is
## delivered AS A SYSCALL RESULT — `-EACCES`, what a kernel that refuses the
## transition returns — so the branch taken is the production failure branch
## and not a shortcut around it. There is no other way to make `mprotect` fail
## on the k-th site of a set on demand, and a gate that cannot choose k cannot
## show that N of M published sites were restored. The lever is test-only; the
## agent never sets it.
##
## `allowed_mocks: none`. Real multi-function patch set over three real
## patchable victims in a real process, real bodies from a real relocatable
## object, the production transaction through the no-mock probe shim, the real
## cross-patcher claim map, and `/proc/self/maps` for the leak check.
##
## ------------------------------------------------------------------------
## DISCRIMINATION, measured by this file:
##
##   * the N = 0, 1, 2 arms produce THREE DIFFERENT published counts from the
##     same set, so an arm's expectations are not satisfiable by another
##     arm's observations;
##   * the positive control (no fault) publishes all three and the text of all
##     three changes, so the byte comparison is not an instrument that can only
##     say "identical";
##   * the falsifier build
##     (`REPRO_HCR_HLX_M3_FALSIFY_NO_ROLLBACK_ON_COMMIT_FAILURE`) removes the
##     rollback and nothing else, and the N = 2 arm MUST then leave two
##     functions returning their NEW values with changed text.

import std/[json, os, sets, strutils, unittest]

when defined(linux) and defined(amd64):
  import m3_fixture

  const PageSize = 4096

  suite "integration_hcr_linux_commit_failure_rolls_back_published_sites":
    setup:
      let repoRoot = getCurrentDir()

    test "the claim map the leak assertion needs is present":
      let path = claimMapPath(repoRoot)
      if not fileExists(path):
        checkpoint("HLX-M3 gate needs the codetracer-native-recorder " &
          "checkout beside this repo: " & path & " is not there.")
      require fileExists(path)

    test "a three-function set commits, which is what makes a failure mean something":
      # THE POSITIVE CONTROL, run first. If a three-site commit could not
      # succeed at all, every failure arm below would be green for the wrong
      # reason.
      let bodies = buildPatchBodies(repoRoot)
      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let run = runArm(fixture, "commit", bodies, ["-1"])

      check run["prepareRc"].getInt() == 0
      check run["commitRc"].getInt() == 0
      check run["txn"]["publishedCount"].getInt() == 3
      check run["txn"]["rolledBack"].getInt() == 0
      let expected = [ValueA, ValueB, ValueC]
      for i, fn in run["functions"].getElems():
        check fn["value"].getInt() == expected[i]
        check fn["before"].getStr() != fn["after"].getStr()

      # ONE NATURALLY ALIGNED 8-BYTE STORE PER SITE, NEVER WIDENED.
      #
      # It cannot be asked of each victim's snapshot in isolation the way the
      # single-site gates ask it: the three victims are adjacent in `.text`,
      # and an 80-byte snapshot around one of them overlaps a neighbour's
      # publication window, so "every changed byte is in ONE aligned block" is
      # false for a correct three-site commit. Asked of the SET instead —
      # which is the stronger question anyway:
      #
      #   a. every byte that changed anywhere lies inside one of the three
      #      windows the transaction reported, so nothing was written outside
      #      them;
      #   b. all three windows moved, so no site was silently skipped.
      var windows: seq[uint64] = @[]
      for site in run["txn"]["sites"]:
        let w = parseHexInt(site["window"].getStr()[2 .. ^1]).uint64
        # A window that is not 8-byte aligned could not be published atomically
        # at all (design §4.2).
        check (w and 7'u64) == 0'u64
        windows.add(w)
      check windows.len == 3

      var movedWindows = initHashSet[uint64]()
      for fn in run["functions"]:
        let addresses = differingAddresses(fn)
        check addresses.len > 0
        for a in addresses:
          check windows.contains(a and not 7'u64)
          movedWindows.incl(a and not 7'u64)
      check movedWindows.len == 3
      # Three retained bodies, one page each, all still mapped — and the claim
      # map holds one claim per published window.
      check run["anonExecAfter"].getInt() -
        run["anonExecBefore"].getInt() == 3 * PageSize
      check run["claimsAfter"].getInt() == 3

    test "a commit failing after N of M restores all N, for N = 0, 1 and 2":
      let bodies = buildPatchBodies(repoRoot)
      let fixture = buildFixture(repoRoot, "hcr_lx_m3_txn")
      var publishedCounts: seq[int] = @[]

      for fault in 0 .. 2:
        checkpoint("fault at site " & $fault)
        let run = runArm(fixture, "commit", bodies, [$fault])

        # Prepare must have fully succeeded, or this arm is measuring a prepare
        # failure wearing a commit failure's label.
        check run["prepareRc"].getInt() == 0
        check run["txn"]["prepareComplete"].getInt() == 1

        # The commit failed, by name, at the site the lever named.
        check run["commitRc"].getInt() != 0
        check run["commitRefusal"].getStr() == "text-protection-failed"
        check run["txn"]["failedSite"].getInt() == fault
        check run["txn"]["commitComplete"].getInt() == 0
        check run["txn"]["rolledBack"].getInt() == 1

        # N sites were published and N were restored. The equality is the
        # transaction's own accounting; the byte comparison below is the
        # independent check on it.
        check run["txn"]["publishedCount"].getInt() == fault
        check run["txn"]["restoredCount"].getInt() == fault
        publishedCounts.add(fault)

        # THE ASSERTION THAT MATTERS: every function's text is byte-identical
        # to the pre-transaction snapshot, and every function returns its
        # original value.
        for fn in run["functions"]:
          checkpoint("  function: " & fn["name"].getStr())
          check fn["before"].getStr() == fn["after"].getStr()
          check fn["value"].getInt() == fn["originalValue"].getInt()
          # Rollback retires the site, so the window is an all-NOP pre-state
          # again and a later patch re-plans from scratch (§4.5).
          check fn["siteLive"].getInt() == 0

        # NO CLAIM LEAKED. Every window this transaction claimed — published or
        # not — is claimable by anyone again.
        check run["claimsAfter"].getInt() == 0
        check run["txn"]["releasedClaimCount"].getInt() == 3

        # NO PATCH PAGE LEAKED, answered by the kernel rather than by the
        # provider's own counter. Exactly the N published bodies are retained
        # (§4.5/§6.1 forbid freeing code a PC may be standing in, and under
        # tier 1 the provider cannot prove one is not); the M - N that were
        # never reachable are unmapped.
        check run["anonExecAfter"].getInt() - run["anonExecBefore"].getInt() ==
          fault * PageSize
        check run["txn"]["retainedBodyCount"].getInt() == fault
        check run["txn"]["freedBodyCount"].getInt() == 3 - fault

      # The three arms really are three different states of the world.
      check publishedCounts == @[0, 1, 2]

    test "the same arm goes RED against a provider with no undo path":
      # DISCRIMINATION, measured. One property removed and nothing else: the
      # commit failure returns without rolling back, which is §11.1's
      # description of the state before this milestone.
      let bodies = buildPatchBodies(repoRoot)
      let healthy = buildFixture(repoRoot, "hcr_lx_m3_txn")
      let falsified = buildFixture(repoRoot, "hcr_lx_m3_txn_no_rollback",
        ["REPRO_HCR_HLX_M3_FALSIFY_NO_ROLLBACK_ON_COMMIT_FAILURE"])

      let green = runArm(healthy, "commit", bodies, ["2"])
      let red = runArm(falsified, "commit", bodies, ["2"])

      # Green: all three back to their original values and bytes.
      for fn in green["functions"]:
        check fn["before"].getStr() == fn["after"].getStr()
        check fn["value"].getInt() == fn["originalValue"].getInt()

      # Red: the two sites that were published stay published. If this arm were
      # also green the assertions above would be measuring nothing.
      let redFns = red["functions"].getElems()
      check redFns[0]["value"].getInt() == ValueA
      check redFns[1]["value"].getInt() == ValueB
      check redFns[0]["before"].getStr() != redFns[0]["after"].getStr()
      check redFns[1]["before"].getStr() != redFns[1]["after"].getStr()
      # The third never got its store in either build, so it is NOT what
      # distinguishes the two arms.
      check redFns[2]["value"].getInt() == OriginalC
      check redFns[2]["before"].getStr() == redFns[2]["after"].getStr()
      check red["txn"]["rolledBack"].getInt() == 0

else:
  suite "integration_hcr_linux_commit_failure_rolls_back_published_sites":
    test "linux/amd64 only":
      skip()
