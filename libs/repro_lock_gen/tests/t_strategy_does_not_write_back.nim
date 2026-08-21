## A strategy overrides a committed lock for the invocation and never writes
## it back.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-3**: "`repro test
## --strategy lowest` against a committed lock resolves differently and leaves
## the lock byte-identical."
##
## Design §5.5 records the decision and its two halves:
##
## > a strategy **overrides** the committed lock for that invocation and
## > **never writes it back**.
## >
## >   * **Overrides** rather than erroring, because the primary use is exactly
## >     an application *with* a committed lock checking that its declared
## >     ranges still hold. …
## >   * **Never writes back**, because a strategy-produced graph is an
## >     experiment, not the project's intended state. Under `lowest` a
## >     write-back would downgrade the whole project as a side effect of
## >     running a test.
##
## ## Both halves must be asserted, and the corpus wording says why
##
## "Resolves differently AND leaves the lock byte-identical". Either alone is
## satisfied by a broken implementation:
##
##   * a strategy that did nothing at all would leave the lock byte-identical;
##   * a strategy that wrote back would resolve differently.
##
## So the two run against one committed lock in one test, and a third
## assertion checks the committed lock's own answer is still what a pinned
## consumer reads afterwards — because "the bytes are the same" and "the
## project still resolves the way it did" are different claims and only the
## second is what the decision is protecting.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full.

import std/[os, strutils, tables, unittest]

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

suite "NLF-STRAT-3 a strategy never writes back":

  test "the committed lock is byte-identical and the answer still differs":
    let reg = startRegistry("strat3")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)

      # The project's committed state: generated under `highest` and WRITTEN,
      # which is the operation §5.5 says writing back requires.
      let committed = reg.scratch / "project" / "repro.lock"
      let intended = runLockSolve(
        reg.request(workspace(), lsHighest), committed)
      check fileExists(committed)
      check intended.resolved()[LibFoo] == "1.9.0"
      let committedBytes = readFile(committed)

      # The experiment: the same project under `lowest`, through the hidden-
      # lock door.
      let experiment = runStrategyHiddenLock(
        reg.request(workspace(), lsLowest), lsLowest)

      # --- half one: it resolved differently ------------------------------
      check experiment.resolved()[LibFoo] == "1.2.0"
      check experiment.resolved() != intended.resolved()
      check experiment.lockIdentity != intended.lockIdentity

      # --- half two: the committed lock did not move ----------------------
      check readFile(committed) == committedBytes
      check experiment.lockPath != committed
      check not experiment.lockPath.startsWith(reg.scratch / "project")

      # --- and the project still resolves the way it did ------------------
      # Byte-equality is evidence for this; it is not the same claim, and a
      # writer that rewrote the file with equivalent-but-reordered content
      # would pass byte-equality only by accident.
      check lockToSolution(parseSolvedGraphLock(readFile(committed)))
        .packages[LibFoo] == "1.9.0"
    finally:
      reg.shutdown()

  test "the write-back operation still writes, so `never` is a real restriction":
    # If `runLockSolve` with a destination did not write either, the assertion
    # above would be measuring an inert code path rather than a decision.
    let reg = startRegistry("strat3-control")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let committed = reg.scratch / "project" / "repro.lock"
      discard runLockSolve(reg.request(workspace(), lsHighest), committed)
      let before = readFile(committed)
      # `repro lock solve --lowest --write` — §5.5's explicit spelling.
      let rewritten = runLockSolve(reg.request(workspace(), lsLowest),
        committed)
      check readFile(committed) != before
      check readFile(committed) == rewritten.lockDocument
      check lockToSolution(parseSolvedGraphLock(readFile(committed)))
        .packages[LibFoo] == "1.2.0"
    finally:
      reg.shutdown()
