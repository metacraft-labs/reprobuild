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
    if pkg.hasDevEnv:
      result.entryPoints.add(GraphEntryPointDescriptor(
        id: devEnvEntryPointId(pkg),
        kind: gpkDevEnvIntrospection,
        stableName: pkg.packageName & ":dev-env",
        bodyHash: pkg.devEnvBodyHash,
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
    resetProviderEvaluationInputRegistry()
    currentProviderProjectRoot = request.arguments
    try:
      if buildProc != nil:
        buildProc()
    finally:
      currentProviderProjectRoot = ""
    let actions = inferDeclaredActionDeps(
      registeredBuildActions(), request.arguments)
    let targets = registeredBuildTargets()
    let pools = registeredBuildPools()
    let defaultAction = registeredDefaultBuildAction()
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
    if devEnvProc == nil:
      raise newException(ValueError,
        "provider does not implement dev-env introspection")
    resetProviderEvaluationInputRegistry()
    resetDevEnvRegistry()
    currentProviderProjectRoot = request.arguments
    try:
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
    for useDef in pkg.toolUses:
      result.toolRequirements.add(DevEnvToolRequirement(
        logicalName: useDef.executableName,
        packageSelector: useDef.packageSelector,
        executableName: useDef.executableName,
        policyPath: useDef.policyPath))

  proc runPackageProvider*(pkg: PackageDef; buildProc: proc ();
                           foreachDefs: openArray[ProviderForeachDef] = [];
                           foreachDispatch: proc (
                             request: ProviderGraphRequest): GraphFragment = nil;
                           devEnvProc: proc () = nil): int {.dynOrStatic.} =
    try:
      let paths = parseProviderProtocolArgs(commandLineParams())
      let request = readProviderRequestFile(paths.requestPath)
      let manifest = providerManifest(pkg, request.providerArtifactId,
        foreachDefs)
      case request.kind
      of prkManifest:
        writeProviderResponseFile(paths.responsePath, manifestResponse(manifest))
      of prkGraphInvocation:
        if request.entryPointId == rootEntryPointId(pkg):
          writeProviderResponseFile(paths.responsePath,
            graphResponse(manifest, buildPackageFragment(pkg, request, buildProc)))
        elif foreachDispatch != nil:
          writeProviderResponseFile(paths.responsePath,
            graphResponse(manifest, foreachDispatch(request)))
        else:
          stderr.writeLine("unknown provider entry point: " & request.entryPointId)
          return 2
      of prkDevEnvIntrospection:
        if request.entryPointId == devEnvEntryPointId(pkg):
          writeProviderResponseFile(paths.responsePath,
            devEnvResponse(manifest, buildPackageDevEnv(pkg, request,
              devEnvProc)))
        else:
          stderr.writeLine("unknown provider dev-env entry point: " &
            request.entryPointId)
          return 2
      0
    except CatchableError as err:
      stderr.writeLine("repro project provider: error: " & err.msg)
      1

