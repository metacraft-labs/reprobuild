## A recipe that declares the `compiler` variant, for
## `t_recipe_module_init_solves_only_for_a_toolchain_variant`.
##
## Its `build:` body reads the toolchain the way every typed-tool call does
## (`activeSolvedVariants`), and records what it got and how many unified
## solves had run by then. The declared value is not the empty default the
## read falls back to when it skips the solve, so the recorded value tells
## the solver's answer from the skip's.

import repro_project_dsl
import repro_dsl_stdlib
import repro_dsl_stdlib/configurables/variants
import repro_dsl_stdlib/toolchain_policy

var compilerSeenByBody*: string
var solvesSeenByBody*: int

package module_init_declares_compiler:
  config:
    compiler: variant string = "clang"

  uses:
    "libfoo >=1.5"

  build:
    compilerSeenByBody = activeSolvedVariants().compiler
    solvesSeenByBody = unifiedSolveCount()
