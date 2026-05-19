## Reprobuild home generation registry and binary state files (M62).
##
## Persists per-generation pointer envelopes under the per-user state
## directory and content-addressed activation manifests + intent
## snapshots in the local CAS. See
## `docs/specs/Home-Profile-Generations-And-State.md` for the
## canonical format.
##
## Public surface:
##
##   - `resolveStateDir` and the layout helpers (`pointerPath`,
##     `applyLockPath`, ...).
##   - `PointerEnvelope` writer/reader (`writePointerFile`,
##     `readPointerFile`, `computeGenerationId`).
##   - `ActivationManifest` writer/reader (`encodeManifest`,
##     `decodeManifestBytes`, `manifestDigest`).
##   - `IntentSnapshot` writer/reader (`encodeSnapshot`,
##     `decodeSnapshotBytes`, `snapshotDigest`,
##     `defaultWalkProfileFiles`).
##   - `writeGeneration` / `enumerateGenerations` (the apply pipeline
##     and `repro home history` consumers).
##   - `acquireApplyLock` / `releaseApplyLock` (cross-process
##     concurrency).
##   - Typed exceptions: `EPointerCorrupt`, `EManifestCorrupt`,
##     `EIntentSnapshotCorrupt`, `EApplyBusy`, `EStateDirInvalid`,
##     `EGenerationDirInvalid`.

import repro_home_generations/errors
import repro_home_generations/state_dir
import repro_home_generations/pointer
import repro_home_generations/manifest
import repro_home_generations/intent_snapshot
import repro_home_generations/locks
import repro_home_generations/registry

export errors
export state_dir
export pointer
export manifest
export intent_snapshot
export locks
export registry
