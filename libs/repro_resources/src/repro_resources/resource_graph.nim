## Named-Runnable-Edges N2 — carry the resource-lane graph (the ``stateGroup``
## resource subgraph + its membership) from the recipe-evaluation process (the
## provider child) to the ``repro run`` CLI, so the leased-consumes bridge can
## reconcile a consumed ``stateGroup`` WITHOUT re-evaluating the recipe.
##
## The provider fragment the CLI reads back carries only build-lane nodes; the
## desired resource graph lives only in ``collect.nim``'s in-process
## ``collectedResources()`` while ``buildProc()`` runs. This module supplies:
##
##   * ``encodeResourceGraphPayload`` / ``decodeResourceGraphPayload`` — a
##     framed codec for ``(seq[ResourceInstance], seq[StateGroupDef])``, reusing
##     the RP protocol lane's per-instance codec (``encodeResourceInstance`` —
##     which round-trips typeId / address / attrs / dependsOn / determinism
##     through the shared Typed-Graph-Extensions attrs marshaller). ``consumes``
##     is NOT carried per-instance: the run-edge's own ``consumes`` list
##     (already serialized on its target-export row) is the consumer edge the
##     bridge synthesizes at reconcile time.
##   * ``installResourceGraphHarvestHook`` — registers the encoder onto
##     ``repro_project_dsl``'s harvest hook (called once at module init below)
##     so ``buildPackageFragment`` can emit the resource graph as a
##     ``reprobuild.resource-graph.v1`` ``gnkMetadata`` node without importing
##     ``repro_resources`` (the layering only runs this direction).

import std/options

import repro_core                        # writeString / readString / writeU32Le …
from repro_home_generations/pointer import Digest256
import repro_project_dsl                 # StateGroupDef / setResourceGraphHarvestHook / registeredStateGroups / TypedExtensionBox
import repro_resources/instance
import repro_resources/collect           # collectedResources
import repro_resources/marshal           # (shared attrs marshaller registry via registerExtension)
import repro_resources/protocol          # encodeResourceInstance / decodeResourceInstance / registerResourceProtocolCodecs

# ---------------------------------------------------------------------------
# Named-Runnable-Edges N2 — the synthetic run-edge CONSUMER resource.
#
# The leased-consumes bridge (``reconcileConsumedStateGroups`` in the CLI)
# reconciles a consumed ``stateGroup`` as: the group's member states PLUS one
# synthetic consumer instance whose ``consumes`` targets every member (the run-
# edge's stable name is the holder id). That consumer flows through the SAME
# reconciler as any resource, so it needs a registered provider — but it is a
# pure lease-bookkeeping edge with no real-world side effect. This built-in
# provider is a no-op world: ``observe`` always reports present + a constant
# digest, ``apply`` does nothing. Registered at module init so BOTH the CLI and
# the hermetic bridge tests see it without extra wiring.
# ---------------------------------------------------------------------------

const RunEdgeConsumerTypeId* = "reprobuild.run-edge-consumer.v1"

type
  RunEdgeConsumerAttrs* = object
    ## The synthetic consumer's attrs: which run-edge holds the lease and the
    ## consumed group name. Purely diagnostic — the digest is constant so the
    ## consumer never drives a re-apply.
    runEdge*: string
    group*: string

proc runEdgeConsumerIdentity(inst: ResourceInstance): string =
  "run-edge-consumer:" & inst.address

proc runEdgeConsumerDigest(inst: ResourceInstance): Digest256 =
  digestString("reprobuild.run-edge-consumer\x00" & inst.address)

proc runEdgeConsumerObserve(inst: ResourceInstance;
                            recorded: Option[ResourceBinding]): ObservedState =
  # Report ABSENT until a binding was recorded, so the FIRST reconcile applies
  # (creating the bookkeeping record the reaper skips as never-reap) and later
  # reconciles observe present-at-constant-digest ⇒ a no-op (never a re-apply
  # of anything real). This mirrors the L3 consumer materializing into a record.
  if recorded.isSome and recorded.get.present:
    result.present = true
    result.digest = runEdgeConsumerDigest(inst)
  else:
    result.present = false

proc runEdgeConsumerApply(inst: ResourceInstance; action: ResourceActionKind;
                          observed: ObservedState): ResourceBinding =
  ResourceBinding(
    address: inst.address, typeId: inst.typeId,
    resourceId: runEdgeConsumerIdentity(inst),
    postWriteDigest: runEdgeConsumerDigest(inst),
    present: action != rakDestroy)

proc registerRunEdgeConsumerProvider*() =
  ## Idempotent: register the built-in synthetic-consumer provider + its attrs
  ## marshaller. Safe to call repeatedly (the registries last-writer-win).
  registerResourceProvider(ResourceProviderDef(
    typeId: RunEdgeConsumerTypeId,
    determinism: rdVolatile,
    driver: ResourceProviderDriver(
      identity: runEdgeConsumerIdentity,
      digest: runEdgeConsumerDigest,
      observe: runEdgeConsumerObserve,
      apply: runEdgeConsumerApply)))
  registerExtension[RunEdgeConsumerAttrs](RunEdgeConsumerTypeId)

registerRunEdgeConsumerProvider()

const
  ResourceGraphMagic = "RGPH"
  ResourceGraphVersion = 1'u16

proc encodeResourceGraphPayload*(resources: seq[ResourceInstance];
                                 groups: seq[StateGroupDef]): seq[byte] =
  ## Frame the desired resource graph + state-group membership. The per-
  ## resource body reuses the RP protocol codec, so the receiving side needs
  ## only each attrs typeId's ``registerExtension`` marshaller (never the
  ## driver) to rehydrate.
  registerResourceProtocolCodecs()
  var payload: seq[byte] = @[]
  payload.writeU32Le(uint32(resources.len))
  for inst in resources:
    let enc = encodeResourceInstance(inst)
    payload.writeU32Le(uint32(enc.len))
    payload.add(enc)
  payload.writeU32Le(uint32(groups.len))
  for g in groups:
    payload.writeString(g.name)
    payload.writeU32Le(uint32(g.members.len))
    for m in g.members:
      payload.writeString(m)
    payload.writeString(g.sourceFile)
    payload.writeU32Le(uint32(g.sourceLine))

  result.add(toBytes(ResourceGraphMagic))
  result.writeU16Le(ResourceGraphVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeResourceGraphPayload*(bytes: openArray[byte]):
    tuple[resources: seq[ResourceInstance]; groups: seq[StateGroupDef]] =
  ## Inverse of ``encodeResourceGraphPayload``. Rehydrates each
  ## ``ResourceInstance`` via the RP codec (hard-errors on an attrs typeId
  ## with no registered marshaller — the applying process must link the
  ## provider module) and the state-group membership.
  registerResourceProtocolCodecs()
  if bytes.len < 10:
    raise newException(ValueError, "truncated resource-graph envelope")
  let magic = toBytes(ResourceGraphMagic)
  for i in 0 ..< magic.len:
    if bytes[i] != magic[i]:
      raise newException(ValueError, "unknown resource-graph payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != ResourceGraphVersion:
    raise newException(ValueError, "unsupported resource-graph payload version")
  let payloadLen = int(readU32Le(bytes, pos))
  if pos + payloadLen != bytes.len:
    raise newException(ValueError, "resource-graph payload length mismatch")
  let resCount = int(readU32Le(bytes, pos))
  result.resources = newSeq[ResourceInstance](resCount)
  for i in 0 ..< resCount:
    let encLen = int(readU32Le(bytes, pos))
    result.resources[i] = decodeResourceInstance(bytes[pos ..< pos + encLen])
    pos += encLen
  let groupCount = int(readU32Le(bytes, pos))
  result.groups = newSeq[StateGroupDef](groupCount)
  for i in 0 ..< groupCount:
    var g: StateGroupDef
    g.name = readString(bytes, pos)
    let memberCount = int(readU32Le(bytes, pos))
    g.members = newSeq[string](memberCount)
    for j in 0 ..< memberCount:
      g.members[j] = readString(bytes, pos)
    g.sourceFile = readString(bytes, pos)
    g.sourceLine = int(readU32Le(bytes, pos))
    result.groups[i] = g

proc encodeCollectedResourceGraphPayload*(): string {.gcsafe.} =
  ## The harvest-hook body ``buildPackageFragment`` calls: encode the
  ## resources ``collectedResources()`` gathered during this package's
  ## ``buildProc()`` + the ``registeredStateGroups()`` membership. Returns
  ## ``""`` when the package declared no resources AND no state groups, so a
  ## resource-free package emits no metadata node (pre-N2 byte-identical).
  ##
  ## The desired-resource + state-group registries are plain module globals
  ## assembled single-threaded during DSL evaluation (see ``collect.nim`` /
  ## ``runtime_core.nim``); the harvest runs on that same evaluation thread, so
  ## reading them here is safe. The ``{.gcsafe.}`` cast asserts that to satisfy
  ## the closure-hook signature.
  {.cast(gcsafe).}:
    let resources = collectedResources()
    let groups = registeredStateGroups()
    if resources.len == 0 and groups.len == 0:
      return ""
    fromBytes(encodeResourceGraphPayload(resources, groups))

proc installResourceGraphHarvestHook*() =
  ## Register the encoder onto ``repro_project_dsl``'s harvest hook so the
  ## provider fragment builder can emit the resource-graph metadata node.
  ## Called once at module init below; idempotent.
  setResourceGraphHarvestHook(encodeCollectedResourceGraphPayload)

installResourceGraphHarvestHook()
