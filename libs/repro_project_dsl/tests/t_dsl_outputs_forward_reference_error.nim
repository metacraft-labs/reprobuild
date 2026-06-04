## Named-Targets M0 verification: an ``outputs notYet`` statement that
## precedes the declaration of ``notYet`` in the same scope fails
## compilation. Source-order visibility matches the rest of the ``cli:``
## grammar — a flag must be declared *before* an ``outputs`` statement
## can reference it.

import std/[unittest]

import repro_project_dsl

suite "t_dsl_outputs_forward_reference_error":
  test "t_dsl_outputs_forward_reference_error":
    check not compiles((block:
      package tDslOutputsForwardBad:
        uses:
          "nim >=2.2 <3.0"
        executable tool:
          cli:
            subcmd "c":
              outputs notYet
              flag notYet is string
    ))
