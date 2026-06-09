## ``t_version_encoder_transitive`` — Spec-Implementation M2c encoder
## test for cross-package transitive dependencies.
##
## Verifies that choosing a package with a dependency on another
## package forces the depended-on package to a satisfying version in
## the same solve.

import std/[strutils, tables, unittest]

import repro_solver/version_encoder
import repro_solver/solver_api

suite "version_encoder: transitive dependencies":
  test "two-hop dependency chain forces consistent versions":
    # ``app`` depends on ``mid``; ``mid`` depends on ``low``.
    # Constraints: ``mid >=1.0`` and ``low >=2.0``.
    let low = newPackage("low",
      versions = ["1.5.0", "2.0.0", "2.5.0"])
    let mid = newPackage("mid",
      versions = ["1.0.0", "1.2.0"],
      depends = [newDependency("low", ">=2.0")])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("mid", ">=1.0")])
    let sol = solve([], [low, mid, app])

    # 1. ``app`` and ``mid`` resolve in the expected range.
    check sol.packages["app"] == "0.1.0"
    check sol.packages["mid"] in ["1.0.0", "1.2.0"]
    # 2. The transitive ``low`` constraint forces a satisfying version.
    check sol.packages["low"] in ["2.0.0", "2.5.0"]
    # 3. All three packages resolve.
    check sol.packages.len == 3

  test "depends_on edges expose the dependency graph":
    let nim = newPackage("nim", versions = ["2.2.4"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("nim", ">=2.0")])
    let program = encodePackages([nim, app])

    # 1. The ``depends_on`` edge lands so cross-package propagation
    #    can later consume it.
    check program.contains("depends_on(\"app\", \"nim\").")
    # 2. The typed ``package_required`` form also lands for
    #    diagnostic-friendly read-back.
    check program.contains(
      "package_required(\"app\", \"nim\", \">=2.0\").")
    # 3. The integrity constraint mentions both sides.
    check program.contains("package_chosen(\"app\", _)")

  test "two independent siblings each see their own constraint":
    # ``app`` depends on ``a >=1.0`` and on ``b >=1.0``. Each sibling
    # must resolve to its own in-range version independently.
    let a = newPackage("a", versions = ["0.5.0", "1.0.0", "1.5.0"])
    let b = newPackage("b", versions = ["0.5.0", "1.0.0", "2.0.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("a", ">=1.0"),
                 newDependency("b", ">=1.0")])
    let sol = solve([], [a, b, app])

    # 1. ``a`` lands inside the explicit range.
    check sol.packages["a"] in ["1.0.0", "1.5.0"]
    # 2. ``b`` lands inside its own explicit range, independently.
    check sol.packages["b"] in ["1.0.0", "2.0.0"]
    # 3. ``app`` resolved.
    check sol.packages["app"] == "0.1.0"
