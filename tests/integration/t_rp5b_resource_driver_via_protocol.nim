## RP5b (Project-Provider-Runtime-Protocol.milestones.org) — the resource
## driver ops executed OVER THE PROTOCOL (Provider-Runtime-Protocol-v1.md §5).
##
## The engine reconciles a desired ``ResourceInstance`` whose driver lives in a
## SEPARATE provider binary: ``observe`` / ``digest`` / ``apply`` are protocol
## ``InvokeEntryPoint``s on a launched provider session (RP2/RP3), NOT
## in-process ``driver.*`` calls. Proven non-vacuously:
##
##   1. The provider's driver mutates a FAKE WORLD that lives in the provider
##      PROCESS's state — a file the driver writes, stamped with the WRITER's
##      process id. The engine reconciles a desired instance and the file is
##      created; a second reconcile is a no-op (the provider's ``observe`` sees
##      the file it already wrote). The engine process NEVER links the driver
##      body (it is compiled only into the provider binary), so:
##   2. NON-VACUITY: the pid stamped in the fake-world file is the PROVIDER
##      child's pid, DISTINCT from the engine (test) process pid — the op
##      genuinely ran in the provider, not in-process. The engine has NO
##      resource provider registered for the type (asserted), so an in-process
##      reconcile would hard-error; only the protocol path can converge it.
##
## The provider is compiled by the RP1 edge exactly as ``t_rp2_...`` does.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources

# The engine side must be able to marshal the desired instance's attrs box, so
# it registers ONLY the attrs record marshaller (a plain record + JSON — no
# driver closure). This is the RP5a "consumer has the contract, not the impl"
# boundary made concrete: the engine holds the attrs codec; the DRIVER (the
# fake-world mutation) lives solely in the provider binary.
type
  FileWorldAttrs = object
    path*: string
    value*: string

# ---------------------------------------------------------------------------
# The provider source. It declares a resource type ``rp5b.fileworld`` whose
# driver's fake world is an on-disk FILE: ``apply`` writes "<pid>\n<value>" and
# ``observe`` reads it back. Because the file records the WRITER's pid, the
# test can prove the op ran in the provider child, not the engine.
# ---------------------------------------------------------------------------

const providerBody = """
import std/[options, os, strutils, tables]
import repro_project_dsl
import repro_resources

type
  FileWorldAttrs = object
    path*: string
    value*: string

proc fwIdentity(inst: ResourceInstance): string {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  "fileworld:" & a.path

proc fwDigest(inst: ResourceInstance): Digest256 {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  digestString(inst.address & "\x00" & a.value)

proc fwObserve(inst: ResourceInstance;
               recorded: Option[ResourceBinding]): ObservedState {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  if fileExists(a.path):
    let contents = readFile(a.path)
    # The realized value is the SECOND line; the first is the writer pid.
    let lines = contents.split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString(inst.address & "\x00" & realized)
  else:
    result.present = false

proc fwApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  # Stamp the WRITER (provider child) process id so the engine can prove the
  # apply ran here, not in-process.
  writeFile(a.path, $getCurrentProcessId() & "\n" & a.value)
  result = ResourceBinding(
    address: inst.address,
    typeId: inst.typeId,
    resourceId: fwIdentity(inst),
    postWriteDigest: fwDigest(inst),
    present: true)

let fileWorldDriver = ResourceProviderDriver(
  identity: fwIdentity,
  digest: fwDigest,
  observe: fwObserve,
  apply: fwApply)

resourceType "rp5b.fileworld":
  attrs: FileWorldAttrs
  wrapper: fileWorld
  determinism: rdVolatile
  driver: fileWorldDriver
  attr path: string
  attr value: string

package rp5bprov:
  build:
    discard
"""

proc writeProject(root: string): string =
  createDir(extendedPath(root))
  let modulePath = root / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)
  modulePath

proc buildProvider(tempRoot: string): tuple[binary, artifactId, projectRoot: string] =
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  createDir(extendedPath(outDir))
  let modulePath = writeProject(projectRoot)
  let interfacePath = outDir / "rp5b-interface.rbsz"
  let stubPath = outDir / "rp5b-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "rp5b-provider"
  let compilePath = outDir / "rp5b-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes),
   projectRoot: projectRoot)

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["rp5b"],
    lockSliceId: "rp5b-lock",
    canonicalExecutionRoot: getCurrentDir())

# The engine holds ONLY the attrs marshaller — never the driver.
registerExtension[FileWorldAttrs]("rp5b.fileworld")

proc desiredInstance(worldPath, value: string): ResourceInstance =
  ResourceInstance(
    typeId: "rp5b.fileworld",
    address: "world",
    attrs: TypedExtensionBox[FileWorldAttrs](
      typeId: "rp5b.fileworld",
      val: FileWorldAttrs(path: worldPath, value: value)),
    dependsOn: @[],
    determinism: rdVolatile)

suite "RP5b: resource driver ops execute over the provider session":

  test "reconcile drives observe->apply over the wire; provider mutates the fake world":
    let tempRoot = getTempDir() / "rp5b-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))
    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))

    # NON-VACUITY (a): the engine process has NO driver registered for the
    # type — an in-process ``reconcileResources`` would hard-error, so only the
    # protocol path can converge this instance.
    check not isResourceProviderRegistered("rp5b.fileworld")

    let worldPath = tempRoot / "fake-world.txt"
    check not fileExists(extendedPath(worldPath))

    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    let artifact = ProviderArtifactRef(
      binaryPath: provider.binary,
      providerArtifactId: provider.artifactId,
      workingDir: getCurrentDir())
    let handle = pool.openProviderSession(artifact, defaultSessionPolicy(),
      engineHello())

    # The resolver hands the reconciler the single launched session for the
    # type (in a real engine this is keyed by ProviderArtifactId and reused).
    let resolve: ResourceSessionResolver = proc (typeId: string): ProviderHandle =
      handle

    # ── FIRST reconcile: create ────────────────────────────────────────────
    let inst = desiredInstance(extendedPath(worldPath), "hello")
    let first = reconcileResourcesViaSession(@[inst], resolve)
    check first.actions.len == 1
    check first.actions[0].kind == rakCreate
    check first.bindings.len == 1

    # The fake world was mutated — BY THE PROVIDER CHILD.
    check fileExists(extendedPath(worldPath))
    let contents = readFile(extendedPath(worldPath))
    let lines = contents.split('\n')
    check lines.len >= 2
    let writerPid = parseInt(lines[0])
    check lines[1] == "hello"

    # NON-VACUITY (b): the writer pid is the PROVIDER child's, NOT the engine.
    check writerPid != int(getCurrentProcessId())

    # ── SECOND reconcile: no-op (provider observe sees its own write) ───────
    let second = reconcileResourcesViaSession(@[inst], resolve,
      recorded = first.bindings)
    check second.actions.len == 1
    check second.actions[0].kind == rakNoOp
    # The fake-world file is unchanged (same pid stamp, same value).
    check readFile(extendedPath(worldPath)) == contents

    # ── CHANGED value: drives an update over the wire ──────────────────────
    let inst2 = desiredInstance(extendedPath(worldPath), "changed")
    let third = reconcileResourcesViaSession(@[inst2], resolve,
      recorded = second.bindings)
    check third.actions.len == 1
    check third.actions[0].kind == rakUpdate
    let updated = readFile(extendedPath(worldPath)).split('\n')
    check updated[1] == "changed"
