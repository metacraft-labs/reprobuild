## Hello World — Recipe-Val M8 multi-output recipe.
##
## Demonstrates Nix-style ``$out`` / ``$out-man`` partitioning at the
## reprobuild recipe layer. The recipe declares two outputs:
##
##   * ``bin``  — receives ``bin/hello`` (the compiled binary)
##   * ``man``  — receives ``share/man/man1/hello.1`` (the man page)
##
## The store layer materialises each output at its own
## content-addressed prefix (``prefixes/hello-world-multi-output-bin/...``
## vs ``prefixes/hello-world-multi-output-man/...``) and a downstream
## consumer that ``uses:`` only ``hello-world-multi-output.bin`` does
## NOT pull the ``man`` prefix into its runtime closure — exactly the
## Nix multi-output behavior the campaign asked for.
##
## Empty / absent ``outputs:`` keeps legacy single-output behavior
## (one prefix per package) so every existing recipe in the tree
## continues to build unchanged.

import repro_project_dsl
# DSL-port M9.R.2c — Library/Executable in scope for typed artifact slot vars.
import repro_dsl_stdlib/types

package helloWorldMultiOutput:
  uses:
    "gcc"

  outputs:
    output bin:
      paths = ["bin/*"]
    output man:
      paths = ["share/man/**"]

  executable hello-world-multi-output:
    discard
