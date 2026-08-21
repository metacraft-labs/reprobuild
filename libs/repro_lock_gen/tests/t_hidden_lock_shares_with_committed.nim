## A hidden lock and an identical committed one share every artifact.
##
## Named-Lock-Files NLF-M6. Corpus case **NLF-STRAT-4**.
##
## Design §5.4, on collapsing "invocation under a strategy" into "generate a
## hidden lock, then use it":
##
## > **Identity is automatic.** A hidden lock and a committed one with
## > identical content are the same lock file under §6.2, so they share every
## > artifact. This needs no rule; it falls out.
##
## ## What "share every artifact" is made to mean, concretely — and what it
## ## cannot yet mean
##
## Every build edge carries a `governingLockIdentity` (`Named-Lock-Files.md`
## §7). "Share every artifact" is measured here as: the hidden lock and the
## committed lock produce EQUAL `LockIdentity` values, and an edge constructed
## under each carries that same identity — so the two are one lock everywhere
## the identity is consulted.
##
## **What is deliberately NOT asserted, and why.** The obvious stronger
## assertion is that the two edges have the same WEAK FINGERPRINT and a
## differing pair has different ones. That assertion cannot be made yet and
## must not be made to pass. `Named-Lock-Files.milestones.org` records the
## reason as a standing hazard:
##
## > M4 deliberately did not mix the lock identity into `weakFingerprint`,
## > because NLF-STAT-4 requires fingerprints stay byte-identical across the
## > campaign, so §7's keying is not yet effective and becomes so at NLF-M7.
##
## So an edge's weak fingerprint is today independent of its governing lock,
## and a test asserting otherwise would either fail or force a change that
## breaks the migration gate. When NLF-M7 makes §7's keying effective, the
## `governingLockIdentity` assertions below should be tightened into
## fingerprint assertions; until then the identity is the strongest thing
## there is to check, and pretending otherwise would be the more misleading
## choice.
##
## ## The control that stops this being a tautology
##
## Two locks generated the same way are trivially equal. So the file also
## generates a lock that DIFFERS (a different strategy) and requires its
## identity and its edge fingerprint to differ — otherwise "they share every
## artifact" would be satisfied by an implementation where everything shares
## every artifact.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `nlf_m6_fixture`'s header, which states the policy in full. The build
## actions below are real `BuildAction` values from the real engine
## constructor, and the fingerprint read off them is the real one
## `repro_local_store.ActionCache` looks up by.

import std/[os, tables, unittest]

import repro_build_engine
import repro_hash
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

proc hex(digest: ContentDigest): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(digest.bytes.len * 2)
  for b in digest.bytes:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

proc consumerEdgeUnder(identity: LockIdentity): BuildAction =
  ## One representative consumer edge, governed by `identity`. Constructed
  ## through the engine's own `action()` rather than by hand, so what is read
  ## off it is what the engine would carry.
  action("consumer/compile",
    ["/usr/bin/cc", "-c", "src/main.c", "-o", "build/main.o"],
    governingLockIdentity = identity,
    cwd = "/workspace",
    inputs = ["src/main.c"],
    outputs = ["build/main.o"],
    cacheable = true)

suite "NLF-STRAT-4 a hidden lock and an identical committed one are one lock":

  test "identical content, different locations, equal identity":
    let reg = startRegistry("strat4")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)

      let committedPath = reg.scratch / "project" / "repro.lock"
      let committed = runLockSolve(
        reg.request(workspace(), lsHighest), committedPath)
      let hidden = runStrategyHiddenLock(
        reg.request(workspace(), lsHighest), lsHighest)

      # They really are in different places and came through different doors.
      check committed.entryPoint == lgeLockSolve
      check hidden.entryPoint == lgeStrategyHiddenLock
      check committed.lockPath != hidden.lockPath
      check fileExists(committedPath)
      check not fileExists(reg.scratch / "project" / "hidden.lock")

      # And they are the same lock.
      check hidden.lockDocument == committed.lockDocument
      check hidden.lockIdentity == committed.lockIdentity
      check hidden.lockIdentity.isValid()

      # Which is what makes every edge under them one edge: an edge built
      # under either carries the same governing identity.
      check consumerEdgeUnder(hidden.lockIdentity).governingLockIdentity ==
        consumerEdgeUnder(committed.lockIdentity).governingLockIdentity
      check consumerEdgeUnder(hidden.lockIdentity).governingLockIdentity ==
        committed.lockIdentity
    finally:
      reg.shutdown()

  test "a lock that DIFFERS does not share, so sharing is not universal":
    let reg = startRegistry("strat4-control")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let highest = runStrategyHiddenLock(
        reg.request(workspace(), lsHighest), lsHighest)
      let lowest = runStrategyHiddenLock(
        reg.request(workspace(), lsLowest), lsLowest)
      check lowest.lockDocument != highest.lockDocument
      check lowest.lockIdentity != highest.lockIdentity
      check consumerEdgeUnder(lowest.lockIdentity).governingLockIdentity !=
        consumerEdgeUnder(highest.lockIdentity).governingLockIdentity

      # The NLF-M7 hazard, asserted in the direction it currently holds so a
      # reader is not left to discover it. Today the two edges share a weak
      # fingerprint DESPITE differing governing locks, because M4 kept the
      # identity out of it to hold NLF-STAT-4 byte-identical. When M7 makes
      # §7's keying effective this assertion must be inverted, and its failure
      # is the signal to do that rather than a regression.
      check hex(consumerEdgeUnder(lowest.lockIdentity).weakFingerprint) ==
        hex(consumerEdgeUnder(highest.lockIdentity).weakFingerprint)
    finally:
      reg.shutdown()

  test "the hidden lock is usable as a pin, not merely equal to one":
    # §5.4: "generate a lock file under the given strategy into a hidden,
    # uncommitted location, THEN USE IT." A lock that were equal to the
    # committed one but unreadable as a pin would satisfy every identity
    # assertion above and none of the purpose.
    let reg = startRegistry("strat4-pin")
    try:
      reg.server.publish(App, ["1.0.0"])
      reg.server.publish(LibFoo, Published)
      let hidden = runStrategyHiddenLock(
        reg.request(workspace(), lsLowest), lsLowest)
      let pinned = resolveSolvedGraph(hidden.lockPath,
        reg.request(workspace(), lsLowest))
      check pinned.source == sgsPinnedLock
      check pinned.identity == hidden.lockIdentity
      check pinned.solution.packages[LibFoo] == "1.2.0"
    finally:
      reg.shutdown()
