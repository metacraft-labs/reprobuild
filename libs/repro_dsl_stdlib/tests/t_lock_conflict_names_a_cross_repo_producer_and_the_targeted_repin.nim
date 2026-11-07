## A lock conflict raised by a constraint a cross-repo PRODUCER declares says
## so, and names the targeted re-pin of the conflicting package as its first
## remedy.
##
## Issue: reprobuild-pm/issues/2026-10-14-declaring-a-sibling-producer-imports-
## its-toolchain-floor-into-the-consumers-committed-lock-solve.md.
## Spec: reprobuild-pm/spec/Locking-And-Solver.md §"Targeted re-pin" (the
## diagnostic paragraph) and Cross-Repo-Source-Consumption.md §6.
##
## WHAT WENT WRONG. Declaring `uses: "codetracer-trace-format-nim >=0"` in
## codetracer imported that producer's `nim >=2.2 <3.0` into codetracer's
## solve, against a lock pinning `nim = 2.0.0`. The refusal itself is right —
## the consumer's compiler builds the producer's sources — but its message
## named only two disproportionate remedies (a whole-lock `repro lock refresh`,
## or relaxing another repo's correct floor), did not say the constraint came
## from another repo, and, because the lock had no pin for the producer's
## package, claimed the lock "was regenerated where that recipe was not
## reachable": the wrong story for a dependency declared after the lock was
## written.
##
## HOW A CROSS-REPO PRODUCER IS MODELLED HERE. The `package` macro registers
## every `uses:` edge with the site that declared it: the recipe being built
## (`isMainModule`), another project's recipe imported into it (a sibling's
## `repro.nim`), or a library module (a bundled stdlib package). The registry
## call below passes those sites exactly as the macro's emission does; this is
## the real registration entry point, not a double.
##
## Test-double policy: NO mocks, doubles, or fakes. Real lock files written by
## the real `repro_lock` writer, read back through the real
## `parseSolvedGraphLock` / `lockToSolution` pair the CLI loader uses, and real
## registration through `registerSolverDependency`.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_lock
import repro_solver

const Nim = "nim"
const LockedVersion = "2.0.0"
const ConsumerRange = ">=1.6 <3.0"
const ProducerRange = ">=2.2 <3.0"
const Consumer = "codetracer"
const Producer = "codetracer_trace_format_nim"

const RepinRemedy = "repro lock refresh --repin=nim"
const CrossRepoPhrase = "cross-repo producer"
const DeclaredAfterPhrase = "declared after the lock was written"

proc writeLock(path: string; packages: openArray[(string, string)]) =
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version) in packages: sol.packages[name] = version
  let solved = solutionToLock(sol, currentPlatformId(), "")
  writeFile(path, serializeLockedDependencies(lockedDepsFromSolved(solved)))

proc governWith(lockPath: string) =
  let solution = lockToSolution(parseSolvedGraphLock(readFile(lockPath)))
  putEnv(LockPinsEnvVar, renderLockPins(solution.packages, solution.variants))
  putEnv(LockPathEnvVar, lockPath)

proc ungovern() =
  delEnv(LockPinsEnvVar)
  delEnv(LockPathEnvVar)

proc conflictMessage(): string =
  ## The `ELockConflict` text, or "" when none is raised (every case below IS
  ## a conflict, so "" fails each of them).
  try:
    discard currentSolverPackageDecls()
  except ELockConflict as err:
    return err.msg
  ""

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-lock-cross-repo-", "")
  ungovern()
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    ungovern()
    removeDir(scratch)

suite "a lock conflict from a cross-repo producer":

  test "a producer the lock already records is named as cross-repo":
    # The writer saw the producer (its package is pinned) and the floor rose
    # afterwards, or the lock was edited. The declarer is still another repo's.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Nim: LockedVersion, Consumer: "0.1.0",
                           Producer: "0.1.0"})
      governWith(lockPath)
      registerSolverDependency(Consumer, Nim, Nim & " " & ConsumerRange,
        declarationSite = sdsRootRecipe)
      registerSolverDependency(Producer, Nim, Nim & " " & ProducerRange,
        declarationSite = sdsSiblingRecipe)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check lockPath in message
      check LockedVersion in message
      check ProducerRange in message
      check "'" & Producer & "'" in message
      check CrossRepoPhrase in message
      check RepinRemedy in message
      # The re-pin is the FIRST remedy: it comes before the whole-lock one.
      check message.find(RepinRemedy) <
        message.find("Regenerate the lock with `repro lock refresh`")
      check DeclaredAfterPhrase notin message

  test "a producer the lock never recorded: declared after, or unreachable":
    # The issue's exact shape: the lock pins the consumer's floor and records
    # the consumer, but has no pin for the producer declared since.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Nim: LockedVersion, Consumer: "0.1.0"})
      governWith(lockPath)
      registerSolverDependency(Consumer, Nim, Nim & " " & ConsumerRange,
        declarationSite = sdsRootRecipe)
      registerSolverDependency(Producer, Nim, Nim & " " & ProducerRange,
        declarationSite = sdsSiblingRecipe)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check "'" & Producer & "'" in message
      check CrossRepoPhrase in message
      check RepinRemedy in message
      # Both explanations of an unseen recipe, not only the unreachable one.
      check "never saw the recipe" in message
      check DeclaredAfterPhrase in message
      check "checked out" in message
      check "relax the declared constraint" notin message
      check message.find(RepinRemedy) < message.find("never saw the recipe")

  test "control: the project's own package is not called cross-repo":
    # The project's own recipe declares the floor the lock contradicts. The
    # re-pin is still the first remedy; the cross-repo statement is not made.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Nim: LockedVersion, Consumer: "0.1.0"})
      governWith(lockPath)
      registerSolverDependency(Consumer, Nim, Nim & " " & ProducerRange,
        declarationSite = sdsRootRecipe)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check RepinRemedy in message
      check CrossRepoPhrase notin message

  test "control: a bundled library module is not called cross-repo":
    # A stdlib package module is imported into the provider but belongs to no
    # other repository the reader could go and edit.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Nim: LockedVersion, "nim_tooling": "0.1.0"})
      governWith(lockPath)
      registerSolverDependency("nim_tooling", Nim, Nim & " " & ProducerRange,
        declarationSite = sdsLibraryModule)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check RepinRemedy in message
      check CrossRepoPhrase notin message

  test "control: a hand registration with no declared site claims nothing":
    # The default, for every caller that is not the `package` macro: absent
    # evidence, the message must not assert where the constraint came from.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Nim: LockedVersion, Producer: "0.1.0"})
      governWith(lockPath)
      registerSolverDependency(Producer, Nim, Nim & " " & ProducerRange)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check RepinRemedy in message
      check CrossRepoPhrase notin message
