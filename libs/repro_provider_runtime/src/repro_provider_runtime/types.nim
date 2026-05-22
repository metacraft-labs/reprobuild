type
  ProviderRuntimeError* = object of CatchableError
  ProviderStoreError* = object of CatchableError

  ProviderRequestKind* = enum
    prkManifest
    prkGraphInvocation
    prkDevEnvIntrospection

  ProviderResponseKind* = enum
    pskManifest
    pskGraphResult
    pskDevEnvResult

  GraphEntryPointKind* = enum
    gpkProjectRoot
    gpkRecipe
    gpkStructuralIteratorBody
    gpkSharedCollectionFinalizer
    gpkRuleGenerator
    gpkTypedExecutableLowering
    gpkResourcePlan
    gpkServicePlan
    gpkDevEnvIntrospection

  GraphInvocationReason* = enum
    girColdStart
    girNoPriorFragment
    girProviderArtifactChanged
    girEntryPointBodyChanged
    girEvaluationInputChanged
    girDirectoryMembershipChanged
    girLockOrConfigChanged
    girExplicitUserRequest

  GraphEvaluationInputKind* = enum
    gevFileRead
    gevDirectoryEnumeration
    gevProviderSource
    gevImportedInterfaceArtifact
    gevLockSlice
    gevResolvedConfigCell
    gevHostFact
    gevStaticPackageMetadata
    gevProviderDependencyResult
    gevDevelopModeOverride
    gevActivitySelection

  GraphNodeKind* = enum
    gnkAction
    gnkGeneratedOutput
    gnkDirectoryEnumeration
    gnkRuleGenerator
    gnkFinalizer
    gnkResource
    gnkService
    gnkMetadata

  GraphEdgeKind* = enum
    gekDependsOn
    gekProduces
    gekConsumes
    gekOrdersBefore
    gekInvalidates

  OwnedEffectKind* = enum
    oekFile
    oekDirectory
    oekOpaqueDirectoryMember
    oekService
    oekSystemUser
    oekDatabase
    oekResource

  CleanupPolicy* = enum
    cplDeleteWhenUnclaimed
    cplKeepAsGarbageCollectable
    cplRequireExplicitDestroy
    cplNeverDeleteAutomatically

  GraphEntryPointDescriptor* = object
    id*: string
    kind*: GraphEntryPointKind
    stableName*: string
    bodyHash*: string
    argumentSchemaId*: string
    outputSchemaId*: string

  ProviderManifest* = object
    providerArtifactId*: string
    protocolVersion*: uint32
    entryPoints*: seq[GraphEntryPointDescriptor]

  GraphNode* = object
    id*: string
    kind*: GraphNodeKind
    stableName*: string
    payload*: string

  GraphEdge* = object
    id*: string
    kind*: GraphEdgeKind
    fromNode*: string
    toNode*: string

  OwnedEffectClaim* = object
    kind*: OwnedEffectKind
    stableName*: string
    identity*: string
    cleanupPolicy*: CleanupPolicy
    payload*: string

  GraphEntryPointInvocationSpec* = object
    entryPointId*: string
    entryPointBodyHash*: string
    arguments*: string
    namespace*: string
    stableName*: string

  GraphEvaluationInput* = object
    kind*: GraphEvaluationInputKind
    identity*: string
    digest*: string
    directoryMembers*: seq[string]
    memberEntryPointId*: string
    memberEntryPointBodyHash*: string
    memberArgumentRoot*: string
    memberNamespace*: string

  GraphFragment* = object
    entryPointId*: string
    entryPointBodyHash*: string
    arguments*: string
    namespace*: string
    nodes*: seq[GraphNode]
    edges*: seq[GraphEdge]
    effectClaims*: seq[OwnedEffectClaim]
    childEntryPoints*: seq[GraphEntryPointInvocationSpec]
    evaluationInputs*: seq[GraphEvaluationInput]
    fragmentDigest*: string

  DevEnvShellOpKind* = enum
    deskSetEnv
    deskUnsetEnv
    deskPrependPath
    deskAppendPath
    deskSetPathList
    deskSetWorkingDirectory

  DevEnvDiagnosticSeverity* = enum
    dedsInfo
    dedsWarning
    dedsError

  DevEnvShellOp* = object
    kind*: DevEnvShellOpKind
    name*: string
    value*: string
    separator*: string
    activityRequirements*: seq[string]

  DevEnvToolRequirement* = object
    logicalName*: string
    packageSelector*: string
    executableName*: string
    policyPath*: seq[string]
    activityRequirements*: seq[string]

  DevEnvTaskMetadata* = object
    name*: string
    description*: string
    command*: string
    activityRequirements*: seq[string]

  DevEnvServiceMetadata* = object
    name*: string
    activityRequirements*: seq[string]
    metadata*: string

  DevEnvDiagnostic* = object
    severity*: DevEnvDiagnosticSeverity
    message*: string
    sourceFile*: string
    sourceLine*: int

  DevEnvSourceFingerprint* = object
    kind*: string
    identity*: string
    digest*: string

  DevEnvResult* = object
    schemaVersion*: uint32
    providerArtifactId*: string
    providerEntryPointId*: string
    providerEntryPointBodyHash*: string
    projectRoot*: string
    lockSliceId*: string
    selectedActivities*: seq[string]
    declaredActivities*: seq[string]
    shellOps*: seq[DevEnvShellOp]
    toolRequirements*: seq[DevEnvToolRequirement]
    tasks*: seq[DevEnvTaskMetadata]
    services*: seq[DevEnvServiceMetadata]
    diagnostics*: seq[DevEnvDiagnostic]
    evaluationInputs*: seq[GraphEvaluationInput]
    sourceFingerprints*: seq[DevEnvSourceFingerprint]

  ProviderGraphRequest* = object
    kind*: ProviderRequestKind
    providerArtifactId*: string
    entryPointId*: string
    entryPointBodyHash*: string
    reason*: GraphInvocationReason
    arguments*: string
    namespace*: string
    lockSliceId*: string
    activity*: string

  ProviderGraphResponse* = object
    kind*: ProviderResponseKind
    manifest*: ProviderManifest
    fragment*: GraphFragment
    devEnv*: DevEnvResult
    diagnostics*: seq[string]

  StoredGraphFragment* = object
    invocationKey*: string
    providerArtifactId*: string
    entryPointId*: string
    entryPointBodyHash*: string
    arguments*: string
    argumentDigest*: string
    lockSliceId*: string
    activity*: string
    namespace*: string
    fragmentDigest*: string
    nodes*: seq[GraphNode]
    edges*: seq[GraphEdge]
    effectClaims*: seq[OwnedEffectClaim]
    childEntryPoints*: seq[GraphEntryPointInvocationSpec]
    evaluationInputs*: seq[GraphEvaluationInput]

  ProviderGraphSnapshot* = object
    providerArtifactId*: string
    manifest*: ProviderManifest
    fragments*: seq[StoredGraphFragment]

  ProviderExecutionConfig* = object
    binaryPath*: string
    extraArgs*: seq[string]
    workingDir*: string
    tempRoot*: string

  RefreshConfig* = object
    storeRoot*: string
    providerBinaryPath*: string
    providerArtifactId*: string
    rootEntryPointId*: string
    rootArguments*: string
    namespace*: string
    lockSliceId*: string
    activity*: string
    providerExtraArgs*: seq[string]
    providerWorkingDir*: string

  ProviderInvocationRecord* = object
    entryPointId*: string
    arguments*: string
    reason*: GraphInvocationReason

  StaleOwnedEffect* = object
    invocationKey*: string
    claim*: OwnedEffectClaim

  StaleOwnedEdge* = object
    invocationKey*: string
    edge*: GraphEdge

  ProviderRefreshReport* = object
    snapshot*: ProviderGraphSnapshot
    invoked*: seq[ProviderInvocationRecord]
    prunedInvocationKeys*: seq[string]
    staleEffects*: seq[StaleOwnedEffect]
    staleEdges*: seq[StaleOwnedEdge]
    earlyCutoffs*: seq[string]
    persistedSnapshotPath*: string

const ProviderProtocolVersion* = 1'u32

proc manifestResponse*(manifest: ProviderManifest;
                       diagnostics: openArray[string] = []): ProviderGraphResponse =
  ProviderGraphResponse(kind: pskManifest, manifest: manifest,
    diagnostics: @diagnostics)

proc graphResponse*(manifest: ProviderManifest; fragment: GraphFragment;
                    diagnostics: openArray[string] = []): ProviderGraphResponse =
  ProviderGraphResponse(kind: pskGraphResult, manifest: manifest,
    fragment: fragment, diagnostics: @diagnostics)

proc devEnvResponse*(manifest: ProviderManifest; devEnv: DevEnvResult;
                     diagnostics: openArray[string] = []): ProviderGraphResponse =
  ProviderGraphResponse(kind: pskDevEnvResult, manifest: manifest,
    devEnv: devEnv, diagnostics: @diagnostics)
