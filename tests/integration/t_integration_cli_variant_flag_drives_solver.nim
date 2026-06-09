## Spec-Implementation M2d — ``--variant name=value`` flows through the
## priority lattice into the solver's optimization objective.
##
## The CLI layer registers each ``--variant`` token via
## ``addVariantCliOverride`` (or via the ``REPRO_VARIANTS`` env var
## the runBuildCommand re-emits before spawning the provider). When the
## ambient context creates the variant node the CLI contribution lands
## as a ``prSet`` contribution. M2d's encoder maps ``prSet`` to
## ``vpSet`` (a higher solver-side weight than ``vpDefault``), so the
## solver's optimum picks the CLI-supplied value over the default.
##
## Asserts:
##   1. The solver receives the CLI contribution and resolves to the
##      requested value.
##   2. The cached ``UnifiedSolution.variants`` records the chosen
##      value verbatim (no priority-lattice fallback path was taken).
##   3. The CLI override survives ``REPRO_VARIANTS`` env-var
##      propagation (the cross-process hop the runBuildCommand uses).
##   4. Multiple variants in one command line all reach the solver.

import std/[os, strutils, tables, unittest]

import repro_dsl_stdlib/configurables

suite "Spec-Implementation M2d: --variant flag drives the solver":

  setup:
    resetVariantState()
    delEnv("REPRO_VARIANTS")

  test "addVariantCliOverride contribution lands in the solver":
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
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "clang"
    check compiler.value == "clang"
    # The solver proved optimality for the trivial single-variant
    # case (the search exhausted).
    check sol.optimal

  test "REPRO_VARIANTS env var reaches the solver":
    putEnv("REPRO_VARIANTS", "compiler=clang")
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
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "clang"
    check compiler.value == "clang"

  test "multiple --variant tokens all reach the solver":
    putEnv("REPRO_VARIANTS", "compiler=clang,enableTls=false")
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
    let tls = declareVariant[bool](
      defaultValue = true,
      scopeName = "enableTls",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "clang"
    check sol.variants["enableTls"] == "false"
    check compiler.value == "clang"
    check tls.value == false

  teardown:
    delEnv("REPRO_VARIANTS")
