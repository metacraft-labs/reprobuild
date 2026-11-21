## A recipe's module init runs no clingo solve unless a toolchain variant is
## declared.
##
## Reprobuild-pm issue
## `2026-11-07-test-binaries-pay-minutes-of-module-init-before-any-case-runs`,
## option A1. In a non-provider binary — every `test_<pkg>_source` smoke test
## — a recipe's `build:` body runs at module init and reaches
## `toolchain_policy.activeSolvedVariants`. That read used to pay the solve the
## module-init finalize had deferred, once per imported recipe copy, over the
## cumulative registry: 102 solves for `test_kcodecs_source`, 622 (365 s) for
## `test_kwin_source`. No source recipe declares `targetTriple` or `compiler`,
## so every one of those solves answered "unset".
##
## The imports below are the test, in this order:
##
##   1. a real source recipe (`zlib`), whose `build:` body calls the
##      `autotools_package` constructor and so the toolchain read;
##   2. `after_real_recipe`, which counts the solves (1) ran, then reads the
##      solved answer and counts again — the control that a solve was owed;
##   3. a fixture recipe that DOES declare `compiler`, whose body records what
##      the toolchain read returned.
##
## Solves are counted (`unifiedSolveCount`), never timed. That the zlib body
## reaches the toolchain read is not asserted here; it was shown by building
## this file with the A1 skip disabled, where the first count is non-zero.
##
## Test-double policy: NO mocks, doubles, or fakes. Real recipes through the
## real `package` macro, real clingo solves.

import std/unittest

import repro_dsl_stdlib/configurables/variants

import "../../recipes/packages/source/zlib/repro" as realRecipe
import "../fixtures/module-init-solve/after_real_recipe" as afterReal
import "../fixtures/module-init-solve/declares-compiler/repro" as declares

suite "a recipe's module init solves only for a toolchain variant":

  test "a real recipe that declares none ran its build body without solving":
    ## Before A1 this count was the number of recipe copies whose body
    ## reached the toolchain read; it is the assertion that moved.
    check afterReal.solvesAfterRealRecipe == 0

  test "control: the recipe left a solve owed, and reading the answer paid it":
    check afterReal.answerAfterRealRecipe
    check afterReal.solvesAfterAnswerRead == 1

  test "a recipe that declares compiler gets the solver's answer in its body":
    check declares.compilerSeenByBody == "clang"
    check declares.solvesSeenByBody == afterReal.solvesAfterAnswerRead + 1
