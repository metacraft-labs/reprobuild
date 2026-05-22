import std/[algorithm, os, osproc, sets, streams, strutils, tables, times]

import repro_core
import repro_hash
import repro_provider_runtime/codec
import repro_provider_runtime/types

type
  InvocationPlan = object
    entryPointId: string
    entryPointBodyHash: string
    arguments: string
    namespace: string
    reason: GraphInvocationReason

proc raiseRuntime(message: string) {.noreturn.} =
  raise newException(ProviderRuntimeError, message)

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestHex(payload: openArray[byte]): string =
  toHex(blake3DomainDigest(payload, hdMetadataEnvelope).bytes)

proc digestText(text: string): string =
  digestHex(toBytes(text))

proc argumentDigest*(arguments: string): string =
  digestText(arguments)

proc graphInvocationKey*(providerArtifactId, entryPointId, entryPointBodyHash,
                         arguments, lockSliceId, activity, namespace: string):
    string =
  providerArtifactId & "|" & entryPointId & "|" & entryPointBodyHash & "|" &
    argumentDigest(arguments) & "|" & lockSliceId & "|" & activity & "|" &
    namespace

proc computeGraphFragmentDigest*(fragment: GraphFragment): string =
  digestHex(encodeFragmentForDigest(fragment))

proc readProviderRequestFile*(path: string): ProviderGraphRequest =
  decodeProviderRequest(fromByteString(readFile(extendedPath(path))))

proc writeProviderRequestFile*(path: string; request: ProviderGraphRequest) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProviderRequest(request)))

proc readProviderResponseFile*(path: string): ProviderGraphResponse =
  decodeProviderResponse(fromByteString(readFile(extendedPath(path))))

proc writeProviderResponseFile*(path: string; response: ProviderGraphResponse) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProviderResponse(response)))

proc providerSnapshotPath*(storeRoot: string): string =
  storeRoot / "provider-fragments.rbsz"

proc loadProviderGraphSnapshot*(storeRoot: string): ProviderGraphSnapshot =
  let path = providerSnapshotPath(storeRoot)
  if not fileExists(extendedPath(path)):
    return ProviderGraphSnapshot()
  decodeProviderSnapshot(fromByteString(readFile(extendedPath(path))))

proc saveProviderGraphSnapshot*(storeRoot: string; snapshot: ProviderGraphSnapshot) =
  createDir(extendedPath(storeRoot))
  let path = providerSnapshotPath(storeRoot)
  let tmp = storeRoot / ("provider-fragments." & $getCurrentProcessId() & "." &
    $epochTime() & ".tmp")
  writeFile(extendedPath(tmp), toByteString(encodeProviderSnapshot(snapshot)))
  if fileExists(extendedPath(path)):
    removeFile(extendedPath(path))
  moveFile(extendedPath(tmp), extendedPath(path))

proc parseProviderProtocolArgs*(args: openArray[string]):
    tuple[requestPath: string; responsePath: string] =
  var i = 0
  while i < args.len:
    case args[i]
    of "--repro-provider-request":
      inc i
      if i >= args.len:
        raiseRuntime("missing value for --repro-provider-request")
      result.requestPath = args[i]
    of "--repro-provider-response":
      inc i
      if i >= args.len:
        raiseRuntime("missing value for --repro-provider-response")
      result.responsePath = args[i]
    else:
      discard
    inc i
  if result.requestPath.len == 0 or result.responsePath.len == 0:
    raiseRuntime("provider protocol request/response arguments are required")

proc runProviderProtocol*(config: ProviderExecutionConfig;
                          request: ProviderGraphRequest): ProviderGraphResponse =
  if config.binaryPath.len == 0:
    raiseRuntime("provider binary path is required")
  let tempRoot =
    if config.tempRoot.len > 0: config.tempRoot
    else: getTempDir()
  createDir(extendedPath(tempRoot))
  let stem = "repro-provider-" & $getCurrentProcessId() & "-" & $epochTime()
  let requestPath = tempRoot / (stem & ".request.rbpg")
  let responsePath = tempRoot / (stem & ".response.rbpg")
  defer:
    if fileExists(extendedPath(requestPath)):
      removeFile(extendedPath(requestPath))
    if fileExists(extendedPath(responsePath)):
      removeFile(extendedPath(responsePath))

  writeProviderRequestFile(requestPath, request)

  let tracePath = getEnv("REPRO_PROVIDER_TRACE")
  if tracePath.len > 0:
    createDir(extendedPath(tracePath.splitPath.head))
    var handle = open(extendedPath(tracePath), fmAppend)
    try:
      handle.writeLine(($request.kind) & "|" & request.entryPointId & "|" &
        request.arguments & "|" & $request.reason)
    finally:
      handle.close()

  let cwd =
    if config.workingDir.len > 0: config.workingDir
    else: getCurrentDir()
  let providerArgs = config.extraArgs & @[
    "--repro-provider-request", requestPath,
    "--repro-provider-response", responsePath]
  let process = startProcess(config.binaryPath, workingDir = cwd,
    args = providerArgs, options = {poUsePath, poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let exitCode = waitForExit(process)
  close(process)
  if exitCode != 0:
    raiseRuntime("provider exited with code " & $exitCode & ": " & output)
  if not fileExists(extendedPath(responsePath)):
    raiseRuntime("provider did not write a response file")
  readProviderResponseFile(responsePath)

proc manifestById(manifest: ProviderManifest):
    Table[string, GraphEntryPointDescriptor] =
  for descriptor in manifest.entryPoints:
    result[descriptor.id] = descriptor

proc validateManifest(manifest: ProviderManifest; expectedArtifactId: string) =
  if manifest.protocolVersion != ProviderProtocolVersion:
    raiseRuntime("unsupported provider protocol version " &
      $manifest.protocolVersion)
  if expectedArtifactId.len > 0 and manifest.providerArtifactId != expectedArtifactId:
    raiseRuntime("provider manifest artifact mismatch: expected " &
      expectedArtifactId & ", got " & manifest.providerArtifactId)
  var seen = initHashSet[string]()
  for descriptor in manifest.entryPoints:
    if descriptor.id.len == 0:
      raiseRuntime("provider manifest entry point id is required")
    if descriptor.bodyHash.len == 0:
      raiseRuntime("provider manifest body hash is required for " &
        descriptor.id)
    if seen.contains(descriptor.id):
      raiseRuntime("duplicate provider manifest entry point: " & descriptor.id)
    seen.incl(descriptor.id)

proc readProviderManifest*(config: ProviderExecutionConfig;
                           providerArtifactId: string): ProviderManifest =
  let response = runProviderProtocol(config, ProviderGraphRequest(
    kind: prkManifest,
    providerArtifactId: providerArtifactId,
    reason: girExplicitUserRequest))
  if response.kind != pskManifest:
    raiseRuntime("provider manifest request returned a graph result")
  validateManifest(response.manifest, providerArtifactId)
  response.manifest

proc namespacePrefix(namespace: string): string =
  if namespace.len == 0: ""
  else: namespace & ":"

proc effectKey(claim: OwnedEffectClaim): string =
  $claim.kind & "|" & claim.identity & "|" & claim.stableName

proc edgeKey(edge: GraphEdge): string =
  edge.id & "|" & $edge.kind & "|" & edge.fromNode & "|" & edge.toNode

proc validateFragment(fragment: GraphFragment; request: ProviderGraphRequest;
                      manifest: ProviderManifest) =
  if fragment.entryPointId != request.entryPointId:
    raiseRuntime("provider response entry point mismatch")
  if fragment.entryPointBodyHash != request.entryPointBodyHash:
    raiseRuntime("provider response body hash mismatch")
  if fragment.arguments != request.arguments:
    raiseRuntime("provider response arguments mismatch")
  if fragment.namespace != request.namespace:
    raiseRuntime("provider response namespace mismatch")
  if fragment.fragmentDigest.len == 0:
    raiseRuntime("provider response is missing a fragment digest")
  let expectedDigest = computeGraphFragmentDigest(fragment)
  if fragment.fragmentDigest != expectedDigest:
    raiseRuntime("provider response fragment digest mismatch")

  let descriptors = manifestById(manifest)
  if not descriptors.hasKey(fragment.entryPointId):
    raiseRuntime("provider response names an entry point not present in manifest")
  if descriptors[fragment.entryPointId].bodyHash != fragment.entryPointBodyHash:
    raiseRuntime("provider response body hash does not match manifest")

  let prefix = namespacePrefix(fragment.namespace)
  var nodeIds = initHashSet[string]()
  for node in fragment.nodes:
    if node.id.len == 0:
      raiseRuntime("graph node id is required")
    if prefix.len > 0 and not node.id.startsWith(prefix):
      raiseRuntime("graph node outside authorized namespace: " & node.id)
    if nodeIds.contains(node.id):
      raiseRuntime("duplicate graph node id: " & node.id)
    nodeIds.incl(node.id)

  var edgeIds = initHashSet[string]()
  for edge in fragment.edges:
    if edge.id.len == 0:
      raiseRuntime("graph edge id is required")
    if prefix.len > 0 and not edge.id.startsWith(prefix):
      raiseRuntime("graph edge outside authorized namespace: " & edge.id)
    if edgeIds.contains(edge.id):
      raiseRuntime("duplicate graph edge id: " & edge.id)
    if not nodeIds.contains(edge.fromNode) or not nodeIds.contains(edge.toNode):
      raiseRuntime("graph edge references a node outside its fragment")
    edgeIds.incl(edge.id)

  var effects = initHashSet[string]()
  for claim in fragment.effectClaims:
    let key = effectKey(claim)
    if claim.identity.len == 0:
      raiseRuntime("owned effect identity is required")
    if effects.contains(key):
      raiseRuntime("duplicate owned effect claim in fragment: " & key)
    effects.incl(key)

  for child in fragment.childEntryPoints:
    if not descriptors.hasKey(child.entryPointId):
      raiseRuntime("child entry point is not present in manifest: " &
        child.entryPointId)
    if descriptors[child.entryPointId].bodyHash != child.entryPointBodyHash:
      raiseRuntime("child entry point body hash does not match manifest")

proc invokeProviderEntryPoint*(config: ProviderExecutionConfig;
                               request: ProviderGraphRequest): ProviderGraphResponse =
  let response = runProviderProtocol(config, request)
  if response.kind != pskGraphResult:
    raiseRuntime("provider graph request returned a manifest response")
  validateManifest(response.manifest, request.providerArtifactId)
  validateFragment(response.fragment, request, response.manifest)
  response

proc fileContentDigest*(path: string): string =
  if not fileExists(extendedPath(path)):
    return "missing"
  digestHex(toBytes(readFile(extendedPath(path))))

proc directoryMemberNames*(path: string): seq[string] =
  if not dirExists(extendedPath(path)):
    return @[]
  for kind, child in walkDir(extendedPath(path)):
    if kind in {pcFile, pcDir}:
      result.add(splitPath(child).tail)
  result.sort()

proc directoryMembersDigest(members: openArray[string]): string =
  var payload: seq[byte] = @[]
  for member in members:
    payload.writeString(member)
  digestHex(payload)

proc fileReadInput*(path: string): GraphEvaluationInput =
  GraphEvaluationInput(kind: gevFileRead, identity: path,
    digest: fileContentDigest(path))

proc directoryEnumerationInput*(path, memberEntryPointId,
                                memberEntryPointBodyHash: string;
                                memberArgumentRoot = "";
                                memberNamespace = ""): GraphEvaluationInput =
  let members = directoryMemberNames(path)
  GraphEvaluationInput(
    kind: gevDirectoryEnumeration,
    identity: path,
    digest: directoryMembersDigest(members),
    directoryMembers: members,
    memberEntryPointId: memberEntryPointId,
    memberEntryPointBodyHash: memberEntryPointBodyHash,
    memberArgumentRoot: if memberArgumentRoot.len > 0: memberArgumentRoot else: path,
    memberNamespace: memberNamespace)

proc emptyProviderGraphSnapshot*(providerArtifactId: string;
                                 manifest: ProviderManifest):
    ProviderGraphSnapshot =
  ProviderGraphSnapshot(providerArtifactId: providerArtifactId,
    manifest: manifest)

proc storedFragmentFrom(fragment: GraphFragment; providerArtifactId,
                        lockSliceId, activity: string): StoredGraphFragment =
  let argDigest = argumentDigest(fragment.arguments)
  StoredGraphFragment(
    invocationKey: graphInvocationKey(providerArtifactId, fragment.entryPointId,
      fragment.entryPointBodyHash, fragment.arguments, lockSliceId, activity,
      fragment.namespace),
    providerArtifactId: providerArtifactId,
    entryPointId: fragment.entryPointId,
    entryPointBodyHash: fragment.entryPointBodyHash,
    arguments: fragment.arguments,
    argumentDigest: argDigest,
    lockSliceId: lockSliceId,
    activity: activity,
    namespace: fragment.namespace,
    fragmentDigest: fragment.fragmentDigest,
    nodes: fragment.nodes,
    edges: fragment.edges,
    effectClaims: fragment.effectClaims,
    childEntryPoints: fragment.childEntryPoints,
    evaluationInputs: fragment.evaluationInputs)

proc reusableIndex(snapshot: ProviderGraphSnapshot;
                   fragment: StoredGraphFragment): int =
  for i, existing in snapshot.fragments:
    if existing.invocationKey == fragment.invocationKey:
      return i
  for i, existing in snapshot.fragments:
    if existing.entryPointId == fragment.entryPointId and
        existing.arguments == fragment.arguments and
        existing.namespace == fragment.namespace and
        existing.activity == fragment.activity:
      return i
  -1

proc recordReplacement(report: var ProviderRefreshReport;
                       oldFragment, newFragment: StoredGraphFragment) =
  if oldFragment.fragmentDigest == newFragment.fragmentDigest:
    report.earlyCutoffs.add(newFragment.invocationKey)

  var newEffects = initHashSet[string]()
  for claim in newFragment.effectClaims:
    newEffects.incl(effectKey(claim))
  for claim in oldFragment.effectClaims:
    if not newEffects.contains(effectKey(claim)):
      report.staleEffects.add(StaleOwnedEffect(
        invocationKey: oldFragment.invocationKey,
        claim: claim))

  var newEdges = initHashSet[string]()
  for edge in newFragment.edges:
    newEdges.incl(edgeKey(edge))
  for edge in oldFragment.edges:
    if not newEdges.contains(edgeKey(edge)):
      report.staleEdges.add(StaleOwnedEdge(
        invocationKey: oldFragment.invocationKey,
        edge: edge))

proc applyStoredFragment(snapshot: var ProviderGraphSnapshot;
                         report: var ProviderRefreshReport;
                         fragment: StoredGraphFragment) =
  let index = reusableIndex(snapshot, fragment)
  if index >= 0:
    recordReplacement(report, snapshot.fragments[index], fragment)
    snapshot.fragments[index] = fragment
  else:
    snapshot.fragments.add(fragment)

proc findFragmentByEntryArgs(snapshot: ProviderGraphSnapshot; entryPointId,
                             arguments, namespace: string): int =
  for i, fragment in snapshot.fragments:
    if fragment.entryPointId == entryPointId and
        fragment.arguments == arguments and
        fragment.namespace == namespace:
      return i
  -1

proc pruneFragmentAt(snapshot: var ProviderGraphSnapshot;
                     report: var ProviderRefreshReport; index: int) =
  if index < 0 or index >= snapshot.fragments.len:
    return
  let removed = snapshot.fragments[index]
  snapshot.fragments.delete(index)
  report.prunedInvocationKeys.add(removed.invocationKey)
  for claim in removed.effectClaims:
    report.staleEffects.add(StaleOwnedEffect(
      invocationKey: removed.invocationKey,
      claim: claim))
  for edge in removed.edges:
    report.staleEdges.add(StaleOwnedEdge(
      invocationKey: removed.invocationKey,
      edge: edge))
  for child in removed.childEntryPoints:
    let childIndex = findFragmentByEntryArgs(snapshot, child.entryPointId,
      child.arguments, child.namespace)
    if childIndex >= 0:
      pruneFragmentAt(snapshot, report, childIndex)

proc ensureNoDuplicateEffects(snapshot: ProviderGraphSnapshot) =
  var owners = initTable[string, string]()
  for fragment in snapshot.fragments:
    for claim in fragment.effectClaims:
      let key = $claim.kind & "|" & claim.identity
      if owners.hasKey(key) and owners[key] != fragment.invocationKey:
        raiseRuntime("duplicate live owned effect claim: " & key)
      owners[key] = fragment.invocationKey

proc currentDescriptor(manifest: ProviderManifest; entryPointId: string):
    tuple[found: bool; descriptor: GraphEntryPointDescriptor] =
  let descriptors = manifestById(manifest)
  if descriptors.hasKey(entryPointId):
    (found: true, descriptor: descriptors[entryPointId])
  else:
    (found: false, descriptor: GraphEntryPointDescriptor())

proc execConfig(config: RefreshConfig): ProviderExecutionConfig =
  ProviderExecutionConfig(
    binaryPath: config.providerBinaryPath,
    extraArgs: config.providerExtraArgs,
    workingDir: if config.providerWorkingDir.len > 0:
      config.providerWorkingDir else: getCurrentDir(),
    tempRoot: config.storeRoot / "tmp")

proc enqueue(plans: var seq[InvocationPlan]; planKeys: var HashSet[string];
             plan: InvocationPlan) =
  let key = plan.entryPointId & "|" & plan.arguments & "|" & plan.namespace
  if not planKeys.contains(key):
    plans.add(plan)
    planKeys.incl(key)

proc memberArgument(input: GraphEvaluationInput; member: string): string =
  let root =
    if input.memberArgumentRoot.len > 0: input.memberArgumentRoot
    else: input.identity
  root / member

proc childSpecForMember(input: GraphEvaluationInput; member: string;
                        descriptor: GraphEntryPointDescriptor;
                        ownerNamespace: string): GraphEntryPointInvocationSpec =
  let ns =
    if input.memberNamespace.len > 0: input.memberNamespace
    else: ownerNamespace
  GraphEntryPointInvocationSpec(
    entryPointId: input.memberEntryPointId,
    entryPointBodyHash: descriptor.bodyHash,
    arguments: memberArgument(input, member),
    namespace: ns,
    stableName: descriptor.stableName & ":" & member)

proc addChildSpec(owner: var StoredGraphFragment;
                  child: GraphEntryPointInvocationSpec) =
  for existing in owner.childEntryPoints:
    if existing.entryPointId == child.entryPointId and
        existing.arguments == child.arguments and
        existing.namespace == child.namespace:
      return
  owner.childEntryPoints.add(child)

proc removeChildSpec(owner: var StoredGraphFragment; entryPointId, arguments,
                     namespace: string) =
  var kept: seq[GraphEntryPointInvocationSpec] = @[]
  for child in owner.childEntryPoints:
    if child.entryPointId == entryPointId and child.arguments == arguments and
        child.namespace == namespace:
      discard
    else:
      kept.add(child)
  owner.childEntryPoints = kept

proc refreshStoredBindings(snapshot: var ProviderGraphSnapshot;
                           manifest: ProviderManifest) =
  let descriptors = manifestById(manifest)
  for i in 0 ..< snapshot.fragments.len:
    for j in 0 ..< snapshot.fragments[i].evaluationInputs.len:
      let entryPointId = snapshot.fragments[i].evaluationInputs[j].memberEntryPointId
      if entryPointId.len > 0 and descriptors.hasKey(entryPointId):
        snapshot.fragments[i].evaluationInputs[j].memberEntryPointBodyHash =
          descriptors[entryPointId].bodyHash
    for j in 0 ..< snapshot.fragments[i].childEntryPoints.len:
      let entryPointId = snapshot.fragments[i].childEntryPoints[j].entryPointId
      if descriptors.hasKey(entryPointId):
        snapshot.fragments[i].childEntryPoints[j].entryPointBodyHash =
          descriptors[entryPointId].bodyHash

proc updateDirectoryInput(owner: var StoredGraphFragment; inputIndex: int;
                          members: seq[string]; bodyHash: string) =
  owner.evaluationInputs[inputIndex].directoryMembers = members
  owner.evaluationInputs[inputIndex].digest = directoryMembersDigest(members)
  owner.evaluationInputs[inputIndex].memberEntryPointBodyHash = bodyHash

proc handleDirectoryChanges(config: RefreshConfig; manifest: ProviderManifest;
                            snapshot: var ProviderGraphSnapshot;
                            report: var ProviderRefreshReport;
                            plans: var seq[InvocationPlan];
                            planKeys: var HashSet[string];
                            rootNeedsRerun: var bool) =
  let descriptors = manifestById(manifest)
  var ownerIndex = 0
  while ownerIndex < snapshot.fragments.len:
    var inputIndex = 0
    while inputIndex < snapshot.fragments[ownerIndex].evaluationInputs.len:
      let input = snapshot.fragments[ownerIndex].evaluationInputs[inputIndex]
      if input.kind != gevDirectoryEnumeration:
        inc inputIndex
        continue
      let currentMembers = directoryMemberNames(input.identity)
      var added: seq[string] = @[]
      var removed: seq[string] = @[]
      for member in currentMembers:
        if input.directoryMembers.find(member) < 0:
          added.add(member)
      for member in input.directoryMembers:
        if currentMembers.find(member) < 0:
          removed.add(member)
      if added.len == 0 and removed.len == 0:
        inc inputIndex
        continue
      if input.memberEntryPointId.len == 0 or
          not descriptors.hasKey(input.memberEntryPointId):
        rootNeedsRerun = true
        inc inputIndex
        continue

      let descriptor = descriptors[input.memberEntryPointId]
      for member in removed:
        let spec = childSpecForMember(input, member, descriptor,
          snapshot.fragments[ownerIndex].namespace)
        let fragmentIndex = findFragmentByEntryArgs(snapshot, spec.entryPointId,
          spec.arguments, spec.namespace)
        if fragmentIndex >= 0:
          pruneFragmentAt(snapshot, report, fragmentIndex)
          if ownerIndex >= snapshot.fragments.len:
            break
        if ownerIndex < snapshot.fragments.len:
          removeChildSpec(snapshot.fragments[ownerIndex], spec.entryPointId,
            spec.arguments, spec.namespace)

      if ownerIndex >= snapshot.fragments.len:
        break

      for member in added:
        let spec = childSpecForMember(input, member, descriptor,
          snapshot.fragments[ownerIndex].namespace)
        addChildSpec(snapshot.fragments[ownerIndex], spec)
        enqueue(plans, planKeys, InvocationPlan(
          entryPointId: spec.entryPointId,
          entryPointBodyHash: spec.entryPointBodyHash,
          arguments: spec.arguments,
          namespace: spec.namespace,
          reason: girDirectoryMembershipChanged))

      updateDirectoryInput(snapshot.fragments[ownerIndex], inputIndex,
        currentMembers, descriptor.bodyHash)
      inc inputIndex
    inc ownerIndex

proc executePlan(config: RefreshConfig; provider: ProviderExecutionConfig;
                 manifest: ProviderManifest; snapshot: var ProviderGraphSnapshot;
                 report: var ProviderRefreshReport; plan: InvocationPlan):
    StoredGraphFragment =
  let request = ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: config.providerArtifactId,
    entryPointId: plan.entryPointId,
    entryPointBodyHash: plan.entryPointBodyHash,
    reason: plan.reason,
    arguments: plan.arguments,
    namespace: plan.namespace,
    lockSliceId: config.lockSliceId,
    activity: config.activity)
  let response = invokeProviderEntryPoint(provider, request)
  if response.manifest.entryPoints != manifest.entryPoints:
    raiseRuntime("provider manifest changed during refresh")
  report.invoked.add(ProviderInvocationRecord(
    entryPointId: plan.entryPointId,
    arguments: plan.arguments,
    reason: plan.reason))
  result = storedFragmentFrom(response.fragment, config.providerArtifactId,
    config.lockSliceId, config.activity)
  applyStoredFragment(snapshot, report, result)

proc runRootAndChildren(config: RefreshConfig; provider: ProviderExecutionConfig;
                        manifest: ProviderManifest;
                        snapshot: var ProviderGraphSnapshot;
                        report: var ProviderRefreshReport;
                        reason: GraphInvocationReason) =
  let root = currentDescriptor(manifest, config.rootEntryPointId)
  if not root.found:
    raiseRuntime("root entry point is missing from provider manifest")
  let rootStored = executePlan(config, provider, manifest, snapshot, report,
    InvocationPlan(
      entryPointId: root.descriptor.id,
      entryPointBodyHash: root.descriptor.bodyHash,
      arguments: config.rootArguments,
      namespace: config.namespace,
      reason: reason))
  for child in rootStored.childEntryPoints:
    discard executePlan(config, provider, manifest, snapshot, report, InvocationPlan(
      entryPointId: child.entryPointId,
      entryPointBodyHash: child.entryPointBodyHash,
      arguments: child.arguments,
      namespace: child.namespace,
      reason: girNoPriorFragment))

proc detectBodyHashChanges(config: RefreshConfig; manifest: ProviderManifest;
                           snapshot: var ProviderGraphSnapshot;
                           report: var ProviderRefreshReport;
                           plans: var seq[InvocationPlan];
                           planKeys: var HashSet[string];
                           rootNeedsRerun: var bool) =
  var i = 0
  while i < snapshot.fragments.len:
    let fragment = snapshot.fragments[i]
    let descriptor = currentDescriptor(manifest, fragment.entryPointId)
    if not descriptor.found:
      if fragment.entryPointId == config.rootEntryPointId:
        raiseRuntime("stored root entry point is absent from provider manifest")
      pruneFragmentAt(snapshot, report, i)
      continue
    if descriptor.descriptor.bodyHash != fragment.entryPointBodyHash:
      if fragment.entryPointId == config.rootEntryPointId:
        rootNeedsRerun = true
      else:
        enqueue(plans, planKeys, InvocationPlan(
          entryPointId: fragment.entryPointId,
          entryPointBodyHash: descriptor.descriptor.bodyHash,
          arguments: fragment.arguments,
          namespace: fragment.namespace,
          reason: girEntryPointBodyChanged))
    inc i

proc detectEvaluationInputChanges(manifest: ProviderManifest;
                                  snapshot: ProviderGraphSnapshot;
                                  plans: var seq[InvocationPlan];
                                  planKeys: var HashSet[string]) =
  for fragment in snapshot.fragments:
    var changed = false
    for input in fragment.evaluationInputs:
      case input.kind
      of gevFileRead:
        if fileContentDigest(input.identity) != input.digest:
          changed = true
      of gevDirectoryEnumeration:
        discard
      else:
        discard
    if changed:
      let descriptor = currentDescriptor(manifest, fragment.entryPointId)
      if descriptor.found:
        enqueue(plans, planKeys, InvocationPlan(
          entryPointId: fragment.entryPointId,
          entryPointBodyHash: descriptor.descriptor.bodyHash,
          arguments: fragment.arguments,
          namespace: fragment.namespace,
          reason: girEvaluationInputChanged))

proc refreshProviderGraph*(config: RefreshConfig): ProviderRefreshReport =
  result.persistedSnapshotPath = providerSnapshotPath(config.storeRoot)
  let provider = execConfig(config)
  var snapshot = loadProviderGraphSnapshot(config.storeRoot)

  if snapshot.fragments.len > 0 and
      snapshot.providerArtifactId == config.providerArtifactId:
    let manifest = snapshot.manifest
    validateManifest(manifest, config.providerArtifactId)
    refreshStoredBindings(snapshot, manifest)

    var plans: seq[InvocationPlan] = @[]
    var planKeys = initHashSet[string]()
    var rootNeedsRerun = false

    handleDirectoryChanges(config, manifest, snapshot, result, plans, planKeys,
      rootNeedsRerun)
    detectEvaluationInputChanges(manifest, snapshot, plans, planKeys)

    if rootNeedsRerun:
      runRootAndChildren(config, provider, manifest, snapshot, result,
        girDirectoryMembershipChanged)
    else:
      for plan in plans:
        discard executePlan(config, provider, manifest, snapshot, result, plan)

    ensureNoDuplicateEffects(snapshot)
    if plans.len > 0 or rootNeedsRerun or result.prunedInvocationKeys.len > 0 or
        result.staleEffects.len > 0 or result.staleEdges.len > 0:
      saveProviderGraphSnapshot(config.storeRoot, snapshot)
    result.snapshot = snapshot
    return

  let manifest = readProviderManifest(provider, config.providerArtifactId)
  validateManifest(manifest, config.providerArtifactId)

  if snapshot.fragments.len == 0:
    snapshot = emptyProviderGraphSnapshot(config.providerArtifactId, manifest)
    runRootAndChildren(config, provider, manifest, snapshot, result,
      girColdStart)
    ensureNoDuplicateEffects(snapshot)
    saveProviderGraphSnapshot(config.storeRoot, snapshot)
    result.snapshot = snapshot
    return

  snapshot.providerArtifactId = config.providerArtifactId
  snapshot.manifest = manifest
  refreshStoredBindings(snapshot, manifest)

  var plans: seq[InvocationPlan] = @[]
  var planKeys = initHashSet[string]()
  var rootNeedsRerun = false

  handleDirectoryChanges(config, manifest, snapshot, result, plans, planKeys,
    rootNeedsRerun)
  detectBodyHashChanges(config, manifest, snapshot, result, plans, planKeys,
    rootNeedsRerun)
  detectEvaluationInputChanges(manifest, snapshot, plans, planKeys)

  if rootNeedsRerun:
    runRootAndChildren(config, provider, manifest, snapshot, result,
      girEntryPointBodyChanged)
  else:
    for plan in plans:
      discard executePlan(config, provider, manifest, snapshot, result, plan)

  ensureNoDuplicateEffects(snapshot)
  saveProviderGraphSnapshot(config.storeRoot, snapshot)
  result.snapshot = snapshot
