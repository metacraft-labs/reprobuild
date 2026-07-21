## RP1 provider-binary compile-time benchmark harness.
##
## Establishes the ``customSmallerIsBetter`` metric the later Provider-
## Runtime-Protocol milestones (RP4 interface-vs-full contrast, RP7 CI
## close-out) gate on: the wall-clock time to MATERIALIZE ``provider(B)``
## for a representative small project via the first-class provider-compile
## edge (``providerCompilePlan`` + ``compileProviderBinary``).
##
## It emits the interface-vs-full contrast the RP7 gate names: the cheap
## INTERFACE-mode thin-interface extraction (what a ``uses:`` consumer pays to
## see the provider's public API) vs the FULL-mode cold provider-binary compile
## that materializes the runnable ``provider(B)`` (freshness cache primed into an
## isolated scratch dir so the measured full run is not a cache hit). The JSON
## document mirrors the shape ``scripts/collect-benchmark-metrics.sh`` consumes
## for the ``rp1`` suite.
##
## Usage:
##   rp1_provider_compile_bench [--quick] [--out <path>]
##
## The RP7 close-out wires the session round-trip (RP2), cold-vs-warm consumer
## build (RP3), and the other composition suites into the shared
## ``scripts/collect-benchmark-metrics.sh`` default suite list, with the
## 20%-regression gate on the gh-pages baseline per continuous-benchmarking.md.

import std/[json, os, strutils, times]

import repro_interface_artifacts
import repro_core
import repro_hash

const providerBody = """
import repro_project_dsl

package rp1benchwidget:
  build:
    discard
"""

proc elapsedMs(start: float): float =
  (epochTime() - start) * 1000.0

proc main() =
  var quick = false
  var outPath = "bench-results/rp1-provider-compile.json"
  var i = 1
  let params = commandLineParams()
  while i <= params.len:
    if i - 1 < params.len:
      let arg = params[i - 1]
      case arg
      of "--quick":
        quick = true
      of "--out":
        if i < params.len:
          outPath = params[i]
          inc i
      else:
        discard
    inc i

  let workDir = getCurrentDir()
  let scratch = getTempDir() / "rp1-bench-" & $getCurrentProcessId() & "-" &
    $int(epochTime())
  removeDir(extendedPath(scratch))
  let projectRoot = scratch / "project"
  let outDir = scratch / "out"
  createDir(extendedPath(outDir))
  createDir(extendedPath(projectRoot))
  defer: removeDir(extendedPath(scratch))

  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)

  let interfacePath = outDir / "rp1-bench-interface.rbsz"
  let stubPath = outDir / "rp1-bench-interface.nim"

  # INTERFACE mode — the cheap thin-interface extraction a downstream consumer
  # pays to see the provider's public API (extract-only, no runnable binary).
  # This is the "fast interface compile" the campaign headlines: it is what a
  # `uses:` consumer needs, and it is strictly cheaper than the FULL
  # provider-binary compile below.
  let interfaceStart = epochTime()
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    workDir)
  let interfaceMs = elapsedMs(interfaceStart)

  let binPath = outDir / "rp1-bench-provider"
  let compilePath = outDir / "rp1-bench-provider-compile.rbsz"

  # FULL mode — the cold provider-binary compile that materializes the runnable
  # provider(B). This is the full source compile, contrasted against the cheap
  # interface extraction above; the interface-vs-full delta is the headline
  # RP7 gate metric.
  let start = epochTime()
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, workDir)
  let compileMs = elapsedMs(start)

  if not fileExists(extendedPath(compiled.outputBinaryPath)):
    quit("rp1 bench: provider binary was not materialized", 1)

  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, workDir)
  let providerArtifactIdHex = toHex(plan.providerArtifactId.bytes)

  let doc = %*{
    "schema": "reprobuild.rp1-provider-compile-bench.v1",
    "metadata": {
      "quick": quick,
      "project": "rp1benchwidget",
      "providerArtifactId": providerArtifactIdHex
    },
    "metrics": [
      {
        "suite": "rp1",
        "name": "provider compile time (interface mode: thin interface extract)",
        "unit": "ms",
        "value": interfaceMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "rp1",
        "name": "provider compile time (full mode: provider binary compile)",
        "unit": "ms",
        "value": compileMs,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "rp1 provider-compile-time: interface ",
    interfaceMs.formatFloat(ffDecimal, 3), " ms; full ",
    compileMs.formatFloat(ffDecimal, 3), " ms"

main()
