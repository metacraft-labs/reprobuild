## Spec-Implementation M5 — cross-compilation fixture compiles + drives
## the solver to the expected variant resolution.
##
## The fixture at
## ``tests/fixtures/spec-examples/cross-compilation/repro.nim`` is the
## load-bearing spec exhibit for the M5 cross-compilation worked
## example. This test:
##   1. Imports the fixture under the default variant resolution
##      (``targetTriple = "native"``) and confirms the solver ran +
##      the variant landed at the default value.
##   2. Confirms the fixture's ``buildCrossCompilationPackage`` proc
##      ran during module init and registered the engine-level
##      ``BuildActionDef`` rows so a ``repro build`` invocation
##      against this fixture sees a populated build graph.
##   3. Confirms the fixture registered a build graph collection
##      named ``hello`` (per the ``collect("hello", ...)`` call) on
##      the M5 parallel ``collectionRegistry`` — verifying the
##      registry split is exercised end-to-end through a real
##      fixture's expansion path.
##   4. Subprocess sub-test: runs the fixture under
##      ``REPRO_VARIANTS=targetTriple=aarch64-linux-gnu`` and asserts
##      the resolved variant value matches.

import std/[os, osproc, strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_project_dsl

# Importing the fixture drives the solver at module init.
import "../fixtures/spec-examples/cross-compilation/repro" as fixture

const ProbeSrcTemplate = """
import std/[os, tables]
import repro_dsl_stdlib/configurables
import "@ROOT@/tests/fixtures/spec-examples/cross-compilation/repro" as fixture

let sol = lastSolverSolution()
if not hasSolverSolution():
  quit "no solver solution"
let resolved = sol.variants.getOrDefault("targetTriple", "")
if resolved != "aarch64-linux-gnu":
  quit "targetTriple resolved to '" & resolved &
    "' but expected 'aarch64-linux-gnu'"
quit 0
"""

proc reproRoot(): string =
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

suite "Spec-Implementation M5: cross-compilation fixture compiles":

  test "fixture's package macro drives the solver at module init":
    check variantsFinalized()
    check hasSolverSolution()
    let sol = lastSolverSolution()
    check sol.variants.hasKey("targetTriple")

  test "default variant value resolves to native":
    let sol = lastSolverSolution()
    check sol.variants["targetTriple"] == "native"

  test "buildCrossCompilationPackage runs and registers compile + link edges":
    resetBuildActionRegistry()
    resetBuildTargetRegistry()
    fixture.buildCrossCompilationPackage()
    let actions = registeredBuildActions()
    check actions.len >= 2
    var sawCompile = false
    var sawLink = false
    for action in actions:
      if "compile" in action.id:
        sawCompile = true
      elif "link" in action.id:
        sawLink = true
    check sawCompile
    check sawLink

  test "fixture registers the 'hello' collection on the M5 collection registry":
    resetBuildActionRegistry()
    resetBuildTargetRegistry()
    fixture.buildCrossCompilationPackage()
    let collections = registeredCollections()
    check collections.len >= 1
    var sawHello = false
    for entry in collections:
      if entry.name == "hello":
        check entry.kind == btkCollection
        sawHello = true
    check sawHello

    # The legacy aggregate half should NOT carry the ``hello`` row —
    # ``collect`` no longer aliases ``aggregate``.
    let aggregates = registeredAggregates()
    for entry in aggregates:
      check entry.name != "hello"

  test "REPRO_VARIANTS=targetTriple=aarch64-linux-gnu drives the solver":
    let root = reproRoot()
    let cacheDir =
      root / "build" / "nimcache" / "cross_compilation_probe"
    let probeSrc = root / "build" / "cross_compilation_probe.nim"
    let probeBin = root / "build" / "test-bin" / "cross_compilation_probe"
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
    putEnv("REPRO_VARIANTS", "targetTriple=aarch64-linux-gnu")
    let runResult = execCmdEx(probeBin)
    delEnv("REPRO_VARIANTS")
    if runResult.exitCode != 0:
      echo "PROBE RUN FAILED with exit " & $runResult.exitCode & ":"
      echo runResult.output
    check runResult.exitCode == 0
