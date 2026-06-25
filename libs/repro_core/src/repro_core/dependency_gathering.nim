import repro_core/process_specs

type
  DependencyGatheringKind* = enum
    dgAutomaticMonitor
    dgRecognizedFormat
    dgPostBuildConverter
    dgRecognizedFormatValidatedByMonitor
    dgPostBuildConverterValidatedByMonitor
    # NOTE: there is intentionally NO "declared-only" / "no runtime
    # dependencies" gathering kind. A mode that tracked only the
    # statically declared inputs and marked the action complete/cacheable
    # — silently letting depended-on files change without a rebuild — was
    # re-introduced more than once by agents without approval (first as
    # ``dgDeclaredOnly`` / ``dgNoRuntimeDependencies``, then via the
    # recipe-facing ``declaredOnlyDependencyPolicy`` and the
    # ``REPRO_MACOS_DISABLE_ACTION_MONITOR`` opt-in). It contradicts the
    # automatic-monitoring baseline for opaque tools and is a soundness
    # hole, so it is REMOVED and MUST NOT be re-added. Opaque tools use
    # automatic monitoring (``dgAutomaticMonitor``); actions with no
    # monitorable evidence (e.g. a pure network fetch) are made
    # NON-CACHEABLE per Monitor-Hook-Shim.md:501 ("injection failure MUST
    # fail the monitored action or make it non-cacheable"), never marked
    # complete-on-declared-inputs. See
    # reprobuild-specs/Reprobuild-Development.milestones.org M17.

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

proc automaticMonitorGatheringPolicy*(
    ignoredInputPrefixes: openArray[string] = []): DependencyGatheringPolicy =
  ## The default dependency-gathering policy: the executor monitors the
  ## action and records every file it actually reads, so the action's
  ## fingerprint covers all real inputs (not just the statically declared
  ## ones). This is the spec's baseline for opaque tools. The removed
  ## ``dgDeclaredOnly`` / ``dgNoRuntimeDependencies`` mode (which tracked
  ## only declared inputs and silently let depended-on files change
  ## without a rebuild) MUST NOT be re-added; see the enum comment above
  ## and Reprobuild-Development.milestones.org M17.
  DependencyGatheringPolicy(
    kind: dgAutomaticMonitor,
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
