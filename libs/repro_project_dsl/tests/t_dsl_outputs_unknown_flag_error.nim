## Named-Targets M0 verification: an ``outputs notDeclared`` statement
## where the named flag is not visible at the statement's scope (and
## not declared anywhere in the cli tree either) fails compilation,
## with the diagnostic citing the unknown name and the statement's
## source location.
##
## Compile real modules: `package` cannot expand inside a `compiles` block,
## even for valid input. The positive control proves the compiler can accept
## the matching legal recipe before the refusal's diagnostic is inspected.
## No mocks: the shared probe invokes the real Nim compiler on repository files.

import std/unittest
import ./dsl_port/service_block_compile_probe

suite "t_dsl_outputs_unknown_flag_error":
  test "t_dsl_outputs_unknown_flag_error":
    let accepted = checkRecipeSource("""
import repro_project_dsl
package tDslOutputsUnknownFlag:
  uses:
    "nim >=2.2 <3.0"
  executable tool:
    cli:
      subcmd "c":
        flag knownFlag is string
        outputs knownFlag
""", "outputs-unknown_flag-valid")
    checkpoint accepted.output
    require accepted.ok

    let rejected = checkRecipeSource("""
import repro_project_dsl
package tDslOutputsUnknownFlag:
  uses:
    "nim >=2.2 <3.0"
  executable tool:
    cli:
      subcmd "c":
        flag knownFlag is string
        outputs notDeclared
""", "outputs-unknown_flag-invalid")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("outputs: 'notDeclared' does not exist")
    check rejected.mentions("recipe.nim(9, 9) Error: outputs:")
