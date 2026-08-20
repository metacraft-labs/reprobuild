## Shared fixture helpers for the NLF-M4 lock-identity corpus cases.
##
## Named-Lock-Files NLF-M4. Not named `t_*` / `test_*`, so
## `scripts/generate_test_edges.nim` does not register it as a test binary of
## its own; it is imported by the `t_lock_identity_*` and
## `t_provenance_*` modules.
##
## Test-double policy: NO mocks, doubles, or fakes. `writeCommittedLock`
## writes a real `reprobuild.solved-graph-lock.v2` document with the real
## `solutionToLock` -> `serializeLockedDependencies` pair — the bytes
## `repro lock refresh` produces — and `readCommittedLock` reads it back with
## the real `parseSolvedGraphLock`, the same reader
## `resolveSolvedGraphForBuild` calls.
##
## **Deliberately NOT used: `serializeSolvedGraphLock`.** That writer emits a
## `…lock.v1` document (`repro_lock.nim`, `serializeSolvedGraphLock`) which
## `parseSolvedGraphLock` rejects outright, so its output cannot be read back
## by this repository's own reader. That is a known open defect, recorded
## against this campaign and not fixed here. Lock identity is over the SOLVED
## GRAPH (§6.2), not over a serialized document, so nothing in these fixtures
## needs the broken writer — and a fixture built on it would be asserting
## against bytes the product cannot load.

import std/tables

import repro_lock

proc solutionOf*(packages: openArray[(string, string)];
                 variants: openArray[(string, string)] = []): UnifiedSolution =
  ## A `UnifiedSolution` with the given package pins and variant assignments.
  result = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version) in packages: result.packages[name] = version
  for (name, value) in variants: result.variants[name] = value

proc writeCommittedLock*(path: string; sol: UnifiedSolution;
                         inputsText = "") =
  ## Write `sol` to `path` as a real committed `…lock.v2` document.
  ##
  ## `inputsText` becomes the lock's `inputs_digest`. It is a parameter
  ## precisely so a test can hold it CONSTANT across two different solved
  ## graphs — which is what NLF-ID-7 needs to prove that identity does not
  ## follow the constraint set.
  let solved = solutionToLock(sol, currentPlatformId(), inputsText)
  writeFile(path, serializeLockedDependencies(lockedDepsFromSolved(solved)))

proc readCommittedLock*(path: string): SolvedGraphLock =
  ## Read a committed lock back through the product's own reader.
  parseSolvedGraphLock(readFile(path))
