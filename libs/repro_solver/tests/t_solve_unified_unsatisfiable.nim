## ``t_solve_unified_unsatisfiable`` — Spec-Implementation M2c unified
## driver failure-path test.
##
## A package + variant combination with no valid concretization must
## raise ``EUnsatisfiable`` and carry the ASP program + unsat-core for
## the diagnostic.

import std/[strutils, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api

suite "unified solve unsatisfiable":
  test "variant trigger forces a range with no satisfying version":
    # ``enableTLS=true`` activates ``openssl >=3.0``. The catalog only
    # has openssl 1.1.0 — no satisfying version exists. To make the
    # variant assignment hard (the priority lattice alone is soft and
    # the solver would otherwise downgrade to enableTLS=false to
    # escape the constraint), we restrict the universe to ``true``
    # only — modeling the case where the user pinned the variant on
    # the command line.
    let enableTls = newEnumVariant("enableTLS", ["true"],
      contributions = [contribution(vpForce, "true")])
    let openssl = newPackage("openssl", versions = ["1.1.0"])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")])

    var raised = false
    var coreHasApp = false
    var coreHasOpenssl = false
    var programNonEmpty = false
    try:
      discard solve([enableTls], [openssl, app])
    except EUnsatisfiable as e:
      raised = true
      coreHasApp = "app" in e.unsatCore
      coreHasOpenssl = "openssl" in e.unsatCore
      programNonEmpty = e.programText.strip().len > 0

    # 1. Unsat detected.
    check raised
    # 2. The diagnostic carries the program text.
    check programNonEmpty
    # 3. The dependency-edge participants appear in the best-effort
    #    core enumeration.
    check coreHasApp
    check coreHasOpenssl

  test "contradictory requires + version pin raise EUnsatisfiable":
    # ``a`` requires ``b=off``; ``b`` is force-set to ``on`` by an
    # upstream contribution. AND the package ``p`` depends on a
    # version of ``q`` not in the catalog.
    let a = newEnumVariant("a", ["on"],
      contributions = [contribution(vpDefault, "on")],
      constraints = [requiresExpr("on", "b", "off")])
    let b = newEnumVariant("b", ["on"],
      contributions = [contribution(vpForce, "on")])
    let q = newPackage("q", versions = ["1.0.0"])
    let p = newPackage("p",
      versions = ["0.1.0"],
      depends = [newDependency("q", ">=2.0")])

    var raised = false
    try:
      discard solve([a, b], [p, q])
    except EUnsatisfiable:
      raised = true
    check raised

  test "empty version catalog is unsat for a depended-on package":
    let empty = newPackage("empty", versions = [])
    let app = newPackage("app",
      versions = ["0.1.0"],
      depends = [newDependency("empty", ">=1.0")])

    var raised = false
    var coreHasEmpty = false
    try:
      discard solve([], [empty, app])
    except EUnsatisfiable as e:
      raised = true
      coreHasEmpty = "empty" in e.unsatCore

    # 1. Unsat detected — the package_active facts demand a
    #    package_chosen but the universe is empty.
    check raised
    # 2. The unsat core mentions the empty-catalog package since it
    #    sits on an edge.
    check coreHasEmpty
