## Four ways of producing a lock are one path.
##
## Named-Lock-Files NLF-M5. Corpus case **NLF-GEN-5**: "Four ways of producing
## a lock yield byte-identical content and identical fingerprints where inputs
## and strategy coincide."
##
## Design §5.6 states the requirement in terms:
##
## > `repro lock solve`, a `--strategy` invocation, an implicit solve during
## > `repro build`, and a hidden lock are the **same edges** reached through
## > different entry points — one path, several doors, not three
## > implementations.
##
## and §5.4 says what the doors are allowed to differ in: "the only difference
## from `repro lock solve --lowest --write` is *where the file lands and
## whether it is committed*."
##
## ## What makes this discriminating rather than tautological
##
## Four wrappers around one call are trivially equal, so three of the six
## suites below exist to make the equality mean something:
##
##   * **The doors must genuinely differ.** If `runLockSolve` and
##     `runLockRefresh` were the same function under two names, the byte
##     equality would be vacuous. So the test asserts the four land their
##     artifacts in four different places and report four different entry
##     points, and that the two write-back doors actually wrote while the two
##     that must not write back did not.
##   * **The fingerprint must move on something.** An implementation that
##     returned a constant fingerprint would pass an all-four-equal check. So
##     a control varies the strategy and requires the fingerprint AND the lock
##     to change — §5.4's "where inputs and strategy coincide" has a live
##     `where`.
##   * **The lock must depend on what was fetched.** The declared candidate
##     universe and the published one are deliberately DISJOINT, so a lock
##     naming a published version proves the metadata-fetch edge's output
##     reached the solve. Without that, the whole path could be a solve over
##     static declarations and every assertion here would still pass.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The metadata comes over a real loopback TCP socket from a real HTTP/1.1
## listener (`loopback_metadata_server`, whose header states the policy in
## full), retrieved by the real in-process `http_pool` client. The edges are
## real `BuildAction`s run by the real `runBuild`. The answers come from a real
## clingo solve. The lock is written by the real `repro_lock` writer and read
## back by the real `parseLockedDependencies`.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_lock
import repro_lock_gen
import repro_solver

import ./loopback_metadata_server

const
  App = "app"
  LibFoo = "libfoo"
  DeclaredOnly = "0.1.0"
    ## The version the RECIPE declares. Deliberately absent from what the
    ## registry publishes: a lock naming this would mean the fetched metadata
    ## never reached the solve.
  Published = ["1.2.0", "1.4.0", "1.9.0"]

proc baseRequest(server: MetadataServer; workDir: string;
                 strategy: LockStrategy): LockGenerationRequest =
  LockGenerationRequest(
    variants: @[],
    packages: @[
      newPackage(App, @["1.0.0"], @[newDependency(LibFoo, ">=1.2 <2.0")]),
      newPackage(LibFoo, @[DeclaredOnly])],
    inputsText: "nlf-gen-5 fixture",
    platform: currentPlatformId(),
    strategy: strategy,
    endpoints: @[server.endpoint()],
    workDir: workDir,
    entryPoint: lgeLockSolve)

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-nlf-gen5-", "")
  let server {.inject.} = startMetadataServer(scratch / "registry")
  server.publish(App, ["1.0.0"])
  server.publish(LibFoo, Published)
  try:
    body
  finally:
    server.stop()
    removeDir(scratch)

type FourDoors = object
  solve, implicit, hidden, refresh: LockGenerationResult
  solveWrite, refreshWrite: string

proc runFourDoors(server: MetadataServer; scratch: string;
                  strategy: LockStrategy): FourDoors =
  ## Every door, over the SAME inputs and the SAME strategy, into four
  ## different destinations.
  let solveWrite = scratch / "committed" / "repro.lock"
  let refreshWrite = scratch / "refreshed" / "repro.lock"
  FourDoors(
    solve: runLockSolve(
      baseRequest(server, scratch / "door-solve", strategy), solveWrite),
    implicit: runImplicitBuildSolve(
      baseRequest(server, scratch / "door-implicit", strategy)),
    hidden: runStrategyHiddenLock(
      baseRequest(server, scratch / "door-hidden", strategy), strategy),
    refresh: runLockRefresh(
      baseRequest(server, scratch / "door-refresh", strategy), refreshWrite),
    solveWrite: solveWrite,
    refreshWrite: refreshWrite)

proc allOf(d: FourDoors): seq[LockGenerationResult] =
  @[d.solve, d.implicit, d.hidden, d.refresh]

suite "NLF-GEN-5 premise: the fetched metadata reaches the solve":
  ## Measured, not assumed. Every equality below is over a lock; if the lock
  ## were a function of the static declarations alone, the whole file would be
  ## testing a constant.

  test "the solved version comes from the registry, not the recipe":
    withScenario:
      let r = runLockSolve(
        baseRequest(server, scratch / "premise", lsDefault), "")
      let sol = lockToSolution(parseSolvedGraphLock(r.lockDocument))
      check LibFoo in sol.packages
      check sol.packages[LibFoo] in Published
      check sol.packages[LibFoo] != DeclaredOnly
      check r.fetchAttempts > 0
      check server.requestsServed() > 0

suite "NLF-GEN-5 the four doors are four doors":
  ## The equality assertions in the next suite are only worth anything if the
  ## things being compared were produced by genuinely different entry points.

  test "each door reports itself and lands its artifact somewhere else":
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      check d.solve.entryPoint == lgeLockSolve
      check d.implicit.entryPoint == lgeImplicitBuildSolve
      check d.hidden.entryPoint == lgeStrategyHiddenLock
      check d.refresh.entryPoint == lgeLockRefresh

      var paths: seq[string] = @[]
      for r in d.allOf(): paths.add(r.lockPath)
      for i in 0 ..< paths.len:
        for j in (i + 1) ..< paths.len:
          check paths[i] != paths[j]

  test "the write-back doors write and the experiment doors do not":
    # §5.5's decision: a strategy invocation "never writes back, because a
    # strategy-produced graph is an experiment, not the project's intended
    # state." A door that quietly wrote the committed lock would pass every
    # byte-equality check in this file.
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      check fileExists(d.solveWrite)
      check fileExists(d.refreshWrite)
      check d.hidden.lockPath.startsWith(scratch / "door-hidden")
      check d.implicit.lockPath.startsWith(scratch / "door-implicit")
      check not fileExists(scratch / "door-hidden" / "repro.lock")

suite "NLF-GEN-5 one path: identical content and identical fingerprints":

  test "all four doors produce byte-identical lock documents":
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      let reference = d.solve.lockDocument
      check reference.len > 0
      for r in d.allOf():
        check r.lockDocument == reference

  test "all four doors produce the same solve-edge weak fingerprint":
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      let reference = d.solve.solveWeakFingerprint
      check reference.len == 64
      for r in d.allOf():
        check r.solveWeakFingerprint == reference

  test "all four doors produce the same lock identity":
    # §6.2's key, and §5.4's "Identity is automatic. A hidden lock and a
    # committed one with identical content are the same lock file under §6.2,
    # so they share every artifact. This needs no rule; it falls out."
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      let reference = d.solve.lockIdentity
      check reference.isValid()
      for r in d.allOf():
        check r.lockIdentity == reference

  test "the bytes that landed on disk are the bytes that were generated":
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      check readFile(d.solveWrite) == d.solve.lockDocument
      check readFile(d.refreshWrite) == d.refresh.lockDocument

  test "the generated lock reads back through the committed-lock reader":
    # PR #87 made the writer emit the schema the reader accepts. Generation
    # goes through that same writer; this is the regression that keeps a new
    # producer from re-opening the drift.
    withScenario:
      let d = runFourDoors(server, scratch, lsDefault)
      let ld = parseLockedDependencies(d.solve.lockDocument)
      check ld.schema == SolvedGraphLockSchemaV2
      check ld.packages.len > 0
      check serializeLockedDependencies(ld) == d.solve.lockDocument

suite "NLF-GEN-5 control: the equalities are not constants":

  test "a different strategy moves the fingerprint and the lock":
    # "where inputs and strategy coincide" — so where the strategy does NOT
    # coincide, they must not. `Locking-And-Solver.md` §"Solver Cache" puts
    # the strategy in the weak fingerprint "because two strategies over
    # identical constraints are two different computations".
    withScenario:
      let lowest = runStrategyHiddenLock(
        baseRequest(server, scratch / "s-lowest", lsLowest), lsLowest)
      let highest = runStrategyHiddenLock(
        baseRequest(server, scratch / "s-highest", lsHighest), lsHighest)
      check lowest.solveWeakFingerprint != highest.solveWeakFingerprint
      check lowest.lockDocument != highest.lockDocument
      check lowest.lockIdentity != highest.lockIdentity

      let lowSol = lockToSolution(parseSolvedGraphLock(lowest.lockDocument))
      let highSol = lockToSolution(parseSolvedGraphLock(highest.lockDocument))
      check lowSol.packages[LibFoo] == Published[0]
      check highSol.packages[LibFoo] == Published[^1]

  test "the fingerprint moves on the constraints too":
    # A fingerprint that only saw the strategy would pass the case above.
    withScenario:
      var narrowed = baseRequest(server, scratch / "narrowed", lsDefault)
      narrowed.packages[0].depends = @[newDependency(LibFoo, ">=1.4 <2.0")]
      let wide = runLockSolve(
        baseRequest(server, scratch / "wide", lsDefault), "")
      let narrow = runLockSolve(narrowed, "")
      check wide.solveWeakFingerprint != narrow.solveWeakFingerprint
