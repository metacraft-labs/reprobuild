## A committed lock PINS the solved graph — versions included — and the pin
## outranks the objective function.
##
## Named-Lock-Files NLF-M3. Design reference: `Named-Lock-Files.md` §1.2 ("the
## relationship to the committed lock is worse than 'ignored'"), which measures
## the defect this file is the regression for:
##
##   * the CLI read the committed lock and forwarded only its VARIANT
##     assignments into `REPRO_VARIANTS`;
##   * `graph.solution.packages` — the locked VERSIONS — was never read at all,
##     so version concretization re-ran fully unpinned even with a lock
##     present.
##
## The property under test is therefore not "the lock is read". It was always
## read. It is that reading it DETERMINES the graph: a locked version survives
## a model that the objective function prefers.
##
## WHY THE OBJECTIVE HAS TO BE IN THE PICTURE. A test that locks the version
## the solver would have picked anyway proves nothing — it passes against an
## implementation that ignores the lock entirely, which is exactly the
## implementation this milestone replaces. So the fixture is built so the free
## solve and the locked solve disagree: `useNewFoo` defaults to true, its
## `true` arm requires `libfoo >=1.9`, and the priority lattice's `#minimize`
## therefore prefers `useNewFoo=true` and with it `1.9.0`. Pinning `1.4.0`
## makes `useNewFoo=true` infeasible, so honouring the pin costs the solver
## objective points it would rather have kept. The control case measures the
## free answer rather than assuming it, so the disagreement is established and
## not asserted.
##
## Test-double policy: NO mocks, doubles, or fakes. The lock is a real
## `reprobuild.solved-graph-lock.v2` file written by the real
## `repro_lock` writer and read back by the real `parseSolvedGraphLock` /
## `lockToSolution` — the exact pair `resolveSolvedGraphForBuild` calls — and
## projected to pins by the same `renderLockPins` the CLI's lock-consumption
## block calls. Registration goes through the real public
## `registerSolverDependency` / `variantImpl` surface, and the answers come
## from a REAL clingo solve via `finalizeVariants()`.
##
## Running clingo is deliberate here, and is the one place this file differs
## from `t_develop_dependency_source_is_read_not_solved.nim`, which avoids it.
## That milestone's properties were properties of what is HANDED to the solver.
## This one's is a property of the ANSWER: "the objective would otherwise
## prefer 1.9" is a claim about what clingo optimizes, and only clingo can
## settle it.

import std/[options, os, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_lock
import repro_solver

const LibFoo = "libfoo"
const LockedVersion = "1.4.0"
const PreferredVersion = "1.9.0"
const GateVariant = "useNewFoo"

proc writeLock(path: string; packages, variants: openArray[(string, string)]) =
  ## Write a real committed lock at `path`. The solved graph goes through
  ## `solutionToLock` -> `serializeLockedDependencies`, which is what
  ## `repro lock refresh` writes, so the bytes on disk are the bytes the
  ## product produces.
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version) in packages: sol.packages[name] = version
  for (name, value) in variants: sol.variants[name] = value
  let solved = solutionToLock(sol, currentPlatformId(), "")
  writeFile(path, serializeLockedDependencies(lockedDepsFromSolved(solved)))

proc governWith(lockPath: string) =
  ## Put the lock at `lockPath` in charge of this process's solve, along the
  ## same path the CLI does: read the committed lock with the loader
  ## `resolveSolvedGraphForBuild` uses, project the SOLVED GRAPH — packages
  ## included — into pins, and export them.
  let solution = lockToSolution(parseSolvedGraphLock(readFile(lockPath)))
  putEnv(LockPinsEnvVar, renderLockPins(solution.packages, solution.variants))
  putEnv(LockPathEnvVar, lockPath)

proc ungovern() =
  delEnv(LockPinsEnvVar)
  delEnv(LockPathEnvVar)

proc declareGraph() =
  ## One variant gating two version arms of one dependency.
  ##
  ## `useNewFoo` defaults to true, which registers a `default`-band
  ## contribution for `"true"` and none for `"false"`; the encoder weights an
  ## uncontributed value strictly worse, so `#minimize` prefers `true`. The
  ## `true` arm admits only `>=1.9` and the `false` arm only `[1.4, 1.9)`, so
  ## the variant preference IS a version preference.
  discard variantImpl[bool](true, GateVariant, captureSite(ckDefault))
  registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=1.9",
                           GateVariant, "true")
  registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=1.4 <1.9",
                           GateVariant, "false")

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-nlf-m3-pin-", "")
  ungovern()
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    ungovern()
    removeDir(scratch)

proc declOf(decls: seq[PackageDecl]; name: string): PackageDecl =
  for d in decls:
    if d.name == name:
      return d
  raise newException(ValueError,
    "no PackageDecl named " & name & " in " & $decls.len & " declarations")

suite "the locked version reaches the solve":
  ## §1.2's version half: `graph.solution.packages` was dropped entirely.

  test "the lock's package versions survive the projection to pins":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, {GateVariant: "false"})
      let solution = lockToSolution(parseSolvedGraphLock(readFile(lockPath)))
      let pins = renderLockPins(solution.packages, solution.variants)
      # The version half, which the measured implementation never forwarded.
      check ("pkg:" & LibFoo & "=" & LockedVersion) in pins
      check ("var:" & GateVariant & "=false") in pins

suite "a committed lock pins versions against the objective":

  test "control: with no lock the objective picks the newer version":
    # The premise, measured rather than assumed. If this ever stops holding,
    # the pinning cases below become vacuous and must be re-fixtured.
    withScenario:
      declareGraph()
      finalizeVariants()
      check chosenVersion(LibFoo) == PreferredVersion
      check lastSolverSolution().variants[GateVariant] == "true"

  test "a lock pinning 1.4.0 yields 1.4.0":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      declareGraph()
      finalizeVariants()
      check chosenVersion(LibFoo) == LockedVersion
      check chosenVersion(LibFoo) != PreferredVersion

  test "the pin is paid for out of the objective":
    # The half that says the pin is a CONSTRAINT and not a preference: the
    # solver gives up the `useNewFoo=true` contribution it prefers, because
    # with `libfoo` pinned below 1.9 that arm's range cannot hold.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      declareGraph()
      finalizeVariants()
      check lastSolverSolution().variants[GateVariant] == "false"

  test "the locked package contributes no version-selection choice":
    # Removing the disagreement is not enough: an implementation could hand
    # clingo the locked version as a one-element candidate SET and still be
    # searching for it. The encoder is the only surface that tells those
    # apart — a `package_chosen` fact versus a `{ ... } = 1` cardinality rule.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      declareGraph()
      let libfoo = declOf(currentSolverPackageDecls(), LibFoo)
      check libfoo.versions == @[LockedVersion]
      check encodePackageCardinality(libfoo).len == 0
      check ("package_chosen(\"" & LibFoo & "\", \"" & LockedVersion &
             "\").") in encodePackageUniverse(libfoo)

  test "an unlocked package keeps its cardinality choice":
    # The negative control. Pinning is granted on the evidence of a lock entry
    # and never by default; a package the lock does not mention is still the
    # solver's to choose.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      declareGraph()
      registerSolverDependency("appAlpha", "zlib", "zlib >=1.2.0")
      let zlib = declOf(currentSolverPackageDecls(), "zlib")
      check "{ package_chosen(\"zlib\", V)" in encodePackageCardinality(zlib)

suite "the governing lock is whichever one was selected":
  ## Deliverable 4 — `--lock <path>` honours the same pinning path. The CLI
  ## forwards the lock it RESOLVED (`--lock <file>` when given, the canonical
  ## `repro.lock` otherwise), so the pinning path must not be keyed on the
  ## file's name.

  test "an alternate lock file pins exactly as the canonical one does":
    withScenario:
      let altLock = scratch / "ci-min.lock"
      writeLock(altLock, {LibFoo: LockedVersion}, [])
      governWith(altLock)
      declareGraph()
      finalizeVariants()
      check chosenVersion(LibFoo) == LockedVersion

  test "the governing lock's path is available to diagnostics":
    withScenario:
      let altLock = scratch / "ci-min.lock"
      writeLock(altLock, {LibFoo: LockedVersion}, [])
      governWith(altLock)
      let pins = lockPinsFromEnv()
      check pins.lockPath == altLock
      check pins.packages[LibFoo] == LockedVersion
