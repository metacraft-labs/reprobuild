## A committed lock that contradicts a declared constraint FAILS, naming both
## sides — it does not quietly re-solve to something the lock never said.
##
## Named-Lock-Files NLF-M3, deliverable 3. Design reference:
## `Named-Lock-Files.md` §1.2.
##
## WHAT THE OLD BEHAVIOUR WAS, and why the diagnostic is the deliverable rather
## than the failure: the locked versions never reached the solve at all, so a
## lock contradicting the recipe produced no error and no warning — it produced
## a DIFFERENT GRAPH, silently, and the build carried on. The first case below
## measures that alternative graph explicitly (the version a free re-solve
## picks), so "fails instead of re-solving" is a comparison against a known
## other answer and not a vague absence.
##
## WHY THE CHECK IS NOT LEFT TO THE SOLVER. Handing clingo a pinned version
## that violates a declared range does make the program unsatisfiable, so
## something would fail either way. What comes back from that route is an unsat
## core over ASP atoms, which answers "these constraints cannot hold together"
## in the encoder's vocabulary rather than "your lock pins libfoo to 1.4.0 and
## your recipe asks for >=1.5" in the recipe's. The reader's question is the
## second one, and it is only answerable before the encoding, which is where
## the check lives.
##
## THE CONDITIONAL-ARM CASE IS PART OF THE CONTRACT, not an edge case. A
## variant-gated arm's range binds the graph only when its gate fires, and
## pinning an older version is the normal way for such a gate to end up off.
## The last suite holds that line: if the conflict check ever widens to
## conditional arms, the pinning milestone's central case starts failing as a
## "conflict", and this case says so first.
##
## Test-double policy: NO mocks, doubles, or fakes. Real lock files written by
## the real `repro_lock` writer, read back through the real
## `parseSolvedGraphLock` / `lockToSolution` pair the CLI loader uses, real
## registration through `registerSolverDependency`, real clingo solves through
## `finalizeVariants()` wherever an answer (rather than a refusal) is the thing
## under test.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/configurables/api
import repro_dsl_stdlib/configurables/types
import repro_lock
import repro_solver

const LibFoo = "libfoo"
const LockedVersion = "1.4.0"
const DeclaredRange = ">=1.5"
const FreeResolution = "1.5.0"

proc writeLock(path: string; packages, variants: openArray[(string, string)]) =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version) in packages: sol.packages[name] = version
  for (name, value) in variants: sol.variants[name] = value
  let solved = solutionToLock(sol, currentPlatformId(), "")
  writeFile(path, serializeLockedDependencies(lockedDepsFromSolved(solved)))

proc governWith(lockPath: string) =
  let solution = lockToSolution(parseSolvedGraphLock(readFile(lockPath)))
  putEnv(LockPinsEnvVar, renderLockPins(solution.packages, solution.variants))
  putEnv(LockPathEnvVar, lockPath)

proc ungovern() =
  delEnv(LockPinsEnvVar)
  delEnv(LockPathEnvVar)

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-nlf-m3-conflict-", "")
  ungovern()
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    ungovern()
    removeDir(scratch)

suite "a lock contradicting a declared constraint fails":

  test "control: without the lock the same declaration solves to 1.5.0":
    # The alternative answer. This is what the measured implementation
    # produced while a lock pinning 1.4.0 sat next to the recipe, and it is
    # what "silently re-solves to something else" means concretely.
    withScenario:
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      check chosenVersion(LibFoo) == FreeResolution

  test "the solve refuses instead of resolving to 1.5.0":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      expect ELockConflict:
        finalizeVariants()
      # No graph was produced. A refusal that still left a usable solution
      # behind would be a warning wearing an exception's clothes.
      check not hasSolverSolution()

  test "the diagnostic names the lock's pin AND the declared constraint":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      var message = ""
      try:
        discard currentSolverPackageDecls()
      except ELockConflict as err:
        message = err.msg
      # Both sides, or the reader is left to diff two files by hand to find
      # out which of the recipe's constraints the lock disagrees with.
      check LibFoo in message
      check LockedVersion in message
      check DeclaredRange in message
      # Which lock, and which package declared the constraint: with several
      # locks and a workspace of packages, neither is inferable.
      check lockPath in message
      check "appAlpha" in message

  test "a lock pinning a version that satisfies the range is accepted":
    # The negative control. The refusal must be evidence-driven; a check that
    # fires on the presence of a lock rather than on a contradiction would
    # pass the cases above and break every ordinary build.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: "1.7.0"}, [])
      governWith(lockPath)
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " " & DeclaredRange)
      finalizeVariants()
      check chosenVersion(LibFoo) == "1.7.0"

suite "a locked variant value outside the declared universe fails":

  test "a bool variant pinned to a non-bool value is refused by name":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, [], {"enableTls": "maybe"})
      governWith(lockPath)
      var message = ""
      try:
        discard variantImpl[bool](false, "enableTls", captureSite(ckDefault))
        discard currentSolverVariantDecls()
      except ELockConflict as err:
        message = err.msg
      check "enableTls" in message
      check "maybe" in message
      check lockPath in message

suite "a conditional arm is not a constraint the lock must satisfy":
  ## The guard on the conflict check's reach. A variant-gated arm binds the
  ## graph only when its gate fires, and a pin is a perfectly ordinary reason
  ## for a gate to be off — that is NLF-M3's central case, not a conflict.

  test "a gated range excluding the locked version is not a conflict":
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {LibFoo: LockedVersion}, [])
      governWith(lockPath)
      discard variantImpl[bool](true, "useNewFoo", captureSite(ckDefault))
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=1.9",
                               "useNewFoo", "true")
      registerSolverDependency("appAlpha", LibFoo, LibFoo & " >=1.4 <1.9",
                               "useNewFoo", "false")
      finalizeVariants()
      check chosenVersion(LibFoo) == LockedVersion
      check lastSolverSolution().variants["useNewFoo"] == "false"
