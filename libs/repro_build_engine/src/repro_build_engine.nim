import std/[algorithm, json, options, os, osproc, sets, streams, strtabs,
    strutils, tables, times]

when defined(windows):
  import std/winlean

import repro_core
import repro_depfile
import repro_hash
import repro_local_store
import repro_monitor_depfile
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
             env: openArray[string] = []): BuildAction =
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
    dependencyPolicy: dependencyPolicy)

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
  # Windows: automatic monitor dependency gathering now works on Windows via
  # the IAT-patching shim + CreateRemoteThread injection (see
  # libs/repro_monitor_shim/src/repro_monitor_shim/windows_interpose.nim and
  # libs/repro_monitor_depfile/src/repro_monitor_depfile/windows_injector.nim).
  # The same `repro-fs-snoop` driver is used as on macOS — only the underlying
  # injection mechanism differs.
  when not (defined(macosx) or defined(linux) or defined(windows)):
    result.diagnostic =
      "automatic monitor dependency gathering is unsupported on this platform"
  else:
    let monitorCli = monitorCliPath(config)
    if monitorCli.len == 0:
      result.diagnostic =
        "automatic monitor dependency gathering requires repro-fs-snoop"
      return
    let depfile = cacheRoot / "monitor-depfiles" /
      (sanitizeActionId(action.id) & ".rdep")
    result.action.monitorDepfile = depfile
    result.action.argv = @[monitorCli] & config.monitorCliArgs &
      @["--depfile", depfile, "--"] & action.argv

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

proc launchChildEnv(action: BuildAction): seq[string] =
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
  for entry in action.env:
    result.add(entry)

proc bypassActionLogDir(cacheRoot: string): string =
  ## **M1 milestone** (Windows-bypass-stdio-capture). Per-action log
  ## files live under ``<cacheRoot>/actions/`` so the same scratch dir
  ## that already holds ``runquota-results/`` and ``monitor-depfiles/``
  ## also owns the bypass-path stdio captures. ``repro clean`` (which
  ## wipes ``cacheRoot``) reclaims them with the rest of the per-build
  ## transient state.
  cacheRoot / "actions"

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

proc startBypassRunQuotaProcess(action: BuildAction;
                                cacheRoot: string): Process =
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
  let mergedEnv = mergeActionEnvWithMsvc(launchChildEnv(action))
  let env = envTableFromArgvStyle(mergedEnv)
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
  let wrapped =
    quotedArgv & " > " & quoteShell(stdoutLog) &
      " 2> " & quoteShell(stderrLog)
  when defined(windows):
    # ``/D`` disables AutoRun (HKCU\Software\Microsoft\Command Processor\
    # AutoRun) so a user-injected init script can't mutate the action's
    # environment; ``/C`` runs the command and terminates. Path lookup
    # for the real tool is delegated to ``cmd`` rather than ``startProcess``
    # because the wrapped command line itself contains the tool name.
    result = startProcess("cmd.exe",
      args = @["/D", "/C", wrapped],
      env = env,
      workingDir = cwd,
      options = {poUsePath})
  else:
    result = startProcess("/bin/sh",
      args = @["-c", wrapped],
      env = env,
      workingDir = cwd,
      options = {})

proc startRunQuotaProcess(action: BuildAction; config: BuildEngineConfig;
                          resultPath: string; bypassRunQuota: bool): Process =
  if bypassRunQuota:
    return startBypassRunQuotaProcess(action, config.cacheRoot)
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
  let command = ReproCommandSpec(
    argv: action.argv,
    cwd: action.cwd,
    env: mergeActionEnvWithMsvc(launchChildEnv(action)),
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
  ReproCommandSpec(
    argv: action.argv,
    cwd: action.cwd,
    env: mergeActionEnvWithMsvc(launchChildEnv(action)),
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
  let stderrPayload = readBypassActionLog(
    bypassActionStderrLogPath(cacheRoot, id))
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
    let req = BinaryCachePublishRequest(
      actionId: action.id,
      weakFingerprint: action.weakFingerprint,
      identity: action.cacheEntryIdentity.get(),
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
        raise err
    finally:
      finishStat("repro runquota session open", sessionStart)

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
        if used + units > cap:
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
