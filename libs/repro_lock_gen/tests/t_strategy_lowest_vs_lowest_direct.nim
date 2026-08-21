## A transitively under-declared workspace fails under `lowest` and succeeds
## under `lowest-direct`.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-7**.
##
## This is also the milestone's SECOND folded criterion from NLF-M5:
##
## > **Strategy semantics beyond the extremes.** M5's `lowest`/`highest` merely
## > narrow the candidate universe to the extreme published version.
## > `lowest-direct` and the interaction with declared ranges are M6's, and
## > `t_strategy_lowest_vs_lowest_direct` is the case that proves the
## > difference is real rather than nominal.
##
## ## What "real rather than nominal" is made to mean here
##
## Two strategies that produce different graphs have not thereby been shown to
## differ in the RIGHT way. `lowest-direct` could differ from `lowest` by
## ignoring the strategy entirely, or by minimising nothing, and this fixture
## would still show two different answers. So the test asserts the shape of the
## difference, not merely its existence:
##
##   * the DIRECT dependency resolves to its minimum under BOTH strategies —
##     `lowest-direct` is still a minimising rule where the workspace's own
##     declaration is concerned, which is the half `lowest-direct` shares with
##     `lowest`;
##   * only the TRANSITIVE dependency moves, and it moves to its MAXIMUM, not
##     to something arbitrary;
##   * consequently the under-declared transitive bound is falsified under
##     `lowest` and not under `lowest-direct`.
##
## The first bullet is the discriminating one. A `lowest-direct` implemented as
## "do nothing" would satisfy the second and third by accident, because doing
## nothing leaves the solver free and this fixture's free answer happens to be
## admissible; it would fail the first, because the direct dependency would not
## be minimised.
##
## ## Where the under-declaration lives, and why it must be transitive
##
## `mid` declares `uses: leaf >=2.0` and its source needs 2.1. That bound is
## `mid`'s author's to get right, not the workspace's. `lowest` minimises it
## anyway and the workspace fails on somebody else's mistake — which is exactly
## why Cargo ships `-Z direct-minimal-versions` next to `-Z minimal-versions`,
## and why the corpus asks for the pair.
##
## ## What stands in for "fails", stated plainly
##
## No compiler runs. `MidTrueRequirement` is fixture data standing for what
## `mid`'s source requires — the thing a compile would discover — and it is
## checked with the REAL `satisfies` against the REAL resolved version read out
## of the REAL generated lock. See `t_strategy_false_minimum_is_caught`'s
## header, which states the same limitation at length for the direct case.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full.

import std/[sets, tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  Mid = "mid"
  Leaf = "leaf"
  MidDeclaredLeafBound = ">=2.0"
    ## What `mid`'s recipe says about `leaf`. Under-declared.
  MidTrueRequirement = ">=2.1"
    ## What `mid`'s source actually needs. Not visible to the solver.
  MidPublished = ["1.0.0", "1.5.0"]
  LeafPublished = ["2.0.0", "2.1.0", "2.5.0"]

proc workspace(): seq[PackageDecl] =
  ## `app` is the root. `mid` is DIRECT (the root declares a bound on it);
  ## `leaf` is reached only through `mid`, so it is transitive.
  @[
    newPackage(App, @["1.0.0"], @[newDependency(Mid, ">=1.0")]),
    newPackage(Mid, @["1.0.0"], @[newDependency(Leaf, MidDeclaredLeafBound)]),
    newPackage(Leaf, @["2.0.0"])]

template withRegistry(tag: string; body: untyped) =
  let reg {.inject.} = startRegistry(tag)
  try:
    reg.server.publish(App, ["1.0.0"])
    reg.server.publish(Mid, MidPublished)
    reg.server.publish(Leaf, LeafPublished)
    body
  finally:
    reg.shutdown()

suite "NLF-STRAT-7 the fixture really is transitively under-declared":

  test "leaf 2.0 satisfies what mid declared and not what mid needs":
    check satisfies("2.0.0", MidDeclaredLeafBound)
    check not satisfies("2.0.0", MidTrueRequirement)
    check satisfies("2.5.0", MidTrueRequirement)

  test "mid is direct and leaf is not":
    # Read off the solver's own `directDependencyNames`, so the test and the
    # objective cannot disagree about which packages `lowest-direct` minimises.
    let directs = directDependencyNames(workspace())
    check directs.contains(Mid)
    check not directs.contains(Leaf)

suite "NLF-STRAT-7 the two strategies differ in the RIGHT place":

  test "the direct dependency is minimised under BOTH":
    withRegistry("strat7-direct"):
      let lo = reg.generate(workspace(), lsLowest)
      let ld = reg.generate(workspace(), lsLowestDirect)
      # THE discriminating assertion. `lowest-direct` implemented as "ignore
      # the flag" would leave `mid` free here.
      check lo.resolved()[Mid] == "1.0.0"
      check ld.resolved()[Mid] == "1.0.0"

  test "only the transitive dependency moves, and it moves to its maximum":
    withRegistry("strat7-transitive"):
      let lo = reg.generate(workspace(), lsLowest)
      let ld = reg.generate(workspace(), lsLowestDirect)
      check lo.resolved()[Leaf] == "2.0.0"
      check ld.resolved()[Leaf] == LeafPublished[^1]

suite "NLF-STRAT-7 the pair: lowest falsifies, lowest-direct does not":

  test "the pair, in one run":
    withRegistry("strat7"):
      let lo = reg.generate(workspace(), lsLowest)
      let ld = reg.generate(workspace(), lsLowestDirect)

      # Both resolved, so what follows is a falsification and not an error.
      check lo.resolved().hasKey(Leaf)
      check ld.resolved().hasKey(Leaf)

      check not satisfies(lo.resolved()[Leaf], MidTrueRequirement)
      check satisfies(ld.resolved()[Leaf], MidTrueRequirement)

      # And the two are genuinely two: different graphs, different identities,
      # separately keyed.
      check lo.resolved() != ld.resolved()
      check lo.lockIdentity != ld.lockIdentity
      check lo.solveWeakFingerprint != ld.solveWeakFingerprint

suite "NLF-STRAT-7 lowest-direct records both interval directions":
  ## The materiality half of the same asymmetry: `lowest-direct` is the only
  ## strategy whose recorded interval direction is not uniform across the
  ## graph, so a path set that recorded one direction everywhere would key the
  ## transitive half on the wrong side of its selection.

  test "the direct package records downward and the transitive one upward":
    withRegistry("strat7-intervals"):
      let ld = reg.generate(workspace(), lsLowestDirect)
      # `mid`: at or below the selection, from the declared `>=1.0`.
      check ld.intervalOf(Mid) == "[1.0.0, 1.0.0]"
      # `leaf`: at or above the selection, `>=2.0` having no upper bound.
      check ld.intervalOf(Leaf) == "[2.5.0, +inf)"
