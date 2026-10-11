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
    # ---------------------------------------------------------------
    # Shared-Development-Services L8 — THE TYPED `service` BLOCK'S
    # FACTS, which until now reached nothing on this channel.
    #
    # L7's review recorded the gap and assigned it here: "L1-L6 lowered
    # the typed `service` block's identity and scope onto
    # `DslServiceDef`, into the `gnkService` graph node (payload v2) and
    # into the interface lift -- but NOTHING routes them into
    # `DevEnvArtifact.services`, which is the only service channel the
    # dev-session supervisor reads." The consequence was that a recipe
    # wanting a SHARED instance had to declare the service TWICE, once
    # as the typed block and once as a `servicePlaceholder`, joined by
    # name -- which would have made L9's "declared once" clause provable
    # only by contradicting it.
    #
    # STRINGS, NOT THE ENUMS. `ServiceIdentityKind` / `ServiceScope`
    # live in `repro_project_dsl`, which DEPENDS ON this library, so
    # importing them here would be a cycle. The same decision L7 took
    # for `protocol.nim` -- "the instance key and the interface snapshot
    # cross the wire as the strings `encodeServiceInstanceKey` produces"
    # -- and the words are produced by `scopeWord` / `identityKindWord`,
    # the single derivation `repro_resources/service_identity.nim`
    # already owns, so there is no third spelling to drift.
    #
    # THE EMPTY STRING MEANS UNDECLARED, for every one of them, and that
    # is the zero value on purpose: a provider built before this field
    # existed reports "" and a consumer reads "nothing was declared"
    # rather than "project scope was declared". The distinction matters
    # because `project` is also the DEFAULT scope, so a zero that
    # decoded to `project` would be indistinguishable from a recipe
    # that wrote `scope project`.
    identityKind*: string
      ## `""` (undeclared) | `"derived"` | `"stable"`.
    identityStableId*: string
      ## The declared id for `"stable"`; empty otherwise.
    scope*: string
      ## `""` (undeclared) | `"project"` | `"workspace"` | `"user"` |
      ## `"system"`.
    compatibilityMajor*: uint32
      ## L6's declared major compatibility field. `0` is UNDECLARED,
      ## which is the convention `ServiceInterfaceDef` already set.
    registrationPoints*: seq[string]
      ## Shared-Development-Services L8: the contribution-point keys
      ## this service `converge`s, fully qualified and resolved.
    registrationMembers*: seq[string]
      ## The folded members of those points, in fold order -- the things
      ## to be REGISTERED in the instance once it answers.
    registrationContributors*: seq[string]
      ## Parallel to `registrationMembers`: the contributing package of
      ## each. Two parallel lists rather than a pair list because this
      ## record crosses a positional codec, where a list of pairs is a
      ## second shape to version.
    typedCommand*: seq[string]
      ## The typed `service` block's own command line -- its
      ## `executable` followed by its `args`, each token separate.
      ##
      ## THIS IS WHAT MAKES "DECLARED ONCE" REACHABLE rather than only
      ## the identity half. With it the supervisor can launch a service
      ## the typed block declared, so a recipe no longer needs a
      ## `servicePlaceholder` to carry a command. Empty when the service
      ## declared no executable, which is the case a `servicePlaceholder`
      ## still answers.

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

proc effectKey*(claim: OwnedEffectClaim): string =
  ## Stable identity of an owned effect, used both to diff previous vs new
  ## fragments (see `recordReplacement`) and to detect whether a stale effect is
  ## still claimed by a surviving fragment (the shared-ownership guard in the
  ## output-cleanup executor). Kind is part of the key so a file and a directory
  ## with the same path are distinct effects.
  $claim.kind & "|" & claim.identity & "|" & claim.stableName

proc devEnvResponse*(manifest: ProviderManifest; devEnv: DevEnvResult;
                     diagnostics: openArray[string] = []): ProviderGraphResponse =
  ProviderGraphResponse(kind: pskDevEnvResult, manifest: manifest,
    devEnv: devEnv, diagnostics: @diagnostics)
