## Reprobuild system-scope profile + `repro infra plan/apply` (M69).
##
## System scope is home scope's careful, privileged sibling
## (System-Profile-And-Infra-Apply.md). M69 Phase A delivers:
##
##   * `state_dir`     — the per-host SYSTEM state directory (the
##     privileged sibling of the M62 home state dir; honors the
##     `$REPRO_INFRA_STATE_DIR` test override).
##   * `errors`        — the typed exception hierarchy.
##   * `profile`       — the `system.nim` profile model and parser;
##     maps each declared resource to a typed M81
##     `PrivilegedOperation`.
##   * `intent`        — the M69 Phase-B formatting-preserving
##     structural editor for `system.nim` (`repro system add/remove`).
##   * `plan_envelope` — the `RBIP` ("Reprobuild Infra Plan") binary
##     envelope, modelled on the M62 `RBPT` pointer envelope.
##   * `gen_envelope`  — the M69 Phase-B `RBSG` per-generation envelope
##     + generation enumeration (`repro system history`).
##   * `audit_log`     — the `RBSL` append-only audit-log envelope +
##     the `repro system audit` reader.
##   * `planner`       — `repro infra plan`: non-mutating, non-
##     elevated, read-only; partitions privileged vs non-privileged
##     via M81's `partition.nim`; stale-detection.
##   * `apply`         — `repro infra apply`: plan-id stale-detection,
##     elevation through the M81 single broker (already-elevated fast
##     path / one broker / `--no-elevate`), generation commit.
##   * `rollback`      — the `--accept-feature-destroy` safety gate.
##
## The Windows system-scope DRIVERS (`windows.registryValue` HKLM,
## `windows.optionalFeature`, `windows.capability`,
## `windows.service`) are real typed `PrivilegedOperation` kinds in
## the M81 `repro_elevation` library — M69 extended the closed set;
## it did not re-implement the elevation mechanism.

import repro_infra/errors
import repro_infra/state_dir
import repro_infra/profile
import repro_infra/intent
import repro_infra/plan_envelope
import repro_infra/gen_envelope
import repro_infra/audit_log
import repro_infra/planner
import repro_infra/apply
import repro_infra/rollback

export errors
export state_dir
export profile
export intent
export plan_envelope
export gen_envelope
export audit_log
export planner
export apply
export rollback
