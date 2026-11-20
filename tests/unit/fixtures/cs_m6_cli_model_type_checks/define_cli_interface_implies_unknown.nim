## A `defineCliInterface` whose `implies` names a parameter its command does
## not see, when compiled with `-d:csM6Wrong` (see
## `t_cs_m6_cli_model_type_checks_in_reprobuild_macros`). The top-level flag
## `verbose` may imply only a top-level flag, and `jobs` is declared in `c`
## alone. Without the define the same interface implies the top-level
## `quiet` instead, and compiles.
import repro_project_dsl

when defined(csM6Wrong):
  defineCliInterface csM6ImpliesUnknownIface, "cs-m6-implies-unknown-iface":
    boolFlag quiet
    boolFlag verbose, implies = [jobs = 8] # CHECK
    subcmd "c":
      flag jobs is int
else:
  defineCliInterface csM6ImpliesUnknownIface, "cs-m6-implies-unknown-iface":
    boolFlag quiet
    boolFlag verbose, implies = [quiet = true]
    subcmd "c":
      flag jobs is int
