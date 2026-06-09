## Spec-Implementation M2d — end-to-end check that
## ``--variant enableTLS=false`` against the variant-feature-flag
## fixture drops the openssl dep, the TLS build edge, and the TLS test
## enrollment.
##
## The fixture's ``repro.nim`` declares ``enableTLS: variant bool =
## true``. The ``uses:`` block has a single ``if enableTLS.value:``
## arm that pulls in openssl; the ``build:`` block emits a TLS test
## edge gated by the same ``.value``. With the variant resolved
## false, all three contributions should disappear from the graph.
##
## In-process assertions (this file):
##   1. Importing the fixture drives the solver (the package macro
##      emits ``finalizeVariants()``). The DEFAULT variant value
##      resolves to ``true`` so the openssl dep gate fires.
##   2. The pending solver-dependency registry records the TLS arm
##      with ``gateVariant = "enableTLS"`` and ``gateValue = "true"``.
##   3. Invoking ``buildVariantFeatureFlagPackage()`` with the default
##      variant emits BOTH the basic test edge and the TLS test edge.
##
## Subprocess assertion:
##   4. Compiles a probe that re-imports the fixture under
##      ``REPRO_VARIANTS=enableTLS=false`` and asserts (a) the
##      solver resolves the variant to ``false``, (b) the build proc
##      emits ONLY the basic test edge (the TLS edge is dropped by
##      the ``if enableTLS.value`` arm in the build body).

import std/[os, osproc, strutils, tables, unittest]

import repro_dsl_stdlib/configurables
import repro_project_dsl

import "../fixtures/spec-examples/variant-feature-flag/repro" as fixture

const ProbeSrcTemplate = """
import std/[os, strutils, tables]
import repro_dsl_stdlib/configurables
import repro_project_dsl
import "@ROOT@/tests/fixtures/spec-examples/variant-feature-flag/repro" as fixture

if not hasSolverSolution():
  quit "no solver solution"
let sol = lastSolverSolution()
let resolved = sol.variants.getOrDefault("enableTLS", "")
if resolved != "false":
  quit "enableTLS resolved to '" & resolved & "' but expected 'false'"
resetBuildActionRegistry()
fixture.buildVariantFeatureFlagPackage()
let edges = registeredBuildActions()
var tlsCount = 0
for e in edges:
  if "t_tls" in e.id:
    inc tlsCount
  for o in e.outputs:
    if "t_tls" in o:
      inc tlsCount
      break
if tlsCount != 0:
  quit "expected 0 TLS edges with enableTLS=false but got " & $tlsCount
if edges.len < 1:
  quit "expected at least one build edge but got 0"
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

suite "Spec-Implementation M2d: variant-feature-flag fixture e2e":

  test "fixture's package macro drives the solver at module init":
    check variantsFinalized()
    check hasSolverSolution()
    let sol = lastSolverSolution()
    check sol.variants.hasKey("enableTLS")

  test "default variant value resolves to true":
    let sol = lastSolverSolution()
    check sol.variants["enableTLS"] == "true"

  test "TLS arm registered with the right gate":
    let pending = pendingSolverDependencies()
    var sawTls = false
    for entry in pending:
      if entry.depPackage == "openssl":
        sawTls = true
        check entry.parentPackage == "variant_feature_flag"
        check entry.gateVariant == "enableTLS"
        check entry.gateValue == "true"
    check sawTls

  test "with enableTLS=true the build proc emits the TLS edge":
    resetBuildActionRegistry()
    fixture.buildVariantFeatureFlagPackage()
    let edges = registeredBuildActions()
    check edges.len >= 2
    var tlsEdgeCount = 0
    for e in edges:
      if "t_tls" in e.id or "t_tls" in $e.outputs:
        inc tlsEdgeCount
    check tlsEdgeCount >= 1

  test "REPRO_VARIANTS=enableTLS=false drops the TLS edge":
    let root = reproRoot()
    let cacheDir = root / "build" / "nimcache" / "variant_feature_flag_probe"
    let probeSrc = root / "build" / "variant_feature_flag_probe.nim"
    let probeBin = root / "build" / "test-bin" / "variant_feature_flag_probe"
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
    putEnv("REPRO_VARIANTS", "enableTLS=false")
    let runResult = execCmdEx(probeBin)
    delEnv("REPRO_VARIANTS")
    if runResult.exitCode != 0:
      echo "PROBE RUN FAILED with exit " & $runResult.exitCode & ":"
      echo runResult.output
    check runResult.exitCode == 0
