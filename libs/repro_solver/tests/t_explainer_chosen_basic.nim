## Spec-Implementation M2e — ``explainChosen`` returns the priority
## contribution that pinned the chosen value when no constraints fire.
##
## The minimal scenario: a single variant with one default contribution.
## ``explainChosen`` must return:
##
##   1. The chosen value as it appears in the solution.
##   2. The single ``vpDefault`` contribution as the only entry in
##      ``contributions``.
##   3. An empty ``gatingConstraints`` list.
##   4. An empty ``parentInfluences`` list.

import std/unittest

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api
import repro_solver/explainer

suite "explainChosen — single contribution, no constraints":
  test "single variant with a default contribution":
    let compiler = newEnumVariant("compiler", ["gcc", "clang"],
      contributions = [contribution(vpDefault, "gcc")])
    let sol = solve([compiler], [])
    let chain = explainChosen(sol, "compiler", [compiler], [])

    # 1. The chain names the variant and the chosen value.
    check chain.variant == "compiler"
    check chain.chosen == "gcc"
    # 2. The single contribution is present and at the right priority.
    check chain.contributions.len == 1
    check chain.contributions[0].priority == vpDefault
    check chain.contributions[0].value == "gcc"
    # 3. No gating constraints.
    check chain.gatingConstraints.len == 0
    # 4. No parent influences.
    check chain.parentInfluences.len == 0

  test "EVariantNotInSolution when variant absent":
    let compiler = newEnumVariant("compiler", ["gcc"],
      contributions = [contribution(vpDefault, "gcc")])
    let sol = solve([compiler], [])
    var raised = false
    try:
      discard explainChosen(sol, "missingVariant", [compiler], [])
    except EVariantNotInSolution:
      raised = true
    check raised
