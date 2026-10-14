## Ephemeral-State-Leases.md §4.5 — a reap over the PROVIDER SESSION needs no
## attrs codec in the reaping process.
##
## §4.2 gives the daemon a provider-session destroy transport precisely so it
## can tear down an out-of-tree provider's resources "WITHOUT linking it into
## the daemon", and declares the persisted `typeId` + attrs transport-agnostic.
## They were not: `reapRecord` reconstructed through the STRICT attrs codec
## before it chose a transport, so a process holding a provider artifact but
## NOT that provider's attrs codec — the configuration §4.2 describes — could
## not reap over the session it had. This case is that configuration, end to
## end, against a real launched provider.
##
## WHAT THIS IS NOT. It is not a reproduction of
## reprobuild-pm/issues/2026-09-29-lease-reap-tick-has-never-once-succeeded.md.
## The daemon in that record swept on the IN-PROCESS transport for all 131,882
## ticks, because `buildLeaseReapTransport` falls back to it when no provider
## artifact is registered and nothing in the shipped tree registers one
## (reprobuild-pm/issues/2026-10-14-no-production-path-enables-the-daemons-session-reap-transport.md).
## Its `vm_harness.nic` record had neither a linked driver nor a linked codec
## there, so no change to the reconstruction could have reaped it. What this
## case pins is the second, independent defect that would have produced the
## identical symptom in a daemon that DID have the artifact — and the
## in-process control below asserts that the strict arm still refuses, so the
## two are not confused here either.
##
## THE SETUP IS A REAL DAEMON CONFIGURATION, not a mock of one. The record on
## disk was written by a process that had the codec; the process that sweeps it
## does not have the codec, has no driver for the type, and reaches the
## provider only by launching its binary. We reproduce that exactly:
##
##   1. a REAL provider binary is compiled from a recipe (the RP1 interface
##      extraction + provider compile, as `t_rp5b_resource_driver_via_protocol`
##      does), owning `reapsess.fileworld`, whose driver's fake world is an
##      on-disk FILE;
##   2. the engine registers the attrs codec, materializes the resource OVER THE
##      SESSION into a real state store, and backdates the record's lease so it
##      is reapable;
##   3. the engine then DROPS the codec from its registry
##      (`extensionRegistry.del`). Nothing else changes. From here the test
##      process is the daemon: record on disk, provider binary reachable, codec
##      absent;
##   4. `reapOnce` over the `rtSession` transport must destroy it.
##
## NON-VACUITY, four ways — this case must be incapable of passing by accident:
##
##   (a) the engine has NO resource provider registered for the type, so an
##       in-process reap could not have done this;
##   (b) the engine has NO attrs codec for the type at reap time, so the strict
##       reconstruction would raise (and did, before the fix — asserted here by
##       running the same sweep over the in-process transport and watching it
##       fail for exactly that reason);
##   (c) the destroy left a WITNESS stamped with the writer's process id, and
##       that pid is the provider CHILD's, not this process's;
##   (d) the fake world really existed before the reap (so the destroy is a real
##       destroy, not an already-absent no-op that removes the record anyway).
##
## Skip rule: none. The provider build is the test.

import std/[options, os, strutils, tables, times, unittest]

import repro_interface_artifacts
import repro_provider_runtime
import repro_core
import repro_hash
import repro_project_dsl
import repro_resources

const ReapTypeId = "reapsess.fileworld"

# The engine side needs the attrs codec only to WRITE the record in step 2 —
# exactly as the process that materialized the live `vm_harness.nic` record did.
# It is dropped again before the reap, which is the state under test.
type
  FileWorldAttrs = object
    path*: string
    value*: string

# ---------------------------------------------------------------------------
# The provider source. `reapsess.fileworld`'s fake world is a FILE:
#
#   * `apply(create/update)` writes "<pid>\n<value>";
#   * `apply(rakDestroy)`    writes "<pid>" to "<path>.destroyed-by" and then
#     REMOVES the world file. The witness file is what proves the destroy ran
#     in the provider child rather than here — a mere absence could also be
#     produced by never having created it.
#   * `observe` reports present iff the world file exists.
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
    let lines = contents.split('\n')
    let realized = if lines.len >= 2: lines[1] else: ""
    result.present = true
    result.digest = digestString(inst.address & "\x00" & realized)
  else:
    result.present = false

proc fwApply(inst: ResourceInstance; action: ResourceActionKind;
             observed: ObservedState): ResourceBinding {.nimcall.} =
  let a = TypedExtensionBox[FileWorldAttrs](inst.attrs).val
  case action
  of rakDestroy:
    # The witness: who actually performed the destroy. Written BEFORE the
    # removal so a crash between the two cannot make the destroy look local.
    writeFile(a.path & ".destroyed-by", $getCurrentProcessId())
    if fileExists(a.path):
      removeFile(a.path)
    result = ResourceBinding(
      address: inst.address,
      typeId: inst.typeId,
      resourceId: fwIdentity(inst),
      present: false)
  else:
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

resourceType "reapsess.fileworld":
  attrs: FileWorldAttrs
  wrapper: fileWorld
  determinism: rdVolatile
  driver: fileWorldDriver
  attr path: string
  attr value: string

package reapsessprov:
  build:
    discard
"""

proc writeProject(root: string): string =
  createDir(extendedPath(root))
  let modulePath = root / "reprobuild.nim"
  writeFile(extendedPath(modulePath), providerBody)
  modulePath

proc buildProvider(tempRoot: string): tuple[binary, artifactId: string] =
  ## Compile the provider the way the engine does: extract its lifted interface
  ## (RP1), then compile the provider binary against that fingerprint.
  let projectRoot = tempRoot / "project"
  let outDir = tempRoot / "out"
  createDir(extendedPath(outDir))
  let modulePath = writeProject(projectRoot)
  let interfacePath = outDir / "reapsess-interface.rbsz"
  let stubPath = outDir / "reapsess-interface.nim"
  let artifact = extractInterfaceFromModule(modulePath, interfacePath,
    stubPath, getCurrentDir())
  let binPath = outDir / "reapsess-provider"
  let compilePath = outDir / "reapsess-provider-compile.rbsz"
  let plan = providerCompilePlan(modulePath, binPath,
    artifact.interfaceFingerprint, getCurrentDir())
  let compiled = compileProviderBinary(modulePath, binPath,
    artifact.interfaceFingerprint, compilePath, getCurrentDir())
  (binary: compiled.outputBinaryPath,
   artifactId: toHex(plan.providerArtifactId.bytes))

proc engineHello(): EngineHello =
  EngineHello(
    protocolVersion: ProviderProtocolVersion,
    engineCapabilities: @["ephemeral-state-lease-reaper"],
    lockSliceId: "lease-reaper",
    canonicalExecutionRoot: getCurrentDir())

proc desiredInstance(worldPath, value: string): ResourceInstance =
  ResourceInstance(
    typeId: ReapTypeId,
    address: "world",
    attrs: TypedExtensionBox[FileWorldAttrs](
      typeId: ReapTypeId,
      val: FileWorldAttrs(path: worldPath, value: value)),
    dependsOn: @[],
    determinism: rdVolatile)

suite "lease reap destroys an unlinked type over a provider session":

  test "a session reap needs no attrs codec in the reaping process":
    let tempRoot = getTempDir() / "reapsess-" & $getCurrentProcessId()
    removeDir(extendedPath(tempRoot))
    defer: removeDir(extendedPath(tempRoot))

    let provider = buildProvider(tempRoot)
    check fileExists(extendedPath(provider.binary))

    let pool = newProviderSessionPool()
    defer: pool.closeAll()
    let artifact = ProviderArtifactRef(
      binaryPath: provider.binary,
      providerArtifactId: provider.artifactId,
      workingDir: getCurrentDir())
    let handle = pool.openProviderSession(artifact, defaultSessionPolicy(),
      engineHello())
    let resolve = proc (typeId: string): ProviderHandle = handle

    let worldPath = extendedPath(tempRoot / "fake-world.txt")
    let witnessPath = worldPath & ".destroyed-by"
    let storeRoot = tempRoot / "state"
    let store = openStateStore(storeRoot)

    # ── Step 2: materialize over the session, WITH the codec present. ──────
    # The engine holds only the attrs codec, never the driver — the RP5a
    # "consumer has the contract, not the impl" boundary. This is the process
    # that wrote the live `vm_harness.nic` record.
    registerExtension[FileWorldAttrs](ReapTypeId)
    check extensionRegistry.contains(ReapTypeId)
    let inst = desiredInstance(worldPath, "up")
    let materialized = reconcileResourcesViaSession(@[inst], resolve,
      store = some(store))
    check materialized.actions.len == 1
    check materialized.actions[0].kind == rakCreate
    # NON-VACUITY (d): the fake world really exists, so the reap below has
    # something to destroy and cannot pass as an already-absent no-op.
    check fileExists(worldPath)
    check not fileExists(witnessPath)
    check hasStateRecord(store, "world")

    # Backdate the lease so the record is reapable. Read-modify-write through
    # the record itself: no codec is needed to move a deadline, which is also
    # why a daemon can select a record it cannot reconstruct — selection never
    # unmarshals, which is exactly why the live daemon's sweep got as far as
    # the first destroy and no further.
    let past = getTime() - initDuration(hours = 1)
    var rec = readStateRecord(store, "world")
    rec.effectiveDeadline = some(past)
    rec.lastRenewed = past
    rec.holders = initTable[string, Time]()
    writeStateRecord(store, rec)
    # The persisted attrs are the provider's own type, under its own typeId.
    check rec.attrsTypeId == ReapTypeId
    check rec.attrsJson.len > 0

    # ── Step 3: become the daemon — drop the codec. ────────────────────────
    extensionRegistry.del(ReapTypeId)
    # NON-VACUITY (a) + (b): no driver, and now no codec either.
    check not isResourceProviderRegistered(ReapTypeId)
    check not extensionRegistry.contains(ReapTypeId)

    # The in-process transport MUST still refuse — this is the control that
    # proves (b) is a live condition and not a formality, and it pins that the
    # strict arm was not loosened to buy the session arm. It is also the arm
    # the live daemon actually swept on, which is why this case does not claim
    # its outage: here the session is reachable, and there it was not.
    let inProcessAttempt = reapOnce(store, past + initDuration(minutes = 1),
      inProcessTransport())
    check inProcessAttempt.reaped.len == 0
    check inProcessAttempt.failed.len == 1
    check inProcessAttempt.failed[0].reason.contains("marshaller")
    # ...and it destroyed nothing on the way to refusing.
    check fileExists(worldPath)
    check not fileExists(witnessPath)
    check hasStateRecord(store, "world")

    # ── Step 4: the session reap. ─────────────────────────────────────────
    let report = reapOnce(store, past + initDuration(minutes = 1),
      sessionTransport(resolve))
    check report.failed.len == 0
    check report.reaped.len == 1
    check report.reaped[0].address == "world"
    check report.reaped[0].typeId == ReapTypeId
    # `wasPresent` distinguishes a real destroy from the already-absent no-op.
    check report.reaped[0].wasPresent

    # The world is torn down and the record removed.
    check not fileExists(worldPath)
    check not hasStateRecord(store, "world")

    # NON-VACUITY (c): the destroy ran in the PROVIDER CHILD. The witness
    # exists and names a pid that is not this process's.
    check fileExists(witnessPath)
    let destroyer = parseInt(readFile(witnessPath).strip())
    check destroyer != int(getCurrentProcessId())
