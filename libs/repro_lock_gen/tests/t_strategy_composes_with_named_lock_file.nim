## One lock bound to a FILE and another bound to a STRATEGY in the same
## invocation; both resolve.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-5**.
##
## Design §5.5 states the composition this is the test of:
##
## > **A name may be bound to a file or to a strategy.** Both produce one
## > solved graph, and everything downstream of §6 consumes that graph without
## > asking where it came from:
## >
## > ```
## > repro build --lock targetRuntime=locks/aarch64.lock     # bound to a FILE
## > repro test  --lock targetRuntime=strategy:lowest        # bound to a STRATEGY
## > ```
##
## ## What this test can and cannot cover at M6, stated rather than implied
##
## `--lock <name>=<binding>` needs NAMED lock files, which are the DSL surface
## of milestone **NLF-M7** (`lockFile` declarations, designation, propagation,
## the `--lock <name>=<path>` binding). None of that exists yet, so this test
## does **not** assert on lock-file NAMES and the corpus case is only
## partially covered here.
##
## What does exist at M6, and what is asserted: two lock files in one process,
## one obtained by SELECTING a committed file and one by GENERATING under a
## strategy, both resolving to complete solved graphs, disagreeing about a
## version, and keeping their own identities. That is the mechanical content of
## §5.5's claim — "both produce one solved graph, and everything downstream
## consumes that graph without asking where it came from" — minus the naming.
## When NLF-M7 lands the binding, this file should grow the name assertions
## rather than be replaced.
##
## The honest limitation is recorded here because the alternative — writing a
## test that names lock files through some ad-hoc M6-only mechanism — would
## make the corpus case look covered while testing a mechanism that is not the
## one being shipped.
##
## ## What makes it a composition rather than two unrelated calls
##
## The two bindings are resolved through the SAME chokepoint
## (`resolveSolvedGraph`) in one invocation, over the same declarations and the
## same registry, and the file asserts that neither leaked into the other:
## the file-bound graph is not re-solved (its `source` is `sgsPinnedLock`) and
## the strategy-bound one is (`sgsGenerated` / a fresh generation), while both
## produce usable answers.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full.

import std/[os, tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  Published = ["1.2.0", "1.4.0", "1.9.0"]

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
    newPackage(LibFoo, @["1.2.0"])]

suite "NLF-STRAT-5 a file binding and a strategy binding in one invocation":

  test "both resolve, and they resolve differently":
    let reg = startRegistry("strat5")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)

      # The FILE binding's artifact: a committed lock, produced under
      # `highest` and written. Standing in for `--lock name=locks/x.lock`.
      let filePath = reg.scratch / "locks" / "pinned.lock"
      let written = runLockSolve(reg.request(workspace(), lsHighest), filePath)
      check fileExists(filePath)

      # --- the invocation: two bindings, one process ----------------------
      let fileBound = resolveSolvedGraph(filePath,
        reg.request(workspace(), lsDefault))
      let strategyBound = runStrategyHiddenLock(
        reg.request(workspace(), lsLowest), lsLowest)

      # Both produced a complete solved graph.
      check fileBound.solution.packages.hasKey(App)
      check fileBound.solution.packages.hasKey(LibFoo)
      check strategyBound.resolved().hasKey(App)
      check strategyBound.resolved().hasKey(LibFoo)

      # And they disagree, which is what makes them two graphs rather than one
      # answered twice.
      check fileBound.solution.packages[LibFoo] == "1.9.0"
      check strategyBound.resolved()[LibFoo] == "1.2.0"
      check fileBound.identity != strategyBound.lockIdentity
      check fileBound.identity == written.lockIdentity
    finally:
      reg.shutdown()

  test "the file binding is SELECTED, not re-solved":
    # §5.4's table: selection and generation are two operations. If the file
    # binding silently re-solved, the composition would be one operation under
    # two names and the strategy could not be said to compose with anything.
    let reg = startRegistry("strat5-selected")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let filePath = reg.scratch / "locks" / "pinned.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), filePath)

      resetSolveExecutions()
      let fileBound = resolveSolvedGraph(filePath,
        reg.request(workspace(), lsDefault))
      check fileBound.source == sgsPinnedLock
      check solveExecutions() == 0

      # The control: with no file to select, the same chokepoint GENERATES.
      let generated = resolveSolvedGraph(reg.scratch / "locks" / "absent.lock",
        reg.request(workspace(), lsLowest))
      check generated.source == sgsGenerated
      check solveExecutions() > 0
      check generated.solution.packages[LibFoo] == "1.2.0"
    finally:
      reg.shutdown()

  test "the strategy binding does not disturb the file binding's artifact":
    let reg = startRegistry("strat5-isolation")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let filePath = reg.scratch / "locks" / "pinned.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), filePath)
      let before = readFile(filePath)
      discard runStrategyHiddenLock(
        reg.request(workspace(), lsLowest), lsLowest)
      check readFile(filePath) == before
    finally:
      reg.shutdown()
