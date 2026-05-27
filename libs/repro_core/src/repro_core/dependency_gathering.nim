import repro_core/process_specs

type
  DependencyGatheringKind* = enum
    dgDeclaredOnly
    dgAutomaticMonitor
    dgRecognizedFormat
    dgPostBuildConverter
    dgRecognizedFormatValidatedByMonitor
    dgPostBuildConverterValidatedByMonitor
    dgNoRuntimeDependencies

  DependencyEvidenceCompleteness* = enum
    decComplete
    decIncompleteNeedsValidation
    decDiagnosticOnly

  DependencyFormatName* = distinct string

  ExpectedDependencyFile* = object
    logicalName*: string
    path*: string
    required*: bool

  RecognizedDependencyReportSpec* = object
    formatName*: DependencyFormatName
    outputs*: seq[ExpectedDependencyFile]
    completeness*: DependencyEvidenceCompleteness

  DependencyConverterOutputKind* = enum
    dcoReproPathSet
    dcoRecognizedFormat

  PostBuildDependencyConverterSpec* = object
    converterProcess*: ProcessSpec
    inputs*: seq[ExpectedDependencyFile]
    outputs*: seq[ExpectedDependencyFile]
    outputKind*: DependencyConverterOutputKind
    outputFormatName*: DependencyFormatName
    completeness*: DependencyEvidenceCompleteness

  DependencyGatheringPolicy* = object
    kind*: DependencyGatheringKind
    completeness*: DependencyEvidenceCompleteness
    recognizedReports*: seq[RecognizedDependencyReportSpec]
    postBuildConverters*: seq[PostBuildDependencyConverterSpec]
    ignoredInputPrefixes*: seq[string]

proc `$`*(name: DependencyFormatName): string =
  string(name)

proc `==`*(a, b: DependencyFormatName): bool =
  string(a) == string(b)

proc declaredOnlyPolicy*(
    ignoredInputPrefixes: openArray[string] = []): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgDeclaredOnly,
    completeness: decComplete,
    ignoredInputPrefixes: @ignoredInputPrefixes)

proc monitorValidatedPolicy*(
    reports: openArray[RecognizedDependencyReportSpec];
    ignoredInputPrefixes: openArray[string] = []): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormatValidatedByMonitor,
    completeness: decComplete,
    recognizedReports: @reports,
    ignoredInputPrefixes: @ignoredInputPrefixes)
