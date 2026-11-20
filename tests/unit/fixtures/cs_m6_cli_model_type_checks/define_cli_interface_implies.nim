## A `defineCliInterface` whose `implies` value is wrong-typed when compiled
## with `-d:csM6Wrong` (see `t_cs_m6_cli_model_type_checks_in_reprobuild_macros`).
## Right-typed, it is an `int`, the type of the implied `jobs`, and not a
## `bool`, the type of the implying `fast`: the control compiles only when
## the value is checked against the parameter it sets. The value is on a line
## of its own, so the error must name that line, not the flag's.
import repro_project_dsl

const csM6Implied = (when defined(csM6Wrong): "eight" else: 8)

defineCliInterface csM6ImpliesIface, "cs-m6-implies-iface":
  subcmd "c":
    flag jobs is int
    boolFlag fast,
      implies = [jobs = csM6Implied] # CHECK
