# repro_lock

The committed **solved-graph lock** writer/reader for Reprobuild
(milestone MO-1, spec `reprobuild-specs/Locking-And-Solver.md`).

This library serializes the solver's resolved package graph
(`UnifiedSolution` from `repro_solver`) — concrete versions, variant
(option) assignments, per-package source identities, the global
optimality decision, the platform fact, and solver-inputs provenance —
into a TOML file (`reprobuild.solved-graph-lock.v2`) committed in the
project repo at the canonical path `repro.lock`, and loads it back
deterministically (write→read round-trips).

There is exactly **one** on-disk schema and every writer here emits it, so
anything this library writes it can read back — pinned by the regression
`tests/t_lock_writer_output_reads_back.nim`. The historical `…v1` tag is
rejected on read; nothing writes it.

It is **distinct from** the manifest-repo SHA lock in
`repro_workspace_manifests` (`lock_writer.nim` / `executeWorkspaceLock`),
which pins per-repo git revisions under `.repo/manifests/locks/...`. The
committed solved-graph lock is repo-local and serializes solver output,
not workspace VCS state.

## Surface

- `SolvedGraphLock`, `LockedVariant`, `LockedPackage`
- `solutionToLock` / `lockToSolution` — convert between a solved
  `UnifiedSolution` and the on-disk lock (deterministic, sorted).
- `serializeSolvedGraphLock` / `parseSolvedGraphLock` — TOML round-trip
  for the solved-graph sub-part. The writer delegates to
  `serializeLockedDependencies` with an empty `deps` set, so there is a
  single byte format.
- `serializeLockedDependencies` / `parseLockedDependencies` — TOML
  round-trip for the unified model (solved graph + per-dependency
  coordinates and integrity). `deps` is normalized to (name, path) order on
  write.
- `sameSolution` — structural equality used by `repro lock validate` to
  detect a tampered or stale lock.
- `inputsDigestOf` / `currentPlatformId` — provenance helpers.
