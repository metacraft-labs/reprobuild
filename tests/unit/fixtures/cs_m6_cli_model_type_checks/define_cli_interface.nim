## A `defineCliInterface` whose `default` is wrong-typed when compiled with
## `-d:csM6Wrong` (see `t_cs_m6_cli_model_type_checks_in_reprobuild_macros`).
import repro_project_dsl

const csM6Default = (when defined(csM6Wrong): "four" else: 4)

defineCliInterface csM6Iface, "cs-m6-iface":
  subcmd "c":
    flag jobs is int, default = csM6Default # CHECK
