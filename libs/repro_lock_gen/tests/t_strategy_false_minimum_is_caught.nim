## A declared minimum that is false passes under `highest` and fails under
## `lowest`.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-1**: "`--strategy highest`
## passes and `--strategy lowest` fails to compile, for a package whose
## declared minimum is wrong. Assert the PAIR."
##
## Design §5.4 states the principle this is the test of:
##
## > **A declared version range is a claim, and a strategy is the experiment
## > that tests it.** Writing `uses: "libfoo >=1.2 <2.0"` asserts that the
## > package works with `libfoo 1.2`. Nothing verifies that assertion until
## > something is built against 1.2 — and under a highest-wins default, nothing
## > ever is.
##
## ## What stands in for "fails to compile", stated plainly
##
## **No compiler runs in this test, and the corpus wording says one does.** The
## honest statement of what is measured instead:
##
## `libfoo` 1.0 and 1.4 are both published. `app` DECLARES `uses: libfoo >=1.0`
## and its source actually needs an API introduced in 1.4 — a fact that, in a
## real workspace, is discovered by the compile failing. Here that fact is
## carried by `TrueRequirement` and checked with the REAL `satisfies` from
## `repro_solver/version_constraints` — the same range checker the solver
## grounds `version_in_range` with — against the REAL resolved version read
## back out of the REAL generated lock document.
##
## So what is measured is: *under `lowest` the resolved graph violates the
## package's true requirement, and under `highest` it does not.* That is the
## proposition a compile failure would be evidence for, checked directly.
## Building a compiler invocation around it would add a C toolchain dependency
## to a lock-generation test and would not make the proposition any more true.
## This is a limitation of the test, recorded here rather than papered over.
##
## It is NOT a mock. `TrueRequirement` is fixture data — a constant standing
## for what the package's source requires — in exactly the sense the published
## version lists are fixture data. Nothing on the path from declaration to
## resolved version is substituted.
##
## ## The pair, and why asserting only half proves nothing
##
## The corpus says "Assert the PAIR", and the reason is sharp: a test that only
## showed `lowest` failing would pass against an implementation where `lowest`
## always fails — including one that resolved to nothing at all. A test that
## only showed `highest` passing would pass against an implementation that
## ignored the strategy flag entirely, which is precisely the defect NLF-M5
## shipped. Both halves run against ONE registry in ONE test below.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full, and the
## paragraph above for the one piece of fixture data doing non-obvious work.

import std/[tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  DeclaredMinimum = ">=1.0"
    ## What `app`'s recipe says. This is the claim under test.
  TrueRequirement = ">=1.4"
    ## What `app`'s source actually needs — the thing a compile would discover.
    ## Deliberately NOT visible to the solver: if it were declared, there would
    ## be no false minimum and nothing to falsify.
  Published = ["1.0.0", "1.2.0", "1.4.0", "1.6.0"]

proc workspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[newDependency(LibFoo, DeclaredMinimum)]),
    newPackage(LibFoo, @["1.0.0"])]

suite "NLF-STRAT-1 the false minimum is a false minimum":
  ## Guards on the fixture. If the declared minimum were already true, or the
  ## registry did not publish anything below the true requirement, the pair
  ## below would pass for reasons that have nothing to do with strategies.

  test "the declared minimum admits a version the true requirement rejects":
    check satisfies("1.0.0", DeclaredMinimum)
    check not satisfies("1.0.0", TrueRequirement)
    check satisfies("1.6.0", DeclaredMinimum)
    check satisfies("1.6.0", TrueRequirement)

suite "NLF-STRAT-1 highest passes and lowest fails, in one run":

  test "the pair":
    let reg = startRegistry("strat1")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)

      let hi = reg.generate(workspace(), lsHighest)
      let lo = reg.generate(workspace(), lsLowest)

      let hiVersion = hi.resolved()[LibFoo]
      let loVersion = lo.resolved()[LibFoo]

      # Both resolved: the failure below is a FALSIFICATION, not an error.
      check hiVersion == "1.6.0"
      check loVersion == "1.0.0"

      # --- the half that passes -------------------------------------------
      check satisfies(hiVersion, TrueRequirement)

      # --- the half that fails: `lowest` catches the false minimum --------
      check not satisfies(loVersion, TrueRequirement)

      # Both halves resolved against the SAME declared range, which is what
      # makes this a statement about the strategy rather than about the recipe.
      check satisfies(hiVersion, DeclaredMinimum)
      check satisfies(loVersion, DeclaredMinimum)
    finally:
      reg.shutdown()

  test "correcting the declared minimum makes lowest pass too":
    # The other direction of the same experiment, and the one that shows
    # `lowest` is testing the DECLARATION rather than simply always failing.
    let reg = startRegistry("strat1-corrected")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let corrected = @[
        newPackage(App, @["1.0.0"],
          @[newDependency(LibFoo, TrueRequirement)]),
        newPackage(LibFoo, @["1.0.0"])]
      let lo = reg.generate(corrected, lsLowest)
      check lo.resolved()[LibFoo] == "1.4.0"
      check satisfies(lo.resolved()[LibFoo], TrueRequirement)
    finally:
      reg.shutdown()
