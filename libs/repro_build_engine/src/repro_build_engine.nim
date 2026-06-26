import std/[algorithm, json, options, os, osproc, sets, streams, strtabs,
    strutils, tables, times]

when defined(windows):
  import std/winlean

import repro_core
import repro_depfile
import repro_hash
import repro_local_store
# Incremental-Test-Runner M7: the build engine consumes the shared ``io-mon``
# library (a byte-identical wire-format + ABI relocation of reprobuild's former
# ``repro_monitor_depfile`` fs-snoop stack) for its monitor-evidence dependency
# tracking. ``io_mon`` re-exports the depfile API under the SAME names
# (``MonitorDepFile`` / ``readMonitorDepFile`` / ``MonitorRecord`` / the
# ``mr*`` / ``mo*`` enums / ``mcComplete`` / ``MonitorDepFileReaderError`` /
# ``findShimLibrary``), so the call sites below are unchanged.
import io_mon
import repro_platform
import repro_runquota

# M9.L.4-refactor Step A: the engine learns ABOUT binary-cache publishing
# but is identity-agnostic — the convention populates the identity tuple
# on the action and the engine passes it through to the publisher
# closure. ``cache_key`` is intentionally lightweight (pulls
# ``repro_binary_cache_server/types`` + ``key`` + ``blake3`` only),
# so this import does NOT drag in the HTTP / closure-walk client
# surface. The publisher closure (wired by ``repro_cli_support`` /
# the standard provider in Step B) is the only seam that touches the
# heavier client modules.
import repro_binary_cache_client/cache_key

# DSL-port M9.R.7 — engine-side platform tagging for binary-cache
# namespacing. The sub-module defines ``DepKind`` (which dep-list a
# tool ref came from), ``TargetTripleResolver`` (the CLI-wired closure
# that hands back the resolved ``targetTriple`` variant value),
# ``buildPlatformTriple()`` / ``resolvedTargetTriple()`` /
# ``cachePlatformTagFor()`` (the namespacing primitives), and
# ``CachePlatformTagOptionKey`` (the synthetic selectedOptions key
# used to fold the tag into ``CacheEntryIdentity`` derivation). On a
# native build everything collapses to the ``"native"`` sentinel —
# cache keys stay byte-identical to pre-M9.R.7.
import repro_build_engine/platform
export platform

type
  BuildEngineError* = object of CatchableError

  ActionStatus* = enum
    asPending
    asRunning
    asSucceeded
    asCacheHit
    asUpToDate
    asWouldRun
    asFailed
    asBlocked

  CacheDecision* = enum
    cdNotCacheable
    cdMiss
    cdHit
    cdHybridCutoff
    cdRejected

  BuildProgressKind* = enum
    bpkActionStarted
    bpkActionCompleted

  BuildActionKind* = enum
    bakProcess
    bakCopyFile
    bakEnsureDir
    bakWriteText
    bakStamp
    bakPreserveTree
    # M2 (Workspace-Management): a typed VCS operation (clone / fetch /
    # switch) dispatched through a registered executor so the engine
    # does not depend on the ``repro_workspace_vcs`` library. The
    # external library registers its executor via
    # ``registerWorkspaceVcsExecutor`` at module init time; if no
    # executor is registered the engine fails closed with a clear
    # diagnostic rather than silently no-op'ing.
    bakWorkspaceVcs
    # A2.5 (ReproOS-Generations-And-Foreign-Packages): a substitution
    # task that fetches + materialises one cache-entry-key from a
    # configured binary-cache server. The engine dispatches through
    # the executor registered by ``repro_binary_cache_client/
    # scheduler_executor.nim``. Each substitute action carries the
    # cache-entry-key hex + the endpoint URL inside
    # ``BuildAction.builtinText``; the closure walker emits one
    # ``bakBinaryCacheSubstitute`` action per closure member and the
    # engine's pool/parallelism semantics drive them.
    bakBinaryCacheSubstitute

  EngineTypedOutput* = object
    ## Typed-Outputs M1: engine-side mirror of
    ## ``repro_project_dsl.BuildActionTypedOutput``. Decoupled by a
    ## distinct type so the engine doesn't take a hard dependency on
    ## the project-DSL package.
    fieldName*: string
    types*: seq[string]
    path*: string

  BuildAction* = object
    kind*: BuildActionKind
    id*: string
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
    pool*: string
    poolUnits*: uint32
    cpuMilli*: uint32
    memoryBytes*: uint64
    commandStatsId*: string
    cacheable*: bool
    weakFingerprint*: ContentDigest
    actionCachePolicy*: FileFingerprintPolicy
    depfile*: string
    dynamicDepsFile*: string
    monitorDepfile*: string
    dependencyPolicy*: DependencyGatheringPolicy
    builtinText*: string
    builtinEntries*: seq[string]
    targetNames*: seq[string]
      ## Named-Targets M1: implicit names this edge contributes to the
      ## project-scoped target-export table. Populated when the DSL
      ## lowering decodes a ``BuildActionDef`` whose typed-tool call
      ## site carried ``outputs`` flags or an ``implicitTargetName``
      ## hook. Engine-internal constructors leave this empty —
      ## anonymous edges remain selectable via the existing
      ## ``<path>[#<action>]`` fragment form.
    typedOutputs*: seq[EngineTypedOutput]
      ## Typed-Outputs M1: per-output (fieldName, types, path) entries
      ## populated when the DSL lowering decodes a ``BuildActionDef``
      ## carrying typed-output declarations (``outputs <field> is
      ## <Type>..., <pathExpr>``). Downstream consumers (CLI resolver,
      ## ``repro why``, the codetracer ``repro test`` integration)
      ## identify framework-specific outputs by interface tag from
      ## this list rather than re-parsing the DSL.
    publishToBinaryCache*: bool
      ## M9.L.4-refactor Step A. When ``true`` AND the action
      ## completes successfully AND ``cacheEntryIdentity.isSome`` AND
      ## ``BuildEngineConfig.binaryCachePublisher != nil``, the engine
      ## invokes the publisher closure with the action's identity +
      ## fingerprint + cwd + outputs + the recorded
      ## ``ActionResultRecord`` outputs. Defaults to ``false`` so
      ## existing per-action callers keep their current behaviour
      ## (zero binary-cache traffic). Step B's convention refactor
      ## sets ``true`` on the install + stage-copy actions; Step A
      ## leaves all conventions untouched, so the field is inert in
      ## the existing recipe corpus.
    cacheEntryIdentity*: Option[CacheEntryIdentity]
      ## M9.L.4-refactor Step A. The convention-supplied identity
      ## tuple from which the publisher re-derives the canonical
      ## entry-key hex (drift-guard) and which signs the manifest.
      ## ``none`` (the default) means "no identity wired" — the
      ## engine skips the publisher call even when
      ## ``publishToBinaryCache`` is true. Step B populates this
      ## from recipe metadata in the from-source conventions; Step A
      ## leaves it ``none`` everywhere.
    toolIdentityRefs*: seq[string]
      ## M9.N Batch B. Names of ``uses:`` tools (e.g. ``"meson"``,
      ## ``"ninja"``, ``"gcc"``, ``"sh"``) this action invokes at
      ## execution time. When non-empty AND
      ## ``BuildEngineConfig.toolIdentityResolver`` is non-nil, the
      ## engine resolves each ref to a ``ToolActionIdentity`` and
      ## prepends the binary directory derived from the identity
      ## (``parentDir(resolvedExecutablePath)`` first, falling back
      ## to each ``pathSearchList`` entry) to the action's ``PATH``
      ## env at fork time. Empty (the default) keeps legacy
      ## behaviour where ``argv[0]`` must be absolute or the host
      ## PATH must already carry the binary.
    toolIdentityRefKinds*: seq[DepKind]
      ## DSL-port M9.R.7. Parallel array of dep-list kinds for each
      ## ``toolIdentityRefs`` entry. The DSL doesn't yet emit this
      ## (no codec change in M9.R.7 — see the commit body); the
      ## engine treats an EMPTY ``toolIdentityRefKinds`` (the
      ## default) as "every ref is ``dkBuild``", which matches the
      ## legacy ``uses:`` semantics — the resolver namespaces the
      ## materialization lookup against the HOST-platform cache
      ## key. When non-empty, the seq MUST have the same length as
      ## ``toolIdentityRefs`` and each entry tags the corresponding
      ## ref with ``dkNative`` / ``dkBuild`` / ``dkRuntime``.
      ##
      ## The kind controls which platform-tagged cache key the
      ## resolver consults at materialization time:
      ##   * ``dkNative``  → ``buildPlatformTriple()``  (BUILD)
      ##   * ``dkBuild``   → ``resolvedTargetTriple()`` (HOST)
      ##   * ``dkRuntime`` → ``resolvedTargetTriple()`` (HOST)
      ## On a native build (``resolvedTargetTriple() == "native"``)
      ## both routes collapse to the same key, so existing recipes
      ## get byte-identical materialization cache behaviour to
      ## pre-M9.R.7.
    cachePlatformTag*: string
      ## DSL-port M9.R.7. Cache-platform namespace tag folded into
      ## ``cacheEntryIdentity`` derivation via the
      ## ``CachePlatformTagOptionKey`` synthetic option. Default
      ## ``""`` is normalised to ``NativeTriple`` (``"native"``) at
      ## fold-in time, so existing actions get byte-identical cache
      ## keys to pre-M9.R.7. When the convention layer wants to
      ## route a per-package install action against a HOST-platform
      ## cache key, it sets this to the resolved ``targetTriple``
      ## value; the engine then mixes it into the canonical key
      ## bytes so two ``targetTriple`` resolutions produce two
      ## distinct entry-key hexes for the same recipe.
    requiresElevation*: bool
      ## Windows-System-Resources Phase E. Marks an action edge whose
      ## execution must cross the privileged-operation broker. When
      ## ``true`` AND the engine's
      ## ``BuildEngineConfig.brokerSpawn`` hook is non-nil, the
      ## scheduler's pre-launch decision point hands the action's
      ## argv + env + cwd to the broker (via a ``pokInlineExecCall``
      ## typed operation, built inside the wired closure) instead of
      ## forking directly. ``false`` (the default) keeps the legacy
      ## direct-fork path, so every pre-Phase-E action is byte-
      ## identical to today. When ``true`` AND ``brokerSpawn`` is
      ## ``nil`` the engine FAILS CLOSED inside ``runBuild`` with a
      ## ``BuildEngineError`` — no silent fallback to a non-elevated
      ## direct fork. The DSL's ``BuildActionDef.requiresElevation``
      ## field propagates here through ``lowerGraphAction`` so the
      ## engine consumes the same flag the build-graph author set.

  BuildPool* = object
    name*: string
    capacity*: uint32

  BuildGraph* = object
    actions*: seq[BuildAction]
    pools*: seq[BuildPool]

  BuildEngineConfig* = object
    # Project-local scratch root: holds `runquota-results/*.json`,
    # `monitor-depfiles/*.rdep`, `dependency-evidence/*.rbar`, and per-build
    # transient state. Cleaned by `repro clean`. Per-project by design.
    cacheRoot*: string
    # User-level shared action cache + CAS root. When empty, defaults to
    # `cacheRoot` for backwards compatibility (callers that haven't been
    # updated yet keep the old single-root behavior). When populated, the
    # engine opens `<actionCacheRoot>/cas` and
    # `<actionCacheRoot>/action-cache` instead of paths under `cacheRoot`.
    # Phase 1 of Provider-Compile-Tiering.md §"Cache Scope".
    actionCacheRoot*: string
    runQuotaCliPath*: string
    monitorCliPath*: string
    # Argument vector prepended to ``monitorCliPath`` when wrapping a monitored
    # action (Executable-Consolidation M1). When ``monitorCliPath`` is the
    # ``repro`` executable itself (self-spawn, ``getAppFilename()``), this holds
    # the ``internal fs-snoop`` subcommand selector so the monitored argv
    # becomes ``repro internal fs-snoop --depfile … -- <cmd>`` rather than
    # invoking a standalone ``repro-fs-snoop`` binary. Empty (the default)
    # preserves the legacy ``<monitorCliPath> --depfile …`` shape used by tests
    # and any caller that still points at a dedicated fs-snoop binary.
    monitorCliArgs*: seq[string]
    # RA-13: the engine's parallelism knob is an ADVERTISED-FRONTIER bound, NOT
    # an independent CPU-slot quota. It caps how many candidate actions the
    # engine offers to / keeps in flight with RunQuota at once (it cannot offer
    # an unbounded ready frontier); RunQuota then selects the fitting subset
    # against the real host budget. When this value and RunQuota's grant
    # disagree, RunQuota's grant is authoritative — this knob never throttles
    # below what RunQuota grants, it only bounds the candidate set above it. See
    # Build-Engine-And-Scheduler.md § "One executor, one resource authority".
    maxParallelism*: uint32
    stdoutLimit*: int
    stderrLimit*: int
    rebuildMissingOutputsOnCacheHit*: bool
    forceRebuild*: bool
    # When true, successful actions record input/output metadata for local
    # invalidation but do not synchronously hash and copy output payloads into
    # the local CAS. This is only appropriate for modes that rebuild missing
    # outputs instead of restoring them from cache.
    deferLocalOutputBlobs*: bool
    # When true, the engine spawns each `bakProcess` action directly via
    # `osproc.startProcess` instead of going through the RunQuota helper, and
    # synthesizes a result JSON in the same on-disk schema the helper would
    # produce. This bypasses ALL resource quotas, named-pool leases, and
    # backend selection.
    bypassRunQuota*: bool
    # When true, the engine probes RunQuota lazily just before the first process
    # launch and uses the bypass path only if the daemon is unavailable. No-op
    # builds therefore do not pay a daemon round trip.
    fallbackToRunQuotaBypass*: bool
    # When true, the engine keeps one RunQuota client session for the build and
    # launches child processes directly under leases instead of spawning a
    # `repro __repro-runquota-helper` process for every action.
    inlineRunQuota*: bool
    dryRun*: bool
    progressCallback*: BuildProgressCallback
    cancelCallback*: BuildCancelCallback
    statsEnabled*: bool
    suppressTrace*: bool
    skipCacheHitEvidence*: bool
    peerCacheActionFetcher*: PeerCacheActionFetcher
      ## Peer-Cache M1 (Linux-Distro-Recipe-Validation M5 wiring,
      ## 2026-06-12): when non-nil, consulted on action-cache miss to
      ## pull the action bundle from a LAN peer before falling through
      ## to a rebuild. Left nil by callers that don't pass
      ## ``--peer-cache=…`` so the legacy local-only flow is byte-for-
      ## byte preserved.
    peerCacheActionPublisher*: PeerCacheActionPublisher
      ## Companion to `peerCacheActionFetcher`: called after each
      ## successful action so the producer-side build seeds the LAN
      ## cache. Nil-safe.
    peerCacheActionInstaller*: PeerCacheActionBundleInstaller
      ## Decoder + installer for peer-cache action bundles. Required
      ## when `peerCacheActionFetcher` is set; the CLI wires it from
      ## `repro_peer_cache.action_bundle`. The engine treats the
      ## fetcher's `some(bytes)` result as an opaque payload and
      ## delegates installation to this closure.
    binaryCachePublisher*: BinaryCachePublisher
      ## M9.L.4-refactor Step A. Optional binary-cache publisher
      ## closure. When non-nil, fired after every successful action
      ## that carries ``publishToBinaryCache = true`` AND a populated
      ## ``cacheEntryIdentity``. Soft-fail: a publish error logs into
      ## stats but does NOT abort the build. ``nil`` keeps the engine
      ## pure-local (legacy behaviour) — the publish hook becomes a
      ## no-op for every action regardless of the per-action flag.
    toolIdentityResolver*: ToolIdentityResolver
      ## M9.N Batch B. Optional tool-identity resolver closure.
      ## When non-nil AND ``BuildAction.toolIdentityRefs.len > 0``,
      ## the engine resolves each ref to its catalog-derived
      ## binary directory and prepends those dirs to the action's
      ## ``PATH`` env at fork time so a bare ``meson`` /
      ## ``ninja`` / ``gcc`` invocation in the action's argv finds
      ## the right binary regardless of whether the host has the
      ## tool installed. ``nil`` keeps the engine ignorant of the
      ## catalog (legacy behaviour); the action's argv must then
      ## reference absolute paths.
    targetTripleResolver*: TargetTripleResolver
      ## DSL-port M9.R.7. Optional ``targetTriple`` variant
      ## resolver closure. When non-nil, the engine consults it
      ## to derive the HOST-platform cache-key namespace tag for
      ## actions and ``dkBuild`` / ``dkRuntime`` tool refs. The
      ## CLI driver wires a closure that reads
      ## ``configurables.lastSolverSolution().variants.
      ## getOrDefault("targetTriple", "native")`` and hands the
      ## string back. ``nil`` is the explicit "no variant resolver
      ## configured" signal — the engine then treats the build as
      ## native (returns ``"native"``) and the namespacing
      ## collapses to the legacy single-key behaviour. Test
      ## fixtures that construct a ``BuildEngineConfig`` via
      ## ``defaultBuildEngineConfig`` get a ``nil`` resolver, which
      ## is the desired pre-M9.R.7-equivalent behaviour.
    brokerSpawn*: ElevatedExecSpawner
      ## Windows-System-Resources Phase E. Optional broker-spawn
      ## closure consulted at the pre-launch decision point when a
      ## ``BuildAction.requiresElevation`` flag is set. When non-nil
      ## the engine packages the action's argv + cwd + env into an
      ## ``ElevatedExecRequest`` and delegates the fork to the
      ## broker; the returned ``ElevatedExecResult`` is projected
      ## back into the action's ``ActionResult`` so the cache layer
      ## treats the elevated execution byte-identically to a direct
      ## fork. When ``nil`` AND a ``requiresElevation = true`` edge
      ## is encountered, ``runBuild`` FAILS CLOSED with a
      ## ``BuildEngineError`` — the engine MUST NOT silently fall
      ## back to a non-elevated direct fork. The CLI's
      ## ``repro infra apply`` path wires a closure that funnels
      ## the request through ``repro_elevation.dispatchOperation``;
      ## the standalone ``repro build`` driver leaves the field
      ## ``nil`` so an inadvertent elevated edge surfaces with the
      ## spec-mandated diagnostic instead of running.

  PathSetEvidence* = object
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    depfileInputs*: seq[string]
    monitorReads*: seq[string]
    monitorWrites*: seq[string]
    monitorProbes*: seq[string]
    diagnostics*: seq[string]

  EvidenceCollection = object
    evidence: PathSetEvidence
    publishable: bool

  ActionResult* = object
    id*: string
    status*: ActionStatus
    exitCode*: int
    launched*: bool
    wouldLaunch*: bool
    cacheDecision*: CacheDecision
    reason*: string
    dependencyPolicyKind*: DependencyGatheringKind
    monitorDepfilePath*: string
    blockedBy*: string
    stdout*: string
    stderr*: string
    leaseId*: uint64
    runQuotaBackend*: string
    runQuotaSocket*: string
    evidence*: PathSetEvidence

  SchedulerTraceEvent* = object
    seq*: uint64
    actionId*: string
    event*: string
    detail*: string

  BuildStatsMetric* = object
    name*: string
    count*: int
    totalUs*: float

  BuildStats* = object
    metrics*: seq[BuildStatsMetric]

  BuildRunResult* = object
    results*: seq[ActionResult]
    trace*: seq[SchedulerTraceEvent]
    stats*: BuildStats
    traceEnabled: bool
    runQuotaBypassed*: bool
      ## RA-13: true when at least one action in this build launched without a
      ## RunQuota lease (explicit ``--runquota=off`` / ``REPROBUILD_NO_RUNQUOTA``
      ## bypass, or the unreachable-daemon fallback). In that state RunQuota is
      ## NOT the resource authority for this run: host limits, cross-session
      ## fairness, and named-pool capacity are enforced only by the engine's
      ## LOCAL pool gate, which cannot make concurrent cross-invocation runs
      ## safe. Surfaced in the build header + run report so the unsafe state is
      ## never entered silently. Stays false when RunQuota gated every launch.

  BuildProgressEvent* = object
    kind*: BuildProgressKind
    actionId*: string
    command*: string
    currentCommand*: string
    status*: ActionStatus
    cacheDecision*: CacheDecision
    launched*: bool
    total*: int
    completed*: int
    checked*: int
    settled*: int
    plannedExecutions*: int
    completedExecutions*: int
    executionPlanKnown*: bool
    running*: int
    ready*: int

  BuildProgressCallback* = proc(event: BuildProgressEvent)
  BuildCancelCallback* = proc(): bool

  PeerCacheActionFetcher* = proc(weakFingerprint: ContentDigest):
    Option[seq[byte]] {.gcsafe, closure.}
    ## Optional peer-cache action-bundle fetcher. The engine calls this
    ## on action-cache miss (no record or input-changed) with the
    ## action's weak fingerprint; a `some(bytes)` reply carries an
    ## encoded `ActionBundle` (see
    ## `repro_peer_cache/action_bundle.nim`) which the engine installs
    ## via `installPeerCacheActionBundle` before re-trying the local
    ## lookup. `none` means the peer cache missed and the engine falls
    ## through to a rebuild. The closure type keeps `repro_build_engine`
    ## free of a `repro_peer_cache` dependency — the CLI wires it.

  PeerCacheActionPublisher* = proc(weakFingerprint: ContentDigest;
                                   bundleBytes: seq[byte])
    {.gcsafe, closure.}
    ## Optional peer-cache action-bundle publisher. The engine calls
    ## this after a successful local cache record write so the producer
    ## side of a same-recipe build seeds the LAN cache. `nil` keeps the
    ## engine pure-local (the legacy behaviour).

  PeerCacheActionBundleInstaller* = proc(weakFingerprint: ContentDigest;
                                          bundleBytes: seq[byte];
                                          cas: LocalCas;
                                          cache: ptr ActionCache):
                                          tuple[ok: bool; reason: string]
    {.gcsafe, closure.}
    ## Optional decoder + installer for peer-cache action bundles. The
    ## engine invokes this synchronously when `peerCacheActionFetcher`
    ## returns `some(bytes)`. The closure decodes the bundle, writes
    ## the output blobs to the engine's `cas` (so the next blob
    ## lookup hits), and appends the action record to the engine's
    ## in-memory `cache` (so the engine's retry `lookupActionResult`
    ## sees the freshly installed record without reloading from
    ## disk). The result tuple lets the engine log a structured
    ## reason on verification failure without crashing the build. The
    ## CLI provides this closure via the wiring helper in
    ## `repro_cli_support`.

  BinaryCachePublishRequest* = object
    ## M9.L.4-refactor Step A. Passed to ``BinaryCachePublisher`` when
    ## the engine fires the post-success publish hook. Decoupled by a
    ## struct value so the publisher closure can ride a normal
    ## ``{.closure, gcsafe.}`` lifetime without sharing references
    ## into the engine's mutable build state.
    ##
    ## Fields (engine-populated):
    ##   * ``actionId`` — ``BuildAction.id`` for diagnostics.
    ##   * ``weakFingerprint`` — the engine-side action fingerprint
    ##     (BLAKE3 over canonical action text). NOT the cache-entry
    ##     key; the closure typically logs it for cross-correlation
    ##     with the action cache.
    ##   * ``identity`` — the convention-supplied
    ##     ``CacheEntryIdentity`` from
    ##     ``BuildAction.cacheEntryIdentity``. The publisher closure
    ##     uses it both to re-derive the entry-key (drift-guard) and
    ##     to sign the manifest.
    ##   * ``cwd`` — ``BuildAction.cwd``; useful when the publisher
    ##     needs to interpret a relative ``prefixDir``.
    ##   * ``declaredOutputs`` — the action's declared output paths
    ##     (verbatim from ``BuildAction.outputs``).
    ##   * ``recordOutputs`` — the (path, blob) pairs the engine's
    ##     local-store ``ActionResultRecord`` captured for the
    ##     successful action. The publisher reads the prefix bytes
    ##     directly from disk by convention, but the record-output
    ##     list lets it skip stat'ing paths the action did not
    ##     actually produce.
    actionId*: string
    weakFingerprint*: ContentDigest
    identity*: CacheEntryIdentity
    cwd*: string
    declaredOutputs*: seq[string]
    recordOutputs*: seq[string]

  BinaryCachePublishResult* = object
    ## Outcome returned by the publisher closure. The engine logs the
    ## diagnostic into stats but does NOT abort the build on a failed
    ## publish — mirrors ``publishPeerCacheBundle`` soft-fail
    ## semantics.
    ok*: bool
    statusCode*: int
    error*: string
    bytesUploaded*: int

  BinaryCachePublisher* = proc(req: BinaryCachePublishRequest):
    BinaryCachePublishResult {.gcsafe, closure.}
    ## M9.L.4-refactor Step A. The engine's seam to the binary-cache
    ## publish pipeline. ``nil`` keeps the engine pure-local — the
    ## publish hook becomes a no-op even when the action carries
    ## ``publishToBinaryCache = true``. Step B's convention refactor
    ## sets the field on actions; the actual closure is wired by the
    ## standard-provider / CLI binding layer (reading the
    ## ``REPRO_BINARY_CACHE_*`` env vars + calling
    ## ``publishInProcess``).

  ElevatedExecRequest* = object
    ## Windows-System-Resources Phase E. Passed to the
    ## ``brokerSpawn`` hook when the engine encounters a
    ## ``requiresElevation = true`` build edge. Decoupled by a struct
    ## value so the engine stays free of a hard ``repro_elevation``
    ## dependency — the broker-spawning closure (wired by
    ## ``repro_cli_support`` / ``repro infra apply``) constructs a
    ## ``pokInlineExecCall`` ``PrivilegedOperation`` from this
    ## request, dispatches it through the broker, and projects the
    ## ``DispatchResult`` back into an ``ElevatedExecResult``.
    ##
    ## Fields (engine-populated, all verbatim from the build edge):
    ##   * ``actionId`` — ``BuildAction.id`` for diagnostics and the
    ##     ``PrivilegedOperation.address`` the hook stamps onto the
    ##     constructed operation.
    ##   * ``argv`` — argv[0] + argv[1..]. The literal
    ##     ``@FILE:<path>`` tokens are preserved here (the broker side
    ##     re-expands them under elevation, matching spec §2.1).
    ##     ``argv[0]`` becomes ``iecExecutable``; the rest become
    ##     ``iecArguments``.
    ##   * ``cwd`` — ``BuildAction.cwd``; empty means "broker's cwd at
    ##     fork time", same convention as ``pokInlineExecCall``.
    ##   * ``env`` — the action's ``env`` list (``NAME=VALUE`` shape)
    ##     passed straight through to ``iecEnvironment``.
    actionId*: string
    argv*: seq[string]
    cwd*: string
    env*: seq[string]

  ElevatedExecResult* = object
    ## Returned by the ``brokerSpawn`` hook. The engine projects this
    ## into the action's ``ActionResult`` (exit code, stdout/stderr,
    ## status) so the cache layer + downstream consumers see the same
    ## shape they would see from a direct fork.
    ##
    ##   * ``ok``       — true when the broker reported the operation
    ##                    as ``applied`` (or ``no-op``); false when the
    ##                    broker reported drift or driver failure.
    ##   * ``exitCode`` — the elevated process's exit code as captured
    ##                    by ``runInlineExecCall``. ``0`` when the
    ##                    operation succeeded inside the spec's
    ##                    ``iecAcceptExitCodes`` set.
    ##   * ``stdout`` / ``stderr`` — the captured tails; the broker
    ##                    side merges stderr into stdout (see
    ##                    ``runInlineExecCall``), so ``stderr`` is
    ##                    typically empty and the operator reads
    ##                    everything from ``stdout``.
    ##   * ``diagnostic`` — empty on success; on failure the broker's
    ##                    rendered ``DispatchResult.detail``.
    ok*: bool
    exitCode*: int
    stdout*: string
    stderr*: string
    diagnostic*: string

  ElevatedExecSpawner* = proc(req: ElevatedExecRequest):
    ElevatedExecResult {.gcsafe, closure.}
    ## Windows-System-Resources Phase E. The engine's seam to the
    ## privileged-operation broker. When ``nil`` (the default) every
    ## ``requiresElevation = true`` build edge FAILS CLOSED inside
    ## ``runBuild`` with a ``BuildEngineError`` — the engine NEVER
    ## silently spawns an elevation-required edge under the
    ## non-elevated path. ``repro infra apply`` wires a non-nil
    ## closure that constructs the matching ``pokInlineExecCall``
    ## ``PrivilegedOperation`` and runs it through
    ## ``repro_elevation.dispatchOperation``; the standalone
    ## ``repro build`` driver leaves the field ``nil`` so an
    ## inadvertent elevated edge on a non-infra-apply path surfaces
    ## with the spec-mandated diagnostic instead of running.

  ResolvedToolIdentity* = object
    ## M9.N Batch B. Opaque engine-side view of the catalog's
    ## ``ToolActionIdentity`` (defined in ``repro_tool_profiles``).
    ## The engine deliberately does NOT import the catalog: the CLI's
    ## ``toolIdentityResolver`` closure projects a ``ToolActionIdentity``
    ## into this minimal shape so the engine stays free of the heavier
    ## catalog modules (Nix / tarball / Scoop adapters) and so the
    ## interface that crosses the seam is just "give me a list of bin
    ## dirs to prepend to PATH" — exactly what the engine needs at
    ## fork time.
    ##
    ## Fields:
    ##   * ``binDirs`` — directories to prepend to the action's
    ##     ``PATH`` env in order. For nix/tarball/scoop modes this is
    ##     the resolved store path's ``bin`` directory; for path-only
    ##     mode it's the host-PATH parent directory of the resolved
    ##     executable. Multiple entries are prepended preserving order
    ##     (first entry ends up leftmost in PATH).
    ##   * ``resolvedExecutablePath`` — the catalog's
    ##     ``ToolActionIdentity.resolvedExecutablePath`` for
    ##     diagnostics. Not used by the env-plumbing path itself.
    binDirs*: seq[string]
    resolvedExecutablePath*: string
    # M9.R.14e.3 — auxiliary search-path channels. The engine threads
    # each list onto a dedicated env var at action-launch time (see
    # ``resolvedToolAuxPaths`` / ``applyEnvSearchLists``):
    #
    #   * ``pkgConfigDirs``  → ``PKG_CONFIG_PATH``
    #   * ``cmakePrefixDirs`` → ``CMAKE_PREFIX_PATH``
    #   * ``includeDirs``    → ``CPATH``
    #   * ``libDirs``        → ``LIBRARY_PATH`` AND ``LD_LIBRARY_PATH``
    #
    # The from-source resolver populates these per-ref from the sibling
    # recipe's staged install tree; the path/nix/tarball/scoop resolvers
    # leave them empty (their store paths already work through PATH +
    # the standard FHS layout).
    pkgConfigDirs*: seq[string]
    cmakePrefixDirs*: seq[string]
    includeDirs*: seq[string]
    libDirs*: seq[string]
    cachePlatformTag*: string
      ## DSL-port M9.R.7. The platform-tag the materialization cache
      ## lookup keyed against (``"native"`` on a native build;
      ## ``buildPlatformTriple()`` for a ``dkNative`` ref under a
      ## cross-build; ``resolvedTargetTriple()`` for ``dkBuild`` /
      ## ``dkRuntime`` under a cross-build). The engine doesn't
      ## consume this field at PATH-prepend time — it's an
      ## observability surface for tests and for ``repro why`` to
      ## explain WHICH cache namespace the tool came from. Defaults
      ## to ``"native"`` (the legacy pre-M9.R.7 namespace) when the
      ## resolver doesn't set it.

  ToolIdentityResolver* = proc(name: string; kind: DepKind):
    Option[ResolvedToolIdentity] {.gcsafe, closure.}
    ## M9.N Batch B + DSL-port M9.R.7. The engine's seam to the tool
    ## catalog. When non-nil AND ``BuildAction.toolIdentityRefs.len >
    ## 0``, the engine calls the resolver once per ref at fork time
    ## and prepends each returned ``binDirs`` entry to the action's
    ## ``PATH``.
    ##
    ## ``kind`` (M9.R.7) tells the resolver which platform-tagged
    ## cache key to look the materialization up against:
    ##   * ``dkNative``  → BUILD-platform cache
    ##     (``buildPlatformTriple()``)
    ##   * ``dkBuild``   → HOST-platform cache
    ##     (``resolvedTargetTriple()``)
    ##   * ``dkRuntime`` → HOST-platform cache
    ##     (``resolvedTargetTriple()``)
    ## On a native build (``resolvedTargetTriple() == "native"``)
    ## both routes resolve to the same ``"native"`` tag and the
    ## materialization cache lookup is byte-identical to pre-
    ## M9.R.7. The engine passes ``dkBuild`` as the default when
    ## ``BuildAction.toolIdentityRefKinds`` is empty — preserving
    ## the legacy ``uses:`` semantics.
    ##
    ## ``none`` is the fail-soft signal that the ref doesn't resolve
    ## (e.g. the tool isn't declared by the recipe or the catalog
    ## substituted a bare host-PATH lookup) — the engine then leaves
    ## PATH unaltered for that ref. ``nil`` keeps the engine
    ## ignorant of catalog state (legacy behaviour); the action's
    ## argv must reference absolute paths or the host PATH must
    ## already carry the binary.

  RunningProcessKind = enum
    rpkHelperProcess
    rpkBypassProcess
    rpkInlineRunQuotaPending
    rpkInlineRunQuota
    rpkInlineRunQuotaFailed

  RunningAction = object
    id: string
    pool: string
    poolUnits: uint32
    action: BuildAction
    processKind: RunningProcessKind
    process: Process
    runQuotaProcess: ReproRunQuotaRunningProcess
    queuedRunQuotaProcess: ReproRunQuotaQueuedProcess
    inlineFailure: ActionResult
    resultPath: string
    when defined(windows):
      # Synchronize-only HANDLE duplicate of the child process, opened on
      # first wait-loop entry via OpenProcess(SYNCHRONIZE, pid). Used as a
      # WaitForMultipleObjects argument so process-exit detection is
      # event-driven (~microseconds) instead of the previous
      # peekExitCode+Sleep(1) spin loop (≥15 ms Windows timer quantum).
      # Closed when the action is reaped. Mirrors Ninja's IOCP-based wait
      # in references/ninja/src/subprocess-win32.cc.
      processWaitHandle: Handle

  DynamicGraphFragment = object
    deps: Table[string, seq[string]]
    outputs: Table[string, seq[string]]
    # M25: action-create records. Each entry describes a new BuildAction
    # that the engine materialises into the running graph mid-build. The
    # producer of the .rbdyn file emits one record per new action; the
    # engine validates uniqueness + dep resolution + cycle freedom before
    # inserting it into the schedule.
    createdActions: seq[BuildAction]

const
  RecognizedPolicyKinds = {
    dgRecognizedFormat,
    dgRecognizedFormatValidatedByMonitor
  }
  ConverterPolicyKinds = {
    dgPostBuildConverter,
    dgPostBuildConverterValidatedByMonitor
  }
  MonitorPolicyKinds = {
    dgAutomaticMonitor,
    dgRecognizedFormatValidatedByMonitor,
    dgPostBuildConverterValidatedByMonitor
  }

proc applyCachePlatformTag*(idy: CacheEntryIdentity; tag: string):
    CacheEntryIdentity =
  ## DSL-port M9.R.7. Return a copy of ``idy`` with the
  ## ``CachePlatformTagOptionKey`` synthetic option set to
  ## ``tag`` (normalising the empty string to ``NativeTriple``).
  ## Centralises the fold-in shape so both the publisher hook and the
  ## test surface go through the same code path — no drift between
  ## what gets published and what tests pin.
  result = idy
  let foldedTag = if tag.len == 0: NativeTriple else: tag
  result.addOption(CachePlatformTagOptionKey, foldedTag)

proc deriveActionCacheKeyHex*(action: BuildAction): string =
  ## DSL-port M9.R.7. Helper that mirrors the publisher hook's
  ## fold-in: takes the action's ``cacheEntryIdentity`` + folds in
  ## ``cachePlatformTag`` via ``CachePlatformTagOptionKey``, then
  ## returns the canonical 64-char lowercase hex of the
  ## ``CacheEntryKey``. Returns ``""`` when the action carries no
  ## identity (no cache key to derive).
  ##
  ## Tests use this to assert that two ``cachePlatformTag`` values
  ## produce two distinct hex keys for the same recipe; production
  ## code goes through the publisher hook which folds the tag in
  ## via ``applyCachePlatformTag`` before forwarding to the
  ## ``BinaryCachePublisher`` closure.
  if action.cacheEntryIdentity.isNone:
    return ""
  let folded = applyCachePlatformTag(
    action.cacheEntryIdentity.get(), action.cachePlatformTag)
  deriveCacheEntryKeyHex(folded)

proc defaultBuildEngineConfig*(cacheRoot: string;
                               actionCacheRoot: string = ""): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: cacheRoot,
    actionCacheRoot: actionCacheRoot,
    runQuotaCliPath: "",
    monitorCliPath: "",
    maxParallelism: 8'u32,
    stdoutLimit: 1_048_576,
    stderrLimit: 1_048_576,
    rebuildMissingOutputsOnCacheHit: false,
    forceRebuild: false,
    deferLocalOutputBlobs: false,
    bypassRunQuota: false,
    fallbackToRunQuotaBypass: false,
    inlineRunQuota: false,
    dryRun: false,
    progressCallback: nil,
    statsEnabled: false,
    suppressTrace: false)

proc addMetric*(stats: var BuildStats; name: string; elapsedUs: float) =
  for metric in stats.metrics.mitems:
    if metric.name == name:
      inc metric.count
      metric.totalUs += elapsedUs
      return
  stats.metrics.add(BuildStatsMetric(name: name, count: 1, totalUs: elapsedUs))

proc mergeStats*(stats: var BuildStats; other: BuildStats) =
  for metric in other.metrics:
    if metric.count <= 0:
      continue
    var merged = false
    for existing in stats.metrics.mitems:
      if existing.name == metric.name:
        existing.count += metric.count
        existing.totalUs += metric.totalUs
        merged = true
        break
    if not merged:
      stats.metrics.add(metric)

proc addCounterMetric(stats: var BuildStats; name: string; count: int) =
  for _ in 0 ..< count:
    stats.addMetric(name, 0.0)

proc textBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFingerprintFromText*(text: string): ContentDigest =
  blake3DomainDigest(text.textBytes(), hdActionFingerprint)

proc legacyDepfileGatheringPolicy(depfile: string;
                                  ignoredInputPrefixes: openArray[string]):
    DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[
          ExpectedDependencyFile(
            logicalName: "deps",
            path: depfile,
            required: false)
        ],
        completeness: decComplete)
    ],
    ignoredInputPrefixes: @ignoredInputPrefixes)

proc action*(id: string; argv: openArray[string]; cwd = "";
             deps: openArray[string] = []; inputs: openArray[string] = [];
             outputs: openArray[string] = []; pool = ""; poolUnits = 1'u32;
             cpuMilli = 1000'u32; memoryBytes = 0'u64;
             commandStatsId = ""; cacheable = false;
             weakFingerprint = weakFingerprintFromText(id);
             actionCachePolicy = ffpTimestamp;
             depfile = ""; monitorDepfile = "";
             dynamicDepsFile = "";
             dependencyPolicy = automaticMonitorGatheringPolicy();
             env: openArray[string] = [];
             requiresElevation = false): BuildAction =
  let effectiveDependencyPolicy =
    if depfile.len > 0 and monitorDepfile.len == 0 and
        dependencyPolicy.kind == dgAutomaticMonitor:
      legacyDepfileGatheringPolicy(depfile,
        dependencyPolicy.ignoredInputPrefixes)
    else:
      dependencyPolicy
  BuildAction(
    kind: bakProcess,
    id: id,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    argv: @argv,
    cwd: cwd,
    env: @env,
    pool: pool,
    poolUnits: poolUnits,
    cpuMilli: cpuMilli,
    memoryBytes: memoryBytes,
    commandStatsId: commandStatsId,
    cacheable: cacheable,
    weakFingerprint: weakFingerprint,
    actionCachePolicy: actionCachePolicy,
    depfile: depfile,
    dynamicDepsFile: dynamicDepsFile,
    monitorDepfile: monitorDepfile,
    dependencyPolicy: effectiveDependencyPolicy,
    requiresElevation: requiresElevation)

proc builtinAction*(kind: BuildActionKind; id: string; cwd = "";
                    deps: openArray[string] = [];
                    inputs: openArray[string] = [];
                    outputs: openArray[string] = [];
                    commandStatsId = ""; cacheable = true;
                    weakFingerprint = weakFingerprintFromText(id);
                    actionCachePolicy = ffpTimestamp;
                    text = ""; entries: openArray[string] = []): BuildAction =
  if kind == bakProcess:
    raise newException(BuildEngineError, "builtinAction requires a built-in action kind")
  BuildAction(
    kind: kind,
    id: id,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    cwd: cwd,
    commandStatsId: commandStatsId,
    cacheable: cacheable,
    weakFingerprint: weakFingerprint,
    actionCachePolicy: actionCachePolicy,
    dependencyPolicy: automaticMonitorGatheringPolicy(),
    builtinText: text,
    builtinEntries: @entries)

proc pool*(name: string; capacity: uint32): BuildPool =
  BuildPool(name: name, capacity: capacity)

proc graph*(actions: openArray[BuildAction];
            pools: openArray[BuildPool] = []): BuildGraph =
  BuildGraph(actions: @actions, pools: @pools)

proc trace(result: var BuildRunResult; actionId, event, detail: string) =
  if not result.traceEnabled:
    return
  result.trace.add SchedulerTraceEvent(
    seq: uint64(result.trace.len + 1),
    actionId: actionId,
    event: event,
    detail: detail)

proc raiseEngine(message: string) {.noreturn.} =
  raise newException(BuildEngineError, message)

proc validateGraph(g: BuildGraph) =
  var ids = initHashSet[string]()
  var byId = initTable[string, BuildAction]()
  var outputs = initHashSet[string]()
  for action in g.actions:
    if action.id.len == 0:
      raiseEngine("action id is required")
    if ids.contains(action.id):
      raiseEngine("duplicate action id: " & action.id)
    ids.incl(action.id)
    byId[action.id] = action
    if action.kind == bakProcess and action.argv.len == 0 and action.outputs.len == 0:
      raiseEngine("action has neither command nor outputs: " & action.id)
    for output in action.outputs:
      if outputs.contains(output):
        raiseEngine("duplicate declared output: " & output)
      outputs.incl(output)
  for action in g.actions:
    for dep in action.deps:
      if not ids.contains(dep):
        raiseEngine("unknown dependency " & dep & " for " & action.id)

  var state = initTable[string, int]()
  var stack: seq[string] = @[]

  proc cycleText(id: string): string =
    let start = stack.find(id)
    if start >= 0:
      var cycle = stack[start .. ^1]
      cycle.add(id)
      return cycle.join(" -> ")
    id

  proc visit(id: string) =
    case state.getOrDefault(id, 0)
    of 1:
      raiseEngine("dependency cycle: " & cycleText(id))
    of 2:
      return
    else:
      state[id] = 1
      stack.add(id)
      for dep in byId[id].deps:
        visit(dep)
      discard stack.pop()
      state[id] = 2

  for action in g.actions:
    visit(action.id)

  for p in g.pools:
    if p.name.len == 0:
      raiseEngine("pool name is required")
    if p.capacity == 0'u32:
      raiseEngine("pool capacity must be positive: " & p.name)

proc pathExists(path: string): bool =
  symlinkExists(extendedPath(path)) or fileExists(extendedPath(path)) or
    dirExists(extendedPath(path))

proc outputPathReady(action: BuildAction; path: string): bool =
  # M2: bakWorkspaceVcs receipts are plain files, same readiness rule.
  if action.kind in {bakCopyFile, bakWriteText, bakStamp, bakWorkspaceVcs} and
      symlinkExists(extendedPath(path)):
    return false
  path.pathExists()

proc allOutputsExist(action: BuildAction): bool =
  if action.outputs.len == 0:
    return false
  for output in action.outputs:
    let path = if output.isAbsolute or action.cwd.len == 0: output else: action.cwd / output
    if not action.outputPathReady(path):
      return false
  true

proc addUnique(values: var seq[string]; value: string) =
  if value.len == 0:
    return
  if values.find(value) < 0:
    values.add(value)

# Deferred-D4: the legacy ``addUnique(values, value)`` does a linear ``find``
# before appending, so N successive calls cost O(N^2). For per-action evidence
# aggregation (``collectEvidence``, ``addPathSet``, ``evidenceFromRecord``,
# ``evidenceInputPaths``, ``cacheInputPaths``) where N can reach into the
# thousands per action, the post-build wrap-up was dominating wall time at
# the 14-app collection (B1) and again at ~1044 actions (B3, B5).
#
# This overload keeps the existing ``seq[string]`` field types (so we don't
# perturb any public-API caller that depends on the seq's insertion order or
# the seq itself), but tracks membership in a side-car ``HashSet[string]``
# threaded in by the caller. Each call is O(1) amortised; the aggregation
# becomes linear in N.
proc addUnique(values: var seq[string]; seen: var HashSet[string];
               value: string) =
  if value.len == 0:
    return
  if seen.containsOrIncl(value):
    return
  values.add(value)

proc normalizedDeclaredActionPath(action: BuildAction; path: string): string =
  result = path.replace('\\', '/').strip()
  while result.startsWith("./"):
    result = result.substr(2)
  while result.endsWith("/") and result.len > 1:
    result.setLen(result.len - 1)
  if result.len == 0:
    return

  if path.isAbsolute:
    result = os.normalizedPath(path).replace('\\', '/')
  elif action.cwd.len > 0:
    result = os.normalizedPath(action.cwd / path).replace('\\', '/')

proc inferDeclaredActionDeps(g: BuildGraph): BuildGraph =
  result = g
  var outputProducer = initTable[string, string]()
  for action in g.actions:
    for output in action.outputs:
      let normalized = normalizedDeclaredActionPath(action, output)
      if normalized.len > 0 and not outputProducer.hasKey(normalized):
        outputProducer[normalized] = action.id

  for i in 0 ..< result.actions.len:
    for input in result.actions[i].inputs:
      let normalized = normalizedDeclaredActionPath(result.actions[i], input)
      if normalized.len == 0 or not outputProducer.hasKey(normalized):
        continue
      let producerId = outputProducer[normalized]
      if producerId != result.actions[i].id:
        result.actions[i].deps.addUnique(producerId)

proc materialPath(root, path: string): string =
  if path.isAbsolute or root.len == 0:
    path
  else:
    root / path

proc parseCreateActionRecord(payload, path: string; lineNo: int): BuildAction =
  ## Decode an M25 ``create-action`` JSON payload into a BuildAction. The
  ## payload format is a single-line JSON object; embedded newlines are
  ## forbidden so the surrounding line-oriented fragment parser stays
  ## simple.
  proc fail(message: string) {.noreturn.} =
    raiseEngine(path & ":" & $lineNo & ": create-action " & message)

  var node: JsonNode
  try:
    node = parseJson(payload)
  except JsonParsingError as err:
    fail("malformed JSON payload: " & err.msg)
  if node.kind != JObject:
    fail("payload must be a JSON object")

  proc stringField(name: string; required = true; default = ""): string =
    if not node.hasKey(name):
      if required:
        fail("missing string field '" & name & "'")
      return default
    if node[name].kind != JString:
      fail("field '" & name & "' must be a string")
    node[name].getStr()

  proc stringSeqField(name: string): seq[string] =
    if not node.hasKey(name):
      return @[]
    if node[name].kind != JArray:
      fail("field '" & name & "' must be an array of strings")
    for item in node[name]:
      if item.kind != JString:
        fail("field '" & name & "' must contain only strings")
      result.add(item.getStr())

  proc boolField(name: string; default = false): bool =
    if not node.hasKey(name):
      return default
    if node[name].kind != JBool:
      fail("field '" & name & "' must be a boolean")
    node[name].getBool()

  proc uintField(name: string; default: uint32): uint32 =
    if not node.hasKey(name):
      return default
    if node[name].kind != JInt:
      fail("field '" & name & "' must be an integer")
    uint32(node[name].getInt())

  let id = stringField("id")
  if id.len == 0:
    fail("'id' must be non-empty")
  let argv = stringSeqField("argv")
  let cwd = stringField("cwd", required = false)
  let inputs = stringSeqField("inputs")
  let outputs = stringSeqField("outputs")
  let deps = stringSeqField("deps")
  let env = stringSeqField("env")
  let pool = stringField("pool", required = false)
  let poolUnits = uintField("poolUnits", 1'u32)
  let cpuMilli = uintField("cpuMilli", 1000'u32)
  let commandStatsId = stringField("commandStatsId", required = false)
  let cacheable = boolField("cacheable", default = false)
  let weakFingerprint = weakFingerprintFromText(id)
  result = action(id, argv, cwd = cwd, deps = deps, inputs = inputs,
    outputs = outputs, pool = pool, poolUnits = poolUnits, cpuMilli = cpuMilli,
    commandStatsId = commandStatsId, cacheable = cacheable,
    weakFingerprint = weakFingerprint, env = env)

proc readDynamicGraphFragment(path: string): DynamicGraphFragment =
  if path.len == 0 or not fileExists(extendedPath(path)):
    raiseEngine("dynamic dependency fragment missing: " & path)
  let lines = readFile(extendedPath(path)).splitLines()
  if lines.len == 0 or lines[0] != "repro-dynamic-graph-v1":
    raiseEngine(path & ": missing repro-dynamic-graph-v1 header")
  for lineNo in 1 ..< lines.len:
    let line = lines[lineNo]
    if line.len == 0:
      continue
    # M25: the ``create-action`` record carries a single JSON payload that
    # may itself contain TAB characters (escaped as ``\t``). Split on the
    # first TAB only so the payload survives unchanged; the legacy 3-field
    # records still validate via the explicit fields-length check below.
    let firstTab = line.find('\t')
    if firstTab < 0:
      raiseEngine(path & ":" & $(lineNo + 1) &
        ": dynamic graph record must contain at least one tab")
    let kind = line[0 ..< firstTab]
    let rest = line[firstTab + 1 .. ^1]
    case kind
    of "dep", "output":
      let fields = rest.split('\t')
      if fields.len != 2:
        raiseEngine(path & ":" & $(lineNo + 1) &
          ": dynamic graph " & kind & " record must have 3 tab-separated fields")
      if kind == "dep":
        result.deps.mgetOrPut(fields[0], @[]).addUnique(fields[1])
      else:
        result.outputs.mgetOrPut(fields[0], @[]).addUnique(fields[1])
    of "create-action":
      # M25: action-create record. The payload is a single-line JSON
      # object describing the BuildAction to materialise. Validation
      # of cross-action invariants (unique id, no cycle, dep targets
      # exist) happens at ingest time in applyDynamicDeps.
      result.createdActions.add(parseCreateActionRecord(rest, path, lineNo + 1))
    else:
      raiseEngine(path & ":" & $(lineNo + 1) &
        ": unsupported dynamic graph record kind: " & kind)

proc expectedPath(action: BuildAction; file: ExpectedDependencyFile): string =
  materialPath(action.cwd, file.path)

proc reportSpecsForPolicy(action: BuildAction):
    seq[RecognizedDependencyReportSpec] =
  if action.dependencyPolicy.kind in RecognizedPolicyKinds:
    return action.dependencyPolicy.recognizedReports
  @[]

proc converterSpecsForPolicy(action: BuildAction):
    seq[PostBuildDependencyConverterSpec] =
  if action.dependencyPolicy.kind in ConverterPolicyKinds:
    return action.dependencyPolicy.postBuildConverters
  @[]

proc monitorEvidenceRequired(action: BuildAction): bool =
  ## Monitor evidence is required for monitored policies once an RMDF
  ## (monitor depfile) has actually been wired up for the action. The only
  ## way a monitored action ends up without an RMDF now is an engine config
  ## that has no fs-snoop wired (``monitorCliPath`` empty): the setup step
  ## emits a "requires repro-fs-snoop" diagnostic and falls back to the
  ## statically declared inputs/outputs rather than claiming complete
  ## evidence. (The Windows ``REPRO_MONITOR_BYPASS`` escape hatch that used
  ## to produce this state was removed.)
  action.dependencyPolicy.kind in MonitorPolicyKinds and
    action.monitorDepfile.len > 0

proc needsExecutionForPolicy(action: BuildAction): bool =
  action.dependencyPolicy.kind in MonitorPolicyKinds or
    action.kind == bakPreserveTree

type
  EvidenceSeenSets = object
    # Deferred-D4: side-car membership trackers for the parallel ``seq[string]``
    # fields on ``PathSetEvidence``. Threaded through the per-action evidence
    # aggregation so each ``addUnique`` lookup is O(1) instead of O(N).
    depfileInputs: HashSet[string]
    monitorReads: HashSet[string]
    monitorWrites: HashSet[string]
    monitorProbes: HashSet[string]

proc addPathSet(evidence: var PathSetEvidence; seen: var EvidenceSeenSets;
                pathSet: DependencyPathSet; recognized: bool) =
  if recognized:
    for input in pathSet.inputs:
      evidence.depfileInputs.addUnique(seen.depfileInputs, input)
  else:
    for input in pathSet.inputs:
      evidence.monitorReads.addUnique(seen.monitorReads, input)
    for output in pathSet.outputs:
      evidence.monitorWrites.addUnique(seen.monitorWrites, output)
    for probe in pathSet.probes:
      evidence.monitorProbes.addUnique(seen.monitorProbes, probe)
  for diagnostic in pathSet.diagnostics:
    evidence.diagnostics.add(diagnostic)

proc collectConvertedEvidence(action: BuildAction;
                              specs: openArray[PostBuildDependencyConverterSpec];
                              evidence: var PathSetEvidence;
                              seen: var EvidenceSeenSets): bool

proc collectEvidence(action: BuildAction; strict: bool): EvidenceCollection =
  result.publishable = true
  result.evidence.declaredInputs = action.inputs
  result.evidence.declaredOutputs = action.outputs
  # Deferred-D4: track membership in side-car ``HashSet``s so adding the
  # k-th unique evidence entry costs O(1) instead of O(k). Monitor
  # records on a single action can exceed several thousand entries; the
  # legacy linear ``find`` made the per-action wrap-up the dominant
  # term on the 14-app / ~1044-action collections from B1/B3/B5.
  var seen: EvidenceSeenSets
  let reports = action.reportSpecsForPolicy()
  if action.dependencyPolicy.kind in RecognizedPolicyKinds and reports.len == 0:
    result.evidence.diagnostics.add(
      "dependency policy requires a recognized report but none is declared")
    result.publishable = false
  for report in reports:
    for output in report.outputs:
      let path = action.expectedPath(output)
      # MR16: a depfile entry whose path contains a glob meta-character
      # is expanded against the action's cwd at evidence-collection
      # time and the matched files are each parsed as the declared
      # ``formatName``. Cargo / rustc emit one ``.d`` per crate at
      # ``target/<profile>/deps/<crate>-<hash>.d`` (the hash depends
      # on the compiler-input content, so the recipe cannot enumerate
      # them at DSL-eval time); the recipe declares
      # ``target/debug/deps/*.d`` and ``target/release/deps/*.d`` and
      # we walk the patterns here. Literal paths take the original
      # single-file branch unchanged.
      let isGlob = '*' in path or '?' in path or '[' in path
      if isGlob:
        var matched = 0
        # walkPattern receives the ordinary form (not ``\\?\``) so
        # std/os glob expansion works on Windows; per-match reads
        # still apply ``extendedPath`` inside
        # ``readRecognizedDependencyReport`` to survive paths beyond
        # the 260-character ``MAX_PATH`` limit.
        for resolved in walkPattern(path):
          inc matched
          try:
            result.evidence.addPathSet(seen,
              readRecognizedDependencyReport($report.formatName, resolved),
              recognized = true)
          except DependencyReportError as err:
            result.evidence.diagnostics.add(
              "dependency report invalid: " & err.msg)
            result.publishable = false
        if output.required and matched == 0:
          result.evidence.diagnostics.add(
            "dependency report glob produced no matches: " & path)
          result.publishable = false
        continue
      if output.required and not fileExists(extendedPath(path)):
        result.evidence.diagnostics.add("dependency report missing: " & path)
        result.publishable = false
        continue
      if not fileExists(extendedPath(path)):
        continue
      try:
        result.evidence.addPathSet(seen,
          readRecognizedDependencyReport($report.formatName, path),
          recognized = true)
      except DependencyReportError as err:
        result.evidence.diagnostics.add("dependency report invalid: " & err.msg)
        result.publishable = false
  let converters = action.converterSpecsForPolicy()
  if action.dependencyPolicy.kind in ConverterPolicyKinds and converters.len == 0:
    result.evidence.diagnostics.add(
      "dependency policy requires a post-build converter but none is declared")
    result.publishable = false
  if not action.collectConvertedEvidence(converters, result.evidence, seen):
    result.publishable = false
  if action.monitorEvidenceRequired():
    if action.monitorDepfile.len == 0:
      result.evidence.diagnostics.add(
        "dependency policy requires monitor evidence but no RMDF path is selected")
      result.publishable = false
      if strict and not result.publishable:
        discard
      return
    try:
      let dep = readMonitorDepFile(action.monitorDepfile)
      for record in dep.records:
        let path = materialPath(action.cwd, record.path)
        case record.kind
        of mrFileRead:
          result.evidence.monitorReads.addUnique(seen.monitorReads, path)
        of mrFileOpen:
          case record.observationKind
          of moFileRead, moFileOpen:
            result.evidence.monitorReads.addUnique(seen.monitorReads, path)
          of moFileWrite:
            result.evidence.monitorWrites.addUnique(seen.monitorWrites, path)
          else:
            discard
        of mrFileWrite:
          result.evidence.monitorWrites.addUnique(seen.monitorWrites, path)
        of mrPathProbe, mrDirectoryEnumerate:
          result.evidence.monitorProbes.addUnique(seen.monitorProbes, path)
        else:
          discard
      if dep.completeness != mcComplete:
        result.evidence.diagnostics.add("monitor depfile is incomplete")
        result.publishable = false
    except MonitorDepFileReaderError as err:
      result.evidence.diagnostics.add("monitor depfile read failed: " & err.msg)
      result.publishable = false
  if strict and not result.publishable:
    discard

proc evidenceInputPaths(evidence: PathSetEvidence): seq[string] =
  # Deferred-D4: side-car ``HashSet`` keeps the per-action wrap-up linear
  # in N rather than quadratic. The output ``seq`` preserves insertion
  # order — callers downstream of action-cache key construction (see
  # ``cacheInputPaths``) depend on it for stable fingerprints.
  var seen = initHashSet[string]()
  for input in evidence.declaredInputs:
    result.addUnique(seen, input)
  for input in evidence.depfileInputs:
    result.addUnique(seen, input)
  for input in evidence.monitorReads:
    result.addUnique(seen, input)
  for probe in evidence.monitorProbes:
    result.addUnique(seen, probe)

proc nixStoreRoot(path: string): string =
  let normalized = path.replace('\\', '/')
  const prefix = "/nix/store/"
  if not normalized.startsWith(prefix):
    return ""
  let rest = normalized.substr(prefix.len)
  let slash = rest.find('/')
  if slash < 0:
    normalized
  else:
    prefix & rest[0 ..< slash]

proc addNixStoreRoot(roots: var seq[string]; path: string) =
  let root = nixStoreRoot(path)
  if root.len > 0:
    roots.addUnique(root)

proc envValue(action: BuildAction; name: string): string =
  let prefix = name & "="
  for item in action.env:
    if item.startsWith(prefix):
      return item.substr(prefix.len)

proc toolInputRoots(action: BuildAction): seq[string] =
  if action.argv.len > 0:
    result.addNixStoreRoot(action.argv[0])
  for value in action.envValue("PATH").split(PathSep):
    result.addNixStoreRoot(value)
  for value in action.envValue("NODE_PATH").split(PathSep):
    result.addNixStoreRoot(value)

proc expandPolicyPath(action: BuildAction; path: string): string =
  result = path
  var start = result.find('$')
  while start >= 0:
    var stop = start + 1
    if stop < result.len and result[stop] == '{':
      inc stop
      let nameStart = stop
      while stop < result.len and result[stop] != '}':
        inc stop
      if stop >= result.len:
        break
      let name = result[nameStart ..< stop]
      let value = block:
        let local = action.envValue(name)
        if local.len > 0: local else: getEnv(name)
      result = result[0 ..< start] & value & result.substr(stop + 1)
    else:
      let nameStart = stop
      while stop < result.len and
          (result[stop].isAlphaNumeric or result[stop] == '_'):
        inc stop
      if stop == nameStart:
        start = result.find('$', start + 1)
        continue
      let name = result[nameStart ..< stop]
      let value = block:
        let local = action.envValue(name)
        if local.len > 0: local else: getEnv(name)
      result = result[0 ..< start] & value & result.substr(stop)
    start = result.find('$', start)

proc ignoredInputRoots(action: BuildAction): seq[string] =
  for prefix in action.dependencyPolicy.ignoredInputPrefixes:
    let expanded = action.expandPolicyPath(prefix)
    if expanded.len > 0:
      result.add(expanded)

proc isUnderAnyRoot(path: string; roots: openArray[string]): bool =
  let normalized = path.replace('\\', '/')
  for root in roots:
    let normalizedRoot = root.replace('\\', '/')
    if normalized == normalizedRoot or normalized.startsWith(normalizedRoot & "/"):
      return true

proc cacheInputPaths(action: BuildAction; evidence: PathSetEvidence): seq[string] =
  let toolRoots = action.toolInputRoots()
  let ignoredRoots = action.ignoredInputRoots()
  var declaredMaterialized = initHashSet[string]()
  # Deferred-D4: side-car ``HashSet`` tracks ``result`` membership; the
  # output ``seq`` retains insertion order because the action-cache key
  # construction downstream is order-sensitive.
  var seen = initHashSet[string]()
  for input in evidence.declaredInputs:
    let path = materialPath(action.cwd, input)
    declaredMaterialized.incl(path.replace('\\', '/'))
    result.addUnique(seen, path)
  for input in evidence.depfileInputs:
    let path = materialPath(action.cwd, input)
    if not declaredMaterialized.contains(path.replace('\\', '/')) and
        (path.isUnderAnyRoot(toolRoots) or path.isUnderAnyRoot(ignoredRoots)):
      continue
    result.addUnique(seen, path)
  for input in evidence.monitorReads:
    let path = materialPath(action.cwd, input)
    if not declaredMaterialized.contains(path.replace('\\', '/')) and
        (path.isUnderAnyRoot(toolRoots) or path.isUnderAnyRoot(ignoredRoots)):
      continue
    result.addUnique(seen, path)
  for probe in evidence.monitorProbes:
    let path = materialPath(action.cwd, probe)
    if not declaredMaterialized.contains(path.replace('\\', '/')) and
        (path.isUnderAnyRoot(toolRoots) or path.isUnderAnyRoot(ignoredRoots)):
      continue
    result.addUnique(seen, path)

proc evidenceFromRecord(action: BuildAction; record: ActionResultRecord): PathSetEvidence =
  result.declaredInputs = action.inputs
  result.declaredOutputs = action.outputs
  var declaredInputPaths = initHashSet[string]()
  for input in action.inputs:
    declaredInputPaths.incl(materialPath(action.cwd, input))
  # Deferred-D4: side-car ``HashSet``s — N successive ``addUnique`` calls
  # would otherwise be O(N^2) over the cache-hit reconstructed evidence.
  var seenMonitorReads = initHashSet[string]()
  var seenDepfileInputs = initHashSet[string]()
  for input in record.inputs:
    if not declaredInputPaths.contains(input.path):
      if action.dependencyPolicy.kind in MonitorPolicyKinds:
        result.monitorReads.addUnique(seenMonitorReads, input.path)
      else:
        result.depfileInputs.addUnique(seenDepfileInputs, input.path)

proc processCwd(action: BuildAction; process: ProcessSpec): string =
  let cwd = $process.cwd
  if cwd.len > 0:
    cwd
  else:
    action.cwd

proc envTable(env: openArray[EnvVar]): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for item in env:
    result[item.name] = item.value

proc runConverter(action: BuildAction; converterSpec: PostBuildDependencyConverterSpec):
    tuple[ok: bool; diagnostic: string] =
  for input in converterSpec.inputs:
    let path = action.expectedPath(input)
    if input.required and not fileExists(extendedPath(path)):
      return (ok: false, diagnostic: "converter input missing: " & path)
  let process = converterSpec.converterProcess
  if process.executable.value.len == 0:
    return (ok: false, diagnostic: "converter executable is empty")
  let env = if process.env.len > 0: envTable(process.env) else: nil
  let child = startProcess($process.executable,
    args = process.args,
    env = env,
    workingDir = action.processCwd(process),
    options = {poUsePath, poStdErrToStdOut})
  let exitCode = child.waitForExit()
  var output = ""
  if child.outputStream != nil:
    output = child.outputStream.readAll()
  child.close()
  if exitCode != 0:
    var diagnostic = "converter failed with exit " & $exitCode
    if output.len > 0:
      diagnostic.add(": " & output.strip())
    return (ok: false, diagnostic: diagnostic)
  for output in converterSpec.outputs:
    let path = action.expectedPath(output)
    if output.required and not fileExists(extendedPath(path)):
      return (ok: false, diagnostic: "converter output missing: " & path)
  (ok: true, diagnostic: "")

proc runConverters(action: BuildAction;
                   specs: openArray[PostBuildDependencyConverterSpec]):
                   tuple[ok: bool; diagnostics: seq[string]] =
  result.ok = true
  for converterSpec in specs:
    let converterResult = action.runConverter(converterSpec)
    if not converterResult.ok:
      result.ok = false
      result.diagnostics.add("dependency converter: " & converterResult.diagnostic)

proc collectConvertedEvidence(action: BuildAction;
                              specs: openArray[PostBuildDependencyConverterSpec];
                              evidence: var PathSetEvidence;
                              seen: var EvidenceSeenSets): bool =
  result = true
  for converterSpec in specs:
    for output in converterSpec.outputs:
      let path = action.expectedPath(output)
      if output.required and not fileExists(extendedPath(path)):
        evidence.diagnostics.add("converted dependency report missing: " & path)
        result = false
        continue
      if not fileExists(extendedPath(path)):
        continue
      try:
        case converterSpec.outputKind
        of dcoReproPathSet:
          evidence.addPathSet(seen, readReproPathSet(path), recognized = false)
        of dcoRecognizedFormat:
          evidence.addPathSet(seen,
            readRecognizedDependencyReport($converterSpec.outputFormatName, path),
            recognized = true)
      except DependencyReportError as err:
        evidence.diagnostics.add("converted dependency report invalid: " & err.msg)
        result = false

proc defaultRunQuotaHelperPath(): string =
  let configured = getEnv("REPRO_RUNQUOTA_HELPER")
  if configured.len > 0:
    return configured
  raiseEngine("BuildEngineConfig.runQuotaCliPath or REPRO_RUNQUOTA_HELPER is required")

proc monitorCliPath(config: BuildEngineConfig): string =
  if config.monitorCliPath.len > 0:
    return config.monitorCliPath
  let configured = getEnv("REPRO_FS_SNOOP")
  if configured.len > 0:
    return configured
  # Windows: the fs-snoop binary is `repro-fs-snoop.exe` (ExeExt expansion).
  # Without the suffix the fileExists check below misses it. Use addFileExt
  # so the same logic works cross-platform.
  let appSibling = getAppDir() / addFileExt("repro-fs-snoop", ExeExt)
  if fileExists(extendedPath(appSibling)):
    return appSibling
  let repoBuild = getCurrentDir() / "build" / "bin" /
    addFileExt("repro-fs-snoop", ExeExt)
  if fileExists(extendedPath(repoBuild)):
    return repoBuild
  ""

proc sanitizeActionId(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "action"

proc actionIdFileSuffix(value: string): string =
  let hash = toHex(weakFingerprintFromText(value).bytes)
  hash[0 .. 15]

proc dependencyEvidencePath*(cacheRoot, actionId: string): string =
  cacheRoot / "dependency-evidence" /
    (sanitizeActionId(actionId) & "-" & actionIdFileSuffix(actionId) & ".rbar")

proc monitoredAction(action: BuildAction; config: BuildEngineConfig;
                     cacheRoot: string): tuple[action: BuildAction;
                                               diagnostic: string] =
  result.action = action
  if action.dependencyPolicy.kind notin MonitorPolicyKinds:
    return
  # Built-in actions (``kind != bakProcess`` — copy-file, write-text, stamp,
  # workspace-vcs, preserve-tree, binary-cache-substitute) run entirely
  # in-process via ``executeBuiltinAction``: there is no child process to
  # interpose on, so there is nothing for ``repro-fs-snoop`` to monitor and
  # nothing to gain from wrapping ``argv``. Their dependency evidence is the
  # statically declared inputs/outputs (and, for recognized/converter
  # policies, the post-build reports) — ``monitorEvidenceRequired`` already
  # returns false for them because no RMDF is ever wired. ``builtinAction``
  # tags every such action with the default ``automaticMonitorGatheringPolicy``
  # (a ``MonitorPolicyKinds`` member), so without this guard a built-in would
  # incorrectly fall into the fs-snoop wiring below and fail with a spurious
  # "requires repro-fs-snoop" diagnostic on any host without the snoop driver
  # wired (e.g. the hermetic workspace/VCS integration tests). Only
  # ``bakProcess`` actions spawn a monitorable subprocess.
  if action.kind != bakProcess:
    return
  # Direct engine callers may provide a monitor depfile path for actions that
  # produce RMDF evidence themselves. Preserve that prewired evidence path
  # instead of wrapping the command and overwriting it with fs-snoop output.
  if action.monitorDepfile.len > 0:
    return
  # Windows: automatic monitor dependency gathering now works on Windows via
  # the IAT-patching shim + CreateRemoteThread injection (see the shared
  # io-mon sibling: io_mon/shim/windows_interpose.nim and
  # io_mon/windows_injector.nim — Incremental-Test-Runner M7 relocated these
  # from reprobuild's former repro_monitor_shim / repro_monitor_depfile libs).
  # The same `repro-fs-snoop` driver is used as on macOS — only the underlying
  # injection mechanism differs.
  # Monitor-Hook-Shim.md:501 — when monitoring cannot be performed (no
  # fs-snoop wired, or an unsupported platform), the failure semantics are
  # "fail the monitored action OR make it non-cacheable, depending on
  # policy". A NON-CACHEABLE action is the "make it non-cacheable" branch:
  # it is always re-executed, so no cache entry's soundness depends on its
  # monitor evidence and there is nothing to gather. Run it unmonitored
  # (leave ``monitorDepfile`` empty so ``monitorEvidenceRequired`` stays
  # false) rather than failing it. This is the sanctioned home for pure
  # network actions with no monitorable file evidence — e.g. ``workspace
  # sync``'s ``git fetch`` (cacheable = false) — which must still run on a
  # host without the snoop driver wired (the hermetic workspace/VCS
  # integration tests). A CACHEABLE action still fails: caching it without
  # complete evidence would be the removed declared-only soundness hole.
  when not (defined(macosx) or defined(linux) or defined(windows)):
    if not action.cacheable:
      return
    result.diagnostic =
      "automatic monitor dependency gathering is unsupported on this platform"
  else:
    let monitorCli = monitorCliPath(config)
    if monitorCli.len == 0:
      if not action.cacheable:
        return
      result.diagnostic =
        "automatic monitor dependency gathering requires repro-fs-snoop"
      return
    let depfile = cacheRoot / "monitor-depfiles" /
      (sanitizeActionId(action.id) & ".rdep")
    result.action.monitorDepfile = depfile
    result.action.argv = @[monitorCli] & config.monitorCliArgs &
      @["--depfile", depfile, "--"] & action.argv
    # M9.R.13c.2: shim-library env seed is layered at LAUNCH time via
    # ``launchChildEnv`` (NOT here on ``result.action.env``). The seed
    # MUST NOT enter the action's fingerprint — the absolute path of
    # ``librepro_monitor_shim.{dll,so,dylib}`` is machine-specific
    # (varies by repro install location) so including it in ``env``
    # would make the action ID non-reproducible across machines and
    # invalidate the binary-cache lookup. See ``launchChildEnv`` for
    # the launch-time injection.

proc envTableFromArgvStyle(env: openArray[string]): StringTableRef =
  ## Convert the ``"NAME=VALUE"`` argv-style env (carried on BuildAction.env)
  ## into the StringTableRef shape that ``osproc.startProcess`` expects.
  ## Returns ``nil`` when no overrides are provided so the child inherits the
  ## parent process environment.
  if env.len == 0:
    return nil
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  for entry in env:
    let eq = entry.find('=')
    if eq <= 0:
      continue
    result[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

when defined(windows):
  proc ensureRunningProcessHandle(item: var RunningAction): Handle =
    ## Lazily open a SYNCHRONIZE-only HANDLE for the running child process,
    ## suitable for WaitForMultipleObjects. Cached on the RunningAction so
    ## each process is opened once and reused across wait iterations.
    if item.processWaitHandle != 0:
      return item.processWaitHandle
    let pid = processID(item.process)
    if pid <= 0:
      return 0
    let handle = openProcess(SYNCHRONIZE, WINBOOL(0), DWORD(pid))
    item.processWaitHandle = handle
    handle

  proc closeRunningProcessHandle(item: var RunningAction) =
    if item.processWaitHandle != 0:
      discard closeHandle(item.processWaitHandle)
      item.processWaitHandle = 0

  proc waitAnyProcessExitWindows(running: var seq[RunningAction];
                                 timeoutMs: int): int =
    ## Returns the index in `running` of the first process whose handle is
    ## signaled within `timeoutMs`, or -1 on timeout. Mirrors Ninja's
    ## event-driven wait (references/ninja/src/subprocess-win32.cc:260):
    ## one syscall, the OS wakes us when ANY child exits, no polling.
    ## Inline-runquota / queued / inline-failed running entries are not
    ## handle-based and are skipped here — the caller still checks them
    ## via pollCompletion / inlineFailure after this returns (the timeout
    ## gives the caller a cadence for those checks).
    var handles: WOHandleArray
    var indices: array[MAXIMUM_WAIT_OBJECTS, int]
    var count = 0
    for i in 0 ..< running.len:
      if count >= MAXIMUM_WAIT_OBJECTS:
        break
      case running[i].processKind
      of rpkHelperProcess, rpkBypassProcess:
        let h = ensureRunningProcessHandle(running[i])
        if h != 0:
          handles[count] = h
          indices[count] = i
          inc count
      else:
        discard
    if count == 0:
      return -1
    let ret = waitForMultipleObjects(DWORD(count), addr handles,
                                     WINBOOL(0), DWORD(timeoutMs))
    const WAIT_OBJECT_0_DWORD = DWORD(0)
    const WAIT_TIMEOUT_DWORD = DWORD(0x102)
    const WAIT_FAILED_DWORD = cast[DWORD](0xFFFFFFFF'u32)
    if ret == WAIT_TIMEOUT_DWORD or ret == WAIT_FAILED_DWORD:
      return -1
    let signaled = int(ret - WAIT_OBJECT_0_DWORD)
    if signaled < 0 or signaled >= count:
      return -1
    indices[signaled]

proc findPathKey(table: StringTableRef): string =
  ## Return the ``PATH`` env var key as it currently appears in
  ## ``table``, accounting for Windows' case-insensitive env-var
  ## naming. ``VsDevCmd.bat`` exports the variable as ``Path``;
  ## ``REPROBUILD_NO_RUNQUOTA`` etc. use uppercase. Returns
  ## ``"PATH"`` when the table doesn't already have an entry, so the
  ## new entry stays consistent with POSIX-style uppercase.
  for key, _ in table.pairs:
    if cmpIgnoreCase(key, "PATH") == 0:
      return key
  "PATH"

proc readPathValue(table: StringTableRef): string =
  ## Read the table's existing ``PATH`` value regardless of case.
  for key, value in table.pairs:
    if cmpIgnoreCase(key, "PATH") == 0:
      return value
  ""

proc prependPathDirsToArgvEnv(env: seq[string];
                              binDirs: openArray[string]): seq[string] =
  ## Walk an argv-style ``KEY=VALUE`` env list, collapse any
  ## case-variant ``PATH`` entries into one, and prepend ``binDirs``
  ## to the resulting ``PATH`` value. Used by the RunQuota helper-
  ## spawn path (which carries env as ``seq[string]`` rather than a
  ## ``StringTableRef``) so the same M9.N Batch B behaviour applies
  ## to the daemon-backed launch as well as the bypass launch.
  if binDirs.len == 0:
    return env
  let sep =
    when defined(windows): ";"
    else: ":"
  var pathValue = ""
  var pathSeen = false
  result = newSeqOfCap[string](env.len + 1)
  for entry in env:
    let eq = entry.find('=')
    if eq <= 0:
      result.add(entry)
      continue
    let key = entry[0 ..< eq]
    if cmpIgnoreCase(key, "PATH") == 0:
      # Last-write-wins matches the StringTableRef merge — keep the
      # most recent value, drop earlier duplicates.
      pathValue = entry[eq + 1 .. ^1]
      pathSeen = true
    else:
      result.add(entry)
  # M9.R.15q.3.3 — dedup the final PATH list so the env stays under
  # ARG_MAX even when 25+ buildDeps + a host PATH with overlapping
  # nix-shell entries pile up.
  var parts: seq[string] = @[]
  var seenP = initHashSet[string]()
  for d in binDirs:
    if d.len > 0 and d notin seenP:
      seenP.incl(d)
      parts.add(d)
  let trailing =
    if pathSeen: pathValue
    else: getEnv("PATH")
  if trailing.len > 0:
    for ent in trailing.split(sep):
      if ent.len > 0 and ent notin seenP:
        seenP.incl(ent)
        parts.add(ent)
  result.add("PATH=" & parts.join(sep))

proc prependPathDirs(table: StringTableRef; binDirs: openArray[string]) =
  ## Prepend ``binDirs`` to the table's existing ``PATH`` value,
  ## preserving case-insensitive key match on Windows. Removes any
  ## duplicate ``Path`` / ``PATH`` entries so the final env carries
  ## a single canonical ``PATH``.
  if table == nil or binDirs.len == 0:
    return
  let sep =
    when defined(windows): ";"
    else: ":"
  # M9.R.15q.3.3 — dedup as in the argv-style counterpart so a host
  # PATH with overlapping nix-shell + scoop entries doesn't push the
  # combined env past ARG_MAX.
  var parts: seq[string] = @[]
  var seenP = initHashSet[string]()
  for d in binDirs:
    if d.len > 0 and d notin seenP:
      seenP.incl(d)
      parts.add(d)
  let existing = readPathValue(table)
  if existing.len > 0:
    for ent in existing.split(sep):
      if ent.len > 0 and ent notin seenP:
        seenP.incl(ent)
        parts.add(ent)
  let combined = parts.join(sep)
  # Remove any case-variant duplicates so the resulting table only
  # has one PATH key. Without this step Windows' StartProcess sees
  # both ``PATH`` and ``Path`` and may pick the wrong one.
  var keysToDel: seq[string] = @[]
  for key, _ in table.pairs:
    if cmpIgnoreCase(key, "PATH") == 0:
      keysToDel.add(key)
  for key in keysToDel:
    table.del(key)
  table["PATH"] = combined

proc prependEnvDirs*(table: StringTableRef; varName: string;
                     dirs: openArray[string]) =
  ## DSL-port M9.R.14e.3 — generalisation of ``prependPathDirs`` for the
  ## per-tool auxiliary search-path channels (``PKG_CONFIG_PATH``,
  ## ``CMAKE_PREFIX_PATH``, ``CPATH``, ``LIBRARY_PATH``,
  ## ``LD_LIBRARY_PATH``). Unlike ``prependPathDirs``, this MUST honour
  ## the case-EXACT key name (Linux env vars are case-sensitive; Windows
  ## doesn't carry these vars natively). When the table already has the
  ## var, prepend with the platform path separator; otherwise inherit
  ## from the process env so a downstream tool that consults the var
  ## still sees the host's existing value as a fallback.
  ##
  ## M9.R.15q.3.3 — dedupe the final colon/semicolon-separated list so
  ## an action env that inherits a CMAKE_PREFIX_PATH from the host
  ## (set by nix-shell or a sibling resolver layer) doesn't end up
  ## with duplicate entries from the newly prepended ``dirs``. ARG_MAX
  ## hits at ~2 MB on Linux, and large recipes (plasma-framework, kwin)
  ## blow past it without dedup.
  if table == nil or dirs.len == 0:
    return
  let sep =
    when defined(windows): ";"
    else: ":"
  var parts: seq[string] = @[]
  var seen = initHashSet[string]()
  for d in dirs:
    if d.len > 0 and d notin seen:
      seen.incl(d)
      parts.add(d)
  if parts.len == 0:
    return
  let existing =
    if table.hasKey(varName): table[varName]
    else: getEnv(varName)
  if existing.len > 0:
    for ent in existing.split(sep):
      if ent.len > 0 and ent notin seen:
        seen.incl(ent)
        parts.add(ent)
  table[varName] = parts.join(sep)

proc prependEnvDirsToArgvEnv*(env: seq[string]; varName: string;
                              dirs: openArray[string]): seq[string] =
  ## Argv-style counterpart of ``prependEnvDirs``. Walks an argv-style
  ## ``KEY=VALUE`` env list, dedupes any existing entries for
  ## ``varName``, and prepends ``dirs`` to the resulting value. Mirrors
  ## ``prependPathDirsToArgvEnv``'s last-write-wins semantics.
  ##
  ## M9.R.15q.3.3 — dedupe the colon/semicolon-separated list so an env
  ## inheriting CMAKE_PREFIX_PATH from the host (set by nix-shell or a
  ## sibling resolver layer) doesn't end up with duplicate entries on
  ## top of the new ``dirs``. Same ARG_MAX rationale as the table-form
  ## counterpart above.
  if dirs.len == 0:
    return env
  let sep =
    when defined(windows): ";"
    else: ":"
  var existing = ""
  var seen = false
  result = newSeqOfCap[string](env.len + 1)
  for entry in env:
    let eq = entry.find('=')
    if eq <= 0:
      result.add(entry)
      continue
    let key = entry[0 ..< eq]
    if key == varName:
      existing = entry[eq + 1 .. ^1]
      seen = true
    else:
      result.add(entry)
  var parts: seq[string] = @[]
  var seenDirs = initHashSet[string]()
  for d in dirs:
    if d.len > 0 and d notin seenDirs:
      seenDirs.incl(d)
      parts.add(d)
  if parts.len == 0:
    if seen:
      result.add(varName & "=" & existing)
    return result
  let trailing =
    if seen: existing
    elif not seen: getEnv(varName)
    else: ""
  if trailing.len > 0:
    for ent in trailing.split(sep):
      if ent.len > 0 and ent notin seenDirs:
        seenDirs.incl(ent)
        parts.add(ent)
  result.add(varName & "=" & parts.join(sep))

proc kindForRef(action: BuildAction; index: int): DepKind {.inline.} =
  ## DSL-port M9.R.7. Per-ref dep-kind lookup. When the action carries
  ## a parallel ``toolIdentityRefKinds`` array of the same length as
  ## ``toolIdentityRefs``, returns the corresponding entry; otherwise
  ## defaults to ``dkBuild`` — the legacy ``uses:`` semantics where
  ## every ref is routed against the HOST-platform cache key (which
  ## collapses to ``"native"`` on a native build).
  if action.toolIdentityRefKinds.len == action.toolIdentityRefs.len and
      index >= 0 and index < action.toolIdentityRefKinds.len:
    action.toolIdentityRefKinds[index]
  else:
    dkBuild

proc resolvedToolBinDirs(action: BuildAction;
                         resolver: ToolIdentityResolver): seq[string] =
  ## M9.N Batch B + DSL-port M9.R.7. Walk
  ## ``action.toolIdentityRefs`` through the engine's
  ## ``ToolIdentityResolver`` and return the in-order list of binary
  ## directories to prepend to the action's ``PATH``. The first ref's
  ## first ``binDir`` ends up leftmost in PATH so a ref order of
  ## ``@["meson", "gcc"]`` puts meson's bin dir BEFORE gcc's — useful
  ## when two refs share a directory and tool-of-record semantics
  ## matter. ``none`` returns or empty ``binDirs`` are silently skipped:
  ## the catalog signals "no contribution for this ref" by returning
  ## ``none`` and the engine then leaves PATH untouched for that ref.
  ##
  ## M9.R.7: the resolver receives a per-ref ``DepKind`` so it can
  ## route the materialization cache lookup against the correct
  ## platform-tagged cache key. On a native build the choice is
  ## inert — both platforms collapse to ``"native"`` — so existing
  ## recipes get byte-identical PATH ordering.
  ##
  ## Returns an empty seq when the action carries no refs OR when the
  ## resolver is nil — both paths skip the PATH-override layer below
  ## so legacy actions and unconfigured engines behave byte-for-byte
  ## as before this milestone.
  if action.toolIdentityRefs.len == 0 or resolver == nil:
    return @[]
  result = @[]
  for i, refName in action.toolIdentityRefs:
    let kind = kindForRef(action, i)
    let resolved = resolver(refName, kind)
    if resolved.isNone:
      continue
    for binDir in resolved.get().binDirs:
      if binDir.len > 0:
        result.add(binDir)

type
  ResolvedAuxPaths* = object
    ## DSL-port M9.R.14e.3 — accumulated per-action auxiliary search
    ## paths gathered from every ref's ``ResolvedToolIdentity``. The
    ## engine threads each list onto a dedicated env var at fork time
    ## (see ``applyResolvedAuxPathsTable`` /
    ## ``applyResolvedAuxPathsArgv``). Defaults to empty (no refs / nil
    ## resolver / non-from-source profiles) — the env-prepend pass is
    ## then a no-op.
    pkgConfigDirs*: seq[string]
    cmakePrefixDirs*: seq[string]
    includeDirs*: seq[string]
    libDirs*: seq[string]

proc collectResolvedAuxPaths(action: BuildAction;
                             resolver: ToolIdentityResolver):
    ResolvedAuxPaths =
  ## Walk every ``toolIdentityRefs`` entry through the resolver and
  ## accumulate the in-order union of each ref's aux-path lists. Same
  ## semantics as ``resolvedToolBinDirs`` but for the four extra search-
  ## path channels.
  if action.toolIdentityRefs.len == 0 or resolver == nil:
    return
  # M9.R.15q.3.3 — dedup at union time to keep the rendered env vars
  # from exploding to E2BIG.  Without dedup, plasma-framework (25
  # buildDeps) emits a CMAKE_PREFIX_PATH > 100 KB because each ref's
  # transitive walk yields overlapping prefix roots and every duplicate
  # appears on the action env. The execve(2) ``Argument list too long``
  # failure in M9.R.15q.3 driving plasma-framework was the trigger —
  # ARG_MAX on Linux is 2 MB combined argv + env, and the bulk of that
  # was duplicate cmakePrefixList paths.
  #
  # Order semantics: keep the FIRST occurrence (in-order union), drop
  # later duplicates. cmake / pkg-config / ld read these vars left-to-
  # right so the first-found wins, identical to the previous behaviour
  # for the dirs that aren't duplicated.
  var seenPkgConfig: HashSet[string] = initHashSet[string]()
  var seenCmakePrefix: HashSet[string] = initHashSet[string]()
  var seenInclude: HashSet[string] = initHashSet[string]()
  var seenLib: HashSet[string] = initHashSet[string]()
  for i, refName in action.toolIdentityRefs:
    let kind = kindForRef(action, i)
    let resolved = resolver(refName, kind)
    if resolved.isNone:
      continue
    let r = resolved.get()
    for d in r.pkgConfigDirs:
      if d.len > 0 and d notin seenPkgConfig:
        seenPkgConfig.incl(d)
        result.pkgConfigDirs.add(d)
    for d in r.cmakePrefixDirs:
      if d.len > 0 and d notin seenCmakePrefix:
        seenCmakePrefix.incl(d)
        result.cmakePrefixDirs.add(d)
    for d in r.includeDirs:
      if d.len > 0 and d notin seenInclude:
        seenInclude.incl(d)
        result.includeDirs.add(d)
    for d in r.libDirs:
      if d.len > 0 and d notin seenLib:
        seenLib.incl(d)
        result.libDirs.add(d)

proc applyResolvedAuxPathsTable*(env: StringTableRef;
                                 paths: ResolvedAuxPaths) =
  ## StringTable-style env mutator. Used by the bypass-spawn path. Each
  ## env var is prepended in-place via ``prependEnvDirs``.
  ##
  ## ``PKG_CONFIG_PATH_FOR_TARGET`` is set IN ADDITION TO
  ## ``PKG_CONFIG_PATH`` because nixpkgs's pkg-config-wrapper consults
  ## ``PKG_CONFIG_PATH_FOR_{BUILD,TARGET}`` and IGNORES the standard
  ## ``PKG_CONFIG_PATH`` env var when those nix-specific ones are set
  ## (which they are inside any ``nix-shell`` invocation). Setting both
  ## keeps the behaviour correct against both host pkg-config (which
  ## reads ``PKG_CONFIG_PATH``) and the nix wrapper.
  if env == nil:
    return
  prependEnvDirs(env, "PKG_CONFIG_PATH", paths.pkgConfigDirs)
  prependEnvDirs(env, "PKG_CONFIG_PATH_FOR_TARGET", paths.pkgConfigDirs)
  prependEnvDirs(env, "PKG_CONFIG_PATH_FOR_BUILD", paths.pkgConfigDirs)
  prependEnvDirs(env, "CMAKE_PREFIX_PATH", paths.cmakePrefixDirs)
  prependEnvDirs(env, "CPATH", paths.includeDirs)
  prependEnvDirs(env, "LIBRARY_PATH", paths.libDirs)
  # LD_LIBRARY_PATH covers run-time test execution; LIBRARY_PATH covers
  # link-time. Same set of dirs feeds both.
  prependEnvDirs(env, "LD_LIBRARY_PATH", paths.libDirs)

proc applyResolvedAuxPathsArgv*(env: seq[string];
                                paths: ResolvedAuxPaths): seq[string] =
  ## Argv-style env mutator. Used by the RunQuota-helper-spawn +
  ## inline-runquota paths. See ``applyResolvedAuxPathsTable`` for
  ## the rationale on ``PKG_CONFIG_PATH_FOR_{TARGET,BUILD}``.
  result = env
  result = prependEnvDirsToArgvEnv(result, "PKG_CONFIG_PATH", paths.pkgConfigDirs)
  result = prependEnvDirsToArgvEnv(result, "PKG_CONFIG_PATH_FOR_TARGET",
    paths.pkgConfigDirs)
  result = prependEnvDirsToArgvEnv(result, "PKG_CONFIG_PATH_FOR_BUILD",
    paths.pkgConfigDirs)
  result = prependEnvDirsToArgvEnv(result, "CMAKE_PREFIX_PATH", paths.cmakePrefixDirs)
  result = prependEnvDirsToArgvEnv(result, "CPATH", paths.includeDirs)
  result = prependEnvDirsToArgvEnv(result, "LIBRARY_PATH", paths.libDirs)
  result = prependEnvDirsToArgvEnv(result, "LD_LIBRARY_PATH", paths.libDirs)

proc launchChildEnv(action: BuildAction;
                    config: BuildEngineConfig): seq[string] =
  ## Nested-build resource model: an action's child process tree may itself
  ## invoke ``repro build`` (the e2e/integration tests spawn an *inner*
  ## ``repro``). The OUTER action is the unit RunQuota schedules — it holds a
  ## lease whose measurement already covers its whole process group (peak
  ## RSS + process count), so the inner build's resource use is accounted to
  ## the outer lease. What must NOT happen is the inner ``repro`` acquiring
  ## its OWN lease from the same daemon: it would request a second lease from
  ## the pool while the parent already holds the outer action's lease, a
  ## parent⇄child cycle the scheduler can only surface as ``build graph made
  ## no progress``. (Clearing ``RUNQUOTA_SOCKET`` alone is insufficient —
  ## ``runquota_ipc`` falls back to the default ``XDG_RUNTIME_DIR``/``TMPDIR``
  ## socket path and reconnects to the very same daemon.)
  ##
  ## So we set ``REPROBUILD_NO_RUNQUOTA=1`` (the documented full-bypass
  ## switch, equivalent to ``--no-runquota``) in every action child env: an
  ## inner ``repro`` runs its own actions unmanaged, as ordinary child
  ## processes of the outer leased action, and its CPU/memory rolls up into
  ## the outer lease's group measurement — exactly the "outer managed, inner
  ## unmanaged, outer measures the whole tree" model.
  ##
  ## The runquota launcher (``runquota_process.applyChildEnv`` on POSIX /
  ## ``windowsChildEnv`` on Windows) and ``envTableFromArgvStyle`` both LAYER
  ## this over the inherited environment, so ``PATH`` etc. survive. The value
  ## is constant, so it does not perturb the action-cache fingerprint, and is
  ## inert for the ~99% of actions (plain ``nim c`` compiles) whose children
  ## never invoke ``repro``. Any explicit ``action.env`` entry wins (appended
  ## after).
  result = @["REPROBUILD_NO_RUNQUOTA=1"]
  # M9.R.13c.2 — **shim-library env seed**. Inject
  # ``REPRO_MONITOR_SHIM_LIB`` at launch time so the daemon-spawned
  # ``repro internal fs-snoop`` subprocess deterministically locates
  # ``librepro_monitor_shim.{dll,so,dylib}`` without having to inherit
  # the user's shell environment. The seed lives HERE — not in
  # ``result.action.env`` — because the absolute shim path is machine-
  # specific (varies by repro install location); putting it in the
  # action's env would make the action ID non-reproducible across
  # machines and invalidate the binary-cache lookup. The seed is
  # constant across actions on the same machine (one repro install
  # surface) so it does not perturb action-ordering or partitioning.
  # An explicit ``action.env`` override wins because the action env
  # is appended AFTER the seed and ``envTableFromArgvStyle``'s overlay
  # is last-write-wins.
  let shimLib = findShimLibrary()
  if shimLib.len > 0:
    result.add("REPRO_MONITOR_SHIM_LIB=" & shimLib)
  # macOS monitoring needs NO env seed: the io-mon shim always runs BOTH
  # monitoring mechanisms (interpose + body-patch) by default — the
  # user-facing ``IO_MON_MACOS_BACKEND`` selector was removed (see
  # ``MacOS-Interpose-Limitations-Under-Chained-Fixups.md``). The two layers
  # are additive, not redundant: interpose redirects the monitored binary's own
  # import-stub ``open``/``read`` calls before they reach libsystem, while the
  # ``mach_vm_remap`` body-patch overwrites the libsystem wrapper bodies and so
  # catches the shared-cache-internal and ``$NOCANCEL`` calls interpose
  # structurally cannot see. The engine therefore just injects the shim
  # (``REPRO_MONITOR_SHIM_LIB`` above) and lets it "just work" — no backend
  # selection. (io-mon keeps DEBUG-only per-mechanism diagnostic toggles, but
  # those are for local A/B diagnosis, not something the engine seeds.)
  for entry in action.env:
    result.add(entry)
  # M9.N Batch B: the resolved-tool ``PATH`` prepend happens in
  # ``envTableFromArgvStyle`` rather than as a ``PATH=...`` argv entry
  # so that Windows' case-insensitive env-var matching (``Path`` vs
  # ``PATH``) is honoured. The argv-style env is filtered into a
  # ``StringTableRef`` first, then ``prependPathDirs`` (next to that
  # filter) does a single case-insensitive PATH override. This avoids
  # the "MSVC's ``Path`` and the action's ``PATH`` are stored as
  # separate keys; Windows CreateProcess picks one" pitfall.

proc bypassActionLogDir(cacheRoot: string): string =
  ## **M1 milestone** (Windows-bypass-stdio-capture). Per-action log
  ## files live under ``<cacheRoot>/actions/`` so the same scratch dir
  ## that already holds ``runquota-results/`` and ``monitor-depfiles/``
  ## also owns the bypass-path stdio captures. ``repro clean`` (which
  ## wipes ``cacheRoot``) reclaims them with the rest of the per-build
  ## transient state.
  cacheRoot / "actions"

when defined(macosx):
  # Portable-Macos-Sandbox-Tools B1: the bypass launch path must NOT route a
  # MONITORED action through the System-Integrity-Protection-protected
  # ``/bin/sh``. On macOS / Apple Silicon, SIP strips ``DYLD_INSERT_LIBRARIES``
  # when a SIP-protected binary is exec'd, so wrapping the io-mon monitor
  # invocation in an outer ``/bin/sh -c`` places a SIP boundary at the very top
  # of the action's process tree — the monitor's shim injection then degrades
  # (the io-mon banner reports ``failed`` hooks / ``spawn_tramp=skip``) and the
  # monitored subtree goes partially blind. The fix, grounded in
  # ``Sandbox-And-Monitoring.md`` (~line 575, "SIP path rewriting from
  # propagation.nim") and ``MacOS-Interpose-Limitations-Under-Chained-Fixups.md``
  # (the drop-in / ``CT_SANDBOX_TOOLS_DIR`` mechanism), is to wrap the action in
  # a NON-SIP shell instead: the ``<CT_SANDBOX_TOOLS_DIR>/bin/sh`` drop-in when
  # present, else any non-SIP ``sh`` resolvable on PATH (the dev shell's
  # Nix/Homebrew bash). The shim then loads in the wrapper shell and propagates
  # into the whole tree.
  #
  # The SIP-prefix predicate is reused from the shared
  # ``stackable_hooks/propagation`` module that io-mon itself uses
  # (``isSipProtected`` / ``sipProtectedPrefixes``) so the engine and the
  # monitor agree byte-for-byte on what counts as SIP-protected — DRY per the
  # spec's "reuse io-mon's existing population rather than re-implementing it".
  import stackable_hooks/propagation as sip_propagation

  proc resolveNonSipShell*(): string =
    ## Resolve a non-SIP POSIX shell suitable for wrapping a monitored
    ## action's redirection (`sh -c "<argv> > out 2> err"`). Resolution order:
    ##
    ## 1. ``<CT_SANDBOX_TOOLS_DIR>/bin/sh`` — the drop-in the io-mon monitor
    ##    populates (``populateReproSandboxTools``). This is the canonical
    ##    SIP-rewrite target (``rewriteSipPath("/bin/sh", dir)``), so reusing it
    ##    keeps the engine's wrapper shell identical to the one the monitor's
    ##    own exec-redirect would pick.
    ## 2. The first non-SIP ``sh`` on ``PATH`` (e.g. the Nix dev shell's bash).
    ##    ``isSipProtected`` rejects ``/bin``, ``/sbin``, ``/usr/bin``,
    ##    ``/usr/sbin`` candidates so a SIP shell is never selected here.
    ##
    ## Returns ``""`` when only SIP-protected shells are available — the caller
    ## then enforces the Monitor-Hook-Shim.md:501 fail-safe for monitored
    ## actions (injection failure MUST fail the action / make it non-cacheable).
    let sandboxDir = getEnv("CT_SANDBOX_TOOLS_DIR")
    if sandboxDir.len > 0:
      let dropInSh = sip_propagation.rewriteSipPath("/bin/sh", sandboxDir)
      if fileExists(dropInSh) or symlinkExists(dropInSh):
        return dropInSh
    let pathEnv = getEnv("PATH")
    for entry in pathEnv.split(PathSep):
      if entry.len == 0:
        continue
      let candidate = entry / "sh"
      if not fileExists(candidate):
        continue
      if sip_propagation.isSipProtected(candidate):
        continue
      return candidate
    ""

proc bypassActionStdoutLogPath(cacheRoot, actionId: string): string =
  bypassActionLogDir(cacheRoot) / (actionId & ".stdout.log")

proc bypassActionStderrLogPath(cacheRoot, actionId: string): string =
  bypassActionLogDir(cacheRoot) / (actionId & ".stderr.log")

proc readBypassActionLog(path: string): string =
  ## Read a bypass-mode per-action log file. Missing-file is the common
  ## "tool produced no output" case and is squashed to an empty string;
  ## any other error is also squashed (the bypass path is best-effort
  ## diagnostic capture — a failed read mustn't escalate into an engine
  ## failure that hides the real action failure).
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
  except CatchableError:
    ""

proc stripMonitorBanner*(captured: string): string =
  ## Portable-Macos-Sandbox-Tools B2: the io-mon shim writes a per-process
  ## diagnostic banner to stderr on every monitored (grand)child
  ## (``io-mon: macOS body-patch installed=… failed=… spawn_tramp=…``). For a
  ## deep autotools process tree this banner is emitted dozens of times and
  ## floods the captured ``<id>.stderr.log``, burying the failing command's
  ## REAL error. ``Monitor-Hook-Shim.md`` (Acceptance Criteria, "child
  ## stdout/stderr pass through without corrupting monitor event streams") and
  ## §"conservative failure diagnostics" require the monitor's own noise to be
  ## separable from the action's output so a failing action shows its actual
  ## error. This strips the monitor banner lines from the surfaced stderr; the
  ## raw on-disk log is left untouched for deep inspection.
  ##
  ## All io-mon macOS banner lines begin ``io-mon: macOS body-patch `` — both the
  ## install banner (``… installed=… failed=… spawn_tramp=…``, optionally with a
  ## debug ``[debug] interpose disabled`` note) and the body-patch-skipped line
  ## (``… not installed [debug] body-patch disabled``). The legacy
  ## ``io-mon: macOS backend=…`` banner no longer exists (the
  ## ``IO_MON_MACOS_BACKEND`` selector was removed; both mechanisms are always
  ## on), so a single prefix match covers every current banner line.
  if captured.len == 0:
    return captured
  var kept: seq[string] = @[]
  for line in captured.splitLines:
    if line.startsWith("io-mon: macOS body-patch "):
      continue
    kept.add(line)
  kept.join("\n")

proc umaskWrappedArgv*(argv: openArray[string]): seq[string] =
  ## M9.R.36.3 — wrap an action's argv in a POSIX ``/bin/sh -c "umask 022
  ## && <argv>"`` invocation so every spawned tool inherits the canonical
  ## ``rw-r--r--`` (0644) / ``rwxr-xr-x`` (0755) file-creation mask.
  ##
  ## M9.R.35.1 lifted this pin into ``startBypassRunQuotaProcess`` (the
  ## ``bypassRunQuota`` path used by direct ``--daemon=off`` invocations).
  ## M9.R.36.3 extends the same pin to the runquota helper-spawn path AND
  ## the inline-runquota batch path, both of which forward an action's
  ## argv unchanged to ``launchProcess`` inside the runquotad helper —
  ## meaning a daemon-mode build would otherwise still hit the umask
  ## drift channel documented in ``startBypassRunQuotaProcess``.
  ##
  ## On Windows the umask concept does not apply and the wrapper would
  ## introduce a ``/bin/sh`` dependency that the Windows build doesn't
  ## have; on non-POSIX platforms this is the identity transform.
  ##
  ## Behaviour for an empty argv is the identity transform — callers can
  ## blindly delegate without a pre-check, and downstream "empty argv"
  ## guards keep their own error surface unchanged.
  result = newSeqOfCap[string](argv.len)
  when defined(posix):
    if argv.len == 0:
      for entry in argv: result.add(entry)
      return result
    var quoted = ""
    for i, a in argv:
      if i > 0: quoted.add(" ")
      quoted.add(quoteShell(a))
    result.add("/bin/sh")
    result.add("-c")
    result.add("umask 022 && " & quoted)
  else:
    for entry in argv: result.add(entry)

proc startBypassRunQuotaProcess(action: BuildAction;
                                config: BuildEngineConfig): Process =
  ## Path-mode escape hatch: spawn the action's argv directly via osproc,
  ## bypassing the RunQuota helper. Only used when
  ## ``BuildEngineConfig.bypassRunQuota`` is true (currently set on
  ## Windows under ``--tool-provisioning=path`` AND whenever the
  ## ``fallbackToRunQuotaBypass`` probe sees an unreachable runquotad).
  ## All resource accounting, named-pool leases, and quota enforcement
  ## are skipped — the engine still honours its own ``poolRunning``
  ## capacity tracking so action graphs that declare pools stay
  ## sequenced, but no daemon-side enforcement happens.
  ##
  ## **Stdio (M1 milestone, Windows-bypass-stdio-capture)**: each
  ## action gets a pair of dedicated log files under
  ## ``<cacheRoot>/actions/<id>.{stdout,stderr}.log`` and the child's
  ## stdout / stderr are routed there via a tiny shell wrapper
  ## (``cmd /D /C`` on Windows, ``sh -c`` on POSIX). The wrapper does
  ## the redirection in the kernel — there is no Nim-side pipe drainer
  ## involved — so the multi-process pipe-buffer deadlock that the
  ## previous ``poStdErrToStdOut`` experiment hit (cargo spawning
  ## rustc spawning link.exe collectively filling a shared kernel
  ## pipe buffer faster than one Nim reader thread could drain) does
  ## NOT recur here. ``finishBypassRunQuotaProcess`` reads the two
  ## files back and stuffs their contents into the same
  ## ``writeBypassResultJson`` payload the helper-path parser already
  ## consumes, so the build-report's per-action ``stdout`` / ``stderr``
  ## fields are now populated under bypass too. This is "option (3)"
  ## from the bypass-stdio design discussion (file-tee per action,
  ## not pipe inheritance).
  ##
  ## Under direct (non-daemon) invocations the user no longer sees the
  ## action's output streaming in the terminal — they see it via the
  ## build report instead. ``repro why <action-id>`` reads the same
  ## result JSON for the same content; the log files themselves stay
  ## on disk under ``cacheRoot`` for ad-hoc inspection.
  if action.argv.len == 0:
    raiseEngine("bypassRunQuota: action has empty argv: " & action.id)
  # MR8: prepend the cached MSVC dev-env diff on Windows so daemon-spawned
  # cargo / cc-rs / link.exe actions land on a coherent MSVC toolchain
  # (cl.exe on PATH + INCLUDE/LIB/LIBPATH/VCToolsInstallDir/WindowsSdk*).
  # No-op on non-Windows and when VS Build Tools is not installed; the
  # action's own ``env`` entries override on key collision.
  let cacheRoot = config.cacheRoot
  let mergedEnv = mergeActionEnvWithMsvc(launchChildEnv(action, config))
  var env = envTableFromArgvStyle(mergedEnv)
  # M9.N Batch B: prepend the resolved-tool bin dirs to PATH after the
  # MSVC + action env layers have been merged into the StringTableRef.
  # Doing it here (not as a PATH= argv entry) ensures case-insensitive
  # key matching on Windows (``Path`` vs ``PATH``) so the resolved
  # dirs win regardless of which casing the upstream merge produced.
  let binDirs = resolvedToolBinDirs(action, config.toolIdentityResolver)
  let auxPaths = collectResolvedAuxPaths(action, config.toolIdentityResolver)
  let hasAuxPaths = auxPaths.pkgConfigDirs.len + auxPaths.cmakePrefixDirs.len +
    auxPaths.includeDirs.len + auxPaths.libDirs.len > 0
  if binDirs.len > 0 or hasAuxPaths:
    if env == nil:
      env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        env[key] = value
    if binDirs.len > 0:
      prependPathDirs(env, binDirs)
    if hasAuxPaths:
      applyResolvedAuxPathsTable(env, auxPaths)
  let cwd = if action.cwd.len > 0: action.cwd else: getCurrentDir()
  let stdoutLog = bypassActionStdoutLogPath(cacheRoot, action.id)
  let stderrLog = bypassActionStderrLogPath(cacheRoot, action.id)
  createDir(extendedPath(bypassActionLogDir(cacheRoot)))
  # Truncate any prior log so a re-run doesn't read stale content from
  # a previous launch of the same action id.
  try: writeFile(extendedPath(stdoutLog), "")
  except CatchableError: discard
  try: writeFile(extendedPath(stderrLog), "")
  except CatchableError: discard
  # Build the shell-wrapped command. ``quoteShell`` handles each argv
  # element per the host platform's shell rules; both branches end up
  # with one redirected-output pipeline that ``cmd`` / ``sh`` will
  # tokenize back into argv before exec'ing the real tool.
  var quotedArgv = ""
  for i, a in action.argv:
    if i > 0: quotedArgv.add(" ")
    quotedArgv.add(quoteShell(a))
  let redirectedArgv =
    quotedArgv & " > " & quoteShell(stdoutLog) &
      " 2> " & quoteShell(stderrLog)
  when defined(windows):
    # ``/D`` disables AutoRun (HKCU\Software\Microsoft\Command Processor\
    # AutoRun) so a user-injected init script can't mutate the action's
    # environment; ``/C`` runs the command and terminates. Path lookup
    # for the real tool is delegated to ``cmd`` rather than ``startProcess``
    # because the wrapped command line itself contains the tool name.
    result = startProcess("cmd.exe",
      args = @["/D", "/C", redirectedArgv],
      env = env,
      workingDir = cwd,
      options = {poUsePath})
  else:
    # POSIX wrapper shell. On Linux ``/bin/sh`` is not SIP-protected so it is
    # used directly. On macOS a MONITORED action (one the engine wrapped with
    # the io-mon monitor — ``action.monitorDepfile.len > 0``) MUST NOT be routed
    # through the SIP-protected ``/bin/sh`` (B1): that strips
    # ``DYLD_INSERT_LIBRARIES`` at the top of the tree and degrades injection.
    var wrapperShell = "/bin/sh"
    when defined(macosx):
      if action.monitorDepfile.len > 0:
        wrapperShell = resolveNonSipShell()
        if wrapperShell.len == 0:
          # Monitor-Hook-Shim.md:501 fail-safe: monitoring is required for this
          # action but no injectable (non-SIP) wrapper shell is available, so we
          # cannot launch it without losing shim injection on macOS. Running it
          # under the SIP ``/bin/sh`` anyway would silently produce incomplete
          # dependency evidence and let it be cached as if its deps were fully
          # captured — exactly the "successful child exit MUST NOT hide monitor
          # failure" hazard the spec forbids. Fail the launch conservatively
          # instead; ``runBuild`` surfaces this as an action failure (and the
          # action is therefore never published to the cache).
          raiseEngine(
            "monitored action " & action.id & " cannot be launched SIP-safely " &
            "on macOS: no non-SIP shell found (set CT_SANDBOX_TOOLS_DIR to a " &
            "drop-in bundle or provide a non-SIP sh on PATH). Refusing to run " &
            "under SIP /bin/sh, which would strip DYLD_INSERT_LIBRARIES and " &
            "produce incomplete, non-cacheable monitor evidence.")
    # M9.R.35.1 — pin the action's umask to a deterministic 022 so every
    # spawned tool creates files with the canonical ``rw-r--r--``
    # (0644) / ``rwxr-xr-x`` (0755) permissions. Without this pin, the
    # umask is inherited from whatever shell launched ``repro build``
    # — and on WSL the inherited value can drift between invocations
    # (observed: Qt6 ``qmlcachegen`` emitting ``qmlcache_loader.cpp``
    # at modes ``0300`` / ``0254`` / ``0044`` / ``0204``, which then
    # trips a downstream ``cc1plus: fatal error: <file>: Permission
    # denied``).  qmlcachegen calls ``QSaveFile::open`` which delegates
    # to ``QTemporaryFileEngine::initialize(0666)``, then commits via
    # rename(); the kernel applies the calling process's umask at
    # ``mkstemp`` time, so any process-state umask drift in the
    # CMake → ninja → qmlcachegen fork chain bleeds into the final
    # file's mode bits.  Pinning umask at the shell-wrap level closes
    # the drift channel for every build action, not just qmlcachegen
    # — the same protection benefits any tool that relies on the
    # process umask for file-creation modes (mostly: every tool that
    # uses libc's ``fopen`` / ``mkstemp`` / ``open(O_CREAT)`` without
    # an explicit ``mode`` argument).
    #
    # Reconciliation note (merge of M9.R.35.1 umask-pin + the io-mon
    # SIP-safe-launch work): the umask wrap and the non-SIP wrapper-shell
    # selection are orthogonal and both required on macOS. We DELIBERATELY
    # run ``umask 022 && …`` through ``wrapperShell`` (the non-SIP shell
    # resolved above for monitored actions) rather than the SIP-protected
    # ``/bin/sh`` — using ``/bin/sh`` here would re-introduce the
    # DYLD_INSERT_LIBRARIES-stripping hazard for monitored macOS actions.
    # For Linux / non-monitored actions ``wrapperShell`` is ``/bin/sh``, so
    # the umask determinism is preserved unchanged on those paths.
    let wrapped = "umask 022 && " & redirectedArgv
    result = startProcess(wrapperShell,
      args = @["-c", wrapped],
      env = env,
      workingDir = cwd,
      options = {})

proc startRunQuotaProcess(action: BuildAction; config: BuildEngineConfig;
                          resultPath: string; bypassRunQuota: bool): Process =
  if bypassRunQuota:
    return startBypassRunQuotaProcess(action, config)
  let rq = ReproResourceRequest(
    label: action.id,
    commandStatsId: action.commandStatsId,
    cpuMilli: action.cpuMilli,
    memoryBytes: action.memoryBytes,
    namedPool: action.pool,
    namedPoolUnits: action.poolUnits)
  # MR8: prepend the cached MSVC dev-env diff on Windows so the
  # runquota helper hands the action a coherent MSVC toolchain
  # (cl.exe / INCLUDE / LIB / LIBPATH / VCToolsInstallDir / WindowsSdk*).
  # The action's own ``env`` entries are appended after, so any
  # recipe-supplied overrides win on key collision. No-op on non-Windows
  # and when VS Build Tools is not installed.
  let mergedEnv = mergeActionEnvWithMsvc(launchChildEnv(action, config))
  let toolBinDirs = resolvedToolBinDirs(action, config.toolIdentityResolver)
  let auxPaths = collectResolvedAuxPaths(action, config.toolIdentityResolver)
  var threadedEnv = prependPathDirsToArgvEnv(mergedEnv, toolBinDirs)
  threadedEnv = applyResolvedAuxPathsArgv(threadedEnv, auxPaths)
  # M9.R.36.3 — same umask-022 pin we apply on the bypass path. The
  # runquota helper forwards ``command.argv`` straight through to its
  # ``launchProcess`` call site, so without this wrap the daemon-mode
  # build inherits whatever umask the runquotad daemon's parent shell
  # had — recreating the qmlcachegen mode-corruption channel that
  # M9.R.35.1 closed on the ``bypassRunQuota`` path.
  let command = ReproCommandSpec(
    argv: umaskWrappedArgv(action.argv),
    cwd: action.cwd,
    env: threadedEnv,
    stdoutLimit: config.stdoutLimit,
    stderrLimit: config.stderrLimit)
  let helper = if config.runQuotaCliPath.len > 0: config.runQuotaCliPath
    else: defaultRunQuotaHelperPath()
  startProcess(helper, args = helperCliArgs(rq, command, resultPath),
    options = {poUsePath, poStdErrToStdOut})

proc runQuotaRequest(action: BuildAction): ReproResourceRequest =
  ReproResourceRequest(
    label: action.id,
    commandStatsId: action.commandStatsId,
    cpuMilli: action.cpuMilli,
    memoryBytes: action.memoryBytes,
    namedPool: action.pool,
    namedPoolUnits: action.poolUnits)

proc runQuotaCommand(action: BuildAction; config: BuildEngineConfig):
    ReproCommandSpec =
  # MR8: prepend the cached MSVC dev-env diff (Windows-only) so the
  # inline-runquota batch path matches the helper-spawn path's env
  # shape. The action's own ``env`` entries override on key collision.
  let mergedEnv = mergeActionEnvWithMsvc(launchChildEnv(action, config))
  let toolBinDirs = resolvedToolBinDirs(action, config.toolIdentityResolver)
  let auxPaths = collectResolvedAuxPaths(action, config.toolIdentityResolver)
  var threadedEnv = prependPathDirsToArgvEnv(mergedEnv, toolBinDirs)
  threadedEnv = applyResolvedAuxPathsArgv(threadedEnv, auxPaths)
  # M9.R.36.3 — apply the same umask-022 wrap the helper-spawn and
  # bypass paths use. The inline-runquota path likewise forwards
  # ``command.argv`` to ``launchProcess`` inside the helper / inline
  # batch, so an unwrapped argv would resurrect the qmlcachegen mode
  # drift.
  ReproCommandSpec(
    argv: umaskWrappedArgv(action.argv),
    cwd: action.cwd,
    env: threadedEnv,
    stdoutLimit: config.stdoutLimit,
    stderrLimit: config.stderrLimit)

proc writeBypassResultJson(resultPath: string; exitCode: int;
                           stdoutPayload, stderrPayload: string) =
  ## Synthesize the same result-JSON schema the RunQuota helper writes, so the
  ## downstream parser in ``finishRunQuotaProcess`` can consume it unchanged.
  ## Keep field names and types byte-for-byte aligned with
  ## ``repro_runquota.executionJson``.
  let payload = %*{
    "runner_error": "",
    "lease_id": 0,
    "exit_code": exitCode,
    "exited": true,
    "signaled": false,
    "signal": 0,
    "stdout": stdoutPayload,
    "stderr": stderrPayload,
    "backend_name": "runquota-bypass",
    "runquota_socket": "",
    "lease_finished_sent": false,
    "lease_released": false
  }
  createDir(extendedPath(parentDir(resultPath)))
  writeFile(extendedPath(resultPath), $payload)

proc finishBypassRunQuotaProcess(id: string; process: Process;
                                 resultPath: string; cacheRoot: string) =
  ## Path-mode escape hatch: wait for the directly-spawned process and
  ## synthesize the result JSON the standard parser expects.
  ##
  ## **M1 milestone (Windows-bypass-stdio-capture)**: read the per-action
  ## ``<cacheRoot>/actions/<id>.{stdout,stderr}.log`` files
  ## ``startBypassRunQuotaProcess`` redirected the child into and embed
  ## their contents in the result JSON. The previous behaviour swallowed
  ## stdio (``poParentStreams`` inherited the engine's stdio but was
  ## invisible under daemon-mode invocations), which surfaced as "exit
  ## code 101 with empty stderr" in build reports. The log-file route
  ## avoids the multi-process pipe-buffer deadlock the in-process
  ## drainer hit; see the rationale in ``startBypassRunQuotaProcess``.
  let exitCode = process.waitForExit()
  let stdoutPayload = readBypassActionLog(
    bypassActionStdoutLogPath(cacheRoot, id))
  # B2: strip the io-mon shim's per-process banner from the surfaced stderr so
  # a failing monitored action shows its REAL error instead of dozens of
  # ``io-mon: macOS body-patch …`` noise lines (Monitor-Hook-Shim.md). The raw
  # ``<id>.stderr.log`` on disk keeps the banner for deep diagnosis.
  let stderrPayload = stripMonitorBanner(readBypassActionLog(
    bypassActionStderrLogPath(cacheRoot, id)))
  writeBypassResultJson(resultPath, exitCode, stdoutPayload, stderrPayload)

proc finishRunQuotaProcess(id: string; process: Process; resultPath: string;
                           bypassRunQuota: bool;
                           cacheRoot: string): ActionResult =
  let backendLabel =
    if bypassRunQuota: "runquota-bypass" else: "runquota-helper"
  result = ActionResult(id: id, launched: true, runQuotaBackend: backendLabel)
  if bypassRunQuota:
    finishBypassRunQuotaProcess(id, process, resultPath, cacheRoot)
  let helperExit =
    if bypassRunQuota: 0
    else: process.waitForExit()
  var helperOutput = ""
  if not bypassRunQuota and process.outputStream != nil:
    helperOutput = process.outputStream.readAll()
  if not fileExists(extendedPath(resultPath)):
    result.status = asFailed
    result.exitCode = if helperExit == 0: 1 else: helperExit
    result.stderr = "runquota helper did not write result"
    if helperOutput.len > 0:
      result.stderr.add(": " & helperOutput)
    return
  try:
    # extendedPath() is required: the result file's path can exceed Windows
    # MAX_PATH (260 chars) once nested under <bench-root>/CMakeFiles/
    # CMakeScratch/TryCompile-<hash>/CMakeFiles/reprobuild/worktrees/<…>/
    # build/reprobuild/build-engine-cache/runquota-results/1.json. Without
    # the \\?\ prefix, parseFile() raises "cannot read from file" even when
    # the prior fileExists() check (which DOES use extendedPath) saw it.
    let node = parseFile(extendedPath(resultPath))
    result.leaseId = node{"lease_id"}.getBiggestInt(0).uint64
    result.exitCode = node{"exit_code"}.getInt(1)
    result.stdout = node{"stdout"}.getStr("")
    result.stderr = node{"stderr"}.getStr("")
    let runnerError = node{"runner_error"}.getStr("")
    if runnerError.len > 0:
      if result.stderr.len > 0:
        result.stderr.add("\n")
      result.stderr.add(runnerError)
    if helperOutput.len > 0:
      if result.stderr.len > 0:
        result.stderr.add("\n")
      result.stderr.add(helperOutput)
    result.runQuotaBackend = node{"backend_name"}.getStr("runquota-helper")
    result.runQuotaSocket = node{"runquota_socket"}.getStr("")
    result.status =
      if helperExit == 0 and runnerError.len == 0 and result.exitCode == 0:
        asSucceeded
      else:
        asFailed
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = if helperExit == 0: 1 else: helperExit
    result.stderr = "runquota helper result parse failed: " & err.msg

proc finishInlineRunQuotaProcess(id: string;
                                 process: var ReproRunQuotaRunningProcess):
    ActionResult =
  result = ActionResult(id: id, launched: true)
  try:
    let execution = process.finishCompleted()
    result.leaseId = execution.leaseId
    result.exitCode = execution.exitCode
    result.stdout = execution.stdout
    result.stderr = execution.stderr
    result.runQuotaBackend = execution.backendName
    result.runQuotaSocket = getEnv("RUNQUOTA_SOCKET", "")
    result.status =
      if execution.exitCode == 0:
        asSucceeded
      else:
        asFailed
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = "runquota inline process failed: " & err.msg
    result.runQuotaBackend = "runquota-inline"
    result.runQuotaSocket = getEnv("RUNQUOTA_SOCKET", "")

proc inlineRunQuotaFailureResult(id, message: string): ActionResult =
  ActionResult(
    id: id,
    status: asFailed,
    exitCode: 1,
    launched: true,
    stderr: message,
    runQuotaBackend: "runquota-inline",
    runQuotaSocket: getEnv("RUNQUOTA_SOCKET", ""))

type
  WorkspaceVcsExecutor* = proc(action: BuildAction): ActionResult {.gcsafe.}
    ## Hook installed by ``repro_workspace_vcs/git_actions`` (M2). The
    ## engine dispatches every ``bakWorkspaceVcs`` action through the
    ## currently registered executor. We keep the dispatch indirect so
    ## the engine library does not need to depend on the VCS library
    ## (which itself depends on the engine for ``BuildAction``).

  BinaryCacheSubstituteExecutor* = proc(action: BuildAction): ActionResult {.gcsafe.}
    ## A2.5: hook installed by ``repro_binary_cache_client/
    ## scheduler_executor.nim``. The engine routes every
    ## ``bakBinaryCacheSubstitute`` action through the registered
    ## executor; the executor reads the entry-key + endpoint URL out
    ## of ``action.builtinText`` and calls into the streaming sink.
    ## Indirect dispatch keeps the engine library free of a hard
    ## dependency on the client library.

var workspaceVcsExecutor {.threadvar.}: WorkspaceVcsExecutor
var binaryCacheSubstituteExecutor {.threadvar.}: BinaryCacheSubstituteExecutor

proc registerWorkspaceVcsExecutor*(executor: WorkspaceVcsExecutor) =
  ## Register the per-thread executor for ``bakWorkspaceVcs`` actions.
  ## M2's ``git_actions`` module calls this at module-init time. Tests
  ## that exercise the engine in-process call it explicitly to install
  ## a fresh executor bound to a resolved ``GitToolIdentity``.
  workspaceVcsExecutor = executor

proc clearWorkspaceVcsExecutor*() =
  ## Clear the registered executor. Tests use this to assert the
  ## fail-closed behavior when no executor is registered.
  workspaceVcsExecutor = nil

proc registerBinaryCacheSubstituteExecutor*(
    executor: BinaryCacheSubstituteExecutor) =
  ## Register the per-thread executor for ``bakBinaryCacheSubstitute``
  ## actions. A2.5's ``scheduler_executor.nim`` calls this at module-
  ## init time. Tests that exercise the engine in-process call it
  ## explicitly with an executor bound to a fresh ``ClientContext`` +
  ## ``HttpPool`` + ``ClientIndex``.
  binaryCacheSubstituteExecutor = executor

proc clearBinaryCacheSubstituteExecutor*() =
  binaryCacheSubstituteExecutor = nil

proc builtinPath(action: BuildAction; path: string): string =
  materialPath(action.cwd, path)

proc builtinRoots(text: string): tuple[sourceRoot: string; outputRoot: string] =
  let lines = text.splitLines()
  if lines.len < 2:
    raiseEngine("preserveTree action requires sourceRoot and outputRoot")
  (sourceRoot: lines[0], outputRoot: lines[1])

proc preserveTreeManifestPath(action: BuildAction): string =
  for output in action.outputs:
    let normalized = output.replace('\\', '/')
    if normalized.startsWith(".repro/preserve-tree/") and
        normalized.endsWith(".manifest"):
      return action.builtinPath(output)
  action.builtinPath(".repro" / "preserve-tree" /
    (sanitizeActionId(action.id) & ".manifest"))

proc readManifestEntries(path: string): seq[string] =
  if not fileExists(extendedPath(path)):
    return @[]
  for line in readFile(extendedPath(path)).splitLines:
    let entry = line.strip().replace('\\', '/')
    if entry.len > 0:
      result.add(entry)

proc writeManifestEntries(path: string; entries: openArray[string]) =
  createDir(extendedPath(path.splitPath.head))
  var text = ""
  for entry in entries:
    text.add(entry)
    text.add("\n")
  writeFile(extendedPath(path), text)

proc prepareBuiltinFileOutput(path: string) =
  ## Built-in file writes must replace output symlinks instead of writing
  ## through them into their targets.
  let expanded = extendedPath(path)
  if symlinkExists(expanded):
    removeFile(expanded)

proc removeExistingPath(path: string) =
  let expanded = extendedPath(path)
  if symlinkExists(expanded) or fileExists(expanded):
    removeFile(expanded)
  elif dirExists(expanded):
    removeDir(expanded)

proc pathWithinRoot(path, root: string): tuple[inside: bool; relative: string] =
  let relative = relativePath(os.normalizedPath(path), os.normalizedPath(root))
  if relative == ".":
    return (inside: true, relative: "")
  if relative.isAbsolute or relative == ".." or relative.startsWith("../") or
      relative.startsWith("..\\"):
    return (inside: false, relative: "")
  (inside: true, relative: relative)

proc copiedSymlinkTarget(sourceRoot, outputRoot, sourceLink, destinationLink,
    target: string): string =
  let resolvedTarget =
    if target.isAbsolute: os.normalizedPath(target)
    else: os.normalizedPath(sourceLink.splitPath.head / target)
  let withinSource = pathWithinRoot(resolvedTarget, sourceRoot)
  let mappedTarget =
    if withinSource.inside: outputRoot / withinSource.relative
    else: resolvedTarget
  relativePath(mappedTarget, destinationLink.splitPath.head)

type
  PreserveTreeEntryKind = enum
    ptekFile
    ptekSymlink

  PreserveTreeEntry = object
    kind: PreserveTreeEntryKind
    relative: string
    target: string

proc parsePreserveTreeEntry(entry: string): PreserveTreeEntry =
  let normalized = entry.replace('\\', '/')
  let fields = normalized.split('\t')
  if fields.len > 0 and fields[0] == "file":
    if fields.len != 2 or fields[1].len == 0:
      raiseEngine("invalid preserveTree file entry: " & entry)
    return PreserveTreeEntry(kind: ptekFile, relative: fields[1])
  if fields.len > 0 and fields[0] == "symlink":
    if fields.len != 3 or fields[1].len == 0:
      raiseEngine("invalid preserveTree symlink entry: " & entry)
    return PreserveTreeEntry(
      kind: ptekSymlink,
      relative: fields[1],
      target: fields[2])
  PreserveTreeEntry(kind: ptekFile, relative: normalized)

proc executeBuiltinAction(action: BuildAction): ActionResult =
  result = ActionResult(
    id: action.id,
    launched: true,
    runQuotaBackend: "builtin",
    dependencyPolicyKind: action.dependencyPolicy.kind)
  try:
    case action.kind
    of bakCopyFile:
      if action.inputs.len != 1 or action.outputs.len != 1:
        raiseEngine("copyFile action requires exactly one input and one output: " &
          action.id)
      let source = action.builtinPath(action.inputs[0])
      let destination = action.builtinPath(action.outputs[0])
      createDir(extendedPath(destination.splitPath.head))
      prepareBuiltinFileOutput(destination)
      # Preserve the source file's mode bits — plain ``copyFile`` creates the
      # destination with the process umask default (typically 0644), which
      # silently drops the executable bit. CodeTracer's recipe copies the
      # cargo-built ``replay-server`` / ``session-manager`` binaries through
      # this action; without the exec bit they fail to launch (exit 126).
      copyFileWithPermissions(extendedPath(source), extendedPath(destination))
    of bakEnsureDir:
      if action.outputs.len != 1:
        raiseEngine("ensureDir action requires exactly one output: " & action.id)
      createDir(extendedPath(action.builtinPath(action.outputs[0])))
    of bakWriteText:
      if action.outputs.len != 1:
        raiseEngine("writeText action requires exactly one output: " & action.id)
      let destination = action.builtinPath(action.outputs[0])
      createDir(extendedPath(destination.splitPath.head))
      prepareBuiltinFileOutput(destination)
      writeFile(extendedPath(destination), action.builtinText)
    of bakStamp:
      if action.outputs.len != 1:
        raiseEngine("stamp action requires exactly one output: " & action.id)
      let destination = action.builtinPath(action.outputs[0])
      createDir(extendedPath(destination.splitPath.head))
      prepareBuiltinFileOutput(destination)
      var text = action.builtinText
      if text.len > 0 and not text.endsWith("\n"):
        text.add("\n")
      for entry in action.builtinEntries:
        text.add(entry)
        text.add("\n")
      writeFile(extendedPath(destination), text)
    of bakPreserveTree:
      let roots = builtinRoots(action.builtinText)
      let sourceRoot = action.builtinPath(roots.sourceRoot)
      let outputRoot = action.builtinPath(roots.outputRoot)
      createDir(extendedPath(outputRoot))
      var expected = initHashSet[string]()
      var currentEntries: seq[string] = @[]
      for rawEntry in action.builtinEntries:
        let entry = parsePreserveTreeEntry(rawEntry)
        let relative = entry.relative
        if relative.len == 0:
          continue
        expected.incl(relative)
        currentEntries.add(relative)
        let source = sourceRoot / relative
        let destination = outputRoot / relative
        createDir(extendedPath(destination.splitPath.head))
        case entry.kind
        of ptekFile:
          if not fileExists(extendedPath(source)):
            raiseEngine("preserveTree source file disappeared before execution: " &
              source)
          prepareBuiltinFileOutput(destination)
          # Preserve source mode bits (notably the exec bit) — see the
          # bakCopyFile note above; preserveTree mirrors arbitrary trees that
          # may contain executables.
          copyFileWithPermissions(extendedPath(source), extendedPath(destination))
        of ptekSymlink:
          if not symlinkExists(extendedPath(source)):
            raiseEngine("preserveTree source symlink disappeared before execution: " &
              source)
          let currentTarget = copiedSymlinkTarget(sourceRoot, outputRoot, source,
            destination, entry.target)
          removeExistingPath(destination)
          createSymlink(currentTarget, extendedPath(destination))
      let manifestPath = preserveTreeManifestPath(action)
      for previous in readManifestEntries(manifestPath):
        if not expected.contains(previous):
          let stale = outputRoot / previous
          if symlinkExists(extendedPath(stale)) or fileExists(extendedPath(stale)):
            removeFile(extendedPath(stale))
      currentEntries.sort(system.cmp[string])
      writeManifestEntries(manifestPath, currentEntries)
    of bakWorkspaceVcs:
      # M2 dispatch: every ``bakWorkspaceVcs`` action runs through the
      # executor registered by ``repro_workspace_vcs/git_actions``. The
      # registered executor returns a fully-populated ``ActionResult``;
      # we copy its status/exitCode/stderr through so the rest of the
      # built-in pipeline (cache record, evidence collect) sees the
      # same shape it would for any other built-in.
      if workspaceVcsExecutor.isNil:
        raiseEngine("bakWorkspaceVcs action requires registerWorkspaceVcsExecutor before runBuild: " &
          action.id)
      let vcsResult = workspaceVcsExecutor(action)
      result.status = vcsResult.status
      result.exitCode = vcsResult.exitCode
      result.stdout = vcsResult.stdout
      result.stderr = vcsResult.stderr
      result.reason = vcsResult.reason
      result.launched = vcsResult.launched
      result.runQuotaBackend = if vcsResult.runQuotaBackend.len > 0:
        vcsResult.runQuotaBackend else: result.runQuotaBackend
      return
    of bakBinaryCacheSubstitute:
      # A2.5 dispatch: the substitute action routes through the
      # executor registered by ``repro_binary_cache_client``. The
      # executor performs the manifest fetch + signature verify +
      # streaming payload sink + index update; we copy its
      # status/exitCode/stderr through so cache-record + evidence
      # paths see the same shape as any other built-in.
      if binaryCacheSubstituteExecutor.isNil:
        raiseEngine(
          "bakBinaryCacheSubstitute action requires " &
          "registerBinaryCacheSubstituteExecutor before runBuild: " &
          action.id)
      let subRes = binaryCacheSubstituteExecutor(action)
      result.status = subRes.status
      result.exitCode = subRes.exitCode
      result.stdout = subRes.stdout
      result.stderr = subRes.stderr
      result.reason = subRes.reason
      result.launched = subRes.launched
      result.runQuotaBackend = if subRes.runQuotaBackend.len > 0:
        subRes.runQuotaBackend else: "binary-cache-substitute"
      return
    of bakProcess:
      raiseEngine("process action cannot be executed as a built-in: " & action.id)
    result.status = asSucceeded
    result.exitCode = 0
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = err.msg

proc resultIndex(ids: Table[string, int]; id: string): int =
  if not ids.hasKey(id):
    raiseEngine("internal missing result id: " & id)
  ids[id]

type
  WarmActionCache = ref object
    cache: ActionCache
    evidence: string

var processWarmActionCaches = initTable[string, WarmActionCache]()

proc durableEvidence(path: string): string =
  try:
    if not fileExists(extendedPath(path)):
      return "missing"
    let info = getFileInfo(extendedPath(path), followSymlink = false)
    $info.size & ":" & $info.lastWriteTime.toUnix & ":" &
      $info.lastWriteTime.nanosecond
  except CatchableError:
    "unavailable"

proc actionCacheDurableEvidence(root: string): string =
  durableEvidence(root / "action-results.hot.records") & "|" &
    durableEvidence(root / "action-results.hot.index") & "|" &
    durableEvidence(root / "action-results.records")

proc warmActionCacheFor(root: string): WarmActionCache =
  let evidence = actionCacheDurableEvidence(root)
  if processWarmActionCaches.hasKey(root):
    let warm = processWarmActionCaches[root]
    if warm.evidence == evidence:
      return warm
  result = WarmActionCache(cache: openActionCache(root), evidence: evidence)
  processWarmActionCaches[root] = result

proc runBuild*(g: BuildGraph; config: BuildEngineConfig): BuildRunResult =
  var stats: BuildStats
  proc statStart(): float =
    if config.statsEnabled:
      epochTime()
    else:
      0.0
  proc finishStat(name: string; started: float) =
    if config.statsEnabled:
      stats.addMetric(name, (epochTime() - started) * 1_000_000.0)

  proc finishMetadataCacheStats(cache: FileMetadataCache) =
    if not config.statsEnabled:
      return
    let metadataStats = cache.metadataStats()
    stats.addCounterMetric("repro file metadata current-run hit",
      metadataStats.currentRunHits)
    stats.addCounterMetric("repro file metadata cold stat",
      metadataStats.coldStats)
    stats.addCounterMetric("repro file metadata warm revalidate",
      metadataStats.warmRevalidated)
    stats.addCounterMetric("repro file metadata warm unchanged",
      metadataStats.warmUnchanged)
    stats.addCounterMetric("repro file metadata warm changed",
      metadataStats.warmChanged)

  let totalStart = statStart()
  let inferStart = statStart()
  # `var` because M25 ``create-action`` dyndep records grow ``buildGraph.actions``
  # mid-build. ``applyDynamicDeps`` appends to it; downstream readers iterate
  # over the growing slice, and the scheduler loop terminates against
  # ``completed < buildGraph.actions.len`` so a freshly inserted action keeps
  # the loop alive.
  var buildGraph = inferDeclaredActionDeps(g)
  # NOTE: an earlier ``REPRO_MACOS_DISABLE_ACTION_MONITOR`` opt-in lived here and
  # downgraded every monitored action to a declared-only (unmonitored) policy
  # on macOS. That was an unapproved soundness hole — it marked actions
  # complete/cacheable on declared inputs alone while silently dropping runtime
  # read-set discovery. It has been REMOVED and MUST NOT be re-added: automatic
  # monitoring is the spec baseline for opaque tools
  # (Reprobuild-Development.milestones.org M17), monitored builds work on arm64e
  # after the io-mon fix, and an action that genuinely cannot be monitored must
  # FAIL or be NON-CACHEABLE per Monitor-Hook-Shim.md:501 — never marked
  # complete-on-declared-inputs.
  finishStat("repro graph infer deps", inferStart)
  var runResult: BuildRunResult
  runResult.traceEnabled = not config.suppressTrace
  let validateStart = statStart()
  validateGraph(buildGraph)
  finishStat("repro graph validate", validateStart)

  let maxParallel = if config.maxParallelism == 0'u32: 1'u32 else: config.maxParallelism

  proc cancellationRequested(): bool =
    config.cancelCallback != nil and config.cancelCallback()

  proc raiseIfCancelled() =
    if cancellationRequested():
      raiseEngine("build cancelled")
  let initStart = statStart()
  let cacheRoot = if config.cacheRoot.len == 0:
      getCurrentDir() / ".repro" / "build-engine-cache"
    else:
      config.cacheRoot
  # The CAS and action-cache live under the shared user-level
  # `actionCacheRoot` when set (Provider-Compile-Tiering.md §"Cache Scope"
  # Phase 1). When empty (legacy / unmigrated callers, tests), they fall
  # back to `cacheRoot` so the single-root layout still works.
  let sharedRoot = if config.actionCacheRoot.len > 0:
      config.actionCacheRoot
    else:
      cacheRoot
  let casOpenStart = statStart()
  let cas = openLocalCas(sharedRoot / "cas")
  finishStat("repro cas open", casOpenStart)
  let actionCacheOpenStart = statStart()
  let warmCache = warmActionCacheFor(sharedRoot / "action-cache")
  var cache = warmCache.cache
  finishStat("repro action cache open", actionCacheOpenStart)
  defer:
    cache.flushHotIndex()
    warmCache.cache = cache
    warmCache.evidence = actionCacheDurableEvidence(sharedRoot / "action-cache")

  proc cacheHitEvidence(action: BuildAction;
                        record: ActionResultRecord): PathSetEvidence =
    if config.skipCacheHitEvidence:
      PathSetEvidence()
    else:
      evidenceFromRecord(action, record)

  proc publishPeerCacheBundle(weakFingerprint: ContentDigest;
                              record: ActionResultRecord) =
    ## Peer-Cache M1 publisher hook (Linux-Distro-Recipe-Validation
    ## M5 wiring). Materialises the action-bundle bytes — record +
    ## every output blob payload read back from the local CAS — and
    ## hands them to the configured publisher closure. Nil-safe;
    ## inactive when the CLI didn't pass ``--peer-cache=…`` or when
    ## the record has no CAS-backed outputs (``opkMetadataOnly``).
    if config.peerCacheActionPublisher == nil:
      return
    if record.outputPayloadKind != opkCasBlobs:
      return
    let publishStart = statStart()
    var bundleBytes: seq[byte] = @[]
    proc writeU32Le(dst: var seq[byte]; value: uint32) =
      dst.add(byte(value and 0xff'u32))
      dst.add(byte((value shr 8) and 0xff'u32))
      dst.add(byte((value shr 16) and 0xff'u32))
      dst.add(byte((value shr 24) and 0xff'u32))
    for ch in "RPAB":
      bundleBytes.add(byte(ord(ch)))
    bundleBytes.add(byte(1)); bundleBytes.add(byte(0))  # version 1, LE
    let recordBytes = encodeActionResultRecord(record)
    bundleBytes.writeU32Le(uint32(recordBytes.len))
    for b in recordBytes: bundleBytes.add(b)
    bundleBytes.writeU32Le(uint32(record.outputs.len))
    for output in record.outputs:
      let payload = cas.readBlob(output.blob)
      bundleBytes.writeU32Le(uint32(payload.len))
      for b in payload: bundleBytes.add(b)
    config.peerCacheActionPublisher(weakFingerprint, bundleBytes)
    finishStat("repro peer-cache publish", publishStart)

  proc publishBinaryCacheBundle(action: BuildAction;
                                record: ActionResultRecord) =
    ## M9.L.4-refactor Step A binary-cache publisher hook. Soft-fail
    ## like ``publishPeerCacheBundle``: a failed publish is logged
    ## into stats but does NOT abort the build.
    ##
    ## Guards (any failure = no-op):
    ##   * ``BuildEngineConfig.binaryCachePublisher == nil`` — no
    ##     publisher wired (legacy CLI default).
    ##   * ``action.publishToBinaryCache == false`` — the convention
    ##     did not opt this action into binary-cache publishing.
    ##     Existing recipes leave the flag at its default, so the hook
    ##     stays inert across the 74-recipe corpus until Step B's
    ##     convention refactor lands.
    ##   * ``action.cacheEntryIdentity.isNone`` — no identity tuple
    ##     to derive the entry-key from. Hard requirement; without
    ##     the identity the publisher cannot run its drift-guard.
    ##   * ``record.outputPayloadKind != opkCasBlobs`` — the cache
    ##     record didn't capture output payloads (metadata-only
    ##     mode), so the publisher has nothing to ship. Mirrors the
    ##     same guard in ``publishPeerCacheBundle``.
    if config.binaryCachePublisher == nil:
      return
    if not action.publishToBinaryCache:
      return
    if action.cacheEntryIdentity.isNone:
      return
    if record.outputPayloadKind != opkCasBlobs:
      return
    let publishStart = statStart()
    var recordOutputs: seq[string] = @[]
    for output in record.outputs:
      recordOutputs.add(output.path)
    # DSL-port M9.R.7. Fold the action's cache-platform tag into the
    # identity's ``selectedOptions`` channel as
    # ``CachePlatformTagOptionKey``. On a native build the tag is the
    # ``"native"`` sentinel — the canonical key derivation includes it
    # uniformly so two distinct ``targetTriple`` resolutions produce
    # two distinct entry-key hexes for the same recipe (and a
    # ``"native"``-tagged action produces a stable hex across recipes
    # that don't declare ``targetTriple`` at all).
    var folded = action.cacheEntryIdentity.get()
    let foldedTag =
      if action.cachePlatformTag.len == 0: NativeTriple
      else: action.cachePlatformTag
    folded.addOption(CachePlatformTagOptionKey, foldedTag)
    let req = BinaryCachePublishRequest(
      actionId: action.id,
      weakFingerprint: action.weakFingerprint,
      identity: folded,
      cwd: action.cwd,
      declaredOutputs: action.outputs,
      recordOutputs: recordOutputs)
    let res =
      try: config.binaryCachePublisher(req)
      except CatchableError as e:
        BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "binary-cache publisher raised: " & e.msg)
    if not res.ok:
      stats.addCounterMetric("repro binary-cache publish failures", 1)
    else:
      stats.addCounterMetric("repro binary-cache publish ok", 1)
      stats.addCounterMetric("repro binary-cache publish bytes uploaded",
        res.bytesUploaded)
    finishStat("repro binary-cache publish", publishStart)

  proc tryFastNoopCacheHits(): Option[BuildRunResult] =
    if not config.rebuildMissingOutputsOnCacheHit:
      return none(BuildRunResult)
    if config.progressCallback != nil:
      return none(BuildRunResult)
    var fastResult: BuildRunResult
    fastResult.traceEnabled = not config.suppressTrace
    var metadataCache = initFileMetadataCache()
    if config.skipCacheHitEvidence:
      var hotProbes: seq[HotMetadataProbe] = @[]
      for action in buildGraph.actions:
        if (not action.cacheable) or action.dynamicDepsFile.len > 0:
          return none(BuildRunResult)
        let outputStatStart = statStart()
        let outputsPresent = action.allOutputsExist()
        finishStat("repro output stat", outputStatStart)
        if not outputsPresent:
          return none(BuildRunResult)
        hotProbes.add(HotMetadataProbe(
          weakFingerprint: action.weakFingerprint,
          policy: action.actionCachePolicy))
      let lookupStart = statStart()
      let navigatorStart = statStart()
      let scan = cache.scanHotIndexMetadataInputsUnchanged(hotProbes,
        addr metadataCache)
      finishStat("repro hot index navigator scan", navigatorStart)
      finishStat("repro cache lookup", lookupStart)
      case scan.status
      of hmssHit:
        let resultMaterializeStart = statStart()
        for action in buildGraph.actions:
          fastResult.results.add(ActionResult(
            id: action.id,
            status: asCacheHit,
            cacheDecision: cdHit,
            dependencyPolicyKind: action.dependencyPolicy.kind))
        finishStat("repro cache hit result materialize", resultMaterializeStart)
        finishMetadataCacheStats(metadataCache)
        fastResult.stats = stats
        return some(fastResult)
      of hmssMissingRecord, hmssInputChanged:
        return none(BuildRunResult)
      of hmssUnavailable, hmssCorrupt:
        discard

    var hotRecords: seq[ActionResultRecord] = @[]
    for action in buildGraph.actions:
      if (not action.cacheable) or action.dynamicDepsFile.len > 0:
        return none(BuildRunResult)
      let outputStatStart = statStart()
      let outputsPresent = action.allOutputsExist()
      finishStat("repro output stat", outputStatStart)
      if not outputsPresent:
        return none(BuildRunResult)
      let hotRecordLookupStart = statStart()
      let hotRecord = cache.lookupHotMetadataRecord(action.weakFingerprint,
        action.actionCachePolicy)
      finishStat("repro hot record lookup", hotRecordLookupStart)
      if hotRecord.isNone:
        return none(BuildRunResult)
      if not config.skipCacheHitEvidence:
        hotRecords.add(hotRecord.get())
    let lookupStart = statStart()
    let inputScanStart = statStart()
    let inputsUnchanged =
      if buildGraph.actions.len == cache.hotMetadataRecordCount():
        cache.hotMetadataInputsUnchanged(addr metadataCache)
      else:
        if config.skipCacheHitEvidence:
          var selectedHotRecords: seq[ActionResultRecord] = @[]
          for action in buildGraph.actions:
            selectedHotRecords.add(cache.lookupHotMetadataRecord(
              action.weakFingerprint, action.actionCachePolicy).get())
          hotMetadataRecordInputsUnchanged(selectedHotRecords, addr metadataCache)
        else:
          hotMetadataRecordInputsUnchanged(hotRecords, addr metadataCache)
    finishStat("repro hot input scan", inputScanStart)
    finishStat("repro cache lookup", lookupStart)
    if not inputsUnchanged:
      return none(BuildRunResult)
    let resultMaterializeStart = statStart()
    for i, action in buildGraph.actions:
      let record =
        if config.skipCacheHitEvidence: ActionResultRecord()
        else: hotRecords[i]
      fastResult.results.add(ActionResult(
        id: action.id,
        status: asCacheHit,
        cacheDecision: cdHit,
        dependencyPolicyKind: action.dependencyPolicy.kind,
        evidence: cacheHitEvidence(action, record)))
    finishStat("repro cache hit result materialize", resultMaterializeStart)
    finishMetadataCacheStats(metadataCache)
    fastResult.stats = stats
    some(fastResult)

  let fastNoopStart = statStart()
  let fastNoop = tryFastNoopCacheHits()
  finishStat("repro fast noop scan", fastNoopStart)
  if fastNoop.isSome:
    runResult = fastNoop.get()
    finishStat("repro scheduler total", totalStart)
    runResult.stats = stats
    return runResult

  var idToIndex = initTable[string, int]()
  var dependents = initTable[string, seq[string]]()
  var remaining = initTable[string, int]()
  var statuses = initTable[string, ActionStatus]()
  var poolCapacity = initTable[string, uint32]()
  var poolRunning = initTable[string, uint32]()
  var ready: seq[string] = @[]
  var actionsById = initTable[string, BuildAction]()
  var launchedSucceeded = initHashSet[string]()
  var dynamicDepsLoaded = initHashSet[string]()
  var fileMetadataCache = initFileMetadataCache()
  var inlineRunQuotaSession: ReproRunQuotaSession
  var inlineRunQuotaSessionOpen = false

  proc invalidateCachedPath(path: string) =
    fileMetadataCache.invalidate(path)

  proc invalidateCachedOutputs(action: BuildAction) =
    for output in action.outputs:
      invalidateCachedPath(materialPath(action.cwd, output))

  proc invalidateCachedWrites(action: BuildAction; evidence: PathSetEvidence) =
    for output in evidence.monitorWrites:
      invalidateCachedPath(materialPath(action.cwd, output))

  poolCapacity[""] = maxParallel
  for p in buildGraph.pools:
    poolCapacity[p.name] = p.capacity
  for action in buildGraph.actions:
    let cap = poolCapacity.getOrDefault(action.pool, maxParallel)
    let units = if action.poolUnits == 0'u32: 1'u32 else: action.poolUnits
    if units > cap:
      raiseEngine("action " & action.id & " requests " & $units &
        " units from pool " & action.pool & " with capacity " & $cap)
  for i, action in buildGraph.actions:
    idToIndex[action.id] = i
    actionsById[action.id] = action
    remaining[action.id] = action.deps.len
    statuses[action.id] = asPending
    if action.deps.len == 0:
      ready.add(action.id)
    for dep in action.deps:
      dependents.mgetOrPut(dep, @[]).add(action.id)
    runResult.results.add(ActionResult(
      id: action.id,
      status: asPending,
      dependencyPolicyKind: action.dependencyPolicy.kind,
      cacheDecision: if action.cacheable: cdMiss else: cdNotCacheable))
  finishStat("repro scheduler initialize", initStart)

  proc readyCmp(a, b: string): int =
    cmp(idToIndex[a], idToIndex[b])

  var running: seq[RunningAction] = @[]
  var runQuotaDaemonReachable: Option[bool]

  # ``REPROBUILD_NO_RUNQUOTA=1`` is the engine's own documented full-bypass
  # switch, which it forces into every action child env (see ``childBypassEnv``)
  # precisely so a NESTED ``repro`` invocation runs unmanaged and never requests
  # its OWN lease from the same daemon — the parent⇄child lease cycle documented
  # there, which otherwise surfaces only as "build graph made no progress" (or,
  # on macOS, a hard hang in the inline grant poll waiting for a lease the outer
  # action already holds). When we observe that switch in our OWN environment we
  # ARE such an inner repro, so we must bypass runquota regardless of the
  # ``bypassRunQuota`` flag the CLI happened to build into the config. Honouring
  # it here — at the single runquota gate — covers every config path (provider
  # compile, dev-env materialisation, command run) without each CLI call site
  # having to remember to translate the env into the flag.
  let effectiveBypassRunQuota =
    config.bypassRunQuota or
    (getEnv("REPROBUILD_NO_RUNQUOTA").normalize in ["1", "true", "yes", "on"])

  proc launchBypassesRunQuota(): bool =
    if effectiveBypassRunQuota:
      return true
    if not config.fallbackToRunQuotaBypass:
      return false
    if runQuotaDaemonReachable.isNone:
      let probeStart = statStart()
      runQuotaDaemonReachable = some(isRunQuotaDaemonReachable())
      finishStat("repro runquota probe", probeStart)
    not runQuotaDaemonReachable.get()

  proc tryEnsureInlineRunQuotaSession(): bool =
    if inlineRunQuotaSessionOpen:
      return true
    let sessionStart = statStart()
    try:
      inlineRunQuotaSession = openRunQuotaSession()
      inlineRunQuotaSessionOpen = true
      runQuotaDaemonReachable = some(true)
      result = true
    except CatchableError as err:
      runQuotaDaemonReachable = some(false)
      if config.fallbackToRunQuotaBypass:
        result = false
      else:
        # M9.R.11 — rewrite the raw ``CreateFileW failed for
        # \\.\pipe\runquota-<user>: Windows error 2`` (or POSIX
        # equivalent) into a remediation hint. The auto-spawn pass
        # (``startAutoRunQuotaIfNeeded``) already tried PATH +
        # $RUNQUOTAD_BIN + the sibling-repo fall-through; reaching this
        # branch means none of those worked AND the build mode demands
        # a real lease coordinator (typically ``--tool-provisioning=
        # from-source`` for which ``fallbackToRunQuotaBypass`` is
        # false). Surfacing the canonical remediation here costs zero
        # behaviour change for the bypass-OK path (returns false above
        # before reaching this branch).
        raise newException(ReproRunQuotaError,
          "runquota daemon unreachable and bypass is disabled. " &
          "Underlying error: " & err.msg & ". " &
          "Searched for runquotad binary on PATH, " &
          "$RUNQUOTAD_BIN, and ../runquota/build/bin/ relative to " &
          "repro.exe. Remediation: " &
          "(a) build the sibling runquota daemon (e.g. " &
          "`cd ../runquota && just build`); " &
          "(b) set $RUNQUOTAD_BIN to an absolute path; " &
          "(c) install runquotad system-wide and re-run; " &
          "(d) bypass runquota explicitly with `--no-runquota` or " &
          "`REPROBUILD_NO_RUNQUOTA=1`.")
    finally:
      finishStat("repro runquota session open", sessionStart)

  proc willBypassRunQuota(): bool =
    ## RA-13: build-stable predicate mirroring the per-launch bypass decision
    ## taken just before a process action is spawned (the ``inlineRunQuota`` /
    ## ``launchBypassesRunQuota`` branch below). It is consulted by the ready
    ## scan to decide whether the LOCAL named-pool gate must enforce capacity:
    ##
    ## - When RunQuota IS the authority (no bypass), the engine declares each
    ##   action's pool membership + units in the lease request and lets
    ##   RunQuota's grant gate the pool cross-session; the engine MUST NOT also
    ##   gate locally (that would double-count the same pool — see
    ##   Build-Engine-And-Scheduler.md § "One executor, one resource authority").
    ## - On the bypass path there is NO lease and NO RunQuota to enforce a pool,
    ##   so the local pool gate is the ONLY enforcement that keeps a declared
    ##   pool (e.g. ``host/linker``) from running unbounded. There the gate is
    ##   kept as the fallback.
    ##
    ## The decision is the same value the launch site computes for
    ## ``bypassRunQuota``, so removing the double-gate cannot diverge from the
    ## path that actually spawns the child. The probe / session-open it triggers
    ## is cached and idempotent (same round trip the first launch would pay).
    if config.inlineRunQuota and not effectiveBypassRunQuota:
      not tryEnsureInlineRunQuotaSession()
    else:
      launchBypassesRunQuota()

  proc terminalCount(): int =
    for action in buildGraph.actions:
      if statuses[action.id] in {asSucceeded, asCacheHit, asUpToDate,
          asWouldRun, asFailed, asBlocked}:
        inc result

  proc checkedCount(): int =
    terminalCount() + running.len

  proc plannedExecutionCount(): int =
    for item in runResult.results:
      if item.launched or item.wouldLaunch:
        inc result

  proc completedExecutionCount(): int =
    for item in runResult.results:
      if item.launched and item.status in {asSucceeded, asFailed}:
        inc result

  proc emitProgress(kind: BuildProgressKind; id: string) =
    if config.progressCallback == nil:
      return
    let idx = idToIndex.resultIndex(id)
    let action = actionsById[id]
    proc commandForAction(action: BuildAction): string =
      if action.argv.len > 0:
        for arg in action.argv:
          if result.len > 0:
            result.add(" ")
          result.add(quoteShell(arg))
      else:
        result = $action.kind & " " & action.id
    let command = commandForAction(action)
    let currentCommand =
      if running.len > 0:
        commandForAction(running[^1].action)
      else:
        ""
    config.progressCallback(BuildProgressEvent(
      kind: kind,
      actionId: id,
      command: command,
      currentCommand: currentCommand,
      status: runResult.results[idx].status,
      cacheDecision: runResult.results[idx].cacheDecision,
      launched: runResult.results[idx].launched,
      total: buildGraph.actions.len,
      completed: terminalCount(),
      checked: checkedCount(),
      settled: terminalCount(),
      plannedExecutions: plannedExecutionCount(),
      completedExecutions: completedExecutionCount(),
      executionPlanKnown: checkedCount() >= buildGraph.actions.len,
      running: running.len,
      ready: ready.len))

  proc hasPendingInlineRunQuota(): bool =
    for item in running:
      if item.processKind == rpkInlineRunQuotaPending:
        return true
    false

  proc anyInlineRunQuotaProcess(): bool =
    ## True when any running entry uses the inline RunQuota path (active
    ## or pending). The Windows event-driven wait can't include these
    ## (they don't expose a SYNCHRONIZE handle to us), so a non-zero
    ## answer caps the WaitForMultipleObjects timeout so we still poll
    ## `pollCompletion` periodically. Zero answer lets us wait longer.
    for item in running:
      if item.processKind in {rpkInlineRunQuota, rpkInlineRunQuotaPending,
                              rpkInlineRunQuotaFailed}:
        return true
    false

  proc failRunningAction(index: int; message: string) =
    running[index].inlineFailure = inlineRunQuotaFailureResult(
      running[index].id, message)
    running[index].processKind = rpkInlineRunQuotaFailed

  proc pollInlineRunQuotaGrants(): int =
    result = -1
    if not inlineRunQuotaSessionOpen or not hasPendingInlineRunQuota():
      return
    try:
      for grant in pollRunQuotaGrants(inlineRunQuotaSession):
        for j in 0 ..< running.len:
          if running[j].processKind != rpkInlineRunQuotaPending:
            continue
          if running[j].queuedRunQuotaProcess.candidateId != grant.candidateId:
            continue
          if not grant.active or grant.queued:
            # FOLLOWUP per docs/runquota-policy.md: a late denial on an
            # already-queued lease MUST delay-and-retry, not surface as
            # an asFailed ActionResult.  The proper fix is to re-offer
            # the candidate via offerWithRunQuota (which now retries on
            # denial with backoff) and reattach the resulting grant to
            # the running entry.  Until that engine-side state-machine
            # plumbing lands, this preserves the legacy fail-fast
            # behaviour for queue-then-denied transitions; the spec
            # explicitly calls this out as a known gap.
            failRunningAction(j, "runquota denied queued lease: " &
              grant.diagnostic)
            return j
          try:
            var queued = running[j].queuedRunQuotaProcess
            running[j].runQuotaProcess = startGrantedWithRunQuota(
              inlineRunQuotaSession, queued, grant)
            running[j].queuedRunQuotaProcess = queued
            running[j].processKind = rpkInlineRunQuota
            runResult.trace(running[j].id, "launched", "runquota-grant")
          except CatchableError as err:
            failRunningAction(j, "runquota inline process failed: " & err.msg)
            return j
          break
    except CatchableError as err:
      for j in 0 ..< running.len:
        if running[j].processKind == rpkInlineRunQuotaPending:
          failRunningAction(j, "runquota inline grant polling failed: " &
            err.msg)
          return j

  proc completeSuccess(id: string; status: ActionStatus; cacheDecision: CacheDecision;
                       launched: bool; detail = "") =
    let idx = idToIndex.resultIndex(id)
    runResult.results[idx].status = status
    runResult.results[idx].cacheDecision = cacheDecision
    runResult.results[idx].launched = launched
    if detail.len > 0:
      runResult.results[idx].reason = detail
    statuses[id] = status
    if (launched and status == asSucceeded) or status == asWouldRun:
      launchedSucceeded.incl(id)
    runResult.trace(id, $status, detail)
    for dep in dependents.getOrDefault(id):
      if statuses[dep] == asPending:
        remaining[dep] = remaining[dep] - 1
        if remaining[dep] == 0:
          ready.add(dep)
    ready.sort(readyCmp)
    emitProgress(bpkActionCompleted, id)

  proc blockClosure(id, blocker: string) =
    for dep in dependents.getOrDefault(id):
      if statuses[dep] == asPending:
        statuses[dep] = asBlocked
        let idx = idToIndex.resultIndex(dep)
        runResult.results[idx].status = asBlocked
        runResult.results[idx].blockedBy = blocker
        runResult.trace(dep, "blocked", blocker)
        emitProgress(bpkActionCompleted, dep)
        blockClosure(dep, blocker)

  # M25: a single declared output may not be claimed by two different
  # actions. The static graph already enforces this in ``validateGraph``;
  # for dynamically materialised actions we re-enforce the invariant by
  # consulting a live set of declared outputs that's seeded from the
  # static graph and grows as ``create-action`` records land.
  var declaredOutputs = initHashSet[string]()
  for action in buildGraph.actions:
    for output in action.outputs:
      declaredOutputs.incl(output)

  proc registerDynamicAction(producerId: string; newAction: BuildAction) =
    ## M25: materialise a ``create-action`` record into the running graph.
    ## Validates uniqueness, dep-target existence, and self-cycle freedom
    ## before threading the new action through every scheduler bookkeeping
    ## structure. The producer id participates only in the trace message
    ## so the materialisation can be attributed back to its source.
    if newAction.id.len == 0:
      raiseEngine("dynamic action-create record from " & producerId &
        ": id must be non-empty")
    if actionsById.hasKey(newAction.id):
      raiseEngine("dynamic action-create record from " & producerId &
        ": action id " & newAction.id & " already exists in the graph")
    for output in newAction.outputs:
      if declaredOutputs.contains(output):
        raiseEngine("dynamic action-create record from " & producerId &
          ": declared output " & output & " is already produced by another action")
    for dep in newAction.deps:
      if dep == newAction.id:
        raiseEngine("dynamic action-create record from " & producerId &
          ": action " & newAction.id & " depends on itself")
      if not actionsById.hasKey(dep):
        raiseEngine("dynamic action-create record from " & producerId &
          ": action " & newAction.id & " depends on unknown action " & dep)

    let newIndex = buildGraph.actions.len
    buildGraph.actions.add(newAction)
    idToIndex[newAction.id] = newIndex
    actionsById[newAction.id] = newAction
    statuses[newAction.id] = asPending
    runResult.results.add(ActionResult(
      id: newAction.id,
      status: asPending,
      dependencyPolicyKind: newAction.dependencyPolicy.kind,
      cacheDecision: if newAction.cacheable: cdMiss else: cdNotCacheable))
    for output in newAction.outputs:
      declaredOutputs.incl(output)
    # Compute initial ``remaining`` only against deps that are not yet
    # terminal-success — the producer of the .rbdyn (which is the consumer
    # action's eventual upstream) may already have succeeded by the time
    # the record is ingested, so its dep edge must NOT contribute to the
    # waiting count.
    var waitingDeps = 0
    var blockedBy = ""
    for dep in newAction.deps:
      dependents.mgetOrPut(dep, @[]).addUnique(newAction.id)
      case statuses[dep]
      of asSucceeded, asCacheHit, asUpToDate, asWouldRun:
        discard
      of asFailed, asBlocked:
        blockedBy = dep
      else:
        inc waitingDeps
    remaining[newAction.id] = waitingDeps
    runResult.trace(newAction.id, "action-create", "producer=" & producerId)
    if blockedBy.len > 0:
      statuses[newAction.id] = asBlocked
      let blockedIdx = idToIndex.resultIndex(newAction.id)
      runResult.results[blockedIdx].status = asBlocked
      runResult.results[blockedIdx].blockedBy = blockedBy
      runResult.trace(newAction.id, "blocked", blockedBy)
      emitProgress(bpkActionCompleted, newAction.id)
      blockClosure(newAction.id, blockedBy)
      return
    if waitingDeps == 0:
      ready.add(newAction.id)
      ready.sort(readyCmp)

  proc applyDynamicDeps(id: string): bool =
    if dynamicDepsLoaded.contains(id):
      return true
    var action = actionsById[id]
    if action.dynamicDepsFile.len == 0:
      dynamicDepsLoaded.incl(id)
      return true
    let fragmentPath = materialPath(action.cwd, action.dynamicDepsFile)
    let dyndepStart = statStart()
    let fragment = readDynamicGraphFragment(fragmentPath)
    finishStat("repro dynamic deps load", dyndepStart)
    # M25: materialise any ``create-action`` records FIRST so subsequent
    # ``dep`` edges can name them. The order in the fragment is preserved;
    # each new action is fully threaded through scheduler state before the
    # next record is processed.
    for newAction in fragment.createdActions:
      registerDynamicAction(id, newAction)
    var addedWaiting = 0
    for output in fragment.outputs.getOrDefault(id):
      action.outputs.addUnique(output)
    for dep in fragment.deps.getOrDefault(id):
      if not actionsById.hasKey(dep):
        raiseEngine("dynamic dependency " & dep & " for " & id &
          " does not name an action in the selected graph")
      if dep == id:
        raiseEngine("dynamic dependency cycle: " & id & " depends on itself")
      if action.deps.find(dep) >= 0:
        continue
      action.deps.add(dep)
      dependents.mgetOrPut(dep, @[]).addUnique(id)
      case statuses[dep]
      of asSucceeded, asCacheHit, asUpToDate, asWouldRun:
        discard
      of asFailed, asBlocked:
        statuses[id] = asBlocked
        let idx = idToIndex.resultIndex(id)
        runResult.results[idx].status = asBlocked
        runResult.results[idx].blockedBy = dep
        runResult.trace(id, "blocked", dep)
        emitProgress(bpkActionCompleted, id)
        blockClosure(id, dep)
        actionsById[id] = action
        dynamicDepsLoaded.incl(id)
        return false
      else:
        inc addedWaiting
    actionsById[id] = action
    dynamicDepsLoaded.incl(id)
    if addedWaiting > 0:
      remaining[id] = remaining.getOrDefault(id, 0) + addedWaiting
      runResult.trace(id, "dynamic-deps", "waiting=" & $addedWaiting)
      return false
    runResult.trace(id, "dynamic-deps", "loaded")
    true

  var completed = 0
  let runQuotaResultRoot = cacheRoot / "runquota-results"
  createDir(extendedPath(runQuotaResultRoot))
  var launchSeq = 0

  type StagedInlineLaunch = object
    id: string
    pool: string
    poolUnits: uint32
    runningIdx: int
    action: BuildAction
    resultPath: string

  try:
    while completed < buildGraph.actions.len:
      raiseIfCancelled()
      ready.sort(readyCmp)
      var launchedAny = false
      var stagedInlineLaunches: seq[StagedInlineLaunch] = @[]
      var i = 0
      while i < ready.len and
          uint32(running.len + stagedInlineLaunches.len) < maxParallel:
        raiseIfCancelled()
        let id = ready[i]
        var action = actionsById[id]
        let poolName = action.pool
        let cap = poolCapacity.getOrDefault(poolName, maxParallel)
        let used = poolRunning.getOrDefault(poolName, 0'u32)
        let units = if action.poolUnits == 0'u32: 1'u32 else: action.poolUnits
        # RA-13: the local pool gate is authoritative ONLY for the default
        # frontier pool ("") and for NAMED pools on the bypass path. When
        # RunQuota is the authority for this launch, a NAMED pool's capacity is
        # enforced by RunQuota's grant against the units declared in the lease
        # request (``namedPool`` / ``namedPoolUnits``) — gating it again here
        # would double-count the same cross-session pool down to this single
        # invocation (Build-Engine-And-Scheduler.md § "One executor, one
        # resource authority"). The default pool is the frontier/parallelism
        # bound and stays local. ``poolRunning`` is still tracked for every
        # pool, but for a RunQuota-gated named pool it is only a
        # non-authoritative ordering hint, never a second gate.
        let localPoolGateActive = poolName.len == 0 or willBypassRunQuota()
        if localPoolGateActive and used + units > cap:
          inc i
          continue

        ready.delete(i)
        if not applyDynamicDeps(id):
          launchedAny = true
          completed = terminalCount()
          continue
        action = actionsById[id]
        runResult.trace(id, "ready", "pool=" & poolName)
        runResult.trace(id, "dependency-policy", $action.dependencyPolicy.kind)

        var cacheMissInputChanged = false
        var dependencyLaunched = false
        var outputsPresentBeforeLookup = false
        var outputsPresentKnown = false
        for dep in action.deps:
          if launchedSucceeded.contains(dep):
            dependencyLaunched = true
            break
        if dependencyLaunched:
          runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
          runResult.results[idToIndex.resultIndex(id)].reason =
            "dependency-launched"
          runResult.trace(id, "cache-skipped", "dependency-launched")
        elif config.forceRebuild:
          runResult.results[idToIndex.resultIndex(id)].cacheDecision =
            if action.cacheable: cdMiss else: cdNotCacheable
          runResult.results[idToIndex.resultIndex(id)].reason = "force-rebuild"
          runResult.trace(id, "cache-skipped", "force-rebuild")
        elif action.cacheable:
          if config.rebuildMissingOutputsOnCacheHit:
            let outputStatStart = statStart()
            outputsPresentBeforeLookup = action.allOutputsExist()
            outputsPresentKnown = true
            finishStat("repro output stat", outputStatStart)
          let lookupStart = statStart()
          var lookup = cache.lookupActionResult(cas, action.weakFingerprint,
            action.actionCachePolicy,
            verifyOutputBlobs = not outputsPresentBeforeLookup,
            allowMetadataOnlyHit = config.rebuildMissingOutputsOnCacheHit and
              outputsPresentBeforeLookup,
            metadataCache = addr fileMetadataCache)
          finishStat("repro cache lookup", lookupStart)
          # Peer-Cache M1: on local miss, consult the LAN peer cache.
          # `peerCacheActionFetcher` is nil when ``--peer-cache=…`` was
          # not passed, so the legacy local-only flow is byte-for-byte
          # preserved. On peer hit we install the bundle locally and
          # re-run the same `lookupActionResult` call so the rest of
          # the scheduler treats this as a normal local hit.
          if lookup.status in {aclMissNoRecord, aclMissInputChanged,
              aclMissNoOutputPayload} and
              config.peerCacheActionFetcher != nil and
              config.peerCacheActionInstaller != nil:
            let peerFetchStart = statStart()
            let peerReply = config.peerCacheActionFetcher(
              action.weakFingerprint)
            finishStat("repro peer-cache fetch", peerFetchStart)
            if peerReply.isSome:
              let installStart = statStart()
              let install = config.peerCacheActionInstaller(
                action.weakFingerprint, peerReply.get(),
                cas, addr cache)
              finishStat("repro peer-cache install", installStart)
              if install.ok:
                let retryStart = statStart()
                lookup = cache.lookupActionResult(cas, action.weakFingerprint,
                  action.actionCachePolicy,
                  verifyOutputBlobs = not outputsPresentBeforeLookup,
                  allowMetadataOnlyHit =
                    config.rebuildMissingOutputsOnCacheHit and
                    outputsPresentBeforeLookup,
                  metadataCache = addr fileMetadataCache)
                finishStat("repro peer-cache lookup-retry", retryStart)
                runResult.trace(id, "peer-cache-hit", $lookup.status)
              else:
                runResult.trace(id, "peer-cache-install-failed",
                  install.reason)
          case lookup.status
          of aclHit:
            var outputsPresent = true
            if config.rebuildMissingOutputsOnCacheHit:
              outputsPresent = outputsPresentBeforeLookup
            if config.rebuildMissingOutputsOnCacheHit and outputsPresent:
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asUpToDate, cdHit, false, "outputs-present")
              inc completed
              launchedAny = true
              continue
            if config.rebuildMissingOutputsOnCacheHit:
              runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
              runResult.results[idToIndex.resultIndex(id)].reason =
                "missing-output"
              runResult.trace(id, "cache-skipped", "missing-output")
            else:
              let restoreStart = statStart()
              cas.restoreOutputs(lookup.record, action.cwd)
              fileMetadataCache.clear()
              finishStat("repro cache restore", restoreStart)
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asCacheHit, cdHit, false, "restored")
              inc completed
              launchedAny = true
              continue
          of aclHybridCutoff:
            var outputsPresent = true
            if config.rebuildMissingOutputsOnCacheHit:
              outputsPresent = outputsPresentBeforeLookup
            if config.rebuildMissingOutputsOnCacheHit and outputsPresent:
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asUpToDate, cdHybridCutoff, false,
                "outputs-present")
              inc completed
              launchedAny = true
              continue
            if config.rebuildMissingOutputsOnCacheHit:
              runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
              runResult.results[idToIndex.resultIndex(id)].reason =
                "missing-output"
              runResult.trace(id, "cache-skipped", "missing-output")
            else:
              let restoreStart = statStart()
              cas.restoreOutputs(lookup.record, action.cwd)
              fileMetadataCache.clear()
              finishStat("repro cache restore", restoreStart)
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              completeSuccess(id, asCacheHit, cdHybridCutoff, false, "restored")
              inc completed
              launchedAny = true
              continue
          of aclRejectedCorruptOutput:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdRejected
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message else: "corrupt-output"
          of aclMissInputChanged:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message else: "input-changed"
            cacheMissInputChanged = true
          else:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message else: $lookup.status
        elif not action.cacheable:
          runResult.results[idToIndex.resultIndex(id)].reason = "not-cacheable"

        var outputsPresent: bool
        if outputsPresentKnown:
          outputsPresent = outputsPresentBeforeLookup
        else:
          let outputStatStart = statStart()
          outputsPresent = action.allOutputsExist()
          finishStat("repro output stat", outputStatStart)
        if outputsPresent and not cacheMissInputChanged and
            not dependencyLaunched and
            not config.forceRebuild and
            not action.needsExecutionForPolicy():
          let evidenceStart = statStart()
          let evidence = collectEvidence(action, strict = true)
          finishStat("repro evidence collect", evidenceStart)
          runResult.results[idToIndex.resultIndex(id)].evidence = evidence.evidence
          if not evidence.publishable:
            statuses[id] = asFailed
            runResult.results[idToIndex.resultIndex(id)].status = asFailed
            runResult.results[idToIndex.resultIndex(id)].stderr =
              evidence.evidence.diagnostics.join("\n")
            runResult.trace(id, "failed", "dependency evidence invalid")
            blockClosure(id, id)
            emitProgress(bpkActionCompleted, id)
            completed = terminalCount()
            launchedAny = true
            continue
          completeSuccess(id, asUpToDate, runResult.results[idToIndex.resultIndex(id)].cacheDecision,
            false, "outputs-present")
          inc completed
          launchedAny = true
          continue

        if config.dryRun:
          let idx = idToIndex.resultIndex(id)
          var reason = runResult.results[idx].reason
          if reason.len == 0:
            if not outputsPresent:
              reason = "missing-output"
            elif action.needsExecutionForPolicy():
              reason = "policy-requires-execution"
            else:
              reason = "cache-miss"
          runResult.results[idx].wouldLaunch = true
          completeSuccess(id, asWouldRun, runResult.results[idx].cacheDecision,
            false, reason)
          inc completed
          launchedAny = true
          continue

        # Windows-System-Resources Phase E — the pre-launch broker-
        # dispatch decision point. This branch sits BEFORE the
        # ``monitoredAction`` / RunQuota launch sites because an
        # elevated edge:
        #   * is a one-shot side-effecting spawn (no monitor depfile);
        #   * never goes through RunQuota (the broker is the resource
        #     boundary, not runquotad);
        #   * still flows through the cache layer above — an elevated
        #     edge that hits the action cache returned earlier at
        #     ``aclHit`` and never reaches this point.
        # When ``brokerSpawn`` is nil we FAIL CLOSED here rather than
        # silently fall through to the legacy direct-fork path: a
        # ``requiresElevation`` edge that runs unelevated is a far
        # worse outcome than a clear diagnostic that points the
        # operator at ``repro infra apply``.
        if action.requiresElevation:
          if config.brokerSpawn == nil:
            raiseEngine(
              "requiresElevation set but brokerSpawn not configured: " &
                action.id &
                " (this build edge must be dispatched via " &
                "`repro infra apply` so the privileged-operation " &
                "broker can fork it; the standalone `repro build` " &
                "driver leaves the broker hook unset by design)")
          let elevatedStart = statStart()
          let req = ElevatedExecRequest(
            actionId: action.id,
            argv: action.argv,
            cwd: action.cwd,
            env: action.env)
          var brokerOutcome: ElevatedExecResult
          var brokerFailure = ""
          try:
            brokerOutcome = config.brokerSpawn(req)
          except CatchableError as err:
            brokerFailure = err.msg
          finishStat("repro broker dispatch", elevatedStart)
          let idx = idToIndex.resultIndex(id)
          let previousCacheDecision = runResult.results[idx].cacheDecision
          if brokerFailure.len > 0:
            runResult.results[idx] = ActionResult(
              id: id,
              status: asFailed,
              exitCode: 1,
              launched: true,
              cacheDecision: previousCacheDecision,
              dependencyPolicyKind: action.dependencyPolicy.kind,
              stderr: "broker dispatch raised: " & brokerFailure,
              runQuotaBackend: "broker")
            statuses[id] = asFailed
            runResult.trace(id, "failed", "broker dispatch raised")
            blockClosure(id, id)
            emitProgress(bpkActionCompleted, id)
            completed = terminalCount()
            launchedAny = true
            continue
          let status =
            if brokerOutcome.ok and brokerOutcome.exitCode == 0:
              asSucceeded
            else: asFailed
          runResult.results[idx] = ActionResult(
            id: id,
            status: status,
            exitCode: brokerOutcome.exitCode,
            launched: true,
            cacheDecision:
              if action.cacheable and previousCacheDecision == cdNotCacheable:
                cdMiss
              else: previousCacheDecision,
            dependencyPolicyKind: action.dependencyPolicy.kind,
            stdout: brokerOutcome.stdout,
            stderr:
              if brokerOutcome.stderr.len > 0: brokerOutcome.stderr
              else: brokerOutcome.diagnostic,
            runQuotaBackend: "broker")
          statuses[id] = status
          if status == asSucceeded:
            invalidateCachedOutputs(action)
            let evidenceStart = statStart()
            let evidence = collectEvidence(action, strict = true)
            finishStat("repro evidence collect", evidenceStart)
            runResult.results[idx].evidence = evidence.evidence
            if not evidence.publishable:
              runResult.results[idx].status = asFailed
              runResult.results[idx].stderr =
                evidence.evidence.diagnostics.join("\n")
              statuses[id] = asFailed
              runResult.trace(id, "failed", "dependency evidence invalid")
              blockClosure(id, id)
              emitProgress(bpkActionCompleted, id)
              completed = terminalCount()
              launchedAny = true
              continue
            invalidateCachedWrites(action, evidence.evidence)
            if action.cacheable:
              let recordStart = statStart()
              let storeOutputBlobs = (not config.deferLocalOutputBlobs) or
                config.peerCacheActionPublisher != nil or
                (config.binaryCachePublisher != nil and
                  action.publishToBinaryCache)
              let record = cache.recordActionResult(cas,
                action.weakFingerprint,
                action.actionCachePolicy,
                action.cacheInputPaths(evidence.evidence),
                action.outputs, action.cwd,
                storeOutputBlobs = storeOutputBlobs,
                metadataCache = addr fileMetadataCache)
              finishStat("repro cache record", recordStart)
              writeActionResultRecordFile(
                dependencyEvidencePath(cacheRoot, action.id), record)
              publishPeerCacheBundle(action.weakFingerprint, record)
              publishBinaryCacheBundle(action, record)
            completeSuccess(id, asSucceeded,
              runResult.results[idx].cacheDecision, true, "elevated")
          else:
            runResult.trace(id, "failed",
              "exit=" & $brokerOutcome.exitCode)
            blockClosure(id, id)
            emitProgress(bpkActionCompleted, id)
            # ``blockClosure`` marks every transitively-dependent
            # action as ``asBlocked`` without touching the local
            # ``completed`` counter. ``inc completed`` here would
            # only count THIS action (the broker-failed one) — the
            # cascaded blocked descendants would stay invisible to
            # the loop's "completed < total" termination check, so
            # the next iteration would find no pending / running /
            # ready work and raise the spec-mandated
            # ``build graph made no progress; pending actions: ``
            # diagnostic with an empty pending list. Every OTHER
            # blockClosure site in this file uses ``terminalCount()``
            # for exactly this reason; this branch was the lone
            # offender.
            completed = terminalCount()
            launchedAny = true
            continue
          inc completed
          launchedAny = true
          continue

        let monitorPlanStart = statStart()
        let plan = monitoredAction(action, config, cacheRoot)
        finishStat("repro monitor plan", monitorPlanStart)
        if plan.diagnostic.len > 0:
          statuses[id] = asFailed
          let idx = idToIndex.resultIndex(id)
          runResult.results[idx].status = asFailed
          runResult.results[idx].stderr = plan.diagnostic
          runResult.trace(id, "failed", plan.diagnostic)
          blockClosure(id, id)
          emitProgress(bpkActionCompleted, id)
          completed = terminalCount()
          launchedAny = true
          continue

        if plan.action.kind != bakProcess:
          let builtinStart = statStart()
          let finished = executeBuiltinAction(plan.action)
          finishStat("repro builtin execute", builtinStart)
          let idx = idToIndex.resultIndex(id)
          let previousCacheDecision = runResult.results[idx].cacheDecision
          runResult.results[idx] = finished
          runResult.results[idx].dependencyPolicyKind =
            plan.action.dependencyPolicy.kind
          runResult.results[idx].cacheDecision =
            if actionsById[finished.id].cacheable and
                previousCacheDecision == cdNotCacheable:
              cdMiss
            else:
              previousCacheDecision
          statuses[id] = finished.status
          if finished.status == asSucceeded:
            invalidateCachedOutputs(plan.action)
            let evidenceStart = statStart()
            let evidence = collectEvidence(plan.action, strict = true)
            finishStat("repro evidence collect", evidenceStart)
            runResult.results[idx].evidence = evidence.evidence
            if not evidence.publishable:
              runResult.results[idx].status = asFailed
              runResult.results[idx].stderr =
                evidence.evidence.diagnostics.join("\n")
              statuses[id] = asFailed
              runResult.trace(finished.id, "failed", "dependency evidence invalid")
              blockClosure(finished.id, finished.id)
              emitProgress(bpkActionCompleted, finished.id)
              completed = terminalCount()
              launchedAny = true
              continue
            invalidateCachedWrites(plan.action, evidence.evidence)
            if plan.action.cacheable:
              let recordStart = statStart()
              # Peer-Cache M1: when a publisher closure is set, force
              # output-blob retention so the publisher can read the
              # blob payloads back out of the local CAS. The
              # publisher-less path (legacy CLI default) keeps the
              # ``deferLocalOutputBlobs`` knob honoured byte-for-byte.
              # M9.L.4-refactor Step A: ALSO force retention when the
              # binary-cache publisher is configured AND this action
              # opted into publishing — the publish hook guards on
              # ``outputPayloadKind == opkCasBlobs`` and would
              # silently skip otherwise.
              let storeOutputBlobs = (not config.deferLocalOutputBlobs) or
                config.peerCacheActionPublisher != nil or
                (config.binaryCachePublisher != nil and
                  plan.action.publishToBinaryCache)
              let record = cache.recordActionResult(cas, plan.action.weakFingerprint,
                plan.action.actionCachePolicy, plan.action.cacheInputPaths(evidence.evidence),
                plan.action.outputs, plan.action.cwd,
                storeOutputBlobs = storeOutputBlobs,
                metadataCache = addr fileMetadataCache)
              finishStat("repro cache record", recordStart)
              writeActionResultRecordFile(
                dependencyEvidencePath(cacheRoot, plan.action.id), record)
              publishPeerCacheBundle(plan.action.weakFingerprint, record)
              publishBinaryCacheBundle(plan.action, record)
            completeSuccess(finished.id, asSucceeded,
              runResult.results[idx].cacheDecision, true, "builtin")
          else:
            runResult.trace(finished.id, "failed", finished.stderr)
            blockClosure(finished.id, finished.id)
            emitProgress(bpkActionCompleted, finished.id)
          inc completed
          launchedAny = true
          continue

        statuses[id] = asRunning
        let runningIdx = idToIndex.resultIndex(id)
        runResult.results[runningIdx].status = asRunning
        runResult.results[runningIdx].launched = true
        runResult.results[runningIdx].monitorDepfilePath = plan.action.monitorDepfile
        poolRunning[poolName] = used + units
        inc launchSeq
        let resultPath = runQuotaResultRoot / ($launchSeq & ".json")
        var bypassRunQuota = false
        var inlineRunQuota = false
        if config.inlineRunQuota and not effectiveBypassRunQuota:
          inlineRunQuota = tryEnsureInlineRunQuotaSession()
          bypassRunQuota = not inlineRunQuota
        else:
          bypassRunQuota = launchBypassesRunQuota()
        # RA-13: record that this run launched at least one action with no
        # RunQuota lease so the build header + run report can surface the
        # unsafe-for-concurrent state (it never makes concurrent cross-
        # invocation runs safe). On the bypass path the local pool gate above
        # was the sole capacity enforcement.
        if bypassRunQuota:
          runResult.runQuotaBypassed = true
        if inlineRunQuota:
          # Pipelined path: defer the actual offer round-trip and stage
          # this launch. After the launch wave we'll dispatch every
          # staged action in a single OfferCandidates batch — the daemon
          # already supports batched candidate decisions, so this turns
          # an O(N) chain of synchronous round-trips at parallel=N into
          # a single round-trip per wave.
          stagedInlineLaunches.add(StagedInlineLaunch(
            id: id,
            pool: poolName,
            poolUnits: units,
            runningIdx: runningIdx,
            action: plan.action,
            resultPath: resultPath))
          launchedAny = true
          continue
        let launchStart = statStart()
        var process: Process
        var processKind =
          if bypassRunQuota: rpkBypassProcess
          else: rpkHelperProcess
        let startEvent = "launched"
        let startDetail = "pool=" & poolName
        var launchFailure = ""
        try:
          process = startRunQuotaProcess(plan.action, config, resultPath,
            bypassRunQuota)
        except CatchableError as err:
          launchFailure = err.msg
        finishStat("repro runquota launch", launchStart)
        if launchFailure.len > 0:
          let previousCacheDecision = runResult.results[runningIdx].cacheDecision
          runResult.results[runningIdx] = ActionResult(
            id: id,
            status: asFailed,
            exitCode: 1,
            launched: true,
            cacheDecision: previousCacheDecision,
            dependencyPolicyKind: plan.action.dependencyPolicy.kind,
            monitorDepfilePath: plan.action.monitorDepfile,
            stderr: "process launch failed: " & launchFailure,
            runQuotaBackend:
              if bypassRunQuota: "runquota-bypass"
              else: "runquota-helper",
            runQuotaSocket: getEnv("RUNQUOTA_SOCKET", ""))
          statuses[id] = asFailed
          let failedUsed = poolRunning.getOrDefault(poolName, 0'u32)
          poolRunning[poolName] =
            if failedUsed > units: failedUsed - units else: 0'u32
          runResult.trace(id, "failed", "launch")
          blockClosure(id, id)
          emitProgress(bpkActionCompleted, id)
          completed = terminalCount()
          launchedAny = true
          continue
        running.add(RunningAction(
          id: id,
          pool: poolName,
          poolUnits: units,
          action: plan.action,
          processKind: processKind,
          process: process,
          resultPath: resultPath
        ))
        runResult.trace(id, startEvent, startDetail)
        emitProgress(bpkActionStarted, id)
        launchedAny = true

      # Flush any staged inline-runquota launches as one batched offer.
      # The previous per-action offerWithRunQuota loop performed an
      # offerCandidates round-trip serialised on each ready action — at
      # parallel=32 that's 32 synchronous round-trips before any work
      # actually starts. The batched call collapses them into one (or a
      # handful, when stagedInlineLaunches exceeds maxCandidatesPerBatch).
      if stagedInlineLaunches.len > 0:
        let batchStart = statStart()
        var requests = newSeq[ReproResourceRequest](stagedInlineLaunches.len)
        var commands = newSeq[ReproCommandSpec](stagedInlineLaunches.len)
        for k, staged in stagedInlineLaunches:
          requests[k] = staged.action.runQuotaRequest()
          commands[k] = staged.action.runQuotaCommand(config)
        var offers: seq[ReproRunQuotaOffer]
        var batchFailure = ""
        try:
          offers = offerWithRunQuotaBatch(inlineRunQuotaSession, requests, commands)
        except CatchableError as err:
          batchFailure = err.msg
        finishStat("repro runquota launch", batchStart)
        if batchFailure.len > 0:
          # The whole batch failed (e.g. session died mid-way). Mark
          # each staged launch failed and undo its pool reservation so
          # we don't lose capacity for the rest of the build.
          for staged in stagedInlineLaunches:
            let previousCacheDecision =
              runResult.results[staged.runningIdx].cacheDecision
            runResult.results[staged.runningIdx] = ActionResult(
              id: staged.id,
              status: asFailed,
              exitCode: 1,
              launched: true,
              cacheDecision: previousCacheDecision,
              dependencyPolicyKind: staged.action.dependencyPolicy.kind,
              monitorDepfilePath: staged.action.monitorDepfile,
              stderr: "process launch failed: " & batchFailure,
              runQuotaBackend: "runquota-inline",
              runQuotaSocket: getEnv("RUNQUOTA_SOCKET", ""))
            statuses[staged.id] = asFailed
            let failedUsed = poolRunning.getOrDefault(staged.pool, 0'u32)
            poolRunning[staged.pool] =
              if failedUsed > staged.poolUnits: failedUsed - staged.poolUnits
              else: 0'u32
            runResult.trace(staged.id, "failed", "launch")
            blockClosure(staged.id, staged.id)
            emitProgress(bpkActionCompleted, staged.id)
          completed = terminalCount()
          launchedAny = true
        else:
          for k, staged in stagedInlineLaunches:
            let offer = offers[k]
            var startEvent = "launched"
            var startDetail = "pool=" & staged.pool
            var processKind: RunningProcessKind
            var runQuotaProcess: ReproRunQuotaRunningProcess
            var queuedRunQuotaProcess: ReproRunQuotaQueuedProcess
            case offer.kind
            of rqokStarted:
              runQuotaProcess = offer.running
              processKind = rpkInlineRunQuota
            of rqokQueued:
              queuedRunQuotaProcess = offer.queued
              processKind = rpkInlineRunQuotaPending
              startEvent = "queued"
              startDetail = "pool=" & staged.pool & " runquota=pending"
            running.add(RunningAction(
              id: staged.id,
              pool: staged.pool,
              poolUnits: staged.poolUnits,
              action: staged.action,
              processKind: processKind,
              runQuotaProcess: runQuotaProcess,
              queuedRunQuotaProcess: queuedRunQuotaProcess,
              resultPath: staged.resultPath
            ))
            runResult.trace(staged.id, startEvent, startDetail)
            emitProgress(bpkActionStarted, staged.id)
            launchedAny = true

      if completed >= buildGraph.actions.len:
        break

      if running.len == 0:
        if ready.len > 0 and not launchedAny:
          raiseEngine("ready queue is blocked by pool capacity")
        var pending: seq[string] = @[]
        for action in buildGraph.actions:
          if statuses[action.id] == asPending:
            pending.add(action.id)
        raiseEngine("build graph made no progress; pending actions: " & pending.join(", "))

      var runIndex = -1
      let waitStart = statStart()
      var nextGrantPoll = 0.0
      while runIndex < 0:
        raiseIfCancelled()
        if hasPendingInlineRunQuota() and epochTime() >= nextGrantPoll:
          runIndex = pollInlineRunQuotaGrants()
          nextGrantPoll = epochTime() + 0.025
          if runIndex >= 0:
            break
        # Cheap inline-only checks first: queued/failed inline-runquota
        # entries are not handle-based and the OS won't wake us for them.
        # Inline-RunQuota processes do their own pipe / handle wait in
        # `pollCompletion`, which is non-blocking here.
        for j in 0 ..< running.len:
          case running[j].processKind
          of rpkInlineRunQuotaPending:
            discard
          of rpkInlineRunQuota:
            if running[j].runQuotaProcess.pollCompletion():
              runIndex = j
              break
          of rpkInlineRunQuotaFailed:
            runIndex = j
            break
          of rpkHelperProcess, rpkBypassProcess:
            when defined(windows):
              # Handled by the event-driven block below; skip here.
              discard
            else:
              if running[j].process.peekExitCode() != -1:
                runIndex = j
                break
        if runIndex >= 0:
          break
        # Event-driven wait: ask the OS to wake us when ANY child process
        # exits. On Windows this is WaitForMultipleObjects on cached
        # SYNCHRONIZE-only handles (mirrors Ninja's IOCP-driven design in
        # references/ninja/src/subprocess-win32.cc) and avoids the
        # ≥15 ms timer-quantum latency the old peekExitCode + sleep(1)
        # spin loop had. We cap the timeout so the loop still revisits
        # inline-runquota grants and pending-queued state periodically.
        let timeoutMs =
          if hasPendingInlineRunQuota(): 25
          elif anyInlineRunQuotaProcess(): 50
          else: 250
        when defined(windows):
          let signaled = waitAnyProcessExitWindows(running, timeoutMs)
          if signaled >= 0:
            runIndex = signaled
        else:
          # POSIX `sleep(1)` is genuine 1 ms (not 15 ms like Windows), so
          # the spin pattern is acceptable here. A SIGCHLD-based waiter
          # would be more efficient but is a larger change.
          sleep(1)
      finishStat("repro process wait", waitStart)
      var runningItem = running[runIndex]
      let finishStart = statStart()
      let finished =
        case runningItem.processKind
        of rpkInlineRunQuotaPending:
          inlineRunQuotaFailureResult(
            runningItem.id,
            "runquota inline process failed: queued action selected before grant")
        of rpkInlineRunQuota:
          finishInlineRunQuotaProcess(
            runningItem.id,
            runningItem.runQuotaProcess)
        of rpkInlineRunQuotaFailed:
          runningItem.inlineFailure
        of rpkBypassProcess:
          finishRunQuotaProcess(
            runningItem.id,
            runningItem.process,
            runningItem.resultPath,
            true,
            cacheRoot)
        of rpkHelperProcess:
          finishRunQuotaProcess(
            runningItem.id,
            runningItem.process,
            runningItem.resultPath,
            false,
            cacheRoot)
      finishStat("repro runquota finish", finishStart)
      if runIndex < 0:
        raiseEngine("internal missing running action: " & finished.id)
      if runningItem.processKind in {rpkHelperProcess, rpkBypassProcess}:
        runningItem.process.close()
      let finishedUsed = poolRunning.getOrDefault(runningItem.pool, 0'u32)
      poolRunning[runningItem.pool] =
        if finishedUsed > runningItem.poolUnits:
          finishedUsed - runningItem.poolUnits
        else:
          0'u32
      when defined(windows):
        closeRunningProcessHandle(running[runIndex])
      running.delete(runIndex)

      let idx = idToIndex.resultIndex(finished.id)
      let previousCacheDecision = runResult.results[idx].cacheDecision
      runResult.results[idx] = finished
      runResult.results[idx].dependencyPolicyKind =
        runningItem.action.dependencyPolicy.kind
      runResult.results[idx].monitorDepfilePath = runningItem.action.monitorDepfile
      runResult.results[idx].cacheDecision =
        if actionsById[finished.id].cacheable and previousCacheDecision == cdNotCacheable:
          cdMiss
        else:
          previousCacheDecision
      statuses[finished.id] = finished.status
      if finished.status == asSucceeded:
        let action = runningItem.action
        invalidateCachedOutputs(action)
        let converterStart = statStart()
        let converterResult = action.runConverters(action.converterSpecsForPolicy())
        finishStat("repro dependency convert", converterStart)
        if not converterResult.ok:
          runResult.results[idx].status = asFailed
          var diagnostics: seq[string] = @[]
          if runResult.results[idx].stderr.len > 0:
            diagnostics.add(runResult.results[idx].stderr)
          diagnostics.add(converterResult.diagnostics)
          runResult.results[idx].stderr = diagnostics.join("\n").strip()
          statuses[finished.id] = asFailed
          runResult.trace(finished.id, "failed", "dependency converter failed")
          blockClosure(finished.id, finished.id)
          emitProgress(bpkActionCompleted, finished.id)
          completed = terminalCount()
          continue
        let evidenceStart = statStart()
        let evidence = collectEvidence(action, strict = true)
        finishStat("repro evidence collect", evidenceStart)
        runResult.results[idx].evidence = evidence.evidence
        if not evidence.publishable:
          runResult.results[idx].status = asFailed
          runResult.results[idx].stderr =
            [runResult.results[idx].stderr, evidence.evidence.diagnostics.join("\n")].join("\n").strip()
          statuses[finished.id] = asFailed
          runResult.trace(finished.id, "failed", "dependency evidence invalid")
          blockClosure(finished.id, finished.id)
          emitProgress(bpkActionCompleted, finished.id)
          completed = terminalCount()
          continue
        invalidateCachedWrites(action, evidence.evidence)
        if action.cacheable:
          let recordStart = statStart()
          # M9.L.4-refactor Step A: force output-blob retention when
          # either the peer-cache publisher OR the binary-cache
          # publisher (with this action opted in) needs to read the
          # blob payloads back out of the local CAS.
          let storeOutputBlobs = (not config.deferLocalOutputBlobs) or
            config.peerCacheActionPublisher != nil or
            (config.binaryCachePublisher != nil and
              action.publishToBinaryCache)
          let record = cache.recordActionResult(cas, action.weakFingerprint,
            action.actionCachePolicy, action.cacheInputPaths(evidence.evidence),
            action.outputs, action.cwd,
            storeOutputBlobs = storeOutputBlobs,
            metadataCache = addr fileMetadataCache)
          finishStat("repro cache record", recordStart)
          writeActionResultRecordFile(
            dependencyEvidencePath(cacheRoot, action.id), record)
          publishPeerCacheBundle(action.weakFingerprint, record)
          publishBinaryCacheBundle(action, record)
        completeSuccess(finished.id, asSucceeded, runResult.results[idx].cacheDecision,
          true, "exit=0")
      else:
        runResult.trace(finished.id, "failed", "exit=" & $finished.exitCode)
        blockClosure(finished.id, finished.id)
        emitProgress(bpkActionCompleted, finished.id)
      inc completed

      completed = 0
      for action in buildGraph.actions:
        if statuses[action.id] in {asSucceeded, asCacheHit, asUpToDate,
            asWouldRun, asFailed, asBlocked}:
          inc completed
  finally:
    for item in running.mitems:
      case item.processKind
      of rpkInlineRunQuotaPending:
        if item.queuedRunQuotaProcess.active:
          item.queuedRunQuotaProcess.cancelQueued()
      of rpkInlineRunQuota:
        if item.runQuotaProcess.active and not item.runQuotaProcess.completed:
          discard item.runQuotaProcess.cancelAndWait()
      of rpkInlineRunQuotaFailed:
        discard
      of rpkHelperProcess, rpkBypassProcess:
        if item.process.running():
          item.process.terminate()
        item.process.close()
    if inlineRunQuotaSessionOpen:
      inlineRunQuotaSession.close()
  finishStat("repro scheduler total", totalStart)
  finishMetadataCacheStats(fileMetadataCache)
  runResult.stats = stats
  result = runResult
