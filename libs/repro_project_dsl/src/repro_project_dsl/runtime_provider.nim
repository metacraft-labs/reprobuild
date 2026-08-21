when defined(reproProviderMode):
  proc providerBodyHash(pkg: PackageDef): string =
    pkg.packageName & ".build.v1"

  proc rootEntryPointId(pkg: PackageDef): string =
    pkg.packageName & ".root"

  proc devEnvEntryPointId(pkg: PackageDef): string =
    devEnvIntrospectionEntryPointId(pkg.packageName)

  proc sanitizeNodePart(value: string): string =
    for ch in value:
      if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
          ch in {'-', '_', '.'}:
        result.add(ch)
      else:
        result.add('_')
    if result.len == 0:
      result = "node"

  proc effectiveDevEnvBodyHash(pkg: PackageDef): string =
    if pkg.devEnvBodyHash.len > 0:
      return pkg.devEnvBodyHash

    # Constructors can append tool requirements after parsePackageDef's
    # implicit-dev-env hash pass. Hash the final floor here as well so those
    # packages never expose a manifest entry with an empty body hash.
    var floorRepr = pkg.packageName & ".dev-env.implicit-floor.v1\n"
    for useDef in pkg.allToolUses():
      floorRepr.add(useDef.rawConstraint & "\x1f" & useDef.packageSelector &
        "\x1f" & useDef.executableName & "\x1f" &
        useDef.policyPath.join("/") & "\x1f" & useDef.gateVariant & "\x1f" &
        useDef.gateValue & "\n")
    stableHashHex(floorRepr)

  proc providerManifest(pkg: PackageDef; providerArtifactId: string;
                        foreachDefs: openArray[ProviderForeachDef]):
      ProviderManifest =
    result = ProviderManifest(
      providerArtifactId: providerArtifactId,
      protocolVersion: ProviderProtocolVersion,
      entryPoints: @[
        GraphEntryPointDescriptor(
          id: rootEntryPointId(pkg),
          kind: gpkProjectRoot,
          stableName: pkg.packageName,
          bodyHash: providerBodyHash(pkg),
          argumentSchemaId: "reprobuild.project-root.v1",
          outputSchemaId: "reprobuild.graph-fragment.v1")
      ])
    if exposesDevEnvIntrospection(pkg):
      # Windows-dev-env M1: exposed for explicit ``devEnv:`` packages AND
      # for ``uses:``-only packages (implicit floor-derived dev-env). The
      # ``devEnvBodyHash`` is content-derived for both cases (an explicit
      # block hashes its body; a ``uses:``-only floor hashes the floor —
      # see ``parsePackageDef``), so the entry has a stable, deterministic
      # id in either case.
      result.entryPoints.add(GraphEntryPointDescriptor(
        id: devEnvEntryPointId(pkg),
        kind: gpkDevEnvIntrospection,
        stableName: pkg.packageName & ":dev-env",
        bodyHash: effectiveDevEnvBodyHash(pkg),
        argumentSchemaId: "reprobuild.dev-env-request.v1",
        outputSchemaId: "reprobuild.dev-env-result.v1"))
    for def in foreachDefs:
      result.entryPoints.add(GraphEntryPointDescriptor(
        id: def.id,
        kind: gpkStructuralIteratorBody,
        stableName: def.stableName,
        bodyHash: def.bodyHash,
        argumentSchemaId: "reprobuild.foreach-member.v1",
        outputSchemaId: "reprobuild.graph-fragment.v1"))

  proc actionNode(namespace, id: string): string =
    namespace & ":action:" & sanitizeNodePart(id)

  proc outputNode(namespace, actionId, output: string): string =
    namespace & ":output:" & sanitizeNodePart(actionId) & ":" &
      sanitizeNodePart(output)

  proc defaultBuildActionNode(namespace: string): string =
    namespace & ":metadata:default-build-action"

  proc buildTargetNode(namespace, name: string): string =
    namespace & ":metadata:build-target:" & sanitizeNodePart(name)

  proc targetExportTableNode(namespace: string): string =
    ## Named-Targets M1: single metadata node id under which the
    ## project-scoped target-export table travels.
    namespace & ":metadata:target-export-table"

  proc addChildSpecsFromInputs(fragment: var GraphFragment) =
    for input in fragment.evaluationInputs:
      if input.kind != gevDirectoryEnumeration or
          input.memberEntryPointId.len == 0:
        continue
      let root =
        if input.memberArgumentRoot.len > 0: input.memberArgumentRoot
        else: input.identity
      for member in input.directoryMembers:
        fragment.childEntryPoints.add(GraphEntryPointInvocationSpec(
          entryPointId: input.memberEntryPointId,
          entryPointBodyHash: input.memberEntryPointBodyHash,
          arguments: root / member,
          namespace: fragment.namespace,
          stableName: input.memberEntryPointId & ":" & member))

  proc buildPackageFragment*(pkg: PackageDef; request: ProviderGraphRequest;
                             buildProc: proc (); includeDefault = true):
      GraphFragment {.dynOrStatic.} =
    resetBuildActionRegistry()
    resetBuildTargetRegistry()
    resetBuildPoolRegistry()
    resetDefaultBuildActionRegistry()
    resetTargetExportRegistry()
    resetProviderEvaluationInputRegistry()
    currentProviderProjectRoot = request.arguments
    # Named-Targets M1: stash the current package as the per-edge
    # owning-package override so typed-tool wrappers defined in a
    # different package still attribute edges to THIS package's
    # ``build:`` body when they fire.
    setCurrentOwningPackageOverride(pkg.packageName)
    try:
      if buildProc != nil:
        buildProc()
    finally:
      currentProviderProjectRoot = ""
      clearCurrentOwningPackageOverride()
    let actions = inferDeclaredActionDeps(
      registeredBuildActions(), request.arguments)
    let targets = registeredBuildTargets()
    let pools = registeredBuildPools()
    let defaultAction = registeredDefaultBuildAction()
    # Named-Targets M1: roll up explicit ``target "name", handle``
    # declarations into the same project-scoped export table as the
    # implicit names recorded at typed-tool call sites. The implicit
    # rows were registered during ``buildProc`` evaluation; the
    # explicit rows go in here because the package name only becomes
    # available at fragment-construction time.
    for target in targets:
      registerExplicitTargetExport(target, pkg.packageName)
    let exportTable = registeredTargetExports()
    result = GraphFragment(
      entryPointId: request.entryPointId,
      entryPointBodyHash: request.entryPointBodyHash,
      arguments: request.arguments,
      namespace: request.namespace)
    if includeDefault and fileExists(extendedPath(pkg.sourceFile)):
      result.evaluationInputs.add(fileReadInput(pkg.sourceFile))
    for input in registeredProviderEvaluationInputs():
      result.evaluationInputs.add(input)
    result.addChildSpecsFromInputs()
    for action in actions:
      let nodeId = actionNode(request.namespace, action.id)
      result.nodes.add(GraphNode(
        id: nodeId,
        kind: gnkAction,
        stableName: action.id,
        payload: actionPayload(action)))
    for target in targets:
      result.nodes.add(GraphNode(
        id: buildTargetNode(request.namespace, target.name),
        kind: gnkMetadata,
        stableName: "reprobuild.build-target.v1",
        payload: targetPayload(target)))
    for pool in pools:
      result.nodes.add(GraphNode(
        id: request.namespace & ":metadata:build-pool:" & sanitizeNodePart(pool.name),
        kind: gnkMetadata,
        stableName: "reprobuild.build-pool.v1",
        payload: poolPayload(pool)))
    # Named-Targets M1: surface the project-scoped target-export table
    # as a single ``gnkMetadata`` node so ``repro graph`` and the M2
    # CLI resolver can consume it directly out of the GraphFragment.
    # Always emitted (even when empty) so consumers can rely on the
    # node's presence as a schema version marker.
    #
    # Spec-Implementation M5: schema-version bump from v1 to v2. The
    # stable-name string moves to ``...v2``; the aggregator at
    # ``aggregateTargetExportTable`` matches both v1 and v2 nodes so
    # on-disk artifacts from older fragments continue to flow through
    # the decoder per Build-Graph-Collections.md §"Persistence and
    # the Target-Export Table"'s backward-compat rule.
    result.nodes.add(GraphNode(
      id: targetExportTableNode(request.namespace),
      kind: gnkMetadata,
      stableName: "reprobuild.target-export-table.v2",
      payload: targetExportTablePayload(exportTable)))
    # Named-Runnable-Edges N2: carry the resource-lane graph (the
    # ``stateGroup`` resource subgraph + membership) that this package's
    # ``buildProc()`` collected to the CLI, so the ``repro run`` leased-
    # consumes bridge can reconcile the group without re-evaluating the
    # recipe. Emitted only when a ``repro_resources`` encoder is linked AND
    # it produced a non-empty payload (a package that declares no resources
    # yields ``""`` ⇒ no node ⇒ byte-identical to a pre-N2 fragment).
    let resourceGraphPayload = harvestResourceGraphPayload()
    if resourceGraphPayload.len > 0:
      result.nodes.add(GraphNode(
        id: request.namespace & ":metadata:resource-graph",
        kind: gnkMetadata,
        stableName: "reprobuild.resource-graph.v1",
        payload: resourceGraphPayload))
    if includeDefault and defaultAction.len > 0:
      var found = false
      for action in actions:
        if action.id == defaultAction:
          found = true
          break
      if not found:
        for target in targets:
          if target.name == defaultAction:
            found = true
            break
      if not found:
        raise newException(ValueError,
          "default build action does not match a declared build action or target: " &
            defaultAction)
      result.nodes.add(GraphNode(
        id: defaultBuildActionNode(request.namespace),
        kind: gnkMetadata,
        stableName: "reprobuild.default-build-action.v1",
        payload: defaultAction))
    for action in actions:
      let nodeId = actionNode(request.namespace, action.id)
      for dep in action.deps:
        result.edges.add(GraphEdge(
          id: request.namespace & ":dep:" & sanitizeNodePart(action.id) & ":" &
            sanitizeNodePart(dep),
          kind: gekDependsOn,
          fromNode: nodeId,
          toNode: actionNode(request.namespace, dep)))
      for output in action.outputs:
        let outNode = outputNode(request.namespace, action.id, output)
        result.nodes.add(GraphNode(
          id: outNode,
          kind: gnkGeneratedOutput,
          stableName: output,
          payload: output))
        result.edges.add(GraphEdge(
          id: request.namespace & ":produces:" & sanitizeNodePart(action.id) &
            ":" & sanitizeNodePart(output),
          kind: gekProduces,
          fromNode: nodeId,
          toNode: outNode))
        result.effectClaims.add(OwnedEffectClaim(
          kind: oekFile,
          stableName: output,
          identity: output,
          cleanupPolicy: cplDeleteWhenUnclaimed,
          payload: action.id))
    result.fragmentDigest = computeGraphFragmentDigest(result)

  proc buildPackageDevEnv*(pkg: PackageDef; request: ProviderGraphRequest;
                           devEnvProc: proc ()): DevEnvResult {.dynOrStatic.} =
    # Windows-dev-env M1: a ``uses:``-only recipe exposes dev-env
    # introspection but has NO explicit ``devEnv:`` body, so the DSL emits
    # no ``devEnv<Package>`` proc and ``runPackageProvider`` is called with
    # ``devEnvProc = nil``. That is the IMPLICIT floor-derived dev-env: run
    # no extra body, and let the ``pkg.toolUses`` append below carry the
    # toolchain-floor env — the same append an explicit-``devEnv:`` recipe
    # gets. A nil proc is therefore no longer an error; it is the implicit
    # case.
    resetProviderEvaluationInputRegistry()
    resetDevEnvRegistry()
    currentProviderProjectRoot = request.arguments
    try:
      if devEnvProc != nil:
        devEnvProc()
    finally:
      currentProviderProjectRoot = ""

    let selectedActivities = selectedActivityList(request.activity)
    result = DevEnvResult(
      schemaVersion: 1'u32,
      providerArtifactId: request.providerArtifactId,
      providerEntryPointId: request.entryPointId,
      providerEntryPointBodyHash: request.entryPointBodyHash,
      projectRoot: request.arguments,
      lockSliceId: request.lockSliceId,
      selectedActivities: selectedActivities,
      declaredActivities: devEnvActivityRegistry,
      shellOps: activeShellOps(selectedActivities),
      toolRequirements: activeToolRequirements(selectedActivities),
      tasks: activeTasks(selectedActivities),
      services: activeServices(selectedActivities),
      diagnostics: devEnvDiagnosticRegistry)
    if fileExists(extendedPath(pkg.sourceFile)):
      let input = fileReadInput(pkg.sourceFile)
      result.evaluationInputs.add(input)
      result.sourceFingerprints.add(DevEnvSourceFingerprint(
        kind: "provider-source",
        identity: input.identity,
        digest: input.digest))
    result.evaluationInputs.add(GraphEvaluationInput(
      kind: gevActivitySelection,
      identity: request.activity,
      digest: request.activity))
    for input in registeredProviderEvaluationInputs():
      result.evaluationInputs.add(input)
      if input.kind == gevFileRead:
        result.sourceFingerprints.add(DevEnvSourceFingerprint(
          kind: "file-read",
          identity: input.identity,
          digest: input.digest))
    for useDef in pkg.allToolUses():
      result.toolRequirements.add(DevEnvToolRequirement(
        logicalName: useDef.executableName,
        packageSelector: useDef.packageSelector,
        executableName: useDef.executableName,
        policyPath: useDef.policyPath))

  proc dispatchProviderGraphRequest(pkg: PackageDef;
                                    request: ProviderGraphRequest;
                                    manifest: ProviderManifest;
                                    buildProc: proc ();
                                    foreachDispatch: proc (
                                      request: ProviderGraphRequest):
                                      GraphFragment;
                                    devEnvProc: proc ()):
      ProviderGraphResponse =
    ## The single dispatch shared by the pre-RP2 file path and the RP2
    ## stdio serve loop: route a decoded ``ProviderGraphRequest`` to the
    ## existing entry-point machinery.
    case request.kind
    of prkManifest:
      manifestResponse(manifest)
    of prkGraphInvocation:
      if request.entryPointId == rootEntryPointId(pkg):
        graphResponse(manifest, buildPackageFragment(pkg, request, buildProc))
      elif foreachDispatch != nil:
        graphResponse(manifest, foreachDispatch(request))
      else:
        raise newException(ValueError,
          "unknown provider entry point: " & request.entryPointId)
    of prkDevEnvIntrospection:
      if request.entryPointId == devEnvEntryPointId(pkg):
        devEnvResponse(manifest, buildPackageDevEnv(pkg, request, devEnvProc))
      else:
        raise newException(ValueError,
          "unknown provider dev-env entry point: " & request.entryPointId)

  # RP2 (Provider-Runtime-Protocol-v1.md §2): the InvokeEntryPoint arg and the
  # EntryPointResult value travel as ``(typeId, jsonStr)`` BoxedValues through
  # the Typed-Graph-Extensions ``extensionRegistry`` — the same registry the
  # resource lane (repro_resources/marshal.nim) marshals its attribute box
  # through. The v1 §3 InvokeEntryPoint carries the provider's decoded request
  # as its single arg; the EntryPointResult's value carries the produced
  # fragment (or dev-env result) inside a ``ProviderGraphResponse``.
  #
  # The two payload types nest enums + object graphs that the default
  # ``registerExtension[T]`` marshaller (a versioned SSZ envelope over a
  # flat record, see ``attr_ssz``) does not model, but a canonical binary
  # codec (``encode/decodeProviderRequest`` /
  # ``…Response`` in repro_provider_runtime) already exists and is the tested
  # serializer for exactly these types. So the two typeIds are registered with
  # a CUSTOM ``ExtensionMarshaler`` on the SAME shared registry whose payload
  # string is that canonical codec's bytes carried verbatim in the (opaque)
  # payload string — the registry stays the single codec of record (no
  # parallel registry), while the proven binary serializer carries the
  # enum/graph payload.
  const
    ProviderGraphRequestTypeId* = "reprobuild.provider-graph-request.v1"
    ProviderGraphResponseTypeId* = "reprobuild.provider-graph-response.v1"

  proc rpBytesToStr(bytes: openArray[byte]): string =
    result = newString(bytes.len)
    for i, b in bytes:
      result[i] = char(b)

  proc rpStrToBytes(text: string): seq[byte] =
    result = newSeq[byte](text.len)
    for i, ch in text:
      result[i] = byte(ord(ch))

  block:
    extensionRegistry[ProviderGraphRequestTypeId] = ExtensionMarshaler(
      marshal: proc(box: ExtensionBox): string =
        rpBytesToStr(encodeProviderRequest(
          TypedExtensionBox[ProviderGraphRequest](box).val)),
      unmarshal: proc(jsonStr: string): ExtensionBox =
        TypedExtensionBox[ProviderGraphRequest](
          typeId: ProviderGraphRequestTypeId,
          val: decodeProviderRequest(rpStrToBytes(jsonStr))))
    extensionRegistry[ProviderGraphResponseTypeId] = ExtensionMarshaler(
      marshal: proc(box: ExtensionBox): string =
        rpBytesToStr(encodeProviderResponse(
          TypedExtensionBox[ProviderGraphResponse](box).val)),
      unmarshal: proc(jsonStr: string): ExtensionBox =
        TypedExtensionBox[ProviderGraphResponse](
          typeId: ProviderGraphResponseTypeId,
          val: decodeProviderResponse(rpStrToBytes(jsonStr))))

  proc boxGraphRequest(request: ProviderGraphRequest): BoxedValue =
    BoxedValue(typeId: ProviderGraphRequestTypeId,
      jsonStr: extensionRegistry[ProviderGraphRequestTypeId].marshal(
        TypedExtensionBox[ProviderGraphRequest](
          typeId: ProviderGraphRequestTypeId, val: request)))

  proc unboxGraphRequest(box: BoxedValue): ProviderGraphRequest =
    if box.typeId != ProviderGraphRequestTypeId:
      raise newException(ValueError,
        "InvokeEntryPoint arg has unexpected typeId '" & box.typeId & "'")
    TypedExtensionBox[ProviderGraphRequest](
      extensionRegistry[ProviderGraphRequestTypeId].unmarshal(box.jsonStr)).val

  proc boxGraphResponse(response: ProviderGraphResponse): BoxedValue =
    BoxedValue(typeId: ProviderGraphResponseTypeId,
      jsonStr: extensionRegistry[ProviderGraphResponseTypeId].marshal(
        TypedExtensionBox[ProviderGraphResponse](
          typeId: ProviderGraphResponseTypeId, val: response)))

  proc unboxGraphResponse*(box: BoxedValue): ProviderGraphResponse =
    ## Engine-side helper: re-hydrate the EntryPointResult value into the
    ## typed ``ProviderGraphResponse`` through the same registry.
    if box.typeId != ProviderGraphResponseTypeId:
      raise newException(ValueError,
        "EntryPointResult value has unexpected typeId '" & box.typeId & "'")
    TypedExtensionBox[ProviderGraphResponse](
      extensionRegistry[ProviderGraphResponseTypeId].unmarshal(box.jsonStr)).val

  proc marshalGraphRequest*(request: ProviderGraphRequest): BoxedValue =
    ## Engine-side helper: marshal a ``ProviderGraphRequest`` into the
    ## InvokeEntryPoint arg BoxedValue through the shared registry.
    boxGraphRequest(request)

  # RP3 (Provider-Runtime-Protocol-v1.md §4): the dependency bindings the
  # engine wired into THIS provider session via BindDependencies. A build body
  # reaches a dependency ONLY through this table — there is no ambient/global
  # sibling discovery. The table is (re)set by the serve loop when a
  # BindDependencies frame arrives.
  var providerDependencyBindings: seq[DependencyBinding] = @[]

  proc setProviderDependencyBindings(bindings: seq[DependencyBinding]) =
    providerDependencyBindings = bindings

  proc boundDependencyResult*(logicalName: string): ProviderGraphResponse =
    ## Provider-side (v1 §4): resolve a dependency the engine bound under
    ## ``logicalName`` into the dependency's already-computed result. Raises a
    ## clean error when the engine did NOT bind that name — the provider must
    ## NOT fall back to ambient discovery.
    for binding in providerDependencyBindings:
      if binding.logicalName == logicalName:
        if not binding.hasResult:
          raise newException(ValueError,
            "dependency '" & logicalName & "' is bound but carries no result")
        return unboxGraphResponse(binding.result)
    raise newException(ValueError,
      "no dependency bound under logical name '" & logicalName &
      "' (providers receive handles from the engine; ambient sibling " &
      "discovery is not permitted)")

  proc boundDependencyNames*(): seq[string] =
    ## The logical names the engine bound for this session (v1 §4).
    for binding in providerDependencyBindings:
      result.add(binding.logicalName)

  proc useBoundDependency*(logicalName: string) {.dynOrStatic.} =
    ## Consumer-side (v1 §3+§4): reach a dependency the engine bound under
    ## ``logicalName`` and record its realization as a
    ## ``gevProviderDependencyResult`` evaluation input on the CURRENT fragment.
    ## The identity is the dependency's ProviderArtifactId + entry point; the
    ## digest is the dependency's fragment digest, so a change to the
    ## dependency's realization re-keys this consumer input. Raises cleanly if
    ## the engine did not bind ``logicalName`` (no ambient sibling discovery).
    ##
    ## The DSL runs a ``build:`` body once at module-init (to pre-populate the
    ## shell registry) with NO active invocation and NO bindings; this call is
    ## a no-op there (``activeProviderProjectRoot`` is empty) so init does not
    ## spuriously demand a binding. During a REAL invocation the project root
    ## is set, so an unbound dependency raises exactly as the contract requires.
    if activeProviderProjectRoot().len == 0:
      return
    var binding: DependencyBinding
    var found = false
    for candidate in providerDependencyBindings:
      if candidate.logicalName == logicalName:
        binding = candidate
        found = true
        break
    if not found:
      raise newException(ValueError,
        "no dependency bound under logical name '" & logicalName &
        "' (providers receive handles from the engine; ambient sibling " &
        "discovery is not permitted)")
    let response = boundDependencyResult(logicalName)
    let digest =
      if response.kind == pskGraphResult: response.fragment.fragmentDigest
      elif response.kind == pskDevEnvResult: response.devEnv.providerArtifactId
      else: binding.providerSessionKey
    providerEvaluationInputRegistry.add(GraphEvaluationInput(
      kind: gevProviderDependencyResult,
      identity: binding.providerArtifactId & ":" & binding.entryPointId & ":" &
        logicalName,
      digest: digest))

  # RP5b (Provider-Runtime-Protocol-v1.md §5): the resource-driver dispatch
  # hook. A provider binary that registers a resource TYPE (via the RP4
  # ``resourceType`` macro / ``registerResourceProvider``) links
  # ``repro_resources``, whose ``installResourceOpDispatch`` sets this hook so
  # the serve loop can route a ``<typeId>.observe/plan/apply/identity/digest``
  # InvokeEntryPoint to the registered driver. The DSL cannot import
  # ``repro_resources`` (the dependency runs the other way — ``repro_resources``
  # imports the DSL), so the resource lane installs itself here at module init.
  # The hook takes the entry-point id + the marshalled args and returns a fully
  # formed EntryPointResult; ``nil`` means "no resource lane linked", in which
  # case an unknown entry point is the usual hard error.
  type ResourceOpDispatch* = proc (entryPointId: string;
                                   args: seq[BoxedValue]): EntryPointResult
                                  {.nimcall.}
  var resourceOpDispatchHook: ResourceOpDispatch = nil

  proc setResourceOpDispatchHook*(hook: ResourceOpDispatch) =
    ## Installed by ``repro_resources`` (RP5b) so the provider serve loop can
    ## dispatch resource driver ops as protocol entry points.
    resourceOpDispatchHook = hook

  proc isResourceOpEntryPoint(entryPointId: string): bool =
    ## A resource op entry point is ``<typeId>.<op>`` for one of the five
    ## driver ops. Package/foreach/dev-env ids never collide with these
    ## suffixes (``.root`` / ``:dev-env`` / foreach stable names).
    for op in [".identity", ".digest", ".observe", ".plan", ".apply"]:
      if entryPointId.endsWith(op):
        return true
    false

  proc serveProviderSession(pkg: PackageDef; buildProc: proc ();
                            foreachDefs: openArray[ProviderForeachDef];
                            foreachDispatch: proc (
                              request: ProviderGraphRequest): GraphFragment;
                            devEnvProc: proc ()): int =
    ## RP2 stdio serve loop (v1 §2-4). Reads EngineHello, replies with the
    ## ProviderManifest, then services InvokeEntryPoint frames against the
    ## existing entry-point machinery until the engine closes the pipe (EOF).
    let toEngine = newFileStream(stdout)
    let fromEngine = newFileStream(stdin)
    # Handshake: EngineHello -> ProviderManifest.
    let helloFrame = fromEngine.readFrame()
    if helloFrame.messageType != smtEngineHello:
      stderr.writeLine("repro provider serve: expected EngineHello, got " &
        $ord(helloFrame.messageType))
      return 2
    let hello = decodeEngineHello(helloFrame.payload)
    # The manifest's providerArtifactId is the identity the engine reconciles
    # against its expected RP1 ProviderArtifactId; the EngineHello does not
    # carry one, so v1 keeps the manifest self-reported id (see the RP2
    # fingerprint-reconciliation note in the milestone). ``lockSliceId`` from
    # the hello flows into each request below.
    let manifest = providerManifest(pkg, "", foreachDefs)
    toEngine.writeFrame(smtProviderManifest, encodeProviderManifestMsg(manifest))
    while true:
      var frame: tuple[messageType: SessionMessageType; payload: seq[byte]]
      try:
        frame = fromEngine.readFrame()
      except ProviderSessionError:
        # Clean EOF at a frame boundary = engine tore the session down.
        break
      if frame.messageType == smtBindDependencies:
        # RP3 (v1 §4): the engine wires dependency handles into this session.
        # Store them for the build body to reach via ``boundDependencyResult``,
        # then acknowledge so the engine knows the bind took effect before it
        # invokes an entry point that needs a dependency.
        let bindMsg = decodeBindDependencies(frame.payload)
        setProviderDependencyBindings(bindMsg.bindings)
        toEngine.writeFrame(smtBindDependenciesAck, @[])
        continue
      if frame.messageType != smtInvokeEntryPoint:
        stderr.writeLine("repro provider serve: expected InvokeEntryPoint, got " &
          $ord(frame.messageType))
        return 2
      let invoke = decodeInvokeEntryPoint(frame.payload)
      # RP5b (v1 §5): a resource driver op (``<typeId>.observe`` etc.) is
      # dispatched to the registered driver through the resource lane's hook,
      # bypassing the ``ProviderGraphRequest`` request/fragment machinery the
      # package/foreach entry points use — its args + result are the
      # resource-lane BoxedValues (ResourceInstance / ObservedState /
      # ResourceBinding), not a graph request/response.
      if resourceOpDispatchHook != nil and
          isResourceOpEntryPoint(invoke.entryPointId):
        var resResult: EntryPointResult
        try:
          resResult = resourceOpDispatchHook(invoke.entryPointId, invoke.args)
        except CatchableError as err:
          resResult = EntryPointResult(ok: false, hasValue: false,
            diagnostics: @[SessionDiagnostic(severity: "error",
              message: err.msg)])
        toEngine.writeFrame(smtEntryPointResult,
          encodeEntryPointResult(resResult))
        continue
      var result = EntryPointResult(ok: false)
      try:
        if invoke.args.len != 1:
          raise newException(ValueError,
            "InvokeEntryPoint expects exactly one request arg, got " &
            $invoke.args.len)
        var request = unboxGraphRequest(invoke.args[0])
        if request.entryPointId.len == 0:
          request.entryPointId = invoke.entryPointId
        if request.lockSliceId.len == 0:
          request.lockSliceId = hello.lockSliceId
        let response = dispatchProviderGraphRequest(pkg, request, manifest,
          buildProc, foreachDispatch, devEnvProc)
        result.ok = true
        result.value = boxGraphResponse(response)
        result.hasValue = true
        if response.kind == pskGraphResult:
          result.evaluationInputs = response.fragment.evaluationInputs
        elif response.kind == pskDevEnvResult:
          result.evaluationInputs = response.devEnv.evaluationInputs
      except CatchableError as err:
        result.ok = false
        result.hasValue = false
        result.diagnostics = @[SessionDiagnostic(severity: "error",
          message: err.msg)]
      toEngine.writeFrame(smtEntryPointResult, encodeEntryPointResult(result))
    0

  proc runPackageProvider*(pkg: PackageDef; buildProc: proc ();
                           foreachDefs: openArray[ProviderForeachDef] = [];
                           foreachDispatch: proc (
                             request: ProviderGraphRequest): GraphFragment = nil;
                           devEnvProc: proc () = nil): int {.dynOrStatic.} =
    try:
      let params = commandLineParams()
      if ProviderServeFlag in params:
        # RP2: long-lived stdio session (v1 §2-4).
        return serveProviderSession(pkg, buildProc, foreachDefs,
          foreachDispatch, devEnvProc)
      # Pre-RP2: single-shot, file-based request/response.
      let paths = parseProviderProtocolArgs(params)
      let request = readProviderRequestFile(paths.requestPath)
      let manifest = providerManifest(pkg, request.providerArtifactId,
        foreachDefs)
      let response = dispatchProviderGraphRequest(pkg, request, manifest,
        buildProc, foreachDispatch, devEnvProc)
      writeProviderResponseFile(paths.responsePath, response)
      0
    except CatchableError as err:
      stderr.writeLine("repro project provider: error: " & err.msg)
      1

