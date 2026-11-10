## Imported by `t_recipe_module_init_solves_only_for_a_toolchain_variant`
## directly AFTER a real source recipe, so its module init runs once that
## recipe's `build:` bodies have run, and before anything else the test
## imports.
##
## It records how many unified solves the recipe's module init ran, then
## reads the solved answer and records the count again. The second number is
## the control for the first: it shows a solve WAS owed and that the counter
## sees it paid, so a zero in the first cannot come from a registry with
## nothing to solve or from a counter that never moves.

import repro_dsl_stdlib/configurables/variants

let solvesAfterRealRecipe* = unifiedSolveCount()
let answerAfterRealRecipe* = hasSolverSolution()
let solvesAfterAnswerRead* = unifiedSolveCount()
