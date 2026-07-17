## RP1 provider-binary compile-time benchmark harness.
##
## Establishes the ``customSmallerIsBetter`` metric the later Provider-
## Runtime-Protocol milestones (RP4 interface-vs-full contrast, RP7 CI
## close-out) gate on: the wall-clock time to MATERIALIZE ``provider(B)``
## for a representative small project via the first-class provider-compile
## edge (``providerCompilePlan`` + ``compileProviderBinary``).
##
## It performs one COLD provider compile (freshness cache primed into an
## isolated scratch dir so the measured run is not a cache hit) and emits a
## JSON document mirroring the shape ``scripts/collect-benchmark-metrics.sh``
## consumes for the ``rp1`` suite.
##
## Usage:
##   rp1_provider_compile_bench [--quick] [--out <path>]
##
## TODO(RP7): fold the session round-trip (RP2) and cold-vs-warm consumer
## build (RP3) metrics into this suite and wire the 20%-regression gate on
## the gh-pages baseline per continuous-benchmarking.md.

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
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    workDir)

  let binPath = outDir / "rp1-bench-provider"
  let compilePath = outDir / "rp1-bench-provider-compile.rbsz"

  # Cold provider compile — this is the metric.
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
        "name": "provider binary compile time (interface mode)",
        "unit": "ms",
        "value": compileMs,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "rp1 provider-compile-time: ", compileMs.formatFloat(ffDecimal, 3), " ms"

main()
