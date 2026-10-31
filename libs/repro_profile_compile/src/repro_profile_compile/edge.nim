## Profile-compile build-graph edges.
##
## `compileProfileToRbpi` turns a `home.nim` / `system.nim` profile into the
## RBPI envelope the apply pipelines consume. It schedules TWO monitored
## `bakProcess` edges through one `runBuild`, encodes what the second one
## produced, and returns it. Nothing in front of the edges, inside the
## processes they spawn, or behind them decides whether a previous result is
## still good -- the engine's action cache decides, per edge, from what io-mon
## observed that edge read.
##
## THE TWO EDGES (reprobuild-pm `spec/Profile-Compilation-Model.md` §2):
##
## * COMPILE, `__repro_profile_compile`: the `__repro-compile-profile` helper
##   runs `nim c` -- and through it the C toolchain -- and links the profile
##   binary, its one declared output. It never runs what it produced. It
##   carries the provider compile's entropy blessing
##   (`ProviderCompilerEntropyJustification`, declared once in
##   `repro_core/entropy_blessings`).
## * RUN, `__repro_profile_run`: the profile binary itself, launched by the
##   engine from argv -- no helper, no shell -- with the intent-output flag
##   (`repro_profile/emit.ReproIntentOutFlag`), so it writes its intent
##   document, the edge's one declared output. The binary is the edge's one
##   declared input. UNBLESSED.
##
## WHY NOTHING ELSE MAY DECIDE FRESHNESS. The compile used to be fronted by a
## structural fast path: an `import ./…` text walk (`discoverProfileSources`)
## was hashed into a digest, the `.rbpi` was named after that digest, and a
## valid envelope at that name was returned before `runBuild` was ever called.
## The walk cannot see what Nim actually reads — `staticRead`, `include`,
## `when`, macros, `config.nims`, and anything the profile binary reads when it
## RUNS — so a profile whose helper read `casks.txt` through `staticRead` kept
## planning the first payload after the file changed. The same defect, in the
## same shape, was removed from the interface-extraction and provider compiles
## earlier ("Compiles-Are-Normal-Edges"); the profile compile had not followed.
##
## WHY THE RUN IS AN EDGE OF ITS OWN, AND STILL A MONITORED ONE. The envelope
## is the binary's BEHAVIOUR, not the binary, so a file the profile reads when
## it runs is a dependency exactly as a `staticRead` payload is
## (`t_e2e_profile_compile_runtime_read_tracked`). The run edge is not "the
## intent memoized on the binary's bytes" -- measured stale in GM0 -- because
## the binary is only one of its inputs: everything the run reads is recorded
## beside it. Running the binary where the monitor cannot see it would bring
## the stale intent back.
##
## WHY TWO EDGES AND NOT ONE. Until 2026-10-22 one unblessed edge compiled
## AND ran. On Windows that edge never published on its first run: MSYS2's
## gcc / cc1 / as / collect2 / ld and the engine's OpenSSL DLLs are
## stack-protector builds that draw a canary seed at start-up through
## `ProcessPrng` / `RtlGenRandom`, which io-mon reports (Linux and macOS seed
## it with no observable call). The edge could not be blessed, because it ran
## the profile: a blessing would have covered the profile's own randomness,
## which can reach the intent. Split, the compile's tree is the provider
## compile's tree -- a compiler that never runs its output -- and carries that
## edge's blessing; the run's tree is chosen by the profile, like a shell's
## by its script, and carries none (idiomatic-reprobuild.md §4.3). See
## reprobuild-pm issue
## 2026-10-13-windows-profile-compile-edge-never-publishes-unattributed-entropy.
##
## The only declared identity each edge carries is what monitoring cannot
## supply (see `profileCompileWeakFingerprint` / `profileRunWeakFingerprint`):
## which tools are doing the work, and where the declared outputs land.

import std/[os, strutils]
from repro_core/paths import extendedPath

import blake3
import repro_core
from repro_core/source_root import resolveReprobuildSourceRoot
import repro_hash
import repro_build_engine
from repro_local_store import FileFingerprintPolicy, ffpHybrid
from repro_profile/emit import ReproIntentOutFlag
import repro_profile_intent/envelope as profile_envelope

import ./sources
import ./compile
import ./platforms

# ---------------------------------------------------------------------------
# Public types.
# ---------------------------------------------------------------------------

type
  ProfileEdgeOutcome* = object
    ## The engine's own decision about ONE of the two edges, copied from its
    ## `ActionResult`, so a caller (and a test) can tell which edge was a
    ## cache answer and which executed without inferring it from timestamps.
    ##
    ## * `launched` — the edge's process was spawned this call (for the
    ##   compile edge: the helper, so `nim`; for the run edge: the profile
    ##   binary). False on an action-cache hit.
    ## * `cacheDecision` / `cacheMissReason` / `cachePublishSkipReason` —
    ##   verbatim from the engine.
    ## * `observedInputs` — the files io-mon observed THIS edge read (see
    ##   `ProfileCompileArtifact.observedInputs` for when a hit has them).
    ## * `entropySources` — the entropy entry points io-mon reported in this
    ##   edge's process tree when it EXECUTED this call (`ProcessPrng`,
    ##   `getrandom`, `arc4random`, …; one per record). Empty on a hit. For
    ##   the blessed compile edge these are excused; for the run edge any
    ##   one of them withholds publication.
    ## * `entropyObservations` — the same records whole, with the IMAGE of
    ##   the process that emitted each one (`EntropyObservation.image`, empty
    ##   when the capture could not name it). The source alone cannot say
    ##   whose draw a record is: in the compile edge a Nix clang wrapper's
    ##   `mktemp` and clang's own temporary-name draw are both `getrandom`.
    id*: string
    launched*: bool
    cacheDecision*: CacheDecision
    cacheMissReason*: string
    cachePublishSkipReason*: string
    observedInputs*: seq[string]
    entropySources*: seq[string]
    entropyObservations*: seq[EntropyObservation]

  ProfileCompileArtifact* = object
    ## Result of a successful profile compile.
    ##
    ## `rbpiBytes` is the RBPI envelope ready to feed into the apply pipeline;
    ## `rbpiPath` is where it was published. `digestHex` is the BLAKE3
    ## of those bytes — the identity of the produced INTENT, not of any
    ## source set (no source set is enumerated any more).
    ##
    ## `compileEdge` and `runEdge` report the engine's decision about each
    ## edge. The remaining fields AGGREGATE them, for callers that ask "was
    ## this call answered from the cache?" without caring which edge:
    ##
    ## * `edgeLaunched` — EITHER edge executed this call. False only when
    ##   both were action-cache hits (nothing was spawned: no helper, no
    ##   `nim`, no profile binary).
    ## * `cacheDecision` — `cdHit` only when BOTH edges were hits; otherwise
    ##   the first non-hit decision, compile before run.
    ## * `cacheMissReason` / `cachePublishSkipReason` — each edge's non-empty
    ##   text, prefixed with the edge's id and joined with "; ".
    ## * `observedInputs` — the UNION of both edges' observed reads, compile
    ##   first: the read set the single pre-split edge recorded. When an
    ##   edge executed this call, the reads of that execution; on a cache
    ##   hit they are reconstructed from the action-cache record only when
    ##   the caller set `ProfileCompileOptions.reportObservedInputs`
    ##   (otherwise empty: the engine is configured not to reconstruct them,
    ##   which keeps the apply path's warm hit cheap). This is the
    ##   dependency record the action cache keys on; it is exposed so
    ##   callers can see what a profile actually depends on.
    profileRoot*: string
    rbpiPath*: string
    rbpiBytes*: seq[byte]
    digestHex*: string
    edgeLaunched*: bool
    cacheDecision*: CacheDecision
    cacheMissReason*: string
    cachePublishSkipReason*: string
    observedInputs*: seq[string]
    compileEdge*: ProfileEdgeOutcome
    runEdge*: ProfileEdgeOutcome

  ProfileCompileOptions* = object
    ## Caller-tunable knobs. `stateDir` is the per-user state directory
    ## that hosts the `<state-dir>/profile-cache/` tree. `publicCliPath`
    ## is the absolute path to the `repro` binary that hosts the
    ## `__repro-compile-profile` internal helper subcommand.
    ## `repoRoot` is the reprobuild source tree, passed to the helper as
    ## `--repo-root`; empty resolves it through `resolveReprobuildSourceRoot()`
    ## and refuses with `missingReprobuildSourcesMessage()` when none holds
    ## reprobuild's libs.
    ## `workDir` is the cwd to run both edges in (defaults to the
    ## profile's parent directory). `verbose` and `forceRebuild` are
    ## debug knobs; `forceRebuild` removes both edges' declared outputs (and
    ## the published envelope) so the engine must re-execute both rather
    ## than answer from its cache.
    ## `reportObservedInputs` asks for `ProfileCompileArtifact.observedInputs`
    ## on a cache hit too (reconstructed from the records the hits were
    ## served from). It does not change the cache decisions or the actions'
    ## identities; `repro home export` sets it to report the profile files
    ## its intent was compiled from.
    stateDir*: string
    publicCliPath*: string
    repoRoot*: string
    workDir*: string
    verbose*: bool
    forceRebuild*: bool
    reportObservedInputs*: bool
    declaredInputs*: seq[string]
      ## Files the caller KNOWS the compile reads, declared as inputs of the
      ## compile edge in addition to what the monitor observes: the deploy
      ## agent's staged profile bundle (RDMF v3 `profileFiles`), which the
      ## profile `staticRead`s. The monitor records such a read on every
      ## supported platform; the declaration is belt to that brace on a
      ## host whose classifier has a gap (a missed read of a closure lock
      ## would apply a stale closure and report success). Absolute paths.

  ProfileCompileError* = object of CatchableError

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

proc raiseProfileCompile(message: string) {.noreturn.} =
  raise newException(ProfileCompileError, message)

const MissingPublicCliPathReason* =
  " (the `repro` image that runs this compile's actions under " &
  "`internal io monitor`). An embedded caller -- a binary that links this " &
  "library and has not declared itself `repro` -- must name one: pass " &
  "`publicCliPath`, or set REPRO_PUBLIC_CLI_PATH. Its own image is never " &
  "used, because it would be re-executed with an internal verb it does " &
  "not implement, run nothing, and leave the monitor capture empty."
  ## Why an empty `publicCliPath` is refused rather than defaulted. The CLI
  ## callers resolve it through `repro_cli_support/self_spawn_image`, which
  ## answers "" for an image that has not declared itself `repro`
  ## (Distribution-And-Packaging.md §5.2), so this is the sentence such a
  ## caller sees.

proc hasFailedActions(run: BuildRunResult): bool =
  for item in run.results:
    if item.status in {asFailed, asBlocked}:
      return true

proc describeActionFailure(item: ActionResult): string =
  var parts = @[item.id & " " & $item.status]
  if item.stderr.len > 0:
    parts.add(item.stderr)
  if item.stdout.len > 0:
    parts.add(item.stdout)
  parts.join("\n")

proc actionFailureDiagnostic(run: BuildRunResult): string =
  ## The diagnostic of the edge that FAILED, in preference to one that was
  ## merely blocked by it: with two edges, a failed compile leaves the run
  ## edge `asBlocked`, and the compile's own transcript (the Nim
  ## diagnostics) is what the user needs to see.
  for item in run.results:
    if item.status == asFailed:
      return describeActionFailure(item)
  for item in run.results:
    if item.status == asBlocked:
      return describeActionFailure(item)
  "profile compile failed"

const
  ProfileCompileActionId* = "__repro_profile_compile"
    ## The compile edge: `nim c` through the helper, output the binary.
  ProfileRunActionId* = "__repro_profile_run"
    ## The run edge: the profile binary itself, output the intent document.

proc actionResultFor(run: BuildRunResult; id: string): ActionResult =
  for item in run.results:
    if item.id == id:
      return item
  ActionResult(id: id)

proc edgeOutcome(item: ActionResult): ProfileEdgeOutcome =
  result = ProfileEdgeOutcome(
    id: item.id,
    launched: item.launched,
    cacheDecision: item.cacheDecision,
    cacheMissReason: item.cacheMissReason,
    cachePublishSkipReason: item.cachePublishSkipReason,
    observedInputs: item.evidence.monitorReads.paths())
  for observation in item.evidence.entropyObservations:
    result.entropySources.add(observation.source)
    result.entropyObservations.add(observation)

proc joinedPerEdge(texts: openArray[(string, string)]): string =
  ## "<edge id>: <text>" for each non-empty text, joined with "; ".
  var parts: seq[string]
  for (id, text) in texts:
    if text.len > 0:
      parts.add(id & ": " & text)
  parts.join("; ")

proc aggregateDecision(compileEdge, runEdge: ProfileEdgeOutcome):
    CacheDecision =
  ## `cdHit` only when both edges were hits; otherwise the first non-hit
  ## decision, compile before run.
  if compileEdge.cacheDecision != cdHit:
    return compileEdge.cacheDecision
  runEdge.cacheDecision

proc unionOfReads(compileEdge, runEdge: ProfileEdgeOutcome): seq[string] =
  ## Both edges' observed reads, compile first, each path once.
  for path in compileEdge.observedInputs:
    if path notin result:
      result.add path
  for path in runEdge.observedInputs:
    if path notin result:
      result.add path

proc profileCompileKey*(absProfile: string): string =
  ## The stable name of one profile's compile outputs under
  ## `<state-dir>/profile-cache/`: the BLAKE3 of the profile root's absolute
  ## path.
  ##
  ## DECLARED OUTPUT IDENTITY, NOT A FRESHNESS KEY. It names WHERE the edges
  ## publish, and it deliberately does not move when the profile's content
  ## changes: an output path that moved with the content would be a second,
  ## hand-written cache key in front of the action cache — the defect this
  ## module exists not to have. Content changes are the action cache's
  ## business. The path is hashed rather than embedded so it stays a single
  ## short component on every filesystem.
  blake3.toHex(blake3.digest(absolutePath(absProfile).replace('\\', '/')))

proc profileCompileWeakFingerprint*(nimExe, publicCliPath,
                                    binaryPath: string;
                                    cCompiler = ""): ContentDigest =
  ## The compile edge's weak fingerprint — the one part of its action key
  ## that is DECLARED rather than observed — reduced to what monitoring
  ## cannot supply:
  ##
  ## * compiler identity: the `nim` and the C compiler the helper will
  ##   resolve, and the helper binary itself;
  ## * declared output identity: the profile binary's path.
  ##
  ## It carries NO source digest. What the profile reads at compile time —
  ## its modules, data files pulled in with `staticRead`, `config.nims`,
  ## reprobuild's libraries — is recorded by the monitor and revalidated by
  ## the action cache on every lookup. Adding a source enumeration here
  ## would re-create the import-scan key that served stale intents.
  ##
  ## (`v3`: the pre-split edge's `v2` named the `.rbpi` path and the RBPI
  ## schema version. The envelope is no longer this edge's output, so its
  ## schema is no business of this key; `compileProfileToRbpi` encodes the
  ## envelope from the run edge's document on every call.)
  weakFingerprintFromText(
    "repro.profile.compile.v3\n" &
    "compiler=" & nimExe & "\n" &
    "c-compiler=" & cCompiler & "\n" &
    "helper=" & publicCliPath & "\n" &
    "output=" & binaryPath & "\n")

proc profileRunWeakFingerprint*(intentPath: string): ContentDigest =
  ## The run edge's weak fingerprint, likewise only what monitoring cannot
  ## supply: the declared output (the intent document's path) and the
  ## intent-output contract the binary is invoked under
  ## (`ReproIntentOutFlag`).
  ##
  ## It does NOT name the binary. The binary is the run edge's declared
  ## INPUT, so the action cache already keys the run on the binary's bytes;
  ## naming its path here as well would add nothing, and naming a digest of
  ## it would be a second, hand-written key for something the engine
  ## fingerprints. Everything the binary reads when it runs is observed.
  weakFingerprintFromText(
    "repro.profile.run.v1\n" &
    "intent-output-flag=" & ReproIntentOutFlag & "\n" &
    "output=" & intentPath & "\n")

# ---------------------------------------------------------------------------
# BuildAction construction.
#
# The COMPILE edge mirrors the provider-compile edge in shape (a monitored
# `bakProcess` running the public CLI's internal helper) AND in its
# determinism claim: it sets `ndpEntropyBlessed` with the provider compile's
# own `ProviderCompilerEntropyJustification` -- the same declaration, not a
# copy. That is sound for the same reason it is sound there: the helper only
# compiles, so its tree is nim and the C toolchain, and their randomness
# (nimcache scratch names, hash seeding, the stack-protector canary every
# MSYS2 gcc process seeds at start-up) does not reach the linked binary.
#
# The RUN edge stops short of that claim, and must. Its tree is the profile
# binary and whatever the profile starts -- chosen by user code, like a
# shell's tree by its script -- so a blessing there would waive randomness
# that CAN reach the intent (idiomatic-reprobuild.md §4.3, "Never bless an
# interpreter"). It is left at the default `ndpUnblessed` with no per-image
# blessings. `t_e2e_profile_run_edge_is_unblessed` holds both halves.
#
# Residual, shared with the provider compile and stated rather than hidden:
# a profile can `staticExec` an arbitrary program at COMPILE time, inside
# the blessed tree. If that program's randomness reached the binary the
# compile edge would publish it, and the run edge (keyed on the binary's
# bytes) would not notice.
#
# Environment. The compile edge's passthrough names the compiler variable
# and the temp-directory variables (`ProfileCompileEnvPassthrough`): the
# helper picks its Nim with `resolveProfileNimCompiler`
# (`$REPRO_NIM_COMPILER`, then `PATH`) and takes its nimcache from argv. Its
# C compiler comes from `resolveProfileCCompiler` (an explicit choice, else
# Nim's default, else the recipe compile's fallback); the variables it reads
# stay OBSERVED (keyed by value), and the resolved path is in the weak
# fingerprint. A clang is passed `-fno-temp-file` where it accepts the flag
# (`profileCompileCFlags`): with the blessing the `arc4random` draw it
# removes would no longer cost a publication, but a removed draw is still
# better than a waived one. The run edge names only the temp-directory
# variables, the rule the single edge applied to the profile binary's reads.
# ---------------------------------------------------------------------------

const ProfileCompileScratchEnvNames* = ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]
  ## Variables that only choose where the compile's disposable files go.
  ## `nim` and the C toolchain read them (io-mon records the reads), and an
  ## observed read is keyed on its VALUE. `nix develop` gives every shell a
  ## fresh `/tmp/nix-shell.XXXXXX`, so keyed by value they made the first
  ## profile compile in every new shell a miss ("input metadata changed:
  ## TEMP") on an unchanged profile -- a full ~7 s recompile. As passthrough
  ## they are keyed by name only (`actionEnvironmentKeyText`) and dropped from
  ## the observed-environment key (`cacheEnvInputs`), exactly as the provider
  ## compile treats them (`ProviderCompileEnvironmentPassthrough`).
  ##
  ## The cost of the rule: a profile whose INTENT embeds its temp directory
  ## (`getTempDir()` in a resource's content) would be served the intent of
  ## the run that published the record. Nothing that describes a home should
  ## depend on a per-shell scratch path, and the alternative is a recompile
  ## in every shell for every profile. Both edges apply it, so the profile
  ## binary's reads of these variables are keyed exactly as they were inside
  ## the single pre-split edge.

const ProfileCompileEnvPassthrough* =
  @[ProfileNimCompilerEnvVar] & @ProfileCompileScratchEnvNames
  ## The compile edge's `envPassthrough`: the compiler override the helper
  ## reads (a value from the ambient environment, so PASSTHROUGH by the
  ## classification rule in `repro_cli_support`) and the scratch-location
  ## variables above.

proc profileCompileBuildAction*(profileRoot, binaryPath, nimcacheDir,
                                publicCliPath, workDir, repoRoot: string;
                                weak: ContentDigest;
                                verbose = false;
                                declaredInputs: seq[string] = @[]): BuildAction =
  ## Build the COMPILE edge's `BuildAction`: the internal
  ## `__repro-compile-profile` helper, which runs `nim c` and links
  ## `binaryPath`.
  ##
  ## Declared inputs: none by default, plus whatever the caller names in
  ## `declaredInputs` (`ProfileCompileOptions.declaredInputs`: the deploy
  ## agent's staged bundle). The dependency record is whatever io-mon observes
  ## the helper, `nim` and the C toolchain read
  ## (`automaticMonitorGatheringPolicy`). There is no hand-written depfile:
  ## everything such a file could list, the monitor observes, and a list
  ## somebody maintains is only correct until a profile reads something its
  ## author did not anticipate. `action()` rejects a legacy depfile next to
  ## an explicit automatic-monitor policy: that combination used to silently
  ## select UNMONITORED `dgRecognizedFormat` evidence, which is how this edge
  ## used to be unmonitored while every comment said otherwise.
  ##
  ## Declared output: the profile binary, which the run edge consumes.
  ##
  ## Ignored input prefix: the per-profile nimcache. It is derived state the
  ## compile writes and reads back (Nim's C and object files); recording it
  ## would key the edge on its own scratch. The real inputs — profile
  ## sources, payloads, reprobuild's libraries, the toolchain — live
  ## elsewhere and stay recorded. Mirrors
  ## `providerCompileIgnoredInputPrefixes`. The binary is deliberately NOT
  ## under it (`cachedProfileBinaryPath`).
  ##
  ## Entropy: blessed exactly as the provider compile is (see the section
  ## comment above).
  var argv = @[
    publicCliPath,
    "__repro-compile-profile",
    "--profile", profileRoot,
    "--binary", binaryPath,
    "--nimcache", nimcacheDir,
    "--repo-root", repoRoot
  ]
  if verbose:
    argv.add("--verbose")
  let cwd =
    if workDir.len > 0: workDir
    else: profileRoot.parentDir
  action(ProfileCompileActionId, argv,
    # Named-Lock-Files §7.2. No solved package instance reaches this edge.
    # See `lockIdentityOutsideSolvedGraph`.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = cwd,
    inputs = declaredInputs,
    outputs = @[binaryPath],
    commandStatsId = "repro profile compile edge",
    cacheable = true,
    weakFingerprint = weak,
    envPassthrough = ProfileCompileEnvPassthrough,
    nonDeterminism = ndpEntropyBlessed,
    nonDeterminismJustification = ProviderCompilerEntropyJustification,
    dependencyPolicy = automaticMonitorGatheringPolicy(
      @[absolutePath(nimcacheDir)]))

proc profileRunBuildAction*(profileRoot, binaryPath, intentPath,
                            workDir: string;
                            weak: ContentDigest): BuildAction =
  ## Build the RUN edge's `BuildAction`: the profile binary, launched
  ## directly, writing its intent document under the intent-output contract
  ## (`<binary> --repro-intent-out <intentPath>`).
  ##
  ## NO HELPER AND NO SHELL. `argv[0]` is the binary; the engine launches it
  ## through the monitor like any tool. A `repro` process in between would
  ## be a stranger in this edge's tree (on Windows it draws a canary seed
  ## through its OpenSSL DLLs), and a shell would split a path with a space.
  ##
  ## Declared input: the binary. That orders this edge after the compile
  ## edge that produces it and puts the binary's bytes in this edge's key.
  ## `ffpHybrid` compares content when the metadata moved, so a compile that
  ## re-executes and links byte-identical bytes does not re-run the profile.
  ## Everything else the run reads is observed
  ## (`automaticMonitorGatheringPolicy`, no ignored prefix).
  ##
  ## Declared output: the intent document. The engine REMOVES it before the
  ## run (`removeBeforeRun`): a binary that exits 0 without emitting (an
  ## empty or comment-only profile) must not leave the previous run's
  ## document behind to be encoded as this run's intent.
  ##
  ## Entropy: UNBLESSED (`ndpUnblessed`, no `entropyBlessedImages`), and it
  ## must stay so -- see the section comment above. cwd and environment are
  ## what the binary had inside the single pre-split edge: the profile's
  ## directory (or `workDir`) and the caller's environment, with the
  ## temp-directory variables as passthrough.
  let cwd =
    if workDir.len > 0: workDir
    else: profileRoot.parentDir
  result = action(ProfileRunActionId,
    [binaryPath, ReproIntentOutFlag, intentPath],
    # Named-Lock-Files §7.2. No solved package instance reaches this edge.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = cwd,
    inputs = @[binaryPath],
    outputs = @[intentPath],
    commandStatsId = "repro profile run edge",
    cacheable = true,
    weakFingerprint = weak,
    actionCachePolicy = ffpHybrid,
    envPassthrough = @ProfileCompileScratchEnvNames,
    dependencyPolicy = automaticMonitorGatheringPolicy())
  result.removeBeforeRun = @[intentPath]

# ---------------------------------------------------------------------------
# BuildEngineConfig defaults appropriate for a profile compile.
# ---------------------------------------------------------------------------

## Selector args that turn ``<publicCliPath>`` into the in-process
## ``repro internal io monitor`` driver. ``monitoredAction`` prepends
## ``monitorCliPath & monitorCliArgs`` ahead of ``--depfile <path> --``
## and the real command, so WITHOUT these args the monitored argv
## degenerates to ``repro --depfile <path> -- <cmd>`` — an invalid
## invocation that exits non-zero and makes every profile-compile action
## fail under ``automaticMonitorGatheringPolicy``. Every production build
## config in ``repro_cli_support`` (``internalIoMonitorArgs``) sets the same
## triple; we mirror the literal here because ``repro_profile_compile``
## sits below ``repro_cli_support`` in the dependency graph and cannot
## import it without a cycle.
##
## NOTE: The canonical CLI recognizes the full ``internal io monitor`` triple.
## Omitting the middle ``io`` category falls through to the unknown-subcommand
## path and exits 2 with ``renderInternalUsage``, which surfaces from the build
## engine as
## ``__repro_profile_compile asFailed`` with the internal-namespace
## usage as the diagnostic body.
const ProfileCompileMonitorCliArgs* = @["internal", "io", "monitor"]

proc profileCompileEngineConfig*(stateDir, publicCliPath: string):
    BuildEngineConfig =
  ## A `BuildEngineConfig` tuned for a one-off profile compile. We park
  ## the action-cache under `<state-dir>/profile-cache/build-engine-cache`
  ## so the cache is per-user and lives alongside the published `.rbpi`
  ## artifacts. One edge at a time: the run edge depends on the compile.
  result = BuildEngineConfig(
    cacheRoot: stateDir / ProfileCacheDirName / "build-engine-cache",
    runQuotaCliPath: publicCliPath,
    monitorCliPath: publicCliPath,
    monitorCliArgs: ProfileCompileMonitorCliArgs,
    maxParallelism: 1'u32,
    stdoutLimit: 1024 * 1024,
    stderrLimit: 1024 * 1024,
    rebuildMissingOutputsOnCacheHit: true,
    deferLocalOutputBlobs: true,
    bypassRunQuota: true,
    fallbackToRunQuotaBypass: true,
    inlineRunQuota: false,
    suppressTrace: true,
    skipCacheHitEvidence: true)

# ---------------------------------------------------------------------------
# Envelope publication: a pure function of the run edge's output.
# ---------------------------------------------------------------------------

proc runDiagnostics(item: ActionResult): string =
  ## The profile binary's own stdout/stderr, when the run edge executed this
  ## call, for a diagnostic about its document.
  var parts: seq[string]
  if item.stderr.len > 0:
    parts.add("---- profile stderr ----\n" & item.stderr)
  if item.stdout.len > 0:
    parts.add("---- profile stdout ----\n" & item.stdout)
  if parts.len == 0:
    return ""
  "\n" & parts.join("\n")

proc publishEnvelope(rbpiPath: string; bytes: seq[byte]) =
  ## Publish `bytes` at `rbpiPath` (atomically), unless the file there
  ## already holds exactly these bytes. Writing only on a change keeps an
  ## unchanged envelope's mtime, which is what a caller that watches the
  ## file sees. This is NOT a freshness decision: `bytes` was just encoded
  ## from this call's intent document, and the existing file is only
  ## compared with it, never used in its place.
  if fileExists(extendedPath(rbpiPath)):
    try:
      if readBytes(rbpiPath) == bytes:
        return
    except IOError, OSError:
      discard
  writeBytesAtomic(rbpiPath, bytes)

# ---------------------------------------------------------------------------
# Public entry point.
# ---------------------------------------------------------------------------

proc anchoredCompileOptions*(opts: ProfileCompileOptions):
    ProfileCompileOptions =
  ## ``opts`` with its directories made absolute against THIS process's
  ## working directory. The compile's edges run with their own working
  ## directory (the reprobuild source tree, which in an installed engine is
  ## a store path), so a relative ``stateDir`` or ``workDir`` handed down as
  ## it was named the nimcache and the published binary relative to that
  ## tree: ``compile-profile --state-dir st`` failed with "cannot create
  ## directory: /nix/store/<...>-source/st/profile-cache/...". A relative
  ## path a caller passes means relative to where the caller runs.
  result = opts
  if result.stateDir.len > 0: result.stateDir = absolutePath(result.stateDir)
  if result.workDir.len > 0: result.workDir = absolutePath(result.workDir)
  if result.repoRoot.len > 0: result.repoRoot = absolutePath(result.repoRoot)

proc compileProfileToRbpi*(profileRoot: string;
                           opts: ProfileCompileOptions):
    ProfileCompileArtifact =
  ## Compile `profileRoot` (a `home.nim` / `system.nim` path) to the RBPI
  ## binary envelope and return both the published path and the bytes.
  ##
  ## Every call schedules both edges through one `runBuild`; the engine's
  ## action cache answers each edge whose observed inputs are unchanged
  ## without spawning it. Then the run edge's intent document is encoded as
  ## the envelope -- on every call, a pure function of that document.
  ##
  ## Required `opts` fields: `stateDir`, `publicCliPath`. An empty `repoRoot`
  ## is resolved through `resolveReprobuildSourceRoot()`, and the call is
  ## refused with `missingReprobuildSourcesMessage()` when nothing resolves.
  if opts.stateDir.len == 0:
    raiseProfileCompile("compileProfileToRbpi: stateDir is required")
  let opts = anchoredCompileOptions(opts)
  if opts.publicCliPath.len == 0:
    raiseProfileCompile("compileProfileToRbpi: publicCliPath is required" &
      MissingPublicCliPathReason)

  let absProfile = absolutePath(profileRoot)
  if not fileExists(extendedPath(absProfile)):
    raiseProfileCompile("compileProfileToRbpi: profile root does not " &
      "exist: " & absProfile)

  # No explicit root: resolve one, and refuse HERE when nothing holds
  # reprobuild's libs, with the list of every place that was looked at. The
  # alternative -- handing the helper a root nobody chose -- surfaced as a
  # nim `cannot open file` (or a `setCurrentDir` failure) deep inside the
  # monitored edge, naming neither the missing tree nor its remedy.
  let repoRoot =
    if opts.repoRoot.len > 0: opts.repoRoot
    else:
      let resolved = resolveReprobuildSourceRoot()
      if resolved.len == 0:
        raiseProfileCompile(missingReprobuildSourcesMessage())
      resolved

  createDir(extendedPath(profileCacheDir(opts.stateDir)))

  # Remove envelopes written in a previous RBPI schema version. This is
  # disk hygiene, not a freshness decision: the envelope is re-encoded from
  # the run edge's document on every call, so a stale-schema file would be
  # replaced anyway.
  discard pruneStaleProfileCache(opts.stateDir)

  let key = profileCompileKey(absProfile)
  let rbpiPath = cachedRbpiPath(opts.stateDir, key)
  let binaryPath = cachedProfileBinaryPath(opts.stateDir, key)
  let intentPath = cachedIntentDocumentPath(opts.stateDir, key)
  let nimcacheDir = cachedNimcacheDir(opts.stateDir, key)

  # The compiler identity the compile edge's weak fingerprint names.
  # Resolved here with the helper's own resolver (`$REPRO_NIM_COMPILER`,
  # then `PATH`), in the same environment the helper inherits, so a missing
  # or mis-named compiler is reported before an edge is scheduled at all.
  let nimExe =
    try:
      resolveProfileNimCompiler()
    except CompileFailure as err:
      raiseProfileCompile(err.msg)
  # The C compiler, likewise: the helper resolves the same one in the same
  # environment, and a mis-named `$REPRO_BOOTSTRAP_CC` is refused here.
  let cCompiler =
    try:
      resolveProfileCCompiler()
    except CompileFailure as err:
      raiseProfileCompile(err.msg)

  # On force-rebuild remove both edges' declared outputs and the envelope.
  # The engine configuration sets `rebuildMissingOutputsOnCacheHit`, so a
  # record whose declared output is missing is re-executed rather than
  # restored — which is what the caller asked for, for both edges.
  if opts.forceRebuild:
    for path in [binaryPath, intentPath, rbpiPath]:
      if fileExists(extendedPath(path)):
        removeFile(extendedPath(path))

  let compileAction = profileCompileBuildAction(absProfile, binaryPath,
    nimcacheDir, opts.publicCliPath, opts.workDir, repoRoot,
    profileCompileWeakFingerprint(nimExe, opts.publicCliPath, binaryPath,
      cCompiler),
    opts.verbose, opts.declaredInputs)
  let runAction = profileRunBuildAction(absProfile, binaryPath, intentPath,
    opts.workDir, profileRunWeakFingerprint(intentPath))
  var config = profileCompileEngineConfig(opts.stateDir, opts.publicCliPath)
  if opts.reportObservedInputs:
    # Reconstruct a hit's evidence from its record. Serving consequences are
    # none: the same record is loaded and revalidated either way.
    config.skipCacheHitEvidence = false
  let runResult = runBuild(graph(@[compileAction, runAction]), config)
  let runItem = runResult.actionResultFor(ProfileRunActionId)
  # The run edge's document is the profile's intent. Its absence after a
  # run that exited 0 is a profile whose emitter never ran -- NOT an empty
  # intent: inventing a zero-resource intent would apply "converge to
  # nothing" to a host and report success.
  #
  # The engine fails such a run edge itself (Build-Engine-And-Scheduler.md
  # §"A declared output is an obligation") and names the absent output in
  # `missingOutputs`; this reports that failure in the profile's terms. The
  # engine's generic sentence is dropped from the transcript quoted below,
  # which is the profile binary's own output.
  var profileOutput = runItem
  if runItem.missingOutputs.len > 0:
    profileOutput.stderr = runItem.stderr.replace(
      missingDeclaredOutputsDiagnostic(runAction, runItem.missingOutputs),
      "").strip()
  let missingIntent = "repro profile compile: the compiled profile " &
    absProfile & " exited 0 but printed no ProfileIntent JSON (no " &
    "intent document at " & intentPath & "). The profile module never " &
    "reached the intent emitter — an empty or comment-only profile does " &
    "exactly this." & runDiagnostics(profileOutput)
  if runResult.hasFailedActions():
    if intentPath in runItem.missingOutputs:
      raiseProfileCompile(missingIntent)
    raiseProfileCompile(actionFailureDiagnostic(runResult))
  # Unreachable while the engine enforces its declared outputs; kept so
  # that this module never encodes an intent it did not see produced.
  if not fileExists(extendedPath(intentPath)):
    raiseProfileCompile(missingIntent)
  let document =
    try:
      readFile(extendedPath(intentPath))
    except IOError as err:
      raiseProfileCompile("repro profile compile: cannot read the intent " &
        "document " & intentPath & ": " & err.msg)
  var bytes: seq[byte]
  try:
    bytes = rbpiBytesFromJson(document)
  except CatchableError as err:
    raiseProfileCompile("repro profile compile: failed to encode RBPI " &
      "envelope from the compiled profile's intent document " & intentPath &
      ": " & err.msg & runDiagnostics(runItem))
  try:
    discard profile_envelope.readEnvelope(bytes)
  except CatchableError as err:
    raiseProfileCompile("repro profile compile: generated RBPI envelope " &
      "is structurally invalid: " & err.msg)
  publishEnvelope(rbpiPath, bytes)
  # Self-consistency of what was published, NOT a freshness re-check:
  # nothing here compares the result against the profile's sources — that
  # question was answered by the action cache, and asking it a second time
  # with a weaker key is the gate this module removed.
  if not rbpiEnvelopeIsValid(rbpiPath):
    raiseProfileCompile("profile compile published a structurally " &
      "invalid RBPI envelope: " & rbpiPath)

  let compileEdge = edgeOutcome(
    runResult.actionResultFor(ProfileCompileActionId))
  let runEdge = edgeOutcome(runItem)
  result = ProfileCompileArtifact(
    profileRoot: absProfile,
    rbpiPath: rbpiPath,
    rbpiBytes: bytes,
    digestHex: blake3.toHex(blake3.digest(bytes)),
    edgeLaunched: compileEdge.launched or runEdge.launched,
    cacheDecision: aggregateDecision(compileEdge, runEdge),
    cacheMissReason: joinedPerEdge([
      (compileEdge.id, compileEdge.cacheMissReason),
      (runEdge.id, runEdge.cacheMissReason)]),
    cachePublishSkipReason: joinedPerEdge([
      (compileEdge.id, compileEdge.cachePublishSkipReason),
      (runEdge.id, runEdge.cachePublishSkipReason)]),
    observedInputs: unionOfReads(compileEdge, runEdge),
    compileEdge: compileEdge,
    runEdge: runEdge)

# ---------------------------------------------------------------------------
# The platform-probe edge.
#
# A second monitored edge beside the compile, run only by `repro home
# export`: it evaluates the profile for every target platform
# (`platforms.nim`) and publishes the outcomes. It is its own edge, not a
# step of the compile, because only the export needs it -- `repro home
# apply` would otherwise pay six `nim check`s on every cold compile -- and
# like the compile it decides nothing about freshness itself: the action
# cache answers from what io-mon observed the checks read.
# ---------------------------------------------------------------------------

const ProfilePlatformProbeActionId* = "__repro_profile_platform_probe"

type
  ProfilePlatformProbeArtifact* = object
    ## Result of a platform probe: one outcome per `ProfileTargetPlatforms`
    ## entry, plus the engine's decision about the edge (as for
    ## `ProfileCompileArtifact`).
    path*: string
    outcomes*: seq[ProbeOutcome]
    edgeLaunched*: bool
    cacheDecision*: CacheDecision
    cacheMissReason*: string

proc cachedPlatformProbePath*(stateDir, profileKey: string): string =
  profileCacheDir(stateDir) / profileKey & ".platforms.json"

proc cachedPlatformProbeScratch*(stateDir, profileKey: string): string =
  ## The probe's per-platform `--nimcache` directories: derived state,
  ## excluded from the edge's recorded inputs like the compile's nimcache.
  profileCacheDir(stateDir) / "platform-probe" / profileKey

proc profilePlatformProbeWeakFingerprint*(nimExe, publicCliPath,
                                          outPath: string): ContentDigest =
  ## Declared identity only, as for `profileCompileWeakFingerprint`: which
  ## compiler and helper, where the output lands, which document version
  ## and which platforms. Everything the profile reads is observed.
  weakFingerprintFromText(
    "repro.profile.platform-probe.v1\n" &
    "compiler=" & nimExe & "\n" &
    "helper=" & publicCliPath & "\n" &
    "output=" & outPath & "\n" &
    "probe-version=" & $ProfilePlatformProbeVersion & "\n" &
    "platforms=" & targetSystemNames().join(",") & "\n")

proc probeProfilePlatforms*(profileRoot: string;
                            opts: ProfileCompileOptions):
    ProfilePlatformProbeArtifact =
  ## Run (or answer from the action cache) the platform-probe edge for
  ## `profileRoot`. Uses the compile's `stateDir`, `publicCliPath`,
  ## `repoRoot` and `workDir`; `forceRebuild` removes the published
  ## document first. Raises `ProfileCompileError` when the edge fails.
  if opts.stateDir.len == 0:
    raiseProfileCompile("probeProfilePlatforms: stateDir is required")
  if opts.publicCliPath.len == 0:
    raiseProfileCompile("probeProfilePlatforms: publicCliPath is required" &
      MissingPublicCliPathReason)
  let absProfile = absolutePath(profileRoot)
  if not fileExists(extendedPath(absProfile)):
    raiseProfileCompile("probeProfilePlatforms: profile root does not " &
      "exist: " & absProfile)
  let repoRoot =
    if opts.repoRoot.len > 0: opts.repoRoot
    else: reprobuildRepoRoot()
  createDir(extendedPath(profileCacheDir(opts.stateDir)))
  let key = profileCompileKey(absProfile)
  let outPath = cachedPlatformProbePath(opts.stateDir, key)
  let scratch = cachedPlatformProbeScratch(opts.stateDir, key)
  let nimExe =
    try:
      resolveProfileNimCompiler()
    except CompileFailure as err:
      raiseProfileCompile(err.msg)
  if opts.forceRebuild and fileExists(extendedPath(outPath)):
    removeFile(extendedPath(outPath))
  let weak = profilePlatformProbeWeakFingerprint(nimExe, opts.publicCliPath,
    outPath)
  let argv = @[
    opts.publicCliPath,
    "__repro-probe-profile-platforms",
    "--profile", absProfile,
    "--out", outPath,
    "--nimcache", scratch,
    "--repo-root", repoRoot
  ]
  let cwd =
    if opts.workDir.len > 0: opts.workDir
    else: absProfile.parentDir
  let buildAction = action(ProfilePlatformProbeActionId, argv,
    # Named-Lock-Files §7.2: no solved package instance reaches this edge.
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    cwd = cwd,
    outputs = @[outPath],
    commandStatsId = "repro profile platform probe edge",
    cacheable = true,
    weakFingerprint = weak,
    envPassthrough = ProfileCompileEnvPassthrough,
    # The compile edge's blessing, for the compile edge's reason: this
    # edge's tree is the helper and `nim dump` / `nim check` -- a compiler
    # that links nothing and runs nothing it produced. The profile's intent
    # proc is evaluated in Nim's compile-time VM, which has no access to an
    # OS entropy source (only `staticExec` reaches outside it, the residual
    # the provider compile and the compile edge share). The one draw
    # measured in this edge on Windows is the helper's own: the engine's
    # OpenSSL DLLs seed a stack-protector canary at start-up, so without the
    # blessing the probe never published on its first run and every export
    # re-ran six `nim check`s (reprobuild-pm
    # `spec/Profile-Compilation-Model.md` §2.1).
    nonDeterminism = ndpEntropyBlessed,
    nonDeterminismJustification = ProviderCompilerEntropyJustification,
    dependencyPolicy = automaticMonitorGatheringPolicy(
      @[absolutePath(scratch)]))
  let config = profileCompileEngineConfig(opts.stateDir, opts.publicCliPath)
  let runResult = runBuild(graph(@[buildAction]), config)
  if runResult.hasFailedActions():
    raiseProfileCompile(actionFailureDiagnostic(runResult))
  if not fileExists(extendedPath(outPath)):
    raiseProfileCompile("platform probe edge did not write its output: " &
      outPath)
  var edge = ActionResult(id: ProfilePlatformProbeActionId)
  for item in runResult.results:
    if item.id == ProfilePlatformProbeActionId:
      edge = item
  let outcomes =
    try:
      decodeProbeOutcomes(readFile(extendedPath(outPath)))
    except CatchableError as err:
      raiseProfileCompile("platform probe edge wrote an unreadable " &
        "document " & outPath & ": " & err.msg)
  ProfilePlatformProbeArtifact(path: outPath, outcomes: outcomes,
    edgeLaunched: edge.launched, cacheDecision: edge.cacheDecision,
    cacheMissReason: edge.cacheMissReason)
