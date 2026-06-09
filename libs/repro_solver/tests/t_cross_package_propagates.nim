## ``t_cross_package_propagates`` — Spec-Implementation M2c encoder
## test for the cross-package ``propagates:`` constraint (deferred
## from M2b).
##
## A ``propagates:`` directive on variant V_X in package X contributes
## to a matching variant in any package Y that depends on X. The M2b
## encoder handled within-package propagation; M2c extends to the
## cross-package case via the ``depends_on(Y, X)`` predicate.

import std/[strutils, tables, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api

suite "cross-package propagates":
  test "propagates forces target variant when dependent depends on source":
    # Source package ``netlib`` has a variant ``hasNetwork=true`` that
    # propagates ``usesNetwork=true`` onto dependents. Dependent
    # package ``app`` declares its own ``usesNetwork`` variant
    # defaulted to ``false``. App depends on netlib so the propagation
    # should flip ``usesNetwork`` to true.
    let netlibVariant = newBoolVariant("hasNetwork",
      contributions = [contribution(vpSet, "true")],
      constraints = [propagatesExpr("true", "usesNetwork", "true")])
    let appVariant = newBoolVariant("usesNetwork",
      contributions = [contribution(vpDefault, "false")])

    let netlib = newPackage("netlib",
      versions = ["1.0.0"],
      variants = [netlibVariant])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("netlib", ">=1.0")],
      variants = [appVariant])

    let sol = solve([], [netlib, app])

    # 1. The source variant kept its set value.
    check sol.variants["hasNetwork"] == "true"
    # 2. The propagation flipped the target variant despite its default.
    check sol.variants["usesNetwork"] == "true"
    # 3. The packages both resolved.
    check sol.packages["netlib"] == "1.0.0"
    check sol.packages["app"] == "0.1.0"

  test "propagation gated on depends_on does NOT cross to unrelated package":
    # ``netlib`` propagates ``usesNetwork=true`` but ``unrelated`` does
    # not depend on netlib. The propagation must NOT touch
    # ``unrelated``'s ``usesNetwork`` variant — it keeps its default.
    let netlibVariant = newBoolVariant("hasNetwork",
      contributions = [contribution(vpSet, "true")],
      constraints = [propagatesExpr("true", "usesNetwork", "true")])
    let unrelatedVariant = newBoolVariant("usesNetwork",
      contributions = [contribution(vpDefault, "false")])

    let netlib = newPackage("netlib",
      versions = ["1.0.0"],
      variants = [netlibVariant])
    let unrelated = newPackage("unrelated",
      versions = ["1.0.0"],
      variants = [unrelatedVariant])

    let sol = solve([], [netlib, unrelated])

    # 1. Source kept its set value.
    check sol.variants["hasNetwork"] == "true"
    # 2. ``unrelated.usesNetwork`` is independent — keeps the default.
    check sol.variants["usesNetwork"] == "false"
    # 3. Optimality proven (no constraint conflict).
    check sol.optimal

  test "encoder emits integrity constraint joined on depends_on":
    let netlibVariant = newBoolVariant("hasNetwork",
      contributions = [contribution(vpDefault, "true")],
      constraints = [propagatesExpr("true", "usesNetwork", "true")])
    let appVariant = newBoolVariant("usesNetwork")

    let netlib = newPackage("netlib",
      versions = ["1.0.0"], variants = [netlibVariant])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("netlib", ">=1.0")],
      variants = [appVariant])

    let program = encodeUnified([], [netlib, app])

    # 1. The propagation rule joins the source variant against the
    #    depends_on edge.
    check program.contains("variant_assigned(\"hasNetwork\", \"true\")")
    check program.contains("depends_on(\"app\", \"netlib\")")
    check program.contains(
      "not variant_assigned(\"usesNetwork\", \"true\")")
    # 2. Exactly one cross-package propagation rule for this pair.
    var count = 0
    for line in program.splitLines():
      let s = line.strip()
      if s.startsWith(":-") and
         s.contains("hasNetwork") and
         s.contains("depends_on(\"app\", \"netlib\")") and
         s.contains("usesNetwork"):
        inc count
    check count == 1
