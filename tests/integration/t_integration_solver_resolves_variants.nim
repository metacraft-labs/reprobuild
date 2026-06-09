## Spec-Implementation M2d — ``finalizeVariants()`` drives the unified
## solver.
##
## After M2d ``finalizeVariants()`` builds a ``VariantDecl`` list from
## the ambient variant context and a ``PackageDecl`` list from the
## pending solver-dependency registry, then calls
## ``repro_solver.solve(variants, packages)`` and writes the returned
## assignments back onto each variant's ``resolvedVal`` slot.
##
## This integration test asserts:
##   1. The solver actually runs (``hasSolverSolution`` flips true).
##   2. ``variant.value`` returns the solver-chosen value, not the M1
##      priority-lattice fallback (which would still work in this case
##      because the chosen value matches the highest-priority
##      contribution; the explicit assertion is on the solution cache).
##   3. The cached ``UnifiedSolution.variants`` mirrors what each
##      variant returns from ``.value``.

import std/[strutils, tables, unittest]

import repro_dsl_stdlib/configurables

suite "Spec-Implementation M2d: finalizeVariants drives the solver":

  setup:
    resetVariantState()

  test "bool variant is resolved via the solver path":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let enableTls = declareVariant[bool](
      defaultValue = true,
      scopeName = "enableTls",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    check not hasSolverSolution()
    finalizeVariants()
    check hasSolverSolution()
    check enableTls.value == true
    let sol = lastSolverSolution()
    check sol.variants["enableTls"] == "true"

  test "enum variant resolves through the solver":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let compiler = declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    check hasSolverSolution()
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "gcc"
    check compiler.value == "gcc"
    # The solver records its optimality bit; for an unconstrained
    # variant set the search exhausts and ``optimal`` is true.
    check sol.optimal

  test "priority lattice flows through the solver":
    # CLI override (prSet) outranks default; solver respects the same
    # ordering by mapping each contribution to a weight where prSet
    # (vpSet=1) is preferred over prDefault (vpDefault=0). After M2d
    # the priority lattice is the SOLVER'S optimization objective, not
    # a pre-solve resolver — but the observed result for a single
    # variant with a default + a set contribution is identical to M1.
    addVariantCliOverride("compiler", "clang")
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let compiler = declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    check hasSolverSolution()
    check compiler.value == "clang"
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "clang"
