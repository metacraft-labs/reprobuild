## Reprobuild home-profile apply pipeline (M63).
##
## Public surface:
##
##   * `runApply(ApplyOptions)` — the synchronous apply pipeline.
##     Owns the 11 spec-defined steps from the
##     `Home-Profile-Generations-And-State.md "Apply Pipeline"`
##     section: lock, intent load, configurable finalize, plan,
##     short-circuit, realize, stage, launchers, rotate `current`,
##     commit manifest, GC.
##
##   * `ApplyOutcome` — the value returned to the CLI layer; carries
##     the new generation id, the manifest digest, recovered aborts,
##     and any structured stow diagnostics.
##
##   * `discoverStowEntries`, `materializeStowEntry`,
##     `suppressStowShadowed` — Phase B seam used by the planner and
##     the gate fixtures.
##
##   * `recoverPartialApply` — exposed for the gate that drives the
##     mid-apply kill so the recovery sweep can be observed by tests.
##
##   * The typed exception hierarchy + `StowDiagnostic` records used
##     by the CLI's stderr renderer.

import repro_home_apply/errors
import repro_home_apply/plan
import repro_home_apply/package_catalog
import repro_home_apply/realize
import repro_home_apply/materialize_files
import repro_home_apply/materialize_managed_blocks
import repro_home_apply/materialize_launchers
import repro_home_apply/current_rotation
import repro_home_apply/partial_recovery
import repro_home_apply/stow
import repro_home_apply/suppression
import repro_home_apply/pipeline
import repro_home_apply/resource_move

export errors
export plan
export package_catalog
export realize
export materialize_files
export materialize_managed_blocks
export materialize_launchers
export current_rotation
export partial_recovery
export stow
export suppression
export resource_move
export pipeline
