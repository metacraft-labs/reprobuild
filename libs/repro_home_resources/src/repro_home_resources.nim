## Reprobuild home-scope resource lifecycle (M68).
##
## Public surface:
##
##   * `Resource` variant + the 11 resource kinds in the catalog
##     (Home-Profile-Resource-Lifecycle.md "Resource Catalog").
##   * `ResourceBinding` / `RecordedBinding` codec (the M62
##     activation-manifest record, extended by M68 with the typed
##     payload fields).
##   * Lifecycle decision algorithm (`decideAction`): pure function
##     from `(desired, observed, recorded)` to `ResourceAction`.
##   * `composePlan` + `renderPlan`: the engine behind
##     `repro home plan`.
##   * Per-resource drivers under `repro_home_resources/drivers/`:
##     `managed_block`, `registry` (Windows), `env_user`,
##     `windows_startup`, `shell_integration`, and the Phase B
##     `gsettings`, `systemd_user`, `defaults`, `launchd_user`.
##
## Phase A (this session): registry, env.userVariable,
## env.userPath, windows.startup, shell.integration on Windows,
## fs.managedBlock as typed resource, ResourceBinding persistence,
## `repro home plan`. Gates 1, 2, 4 pass on Windows.
##
## Phase B (future): full `linux.gsettings` / `macos.userDefault`
## / `systemd.userUnit` / `launchd.userAgent` execution and
## `repro home adopt` / `repro home resource move`.

import repro_home_resources/errors
import repro_home_resources/types
import repro_home_resources/manifest_record
import repro_home_resources/validation
import repro_home_resources/lifecycle
import repro_home_resources/plan
import repro_home_resources/drivers/env_user
import repro_home_resources/drivers/managed_block
import repro_home_resources/drivers/registry
import repro_home_resources/drivers/shell_integration
import repro_home_resources/drivers/windows_startup
import repro_home_resources/drivers/defaults
import repro_home_resources/drivers/gsettings
import repro_home_resources/drivers/launchd_user
import repro_home_resources/drivers/systemd_user

export errors
export types
export manifest_record
export validation
export lifecycle
export plan
export env_user
export managed_block
export registry
export shell_integration
export windows_startup
export defaults
export gsettings
export launchd_user
export systemd_user
