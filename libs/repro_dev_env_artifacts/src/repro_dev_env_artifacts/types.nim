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
  DevEnvArtifactSchemaVersion* = 1'u32
  DevEnvArtifactRequiredFeatures* = 0'u32
