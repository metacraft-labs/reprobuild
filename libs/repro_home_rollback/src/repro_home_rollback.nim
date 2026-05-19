## Reprobuild home-profile rollback pipeline (M64).
##
## Public surface:
##
##   * `runRollback(RollbackOptions)` — diff CURRENT vs TARGET
##     activation manifests, verify on-disk digests against CURRENT
##     for every destructive op, execute the revert ops, rotate
##     `current` to the target generation.
##   * `RollbackOutcome` — the value returned to the CLI layer: which
##     generation we rolled FROM, which we rolled TO, op counts, and
##     (when `--accept-overwrite` was set) the list of paths whose
##     user-edited bytes were clobbered.
##   * Typed exception hierarchy (`EUserEditDetected`,
##     `ERollbackPartial`, `EUnknownGeneration`, ...).

import repro_home_rollback/errors
import repro_home_rollback/diff_plan
import repro_home_rollback/digest_check
import repro_home_rollback/pipeline

export errors
export diff_plan
export digest_check
export pipeline
