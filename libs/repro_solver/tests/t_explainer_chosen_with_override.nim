## Spec-Implementation M2e — ``explainChosen`` surfaces both
## contributions in priority order when a higher-priority contribution
## outranks the default.
##
## Two contributions land on the same variant: ``vpDefault = "gcc"``
## and ``vpSet = "clang"`` (modeling a workspace override). The solver
## picks ``"clang"`` because ``vpSet`` outranks ``vpDefault``.
##
## ``explainChosen`` must:
##
##   1. Return ``"clang"`` as the chosen value.
##   2. Show ``vpSet`` BEFORE ``vpDefault`` in the contributions list
##      (sorted by priority descending).
##   3. Include BOTH contributions (sorting is not the same as
##      filtering — the lower-priority entry stays visible so the
##      diagnostic can render the full lattice).
##   4. Empty constraints / parents.

import std/unittest

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api
import repro_solver/explainer

suite "explainChosen — override outranks default":
  test "vpSet contribution outranks vpDefault":
    let compiler = newEnumVariant("compiler", ["gcc", "clang"],
      contributions = [
        contribution(vpDefault, "gcc"),
        contribution(vpSet, "clang")])
    let sol = solve([compiler], [])
    let chain = explainChosen(sol, "compiler", [compiler], [])

    # 1. Chosen is the higher-priority value.
    check chain.chosen == "clang"
    # 2. Two contributions visible.
    check chain.contributions.len == 2
    # 3. Sorted by priority descending: vpSet (1) before vpDefault (0).
    check chain.contributions[0].priority == vpSet
    check chain.contributions[0].value == "clang"
    check chain.contributions[1].priority == vpDefault
    check chain.contributions[1].value == "gcc"
    # 4. No constraints, no parents.
    check chain.gatingConstraints.len == 0
    check chain.parentInfluences.len == 0

  test "vpForce contribution outranks vpOverride":
    let toolchain = newEnumVariant("toolchain", ["a", "b", "c"],
      contributions = [
        contribution(vpDefault, "a"),
        contribution(vpOverride, "b"),
        contribution(vpForce, "c")])
    let sol = solve([toolchain], [])
    let chain = explainChosen(sol, "toolchain", [toolchain], [])

    # 1. The force contribution wins.
    check chain.chosen == "c"
    # 2. All three contributions surface.
    check chain.contributions.len == 3
    # 3. Highest priority lands at index 0.
    check chain.contributions[0].priority == vpForce
    check chain.contributions[0].value == "c"
    # 4. Lowest at the tail.
    check chain.contributions[^1].priority == vpDefault
