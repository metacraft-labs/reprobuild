## The assumption-interface unsat core names the constraints that fail,
## each once — not the first guard twice.
##
## Regression for reprobuild-pm
## ``issues/2026-11-19-the-unsat-core-driver-reports-the-first-assumption-twice-instead-of-the-core.md``.
## ``encodeWithAssumptions`` guards every constraint with an
## ``#external assume_constraint(N).`` atom. clingo keeps an unassigned
## external false by handing the solver the external's negation as an
## assumption of its own, so assuming the guard true contradicted that
## assumption by itself: the solve was UNSAT whatever the program said,
## and the core was the first guard and its negation, which the driver
## decoded as ``assume_constraint(0)`` twice. Every pre-existing
## ``t_explainer_unsat_*`` scenario either carried a single constraint
## (where "the first guard" happens to be the right answer) or checked
## only that the core was non-empty, so none of them noticed.
##
## Each case below has a satisfied constraint annotated BEFORE the
## violated one, which is the shape that exposes the defect, and asserts
## the exact decoded core. No mocks: the real encoder and the real
## clingo library run end to end.
##
## Locking-And-Solver.md §"CLI Surface": the failure's message carries
## the unsat core, each constraint in it named as the recipe declared it.

import std/[strutils, unittest]

import repro_solver/variant_encoder
import repro_solver/version_encoder
import repro_solver/solver_api
import repro_solver/explainer

proc unsatOf(variants: openArray[VariantDecl];
             packages: openArray[PackageDecl]): ref EUnsatisfiable =
  ## Run ``solve`` and return the ``EUnsatisfiable`` it raises, or nil
  ## when it does not raise.
  try:
    discard solve(variants, packages)
  except EUnsatisfiable as e:
    return e
  return nil

proc coreSources(e: ref EUnsatisfiable;
                 variants: openArray[VariantDecl];
                 packages: openArray[PackageDecl]): seq[string] =
  for entry in explainUnsat(e.coreAtoms, variants, packages):
    result.add("[" & entry.kind & "] " & entry.source)

suite "unsat core names the violated constraints":
  test "a transitive edge with no candidate is the core, named once":
    # The issue's scenario: root -> a >=0.0.0 holds (a 1.0.0 is in
    # range); a -> b >=2.0.0 cannot (b has only 1.0.0).
    let root = newPackage("root", versions = ["0.1.0"],
      depends = [newDependency("a", ">=0.0.0")])
    let a = newPackage("a", versions = ["1.0.0"],
      depends = [newDependency("b", ">=2.0.0")])
    let b = newPackage("b", versions = ["1.0.0"])
    let packages = [root, a, b]

    let e = unsatOf([], packages)
    require e != nil
    check e.coreAtoms == @["assume_constraint(1)"]
    check coreSources(e, [], packages) ==
      @["[depends_on] a -> b >=2.0.0"]
    # The message every route prints names the failing edge and never
    # the satisfied one.
    check "  - [depends_on] a -> b >=2.0.0" in e.msg
    check "root -> a" notin e.msg

  test "the violated edge is found behind several satisfied ones":
    let app = newPackage("app", versions = ["1.0.0"],
      depends = [newDependency("zlib", ">=1.0"),
                 newDependency("curl", ">=7.0"),
                 newDependency("openssl", ">=3.0")])
    let zlib = newPackage("zlib", versions = ["1.3.0"])
    let curl = newPackage("curl", versions = ["8.0.0"])
    let openssl = newPackage("openssl", versions = ["1.1.0"])
    let packages = [app, zlib, curl, openssl]

    let e = unsatOf([], packages)
    require e != nil
    check coreSources(e, [], packages) ==
      @["[depends_on] app -> openssl >=3.0"]

  test "two variant constraints that conflict are both named, once each":
    # An unrelated, satisfied constraint on ``d`` is annotated first.
    # a=on requires b=on; b=on conflicts with c=on; a and c are forced
    # on. Neither constraint fails alone, so the core is exactly both.
    let d = newEnumVariant("d", ["x", "y"],
      contributions = [contribution(vpDefault, "x")],
      constraints = [requiresExpr("x", "d", "x")])
    let a = newEnumVariant("a", ["on"],
      contributions = [contribution(vpForce, "on")],
      constraints = [requiresExpr("on", "b", "on")])
    let b = newEnumVariant("b", ["on", "off"],
      contributions = [contribution(vpDefault, "off")],
      constraints = [conflictsExpr("on", "c", "on")])
    let c = newEnumVariant("c", ["on"],
      contributions = [contribution(vpForce, "on")])
    let variants = [d, a, b, c]

    let e = unsatOf(variants, [])
    require e != nil
    check coreSources(e, variants, []) == @[
      "[constraint] a requires b==on (when a==on)",
      "[constraint] b conflicts c==on (when b==on)"]
