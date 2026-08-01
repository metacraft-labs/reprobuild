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

import std/[options, tables, times]
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
import repro_resources/state_store

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
  # M2 opaque attr pass-through: an UNREGISTERED attrs typeId yields a
  # ``RawExtensionBox`` (opaque bytes + typeId) instead of a hard error, so the
  # ``repro`` CLI can decode an out-of-tree provider's resource graph and route
  # the member to the provider SESSION (which HAS the codec) / the state store
  # without linking the driver's attrs codec. A provider process that DOES have
  # the codec still gets the typed box via the same registered path.
  result.attrs = unmarshalAttrsOrRaw(attrsTypeId, attrsJson)
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

  ResourceLibraryResolver* = proc (typeId: string): pointer {.closure.}
    ## Typed-Extension-Interfaces M4a: optional gate for the C-ABI LIBRARY
    ## transport. Return a non-nil, opaque ``LoadedResourceProviderLibrary``
    ## (as a ``pointer`` to avoid a module cycle — ``library_transport`` imports
    ## this module) for a ``typeId`` whose provider is available as a linkable
    ## ``.so`` the engine ``dlopen``ed, else ``nil``. When it yields a library,
    ## the leaf op runs over the C ABI (a direct in-process cdecl call, NO
    ## process spawn / socket) instead of the session. ``nil`` (the default)
    ## keeps the pre-M4a session / in-process choice unchanged. The three leaf
    ## dispatchers are installed by ``library_transport.nim`` via
    ## ``setResourceLibraryLeafHooks`` (below), breaking the import cycle.

  ResourceInProcessPredicate* = proc (typeId: string): bool {.closure.}
    ## Optional HYBRID gate for ``reconcileResourcesViaSession``: return true
    ## for a ``typeId`` whose driver is LINKED in this process, so its leaf ops
    ## run in-process (``lookupResourceProvider(typeId).driver.*``) instead of
    ## over a session. This lets ONE reconcile drive a MIXED desired graph —
    ## out-of-tree members over the session PLUS an in-tree resource (e.g. the
    ## Named-Runnable-Edges synthetic run-edge-consumer, whose lease-bookkeeping
    ## driver is always linked and has no provider binary to launch) — in a
    ## single pass so ``collectLeaseHolders`` sees the consumer's ``consumes``
    ## edges and renews the session-materialized members. ``nil`` (the default)
    ## sends every op over the session (the RP5b / L5 behaviour, unchanged).

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

# --------------------------------------------------------------------------
# C-ABI LIBRARY transport leaf hooks (M4a). Installed by
# ``library_transport.nim`` so the leaf dispatchers below can run an op over a
# ``dlopen``ed provider ``.so`` without ``protocol.nim`` importing the loader
# (which imports ``protocol.nim``). Each takes the opaque library pointer the
# ``ResourceLibraryResolver`` returned.
# --------------------------------------------------------------------------

type
  LibraryDigestHook = proc (lib: pointer; inst: ResourceInstance): Digest256 {.nimcall.}
  LibraryObserveHook = proc (lib: pointer; inst: ResourceInstance;
                             prior: Option[ResourceBinding]): ObservedState {.nimcall.}
  LibraryApplyHook = proc (lib: pointer; inst: ResourceInstance;
                           action: ResourceActionKind;
                           observed: ObservedState): ResourceBinding {.nimcall.}

var
  libraryDigestHook: LibraryDigestHook
  libraryObserveHook: LibraryObserveHook
  libraryApplyHook: LibraryApplyHook

proc setResourceLibraryLeafHooks*(digest: LibraryDigestHook;
                                  observe: LibraryObserveHook;
                                  apply: LibraryApplyHook) =
  ## Install the C-ABI library leaf dispatchers (called once by
  ## ``library_transport.nim`` at its module init).
  libraryDigestHook = digest
  libraryObserveHook = observe
  libraryApplyHook = apply

proc observeLeaf(resolve: ResourceSessionResolver;
                 inProcess: ResourceInProcessPredicate;
                 inst: ResourceInstance;
                 prior: Option[ResourceBinding];
                 library: ResourceLibraryResolver = nil): ObservedState =
  ## Dispatch ``observe`` for ONE instance. Preference order: C-ABI LIBRARY (a
  ## dlopened provider ``.so``, direct cdecl call) > in-process (hybrid gate) >
  ## the resolved session.
  if library != nil and libraryObserveHook != nil:
    let lib = library(inst.typeId)
    if lib != nil:
      return libraryObserveHook(lib, inst, prior)
  if inProcess != nil and inProcess(inst.typeId):
    lookupResourceProvider(inst.typeId).driver.observe(inst, prior)
  else:
    observeViaSession(resolve(inst.typeId), inst, prior)

proc digestLeaf(resolve: ResourceSessionResolver;
                inProcess: ResourceInProcessPredicate;
                inst: ResourceInstance;
                library: ResourceLibraryResolver = nil): Digest256 =
  if library != nil and libraryDigestHook != nil:
    let lib = library(inst.typeId)
    if lib != nil:
      return libraryDigestHook(lib, inst)
  if inProcess != nil and inProcess(inst.typeId):
    lookupResourceProvider(inst.typeId).driver.digest(inst)
  else:
    digestViaSession(resolve(inst.typeId), inst)

proc applyLeaf(resolve: ResourceSessionResolver;
               inProcess: ResourceInProcessPredicate;
               inst: ResourceInstance; action: ResourceActionKind;
               observed: ObservedState;
               library: ResourceLibraryResolver = nil): ResourceBinding =
  if library != nil and libraryApplyHook != nil:
    let lib = library(inst.typeId)
    if lib != nil:
      return libraryApplyHook(lib, inst, action, observed)
  if inProcess != nil and inProcess(inst.typeId):
    lookupResourceProvider(inst.typeId).driver.apply(inst, action, observed)
  else:
    applyViaSession(resolve(inst.typeId), inst, action, observed)

proc reconcileResourcesViaSession*(desired: seq[ResourceInstance];
                                   resolve: ResourceSessionResolver;
                                   recorded: seq[ResourceBinding] = @[];
                                   options: ReconcileOptions = ReconcileOptions();
                                   store: Option[StateStore] = none(StateStore);
                                   now: Time = getTime();
                                   inProcess: ResourceInProcessPredicate = nil;
                                   library: ResourceLibraryResolver = nil):
                                   ReconcileResult =
  ## The PROTOCOL-backed reconcile: the same seven-step algorithm as the
  ## in-process ``reconcileResources``, but each leaf op (observe / digest /
  ## apply) is an ``invokeEntryPoint`` against the resolved provider session
  ## rather than an in-process ``driver.*`` call. The engine process never
  ## links the driver body — it runs in the provider. Selection between this
  ## path and the in-process path is the CALLER's: use this when the resource
  ## type is provider-backed (a launched session), and ``reconcileResources``
  ## when the driver is locally registered.
  ##
  ## L1/L2 (Named-Runnable-Edges N3a) — store-backed reuse + lease renewal over
  ## a SESSION. When ``store`` is ``some`` this path mirrors the in-process
  ## ``reconcileResources(store)`` decisions EXACTLY, only running the leaf ops
  ## over the session so an OUT-OF-TREE (unlinked) type materializes-or-reuses +
  ## renews without linking its driver:
  ##
  ##   * REUSE-OR-MATERIALIZE: a leased state with a PRESENT, digest-matching
  ##     store record is already up + current — REUSE it (emit ``rakNoOp``, no
  ##     ``observe``/``apply`` over the wire), reconstructing the effective
  ##     binding from the record. Otherwise materialize normally.
  ##   * RENEW: for a leased state, merge this run's holder deadlines into the
  ##     record and recompute the reference-counted MAX ``effectiveDeadline``
  ##     (keep-dominates -> ``none``); persist with the record.
  ##   * a non-leased resource follows the L1 persist path (a record for every
  ##     present binding after the reconcile).
  ##
  ## When ``store`` is ``none`` (the default) the loop is BYTE-IDENTICAL to the
  ## pre-N3a behaviour: no store I/O, no record writes — the RP5b tests and the
  ## L5 reaper's no-store session reconcile are untouched. ``now`` is injectable
  ## for hermetic tests, exactly as in-process.
  registerResourceProtocolCodecs()
  result.actions = @[]
  result.bindings = @[]

  var recordedByAddr = initTable[string, ResourceBinding]()
  for b in recorded:
    recordedByAddr[b.address] = b

  let leaseHolders =
    if store.isSome: collectLeaseHolders(desired)
    else: initTable[string, seq[LeasedDep]]()

  for inst in topoOrder(desired):
    let prior =
      if recordedByAddr.hasKey(inst.address): some(recordedByAddr[inst.address])
      else: none(ResourceBinding)

    let desiredDigest = digestLeaf(resolve, inProcess, inst, library)
    let renewals =
      if leaseHolders.hasKey(inst.address): leaseHolders[inst.address]
      else: @[]
    let isLeasedState = renewals.len > 0

    # L2 cross-run reuse: a leased state with a PRESENT, digest-matching store
    # record is already up + current — reuse it WITHOUT observing or re-applying
    # over the wire (the store record is the reuse index).
    var reuseRec = none(ResourceStateRecord)
    if isLeasedState and store.isSome and hasStateRecord(store.get, inst.address):
      let rec = readStateRecord(store.get, inst.address)
      if rec.present and rec.digest == desiredDigest:
        reuseRec = some(rec)

    var effective = none(ResourceBinding)
    var action: ResourceActionKind

    if reuseRec.isSome:
      action = rakNoOp
      let rec = reuseRec.get
      let binding = ResourceBinding(
        address: rec.address, typeId: rec.typeId,
        resourceId: rec.identity, postWriteDigest: rec.digest,
        present: rec.present)
      result.bindings.add(binding)
      recordedByAddr[inst.address] = binding
      effective = some(binding)
    else:
      let observed = observeLeaf(resolve, inProcess, inst, prior, library)
      action = decide(desiredDigest, observed, prior, options)
      case action
      of rakCreate, rakUpdate, rakReplace, rakDestroy:
        let binding = applyLeaf(resolve, inProcess, inst, action, observed, library)
        result.bindings.add(binding)
        recordedByAddr[inst.address] = binding
        effective = some(binding)
      of rakNoOp, rakAdopt, rakDriftBlocked:
        if prior.isSome:
          result.bindings.add(prior.get)
          effective = prior

    result.actions.add(ResourceAction(
      address: inst.address,
      typeId: inst.typeId,
      kind: action,
      summary: $action & " " & inst.address & " (" & inst.typeId & ")"))

    # L1/L2 persist (only with a store — the no-store path is untouched).
    if store.isSome and effective.isSome and effective.get.present:
      if isLeasedState:
        let existingHolders =
          if hasStateRecord(store.get, inst.address):
            readStateRecord(store.get, inst.address).holders
          else:
            initTable[string, Time]()
        let merged = mergeHolderDeadlines(existingHolders, renewals, now)
        writeStateRecord(store.get, inst, effective.get,
          holders = merged.holders,
          effectiveDeadline = merged.effective,
          lastRenewed = now)
      else:
        writeStateRecord(store.get, inst, effective.get)
