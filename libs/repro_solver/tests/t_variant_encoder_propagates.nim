## ``t_variant_encoder_propagates`` — Spec-Implementation M2b encoder
## test for the ``propagates:`` constraint form.
##
## Per the M2b scope statement, cross-package propagation is M2c
## work; in M2b the encoder treats ``propagates:`` as a forced
## within-package equality (``A=x => B=y``). The same lowering shape
## as ``requires:`` applies — the distinction surfaces only when M2c
## adds the dependency-walk component. This test verifies the
## current within-package contract.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/solver_api

suite "variant_encoder: propagates":
  test "propagates lowers to forced-equality shape":
    let hasNetwork = newBoolVariant("hasNetwork",
      contributions = [contribution(vpDefault, "true")],
      constraints = [propagatesExpr("true", "dependentNet", "true")])
    let dep = newBoolVariant("dependentNet")
    let program = encodeVariants([hasNetwork, dep])

    # 1. The forced-equality shape lands (same as requires).
    check program.contains(
      ":- variant_assigned(\"hasNetwork\", \"true\"), " &
      "not variant_assigned(\"dependentNet\", \"true\").")

    # 2. The target variant's universe is present so the rule fires.
    check program.contains("variant_value(\"dependentNet\", \"true\").")

    # 3. Exactly one propagates-style integrity constraint.
    var constraintCount = 0
    for line in program.splitLines():
      let s = line.strip()
      if s.startsWith(":-") and s.contains("\"hasNetwork\""):
        constraintCount.inc
    check constraintCount == 1

  test "within-package propagation carries the target value":
    let hasNetwork = newBoolVariant("hasNetwork",
      contributions = [contribution(vpSet, "true")],
      constraints = [propagatesExpr("true", "dependentNet", "true")])
    let dep = newBoolVariant("dependentNet",
      contributions = [contribution(vpDefault, "false")])
    let sol = solveVariants([hasNetwork, dep])

    # 1. Source kept its set value.
    check sol.assignments["hasNetwork"] == "true"
    # 2. Target was forced to the propagated value despite its
    #    default of false.
    check sol.assignments["dependentNet"] == "true"
    # 3. Both variants are in the solution.
    check sol.assignments.len == 2

  test "propagates does not fire when source mismatches trigger":
    let hasNetwork = newBoolVariant("hasNetwork",
      contributions = [contribution(vpSet, "false")],
      constraints = [propagatesExpr("true", "dependentNet", "true")])
    let dep = newBoolVariant("dependentNet",
      contributions = [contribution(vpDefault, "false")])
    let sol = solveVariants([hasNetwork, dep])

    # 1. Source is false, the propagate body never fires.
    check sol.assignments["hasNetwork"] == "false"
    # 2. The dependent keeps its default rather than the propagated
    #    value.
    check sol.assignments["dependentNet"] == "false"
    # 3. The solver still proves optimality with the propagate dormant.
    check sol.optimal
