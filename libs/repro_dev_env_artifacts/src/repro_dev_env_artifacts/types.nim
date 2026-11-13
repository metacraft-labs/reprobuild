import cbor
import repro_provider_runtime

type
  Digest32* = array[32, byte]

  DevEnvToolProfileRef* = object
    logicalName*: string
    packageIdentity*: string
    executionProfileId*: Digest32
    policyPath*: string
      ## The `uses:` nesting policy path the tool was declared under, its
      ## segments joined with ":" (`lint:` → `strict:` → "lint:strict"); empty
      ## for a top-level `uses:` entry.
      ##
      ## It is NOT where the tool was realized. The artifact is produced, and
      ## cached by content, before activation realizes any tool, so it holds
      ## no prefix: the realized prefix appears only in the activated PATH. The field was once named `realizedPrefix`, and the
      ## empty value every top-level tool carried was read as "nothing was
      ## realized".
    activityRequirements*: seq[string]

  DevEnvTaskSummary* = object
    name*: string
    description*: string
    activityRequirements*: seq[string]
    commandRef*: Digest32
    command*: string

  DevEnvServiceSummary* = object
    name*: string
    activityRequirements*: seq[string]
    supervisorPlanRef*: Digest32
    hasSupervisorPlanRef*: bool
    metadata*: DynamicValue
    # Shared-Development-Services L8: the typed `service` block's facts.
    # L7's review measured that this record "carries only `name`,
    # `activityRequirements`, `supervisorPlanRef`,
    # `hasSupervisorPlanRef` and `metadata`. There is no field an
    # identity or a scope could travel in, so no amount of routing on
    # the PRODUCING side closes it -- the typed interface has to reach
    # the CONSUMING path first." These fields are that channel.
    # `DevEnvServiceMetadata`'s own comment carries why they are strings
    # and why the empty string means UNDECLARED.
    identityKind*: string
    identityStableId*: string
    scope*: string
    compatibilityMajor*: uint32
    typedCommand*: seq[string]
    registrationPoints*: seq[string]
    registrationMembers*: seq[string]
    registrationContributors*: seq[string]
    # Shared-Development-Services L9: the SUPERVISION facts. L8's
    # review named what it left -- "the `instance` block and
    # `readiness` still require a `servicePlaceholder`" -- and these
    # are the rest of the channel it opened.
    # `DevEnvServiceMetadata`'s own comment carries the semantics of
    # each, including that the empty string / 0 / false mean
    # UNDECLARED and send the supervisor to the placeholder.
    readinessKind*: string
    readinessPath*: string
    readinessUrl*: string
    readinessTimeoutMs*: int64
    workingDirectory*: string
    stateDirectories*: seq[string]
    instanceDeclared*: bool
    instanceLeaseTtlSeconds*: int64
    instanceEnvironment*: string
    # Shared-Development-Services F1 (§4.8 / D-SS15), SECOND HALF: the
    # ids of the build actions whose outputs this service NAMES.
    #
    # WHY IT IS ON THE ARTIFACT AND NOT ONLY ON THE PROVIDER WIRE, which
    # is D-SS11's reason repeated for the third construct in a row: a
    # cached dev-env edge is answered FROM THE ARTIFACT without
    # re-running the provider, so an edge that lived only on the wire
    # would order the actions on a cold evaluation and silently never
    # again -- F1's own missing file, moved from the first run to the
    # second.
    #
    # `actions` alone is not enough to order anything. It says WHICH
    # actions exist; this says WHICH SERVICE each one has to be built
    # before. Without it the supervisor holds two unrelated lists.
    consumedActionIds*: seq[string]

  DevEnvActionSummary* = object
    ## Shared-Development-Services F1: one build ACTION a `devEnv:` body
    ## registered, as the ARTIFACT carries it.
    ##
    ## THE PAYLOAD IS CARRIED VERBATIM AND NOT RE-MODELLED. `payload` is
    ## the bytes `repro_project_dsl`'s `actionPayload` produced -- the
    ## same versioned action record the BUILD lane's `gnkAction` node
    ## carries -- held here as an opaque string. Re-modelling the action
    ## in this library would be a second representation of one edge,
    ## with its own version to keep in step; carrying the bytes keeps
    ## exactly one definition of what an action is, and this record adds
    ## only the identity a reader needs to address it.
    nodeId*: string
      ## The graph node id (`actionNode(namespace, actionId)`), so a
      ## caller can name the same node the build lane names.
    actionId*: string
      ## The action's own id, which is the `stableName` of its node.
    payload*: string
      ## `actionPayload`'s bytes, verbatim.

  DevEnvSharedResolutionSummary* = object
    ## Shared-Development-Services D-SS11 (§4.6): one resolver call, as
    ## the ARTIFACT carries it.
    ##
    ## Field-for-field the provider record
    ## (`repro_provider_runtime`'s `DevEnvSharedResolution`), mapped by
    ## NAME in `artifactFromDevEnvResult`. Two records rather than one
    ## for the reason `DevEnvServiceSummary` and
    ## `DevEnvServiceMetadata` are two: the provider wire and the
    ## artifact are versioned independently and this library must not
    ## depend on that one's layout.
    ##
    ## WHY IT IS ON THE ARTIFACT AT ALL. The artifact is the DURABLE
    ## answer to a dev-env edge; a cached edge is served from it without
    ## re-running the provider. A resolution that lived only on the
    ## provider wire would therefore reach `repro up` on a cold
    ## evaluation and not on a cached one, so a consumer's contributions
    ## would be deposited once and then silently stop being deposited --
    ## the exact "declared, looks wired, does nothing" shape §4.6 exists
    ## to close.
    ownerPackage*: string
    serviceName*: string
    activityName*: string
    ownerRecipeDir*: string
    consumerPackage*: string
    environment*: string
      ## The environment selected for the evaluation that resolved this
      ## service -- §6.5's third component of the instance key. Derived,
      ## never authored; see the provider record's own note.
    sourceFile*: string
    sourceLine*: int64
    contributionPoints*: seq[string]
    contributionOperations*: seq[string]
    contributionPrecedences*: seq[string]
    contributionSites*: seq[string]
    contributionMemberPoints*: seq[string]
    contributionMembers*: seq[string]

  DevEnvArtifact* = object
    schemaVersion*: uint32
    artifactId*: Digest32
    providerArtifactId*: Digest32
    providerArtifactIdText*: string
    providerEntryPointId*: Digest32
    providerEntryPointName*: string
    providerEntryPointBodyHash*: Digest32
    providerEntryPointBodyHashText*: string
    projectRootDigest*: Digest32
    projectRoot*: string
    lockSliceId*: Digest32
    lockSliceName*: string
    activitySelectionDigest*: Digest32
    selectedActivities*: seq[string]
    declaredActivities*: seq[string]
    developModeOverrideDigest*: Digest32
    shellOps*: seq[DevEnvShellOp]
    toolProfiles*: seq[DevEnvToolProfileRef]
    tasks*: seq[DevEnvTaskSummary]
    services*: seq[DevEnvServiceSummary]
    resourcePrerequisites*: seq[Digest32]
    diagnostics*: seq[DevEnvDiagnostic]
    evaluationInputs*: seq[GraphEvaluationInput]
    sourceFingerprints*: seq[DevEnvSourceFingerprint]
    evaluationEvidenceRef*: Digest32
    providerMetadata*: DynamicValue
    sharedResolutions*: seq[DevEnvSharedResolutionSummary]
      ## Shared-Development-Services D-SS11 (§4.6): every
      ## `<package>.<service>.shared(...)` call this project's recipe
      ## made.
      ##
      ## APPENDED AT THE END, after `providerMetadata`, so every field
      ## above keeps its SSZ offset and the navigator's relational
      ## assertions about the `shellOps` / `tasks` / `services` sections
      ## stay about what they claim.
    actions*: seq[DevEnvActionSummary]
      ## Shared-Development-Services F1: every build ACTION the
      ## `devEnv:` body registered.
      ##
      ## THE ARTIFACT HOP IS NOT OPTIONAL, for the reason D-SS11 records
      ## for `sharedResolutions`: a cached dev-env edge is answered FROM
      ## THE ARTIFACT without re-running the provider, so an actions
      ## channel that lived only on the provider wire would report the
      ## actions on a cold evaluation and silently never again -- and
      ## the second `repro up` would launch a service whose rendered
      ## configuration nobody produced. That is the same silent drop F1
      ## measured, moved from the first run to the second.
      ##
      ## Appended at the END, after `sharedResolutions`, for that
      ## field's own stated reason.

  DevEnvNavigatorStats* = object
    envelopeBytesChecked*: int
    payloadBytesHashed*: int
    payloadHeaderBytesRead*: int
    shellOpRecordsDecoded*: int
    taskRecordsDecoded*: int
    serviceRecordsDecoded*: int
    maxDecodedPayloadOffset*: int
    shellOpsSectionStart*: int
    shellOpsSectionEnd*: int
    tasksSectionStart*: int
    servicesSectionStart*: int

const
  DevEnvArtifactSchemaVersion* = 6'u32  # version-literal-ok: this IS
                                        # the schema version definition,
                                        # not a literal standing in for
                                        # one.
    ## Shared-Development-Services L8 bumped this from 1 to 2 because
    ## `DevEnvServiceSummary` grew eight fields and the SSZ container is
    ## positional, so a v1 payload decoded as v2 would not be refused by
    ## the format -- it would be refused by the schema check, which is
    ## what this constant is for. A cached v1 artifact is re-evaluated
    ## rather than mis-read.
    ##
    ## Shared-Development-Services F1 bumped it 4 -> 5 for the same
    ## reason one more time: the container grew an `actions` list.
    ##
    ## And F1's SECOND half bumped it 5 -> 6: `DevEnvServiceSummary`
    ## grew `consumedActionIds`, the edge from a service to the actions
    ## the dev session must build before starting it. Same positional
    ## container, same rule -- a v5 artifact is re-evaluated rather
    ## than read with shifted offsets.
  DevEnvArtifactRequiredFeatures* = 0'u32
