## Under `highest`, publishing a higher version in range invalidates the lock.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-GEN-2**: "Under `highest`,
## publishing a higher version in range invalidates. The under-invalidation
## direction — the only one producing a wrong answer."
##
## Design §5.7's worked example, verbatim, is the fixture:
##
## > Under **`highest`** with 1.9 selected, the filter is `[1.9, 2.0)`. 1.10 is
## > inside it. **Invalidation** — correct.
##
## ## Why 1.10 and not 1.99
##
## `1.10` is chosen deliberately. Under a LEXICOGRAPHIC ordering `1.10 < 1.9`,
## so an implementation that compared version strings rather than semver
## triples would place 1.10 outside `[1.9, 2.0)`, report no invalidation, and
## keep answering 1.9 while 1.10 was the correct answer. That is the
## under-invalidation direction, and it is the only one that produces a wrong
## answer rather than extra work — which is why the corpus names it.
##
## ## Both directions, in one run
##
## NLF-M6's exit criteria require the paired mutation, and here the pairing is
## the other way round from NLF-GEN-1: the interesting claim is that something
## DOES invalidate, so the pair is a publication that must NOT.
##
##   1. **1.10.0**, inside `[1.9, 2.0)` — invalidates, and the answer moves to
##      it. Asserting the answer moved is what separates "the cache missed"
##      from "the cache missed for the right reason".
##   2. **2.5.0**, outside the declared range and therefore outside the
##      interval — does not invalidate. Without it, an implementation that
##      re-solved on every registry write would pass (1) perfectly.
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
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

suite "NLF-GEN-2 the interval is the one §5.7 specifies":

  test "highest over >=1.2 <2.0 with 1.9 selected records [1.9, 2.0)":
    let reg = startRegistry("gen2-shape")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.2.0", "1.4.0", "1.9.0"])
      let r = reg.generate(workspace(), lsHighest)
      check r.solveExecuted
      check r.resolved()[LibFoo] == "1.9.0"
      # At or above the selection, up to the range's EXCLUSIVE upper bound.
      check r.intervalOf(LibFoo) == "[1.9.0, 2.0.0)"
    finally:
      reg.shutdown()

suite "NLF-GEN-2 a higher version in range invalidates":

  test "publishing 1.10 invalidates and moves the answer; 2.5 does neither":
    let reg = startRegistry("gen2")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.2.0", "1.4.0", "1.9.0"])

      let first = reg.generate(workspace(), lsHighest)
      check first.solveExecuted
      check first.resolved()[LibFoo] == "1.9.0"

      # --- the material publication --------------------------------------
      reg.server.publish(LibFoo, ["1.2.0", "1.4.0", "1.9.0", "1.10.0"])
      let after = reg.generate(workspace(), lsHighest)
      check after.solveExecuted
      check after.pathSetHitIndex == -1
      # The answer MOVED. A miss that produced the same answer would mean the
      # cache was merely noisy; a miss that moves the answer is the case the
      # corpus calls "the only one producing a wrong answer".
      check after.resolved()[LibFoo] == "1.10.0"
      check after.lockDocument != first.lockDocument
      check after.intervalOf(LibFoo) == "[1.10.0, 2.0.0)"

      # --- THE PAIR: a publication outside the range ----------------------
      reg.server.publish(LibFoo,
        ["1.2.0", "1.4.0", "1.9.0", "1.10.0", "2.5.0"])
      let outside = reg.generate(workspace(), lsHighest)
      check not outside.solveExecuted
      check outside.pathSetHitIndex >= 0
      check outside.lockDocument == after.lockDocument
    finally:
      reg.shutdown()

  test "the same publication under a lexicographic order would be missed":
    # A guard on the fixture rather than on the implementation: if `1.10.0`
    # ever stopped being greater than `1.9.0` under the ordering this test
    # relies on, the case above would still pass and would have stopped
    # testing anything.
    check cmpSemver(parseSemver("1.10.0"), parseSemver("1.9.0")) > 0
    check "1.10.0" < "1.9.0"
