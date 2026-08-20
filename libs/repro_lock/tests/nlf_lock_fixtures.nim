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
## `serializeLockedDependencies` is used directly (rather than
## `serializeSolvedGraphLock`) because it is the call `repro lock refresh`
## makes, so these fixtures are byte-for-byte the documents the product
## commits. The two are no longer in tension: `serializeSolvedGraphLock` now
## delegates to `serializeLockedDependencies`, so both emit the same
## `…lock.v2` bytes. When NLF-M4 wrote these fixtures that was NOT true —
## `serializeSolvedGraphLock` emitted a `…lock.v1` document that
## `parseSolvedGraphLock` rejected outright — and avoiding the writer was how
## this file stayed loadable. See `t_lock_writer_output_reads_back.nim` for the
## regression that now holds the invariant.

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
