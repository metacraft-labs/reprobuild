## `lowest` and `highest` produce different graphs, identities and fingerprints.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-2**: "The two strategies
## produce different resolved version sets, different lock identities and
## disjoint fingerprints. Catches a strategy flag accepted and ignored — which
## NLF-STRAT-1 alone would miss if the ignored default happened to be
## `highest`."
##
## ## What "differ" has to mean here, and why "not equal" is not enough
##
## Two strategies could differ and both be wrong. So this file does not stop at
## inequality: it asserts each strategy picked the EXTREME ADMISSIBLE version
## on its own side of the declared range — the lowest version satisfying
## `>=1.2 <2.0` and the highest — over a published universe that extends
## outside the range in BOTH directions. A flag that was accepted and then
## quietly mapped to "first model clingo returned" would satisfy inequality on
## some runs and fail this.
##
## The universe extending outside the range in both directions is the second
## half of that. NLF-M5's implementation narrowed the candidate universe to the
## extreme PUBLISHED version before the declared ranges were applied, which for
## this fixture selects 1.0.0 — outside `>=1.2` — and reports UNSAT. So this
## file is also the regression for that defect: it cannot pass against
## candidate narrowing at all.
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
  Published = ["1.0.0", "1.2.0", "1.4.0", "1.9.0", "2.5.0"]
    ## Extends BELOW the declared lower bound and ABOVE the declared upper
    ## bound, so "the extreme published version" and "the extreme admissible
    ## version" are different answers and the test can tell them apart.

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

template withRegistry(tag: string; body: untyped) =
  let reg {.inject.} = startRegistry(tag)
  try:
    reg.server.publish(App, ["1.0.0"])
    reg.server.publish(LibFoo, Published)
    body
  finally:
    reg.shutdown()

suite "NLF-STRAT-2 each strategy picks its extreme ADMISSIBLE version":

  test "lowest takes 1.2 and highest takes 1.9, not 1.0 and 2.5":
    withRegistry("strat2-extremes"):
      let lo = reg.generate(workspace(), lsLowest)
      let hi = reg.generate(workspace(), lsHighest)
      check lo.resolved()[LibFoo] == "1.2.0"
      check hi.resolved()[LibFoo] == "1.9.0"
      # The published extremes are outside the range. A strategy that ranked
      # the published list instead of the admissible one would name these.
      check lo.resolved()[LibFoo] != Published[0]
      check hi.resolved()[LibFoo] != Published[^1]

  test "the declared range is a hard constraint the strategy cannot overrule":
    # NLF-M5's narrowing made this an UNSAT, which is the failure this file
    # exists to keep out. Both strategies must produce an answer at all.
    withRegistry("strat2-sat"):
      for strategy in [lsLowest, lsHighest, lsDefault, lsLowestDirect]:
        let r = reg.generate(workspace(), strategy)
        let v = r.resolved()[LibFoo]
        check satisfies(v, ">=1.2 <2.0")

suite "NLF-STRAT-2 different sets, identities and fingerprints":

  test "the resolved version set differs":
    withRegistry("strat2-sets"):
      let lo = reg.generate(workspace(), lsLowest)
      let hi = reg.generate(workspace(), lsHighest)
      check lo.resolved() != hi.resolved()

  test "the lock identities differ":
    withRegistry("strat2-identity"):
      let lo = reg.generate(workspace(), lsLowest)
      let hi = reg.generate(workspace(), lsHighest)
      check lo.lockIdentity.isValid()
      check hi.lockIdentity.isValid()
      check lo.lockIdentity != hi.lockIdentity

  test "the solve-edge weak fingerprints are disjoint":
    # `Locking-And-Solver.md` §"Solver Cache": the strategy is in the weak
    # fingerprint "because two strategies over identical constraints are two
    # different computations". If they shared one, either could be served from
    # the other's cache entry.
    withRegistry("strat2-fingerprint"):
      let lo = reg.generate(workspace(), lsLowest)
      let hi = reg.generate(workspace(), lsHighest)
      let df = reg.generate(workspace(), lsDefault)
      let ld = reg.generate(workspace(), lsLowestDirect)
      var seen: seq[string] = @[]
      for r in [lo, hi, df, ld]:
        check r.solveWeakFingerprint.len == 64
        check r.solveWeakFingerprint notin seen
        seen.add(r.solveWeakFingerprint)

  test "the recorded intervals sit on opposite sides of the selection":
    withRegistry("strat2-intervals"):
      let lo = reg.generate(workspace(), lsLowest)
      let hi = reg.generate(workspace(), lsHighest)
      check lo.intervalOf(LibFoo) == "[1.2.0, 1.2.0]"
      check hi.intervalOf(LibFoo) == "[1.9.0, 2.0.0)"
