## Spec-Implementation M2e — ``explainChosen`` surfaces the gating
## constraints that pinned a variant via a sibling variant's
## ``requires:`` rule.
##
## Scenario: variant ``compiler == "gcc"`` REQUIRES ``stdlib == "libstdc++"``.
## When the solve fixes compiler to gcc (via a vpForce contribution),
## explaining stdlib should surface the incoming requires constraint
## from compiler.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api
import repro_solver/explainer

suite "explainChosen — gating constraints":
  test "incoming requires from a sibling variant lands in the chain":
    # ``compiler=gcc`` requires ``stdlib=libstdc++``. The default for
    # stdlib is ``libc++`` — but the constraint forces libstdc++.
    let compiler = newEnumVariant("compiler", ["gcc", "clang"],
      contributions = [contribution(vpForce, "gcc")],
      constraints = [requiresExpr("gcc", "stdlib", "libstdc++")])
    let stdlib = newEnumVariant("stdlib", ["libc++", "libstdc++"],
      contributions = [contribution(vpDefault, "libc++")])
    let sol = solve([compiler, stdlib], [])

    # The constraint dominates the default.
    check sol.variants["compiler"] == "gcc"
    check sol.variants["stdlib"] == "libstdc++"

    let chain = explainChosen(sol, "stdlib", [compiler, stdlib], [])

    # 1. Chosen reflects the constraint outcome.
    check chain.chosen == "libstdc++"
    # 2. The default contribution still surfaces (the constraint is
    #    represented separately in gatingConstraints).
    check chain.contributions.len == 1
    check chain.contributions[0].priority == vpDefault
    check chain.contributions[0].value == "libc++"
    # 3. The gating constraint from compiler is present in the chain.
    check chain.gatingConstraints.len >= 1
    var sawSource = false
    for c in chain.gatingConstraints:
      # The source-encoded form is "compiler==gcc" for incoming
      # constraints (see ``collectIncomingConstraints``).
      if "compiler" in c.sourceValue and c.kind == crkRequires and
         c.target == "stdlib" and c.targetValue == "libstdc++":
        sawSource = true
    check sawSource

  test "own constraint surfaces when explaining the source variant":
    # Explaining "compiler" itself should include the requires
    # constraint defined ON compiler (because the source value fired).
    let compiler = newEnumVariant("compiler", ["gcc"],
      contributions = [contribution(vpDefault, "gcc")],
      constraints = [requiresExpr("gcc", "stdlib", "libstdc++")])
    let stdlib = newEnumVariant("stdlib", ["libstdc++"],
      contributions = [contribution(vpDefault, "libstdc++")])
    let sol = solve([compiler, stdlib], [])

    let chain = explainChosen(sol, "compiler", [compiler, stdlib], [])
    check chain.chosen == "gcc"

    # 1. The variant's own constraint surfaces (sourceValue is the
    #    raw "gcc", not the encoded "name==value" form, because this
    #    is the variant's OWN constraint).
    var sawOwn = false
    for c in chain.gatingConstraints:
      if c.kind == crkRequires and c.target == "stdlib" and
         c.sourceValue == "gcc":
        sawOwn = true
    check sawOwn
    # 2. The contributions list still carries the default.
    check chain.contributions.len == 1
    # 3. No parent influences (no packages declared).
    check chain.parentInfluences.len == 0
