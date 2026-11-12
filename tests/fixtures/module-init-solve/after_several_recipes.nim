## Imported by `t_several_recipe_modules_init_without_a_solve_each` directly
## AFTER the real source recipes it links in, so its module init runs once
## every one of their `package` blocks has registered and every `build:` body
## has run.
##
## It records the unified-solve count, then reads the solved answer and
## records the count again. The second number is the control for the first:
## it shows a solve WAS owed over the registry the recipes built, and that the
## counter sees it paid.

import repro_dsl_stdlib/configurables/variants

let solvesAfterRecipes* = unifiedSolveCount()
let answerAfterRecipes* = hasSolverSolution()
let solvesAfterAnswerRead* = unifiedSolveCount()
