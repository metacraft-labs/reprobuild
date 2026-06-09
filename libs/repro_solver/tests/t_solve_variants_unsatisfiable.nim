## ``t_solve_variants_unsatisfiable`` — Spec-Implementation M2b
## driver test for the failure path.
##
## Feeds a contradictory registry (a variant forced to ``true`` with
## a ``requires: false`` clause against another forced-true variant)
## and verifies that ``solveVariants`` raises ``EVariantUnsatisfiable``
## carrying the ASP program text and the best-effort unsat-core
## enumeration of the constraint-participating variants.

import std/[strutils, unittest]

import repro_solver/variant_encoder
import repro_solver/solver_api

suite "solveVariants unsatisfiable":
  test "singleton-universe variants with contradictory require raise":
    # ``a`` has a single-value universe (always picks "on") and
    # carries a ``requires: b == "off"`` constraint. ``b`` has a
    # single-value universe locked to "on". The require demands
    # b=off but the only model for b is b=on, so the joint problem
    # has no stable model.
    let a = newEnumVariant("a", ["on"],
      contributions = [contribution(vpDefault, "on")],
      constraints = [requiresExpr("on", "b", "off")])
    let b = newEnumVariant("b", ["on"],
      contributions = [contribution(vpDefault, "on")])

    var raised = false
    var coreHasA = false
    var coreHasB = false
    var programNonEmpty = false
    try:
      discard solveVariants([a, b])
    except EVariantUnsatisfiable as e:
      raised = true
      coreHasA = "a" in e.unsatCore
      coreHasB = "b" in e.unsatCore
      programNonEmpty = e.programText.strip().len > 0

    # 1. The contradictory input is detected as unsat.
    check raised
    # 2. The unsat-core mentions the constraint source variant.
    check coreHasA
    # 3. The unsat-core mentions the constraint target variant.
    check coreHasB
    # 4. The exception carries the ASP program text for diagnostics.
    check programNonEmpty

  test "empty value space is unsatisfiable":
    # An enum variant with NO allowed values has an empty universe;
    # cardinality {…} = 1 cannot be satisfied.
    let v = VariantDecl(
      name: "empty",
      kind: vkEnum,
      allowedValues: @[],
      contributions: @[],
      constraints: @[])

    var raised = false
    var programNonEmpty = false
    try:
      discard solveVariants([v])
    except EVariantUnsatisfiable as e:
      raised = true
      programNonEmpty = e.programText.strip().len > 0

    # 1. Empty universe => unsat.
    check raised
    # 2. The diagnostic carries the program text.
    check programNonEmpty
    # 3. The exception is the typed unsat exception (not a generic one).
    check raised
