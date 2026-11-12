## Several recipe modules linked into one binary initialise without a clingo
## solve per registration.
##
## Reprobuild-pm issue
## `2026-11-01-recipe-modules-compiled-together-pay-a-clingo-solve-per-registration-at-start-up`.
## A binary importing 25 `recipes/packages/source/<pkg>` smoke tests spent
## 43 s of user CPU at start-up (5 tests: 23 s; one alone: 0.01 s), logging
## 147 solves over a program that grew with every registered recipe. Each
## `package` block left the module-init solve owed and each `build:` body's
## toolchain read paid it again over the cumulative registry. The fix is
## reprobuild `aa127fd53` (A1 + A2 of issue
## `2026-11-07-test-binaries-pay-minutes-of-module-init-before-any-case-runs`);
## `t_recipe_module_init_solves_only_for_a_toolchain_variant` holds it for a
## single recipe, and this file holds it for the case that issue measured:
## several DISTINCT recipes, each its own module, in one program.
##
## The imports below are the test, in this order:
##
##   1. `before_several_recipes`, which records the solve count so far;
##   2. five real source recipes (`alsa-lib`, `at-spi2-core`, `attica`,
##      `dbus`, `expat`), each its own module with a `build:` body;
##   3. `after_several_recipes`, which records the count again, then reads the
##      solved answer and counts once more — the control that the registry
##      the recipes built did owe a solve.
##
## Solves are counted (`unifiedSolveCount`), never timed. Built with
## `aa127fd53`'s `toolchain_policy.nim` change (A1) reverted, the difference
## between (3) and (1) was 71 solves and the control read found none owed;
## with it, 0 and 1 (measured 2026-11-11 on `agents` `a2eb4cfed`).
##
## Test-double policy: NO mocks, doubles, or fakes. Real recipes through the
## real `package` macro, real clingo solves.

import std/unittest

import repro_dsl_stdlib/configurables/variants

import "../fixtures/module-init-solve/before_several_recipes" as before
import "../../recipes/packages/source/alsa-lib/repro" as alsaLib
import "../../recipes/packages/source/at-spi2-core/repro" as atSpi2Core
import "../../recipes/packages/source/attica/repro" as attica
import "../../recipes/packages/source/dbus/repro" as dbus
import "../../recipes/packages/source/expat/repro" as expat
import "../fixtures/module-init-solve/after_several_recipes" as after

suite "several recipe modules in one binary initialise without a solve each":

  test "registering five real recipes ran no solve":
    check after.solvesAfterRecipes - before.solvesBeforeRecipes == 0

  test "control: the recipes left one solve owed, and one read paid it":
    check after.answerAfterRecipes
    check after.solvesAfterAnswerRead - after.solvesAfterRecipes == 1

  test "a second read of the answer runs no further solve":
    discard hasSolverSolution()
    discard lastSolverSolution()
    check unifiedSolveCount() == after.solvesAfterAnswerRead
