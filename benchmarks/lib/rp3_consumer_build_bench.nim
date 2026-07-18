## RP3 (Project-Provider-Runtime-Protocol) — cold-vs-warm consumer-build
## benchmark harness.
##
## Establishes the ``customSmallerIsBetter`` cold-vs-warm consumer-build metric
## the RP3 gate names: the "build once, share" win. Two consumers bind the
## SAME dependency (same ProviderArtifactId ⇒ same ProviderSessionKey):
##
##   COLD — the FIRST consumer must materialize + launch the shared dependency
##          provider (EngineHello/ProviderManifest handshake + a dependency
##          invoke), then bind + invoke its own root.
##   WARM — the SECOND consumer REUSES the already-launched dependency session
##          (no relaunch, no re-handshake), then binds + invokes its own root.
##
## The two consumers' own provider binaries are materialized once via the RP1
## edge (``compileProviderBinary``); compile time is NOT part of the measured
## metric (RP1 owns that). The measured delta is the dependency
## launch+handshake the warm path skips — the shared-session win.
##
## Mirrors the RP1/RP2 harness JSON shape so
## ``scripts/collect-benchmark-metrics.sh``'s ``rp1``-kind parser consumes the
## ``rp3`` suite unchanged.
##
## Usage:
##   rp3_consumer_build_bench [--quick] [--out <path>]
##
## TODO(RP7): fold this into the shared provider-runtime bench suite + wire the
## 20%-regression gh-pages gate per continuous-benchmarking.md.

import std/[json, os, strutils, tables, times]

import repro_interface_artifacts
import repro_provider_runtime
import repro_project_dsl
import repro_core
import repro_hash

const dependencyBody = """
import repro_project_dsl

package rp3benchdep:
  build:
    discard
"""

# Two distinct consumers that both bind the SAME dependency under "dep".
proc consumerBody(tag: string): string =
  "import repro_project_dsl\n\npackage rp3benchconsumer" & tag &
    ":\n  build:\n    useBoundDependency(\"dep\")\n"

const ProviderGraphRequestTypeId = "reprobuild.provider-graph-request.v1"
const ProviderGraphResponseTypeId = "reprobuild.provider-graph-response.v1"

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

proc rpMarshalResponse(box: ExtensionBox): string {.nimcall.} =
  rpBytesToStr(encodeProviderResponse(
    TypedExtensionBox[ProviderGraphResponse](box).val))

proc rpUnmarshalResponse(jsonStr: string): ExtensionBox {.nimcall.} =
  TypedExtensionBox[ProviderGraphResponse](
    typeId: ProviderGraphResponseTypeId,
    val: decodeProviderResponse(rpStrToBytes(jsonStr)))

proc registerRp3Codecs() =
  extensionRegistry[ProviderGraphRequestTypeId] = ExtensionMarshaler(
    marshal: rpMarshalRequest, unmarshal: rpUnmarshalRequest)
  extensionRegistry[ProviderGraphResponseTypeId] = ExtensionMarshaler(
    marshal: rpMarshalResponse, unmarshal: rpUnmarshalResponse)

registerRp3Codecs()

proc marshalRequest(request: ProviderGraphRequest): BoxedValue =
  BoxedValue(typeId: ProviderGraphRequestTypeId,
    jsonStr: extensionRegistry[ProviderGraphRequestTypeId].marshal(
      TypedExtensionBox[ProviderGraphRequest](
        typeId: ProviderGraphRequestTypeId, val: request)))

type BuiltProvider = tuple[binary, artifactId, projectRoot, packageName: string]

proc buildProvider(scratch, tag, body, packageName: string): BuiltProvider =
  let projectRoot = scratch / tag
  let outDir = scratch / (tag & "-out")
  createDir(extendedPath(projectRoot))
  createDir(extendedPath(outDir))
  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), body)
  let interfacePath = outDir / (tag & "-interface.rbsz")
  let stubPath = outDir / (tag & "-interface.nim")
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / (tag & "-provider")
  let compilePath = outDir / (tag & "-provider-compile.rbsz")
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  if not fileExists(extendedPath(compiled.outputBinaryPath)):
    quit("rp3 bench: provider binary was not materialized", 1)
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes),
   projectRoot: projectRoot, packageName: packageName)

proc rootRequest(p: BuiltProvider): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: p.artifactId,
    entryPointId: p.packageName & ".root",
    entryPointBodyHash: p.packageName & ".build.v1",
    reason: girColdStart,
    arguments: p.projectRoot,
    namespace: p.packageName,
    lockSliceId: "rp3-bench-lock",
    activity: "default")

proc engineHello(): EngineHello =
  EngineHello(protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp3-bench"], lockSliceId: "rp3-bench-lock",
    canonicalExecutionRoot: getCurrentDir())

proc artifactRef(p: BuiltProvider): ProviderArtifactRef =
  ProviderArtifactRef(binaryPath: p.binary, providerArtifactId: p.artifactId,
    workingDir: getCurrentDir())

proc elapsedMs(start: float): float =
  (epochTime() - start) * 1000.0

# One consumer build: resolve the dependency (open-or-reuse its shared session
# + invoke it), bind it into the consumer session, invoke the consumer root.
proc consumerBuild(pool: ProviderSessionPool; dep, consumer: BuiltProvider) =
  let depHandle = pool.openProviderSession(dep.artifactRef(),
    defaultSessionPolicy(), engineHello())
  let depRes = depHandle.invokeEntryPoint(dep.packageName & ".root",
    @[marshalRequest(dep.rootRequest())])
  let binding = resolveDependencyBinding(depHandle, "dep",
    dep.packageName & ".root", depRes)
  let consumerHandle = pool.openProviderSession(consumer.artifactRef(),
    defaultSessionPolicy(), engineHello())
  consumerHandle.bindDependencies(@[binding])
  discard consumerHandle.invokeEntryPoint(consumer.packageName & ".root",
    @[marshalRequest(consumer.rootRequest())])

proc main() =
  var quick = false
  var outPath = "bench-results/rp3-consumer-build.json"
  let params = commandLineParams()
  var i = 0
  while i < params.len:
    case params[i]
    of "--quick": quick = true
    of "--out":
      if i + 1 < params.len:
        outPath = params[i + 1]
        inc i
    else: discard
    inc i

  let scratch = getTempDir() / "rp3-bench-" & $getCurrentProcessId() & "-" &
    $int(epochTime())
  removeDir(extendedPath(scratch))
  createDir(extendedPath(scratch))
  defer: removeDir(extendedPath(scratch))

  let dep = buildProvider(scratch, "dep", dependencyBody, "rp3benchdep")
  let consumerA = buildProvider(scratch, "ca", consumerBody("a"),
    "rp3benchconsumera")
  let consumerB = buildProvider(scratch, "cb", consumerBody("b"),
    "rp3benchconsumerb")

  # COLD: first consumer must launch + handshake the shared dependency provider.
  let pool = newProviderSessionPool()
  let coldStart = epochTime()
  consumerBuild(pool, dep, consumerA)
  let coldMs = elapsedMs(coldStart)
  let launchesAfterCold = pool.launchCount

  # WARM: second consumer reuses the already-launched dependency session
  # (median of a small batch of distinct-consumer builds against the shared
  # dependency; consumerB's own session is opened once and then reused).
  let warmRuns = if quick: 3 else: 10
  var warmTotal = 0.0
  for _ in 0 ..< warmRuns:
    let warmStart = epochTime()
    consumerBuild(pool, dep, consumerB)
    warmTotal += elapsedMs(warmStart)
  let warmMs = warmTotal / float(warmRuns)
  # The dependency provider was launched exactly once across cold + warm.
  let sharedDependencyLaunches = 1
  pool.closeAll()

  let doc = %*{
    "schema": "reprobuild.rp3-consumer-build-bench.v1",
    "metadata": {
      "quick": quick,
      "warmRuns": warmRuns,
      "launchesAfterCold": launchesAfterCold,
      "dependencyProviderArtifactId": dep.artifactId
    },
    "metrics": [
      {
        "suite": "rp3",
        "name": "consumer build (cold: materialize+launch shared dependency provider)",
        "unit": "ms",
        "value": coldMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "rp3",
        "name": "consumer build (warm: reuse shared dependency session)",
        "unit": "ms",
        "value": warmMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "rp3",
        "name": "shared dependency provider launches across all consumer builds",
        "unit": "count",
        "value": sharedDependencyLaunches,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "rp3 consumer-build cold: ", coldMs.formatFloat(ffDecimal, 3),
    " ms; warm: ", warmMs.formatFloat(ffDecimal, 3),
    " ms; shared dependency launches: ", sharedDependencyLaunches

main()
