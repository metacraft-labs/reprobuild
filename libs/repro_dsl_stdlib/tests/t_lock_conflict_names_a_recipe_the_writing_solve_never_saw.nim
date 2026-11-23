## A lock conflict whose declaring package the lock never recorded says the
## lock came from a solve that never saw that recipe, and does NOT tell the
## reader to run the command that wrote it.
##
## Issue: reprobuild-pm/issues/2026-10-12-lock-refresh-grounds-a-package-at-
## the-root-floor-so-the-writer-cannot-produce-a-lock-the-checker-accepts.md.
##
## WHAT WENT WRONG. `repro lock refresh` ran where a `uses:`-reachable sibling
## recipe was not checked out, so that recipe's ranges never reached the solve
## and the lock pinned `cargo` at the root's floor (`1.0.0`). The next build,
## in a complete workspace, saw the sibling's `cargo >=1.85` and refused —
## with a message whose remedy was "Regenerate the lock with `repro lock
## refresh`", the very command that had produced the bad lock. Followed
## literally, the advice loops.
##
## THE EVIDENCE THE CHECKER HAS. A solve that saw a recipe records that
## recipe's package in the lock (`buildPackageDecls` gives every parent package
## a synthetic `0.1.0` candidate, and the solved graph carries it). So a
## conflicting edge whose PARENT is absent from the lock's pins is an edge the
## writing solve never had: the lock is a partial solve, not a relaxed one. A
## parent that IS in the lock means the writer saw the constraint and the lock
## was edited or relaxed afterwards — there the original advice is right.
##
## Both arms are pinned here: the first case is the new wording, the second is
## the negative control that keeps the old wording for a lock that did see the
## recipe. Without the second, a message that always claimed "never saw" would
## pass the first case and mislead every reader of a hand-edited lock.
##
## Test-double policy: NO mocks, doubles, or fakes. Real lock files written by
## the real `repro_lock` writer, read back through the real
## `parseSolvedGraphLock` / `lockToSolution` pair the CLI loader uses, and real
## registration through `registerSolverDependency`.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_dsl_stdlib/configurables/variants
import repro_lock
import repro_solver

const Cargo = "cargo"
const LockedVersion = "1.0.0"
const DeclaredRange = ">=1.85"
const Declarer = "leaf_pkg"
  ## The sibling recipe's package — the one whose constraint a narrower
  ## refresh dropped.

const NeverSawPhrase = "never saw the recipe"
  ## The distinguishing clause of the new wording. Pinned as one literal so the
  ## positive case and the negative control test the SAME words.

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
  ## The `ELockConflict` text the pending registry raises against the
  ## governing lock, or "" when no conflict is raised (which every case below
  ## treats as a failure: each scenario IS a conflict).
  try:
    discard currentSolverPackageDecls()
  except ELockConflict as err:
    return err.msg
  ""

template withScenario(body: untyped) =
  let scratch {.inject.} = createTempDir("repro-lock-unseen-recipe-", "")
  ungovern()
  resetVariantState()
  try:
    body
  finally:
    resetVariantState()
    ungovern()
    removeDir(scratch)

suite "a lock conflict names a recipe the writing solve never saw":

  test "a declaring package absent from the lock is named as unseen":
    # The issue's shape: the lock pins the root's floor and records the root,
    # but not the sibling recipe whose stricter floor the build now sees.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Cargo: LockedVersion, "consumer": "0.1.0"})
      governWith(lockPath)
      registerSolverDependency("consumer", Cargo, Cargo & " >=1")
      registerSolverDependency(Declarer, Cargo, Cargo & " " & DeclaredRange)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      # Both sides of the conflict are still named, as before.
      check lockPath in message
      check Cargo in message
      check LockedVersion in message
      check DeclaredRange in message
      check Declarer in message
      # The new finding: this lock was written without that recipe.
      check NeverSawPhrase in message
      # The remedy names the condition that makes a refresh correct, rather
      # than the bare command that reproduced the refusal.
      check "checked out" in message
      check "relax the declared constraint" notin message

  test "a hyphen spelling of the declaring package still counts as seen":
    # Package identifiers reach a lock in both spellings (the issue lists
    # `isonim-gpui` and `isonim_gpui` side by side). A lock that recorded the
    # recipe under the other spelling DID see it, and must not be accused of
    # a partial solve.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Cargo: LockedVersion, "leaf-pkg": "0.1.0"})
      governWith(lockPath)
      registerSolverDependency(Declarer, Cargo, Cargo & " " & DeclaredRange)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check NeverSawPhrase notin message

  test "control: a declaring package the lock records keeps the old wording":
    # The writer saw this constraint; the lock was relaxed or edited after.
    # Re-solving IS the remedy here, so the original advice stands.
    withScenario:
      let lockPath = scratch / "repro.lock"
      writeLock(lockPath, {Cargo: LockedVersion, Declarer: "0.1.0"})
      governWith(lockPath)
      registerSolverDependency(Declarer, Cargo, Cargo & " " & DeclaredRange)
      let message = conflictMessage()
      checkpoint(message)
      check message.len > 0
      check Declarer in message
      check DeclaredRange in message
      check NeverSawPhrase notin message
      check "Regenerate the lock with `repro lock refresh` or relax the " &
        "declared constraint" in message
