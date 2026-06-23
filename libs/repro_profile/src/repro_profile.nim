## Reprobuild profile macro library (M83 Phase A).
##
## Users `import repro_profile` (canonically aliased as `repro/profile`
## once the local path mapping is wired up) and get the
## `profile`/`activity`/`config`/`hosts`/`resources` DSL plus the
## standard predicate set, resource constructors, and content helpers.
##
## This umbrella module re-exports the layered submodules so the
## user-facing surface is a single import.

import repro_profile/types
import repro_profile/predicates
import repro_profile/strings
import repro_profile/emit
import repro_profile/resources
import repro_profile/macros
import repro_profile/macros_system
import repro_profile/hardware_id
import repro_profile/hardware_probe

export types
export predicates
export strings
export emit
export resources
export macros
export macros_system
export hardware_id
export hardware_probe
