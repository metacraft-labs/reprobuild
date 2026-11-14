## A package `cli:` block whose `default` is wrong-typed when compiled with
## `-d:csM6Wrong` (see `t_cs_m6_cli_model_type_checks_in_reprobuild_macros`).
import repro_project_dsl
import repro_dsl_stdlib/types

const csM6Default = (when defined(csM6Wrong): "four" else: 4)

package csM6TypeChecksPkg:
  uses:
    "nim >=2.2 <3.0"

  executable foo:
    cli:
      subcmd "c":
        flag jobs is int, default = csM6Default # CHECK
