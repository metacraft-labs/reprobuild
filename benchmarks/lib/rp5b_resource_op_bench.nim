## RP5b (Project-Provider-Runtime-Protocol) — resource-op round-trip latency
## benchmark harness.
##
## Establishes the ``customSmallerIsBetter`` resource-op round-trip metric the
## RP5b milestone names: the cost of running a resource driver op
## (``<typeId>.observe`` / ``<typeId>.apply``) as a protocol
## ``InvokeEntryPoint`` on a launched provider session. WARM = an op over an
## already-launched, reused session; COLD = launch child +
## EngineHello/ProviderManifest handshake + the first op. Mirrors the RP1/RP2
## harness JSON shape so ``scripts/collect-benchmark-metrics.sh``'s
## ``rp1``-kind parser consumes the ``rp5b`` suite unchanged.
##
## The provider binary is materialized once via the RP1 edge
## (``compileProviderBinary``); the compile time is NOT part of the measured
## op metric (RP1 owns that). The resource type served is a reprobuild-local
## ``rp5b_bench.thing`` whose driver mutates an in-memory fake world in the
## provider process — the same shape the RP5b gate test proves non-vacuously.
##
## Usage:
##   rp5b_resource_op_bench [--quick] [--out <path>]
##
## TODO(RP7): fold this into the shared provider-runtime bench suite + wire the
## 20%-regression gh-pages gate per continuous-benchmarking.md.

import std/[json, options, os, strutils, times]

import repro_interface_artifacts
import repro_provider_runtime
import repro_project_dsl
import repro_resources
import repro_core
import repro_hash

const providerBody = """
import std/[options, tables]
import repro_project_dsl
import repro_resources

type
  BenchAttrs = object
    value*: string

var world {.threadvar.}: Table[string, string]

proc bIdentity(inst: ResourceInstance): string {.nimcall.} =
  "bench:" & inst.address

proc bDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[BenchAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & a.value)

proc bObserve(inst: ResourceInstance;
              recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let id = bIdentity(inst)
  if world.hasKey(id):
    result.present = true
    result.digest = digestString(inst.address & "\x00" & world[id])
  else:
    result.present = false

proc bApply(inst: ResourceInstance; action: ResourceActionKind;
            observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[BenchAttrs](inst.attrs).val
  world[bIdentity(inst)] = a.value
  result = ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: bIdentity(inst), postWriteDigest: bDigest(inst), present: true)

let benchDriver = ResourceProviderDriver(
  identity: bIdentity, digest: bDigest, observe: bObserve, apply: bApply)

resourceType "rp5b_bench.thing":
  attrs: BenchAttrs
  wrapper: benchThing
  determinism: rdVolatile
  driver: benchDriver
  attr value: string

package rp5bbench:
  build:
    discard
"""

type
  BenchAttrs = object
    value*: string

proc elapsedMs(start: float): float =
  (epochTime() - start) * 1000.0

proc benchInstance(value: string): ResourceInstance =
  ResourceInstance(
    typeId: "rp5b_bench.thing",
    address: "thing",
    attrs: TypedExtensionBox[BenchAttrs](
      typeId: "rp5b_bench.thing", val: BenchAttrs(value: value)),
    dependsOn: @[],
    determinism: rdVolatile)

proc main() =
  var quick = false
  var outPath = "bench-results/rp5b-resource-op.json"
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

  let workDir = getCurrentDir()
  let scratch = getTempDir() / "rp5b-bench-" & $getCurrentProcessId() & "-" &
    $int(epochTime())
  removeDir(extendedPath(scratch))
  let projectRoot = scratch / "project"
  let outDir = scratch / "out"
  createDir(extendedPath(outDir))
  createDir(extendedPath(projectRoot))
  defer: removeDir(extendedPath(scratch))

  let modulePath = projectRoot / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)

  let interfacePath = outDir / "rp5b-bench-interface.rbsz"
  let stubPath = outDir / "rp5b-bench-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath, stubPath,
    workDir)
  let binPath = outDir / "rp5b-bench-provider"
  let compilePath = outDir / "rp5b-bench-provider-compile.rbsz"
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, workDir)
  if not fileExists(extendedPath(compiled.outputBinaryPath)):
    quit("rp5b bench: provider binary was not materialized", 1)
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, workDir)
  let providerArtifactIdHex = toHex(plan.providerArtifactId.bytes)

  # The engine side needs only the attrs marshaller (no driver closure).
  registerExtension[BenchAttrs]("rp5b_bench.thing")
  registerResourceProtocolCodecs()

  let hello = EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp5b-bench"],
    lockSliceId: "rp5b-bench-lock",
    canonicalExecutionRoot: workDir)
  let artifactRef = ProviderArtifactRef(
    binaryPath: compiled.outputBinaryPath,
    providerArtifactId: providerArtifactIdHex,
    workingDir: workDir)

  let inst = benchInstance("bench-value")

  # COLD: launch + handshake + first resource op (observe).
  let pool = newProviderSessionPool()
  let coldStart = epochTime()
  let handle = pool.openProviderSession(artifactRef, defaultSessionPolicy(),
    hello)
  discard observeViaSession(handle, inst, none(ResourceBinding))
  let coldMs = elapsedMs(coldStart)

  # WARM: observe+apply round-trips over the reused session.
  let warmRuns = if quick: 5 else: 25
  var warmTotal = 0.0
  for _ in 0 ..< warmRuns:
    let warmStart = epochTime()
    let obs = observeViaSession(handle, inst, none(ResourceBinding))
    discard applyViaSession(handle, inst, rakCreate, obs)
    warmTotal += elapsedMs(warmStart)
  let warmMs = warmTotal / float(warmRuns)
  pool.closeAll()

  let doc = %*{
    "schema": "reprobuild.rp5b-resource-op-bench.v1",
    "metadata": {
      "quick": quick,
      "project": "rp5bbench",
      "warmRuns": warmRuns,
      "providerArtifactId": providerArtifactIdHex
    },
    "metrics": [
      {
        "suite": "rp5b",
        "name": "resource op round-trip (cold: launch+handshake+observe)",
        "unit": "ms",
        "value": coldMs,
        "direction": "lower-is-better",
        "status": "measured"
      },
      {
        "suite": "rp5b",
        "name": "resource op round-trip (warm: reused session observe+apply)",
        "unit": "ms",
        "value": warmMs,
        "direction": "lower-is-better",
        "status": "measured"
      }
    ]
  }

  createDir(extendedPath(parentDir(outPath)))
  writeFile(extendedPath(outPath), pretty(doc))
  echo "rp5b resource-op cold: ", coldMs.formatFloat(ffDecimal, 3),
    " ms; warm: ", warmMs.formatFloat(ffDecimal, 3), " ms"

main()
