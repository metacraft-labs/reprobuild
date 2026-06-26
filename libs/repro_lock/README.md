# repro_lock

The committed **solved-graph lock** writer/reader for Reprobuild
(milestone MO-1, spec `reprobuild-specs/Locking-And-Solver.md`).

This library serializes the solver's resolved package graph
(`UnifiedSolution` from `repro_solver`) — concrete versions, variant
(option) assignments, per-package source identities, the global
optimality decision, the platform fact, and solver-inputs provenance —
into a TOML file (`reprobuild.solved-graph-lock.v1`) committed in the
project repo at the canonical path `repro.lock`, and loads it back
deterministically (write→read round-trips).

It is **distinct from** the manifest-repo SHA lock in
`repro_workspace_manifests` (`lock_writer.nim` / `executeWorkspaceLock`),
which pins per-repo git revisions under `.repo/manifests/locks/...`. The
committed solved-graph lock is repo-local and serializes solver output,
not workspace VCS state.

## Surface

- `SolvedGraphLock`, `LockedVariant`, `LockedPackage`
- `solutionToLock` / `lockToSolution` — convert between a solved
  `UnifiedSolution` and the on-disk lock (deterministic, sorted).
- `serializeSolvedGraphLock` / `parseSolvedGraphLock` — TOML round-trip.
- `sameSolution` — structural equality used by `repro lock validate` to
  detect a tampered or stale lock.
- `inputsDigestOf` / `currentPlatformId` — provenance helpers.
