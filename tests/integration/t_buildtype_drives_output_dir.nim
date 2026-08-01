## Standard-Configurations — end-to-end check that a ``buildType`` variant
## drives the output directory of a package's build actions.
##
## The fixture (tests/fixtures/spec-examples/buildtype-output/repro.nim)
## declares ``buildType: variant string = "debug"`` and emits a single
## ``nim.c`` action whose binary lives under ``build/<buildType>/bin/app``.
##
## In-process assertions (this file):
##   1. Importing the fixture drives the solver; the DEFAULT variant value
##      resolves to ``"debug"``.
##   2. Invoking the build proc with the default variant emits an action
##      whose output is under ``build/debug/``.
##
## Subprocess assertion:
##   3. A graph-built probe re-imports the fixture under
##      ``REPRO_VARIANTS=buildType=release``
##      and asserts (a) the solver resolves the variant to ``release`` and
##      (b) the emitted action's output moves to ``build/release/`` (and never
##      stays under ``build/debug/``). This is the invariant codetracer's
##      reprobuild output-dir split relies on.

import std/[os, osproc, strutils, tables, unittest]

import repro_test_support
import repro_dsl_stdlib/configurables
import repro_project_dsl

import "../fixtures/spec-examples/buildtype-output/repro" as fixture

proc reproRoot(): string =
  # Anchor on the source tree (currentSourcePath), not the compiled binary,
  # so the upward Justfile walk works under `nim r`.
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

suite "Standard-Configurations: buildType drives the output directory":

  test "fixture's package macro drives the solver at module init":
    check variantsFinalized()
    check hasSolverSolution()
    let sol = lastSolverSolution()
    check sol.variants.hasKey("buildType")

  test "default buildType resolves to debug":
    let sol = lastSolverSolution()
    check sol.variants["buildType"] == "debug"

  test "with the default variant the output is under build/debug/":
    resetBuildActionRegistry()
    fixture.buildBuildtypeOutputPackage()
    let edges = registeredBuildActions()
    check edges.len >= 1
    var sawDebug = false
    for e in edges:
      for o in e.outputs:
        check "build/release/" notin o
        if "build/debug/" in o:
          sawDebug = true
    check sawDebug

  test "REPRO_VARIANTS=buildType=release moves output to build/release/":
    let root = reproRoot()
    let probeBin = requireBinary(
      root / "build" / "test-bin" /
        addFileExt("buildtype_output_probe", ExeExt),
      "reprobuild.test_fixtures.buildtype_output_probe")
    let hadVariants = existsEnv("REPRO_VARIANTS")
    let oldVariants = getEnv("REPRO_VARIANTS")
    putEnv("REPRO_VARIANTS", "buildType=release")
    var runResult: tuple[output: string, exitCode: int]
    try:
      runResult = execCmdEx(quoteShell(probeBin))
    finally:
      if hadVariants:
        putEnv("REPRO_VARIANTS", oldVariants)
      else:
        delEnv("REPRO_VARIANTS")
    if runResult.exitCode != 0:
      echo "PROBE RUN FAILED with exit " & $runResult.exitCode & ":"
      echo runResult.output
    check runResult.exitCode == 0
