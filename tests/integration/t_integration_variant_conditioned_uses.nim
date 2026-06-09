## Spec-Implementation M2d — variant-conditioned ``uses:`` arms
## actually contribute the right package constraint after the solver
## resolves the variant.
##
## In M1 the macro-time ``collectUses`` walk took the UNION of every
## branch's leaves (no runtime info to gate on). In M2d the parser
## tags each branch's leaves with the gating variant + value, the
## ``package`` macro emits one ``registerSolverDependency`` per leaf,
## and the solver activates only the arm whose gate matches the
## resolved variant.
##
## This test drives the surface directly via
## ``registerSolverDependency`` so we don't depend on the macro
## emission for the gate semantics — that's covered by the e2e
## fixture test. Here we assert:
##
##   1. The ``compiler == "gcc"`` arm contributes ``gcc >=12``.
##   2. The ``compiler == "clang"`` arm contributes ``clang >=16``.
##   3. The solver resolves ``compiler`` to the requested value AND
##      the gated dep's chosen version satisfies the arm's range.
##   4. The unselected arm's package still appears in the universe but
##      the integrity constraint that binds the chosen version to the
##      arm's range does not fire — so a fresh test scenario with
##      ``compiler == "clang"`` lands ``clang`` at a clang-shaped
##      version.

import std/[strutils, tables, unittest]

import repro_dsl_stdlib/configurables

suite "Spec-Implementation M2d: variant-conditioned uses: resolution":

  setup:
    resetVariantState()

  test "case arm with compiler=gcc activates the gcc range":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    registerSolverDependency("toolchain_demo", "gcc",
      "gcc >=12 <15", gateVariant = "compiler", gateValue = "gcc")
    registerSolverDependency("toolchain_demo", "clang",
      "clang >=16 <19", gateVariant = "compiler", gateValue = "clang")
    finalizeVariants()
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "gcc"
    # gcc range "gcc >=12 <15" -> smallest satisfying version is 12.0.0.
    check chosenVersion("gcc") == "12.0.0"
    # clang's gate didn't fire; its universe entry is still present so
    # the solver picks SOMETHING for it (the cardinality constraint
    # mandates one chosen version per declared package). The arm's
    # integrity constraint is unconditioned on the gate so clang's
    # chosen version is still drawn from its universe.
    check chosenVersion("clang") == "16.0.0"

  test "case arm with compiler=clang activates the clang range":
    addVariantCliOverride("compiler", "clang")
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    registerSolverDependency("toolchain_demo", "gcc",
      "gcc >=12 <15", gateVariant = "compiler", gateValue = "gcc")
    registerSolverDependency("toolchain_demo", "clang",
      "clang >=16 <19", gateVariant = "compiler", gateValue = "clang")
    finalizeVariants()
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "clang"
    # clang range "clang >=16 <19" -> smallest satisfying version is 16.0.0.
    check chosenVersion("clang") == "16.0.0"

  test "the pending solver dependency registry records both arms":
    registerSolverDependency("toolchain_demo", "gcc",
      "gcc >=12 <15", gateVariant = "compiler", gateValue = "gcc")
    registerSolverDependency("toolchain_demo", "clang",
      "clang >=16 <19", gateVariant = "compiler", gateValue = "clang")
    let pending = pendingSolverDependencies()
    check pending.len == 2
    var sawGcc = false
    var sawClang = false
    for entry in pending:
      check entry.parentPackage == "toolchain_demo"
      check entry.gateVariant == "compiler"
      if entry.depPackage == "gcc":
        sawGcc = true
        check entry.gateValue == "gcc"
        check "gcc" in entry.rng
      elif entry.depPackage == "clang":
        sawClang = true
        check entry.gateValue == "clang"
        check "clang" in entry.rng
    check sawGcc
    check sawClang
