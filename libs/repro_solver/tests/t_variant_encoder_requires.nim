## ``t_variant_encoder_requires`` — Spec-Implementation M2b encoder
## test for the ``requires:`` constraint form.
##
## Verifies that a ``requires:`` clause translates to the
## ``:- src, not tgt.`` integrity-constraint shape from the
## ``Configurable-System.md`` §"Constraint Expressions" spec, and
## that the end-to-end solve forces the target value once the source
## value is set.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/solver_api

suite "variant_encoder: requires":
  test "requires lowers to integrity-constraint shape":
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "true")],
      constraints = [requiresExpr("true", "tlsBackend", "openssl")])
    let backend = newEnumVariant("tlsBackend", ["openssl", "boringssl"])
    let program = encodeVariants([enableTls, backend])

    # 1. The integrity constraint shape lands verbatim.
    check program.contains(
      ":- variant_assigned(\"enableTLS\", \"true\"), " &
      "not variant_assigned(\"tlsBackend\", \"openssl\").")

    # 2. Both variants' universes appear so the rule can fire.
    check program.contains("variant_value(\"enableTLS\", \"true\").")
    check program.contains("variant_value(\"tlsBackend\", \"openssl\").")
    check program.contains("variant_value(\"tlsBackend\", \"boringssl\").")

    # 3. Only one constraint of this shape — no duplicate emission.
    var constraintCount = 0
    for line in program.splitLines():
      let s = line.strip()
      if s.startsWith(":-") and s.contains("\"enableTLS\""):
        constraintCount.inc
    check constraintCount == 1

  test "requires forces target when source is set":
    # enableTLS=true requires tlsBackend=openssl. Without the require,
    # the cardinality lets the solver pick boringssl freely; with it,
    # only openssl satisfies the model.
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "true")],
      constraints = [requiresExpr("true", "tlsBackend", "openssl")])
    let backend = newEnumVariant("tlsBackend", ["openssl", "boringssl"])
    let sol = solveVariants([enableTls, backend])

    # 1. The source variant kept its set value.
    check sol.assignments["enableTLS"] == "true"
    # 2. The target variant was forced to the required value.
    check sol.assignments["tlsBackend"] == "openssl"
    # 3. The solver proved optimality.
    check sol.optimal

  test "requires does not constrain when source is not at trigger value":
    # When enableTLS=false the requires clause does not fire, so the
    # solver is free to pick the lowest-priority default for the
    # backend (the first universe entry under a tie).
    let enableTls = newBoolVariant("enableTLS",
      contributions = [contribution(vpSet, "false")],
      constraints = [requiresExpr("true", "tlsBackend", "openssl")])
    let backend = newEnumVariant("tlsBackend", ["openssl", "boringssl"],
      contributions = [contribution(vpDefault, "boringssl")])
    let sol = solveVariants([enableTls, backend])

    # 1. Source is false, so the require body never fires.
    check sol.assignments["enableTLS"] == "false"
    # 2. The backend keeps its default, not the require's "openssl".
    check sol.assignments["tlsBackend"] == "boringssl"
    # 3. Both variants are in the model.
    check sol.assignments.len == 2
