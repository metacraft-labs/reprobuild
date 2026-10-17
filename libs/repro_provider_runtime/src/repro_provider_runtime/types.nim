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
    # ---------------------------------------------------------------
    # Shared-Development-Services L9 — THE SUPERVISION FACTS.
    #
    # L8 gave identity, scope, compatibility and the command a typed
    # channel; its review recorded what was left: "the `instance` block
    # and `readiness` still require a `servicePlaceholder`, so
    # 'declared once' is only PARTLY unblocked." These fields are the
    # rest, and with them `infra/repro.nim`'s `servicePlaceholder` is
    # DELETED rather than kept beside the typed block for the two facts
    # it alone could carry.
    #
    # STRINGS AND SCALARS, for `identityKind`'s reason above: the enums
    # live in `repro_project_dsl`, which is ABOVE this library, so
    # importing them here would be a cycle.
    # ---------------------------------------------------------------
    readinessKind*: string
      ## `""` (undeclared) | `"none"` | `"fileExists"` | `"httpGet"`.
      ## The empty string sends the supervisor to the placeholder's
      ## probe, which is what keeps every pre-L9 recipe unchanged.
    readinessPath*: string
    readinessUrl*: string
    readinessTimeoutMs*: int64
      ## `0` is UNDECLARED, so the supervisor's own default applies.
      ## There is no second copy of that default here to drift from it.
    workingDirectory*: string
      ## The typed `workingDirectory` — the placeholder's `cwd`.
    stateDirectories*: seq[string]
      ## The typed `stateDirectory` setters — the placeholder's
      ## `resources` directories, in declaration order.
    instanceDeclared*: bool
      ## Whether the typed `service` block carried an `instance:` block,
      ## i.e. whether this service is a SHARED instance the daemon owns.
    instanceLeaseTtlSeconds*: int64
      ## D-SS5's lease as the wire number: -1 `keep`, 0 `immediate`,
      ## n > 0 `delayed`.
    instanceEnvironment*: string
      ## The environment component of the instance key, DERIVED from the
      ## per-invocation selection (§6.4) rather than declared. The typed
      ## `instance:` block refuses an `environment` setting by name for
      ## exactly that reason.

  DevEnvDiagnostic* = object
    severity*: DevEnvDiagnosticSeverity
    message*: string
    sourceFile*: string
    sourceLine*: int

  DevEnvSourceFingerprint* = object
    kind*: string
    identity*: string
    digest*: string

  DevEnvSharedResolution* = object
    ## Shared-Development-Services D-SS11 (§4.6): one
    ## `<package>.<service>.shared(...)` call in a CONSUMER's recipe, on
    ## its way out of the evaluation that made it.
    ##
    ## This is the whole of what the cross-process contribution lane
    ## carries. §4.6: "the consumer's contributions are **arguments of
    ## the resolver call**, carried on the interface the owner already
    ## lifts, and applied by the owner's instance when it converges." The
    ## first half of that is the owner's lift (which now carries its
    ## contribution points); this record is the second half's vehicle --
    ## it takes the consumer's arguments to the consumer's `repro up`,
    ## which deposits them in the instance's identity-keyed store where
    ## the owner's converge reads them.
    ##
    ## WHY THE ARTIFACT AND NOT A DIRECT WRITE. The resolver is evaluated
    ## inside the provider process, which may not run again: a cached
    ## dev-env edge is answered from the artifact. A resolver that wrote
    ## the store itself would therefore deposit its contributions on the
    ## first `repro up` and on no later one, so a `repro down` plus
    ## `repro up` would attach WITHOUT the contributions and nothing
    ## would say so -- a construct that is declared, looks wired and
    ## works once. Carrying the record makes the deposit a function of
    ## the artifact rather than of whether the evaluation was cached.
    ##
    ## THE ENUMS CROSS AS STRINGS, as every other enum on this wire
    ## does: `repro_project_dsl` imports this library, so naming
    ## `ContributionOperation` or `EnvironmentPrecedence` here would be a
    ## cycle. The empty string means UNDECLARED and is refused by name on
    ## the reading side rather than mapped to an ordinal-0 default --
    ## ordinal 0 is `coReplace`, which is the one operation a consumer
    ## may not use, so a silent default would turn a dropped field into
    ## a destructive contribution.
    ownerPackage*: string
    serviceName*: string
    activityName*: string
    ownerRecipeDir*: string
    consumerPackage*: string
    environment*: string
      ## The environment SELECTED for the evaluation that made this
      ## resolution, derived from `selectedEnvironmentName()` -- never
      ## written by the author.
      ##
      ## §6.5 makes the environment part of the instance key, and §6.4
      ## makes its selection a per-invocation tracked input. The owner's
      ## `instance:` block derives it the same way and REFUSES an
      ## authored `environment` word for the same reason: a second
      ## answer could disagree with the selection the artifact was
      ## evaluated under. A consumer that resolved under `development`
      ## must attach to the `development` instance even if its `repro
      ## up` is invoked with nothing selected, so the value is captured
      ## at evaluation and carried rather than re-read later.
    sourceFile*: string
    sourceLine*: int64
    contributionPoints*: seq[string]
      ## One entry per CONTRIBUTION, in call order. The next three seqs
      ## are parallel to this one and a length mismatch is refused: the
      ## four were built together, so a disagreement means the record was
      ## assembled from two different reads.
    contributionOperations*: seq[string]
    contributionPrecedences*: seq[string]
    contributionSites*: seq[string]
      ## `<file>:<line>` of each contribution's own argument, for the
      ## step-4 diagnostic. Rendered rather than carried as a pair
      ## because this wire has no `seq[int64]` and a second number
      ## encoding for one fact is how the two sides drift.
    contributionMemberPoints*: seq[string]
      ## One entry per MEMBER: the point that member belongs to.
      ## Parallel to `contributionMembers`.
      ##
      ## A POINT-PER-MEMBER RATHER THAN A COUNT-PER-POINT. A count seq
      ## would need `seq[int64]`, which this codec does not have, and
      ## more importantly a wrong count mis-slices SILENTLY -- members
      ## would be attributed to the neighbouring point with nothing
      ## malformed to detect. A point name per member is self-describing:
      ## a member naming a point the record does not declare is a refusal.
    contributionMembers*: seq[string]

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
    sharedResolutions*: seq[DevEnvSharedResolution]
      ## Shared-Development-Services D-SS11 (§4.6): every resolver call
      ## this evaluation made. Appended at the END for the reason the
      ## L8 and L9 service fields were: a diff of the codec reads as an
      ## addition rather than a reshuffle.
    actions*: seq[GraphNode]
      ## Shared-Development-Services F1 (§2) — THE ACTIONS CHANNEL:
      ## every build ACTION the `devEnv:` body registered, as the
      ## `gnkAction` graph nodes the build lane already carries.
      ##
      ## WHY `seq[GraphNode]` AND NOT A NEW RECORD, which is the
      ## decision this field is. `renderConfigFile` registers a
      ## `BuildActionDef`; the build lane lowers one into a `gnkAction`
      ## node whose payload is `actionPayload`'s versioned bytes, and
      ## `GraphNode` already crosses this codec. A bespoke
      ## `DevEnvAction` record would be a SECOND representation of one
      ## action, with a second codec to version and two readings that
      ## can disagree about the same edge -- which is the shape this
      ## campaign keeps finding. One representation, two channels.
      ##
      ## L9's F1 measured the absence: "`DevEnvResult` ... has NO
      ## actions field, so an action registered while the `devEnv:` body
      ## runs reaches nothing", and the consequence end to end was
      ## `repro up --activity sso` reporting the session up with
      ## `etc/sso/` never created -- "the path reached argv and the file
      ## never did".
      ##
      ## AN ACTION NOTHING CONSUMES IS AN ERROR DIAGNOSTIC, not an
      ## absence: see `buildPackageDevEnv`. Carrying the actions without
      ## that check would move the silent drop one hop downstream rather
      ## than close it.
      ##
      ## Appended at the END, for `sharedResolutions`' reason.

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
