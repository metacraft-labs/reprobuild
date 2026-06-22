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
##   3. A probe re-imports the fixture under ``REPRO_VARIANTS=buildType=release``
##      and asserts (a) the solver resolves the variant to ``release`` and
##      (b) the emitted action's output moves to ``build/release/`` (and never
##      stays under ``build/debug/``). This is the invariant codetracer's
##      reprobuild output-dir split relies on.

import std/[os, osproc, strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_project_dsl

import "../fixtures/spec-examples/buildtype-output/repro" as fixture

const ProbeSrcTemplate = """
import std/[os, strutils, tables]
import repro_dsl_stdlib/configurables
import repro_project_dsl
import "@ROOT@/tests/fixtures/spec-examples/buildtype-output/repro" as fixture

if not hasSolverSolution():
  quit "no solver solution"
let sol = lastSolverSolution()
let resolved = sol.variants.getOrDefault("buildType", "")
if resolved != "release":
  quit "buildType resolved to '" & resolved & "' but expected 'release'"
resetBuildActionRegistry()
fixture.buildBuildtypeOutputPackage()
let edges = registeredBuildActions()
var sawRelease = false
for e in edges:
  for o in e.outputs:
    if "build/debug/" in o:
      quit "output still under build/debug with buildType=release: " & o
    if "build/release/" in o:
      sawRelease = true
if not sawRelease:
  quit "expected an output under build/release/ but found none"
quit 0
"""

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
    let cacheDir = root / "build" / "nimcache" / "buildtype_output_probe"
    let probeSrc = root / "build" / "buildtype_output_probe.nim"
    let probeBin = root / "build" / "test-bin" / "buildtype_output_probe"
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
    putEnv("REPRO_VARIANTS", "buildType=release")
    let runResult = execCmdEx(probeBin)
    delEnv("REPRO_VARIANTS")
    if runResult.exitCode != 0:
      echo "PROBE RUN FAILED with exit " & $runResult.exitCode & ":"
      echo runResult.output
    check runResult.exitCode == 0
