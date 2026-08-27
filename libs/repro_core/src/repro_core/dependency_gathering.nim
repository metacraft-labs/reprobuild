import repro_core/process_specs

type
  DependencyGatheringKind* = enum
    dgAutomaticMonitor
    dgRecognizedFormat
    dgPostBuildConverter
    dgRecognizedFormatValidatedByMonitor
    dgPostBuildConverterValidatedByMonitor

    # NOTE: there is intentionally NO "declared-only" / "no runtime
    # dependencies" gathering kind, in any form — narrow ones included.
    #
    # A mode that tracked only the
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
    #
    # A FOURTH form, ``dgTrustedDeclaredInputs``, was added and has now been
    # removed too. It was pitched as a narrow exception — the author writes
    # the input list and a justification inline, the engine trusts both — but
    # it was the same shape as the other three: ``decComplete``, cacheable,
    # outside ``MonitorPolicyKinds``, and nothing anywhere able to recompute
    # or re-check the list. The specs ban the idea by name (Domain-Types.md
    # "there is intentionally NO declared-only / no-runtime-dependencies",
    # "There is deliberately no 'declared inputs only' mode", "there is
    # intentionally NO ``dgpDeclaredOnly``") and were never amended.
    #
    # THE SANCTIONED ROUTE for an action that genuinely cannot be monitored
    # (today: one that performs library interposition itself, so the engine's
    # interposer and the action's re-enter each other on the same libc entry
    # points) is a DEPFILE — ``dgRecognizedFormat`` via ``makeDepfilePolicy``.
    # It is likewise unmonitored, but the input set is DERIVED rather than
    # ASSERTED: it lives in a file that some edge produces, that can be
    # regenerated, and that the engine reads back as real evidence, so the
    # listed paths do invalidate the action cache when their content changes.
    # The DSL helper ``unmonitorableActionDepfile`` generates such a file as a
    # graph output; see its docstring in repro_project_dsl/runtime_core.nim.

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
    # Event-interest opt-ins for automatic monitoring. A build edge's
    # reproducibility hinges on the files/binaries/libraries it reads, NOT on the
    # clock, environment, sysctls, entropy, or IPC peers a tool happens to touch,
    # so the engine monitors an action with io-mon's ecFileDeps+ecProcessTree+
    # ecLibraryLoads categories only (see `monitorHostRequest`). io-mon then skips
    # installing/recording the non-determinism and IPC observations, which it
    # would otherwise spend resources on. An edge that genuinely depends on such
    # an input sets the matching flag to add the category back. Kept as bools (not
    # a `set[EventCategory]`) so repro_core carries no io_mon dependency; the
    # engine translates them. Default false = off.
    captureNonDeterminism*: bool  ## add io-mon's ecNonDeterminism
    captureIpc*: bool             ## add io-mon's ecIpc
    suppressMonitorShimSeed*: bool
      ## Withhold the launch-time ``REPRO_MONITOR_SHIM_LIB`` environment seed
      ## from this action (see ``launchChildEnv`` in the build engine).
      ##
      ## Default false, so every edge that exists today — monitored or not —
      ## keeps the seed it gets today. Only an edge that asks for it loses the
      ## variable.
      ##
      ## An edge asks for it when the action performs library interposition
      ## ITSELF. Declining to WRAP such an action is not enough to keep it
      ## shim-free: io-mon's preload runtime propagates whatever this variable
      ## names into the processes it starts, so an action that builds its own
      ## interposer on top of that runtime re-injects our shim into its own
      ## children and the two interposers re-enter each other on the same libc
      ## entry points. "Do not monitor this action" therefore has to also mean
      ## "do not hand this action the means to monitor itself".
      ##
      ## Requested from a recipe with
      ## ``makeDepfilePolicy(..., suppressMonitorShimSeed = true)``.

const IomonFormatName* = "iomon"
  ## Recognized-report format name for an edge whose command PRODUCES its own
  ## io-mon ``.iomon`` dependency capture, which the engine then consumes as
  ## the edge's evidence (read via ``foldMonitorDepFileEvidence`` in the build
  ## engine) instead of monitoring the orchestrator process itself. Kept as a
  ## plain string constant so ``repro_core`` stays free of any io_mon
  ## dependency; the build engine routes on ``DependencyFormatName(this)``.

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
