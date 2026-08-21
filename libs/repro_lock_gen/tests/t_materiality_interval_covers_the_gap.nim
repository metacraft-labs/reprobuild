## `>=1.2` selecting 1.4: publishing 1.3 invalidates.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-GEN-4**: "`>=1.2` selecting 1.4;
## publishing 1.3 invalidates."
##
## Design §5.7 calls this "the case that shows the interval is doing real work
## rather than being a restatement of the answer":
##
## > `>=1.2` where 1.2 does not exist and the lowest available is 1.4. The
## > filter `[1.2, 1.4]` covers the *gap*, so publishing 1.3 invalidates — as
## > it must, because the answer moves to 1.3.
##
## ## What this rules out that the other three cases do not
##
## Every other materiality case here is satisfied by an implementation that
## records only the WITNESS — "the selection was 1.4, and 1.4 is still
## published". That implementation is wrong in exactly one place, and it is
## this one: it would keep answering 1.4 after 1.3 appeared, silently, forever.
## §5.7 calls the recorded fact "a witness plus a negative bound"; this file is
## the test of the negative bound.
##
## ## The pairing, and the second thing this file measures
##
## NLF-M6's exit criteria require the mutation that does NOT invalidate in the
## same run, so the fixture publishes 1.1 as well — below the declared lower
## bound and therefore outside `[1.2, 1.4]`.
##
## And because the registry can be moved BACK, this file is also where the
## two-phase structure becomes observable. §5.7 / `Locking-And-Solver.md`
## §"Lookup": "one weak fingerprint may have several recorded path sets, tried
## in order against live metadata, under a bounded candidate budget." Publishing
## 1.3 records a second path set under the SAME weak fingerprint; withdrawing
## it again makes the FIRST one match. A single-entry cache under a longer name
## would re-solve on the way back.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full.

import std/[tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"

proc workspace(): seq[PackageDecl] =
  ## `>=1.2` with no upper bound, so the interval's lower half comes from the
  ## DECLARED bound and its upper half from the SELECTION — which is what makes
  ## the gap between them real rather than an artifact of a narrow range.
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2")]),
    newPackage(LibFoo, @["1.4.0"])]

suite "NLF-GEN-4 the gap is inside the recorded interval":

  test "1.2 was never published, and the interval starts there anyway":
    let reg = startRegistry("gen4-shape")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      let r = reg.generate(workspace(), lsLowest)
      check r.solveExecuted
      check r.resolved()[LibFoo] == "1.4.0"
      # `[1.2.0, 1.4.0]`, not `[1.4.0, 1.4.0]`. The lower bound is the DECLARED
      # one; an implementation that recorded the selection as both ends would
      # produce the latter and pass every other case in this milestone.
      check r.intervalOf(LibFoo) == "[1.2.0, 1.4.0]"
    finally:
      reg.shutdown()

suite "NLF-GEN-4 publishing into the gap invalidates":

  test "1.3 invalidates and moves the answer; 1.1 does neither":
    let reg = startRegistry("gen4")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])

      let first = reg.generate(workspace(), lsLowest)
      check first.solveExecuted
      check first.resolved()[LibFoo] == "1.4.0"

      # --- THE PAIR, first: below the declared bound, outside the interval --
      reg.server.publish(LibFoo, ["1.1.0", "1.4.0", "1.9.0"])
      let below = reg.generate(workspace(), lsLowest)
      check not below.solveExecuted
      check below.pathSetHitIndex == 0
      check below.lockDocument == first.lockDocument

      # --- the gap publication ---------------------------------------------
      reg.server.publish(LibFoo, ["1.1.0", "1.3.0", "1.4.0", "1.9.0"])
      let gap = reg.generate(workspace(), lsLowest)
      check gap.solveExecuted
      check gap.pathSetHitIndex == -1
      check gap.resolved()[LibFoo] == "1.3.0"
      check gap.intervalOf(LibFoo) == "[1.2.0, 1.3.0]"
      check gap.lockDocument != first.lockDocument
    finally:
      reg.shutdown()

suite "NLF-GEN-4 two path sets under one weak fingerprint":

  test "withdrawing 1.3 matches the FIRST recorded path set, without solving":
    let reg = startRegistry("gen4-twophase")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      let first = reg.generate(workspace(), lsLowest)
      check first.pathSetsRecorded == 1

      reg.server.publish(LibFoo, ["1.3.0", "1.4.0", "1.9.0"])
      let gap = reg.generate(workspace(), lsLowest)
      check gap.solveExecuted
      check gap.pathSetsRecorded == 2
      check gap.solveWeakFingerprint == first.solveWeakFingerprint

      # Upstream yanks 1.3. The registry is back in the state the FIRST path
      # set was taken over.
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      let back = reg.generate(workspace(), lsLowest)
      check not back.solveExecuted
      check back.pathSetHitIndex == 0
      check back.lockDocument == first.lockDocument
      # Still two entries: matching an older one must not discard the newer.
      check back.pathSetsRecorded == 2

      # And forward again, still without solving.
      reg.server.publish(LibFoo, ["1.3.0", "1.4.0", "1.9.0"])
      let forward = reg.generate(workspace(), lsLowest)
      check not forward.solveExecuted
      check forward.pathSetHitIndex == 1
      check forward.lockDocument == gap.lockDocument
    finally:
      reg.shutdown()

suite "NLF-GEN-4 raw is reached, and it is the mandated fallback":
  ## §5.7: "**Raw remains the correct fallback** and should be specified as the
  ## behaviour when an interval cannot be computed." The `default` strategy
  ## states no direction, so there is no side of the selection on which "no
  ## better candidate exists" is a claim the solve made — and `default` is the
  ## strategy most invocations run under, so the fallback is the hot path.

  test "under default the observation is raw, with a stated reason":
    let reg = startRegistry("gen4-raw")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      let r = reg.generate(workspace(), lsDefault)
      check r.solveExecuted
      check r.intervalOf(LibFoo) == "raw"
      check r.observationFor(LibFoo).reason.len > 0
    finally:
      reg.shutdown()

  test "raw over-invalidates where the interval would not, and never under-invalidates":
    # The two halves of §5.7's claim about the fallback, measured against each
    # other over ONE publication that the interval classifies as immaterial.
    let reg = startRegistry("gen4-raw-pair")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0"])
      let rawFirst = reg.generate(workspace(), lsDefault)
      let lowFirst = reg.generate(workspace(), lsLowest)
      check rawFirst.solveExecuted
      check lowFirst.solveExecuted

      # 1.9.5 is above the `lowest` selection and therefore outside its
      # interval; raw has no interval and sees the whole list change.
      reg.server.publish(LibFoo, ["1.4.0", "1.9.0", "1.9.5"])
      let rawAgain = reg.generate(workspace(), lsDefault)
      let lowAgain = reg.generate(workspace(), lsLowest)
      check rawAgain.solveExecuted        # over-invalidated: extra work
      check not lowAgain.solveExecuted    # precise: no work

      # `lowest` did not merely skip the solve — it returned the SAME lock, so
      # the skip cost nothing in correctness.
      check lowAgain.lockDocument == lowFirst.lockDocument

      # Note what is deliberately NOT asserted about the raw half: that its
      # re-solve produced a byte-identical lock. §5.7 says over-invalidation
      # "costs one solve, never a rebuild" because the re-solve usually emits
      # the same lock and early cutoff stops there — but `default` states no
      # version preference at all, so a larger candidate set can legitimately
      # move its answer. Asserting byte-equality here would be asserting a
      # property of `default`'s arbitrary choice rather than of the fallback,
      # and it fails against this fixture for exactly that reason.
      check rawAgain.solveWeakFingerprint == rawFirst.solveWeakFingerprint
    finally:
      reg.shutdown()
