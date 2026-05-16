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

  PostBuildDependencyConverterSpec* = object
    converterPath*: string
    args*: seq[string]
    outputs*: seq[ExpectedDependencyFile]

  DependencyGatheringPolicy* = object
    kind*: DependencyGatheringKind
    completeness*: DependencyEvidenceCompleteness
    recognizedReports*: seq[RecognizedDependencyReportSpec]
    postBuildConverters*: seq[PostBuildDependencyConverterSpec]

proc `$`*(name: DependencyFormatName): string =
  string(name)

proc `==`*(a, b: DependencyFormatName): bool =
  string(a) == string(b)

proc declaredOnlyPolicy*(): DependencyGatheringPolicy =
  DependencyGatheringPolicy(kind: dgDeclaredOnly, completeness: decComplete)

proc monitorValidatedPolicy*(
    reports: openArray[RecognizedDependencyReportSpec]): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormatValidatedByMonitor,
    completeness: decComplete,
    recognizedReports: @reports)
