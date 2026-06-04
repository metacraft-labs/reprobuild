## Named-Targets M0 verification: an ``outputs notDeclared`` statement
## where the named flag is not visible at the statement's scope (and
## not declared anywhere in the cli tree either) fails compilation,
## with the diagnostic citing the unknown name and the statement's
## source location.
##
## The macro emits ``error(...)`` at compile time, so ``not compiles``
## traps the failure inside the surrounding type check.

import std/[unittest]

import repro_project_dsl

suite "t_dsl_outputs_unknown_flag_error":
  test "t_dsl_outputs_unknown_flag_error":
    check not compiles((block:
      package tDslOutputsUnknownFlagBad:
        uses:
          "nim >=2.2 <3.0"
        executable tool:
          cli:
            subcmd "c":
              flag knownFlag is string
              outputs notDeclared
    ))
