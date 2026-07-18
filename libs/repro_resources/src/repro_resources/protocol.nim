## RP5b (Provider-Runtime-Protocol-v1.md §5): run a resource type's driver
## ops OVER THE PROTOCOL.
##
## This module closes the RP5a runtime gap: a consumer's ``resource(typeId,
## …)`` can type-check against an imported resource contract (RP5a), but its
## driver body lives in the DEFINING repo's provider binary, so it cannot run
## in-process. RP5b wires the two ends:
##
##   * PROVIDER side — a provider binary that registers a resource type (via
##     the RP4 ``resourceType`` macro / ``registerResourceProvider``) links
##     this module; ``installResourceOpDispatch`` installs a hook into the DSL
##     provider serve loop (RP2, ``runtime_provider.nim``) so the loop routes a
##     ``<typeId>.identity/digest/observe/plan/apply`` InvokeEntryPoint to the
##     registered ``lookupResourceProvider(typeId).driver.*``. The
##     ``ResourceInstance`` arg + the op result (ObservedState / ResourceBinding)
##     cross the wire as ``BoxedValue`` payloads.
##
##   * ENGINE / reconcile side — ``reconcileResourcesViaSession`` drives the
##     desired graph exactly like the in-process ``reconcileResources``, but
##     every leaf op is an ``invokeEntryPoint`` against a launched provider
##     session (RP2/RP3) instead of an in-process ``driver.*`` call. The
##     consumer process therefore never links the driver body — it runs in the
##     provider process.
##
## Marshalling (v1 §2): the three resource-lane payloads travel as
## ``BoxedValue = (typeId, jsonStr)`` pairs through the shared
## Typed-Graph-Extensions ``extensionRegistry``. Because ``ResourceInstance``
## nests an ``ExtensionBox`` (the attrs, which the provider marshals by its OWN
## resource typeId via ``registerExtension[Attrs](typeId)``) and the two result
## types carry a ``Digest256`` array + an enum, ``std/json``'s ``%*`` cannot
## serialize them directly; the three typeIds are registered with a CUSTOM
## ``ExtensionMarshaler`` whose opaque payload string is a canonical binary
## codec's bytes carried verbatim — the SAME approach RP2 uses for the
## provider-graph request/response, keeping the registry the single codec of
## record.

import std/[options, tables]
from std/strutils import parseInt, rfind

import repro_core                    # writeString / readString / writeU32Le …
import repro_provider_runtime        # BoxedValue / EntryPointResult / invokeEntryPoint / ProviderHandle
from repro_home_generations/pointer import Digest256, DigestSize
from repro_home_resources/types import ObservedState, ResourceActionKind,
  rakNoOp, rakCreate, rakUpdate, rakReplace, rakDestroy, rakAdopt,
  rakDriftBlocked
import repro_project_dsl             # ExtensionBox / extensionRegistry / marshalAttrs seam
import repro_resources/instance
import repro_resources/marshal
import repro_resources/reconcile

const
  ResourceInstanceTypeId* = "reprobuild.resource-instance.v1"
  ObservedStateTypeId* = "reprobuild.resource-observed-state.v1"
  ResourceBindingTypeId* = "reprobuild.resource-binding.v1"

# --------------------------------------------------------------------------
# byte<->string bridge (an opaque BoxedValue.jsonStr carries binary bytes,
# exactly as RP2's provider-graph codec does).
# --------------------------------------------------------------------------

proc bytesToStr(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc strToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc writeDigest(outp: var seq[byte]; d: Digest256) =
  for b in d:
    outp.add(b)

proc readDigest(bytes: openArray[byte]; pos: var int): Digest256 =
  if pos + DigestSize > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated resource digest")
  for i in 0 ..< DigestSize:
    result[i] = bytes[pos + i]
  pos += DigestSize

# --------------------------------------------------------------------------
# ResourceInstance codec. The attrs box travels as its OWN (resource) typeId
# + the marshalled attrs JSON, rehydrated via ``unmarshalAttrs`` — so the
# receiving side needs only the attrs ``registerExtension`` marshaller, never
# the driver.
# --------------------------------------------------------------------------

proc encodeResourceInstance*(inst: ResourceInstance): seq[byte] =
  result.writeString(inst.typeId)
  result.writeString(inst.address)
  # attrs: (box typeId, marshalled attrs payload)
  result.writeString(inst.attrs.typeId)
  result.writeString(marshalAttrs(inst.attrs))
  result.writeU32Le(uint32(inst.dependsOn.len))
  for dep in inst.dependsOn:
    result.writeString(dep)
  result.writeU32Le(uint32(ord(inst.determinism)))

proc decodeResourceInstance*(bytes: openArray[byte]): ResourceInstance =
  var pos = 0
  result.typeId = readString(bytes, pos)
  result.address = readString(bytes, pos)
  let attrsTypeId = readString(bytes, pos)
  let attrsJson = readString(bytes, pos)
  result.attrs = unmarshalAttrs(attrsTypeId, attrsJson)
  let deps = int(readU32Le(bytes, pos))
  result.dependsOn = newSeq[string](deps)
  for i in 0 ..< deps:
    result.dependsOn[i] = readString(bytes, pos)
  result.determinism = ResourceDeterminism(int(readU32Le(bytes, pos)))

proc encodeObservedState*(obs: ObservedState): seq[byte] =
  result.add(if obs.present: 1'u8 else: 0'u8)
  result.writeDigest(obs.digest)
  result.writeU32Le(uint32(obs.rawBytes.len))
  for b in obs.rawBytes:
    result.add(b)

proc decodeObservedState*(bytes: openArray[byte]): ObservedState =
  var pos = 0
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated observed state")
  result.present = bytes[pos] != 0'u8
  inc pos
  result.digest = readDigest(bytes, pos)
  let rawLen = int(readU32Le(bytes, pos))
  if pos + rawLen > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated observed-state raw bytes")
  result.rawBytes = newSeq[byte](rawLen)
  for i in 0 ..< rawLen:
    result.rawBytes[i] = bytes[pos + i]
  pos += rawLen

proc encodeResourceBinding*(b: ResourceBinding): seq[byte] =
  result.writeString(b.address)
  result.writeString(b.typeId)
  result.writeString(b.resourceId)
  result.writeDigest(b.postWriteDigest)
  result.add(if b.present: 1'u8 else: 0'u8)

proc decodeResourceBinding*(bytes: openArray[byte]): ResourceBinding =
  var pos = 0
  result.address = readString(bytes, pos)
  result.typeId = readString(bytes, pos)
  result.resourceId = readString(bytes, pos)
  result.postWriteDigest = readDigest(bytes, pos)
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated resource binding present flag")
  result.present = bytes[pos] != 0'u8

# --------------------------------------------------------------------------
# Register the three payload codecs on the shared registry (custom marshaler,
# opaque binary payload — the RP2 pattern).
# --------------------------------------------------------------------------

proc registerResourceProtocolCodecs*() =
  ## Idempotent: register the ResourceInstance / ObservedState /
  ## ResourceBinding marshallers on the shared ``extensionRegistry`` so their
  ## values cross the session boundary. Both the engine (which builds the
  ## desired ``ResourceInstance`` + reads results) and the provider (which
  ## reads the instance + writes results) call this.
  extensionRegistry[ResourceInstanceTypeId] = ExtensionMarshaler(
    marshal: proc(box: ExtensionBox): string =
      bytesToStr(encodeResourceInstance(
        TypedExtensionBox[ResourceInstance](box).val)),
    unmarshal: proc(jsonStr: string): ExtensionBox =
      TypedExtensionBox[ResourceInstance](
        typeId: ResourceInstanceTypeId,
        val: decodeResourceInstance(strToBytes(jsonStr))))
  extensionRegistry[ObservedStateTypeId] = ExtensionMarshaler(
    marshal: proc(box: ExtensionBox): string =
      bytesToStr(encodeObservedState(
        TypedExtensionBox[ObservedState](box).val)),
    unmarshal: proc(jsonStr: string): ExtensionBox =
      TypedExtensionBox[ObservedState](
        typeId: ObservedStateTypeId,
        val: decodeObservedState(strToBytes(jsonStr))))
  extensionRegistry[ResourceBindingTypeId] = ExtensionMarshaler(
    marshal: proc(box: ExtensionBox): string =
      bytesToStr(encodeResourceBinding(
        TypedExtensionBox[ResourceBinding](box).val)),
    unmarshal: proc(jsonStr: string): ExtensionBox =
      TypedExtensionBox[ResourceBinding](
        typeId: ResourceBindingTypeId,
        val: decodeResourceBinding(strToBytes(jsonStr))))

proc boxResourceInstance*(inst: ResourceInstance): BoxedValue =
  registerResourceProtocolCodecs()
  BoxedValue(typeId: ResourceInstanceTypeId,
    jsonStr: extensionRegistry[ResourceInstanceTypeId].marshal(
      TypedExtensionBox[ResourceInstance](
        typeId: ResourceInstanceTypeId, val: inst)))

proc unboxResourceInstance*(box: BoxedValue): ResourceInstance =
  if box.typeId != ResourceInstanceTypeId:
    raise newException(ValueError,
      "expected a ResourceInstance BoxedValue, got typeId '" & box.typeId & "'")
  registerResourceProtocolCodecs()
  TypedExtensionBox[ResourceInstance](
    extensionRegistry[ResourceInstanceTypeId].unmarshal(box.jsonStr)).val

proc boxObservedState*(obs: ObservedState): BoxedValue =
  registerResourceProtocolCodecs()
  BoxedValue(typeId: ObservedStateTypeId,
    jsonStr: extensionRegistry[ObservedStateTypeId].marshal(
      TypedExtensionBox[ObservedState](
        typeId: ObservedStateTypeId, val: obs)))

proc unboxObservedState*(box: BoxedValue): ObservedState =
  if box.typeId != ObservedStateTypeId:
    raise newException(ValueError,
      "expected an ObservedState BoxedValue, got typeId '" & box.typeId & "'")
  registerResourceProtocolCodecs()
  TypedExtensionBox[ObservedState](
    extensionRegistry[ObservedStateTypeId].unmarshal(box.jsonStr)).val

proc boxResourceBinding*(b: ResourceBinding): BoxedValue =
  registerResourceProtocolCodecs()
  BoxedValue(typeId: ResourceBindingTypeId,
    jsonStr: extensionRegistry[ResourceBindingTypeId].marshal(
      TypedExtensionBox[ResourceBinding](
        typeId: ResourceBindingTypeId, val: b)))

proc unboxResourceBinding*(box: BoxedValue): ResourceBinding =
  if box.typeId != ResourceBindingTypeId:
    raise newException(ValueError,
      "expected a ResourceBinding BoxedValue, got typeId '" & box.typeId & "'")
  registerResourceProtocolCodecs()
  TypedExtensionBox[ResourceBinding](
    extensionRegistry[ResourceBindingTypeId].unmarshal(box.jsonStr)).val

# --------------------------------------------------------------------------
# Provider-side dispatch: <typeId>.<op> InvokeEntryPoint -> driver.<op>.
# --------------------------------------------------------------------------

proc splitResourceOp(entryPointId: string): tuple[typeId, op: string] =
  ## ``<typeId>.<op>`` where ``<op>`` is the last dotted segment. The typeId
  ## itself contains dots (e.g. ``vm_harness.container.observe``), so we split
  ## on the LAST dot.
  let idx = entryPointId.rfind('.')
  if idx <= 0:
    raise newException(ValueError,
      "malformed resource op entry point '" & entryPointId & "'")
  (typeId: entryPointId[0 ..< idx], op: entryPointId[idx + 1 .. ^1])

proc dispatchResourceOp*(entryPointId: string;
                         args: seq[BoxedValue]): EntryPointResult {.nimcall.} =
  ## The provider-side handler the serve loop calls for a resource op entry
  ## point. Unboxes the ``ResourceInstance`` arg, looks up the registered
  ## driver by typeId (a HARD error on unknown — the provider binary linked
  ## this module, so the type MUST be registered), runs the op, and boxes the
  ## result. Runs in the PROVIDER process, so any real-world effect (the fake
  ## world in the RP5b test) happens here, never in the engine.
  registerResourceProtocolCodecs()
  let parts = splitResourceOp(entryPointId)
  if args.len < 1:
    raise newException(ValueError,
      "resource op '" & entryPointId & "' expects a ResourceInstance arg")
  let inst = unboxResourceInstance(args[0])
  if inst.typeId != parts.typeId:
    raise newException(ValueError,
      "resource op typeId mismatch: entry point '" & entryPointId &
      "' vs instance typeId '" & inst.typeId & "'")
  let def = lookupResourceProvider(parts.typeId)   # hard error on unknown
  let drv = def.driver
  result = EntryPointResult(ok: true, hasValue: true)
  case parts.op
  of "identity":
    result.value = boxResourceBinding(ResourceBinding(
      address: inst.address, typeId: inst.typeId,
      resourceId: drv.identity(inst)))
  of "digest":
    var obs: ObservedState
    obs.present = true
    obs.digest = drv.digest(inst)
    result.value = boxObservedState(obs)
  of "observe":
    # The 2nd arg (optional) is a prior ResourceBinding.
    var prior = none(ResourceBinding)
    if args.len >= 2 and args[1].typeId == ResourceBindingTypeId:
      prior = some(unboxResourceBinding(args[1]))
    result.value = boxObservedState(drv.observe(inst, prior))
  of "apply":
    # apply(inst, action, observed): args[1] = observed, args[2] = action ord
    var observed: ObservedState
    if args.len >= 2 and args[1].typeId == ObservedStateTypeId:
      observed = unboxObservedState(args[1])
    var action = rakCreate
    if args.len >= 3 and args[2].typeId == "reprobuild.resource-action.v1":
      # action is carried as a tiny observed-state-free box: its jsonStr is the
      # ordinal as decimal text.
      action = ResourceActionKind(parseInt(args[2].jsonStr))
    result.value = boxResourceBinding(drv.apply(inst, action, observed))
  else:
    raise newException(ValueError,
      "unknown resource op '" & parts.op & "' for '" & entryPointId & "'")

proc boxResourceAction*(action: ResourceActionKind): BoxedValue =
  ## A minimal side-payload carrying the planned action ordinal into ``apply``.
  BoxedValue(typeId: "reprobuild.resource-action.v1", jsonStr: $ord(action))

# --------------------------------------------------------------------------
# Provider serve-loop hook installation. Guarded so this module compiles in
# NON-provider mode too (the engine side links it without the DSL serve loop).
# --------------------------------------------------------------------------

when defined(reproProviderMode):
  proc installResourceOpDispatch*() =
    ## Called at module init inside a provider binary: register the codecs and
    ## install ``dispatchResourceOp`` into the DSL provider serve loop so a
    ## ``<typeId>.<op>`` InvokeEntryPoint reaches the registered driver.
    registerResourceProtocolCodecs()
    setResourceOpDispatchHook(dispatchResourceOp)

  installResourceOpDispatch()

# --------------------------------------------------------------------------
# Engine / reconcile side: drive the desired graph via a provider SESSION.
# --------------------------------------------------------------------------

type
  ResourceSessionResolver* = proc (typeId: string): ProviderHandle {.closure.}
    ## Given a resource ``typeId``, return the launched provider session whose
    ## binary registers that type. The engine keys these by ProviderArtifactId
    ## (RP1/RP2) and reuses one session per key; the RP5b test supplies a
    ## resolver over a single launched provider.

proc invokeResourceOp(handle: ProviderHandle; typeId, op: string;
                      args: seq[BoxedValue]): EntryPointResult =
  let res = handle.invokeEntryPoint(typeId & "." & op, args)
  if not res.ok:
    var msg = "resource op '" & typeId & "." & op & "' failed in provider"
    for d in res.diagnostics:
      msg.add(": " & d.message)
    raise newException(ValueError, msg)
  res

proc observeViaSession*(handle: ProviderHandle; inst: ResourceInstance;
                        prior: Option[ResourceBinding]): ObservedState =
  ## Run ``<typeId>.observe`` in the provider process over the session.
  var args = @[boxResourceInstance(inst)]
  if prior.isSome:
    args.add(boxResourceBinding(prior.get))
  let res = invokeResourceOp(handle, inst.typeId, "observe", args)
  unboxObservedState(res.value)

proc digestViaSession*(handle: ProviderHandle; inst: ResourceInstance): Digest256 =
  ## Run ``<typeId>.digest`` in the provider process over the session.
  let res = invokeResourceOp(handle, inst.typeId, "digest",
    @[boxResourceInstance(inst)])
  unboxObservedState(res.value).digest

proc applyViaSession*(handle: ProviderHandle; inst: ResourceInstance;
                      action: ResourceActionKind;
                      observed: ObservedState): ResourceBinding =
  ## Run ``<typeId>.apply`` in the provider process over the session.
  let res = invokeResourceOp(handle, inst.typeId, "apply",
    @[boxResourceInstance(inst), boxObservedState(observed),
      boxResourceAction(action)])
  unboxResourceBinding(res.value)

proc reconcileResourcesViaSession*(desired: seq[ResourceInstance];
                                   resolve: ResourceSessionResolver;
                                   recorded: seq[ResourceBinding] = @[];
                                   options: ReconcileOptions = ReconcileOptions()):
                                   ReconcileResult =
  ## The PROTOCOL-backed reconcile: the same seven-step algorithm as the
  ## in-process ``reconcileResources``, but each leaf op (observe / digest /
  ## apply) is an ``invokeEntryPoint`` against the resolved provider session
  ## rather than an in-process ``driver.*`` call. The engine process never
  ## links the driver body — it runs in the provider. Selection between this
  ## path and the in-process path is the CALLER's: use this when the resource
  ## type is provider-backed (a launched session), and ``reconcileResources``
  ## when the driver is locally registered.
  registerResourceProtocolCodecs()
  result.actions = @[]
  result.bindings = @[]

  var recordedByAddr = initTable[string, ResourceBinding]()
  for b in recorded:
    recordedByAddr[b.address] = b

  for inst in topoOrder(desired):
    let handle = resolve(inst.typeId)
    let prior =
      if recordedByAddr.hasKey(inst.address): some(recordedByAddr[inst.address])
      else: none(ResourceBinding)

    let observed = observeViaSession(handle, inst, prior)
    let desiredDigest = digestViaSession(handle, inst)
    let action = decide(desiredDigest, observed, prior, options)

    result.actions.add(ResourceAction(
      address: inst.address,
      typeId: inst.typeId,
      kind: action,
      summary: $action & " " & inst.address & " (" & inst.typeId & ")"))

    case action
    of rakCreate, rakUpdate, rakReplace, rakDestroy:
      let binding = applyViaSession(handle, inst, action, observed)
      result.bindings.add(binding)
      recordedByAddr[inst.address] = binding
    of rakNoOp, rakAdopt, rakDriftBlocked:
      if prior.isSome:
        result.bindings.add(prior.get)
