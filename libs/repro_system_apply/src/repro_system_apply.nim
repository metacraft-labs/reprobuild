## Reprobuild system-scope configuration DSL + apply pipeline (B1).
##
## Public surface (B1):
##
##   * `parseSystemConfigFile` / `parseSystemConfigSource` — parse an
##     `/etc/reproos/configuration.nim` file into a typed `SystemConfig`
##     AST. Imports are resolved at parse time.
##   * `SystemConfig`, `PackageRef`, `User`, `ServiceState`,
##     `MountEntry`, `KernelRef`, `KernelCmdline`,
##     `SystemConfigDiff*` — the typed shapes.
##   * `lower(cfg: SystemConfig): BuildGraph` — lowering pass; emits
##     one edge per kernel / per package / per unit-graph snapshot /
##     per /etc skeleton snapshot, deterministically ordered.
##   * `serializeForReproCheck(g: BuildGraph): string` —
##     reproducibility-check serialization.
##   * The structured exception hierarchy (`ESystemConfig` and
##     descendants).
##
## B2 (system generation apply pipeline) and B3 (rollback) are not
## delivered here; they consume the output of `lower(...)` later in
## the campaign.

import repro_system_apply/types
import repro_system_apply/errors
import repro_system_apply/dsl
import repro_system_apply/lower

export types
export errors
export dsl
export lower
