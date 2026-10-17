## Named-Targets M0 verification: an ``outputs siblingFlag`` where the
## named flag is declared on a *sibling* subcmd (not on the current
## subcmd and not on any enclosing one) fails compilation, and the
## diagnostic uses the "not in lexical scope" wording — distinct from
## the "does not exist" wording used for genuinely unknown names.

##
## Compile real modules: `package` cannot expand inside a `compiles` block,
## even for valid input. The positive control proves the compiler can accept
## the matching legal recipe before the refusal's diagnostic is inspected.
## No mocks: the shared probe invokes the real Nim compiler on repository files.

import std/unittest
import ./dsl_port/service_block_compile_probe

suite "t_dsl_outputs_sibling_scope_invisible_error":
  test "t_dsl_outputs_sibling_scope_invisible_error":
    let accepted = checkRecipeSource("""
import repro_project_dsl
package tDslOutputsSibling:
  uses:
    "nim >=2.2 <3.0"
  executable tool:
    cli:
      subcmd "sibling":
        flag siblingFlag is string
      subcmd "c":
        flag knownFlag is string
        outputs knownFlag
""", "outputs-sibling_scope_invisible-valid")
    checkpoint accepted.output
    require accepted.ok

    let rejected = checkRecipeSource("""
import repro_project_dsl
package tDslOutputsSibling:
  uses:
    "nim >=2.2 <3.0"
  executable tool:
    cli:
      subcmd "sibling":
        flag siblingFlag is string
      subcmd "c":
        flag knownFlag is string
        outputs siblingFlag
""", "outputs-sibling_scope_invisible-invalid")
    checkpoint rejected.output
    check not rejected.ok
    check rejected.mentions("outputs: 'siblingFlag' is not in lexical scope")
    check rejected.mentions("recipe.nim(11, 9) Error: outputs:")
