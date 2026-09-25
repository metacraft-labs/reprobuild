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
- `repro_lock/provisioning` (re-exported) — the locked provisioning
  realization (ReproOS-Campaign-Completion M7 deliverable 2): one record per
  (package, host platform, target platform) binding the canonical interface
  fingerprint, the selected contributor and its contribution fingerprint, the
  catalog workspace/remote/full-width revision/interface-artifact identity,
  the realization kind, lock identity and integrity, and the selected
  capabilities. Serialized under the `provisioning` key of the same v2
  document ONLY when non-empty, so every existing lock re-serializes
  byte-identically; each record carries its own version tag
  (`reprobuild.locked-provisioning-realization.v1`). The reader is strict
  (missing/unknown/duplicate fields, truncation and non-canonical spelling
  refuse). `withProvisioningRealizations` sets the records;
  `lockedRealizationFor` hands one back ONLY against the current interface
  and contribution fingerprints; `lockedProvisioningClaims` hands the raw
  records to the provisioning resolver
  (`repro_interface_artifacts/contribution_selection`, M7 D3), which checks
  each one against the composed catalogs before selecting from it. The
  records are NOT part of `lockIdentityOf`, so a contribution-only refresh
  leaves typechecking cached; the realization and build edges that select a
  record are keyed on its contribution fingerprint instead (the resolver's
  `ProvisioningPin`, folded into the acquisition plan's lock identity by
  `repro_tool_profiles`, M7 D4).
  `withProvisioningCarriedForward` is how `repro lock refresh` / `repro lock
  solve --write` (`repro_lock_gen`) keep the array: carried forward
  unchanged, and a refresh refuses rather than drop an array it cannot read.
  The writer that turns a composed catalog selection into a record is
  `repro_interface_artifacts/contribution_lock`.
- `inputsDigestOf` / `currentPlatformId` — provenance helpers.
