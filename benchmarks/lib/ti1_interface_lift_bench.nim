## TI1 interface-lift-time benchmark harness (Production Thin Interface Mode).
##
## Establishes the ``customSmallerIsBetter`` metric the TI-track / RP7 CI
## close-out gate on: the wall-clock time to LIFT a producer's interface via
## the first-class, cached interface-artifact edge (``interfaceLiftPlan`` +
## ``liftInterfaceArtifact``), contrasted COLD (first materialization) vs
## cache-HIT (the lift edge is NOT re-run — the artifact is read from cache).
##
## This is the metric that makes the TI2 win visible: once the producer's
## interface is lifted once, every consumer reads the cache-HIT path instead
## of the RP5a ``staticExec``-per-consumer re-extract (~2m/consumer).
##
## Usage:
##   ti1_interface_lift_bench [--quick] [--out <path>]
##
## TODO(RP7): fold this into the shared suite loop + wire the 20%-regression
## gate on the gh-pages baseline per continuous-benchmarking.md.

import std/[json, os, strutils, times]

import repro_interface_artifacts
import repro_core
import repro_hash

const producerBody = """
import repro_project_dsl

package ti1benchwidget:
  executable ti1bench:
    name: "ti1-bench"
    cli:
      subcmd "bundle":
        flag output is string
  build:
    discard
"""

proc elapsedMs(start: float): float =
  (epochTime() - start) * 1000.0

proc main() =
  var quick = false
  var outPath = "bench-results/ti1-interface-lift.json"
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
  let scratch = getTempDir() / "ti1-bench-" & $getCurrentProcessId() & "-" &
    $int(epochTime())
  removeDir(extendedPath(scratch))
  let projectRoot = scratch / "project"
  let outDir = scratch / "out"
  createDir(extendedPath(outDir))
  createDir(extendedPath(projectRoot))
  defer: removeDir(extendedPath(scratch))

  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), producerBody)

  let artifactPath = outDir / "ti1-bench-interface.rbsz"
  let stubPath = outDir / "ti1-bench-interface.nim"

  # COLD lift — first materialization of the interface-artifact edge.
  let coldPlan = interfaceLiftPlan(modulePath, artifactPath, stubPath,
    workDir = workDir)
  let coldStart = epochTime()
  let cold = liftInterfaceArtifact(coldPlan)
  let coldMs = elapsedMs(coldStart)

  if not fileExists(extendedPath(artifactPath)):
    quit("ti1 bench: interface artifact was not materialized", 1)

  # Cache-HIT lift — the lift edge is NOT re-run; the artifact is read back.
  let warmPlan = interfaceLiftPlan(modulePath, artifactPath, stubPath,
    workDir = workDir)
  let warmStart = epochTime()
  let warm = liftInterfaceArtifact(warmPlan)
  let warmMs = elapsedMs(warmStart)

  if warm.interfaceFingerprint != cold.interfaceFingerprint:
    quit("ti1 bench: cache-HIT lift produced a different fingerprint", 1)

  let interfaceFingerprintHex = toHex(cold.interfaceFingerprint.bytes)

  let doc = %*{
    "schema": "reprobuild.ti1-interface-lift-bench.v1",
    "metadata": {
      "quick": quick,
      "project": "ti1benchwidget",
      "interfaceFingerprint": interfaceFingerprintHex,
      "interfaceLiftActionKey": toHex(coldPlan.interfaceLiftActionKey.bytes)
    },
    "metrics": [
      {
        "suite": "ti1",
        "name": "interface lift time (cold materialize)",
        "unit": "ms",
        "value": coldMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "ti1",
        "name": "interface lift time (cache HIT)",
        "unit": "ms",
        "value": warmMs,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "ti1 interface-lift-time: cold ", coldMs.formatFloat(ffDecimal, 3),
    " ms; cache-HIT ", warmMs.formatFloat(ffDecimal, 3), " ms"

main()
