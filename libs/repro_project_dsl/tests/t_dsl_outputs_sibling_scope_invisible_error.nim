## Named-Targets M0 verification: an ``outputs siblingFlag`` where the
## named flag is declared on a *sibling* subcmd (not on the current
## subcmd and not on any enclosing one) fails compilation, and the
## diagnostic uses the "not in lexical scope" wording — distinct from
## the "does not exist" wording used for genuinely unknown names.

import std/[unittest]

import repro_project_dsl

suite "t_dsl_outputs_sibling_scope_invisible_error":
  test "t_dsl_outputs_sibling_scope_invisible_error":
    check not compiles((block:
      package tDslOutputsSiblingBad:
        uses:
          "nim >=2.2 <3.0"
        executable tool:
          cli:
            subcmd "sibling":
              flag siblingFlag is string
            subcmd "c":
              flag knownFlag is string
              outputs siblingFlag
    ))
