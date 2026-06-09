## ``t_variant_encoder_conflicts`` — Spec-Implementation M2b encoder
## test for the ``conflicts:`` constraint form.
##
## Verifies that a ``conflicts:`` clause translates to the
## ``:- src, tgt.`` mutual-exclusion shape from the
## ``Configurable-System.md`` §"Constraint Expressions" spec.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/solver_api

suite "variant_encoder: conflicts":
  test "conflicts lowers to mutual-exclusion shape":
    let native = newBoolVariant("nativeTls",
      constraints = [conflictsExpr("true", "opensslTls", "true")])
    let openssl = newBoolVariant("opensslTls")
    let program = encodeVariants([native, openssl])

    # 1. The mutual-exclusion shape lands.
    check program.contains(
      ":- variant_assigned(\"nativeTls\", \"true\"), " &
      "variant_assigned(\"opensslTls\", \"true\").")

    # 2. NO "not" keyword in the conflicts shape (distinguishes from
    #    requires).
    var hasNotForConflict = false
    for line in program.splitLines():
      let s = line.strip()
      if s.startsWith(":-") and s.contains("\"nativeTls\""):
        if s.contains("not "):
          hasNotForConflict = true
    check not hasNotForConflict

    # 3. Both universes are present.
    check program.contains("variant_value(\"nativeTls\", \"true\").")
    check program.contains("variant_value(\"opensslTls\", \"true\").")

  test "conflicts forces the other variant off when one is on":
    # Both variants default to false. nativeTls=true is set by the
    # workspace; the conflicts clause then forces opensslTls=false.
    let native = newBoolVariant("nativeTls",
      contributions = [contribution(vpSet, "true")],
      constraints = [conflictsExpr("true", "opensslTls", "true")])
    let openssl = newBoolVariant("opensslTls",
      contributions = [contribution(vpDefault, "true")])
    let sol = solveVariants([native, openssl])

    # 1. The set value sticks for the source.
    check sol.assignments["nativeTls"] == "true"
    # 2. The conflict forced the target off despite its default.
    check sol.assignments["opensslTls"] == "false"
    # 3. Both variants are resolved.
    check sol.assignments.len == 2

  test "conflicts under double-force flips the lower-cost side off":
    # Priority weights are soft preferences — the integrity
    # constraint dominates. With both ``nativeTls`` and ``opensslTls``
    # carrying a ``prForce`` contribution toward ``true``, the
    # conflict rule means at most one can be ``true``. The solver
    # picks ONE of the two as ``true`` (tie under #minimize) and
    # flips the other off; both being ``true`` is the only model
    # forbidden by the integrity constraint.
    let native = newBoolVariant("nativeTls",
      contributions = [contribution(vpForce, "true")],
      constraints = [conflictsExpr("true", "opensslTls", "true")])
    let openssl = newBoolVariant("opensslTls",
      contributions = [contribution(vpForce, "true")])
    let sol = solveVariants([native, openssl])

    let n = sol.assignments["nativeTls"]
    let o = sol.assignments["opensslTls"]

    # 1. Both variables resolved.
    check sol.assignments.len == 2
    # 2. The conflict forbade the (true, true) joint assignment.
    check not (n == "true" and o == "true")
    # 3. At least one is true (clingo prefers higher-priority side
    #    under #minimize since prForce=1, no-contribution=5).
    check (n == "true" or o == "true")
