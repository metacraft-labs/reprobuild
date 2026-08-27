import repro_core/process_specs

type
  DependencyGatheringKind* = enum
    dgAutomaticMonitor
    dgRecognizedFormat
    dgPostBuildConverter
    dgRecognizedFormatValidatedByMonitor
    dgPostBuildConverterValidatedByMonitor

    dgTrustedDeclaredInputs
      ## HAZARDOUS. The action's inputs are whatever the recipe author wrote
      ## inline, and the engine performs NO monitoring and NO result
      ## processing for the edge. Nothing verifies the list.
      ##
      ## USE ONLY when the action CANNOT be monitored at all — today that
      ## means an action performing ``LD_PRELOAD`` interposition itself,
      ## because the monitor's interposer and the action's re-enter each
      ## other on the same libc entry points and livelock. "Monitoring is
      ## inconvenient", "the action is slow", or "the evidence looks noisy"
      ## are NOT reasons; those keep ``dgAutomaticMonitor``.
      ##
      ## THE HAZARD: a declared list that is wrong, or that goes stale when a
      ## dependency moves, will NOT invalidate the cache. The action keeps
      ## serving a cached result built from inputs that have since changed,
      ## silently and indefinitely, until a human notices and edits the list.
      ## Automatic monitoring exists precisely so that cannot happen.
      ##
      ## Note the engine must ALSO withhold the shim-library env seed for
      ## this kind (see ``launchChildEnv``): suppressing the monitor wrap
      ## alone is not enough, because io-mon's preload runtime propagates
      ## whatever ``REPRO_MONITOR_SHIM_LIB`` names into child processes.
      ##
      ## Authorized by the repository owner on 2026-08-21 for the narrow
      ## self-interposing-test case, with the explicit instruction that its
      ## use stay discouraged. See the history note below for why the
      ## unrestricted forms of this idea were removed and must not return.

    # NOTE: there is intentionally NO "declared-only" / "no runtime
    # dependencies" gathering kind of the UNRESTRICTED kind described below.
    # ``dgTrustedDeclaredInputs`` above is a deliberately narrow,
    # owner-authorized exception requiring the author to write the inputs and
    # a justification inline at the call site; it is NOT a default, NOT a
    # fallback, and NOT reachable from an environment variable. The blanket
    # forms remain banned:
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
