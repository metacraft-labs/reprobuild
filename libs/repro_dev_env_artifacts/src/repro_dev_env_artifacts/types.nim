import cbor
import repro_provider_runtime

type
  Digest32* = array[32, byte]

  DevEnvToolProfileRef* = object
    logicalName*: string
    packageIdentity*: string
    executionProfileId*: Digest32
    realizedPrefix*: string
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
  DevEnvArtifactSchemaVersion* = 3'u32
    ## Shared-Development-Services L8 bumped this from 1 to 2 because
    ## `DevEnvServiceSummary` grew eight fields and the SSZ container is
    ## positional, so a v1 payload decoded as v2 would not be refused by
    ## the format -- it would be refused by the schema check, which is
    ## what this constant is for. A cached v1 artifact is re-evaluated
    ## rather than mis-read.
  DevEnvArtifactRequiredFeatures* = 0'u32
