import std/[strutils]

import cbor
import repro_provider_runtime

import ./types

proc esc(text: string): string =
  result = newStringOfCap(text.len)
  for ch in text:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(ch)

proc q(text: string): string =
  "\"" & esc(text) & "\""

proc digestJson(digest: Digest32): string =
  result = newStringOfCap(66)
  result.add('"')
  for b in digest:
    result.add(toHex(int(b), 2).toLowerAscii())
  result.add('"')

proc stringsJson(values: openArray[string]): string =
  var parts: seq[string] = @[]
  for value in values:
    parts.add(q(value))
  "[" & parts.join(",") & "]"

proc shellOpJson(op: DevEnvShellOp): string =
  "{\"kind\":" & q($op.kind) &
    ",\"name\":" & q(op.name) &
    ",\"value\":" & q(op.value) &
    ",\"separator\":" & q(op.separator) &
    ",\"activityRequirements\":" & stringsJson(op.activityRequirements) & "}"

proc toolProfileJson(profile: DevEnvToolProfileRef): string =
  "{\"logicalName\":" & q(profile.logicalName) &
    ",\"packageIdentity\":" & q(profile.packageIdentity) &
    ",\"executionProfileId\":" & digestJson(profile.executionProfileId) &
    ",\"realizedPrefix\":" & q(profile.realizedPrefix) &
    ",\"activityRequirements\":" & stringsJson(profile.activityRequirements) & "}"

proc taskJson(task: DevEnvTaskSummary): string =
  "{\"name\":" & q(task.name) &
    ",\"description\":" & q(task.description) &
    ",\"activityRequirements\":" & stringsJson(task.activityRequirements) &
    ",\"commandRef\":" & digestJson(task.commandRef) &
    ",\"command\":" & q(task.command) & "}"

proc serviceJson(service: DevEnvServiceSummary): string =
  "{\"name\":" & q(service.name) &
    ",\"activityRequirements\":" & stringsJson(service.activityRequirements) &
    ",\"hasSupervisorPlanRef\":" & (if service.hasSupervisorPlanRef: "true" else: "false") &
    ",\"supervisorPlanRef\":" & digestJson(service.supervisorPlanRef) &
    ",\"metadata\":" & toJson(service.metadata) & "}"

proc diagnosticJson(diagnostic: DevEnvDiagnostic): string =
  "{\"severity\":" & q($diagnostic.severity) &
    ",\"message\":" & q(diagnostic.message) &
    ",\"sourceFile\":" & q(diagnostic.sourceFile) &
    ",\"sourceLine\":" & $diagnostic.sourceLine & "}"

proc inputJson(input: GraphEvaluationInput): string =
  "{\"kind\":" & q($input.kind) &
    ",\"identity\":" & q(input.identity) &
    ",\"digest\":" & q(input.digest) &
    ",\"directoryMembers\":" & stringsJson(input.directoryMembers) &
    ",\"memberEntryPointId\":" & q(input.memberEntryPointId) &
    ",\"memberEntryPointBodyHash\":" & q(input.memberEntryPointBodyHash) &
    ",\"memberArgumentRoot\":" & q(input.memberArgumentRoot) &
    ",\"memberNamespace\":" & q(input.memberNamespace) & "}"

proc sourceFingerprintJson(fp: DevEnvSourceFingerprint): string =
  "{\"kind\":" & q(fp.kind) &
    ",\"identity\":" & q(fp.identity) &
    ",\"digest\":" & q(fp.digest) & "}"

proc listJson[T](values: openArray[T]; render: proc(value: T): string): string =
  var parts: seq[string] = @[]
  for value in values:
    parts.add(render(value))
  "[" & parts.join(",") & "]"

proc digestsJson(values: openArray[Digest32]): string =
  var parts: seq[string] = @[]
  for value in values:
    parts.add(digestJson(value))
  "[" & parts.join(",") & "]"

proc toJsonInspection*(artifact: DevEnvArtifact): string =
  "{\"kind\":\"DevEnvArtifact\"" &
    ",\"schemaVersion\":" & $artifact.schemaVersion &
    ",\"artifactId\":" & digestJson(artifact.artifactId) &
    ",\"providerArtifactId\":" & digestJson(artifact.providerArtifactId) &
    ",\"providerArtifactIdText\":" & q(artifact.providerArtifactIdText) &
    ",\"providerEntryPointId\":" & digestJson(artifact.providerEntryPointId) &
    ",\"providerEntryPointName\":" & q(artifact.providerEntryPointName) &
    ",\"providerEntryPointBodyHash\":" & digestJson(artifact.providerEntryPointBodyHash) &
    ",\"providerEntryPointBodyHashText\":" & q(artifact.providerEntryPointBodyHashText) &
    ",\"projectRootDigest\":" & digestJson(artifact.projectRootDigest) &
    ",\"projectRoot\":" & q(artifact.projectRoot) &
    ",\"lockSliceId\":" & digestJson(artifact.lockSliceId) &
    ",\"lockSliceName\":" & q(artifact.lockSliceName) &
    ",\"activitySelectionDigest\":" & digestJson(artifact.activitySelectionDigest) &
    ",\"selectedActivities\":" & stringsJson(artifact.selectedActivities) &
    ",\"declaredActivities\":" & stringsJson(artifact.declaredActivities) &
    ",\"developModeOverrideDigest\":" & digestJson(artifact.developModeOverrideDigest) &
    ",\"shellOps\":" & listJson(artifact.shellOps, shellOpJson) &
    ",\"toolProfiles\":" & listJson(artifact.toolProfiles, toolProfileJson) &
    ",\"tasks\":" & listJson(artifact.tasks, taskJson) &
    ",\"services\":" & listJson(artifact.services, serviceJson) &
    ",\"resourcePrerequisites\":" & digestsJson(artifact.resourcePrerequisites) &
    ",\"diagnostics\":" & listJson(artifact.diagnostics, diagnosticJson) &
    ",\"evaluationInputs\":" & listJson(artifact.evaluationInputs, inputJson) &
    ",\"sourceFingerprints\":" & listJson(artifact.sourceFingerprints, sourceFingerprintJson) &
    ",\"evaluationEvidenceRef\":" & digestJson(artifact.evaluationEvidenceRef) &
    ",\"providerMetadata\":" & toJson(artifact.providerMetadata) & "}"
