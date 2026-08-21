## One publication event; `highest` invalidates and `lowest` does not.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-GEN-3**: "One publication event;
## `highest` invalidates, `lowest` does not. Assert on whether the solve RAN,
## not only on lock content, or the raw fallback passes as though it were the
## target."
##
## This is the case design §5.7 says "decides it":
##
## > Consider `uses: "libfoo >=1.2 <2.0"`, with 1.2 … 1.9 published, and
## > upstream publishes 1.10.
## >
## >   * Under **`highest`**, the answer *moves*: 1.9 → 1.10. The publication
## >     **is material**.
## >   * Under **`lowest`**, the answer is unchanged: 1.2 either way. The
## >     publication **is immaterial**.
##
## ## Why the assertion is on `solveExecuted` and not on the lock
##
## The corpus case says why, and NLF-M6's exit criteria repeat it as a
## requirement rather than a suggestion: "NLF-GEN-3 asserts on solve execution,
## not only on lock content."
##
## Under `lowest`, a RAW path set — the mandated fallback, which records the
## whole published enumeration rather than the interval — invalidates when
## 1.10 appears, re-solves, and produces a byte-identical lock, because the
## answer really is 1.2 either way. So every assertion about lock content,
## lock identity or resolved versions passes against an implementation with no
## filtered interval in it at all. `solveExecuted` is the only observable that
## distinguishes them, and this file asserts it in both directions.
##
## ## The pairing
##
## The two halves ARE each other's pair: the same registry, the same
## publication, two strategies, opposite outcomes. That is a stronger form of
## NLF-M6's "show the mutation that DOES invalidate in the same run" than a
## second mutation would be, because a fingerprint that never changed would
## fail the `highest` half and a fingerprint that always changed would fail the
## `lowest` half. Neither constant survives.
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
  Before = ["1.2.0", "1.3.0", "1.4.0", "1.9.0"]
  After = ["1.2.0", "1.3.0", "1.4.0", "1.9.0", "1.10.0"]

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

template withPublication(tag: string; body: untyped) =
  ## One registry, seeded to §5.7's example, with `publish110` available to
  ## perform the single publication event both halves react to.
  let reg {.inject.} = startRegistry(tag)
  try:
    reg.server.publish(App, ["1.0.0"])
    reg.server.publish(LibFoo, Before)
    proc publish110() {.inject, used.} =
      reg.server.publish(LibFoo, After)
    body
  finally:
    reg.shutdown()

suite "NLF-GEN-3 the two strategies start from the same facts":

  test "the same registry gives 1.9 under highest and 1.2 under lowest":
    withPublication("gen3-premise"):
      let hi = reg.generate(workspace(), lsHighest)
      let lo = reg.generate(workspace(), lsLowest)
      check hi.resolved()[LibFoo] == "1.9.0"
      check lo.resolved()[LibFoo] == "1.2.0"
      # And the recorded intervals are the two §5.7 tabulates — opposite
      # sides of the selection, both bounded by the declared range.
      check hi.intervalOf(LibFoo) == "[1.9.0, 2.0.0)"
      check lo.intervalOf(LibFoo) == "[1.2.0, 1.2.0]"

suite "NLF-GEN-3 one event, two verdicts, asserted on solve execution":

  test "under highest the publication is material — the solve RUNS":
    withPublication("gen3-highest"):
      let first = reg.generate(workspace(), lsHighest)
      check first.solveExecuted

      # A control: with nothing published, the second generation must NOT
      # solve. Without it, "the solve ran" below would be satisfied by an
      # implementation that never caches at all.
      let unchanged = reg.generate(workspace(), lsHighest)
      check not unchanged.solveExecuted

      publish110()
      let after = reg.generate(workspace(), lsHighest)
      check after.solveExecuted
      check after.pathSetHitIndex == -1
      check after.resolved()[LibFoo] == "1.10.0"

  test "under lowest the same publication is immaterial — the solve does NOT run":
    withPublication("gen3-lowest"):
      let first = reg.generate(workspace(), lsLowest)
      check first.solveExecuted
      check first.resolved()[LibFoo] == "1.2.0"

      publish110()
      let after = reg.generate(workspace(), lsLowest)
      # THE assertion. A raw fallback would fail here and pass everything
      # below it.
      check not after.solveExecuted
      check after.pathSetHitIndex == 0

      # The lock content assertions that would have passed either way, kept
      # deliberately AFTER the one that discriminates, so the file reads as
      # what it is: the interesting property first, its consequences second.
      check after.lockDocument == first.lockDocument
      check after.lockIdentity == first.lockIdentity
      check after.resolved()[LibFoo] == "1.2.0"

  test "the two strategies are keyed apart, so neither answered for the other":
    # `Locking-And-Solver.md` §"Solver Cache" puts the strategy in the WEAK
    # fingerprint. If it did not, the `lowest` hit above could have been served
    # from the `highest` entry and the whole comparison would be an artifact.
    withPublication("gen3-keying"):
      let hi = reg.generate(workspace(), lsHighest)
      let lo = reg.generate(workspace(), lsLowest)
      check hi.solveWeakFingerprint != lo.solveWeakFingerprint
      check hi.solveExecuted
      check lo.solveExecuted
      check hi.pathSetsRecorded == 1
      check lo.pathSetsRecorded == 1
