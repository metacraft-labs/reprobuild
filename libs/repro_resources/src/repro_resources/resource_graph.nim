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

import std/[options, tables, algorithm]

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

# ---------------------------------------------------------------------------
# Named-Runnable-Edges N3b — per-typeId provider-artifact refs.
#
# An out-of-tree ``stateGroup`` member (a vm-harness Incus type the ``repro``
# CLI does not link) cannot be reconciled in-process; the leased-consumes
# bridge routes it to a PROVIDER SESSION (N3a). To OPEN that session the CLI
# must know the provider BINARY that serves the member's ``typeId`` — its
# content-addressed ``providerArtifactId`` + working dir. That is exactly the
# ``ProviderArtifactRef`` the engine launches and the daemon reaper's
# ``leaseReapProviders`` registry holds.
#
# The recipe that declares a ``stateGroup`` also composes the provider that
# owns its member types, so the provider artifact is derivable during recipe
# eval. A recipe registers each out-of-tree type's artifact here — a plain
# module global on the SAME eval thread as ``collectedResources`` /
# ``registeredStateGroups`` — and the harvest hook folds the registry into the
# ``reprobuild.resource-graph.v1`` metadata node (below), so ``repro run``
# reads it back WITHOUT re-evaluating the recipe and builds the session
# resolver ``reconcileConsumedStateGroups`` needs (N3b step 1). The mechanism
# mirrors the daemon's ``registerLeaseReapProvider`` registry verbatim, on the
# resources side.
# ---------------------------------------------------------------------------

type
  ResourceProviderArtifactRef* = object
    ## The provider binary that serves an out-of-tree resource ``typeId`` —
    ## the CLI-side analog of the daemon reaper's ``LeaseReapProviderArtifact``
    ## and a strict subset of the engine's ``ProviderArtifactRef`` (the three
    ## fields a session launch needs). Carried in the resource-graph metadata.
    binaryPath*: string
    providerArtifactId*: string
    workingDir*: string

var resourceProviderArtifacts {.threadvar.}: Table[string, ResourceProviderArtifactRef]
  ## typeId -> the provider artifact serving that out-of-tree type. Populated
  ## on the eval thread by a recipe that composes the provider; harvested into
  ## the metadata. A threadvar (like the collect/state-group registries) so the
  ## single-threaded harvest reads what the same thread registered.

proc registerResourceProviderArtifact*(typeId: string;
                                       artifact: ResourceProviderArtifactRef) =
  ## Register (or replace) the provider artifact that serves ``typeId``. A
  ## recipe composing an out-of-tree resource type calls this during eval so
  ## the harvest hook can carry the artifact ref to ``repro run``.
  resourceProviderArtifacts[typeId] = artifact

proc registeredResourceProviderArtifacts*():
    seq[tuple[typeId: string; artifact: ResourceProviderArtifactRef]] =
  ## The registered per-typeId provider artifacts, sorted by ``typeId`` for a
  ## deterministic metadata payload. Empty when the recipe composed none —
  ## keeping the metadata byte-identical to the pre-N3b (v1) layout.
  result = @[]
  for k, v in resourceProviderArtifacts:
    result.add((typeId: k, artifact: v))
  result.sort(proc(a, b: (string, ResourceProviderArtifactRef)): int =
    cmp(a[0], b[0]))

proc clearResourceProviderArtifacts*() =
  ## Test isolation: drop every registered artifact ref.
  resourceProviderArtifacts.clear()

const
  ResourceGraphMagic = "RGPH"
  ResourceGraphVersionV1 = 1'u16
    ## Pre-N3b layout: resources + groups only. Still emitted verbatim when no
    ## provider-artifact ref is registered (byte-identical to N2).
  ResourceGraphVersionV2 = 2'u16
    ## N3b: appends the per-typeId provider-artifact section AFTER groups.

proc encodeResourceGraphPayload*(resources: seq[ResourceInstance];
                                 groups: seq[StateGroupDef];
                                 providerArtifacts: openArray[
                                   tuple[typeId: string;
                                         artifact: ResourceProviderArtifactRef]] = @[]):
    seq[byte] =
  ## Frame the desired resource graph + state-group membership (+ the N3b
  ## per-typeId provider-artifact refs, if any). The per-resource body reuses
  ## the RP protocol codec, so the receiving side needs only each attrs
  ## typeId's ``registerExtension`` marshaller (never the driver) to rehydrate.
  ##
  ## When ``providerArtifacts`` is EMPTY the payload + version are byte-
  ## identical to the pre-N3b v1 layout (the N2 invariant); a non-empty set
  ## bumps to v2 and appends the section.
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

  let version =
    if providerArtifacts.len == 0: ResourceGraphVersionV1
    else: ResourceGraphVersionV2
  if version == ResourceGraphVersionV2:
    # Additive, non-empty-only: the section is present ONLY in v2 so a graph
    # with no out-of-tree provider stays byte-identical to N2.
    payload.writeU32Le(uint32(providerArtifacts.len))
    for pa in providerArtifacts:
      payload.writeString(pa.typeId)
      payload.writeString(pa.artifact.binaryPath)
      payload.writeString(pa.artifact.providerArtifactId)
      payload.writeString(pa.artifact.workingDir)

  result.add(toBytes(ResourceGraphMagic))
  result.writeU16Le(version)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeResourceGraphPayload*(bytes: openArray[byte]):
    tuple[resources: seq[ResourceInstance]; groups: seq[StateGroupDef];
          providerArtifacts: seq[tuple[typeId: string;
                                       artifact: ResourceProviderArtifactRef]]] =
  ## Inverse of ``encodeResourceGraphPayload``. Rehydrates each
  ## ``ResourceInstance`` via the RP codec (hard-errors on an attrs typeId
  ## with no registered marshaller — the applying process must link the
  ## provider module), the state-group membership, and (v2 only) the N3b
  ## per-typeId provider-artifact refs. A v1 payload yields an empty
  ## ``providerArtifacts`` seq — the all-in-tree fast path.
  registerResourceProtocolCodecs()
  if bytes.len < 10:
    raise newException(ValueError, "truncated resource-graph envelope")
  let magic = toBytes(ResourceGraphMagic)
  for i in 0 ..< magic.len:
    if bytes[i] != magic[i]:
      raise newException(ValueError, "unknown resource-graph payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != ResourceGraphVersionV1 and version != ResourceGraphVersionV2:
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
  result.providerArtifacts = @[]
  if version == ResourceGraphVersionV2:
    let paCount = int(readU32Le(bytes, pos))
    for i in 0 ..< paCount:
      let typeId = readString(bytes, pos)
      var a: ResourceProviderArtifactRef
      a.binaryPath = readString(bytes, pos)
      a.providerArtifactId = readString(bytes, pos)
      a.workingDir = readString(bytes, pos)
      result.providerArtifacts.add((typeId: typeId, artifact: a))

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
    let providerArtifacts = registeredResourceProviderArtifacts()
    fromBytes(encodeResourceGraphPayload(resources, groups, providerArtifacts))

proc installResourceGraphHarvestHook*() =
  ## Register the encoder onto ``repro_project_dsl``'s harvest hook so the
  ## provider fragment builder can emit the resource-graph metadata node.
  ## Called once at module init below; idempotent.
  setResourceGraphHarvestHook(encodeCollectedResourceGraphPayload)

installResourceGraphHarvestHook()
