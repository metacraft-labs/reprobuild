## Spec-Implementation M2d — end-to-end check that the
## ``selectable-toolchain`` fixture compiles AND its build proc lands
## the variant-resolved compiler choice.
##
## The fixture's ``repro.nim`` declares a ``variant: string``
## ``compiler`` with two ``case`` arms inside ``uses:``. M2d's
## ``finalizeVariants()`` drives the unified solver against the
## variant + the per-arm ``registerSolverDependency`` emissions; the
## generated ``buildSelectableToolchainPackage()`` proc consumes the
## resolved ``compiler.value`` to dispatch into the right adapter.
##
## In-process assertions (this file):
##   1. The fixture's package macro emits + drives the solver at
##      module init (``hasSolverSolution`` flips true, variant
##      ``compiler`` is in the solution).
##   2. The default variant value lands when no override is supplied
##      (resolves to ``"gcc"``).
##   3. The pending solver-dependency registry records BOTH the gcc
##      arm and the clang arm with the right ``gateVariant`` /
##      ``gateValue`` pair on each.
##   4. Invoking the generated ``buildSelectableToolchainPackage``
##      proc emits at least one BuildActionDef (the gcc compile edge).
##
## Subprocess assertion (covers the CLI variant flag path):
##   5. Compiles a thin probe that imports the fixture under
##      ``REPRO_VARIANTS=compiler=clang``. The probe asserts the
##      variant resolved to ``"clang"`` and exits 0; the test fails
##      if the probe exits nonzero.

import std/[os, osproc, strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_project_dsl

# The fixture's repro.nim emits ``finalizeVariants()`` at module init.
# Importing it drives the solver against the variant + the per-arm
# solver-dependency registrations. The variants module reads the env
# var at first-access time, so the in-process import always sees the
# DEFAULT variant value (no REPRO_VARIANTS is set in the test's
# parent environment).
import "../fixtures/spec-examples/selectable-toolchain/repro" as fixture

const ProbeSrcTemplate = """
import std/[os, tables]
import repro_dsl_stdlib/configurables
import "@ROOT@/tests/fixtures/spec-examples/selectable-toolchain/repro" as fixture

let sol = lastSolverSolution()
if not hasSolverSolution():
  quit "no solver solution"
if sol.variants.getOrDefault("compiler", "") != "clang":
  quit "compiler resolved to '" & sol.variants.getOrDefault("compiler", "") &
    "' but expected 'clang'"
quit 0
"""

proc reproRoot(): string =
  # Walk up from the test source file (this .nim) rather than the
  # compiled binary location: getAppFilename() points at the nim
  # cache when the test was built via `nim r`, which has no Justfile
  # on the upward path. currentSourcePath stays anchored to the
  # source tree regardless of where the binary lives.
  var dir = currentSourcePath().parentDir
  while dir.len > 1:
    if fileExists(dir / "Justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

suite "Spec-Implementation M2d: selectable-toolchain fixture e2e":

  test "fixture's package macro drives the solver at module init":
    check variantsFinalized()
    check hasSolverSolution()
    let sol = lastSolverSolution()
    check sol.variants.hasKey("compiler")

  test "default variant value resolves to gcc":
    let sol = lastSolverSolution()
    check sol.variants["compiler"] == "gcc"

  test "both case arms of uses: registered solver deps with gates":
    let pending = pendingSolverDependencies()
    var sawGcc = false
    var sawClang = false
    for entry in pending:
      check entry.parentPackage == "selectable_toolchain"
      check entry.gateVariant == "compiler"
      if entry.depPackage == "gcc":
        sawGcc = true
        check entry.gateValue == "gcc"
      elif entry.depPackage == "clang":
        sawClang = true
        check entry.gateValue == "clang"
    check sawGcc
    check sawClang

  test "buildSelectableToolchainPackage runs and emits at least one edge":
    resetBuildActionRegistry()
    fixture.buildSelectableToolchainPackage()
    let edges = registeredBuildActions()
    check edges.len >= 1

  test "REPRO_VARIANTS=compiler=clang flows through the solver":
    # Build a probe binary that imports the fixture under the env-var
    # override, then exec it. The probe asserts the solver resolved
    # compiler to "clang" and exits 0 on success.
    let root = reproRoot()
    let cacheDir = root / "build" / "nimcache" / "selectable_toolchain_probe"
    let probeSrc = root / "build" / "selectable_toolchain_probe.nim"
    let probeBin = root / "build" / "test-bin" / "selectable_toolchain_probe"
    createDir(cacheDir)
    createDir(root / "build" / "test-bin")
    writeFile(probeSrc, ProbeSrcTemplate.replace("@ROOT@", root))
    let nimcmd = "nim c --hints:off --warnings:off --nimcache:" & cacheDir &
      " --out:" & probeBin & " " & probeSrc
    let buildResult = execCmdEx(nimcmd)
    if buildResult.exitCode != 0:
      echo "PROBE BUILD FAILED:"
      echo buildResult.output
    check buildResult.exitCode == 0
    # Run the probe with REPRO_VARIANTS set; the probe writes its
    # diagnostic to stdout via ``quit``.
    putEnv("REPRO_VARIANTS", "compiler=clang")
    let runResult = execCmdEx(probeBin)
    delEnv("REPRO_VARIANTS")
    if runResult.exitCode != 0:
      echo "PROBE RUN FAILED with exit " & $runResult.exitCode & ":"
      echo runResult.output
    check runResult.exitCode == 0
