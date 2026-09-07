## Foreign dev-environment activation (NF-4, `Nix-Flake-Coexistence.md` §2b).
##
## One import for a recipe that wants to keep its existing Nix flake or
## `.envrc` and activate it through Reprobuild:
##
##     import repro_dsl_stdlib/foreign_env
##
##     package myproject:
##       devEnv:
##         useFlakeDevShell()
##
## See `foreign_env/flake.nim` for what that one line does, `foreign_env/
## env_capture.nim` for how the contribution is derived, and
## `foreign_env/auto_load.nim` for the two configuration flags that run the
## same helpers for a project that has no `repro.nim` at all.

import repro_dsl_stdlib/foreign_env/apply
import repro_dsl_stdlib/foreign_env/auto_load
import repro_dsl_stdlib/foreign_env/env_capture
import repro_dsl_stdlib/foreign_env/envrc
import repro_dsl_stdlib/foreign_env/flake

export apply
export auto_load
export env_capture
export envrc
export flake
