## Imported by `t_several_recipe_modules_init_without_a_solve_each` directly
## BEFORE the real source recipes it links in, so its module init runs before
## any of their `package` blocks register.
##
## It records the unified-solve count at that point. The test asserts on the
## difference to the count taken after the recipes, so a solve some other
## module in the same binary ran earlier (a group binary initialises every
## member) cannot be mistaken for, or hide, one the recipes ran.

import repro_dsl_stdlib/configurables/variants

let solvesBeforeRecipes* = unifiedSolveCount()
