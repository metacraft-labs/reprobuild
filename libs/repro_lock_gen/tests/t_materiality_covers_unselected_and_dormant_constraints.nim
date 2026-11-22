## A publication that moves the answer invalidates the lock even when it lands
## on a package the answer did not SELECT, or below the selection of one it did.
##
## Named-Lock-Files NLF-M6, design §5.7; `Locking-And-Solver.md` §"Solver
## Cache" §"Strong fingerprint: what the solve actually consulted". Corpus case
## **NLF-GEN-8**. Recorded as reprobuild-pm
## `issues/2026-11-12-filtered-interval-materiality-misses-changes-that-matter-and-is-undefined-for-the-most.md`.
##
## ## The property
##
## > For every constraint `Y ∈ R` that the solver evaluates, record Y's
## > enumeration filtered to R.
##
## The filtered interval recorded for a SELECTED package — the selection plus
## the interval in which no better candidate exists — is not the whole of what
## the answer depends on. The solver also weighs candidates it then rejects:
##
##   1. **A dormant constraint on an unselected package.** `app` wants the
##      `tls` arm (a `default` contribution), and the arm needs
##      `libssl >=2.0 <2.5`. Only `libssl 3.0` exists, so the arm cannot be
##      satisfied, `tls` resolves `false` and `libssl` is selected by nothing.
##      `libssl`'s enumeration was consulted — to reject the arm — and has no
##      selection. Publishing `libssl 2.2` moves the correct answer to
##      `tls=true, libssl=2.2`. This is the issue's counterexample, in the form
##      this solver's per-package (not per-version) dependency model expresses
##      it: the arm is gated on a variant rather than on `X`'s version.
##   2. **A dormant constraint on a selected package, below its selection.**
##      `app` needs `libfoo >=1.0` unconditionally and `libfoo <1.5` when
##      `fast` is on (a `default` contribution). Only `libfoo 2.0` exists, so
##      `fast` resolves `false` and `highest` selects 2.0, recording
##      `[2.0.0, +inf)`. Publishing 1.2 lies below that interval, and it moves
##      the answer to `fast=true, libfoo=1.2`.
##   3. **The chosen version of an unselected package.** The lock carries a
##      version for every package instance, selected or not
##      (`solutionToLock`), and the version preference ranks every
##      `package_chosen` atom. Under `highest` with `tls` pinned off, publishing
##      `libssl 3.9` changes the version the lock records for `libssl`.
##   4. **A live arm abandoned for a better version.** `fast` has no
##      contribution, so `true` and `false` tie at the variant level and the
##      version objective breaks the tie. `fast=true` caps `libfoo` at `<1.5`;
##      `fast=false` caps `libzed` at `<1.5`. With only `libfoo 1.4`
##      published, `highest` takes `fast=true` (`libzed 2.0`). Publishing
##      `libfoo 2.0` and `3.0` — both outside the `[1.4, 1.5)` interval the
##      live cap folds into — makes `fast=false, libfoo 3.0, libzed 1.0` the
##      better configuration. A strategy settles packages one at a time, at
##      equal distance from the request by name (Named-Lock-Files §5.5), so
##      the second package is named to come AFTER `libfoo`, as `Z` comes
##      after `X` in the spec's own example of this case: `libfoo` is settled
##      first, and its new release is what decides the variant. No interval
##      can express that, so the packages a tied variant reaches are recorded
##      raw.
##
## Each case asserts that the SOLVE RAN (NLF-GEN-3: "Assert on whether the
## solve RAN, not only on lock content") and that the regenerated lock agrees
## with a fresh solve over the same registry state in a store that has never
## seen this workspace — so the expected answer is the solver's, not this
## file's.
##
## ## Paired with the publication that must NOT invalidate
##
## NLF-M6's exit criteria: a one-sided materiality test "cannot distinguish a
## working filter from a fingerprint that never changes". Recording the
## unselected package's whole enumeration would pass cases 1-3 and silently
## give up §5.7. So the pair publishes, under `lowest`, a `libssl` version that
## is outside the dormant constraint's range and above the unselected
## package's chosen version — it can neither satisfy the arm nor become the
## lowest — and asserts a path-set hit.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full for every
## test that imports it: a real loopback HTTP server, the real in-process
## fetch client, real engine edges, a real clingo solve, a real lock writer,
## and a real on-disk path-set store.

import std/[tables, unittest]

import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

const
  App = "app"
  LibFoo = "libfoo"
  LibSsl = "libssl"
  LibZed = "libzed"
  Tls = "tls"
  Fast = "fast"

proc tlsWorkspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[
      newDependency(LibFoo, ">=1.0"),
      newConditionalDependency(LibSsl, ">=2.0 <2.5", Tls, "true")]),
    newPackage(LibFoo, @["1.4.0"]),
    newPackage(LibSsl, @["3.0.0"])]

proc tlsWanted(): seq[VariantDecl] =
  ## A `default` contribution: a soft preference the solver honours when it
  ## can, and gives up — rather than failing — when the arm it opens cannot be
  ## satisfied. That give-up is the decision made from `libssl`'s metadata.
  @[newBoolVariant(Tls, @[contribution(vpDefault, "true")])]

proc tlsPinnedOff(): seq[VariantDecl] =
  @[newBoolVariant(Tls, pinnedValue = "false")]

proc fastWorkspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[
      newDependency(LibFoo, ">=1.0"),
      newConditionalDependency(LibFoo, ">=1.0 <1.5", Fast, "true")]),
    newPackage(LibFoo, @["2.0.0"])]

proc fastWanted(): seq[VariantDecl] =
  @[newBoolVariant(Fast, @[contribution(vpDefault, "true")])]

proc variantsOf(r: LockGenerationResult): Table[string, string] =
  lockToSolution(parseSolvedGraphLock(r.lockDocument)).variants

proc freshAnswer(packages: seq[PackageDecl]; strategy: LockStrategy;
                 variants: seq[VariantDecl];
                 publish: proc(reg: Registry)): LockGenerationResult =
  ## What a solve over this registry state answers with NO recorded path set:
  ## the ground truth a cache hit must reproduce.
  let reg = startRegistry("gen8-fresh")
  try:
    publish(reg)
    result = runLockSolve(reg.request(packages, strategy, variants), "")
    doAssert result.solveExecuted
  finally:
    reg.shutdown()

suite "NLF-GEN-8 a rejected candidate's enumeration is material":

  for strategy in [lsDefault, lsLowest, lsHighest, lsLowestDirect]:
    test "publishing into an unselected package's dormant range invalidates (" &
        $strategy & ")":
      let reg = startRegistry("gen8-unselected-" & $strategy)
      try:
        reg.server.publish(App, ["1.0.0"])
        reg.server.publish(LibFoo, ["1.4.0"])
        reg.server.publish(LibSsl, ["3.0.0"])

        let first = runLockSolve(
          reg.request(tlsWorkspace(), strategy, tlsWanted()), "")
        check first.solveExecuted
        # The premise: the arm was rejected, so `libssl` is unselected.
        check first.variantsOf()[Tls] == "false"
        check lockToSolution(parseSolvedGraphLock(
          first.lockDocument)).selected[LibSsl] == ssUnselected

        reg.server.publish(LibSsl, ["2.2.0", "3.0.0"])
        let after = runLockSolve(
          reg.request(tlsWorkspace(), strategy, tlsWanted()), "")
        let truth = freshAnswer(tlsWorkspace(), strategy, tlsWanted(),
          proc(r: Registry) =
            r.server.publish(App, ["1.0.0"])
            r.server.publish(LibFoo, ["1.4.0"])
            r.server.publish(LibSsl, ["2.2.0", "3.0.0"]))
        # Ground truth first, so a failure below cannot be blamed on the
        # expectation: the solver really does take the arm now.
        check truth.variantsOf()[Tls] == "true"
        check truth.resolved()[LibSsl] == "2.2.0"

        check after.solveExecuted
        check after.pathSetHitIndex == -1
        check after.variantsOf()[Tls] == "true"
        check after.resolved()[LibSsl] == "2.2.0"
        check after.lockDocument == truth.lockDocument
      finally:
        reg.shutdown()

  test "publishing below a selected package's interval into its dormant " &
      "range invalidates (highest)":
    let reg = startRegistry("gen8-selected-below")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["2.0.0"])

      let first = runLockSolve(
        reg.request(fastWorkspace(), lsHighest, fastWanted()), "")
      check first.solveExecuted
      check first.variantsOf()[Fast] == "false"
      check first.resolved()[LibFoo] == "2.0.0"

      reg.server.publish(LibFoo, ["1.2.0", "2.0.0"])
      let after = runLockSolve(
        reg.request(fastWorkspace(), lsHighest, fastWanted()), "")
      let truth = freshAnswer(fastWorkspace(), lsHighest, fastWanted(),
        proc(r: Registry) =
          r.server.publish(App, ["1.0.0"])
          r.server.publish(LibFoo, ["1.2.0", "2.0.0"]))
      check truth.variantsOf()[Fast] == "true"
      check truth.resolved()[LibFoo] == "1.2.0"

      check after.solveExecuted
      check after.pathSetHitIndex == -1
      check after.resolved()[LibFoo] == "1.2.0"
      check after.lockDocument == truth.lockDocument
    finally:
      reg.shutdown()

suite "NLF-GEN-8 an unselected package's chosen version is material":

  test "a higher version of an unselected package invalidates under highest":
    let reg = startRegistry("gen8-unselected-chosen")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0"])
      reg.server.publish(LibSsl, ["3.0.0", "3.1.0"])

      let first = runLockSolve(
        reg.request(tlsWorkspace(), lsHighest, tlsPinnedOff()), "")
      check first.solveExecuted
      check first.resolved()[LibSsl] == "3.1.0"

      reg.server.publish(LibSsl, ["3.0.0", "3.1.0", "3.9.0"])
      let after = runLockSolve(
        reg.request(tlsWorkspace(), lsHighest, tlsPinnedOff()), "")
      let truth = freshAnswer(tlsWorkspace(), lsHighest, tlsPinnedOff(),
        proc(r: Registry) =
          r.server.publish(App, ["1.0.0"])
          r.server.publish(LibFoo, ["1.4.0"])
          r.server.publish(LibSsl, ["3.0.0", "3.1.0", "3.9.0"]))
      check truth.resolved()[LibSsl] == "3.9.0"

      check after.solveExecuted
      check after.pathSetHitIndex == -1
      check after.lockDocument == truth.lockDocument
    finally:
      reg.shutdown()

proc tiedWorkspace(): seq[PackageDecl] =
  @[
    newPackage(App, @["1.0.0"], @[
      newDependency(LibFoo, ">=1.0"),
      newConditionalDependency(LibFoo, ">=1.0 <1.5", Fast, "true"),
      newConditionalDependency(LibZed, ">=1.0 <1.5", Fast, "false")]),
    newPackage(LibFoo, @["1.4.0"]),
    newPackage(LibZed, @["1.0.0", "2.0.0"])]

proc fastTied(): seq[VariantDecl] =
  ## No contribution: both values carry the same variant-level weight, so the
  ## version objective decides.
  @[newBoolVariant(Fast)]

suite "NLF-GEN-8 a live arm a tied variant can abandon is material":

  test "publishing above a live cap flips a tied variant (highest)":
    let reg = startRegistry("gen8-tied")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0"])
      reg.server.publish(LibZed, ["1.0.0", "2.0.0"])

      let first = runLockSolve(
        reg.request(tiedWorkspace(), lsHighest, fastTied()), "")
      check first.solveExecuted
      check first.variantsOf()[Fast] == "true"
      check first.resolved()[LibFoo] == "1.4.0"
      check first.resolved()[LibZed] == "2.0.0"
      # Both packages a tied variant reaches are recorded whole.
      check first.intervalOf(LibFoo) == "raw"
      check first.intervalOf(LibZed) == "raw"

      reg.server.publish(LibFoo, ["1.4.0", "2.0.0", "3.0.0"])
      let after = runLockSolve(
        reg.request(tiedWorkspace(), lsHighest, fastTied()), "")
      let truth = freshAnswer(tiedWorkspace(), lsHighest, fastTied(),
        proc(r: Registry) =
          r.server.publish(App, ["1.0.0"])
          r.server.publish(LibFoo, ["1.4.0", "2.0.0", "3.0.0"])
          r.server.publish(LibZed, ["1.0.0", "2.0.0"]))
      check truth.variantsOf()[Fast] == "false"
      check truth.resolved()[LibFoo] == "3.0.0"

      check after.solveExecuted
      check after.pathSetHitIndex == -1
      check after.lockDocument == truth.lockDocument
    finally:
      reg.shutdown()

suite "NLF-GEN-8 the pair: an immaterial publication still hits":

  test "a libssl version outside the dormant range and above the chosen " &
      "one does not invalidate under lowest":
    let reg = startRegistry("gen8-immaterial")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, ["1.4.0"])
      reg.server.publish(LibSsl, ["3.0.0"])

      let first = runLockSolve(
        reg.request(tlsWorkspace(), lsLowest, tlsWanted()), "")
      check first.solveExecuted
      check first.variantsOf()[Tls] == "false"
      check first.resolved()[LibSsl] == "3.0.0"
      # What makes the hit below a FILTER rather than an absence: `libssl`
      # carries both a selection and a constraint observation, and 3.5 lies
      # outside each.
      var recorded: seq[string] = @[]
      for obs in first.pathSet.observations:
        if obs.subject == LibSsl:
          recorded.add($obs.basis & " [" & obs.low & ", " & obs.high &
            (if obs.highInclusive: "]" else: ")"))
      check recorded == @["selection [, 3.0.0]", "constraint [2.0.0, 2.5.0)"]

      # 3.5 cannot satisfy `>=2.0 <2.5`, and it is not lower than 3.0.
      reg.server.publish(LibSsl, ["3.0.0", "3.5.0"])
      let after = runLockSolve(
        reg.request(tlsWorkspace(), lsLowest, tlsWanted()), "")
      check not after.solveExecuted
      check after.pathSetHitIndex == 0
      check after.lockDocument == first.lockDocument
    finally:
      reg.shutdown()
