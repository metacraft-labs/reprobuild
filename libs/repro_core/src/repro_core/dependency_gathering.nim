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

  NonDeterminismPolicy* = enum
    ## Windows-Build-Correctness M6 — what an OBSERVED entropy read by a
    ## monitored action means for that action's cache publication.
    ##
    ## io-mon records `mrNonDeterministic` when a monitored process reads an
    ## entropy source (`BCryptGenRandom` / `ProcessPrng` / `RtlGenRandom` /
    ## `CryptGenRandom` on Windows, `getentropy` / `arc4random*` on macOS,
    ## `getrandom` on Linux). That record is deliberately NOT a monitoring
    ## loss — io-mon SAW the read, so nothing is missing from the capture —
    ## and io-mon says so at the declaration of the record kind: "caller
    ## policy decides whether that evidence invalidates the build/cache
    ## result". This enum is that policy.
    ##
    ## THE BLESSING IS A PROPERTY OF THE TOOL, NOT OF THE EDGE. It is
    ## declared once in the tool's CLI spec (`nonDeterminism entropyBlessed,
    ## justification = "..."` inside a `package`'s `cli:` block) and the DSL
    ## stamps it onto every action that invokes that tool. A recipe writes
    ## `nim.c(...)` and gets the right answer without knowing that entropy
    ## exists; correspondingly, a recipe CANNOT bless a tool it happens to
    ## call, because the generated wrapper hard-codes the tool's declaration
    ## rather than exposing it as an overridable parameter.
    ndpUnblessed
      ## The default, and the fail-closed one. Nobody has vouched for this
      ## tool's use of randomness, so observed entropy in the action's
      ## process tree costs the action its action-cache publication (the
      ## action still SUCCEEDS — the result is used, it is just not
      ## remembered). The same applies when the capture's own backend
      ## profile says entropy could not be observed at all: "the monitor
      ## cannot see it" is not "it did not happen".
    ndpEntropyBlessed
      ## The tool's author (in reprobuild's own package spec) states that
      ## randomness this tool draws does not reach its outputs, so an
      ## entropy observation is evidence about the tool's internals and not
      ## about the reproducibility of its result. `nonDeterminismJustification`
      ## carries WHY, and the DSL refuses a blessing without one.
      ##
      ## Note what this does NOT bless: it is scoped to entropy
      ## (`mrNonDeterministic`). Clock reads (`mrTimeRead`) are a separate
      ## signal precisely because almost every program reads a clock, and
      ## nothing here weakens the file/library/ipc/external-content evidence
      ## that decides completeness.

  MonitorCaptureBreadth* = enum
    ## DA-6 — HOW MUCH of io-mon's event stream a monitored action asks for,
    ## declared by the TOOL PACKAGE that knows the tool and read by
    ## ``monitorInterest`` in ``repro_build_engine.nim``, which is the one
    ## place that turns it into a ``set[EventCategory]``.
    ##
    ## THE CLAIM. A recipe writing ``nim.c(...)`` or ``gcc(...)`` knows
    ## neither the workspace's store roots nor io-mon's record kinds, and
    ## should declare nothing about monitoring. The tool package knows the
    ## tool: whether it emits its own dependency list, whether its randomness
    ## reaches its output, whether its process tree is the tool or a script's
    ## choice. So the declaration lives beside the tool's CLI spec, exactly
    ## where ``nonDeterminism entropyBlessed`` already lives, and inherits the
    ## same way.
    ##
    ## WHY THE VOCABULARY IS TWO WORDS AND NOT A CATEGORY SET. io-mon's DA-5
    ## split proved, over all 256 interest sets, that exactly ONE proper
    ## subset of ``FullInterest`` is safe for a reprobuild edge:
    ## ``FullInterest - {ecAmbientReads}``. Every other category carries a
    ## record kind some reprobuild consumer reads — ``mrEnvRead`` keys the
    ## action cache through ``cacheEnvInputs``, ``mrNonDeterministic`` gates
    ## publication through ``applyEntropyBlessingPolicy``, and
    ## ``mrIpcConnect`` / ``mrExternalContent`` are not gate-able at all
    ## (io-mon's ``categoryOf`` answers ``none`` for them, because the harm is
    ## that the records do not exist when ``mergeFragments`` derives its
    ## synthetic ``mrEventLoss``). A free-form category set would let a tool
    ## package express 254 declarations that are all the cardinal sin — a
    ## capture that grades ``mcComplete`` while missing evidence a consumer
    ## needed, i.e. a false cache hit. The enum can only say the two things
    ## that are true.
    ##
    ## SCOPE. This decides what the monitor is ASKED for. It does not touch
    ## the evidence SCOPE axis (``EvidenceScope``, an operator choice —
    ## ``monitorEvidenceScope``), it does not touch the entropy blessing
    ## (``NonDeterminismPolicy`` above; a blessing decides what an observed
    ## ``mrNonDeterministic`` MEANS, this decides whether it is observed at
    ## all), and it changes no action-cache key by itself.
    ##
    ## Kept as a plain enum declared in ``repro_core`` — not a
    ## ``set[EventCategory]`` — so ``repro_core`` carries no io_mon
    ## dependency, which is the same reason the two bools it replaces were
    ## bools.
    mcbFullCapture
      ## Every io-mon event category. THE DEFAULT AND THE ZERO VALUE, so a
      ## tool package that declares nothing, a test that default-constructs a
      ## policy, and a ``seq`` grow all get the widest capture rather than the
      ## narrowest. Fail-closed: the cost of being wrong this way is records
      ## nobody reads, and the cost of the other way is a false ``mcComplete``.
    mcbOmitAmbientReads
      ## ``FullInterest - {ecAmbientReads}`` — drop ``mrTimeRead`` and
      ## ``mrSysctlRead``, and NOTHING else. These two are the only record
      ## kinds with no reprobuild consumer whatsoever: both land on the
      ## ``else: discard`` arm of the fold in ``repro_build_engine.nim``
      ## (beside the ``mrEnvRead`` and ``mrNonDeterministic`` arms that do
      ## have one), so excluding them removes no evidence any decision reads.
      ##
      ## Priced live by DA-5 on a ``bash -c 'date; ls /usr'`` capture:
      ## 135 -> 132 records (two ``mrTimeRead`` plus one ``mrSysctlRead``),
      ## both arms ``mcComplete`` / 0 losses. A small, honest 2.2%.
      ##
      ## A tool package should declare this only when it can say that nothing
      ## about the tool's own non-reproducibility is witnessed by a clock or
      ## sysctl read. That is a real per-tool question and its answer is not
      ## uniform: ``nim`` can say it, ``gcc`` cannot (``__DATE__`` /
      ## ``__TIME__`` / ``__TIMESTAMP__`` are gcc's signature
      ## irreproducibility and ``mrTimeRead`` is the only record that
      ## witnesses them).

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
    captureBreadth*: MonitorCaptureBreadth
      ## DA-6 — the TOOL PACKAGE's declaration of how much of io-mon's event
      ## stream this action asks for. Lowered here from
      ## ``BuildActionDependencyPolicy.captureBreadth`` and read by
      ## ``monitorInterest`` in ``repro_build_engine.nim``; the full argument
      ## for the vocabulary is at ``MonitorCaptureBreadth`` above.
      ##
      ## THIS FIELD REPLACES TWO INERT BOOLS, and the history is worth keeping
      ## because it is the reasoning that has to stay dead. ``captureIpc`` and
      ## ``captureNonDeterminism`` used to reduce io-mon's event interest to
      ## ``ecFileDeps+ecProcessTree+ecLibraryLoads`` on the grounds that a
      ## build edge's reproducibility hinges on the files/binaries/libraries it
      ## reads and not on the clock, environment, sysctls, entropy or IPC peers
      ## a tool happens to touch. That is true of what those records DESCRIBE
      ## and false of what the engine DOES with them, so both flags were
      ## neutralised and left standing with an ``INERT`` comment.
      ##
      ## ``captureIpc`` IS RETIRED OUTRIGHT, not re-scoped. After DA-5
      ## ``mrIpcConnect`` is not gate-able at ANY granularity — io-mon's
      ## ``categoryOf`` answers ``none`` for it, alongside
      ## ``mrExternalContent`` and the META kinds — so there is no set of
      ## categories at which the switch could be honoured. It was
      ## CONTINGENTLY inert (the engine happened to ask for everything); it is
      ## now PERMANENTLY, STRUCTURALLY inert, which is a different fact and a
      ## field that cannot ever mean anything is worse than no field: the
      ## previous generation of it spent a whole milestone carrying a comment
      ## that had become false without anything refusing it.
      ##
      ## ``captureNonDeterminism`` SURVIVES AS A DSL SPELLING OF THIS FIELD,
      ## with its scope shrunk to the part that was ever safe — see the
      ## ``dependencyPolicy`` parser in ``repro_project_dsl/macros_a.nim``.
      ## ``captureNonDeterminism = true`` is ``mcbFullCapture`` and
      ## ``captureNonDeterminism = false`` is ``mcbOmitAmbientReads``, because
      ## the ambient reads are the only members of the old category it could
      ## ever have dropped safely: env reads still key the action and entropy
      ## still gates publication.
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
