## Named-Targets M0 verification: an ``outputs notYet`` statement that
## precedes the declaration of ``notYet`` in the same scope fails
## compilation. Source-order visibility matches the rest of the ``cli:``
## grammar — a flag must be declared *before* an ``outputs`` statement
## can reference it.

##
## Compile real modules: `package` cannot expand inside a `compiles` block,
## even for valid input. The positive control proves the compiler can accept
## the matching legal recipe before the refusal's diagnostic is inspected.
## No mocks: the shared probe invokes the real Nim compiler on repository files.

import std/unittest
import ./dsl_port/service_block_compile_probe

suite "t_dsl_outputs_forward_reference_error":
  test "t_dsl_outputs_forward_reference_error":
    let accepted = checkRecipeSource("""
import repro_project_dsl
package tDslOutputsForward:
  uses:
    "nim >=2.2 <3.0"
  executable tool:
    cli:
      subcmd "c":
        flag notYet is string
        outputs notYet
""", "outputs-forward_reference-valid")
    checkpoint accepted.output
    require accepted.ok

    let rejected = checkRecipeSource("""
import repro_project_dsl
package tDslOutputsForward:
  uses:
    "nim >=2.2 <3.0"
  executable tool:
    cli:
      subcmd "c":
        outputs notYet
        flag notYet is string
""", "outputs-forward_reference-invalid")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("outputs: 'notYet' is not in lexical scope")
    check rejected.mentions("recipe.nim(8, 9) Error: outputs:")
