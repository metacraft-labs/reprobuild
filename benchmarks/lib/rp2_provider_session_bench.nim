## RP2 (Project-Provider-Runtime-Protocol) — provider-session round-trip
## latency benchmark harness.
##
## Establishes the ``customSmallerIsBetter`` session round-trip metric the
## milestone's benchmark gate names: WARM (an invoke over an already-launched,
## reused session) vs COLD (launch child + EngineHello/ProviderManifest
## handshake + first invoke). Mirrors the RP1 harness JSON shape so
## ``scripts/collect-benchmark-metrics.sh``'s ``rp1``-kind parser consumes the
## ``rp2`` suite unchanged.
##
## The provider binary is materialized once via the RP1 edge
## (``compileProviderBinary``); the compile time is NOT part of the measured
## session metric (RP1 owns that).
##
## Usage:
##   rp2_provider_session_bench [--quick] [--out <path>]
##
## TODO(RP7): fold this into the shared provider-runtime bench suite + wire the
## 20%-regression gh-pages gate per continuous-benchmarking.md.

import std/[json, os, strutils, tables, times]

import repro_interface_artifacts
import repro_provider_runtime
import repro_project_dsl
import repro_core
import repro_hash

const providerBody = """
import repro_project_dsl

package rp2benchwidget:
  build:
    discard
"""

const ProviderGraphRequestTypeId = "reprobuild.provider-graph-request.v1"

proc rpBytesToStr(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc rpStrToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc rpMarshalRequest(box: ExtensionBox): string {.nimcall.} =
  rpBytesToStr(encodeProviderRequest(
    TypedExtensionBox[ProviderGraphRequest](box).val))

proc rpUnmarshalRequest(jsonStr: string): ExtensionBox {.nimcall.} =
  TypedExtensionBox[ProviderGraphRequest](
    typeId: ProviderGraphRequestTypeId,
    val: decodeProviderRequest(rpStrToBytes(jsonStr)))

proc registerRp2RequestCodec() =
  extensionRegistry[ProviderGraphRequestTypeId] = ExtensionMarshaler(
    marshal: rpMarshalRequest, unmarshal: rpUnmarshalRequest)

registerRp2RequestCodec()

proc marshalRequest(request: ProviderGraphRequest): BoxedValue =
  BoxedValue(typeId: ProviderGraphRequestTypeId,
    jsonStr: extensionRegistry[ProviderGraphRequestTypeId].marshal(
      TypedExtensionBox[ProviderGraphRequest](
        typeId: ProviderGraphRequestTypeId, val: request)))

proc elapsedMs(start: float): float =
  (epochTime() - start) * 1000.0

proc main() =
  var quick = false
  var outPath = "bench-results/rp2-provider-session.json"
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    case params[i]
    of "--quick":
      quick = true
    of "--out":
      if i + 1 < params.len:
        outPath = params[i + 1]
        inc i
    else:
      discard
    inc i

  let workDir = getCurrentDir()
  let scratch = getTempDir() / "rp2-bench-" & $getCurrentProcessId() & "-" &
    $int(epochTime())
  removeDir(extendedPath(scratch))
  let projectRoot = scratch / "project"
  let outDir = scratch / "out"
  createDir(extendedPath(outDir))
  createDir(extendedPath(projectRoot))
  defer: removeDir(extendedPath(scratch))

  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)

  let interfacePath = outDir / "rp2-bench-interface.rbsz"
  let stubPath = outDir / "rp2-bench-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    workDir)
  let binPath = outDir / "rp2-bench-provider"
  let compilePath = outDir / "rp2-bench-provider-compile.rbsz"
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, workDir)
  if not fileExists(extendedPath(compiled.outputBinaryPath)):
    quit("rp2 bench: provider binary was not materialized", 1)
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, workDir)
  let providerArtifactIdHex = toHex(plan.providerArtifactId.bytes)

  let request = ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: providerArtifactIdHex,
    entryPointId: "rp2benchwidget.root",
    entryPointBodyHash: "rp2benchwidget.build.v1",
    reason: girColdStart,
    arguments: projectRoot,
    namespace: "rp2benchwidget",
    lockSliceId: "rp2-bench-lock",
    activity: "default")
  let hello = EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp2-bench"],
    lockSliceId: "rp2-bench-lock",
    canonicalExecutionRoot: workDir)
  let artifactRef = ProviderArtifactRef(
    binaryPath: compiled.outputBinaryPath,
    providerArtifactId: providerArtifactIdHex,
    workingDir: workDir)

  # COLD: launch + handshake + first invoke.
  let pool = newProviderSessionPool()
  let coldStart = epochTime()
  let handle = pool.openProviderSession(artifactRef, defaultSessionPolicy(),
    hello)
  discard handle.invokeEntryPoint("rp2benchwidget.root",
    @[marshalRequest(request)])
  let coldMs = elapsedMs(coldStart)

  # WARM: invoke over the reused session (median of a small batch).
  let warmRuns = if quick: 5 else: 25
  var warmTotal = 0.0
  for _ in 0 ..< warmRuns:
    let warmStart = epochTime()
    discard handle.invokeEntryPoint("rp2benchwidget.root",
      @[marshalRequest(request)])
    warmTotal += elapsedMs(warmStart)
  let warmMs = warmTotal / float(warmRuns)
  pool.closeAll()

  let doc = %*{
    "schema": "reprobuild.rp2-provider-session-bench.v1",
    "metadata": {
      "quick": quick,
      "project": "rp2benchwidget",
      "warmRuns": warmRuns,
      "providerArtifactId": providerArtifactIdHex
    },
    "metrics": [
      {
        "suite": "rp2",
        "name": "provider session round-trip (cold: launch+handshake+invoke)",
        "unit": "ms",
        "value": coldMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "rp2",
        "name": "provider session round-trip (warm: reused session invoke)",
        "unit": "ms",
        "value": warmMs,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "rp2 provider-session cold: ", coldMs.formatFloat(ffDecimal, 3),
    " ms; warm: ", warmMs.formatFloat(ffDecimal, 3), " ms"

main()
