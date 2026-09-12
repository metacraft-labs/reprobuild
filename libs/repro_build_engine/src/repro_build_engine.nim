import std/[algorithm, json, locks, monotimes, options, os, osproc, net,
    nativesockets, parsecfg, sets, streams, strtabs, strutils, tables,
    tempfiles, times]

# The OS is reached through a named symbol list on both platforms, never
# wholesale. ``std/posix`` exports ``fork`` / ``execvp`` / ``posix_spawn``
# and ``std/winlean`` exports ``createProcessW`` / ``shellExecuteW``, so a
# blanket import puts a way to start an UNMONITORED child in scope
# throughout this module. Every launch path here has to go through
# ``monitoredAction`` and ``preparedRunQuotaCommand``; keeping the import
# narrow is what makes that a property of the code rather than a
# convention. ``tests/integration/t_every_launch_path_is_monitored.nim``
# enforces both lists.
when defined(windows):
  from std/winlean import Handle, DWORD, WINBOOL, SYNCHRONIZE,
    MAXIMUM_WAIT_OBJECTS, WOHandleArray, openProcess, closeHandle,
    waitForMultipleObjects
elif defined(posix):
  # ``Mode`` / ``umask`` / ``dup`` / ``dup2`` / ``close`` are the
  # In-Process-Monitor-Hosting HM-4 spawn context and nothing else. io-mon
  # spawns with ``poParentStreams``, so a monitored child inherits THIS
  # process's descriptors 1 and 2, and the canonical 0022 file-creation mask
  # used to arrive through the ``/bin/sh -c 'umask 022 && …'`` wrapper the
  # monitor CLI ran under. Both are re-established across the spawn instead —
  # see ``beginMonitorSpawnContext``. None of the five starts a child.
  from std/posix import Pid, SIGKILL, SIGTERM, kill, setpgid, Mode, umask,
    dup, dup2, close

import repro_core
import repro_depfile
import repro_hash
import repro_local_store
import repro_cas_store
# Incremental-Test-Runner M7: the build engine consumes the shared ``io-mon``
# library (a byte-identical wire-format + ABI relocation of reprobuild's former
# ``repro_monitor_depfile`` io-monitor stack) for its monitor-evidence dependency
# tracking. ``io_mon`` re-exports the depfile API under the SAME names
# (``MonitorDepFile`` / ``readMonitorDepFile`` / ``MonitorRecord`` / the
# ``mr*`` / ``mo*`` enums / ``mcComplete`` / ``MonitorDepFileReaderError`` /
# ``findShimLibrary``), so the call sites below are unchanged.
# The depfile FORMAT is owned by io-mon; reprobuild consumes it through io-mon's
# public API (`streamMonitorDepFileRecords` / `MonitorRecord` / the `mr*`/`mo*`
# enums / `MonitorDepFileReaderError`), never by re-deriving the envelope layout.
# The former `io_mon/codec` + `io_mon/writer` internal imports (the hand-rolled
# iomon decoder reached into them) are gone.
import io_mon
import repro_platform
import repro_runquota
# M17: the ``ext_repro_action`` schema, the compatibility key, and the
# row shape. A leaf module by construction — it imports only the hash
# library — so the engine can build a row without the row's definition
# reaching back into the engine.
import repro_build_engine/action_extension

# In-Process-Monitor-Hosting HM-5 — the asynchronous, atomic depfile
# publication. A leaf module by construction: it takes two paths and an action
# id, imports nothing that can start a child, and shares no GC'd structure with
# the scheduler. Read its header before changing anything here that touches
# ``depTempPath`` / ``depDestPath``.
import repro_build_engine/monitor_flush
# Engine-Threadpool TP-1/TP-2: the flush above is one TENANT of the engine's
# worker pool, not a thread of its own, and TP-2's monitor finish is the
# second. The flush's tenancy is entirely inside ``monitor_flush``, so the
# scheduler needed only the pool's whole-pool drain from here and the import
# was narrowed to it — deliberately, so the pool's shared-memory helpers did
# not enter this module's namespace.
#
# THAT NARROWING IS GONE, and the reason is a gate rather than a preference.
# TP-2's tenant has to name ``MonitorHandle`` and CALL ``finishMonitor``, and
# ``t_every_launch_path_is_monitored`` requires both to live in THIS module —
# so the tenant is written below (see the TP-2 block above
# ``InProcessMonitorHostSupported``) and it needs the pool's job header, its
# submit, its per-tenant waits and its ``sharedDup`` / ``sharedFree``. What
# the narrow import bought is preserved by the tenant instead: the only place
# in this file that touches shared memory is the TP-2 block, and every node it
# allocates is freed in one proc (``dropMonitorFinishNode``).
import repro_build_engine/worker_pool
export action_extension

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

# Named-Lock-Files §7.2. ``repro_lock/identity`` is a LEAF module — ``std`` +
# ``repro_multihash`` and nothing else — precisely so the engine can carry a
# governing lock identity on every action without acquiring a dependency on
# ``repro_lock.nim``, which imports ``repro_solver`` and therefore dlopens
# ``libclingo`` at module-init time. Importing the parent here would put a
# clingo runtime requirement on every engine binary. Do not "simplify" this to
# ``import repro_lock``.
import repro_lock/identity
export identity

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
    bakEnsureLine
    bakEnsureSnippet
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
    # Provisioning task delegating to Nix Evaluation Daemon or other foreign provisioners
    bakForeignProvision
    # Named-Lock-Files NLF-M5 (§5.6): one retrieved metadata object — a
    # repository root manifest, an index shard, a package's version list.
    # An explicitly NON-HERMETIC, cacheable fetch edge whose output is
    # content-addressed by what it actually retrieved, and which exists on
    # the lock-GENERATION path only. It carries ``netFetch`` (see
    # ``NetworkMode``) so the non-hermeticity is visible in the graph
    # before the action runs. Dispatched through the executor registered
    # by ``repro_lock_gen``, which rides the in-process fetch path
    # (``http_pool``) — a metadata fetch MUST NOT shell out to a solved
    # tool, because that tool is an output of the solve the fetch
    # precedes.
    bakMetadataFetch
    # Named-Lock-Files NLF-M5 (§5.6): THE SOLVE, as a **rule generator**
    # in the sense of ``Package-Model.md`` §"Rule Generators And Dynamic
    # Rule Discovery". Its generated rule-set artifact is the LOCK FILE,
    # which the evaluator then expands into the concrete build actions of
    # the second wave. It is not an ordinary peer edge of the actions it
    # determines; see ``expandGraphInWaves``.
    bakSolveLock

  NetworkMode* = enum
    ## Sandbox-And-Monitoring.md §"The Network Dimension" (NLF-M5
    ## amendment, 2026-08-21) — the per-action half of the policy layer's
    ## second dimension.
    ##
    ## ``netDenied`` is FIRST deliberately: it is the enum's zero value, so
    ## an action that says nothing about the network is denied by
    ## construction rather than by a defaulting rule somebody has to
    ## remember to write. That is amendment rule 1 — "Default deny; silence
    ## is denial. An action with no network policy is ``netDenied``. Adding
    ## the dimension must not turn unclassified into permitted." — made
    ## structural.
    netDenied
      ## The action is hermetic in the strict sense and reaches no
      ## destination. Any attempt is a policy violation, handled exactly as
      ## a denied-path access is.
    netFetch
      ## The action is an explicitly non-hermetic, cacheable fetch edge. It
      ## may reach the destinations its policy classifies as tracked; its
      ## output is content-addressed by what it actually retrieved; and its
      ## cache behaviour is revalidation under a freshness policy, never an
      ## assumption that a past result still holds.
      ##
      ## Amendment rule 2 — "Non-hermeticity is declared, not inferred" —
      ## is why this lives in the action's DEFINITION: the fact is visible
      ## in the graph before the action runs, and an attempted access under
      ## ``netDenied`` is a violation, never a silent promotion to here.

  EngineTypedOutput* = object
    ## Typed-Outputs M1: engine-side mirror of
    ## ``repro_project_dsl.BuildActionTypedOutput``. Decoupled by a
    ## distinct type so the engine doesn't take a hard dependency on
    ## the project-DSL package.
    fieldName*: string
    types*: seq[string]
    path*: string

  BuildAction* = object
    governingLockIdentity* {.requiresInit.}: LockIdentity
      ## Named-Lock-Files §7.2 — the identity of the lock file governing this
      ## edge. **Required, by the type system.**
      ##
      ## §7 keys action identity on the governing lock (design A, decided by
      ## the owner on 2026-08-18 in favour of A over path-partitioning,
      ## because B "requires every action's outputs to sit under a root
      ## Reprobuild controls" and `Foreign-Provisioner-Contracts.md` exists
      ## precisely because some instances are materialised by provisioners
      ## Reprobuild does not own). A's one real weakness is that it can be
      ## applied INCOMPLETELY, and incompleteness is silent: "a single edge
      ## whose fingerprint forgets the governing lock identity is a silent
      ## poisoning vector — it serves one lock file's artifacts to another and
      ## reports success."
      ##
      ## §7.2 closes that "by a structural check, not by care", and names two
      ## halves. This field is the first: "The governing lock identity is a
      ## non-optional field on the action construction path, so an action
      ## cannot be built without one. Absence is a compile error where the
      ## type system can reach it, and a hard failure at graph construction
      ## where it cannot." `{.requiresInit.}` is the compile-error half and it
      ## reaches further than the constructors — it rejects a direct
      ## `BuildAction(...)` object construction that omits the field, so a
      ## newly added edge kind cannot quietly opt out by bypassing `action()`
      ## / `builtinAction()`. `auditGoverningLockIdentity` is the second half:
      ## a whole-graph assertion, enforced from `validateGraph`.
      ##
      ## It is FIRST in the field list deliberately. A required field placed
      ## among optional ones reads as one more knob; placed first it is the
      ## first thing an author of a new edge kind meets.
      ##
      ## The value is content-derived (§6.2) and the lock-file NAME is not in
      ## it. Provenance — which name or names resolved to this identity — is a
      ## side table (`repro_lock/identity.LockProvenance`), read by
      ## diagnostics and never mixed into a key.
    kind*: BuildActionKind
    id*: string
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    argv*: seq[string]
    cwd*: string
    env*: seq[string]
    envPassthrough*: seq[string]
      ## Names of environment variables whose VALUE is the host's, not
      ## Reprobuild's. BuildXL's `passThroughEnvironmentVariables`, with
      ## BuildXL's semantics: the NAME is part of what the action is (it
      ## records "this action reads the host's `PATH`") and enters the
      ## weak fingerprint; the VALUE never does — including when `env`
      ## above carries a declared value for the same name, which is
      ## BuildXL's passthrough-with-value case (the process is launched
      ## with that value, the fingerprint does not see it).
      ##
      ## This exists because keying on the environment BY VALUE is not
      ## the fix for an unkeyed environment, it is a different defect.
      ## An action's `PATH` is resolved tool directories prepended to
      ## the host's; under `nix develop` that is not what it is in CI.
      ## A key that read it would invalidate every edge of every graph
      ## on any host difference.
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
    nonDeterminism*: NonDeterminismPolicy
      ## Windows-Build-Correctness M6 — the entropy blessing of the TOOL
      ## this action invokes, declared in that tool's CLI spec and lowered
      ## here by ``repro_cli_support``. ``ndpUnblessed`` (the zero value) is
      ## the default for every hand-constructed and legacy action, which is
      ## the fail-closed direction: an action nobody vouched for pays for
      ## observed entropy with its cache publication. Read by
      ## ``collectEvidence``.
    nonDeterminismJustification*: string
      ## The tool's own stated reason, quoted into the action's evidence
      ## diagnostics so ``repro why`` can answer "why did this keep caching
      ## despite reading randomness?" without the reader having to go and
      ## find the package spec.
    determinism*: Option[EdgeDeterminism]
      ## ``Edge-Determinism-And-Soft-Rebuild.md`` §2 — the edge's declared
      ## determinism class, from the tool's ``cli:`` block or a per-edge
      ## strengthening override.
      ##
      ## An ``Option`` and not a bare enum ON PURPOSE. §2.1's default for an
      ## unlabelled tool is ``weak``, but the enum's ZERO value is
      ## ``edStrong`` — the one class the trust model lets cross a machine
      ## boundary unverified. A bare field would hand every legacy and
      ## hand-constructed action a silent ``strong`` label, which is an
      ## over-promise waiting for the binary-cache slice to read it.
      ## ``none`` means "unlabelled"; ``effectiveDeterminism`` resolves it to
      ## ``edWeak``. Do not "simplify" this to a plain enum.
      ##
      ## This is DISTINCT from ``nonDeterminism`` above, which is a narrow
      ## policy about whether an OBSERVED entropy read costs the action its
      ## cache publication. This field is the action's declared
      ## reproducibility class and drives retention, cross-machine
      ## substitution, and the ``--soft-rebuild`` family.
    cacheRetention*: CacheRetention
      ## §2.2's clause, meaningful only for a ``volatile`` edge (for which
      ## §2.2 makes its ABSENCE an error). ``crkForever`` — the zero value —
      ## is what every other class carries and what every existing action
      ## keeps, so the cache read path for them is byte-for-byte unchanged.
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
    declaredOutputs*: seq[string]
      ## M9.R.75 — R7 (double-write reject) per-action write-root
      ## declaration. Spec cite: Filesystem-Policy-And-Observed-
      ## Inputs.md §"Double Writes" (lines 246-262). Populated by the
      ## DSL lowering from ``BuildActionDef.declaredOutputs``; consumed
      ## by ``validateGraph``'s pairwise write-root intersection pass.
      ##
      ## Distinct from ``outputs``: that field is the per-action stamp
      ## / artefact set for post-run readiness + cache-key composition
      ## (typically a single stamp file that differs per action by
      ## design). ``declaredOutputs`` carries the FULL write ROOT
      ## (``$buildDir`` / ``$installDir`` / ``$fetchExtracted``) so
      ## the intersection pass catches two actions racing for the same
      ## DESTDIR — the case the string-equality check on ``outputs``
      ## misses because the stamp files differ.
      ##
      ## Empty (the default) preserves pre-M9.R.75 behaviour: the
      ## intersection pass no-ops for actions that didn't opt in.
    readOnlyRoots*: seq[string]
      ## M9.R.75 — R6 (source-write reject) per-action read-only-root
      ## declaration. Spec cite: Filesystem-Policy-And-Observed-
      ## Inputs.md §"Source Rewrites" (lines 264-278). Populated by
      ## the DSL lowering from ``BuildActionDef.readOnlyRoots``;
      ## consumed by the engine's spawn wrapper (bwrap sandbox on
      ## Linux) and the post-hoc monitor-evidence checker (all
      ## platforms).
      ##
      ## Fetch actions leave this empty — R6 explicitly names the
      ## fetch step as "the action explicitly owns the target
      ## location" and permits it to write into the source tree.
      ## Empty (the default) preserves pre-M9.R.75 behaviour: the
      ## source-write enforcement layer no-ops.
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
    networkMode*: NetworkMode
      ## Sandbox-And-Monitoring.md §"The Network Dimension" — this
      ## action's network mode. The zero value is ``netDenied``, so every
      ## action that predates the dimension, and every action whose author
      ## says nothing, is denied. There is no ambient or global "network
      ## allowed" switch: a build in which some edge reaches the network
      ## is a build in which THAT edge declared it.
    netDestinations*: seq[string]
      ## The destinations this action's policy classifies as **tracked
      ## fetch destinations** — the only class that makes a
      ## network-touching edge cacheable. A destination is named by
      ## scheme, host, optional port and optional path prefix
      ## (``https://index.example/pkgs/``), so "this edge may reach the
      ## package index" is expressible without granting the host
      ## generally.
      ##
      ## Empty under ``netDenied`` and non-empty under ``netFetch``; both
      ## halves are enforced by ``auditNetworkPolicy`` from
      ## ``validateGraph``, because a ``netFetch`` edge with no declared
      ## destination is a permission with no subject, and a ``netDenied``
      ## edge that names one is an author who believed they had granted
      ## something and did not.
      ##
      ## The recorded destination set is HALF the evidence a ``netFetch``
      ## edge produces; the other half is the content digest of what it
      ## retrieved. Per the amendment this is deliberately NOT a sixth
      ## observed-input class — a network access is not a filesystem fact
      ## — so it is recorded alongside the path set, never inside it.

  BuildPool* = object
    name*: string
    capacity*: uint32

  BuildGraph* = object
    actions*: seq[BuildAction]
    pools*: seq[BuildPool]

  MonitorLaunchPath* = enum
    ## In-Process-Monitor-Hosting P3 — the launch paths a ``bakProcess``
    ## action can be started through, as ONE value.
    ##
    ## It exists so that "which launch path is this" and "may that launch
    ## path host io-mon in-process" stop being two independent boolean
    ## expressions that can drift apart. They used to be exactly that: the
    ## hosting decision carried a bare ``bypassRunQuota`` conjunct and the
    ## inline launch site never looked at the answer at all, so relaxing the
    ## conjunct would have stripped the monitor wrapper from an action that
    ## no site was going to host. See ``launchPathHostsMonitorInProcess``.
    mlpBypassRunQuota
      ## L1 — the engine spawns the child itself (`--no-runquota`, an
      ## unreachable daemon, and every nested build in the test suite).
    mlpInlineRunQuota
      ## L3 / L3b — the engine holds the RunQuota session, but
      ## ``offerWithRunQuotaBatch`` / ``startGrantedWithRunQuota`` spawn the
      ## child themselves as an inseparable part of binding it to the
      ## granted lease. This is what a normal ``repro build`` takes.
    mlpRunQuotaHelper
      ## L2 — a separate ``repro __repro-runquota-helper`` process spawns
      ## the action, two processes deep.

  MonitorHostingMode* = enum
    ## How hard ``BuildEngineConfig`` asks for in-process monitor hosting.
    ##
    ## An enum rather than a bool because "host where you can, wrap
    ## elsewhere" and "host or fail" are different requests and the
    ## difference is load-bearing: the second one is what makes the launch
    ## sites' refusal REACHABLE, and an unreachable refusal is a comment.
    mhmNever
      ## The shipped default (Nim's zero value, and it is meant to be).
      ## Every monitored action is launched as
      ## ``<repro> internal io monitor --depfile <f> -- <argv>``. HM-6
      ## measured hosting as no faster at the default parallelism and
      ## 1.5-2.4x slower on cheap actions; see the "who hosts the monitor"
      ## block below ``preparedRunQuotaCommand``.
    mhmWhereSupported
      ## Host on the launch paths that CAN host and keep the CLI wrapper
      ## everywhere else. The wrapper is not a degraded form — it is the
      ## same io-mon code producing evidence nothing downstream can tell
      ## apart — so this fallback is silent on purpose.
    mhmRequired
      ## Host wherever hosting is requested, and FAIL an action whose
      ## launch path cannot host rather than falling back. Use it to
      ## measure or audit hosting without a launch path quietly opting out.
      ## On a platform where hosting is unsupported outright
      ## (``InProcessMonitorHostSupported``) this mode still takes the
      ## wrapper: that is a property of the host OS, not of a launch path
      ## disagreeing with the plan, and the wrapper monitors correctly.

  BuildEngineConfig* = object
    # Project-local scratch root: holds `runquota-results/*.json`,
    # `monitor-depfiles/*.iomon`, `dependency-evidence/*.rbar`, and per-build
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
    # the ``internal io monitor`` subcommand selector so the monitored argv
    # becomes ``repro internal io monitor --depfile … -- <cmd>`` rather than
    # invoking a standalone monitor binary. Empty (the default)
    # preserves the legacy ``<monitorCliPath> --depfile …`` shape used by tests
    # and any caller that still points at a dedicated monitor binary.
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
    rebuildClass*: RebuildClass
      ## ``Edge-Determinism-And-Soft-Rebuild.md`` §4.1–§4.3, i.e. which of
      ## ``--soft-rebuild`` / ``--rebuild-host-bound`` / ``--hard-rebuild``
      ## the invocation carries. ``rbNone`` (the zero value, and what every
      ## existing caller gets) is §4.4's unchanged default path.
      ##
      ## Deliberately SEPARATE from ``forceRebuild`` rather than folded into
      ## it. ``forceRebuild`` means "ignore the cache for every edge in this
      ## graph" and predates the determinism model; ``rbHard`` means the same
      ## thing arrived at through the class lattice and is additionally
      ## scopable by ``rebuildOnly``. Collapsing them would make
      ## ``--force-rebuild --only X`` silently mean ``--force-rebuild``.
    rebuildOnly*: seq[string]
      ## §4.5's ``--only <pattern>`` selector. EMPTY means "no selector",
      ## which selects every edge — so ``rebuildClass`` alone behaves exactly
      ## as §4.1 describes it unqualified. Matched against ``action.id`` and
      ## ``action.targetNames`` by ``matchesOnlySelector``.
    nowUnix*: int64
      ## Injected wall clock for retention decisions. 0 means read the real
      ## one. Exists so ``t_volatile_retention_expiry_is_a_miss`` can assert
      ## on an expiry boundary without sleeping through it; a retention test
      ## that slept would be both slow and flaky.
    buildEpoch*: string
      ## Identifies THIS ``repro build`` invocation, for §2.2's
      ## ``this-build`` retention clause. Empty means the engine has not been
      ## given one, under which a ``this-build`` entry is never a hit — the
      ## fail-closed direction.
    # When true, successful actions record input/output metadata for local
    # invalidation but do not synchronously hash and copy output payloads into
    # the local CAS. This is only appropriate for modes that rebuild missing
    # outputs instead of restoring them from cache.
    deferLocalOutputBlobs*: bool
    requireCompleteOutputEvidence*: bool
      ## S7 — the safety gate that makes the restore branch usable without
      ## also making it dangerous.
      ##
      ## Restoring an action's DECLARED outputs is equivalent to re-running
      ## it only when those outputs are the whole of its product. When they
      ## are not, a restore yields a tree that is silently missing whatever
      ## the action produced but did not declare — and it reports a cache
      ## HIT while doing so. ``repro_cli_support.nim`` records the precedent
      ## (see the ``develop --all`` note at its ``rebuildMissingOutputs``
      ## call site): an action whose real product was a clone TREE
      ## materialized only its receipt, and the chained step then failed
      ## against a directory nobody had created.
      ##
      ## With this set, an action whose observed writes are not accounted
      ## for by its declared outputs is published WITHOUT output payloads.
      ## A payload-less record cannot serve a restore — the lookup returns
      ## ``aclMissNoOutputPayload`` — so the action re-executes and produces
      ## its whole product again. The gate therefore fails CLOSED: the cost
      ## of a false negative is a rebuild, never an incomplete tree.
      ##
      ## "Accounted for" is deliberately narrow; see
      ## ``undeclaredSurvivingWrites``. Default ``false`` preserves every
      ## pre-S7 caller byte for byte. ``enableCachedOutputRestore`` is the
      ## one place that turns it on, together with the two knobs it guards.
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
    # OPT-IN, and ``mhmNever`` by default because measurement says so. Above
    # ``mhmNever`` the engine hosts io-mon's consumer itself on the launch
    # paths it spawns (today only the RunQuota-bypass path) instead of putting
    # a ``repro internal io monitor`` process in between. The mechanism works
    # and is exercised by the suite; what does not hold is the LATENCY case for
    # turning it on by default. See the "who hosts the monitor" block below
    # ``preparedRunQuotaCommand`` for the numbers and for what would have to
    # change before this becomes the default, and ``MonitorHostingMode`` for
    # what the three settings mean.
    #
    # IT IS A PRODUCT OPTION, NOT A TEST SEAM (In-Process-Monitor-Hosting P1,
    # option (b)). ``repro build --monitor-hosting=never|where-supported|
    # required`` and ``REPROBUILD_MONITOR_HOSTING`` set it; both go through
    # ``parseMonitorHostingMode`` below. The surface exists so the HM-6
    # verdict above can be RE-MEASURED on other hardware without writing a
    # harness — which is the only reason to move it off ``mhmNever``. Note
    # that only L1 (``--no-runquota``) can host, so the experiment is
    # ``--no-runquota --monitor-hosting=where-supported``.
    monitorHosting*: MonitorHostingMode
    evidenceScope*: EvidenceScope
      ## DA-1i — HOW MUCH OF WHAT THE MONITOR OBSERVES THIS BUILD WRITES DOWN,
      ## and, symmetrically, the narrowest capture this build will TRUST.
      ## ``repro build --evidence=full|reads-only`` sets it; the default is
      ## ``esFull``, which is also the enum's zero value, so every caller that
      ## predates this field keeps exactly its previous meaning with no special
      ## case anywhere.
      ##
      ## It does NOT change what the monitor observes and it is NOT a
      ## completeness input: a narrowed capture is the operator answering a
      ## narrower question honestly, not the monitor failing, and
      ## ``mcIncomplete`` means the latter. See io-mon's ``EvidenceScope``,
      ## which owns the vocabulary, the record-side predicate and the trust
      ## order; nothing about any of the three is restated here.
      ##
      ## IT IS DELIBERATELY NOT A CACHE-KEY COMPONENT. Trust here is a PARTIAL
      ## ORDER, not a partition — full evidence is strictly stronger than
      ## reads-only evidence, so a reads-only consumer must accept a full
      ## capture while a strict consumer rejects a narrowed one. Keying on the
      ## scope would make the two disjoint and block the useful direction: the
      ## careful teammate publishes and the fast teammate cannot consume.
      ## ``cacheInputPaths`` and the fingerprints therefore never read this
      ## field, and ``t_da1i_evidence_scope`` pins that they do not.
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
    binaryCacheIntermediateScope*: bool
      ## L3 PUBLISH-SCOPE. When ``true`` the target binary cache is an
      ## INTERMEDIATE cache: EVERY successful cacheable action's store
      ## outputs are published (not just the public-interface members
      ## tagged ``publishToBinaryCache``). When ``false`` (the default,
      ## and the safe default for a RELEASE cache) only tagged
      ## public-interface actions publish — untagged intermediate
      ## artefacts stay local. The CLI sets this from the effective
      ## cache scope (``REPRO_BINARY_CACHE_SCOPE`` / caches.conf
      ## ``scope``). Ignored when ``binaryCachePublisher == nil``.
    publishCachedResults*: bool
      ## When true, eligible binary-cache outputs are published after a
      ## validated local action-cache hit as well as after execution. This is
      ## opt-in so ordinary no-op builds never perform network writes. Cached
      ## metadata-only records are safe here because the engine requires the
      ## declared outputs to be materialized before invoking the publisher.
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

  EntropyCallerOrigin* = enum
    ## Windows-Build-Correctness M6 — where an observed entropy read came
    ## from, as far as the capture can tell. READ THE CASES LITERALLY; the
    ## middle one is narrower than its io-mon spelling suggests.
    ecoMainImage
      ## The Windows shim's `caller=program`. The return address of the call
      ## lay inside the main EXE image, so this is the monitored program's
      ## own code. This inference is SOUND in this direction.
    ecoOutsideMainImage
      ## The Windows shim's `caller=system` — and the one token in this
      ## whole design that must not be over-read. It means "the return
      ## address was not in the main EXE image", which covers ntdll's and
      ## the loader's startup baseline AND a bundled libcrypto, a compiler
      ## plugin, or a native extension under an interpreter host. The
      ## program's own randomness routinely lands here, and the shim's
      ## per-(source, origin) dedup collapses even the count, so there is
      ## no residual to notice it by. Treating this as "no program
      ## randomness" would silently grade an unblessed program
      ## deterministic. This engine therefore treats it EXACTLY like
      ## `ecoMainImage` for the cache decision; it is kept as a distinct
      ## case only so the diagnostic can say which one it saw.
    ecoUnattributed
      ## No `caller=` token at all. This is the macOS and Linux shape:
      ## those arms attribute at the SHIM and emit `mrNonDeterministic`
      ## only for the program's own use, so an absent token means "already
      ## filtered", not "unknown". Same consequence as the two above.

  EntropyObservation* = object
    source*: string
      ## The entry point io-mon named: `BCryptGenRandom`, `ProcessPrng`,
      ## `RtlGenRandom`, `CryptGenRandom`, `getentropy`, `arc4random`,
      ## `getrandom`, ...
    origin*: EntropyCallerOrigin

  EntropyObservability* = enum
    ## Whether the capture's own backend declaration says entropy COULD be
    ## observed. This exists because the absence of `mrNonDeterministic`
    ## records is only meaningful if the monitor was able to produce them:
    ## "the shim has no entropy hooks" and "the program read no entropy"
    ## are the same silence, and this milestone's whole subject is telling
    ## those two apart.
    entUnknown
      ## The capture carries no `mrBackendProfile` record, so it makes no
      ## claim either way. Deliberately the ZERO value, so a `PathSetEvidence`
      ## that was never folded starts here rather than at `entObserved`.
    entObserved
      ## A backend profile is present and lists `non-determinism` among its
      ## supported capabilities. Absence of entropy records is then real
      ## evidence of absence.
    entNotObserved
      ## A backend profile is present and does NOT list `non-determinism`,
      ## or the capture carries an explicit `mrCapabilityGap` for it. The
      ## monitor could not have seen an entropy read, so silence proves
      ## nothing.

  PathSetEvidence* = object
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    depfileInputs*: seq[string]
    monitorReads*: seq[string]
    monitorWrites*: seq[string]
    monitorProbes*: seq[string]
    monitorEnvReads*: seq[string]
      ## M10 — the NAMES of the environment variables the monitor observed
      ## this action reading (`mrEnvRead`, io-mon's observed-declared-input
      ## record; deduped per process by the shim and again here).
      ##
      ## NAMES, not paths: they are deliberately kept out of `monitorReads`
      ## and never run through `materialPath`. A variable is not a file, has
      ## no content to fingerprint and no directory to resolve against;
      ## `cacheEnvInputs` pairs each name with the VALUE the action saw and
      ## the action cache re-reads that value on the next lookup.
      ##
      ## This field is what makes io-mon's `mcapObservedEnv` mean anything to
      ## a consumer. Until it existed, `foldMonitorDepFileEvidence` dropped
      ## every `mrEnvRead` on its `else: discard` arm -- so all three
      ## platforms' shims recorded environment reads faithfully and the action
      ## cache ignored them, which is a false cache HIT whenever a build reads
      ## a variable whose value later changes.

    monitorDirectoryEnumerations*: seq[string]
      ## Directories the action ENUMERATED (`opendir`/`readdir`), as opposed
      ## to merely probed for existence. The monitor reports the two as
      ## distinct iomon record kinds (`mrDirectoryEnumerate` vs
      ## `mrPathProbe`) and the engine used to collapse them into
      ## `monitorProbes` one line after decoding them, which is where the
      ## distinction was lost.
      ##
      ## It matters because the two imply different invalidation rules.
      ## Existence is all a probe depends on, and a recorded directory
      ## compares as "does it still exist" (`fingerprintMetadata` zeroes
      ## size and mtime for `ffkDirectory`). An ENUMERATION depends on
      ## MEMBERSHIP: Incremental-Invalidation.md §"Validation Criteria"
      ## requires that "adding or removing a file in an enumerated directory
      ## invalidates the action", and existence cannot express that.
      ##
      ## Entries also remain in `monitorProbes`, so every existing consumer
      ## of that field keeps the exact set it had before.
    diagnostics*: seq[string]
    entropyObservations*: seq[EntropyObservation]
      ## M6 — one entry per distinct (source, origin) the capture recorded.
      ## io-mon already dedupes per source per caller-origin per process, so
      ## this stays small even for a build that draws randomness in a loop.
      ## Deliberately NOT folded into `monitorReads`: an entropy read is not
      ## a file whose content can be fingerprinted, which is exactly why it
      ## needs a policy rather than a cache-key entry.
    entropyObservability*: EntropyObservability
      ## M6 — what the capture's backend profile says about whether entropy
      ## reads are observable at all.

  MonitorEvidenceStatus* = enum
    ## M9.R.72.3 — spec-graded monitor-loss status. Implements the ladder
    ## from Failure-Semantics.md §"Monitoring Failures":
    ##   Level 0 (no loss):        publish action-cache record.
    ##   Level 1 (known scope):    invalidate affected path set;
    ##                             this session's cache publish MAY be skipped
    ##                             depending on the classifier.
    ##   Level 2 (unknown scope):  disable cache hits for the session;
    ##                             action still succeeds, no cache publish.
    ##   Level 3 (no monitoring):  fail the action.
    ##
    ## Before M9.R.72.3, all of Levels 1/2/3 were collapsed into Level 3 by
    ## the ``publishable = false`` sentinel in ``foldMonitorDepFileEvidence``
    ## and ``collectEvidence``. See recipes/reproos-image/run-evidence/m9r72/
    ## m9r72_phaseB_gap_enumeration.txt Gap I.
    mesComplete            ## Level 0
    mesKnownScopeLoss      ## Level 1 (currently treated as Level 2)
    mesUnknownScopeLoss    ## Level 2
    mesMonitorUnavailable  ## Level 3

  CacheIneligibilityReason = enum
    cirUnblessedEntropy = "unblessed-entropy"
    cirEntropyUnobservable = "entropy-unobservable"
    cirEntropyObservabilityUnknown = "entropy-observability-unknown"
    cirEmptyEvidence = "empty-evidence"
    cirMonitorLoss = "monitor-loss"
    cirMonitorFlushFailed = "monitor-flush-failed"

  MonitorEvidenceRequirement* = object
    ## WHAT THIS BUILD NEEDS A CAPTURE TO HAVE OBSERVED BEFORE IT WILL TRUST IT
    ## — the consumer side of DA-1i and DA-1j, in one object so a fold site
    ## cannot satisfy one axis and forget the other.
    ##
    ## Two axes, both io-mon's, and they are composed rather than conflated
    ## because they gate different things: ``interest`` is the KIND axis
    ## (DA-1j — which categories of event the capture was asked for) and
    ## ``evidenceScope`` is the RESULT axis (DA-1i — whether lookups that
    ## found nothing were written down). A capture is trustworthy iff it
    ## covers BOTH.
    ##
    ## NEITHER COMPARISON IS IMPLEMENTED HERE. ``observedInterestCovers`` and
    ## ``observedEvidenceScopeCovers`` live in io-mon beside the enums they
    ## order, and this module only supplies the required side and reports the
    ## refusal — see ``monitorScopeRefusal``. Restating either order here is
    ## how the two copies drift, and the direction that drift fails in is the
    ## cardinal one: accepting a narrowed capture as though it were complete.
    ##
    ## DO NOT DEFAULT-CONSTRUCT THIS. The zero value has ``interest == {}``,
    ## which ``observedInterestCovers`` accepts from ANY capture (a consumer
    ## that needs no category cannot be missing one) — fail-open, and exactly
    ## the wrong direction. Use ``FullMonitorEvidenceRequirement`` or build it
    ## from the action and the config with ``monitorEvidenceRequirement``.
    interest*: set[EventCategory]
    evidenceScope*: EvidenceScope

  EvidenceCollection = object
    evidence: PathSetEvidence
    publishable: bool
    disableCacheHits: bool
      ## Withhold this action's cache publication without failing the action.
      ## Entropy policy, empty evidence, unknown-scope monitor loss, and
      ## capture-flush failure can all set this flag. Only ``monitorStatus``
      ## governs session-wide loss invalidation; known-scope loss uses
      ## ``invalidatedPaths`` instead.
    cacheIneligibilityReasons: set[CacheIneligibilityReason]
      ## Diagnostic only; never used to decide cache acceptance/publication.
    invalidatedPaths: HashSet[string]
      ## M9.R.73.2 — per-Failure-Semantics.md-plus-Monitor-Loss-Path-Invalidation.md
      ## the certainly-invalidated + ambiguous path set for a Level 1
      ## (known-scope) monitor loss. Populated ONLY when
      ## ``monitorStatus == mesKnownScopeLoss``. Currently maps
      ## kill-before-flush to the action's own materialized declared
      ## outputs — the tight closed-form bound derived in the memo.
      ## The scheduler folds this into a session-wide accumulator and
      ## consults it on each downstream cache lookup: a lookup whose
      ## action's declared inputs (materialized to cwd) intersect the
      ## accumulator is skipped as ``cdMiss``. Empty for Levels 0/2/3.
    monitorStatus: MonitorEvidenceStatus
    engineSuppliedRootImage: string
      ## The one entry in ``evidence.monitorReads`` that no monitor reported:
      ## the action's own root image, reconstructed from its argv by
      ## ``executedToolImagePath`` and folded in because the launcher's exec
      ## precedes the shim's constructor and so produces no record. Empty when
      ## the image could not be identified without guessing, or when the
      ## action's policy is not a monitor-gathering one.
      ##
      ## Recorded because the zero-evidence guard in
      ## ``applyMonitorEvidenceStatus`` asks whether the MONITOR observed
      ## anything, and this path is not an observation — see
      ## ``executedToolImagePath``: "a reconstruction of the launcher's
      ## resolution, not an observation of the kernel's". Without this field
      ## the guard reads a set the engine itself seeded and can never fire.

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
    strongFingerprintHex*: string
      ## M17 (``ext_repro_action``): the ACTION-CACHE KEY the lookup
      ## compared against, hex-encoded, or "" when the lookup found no
      ## record at all and there was therefore no key to report. Recorded
      ## here rather than recomputed later because a cache lookup is the
      ## only moment at which it exists — and it is the quantity the
      ## compatibility key must be COARSER than, so a row carrying one
      ## without the other cannot show that the two diverge.
    cacheMissReason*: string
      ## Why the lookup did not hit, in the cache layer's own words
      ## ("no cache record for weak fingerprint", "input changed: <path>",
      ## …). Empty when there is nothing to say; stored as SQL NULL so
      ## "no reason recorded" stays distinguishable from an empty reason.
    outputBytes*: int64
      ## Total size of the action's declared outputs after it settled.

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

  EnvironmentInheritanceCensus* = object
    ## STAGE 2 — the denominator for the environment Reprobuild does not
    ## control.
    ##
    ## Reprobuild passes an action's `env` as an OVERLAY: the launcher
    ## layers those entries over the environment the build process
    ## itself inherited, so an action that declares nothing runs with the
    ## developer's or the CI runner's entire environment, and nothing
    ## records that it did. That is not a cache-key defect — closing it
    ## is a behaviour change that will break real edges — so this counts
    ## the population first and changes nothing about it.
    ##
    ## PER VARIABLE, "OVERLAY" MEANS LAST-WRITE-WINS, NOT MERGE. A
    ## variable the action declares REPLACES the inherited value; only a
    ## variable it does not declare is inherited. For `PATH` specifically
    ## that is spelled out in `prependPathDirsToArgvEnv` below, whose
    ## `getEnv("PATH")` fallback is reached only when no `PATH` entry is
    ## present. A blanket "declared entries overlay the environment, they
    ## do not replace it" reading of this census is what let three
    ## lowering sites emit `PATH=` — an empty `PATH` the action really
    ## ran with — for 1372 of 2753 edges. `emptyPathActions` below is the
    ## number that would have said so.
    ##
    ## This is deliberately a CENSUS and not a warning. PR #99's shm drop
    ## was invisible for the same reason: nobody had put a number on it.
    ## A number is what makes the next decision arguable.
    totalActions*: int
    declaringActions*: int
      ## Actions carrying at least one `NAME=VALUE` Reprobuild chose.
    passthroughActions*: int
      ## Actions naming at least one variable whose value is the host's.
      ## The name IS recorded (it is in the weak fingerprint); the value
      ## is not, by design.
    undeclaredActions*: int
      ## Actions that declare NOTHING at all.
      ##
      ## Read this as "declares nothing", NOT as "inherits nothing".
      ## EVERY process action inherits the build process environment,
      ## because `env` is an overlay on it rather than a replacement —
      ## so the population exposed to the host environment is
      ## `totalActions`, and this narrower count is only the subset that
      ## does not even overlay one variable on top.
      ##
      ## The distinction is the whole reason this is a census: on this
      ## repository's own graph `undeclaredActions` is 0 while
      ## `totalActions` is 1391, and a report that called the first
      ## number "inheriting" would have said the channel was closed
      ## when it is open for every edge.
    hermeticPathActions*: int
      ## Actions whose `PATH` is composed only of solved-graph tool
      ## directories and is keyed BY VALUE — the edges for which a
      ## prepended shadowing directory on the caller's `$PATH` is
      ## unreachable rather than merely uninvalidating.
    inheritedPathActions*: int
      ## Actions whose `PATH` still carries the caller's, declared
      ## PASSTHROUGH so the name is in the key and the value is not.
      ## These are the edges that declare no tool refs; for them the host
      ## `$PATH` remains an unkeyed input.
    emptyPathActions*: int
      ## THE ONE NUMBER THAT MUST BE ZERO. Actions carrying `PATH=` with
      ## an empty value, i.e. actions that run with no `PATH` at all
      ## because their declaration replaced the inherited one with
      ## nothing. Not a portability question and not a key question — a
      ## `findExe` inside such an action returns `""`, so a test that
      ## probes for its tools skips itself into a green, cacheable pass.
      ## Gated at zero by
      ## `libs/repro_build_engine/tests/t_declared_env_is_in_the_cache_key.nim`.

  BuildRunResult* = object
    results*: seq[ActionResult]
    trace*: seq[SchedulerTraceEvent]
    stats*: BuildStats
    environmentInheritance*: EnvironmentInheritanceCensus
      ## STAGE 2 census of this graph — see `EnvironmentInheritanceCensus`.
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
                                          cas: var CasStore;
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
    publishPrefix*: string
      ## Explicit public-interface root to package. Empty preserves the
      ## legacy first-declared-output fallback in the publisher.
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
    nimPathDirs*: seq[string]
      ## Cross-Repo-Source-Consumption SC-11 (§4.2a) — the PARALLEL Nim
      ## language channel. Each dir is a sibling Nim ``library``'s importable
      ## source root; the engine prepends a ``--path:<dir>`` compiler FLAG onto
      ## the consumer's ``nim c`` argv for each (see ``applyNimPathArgs``),
      ## rather than an env var as for the C/C++ channels above. The from-source
      ## resolver populates it per-ref; every other resolver leaves it empty
      ## (their imports resolve through nim.cfg / the standard layout).
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
    rpkMonitorHost
      ## In-Process-Monitor-Hosting HM-4. The engine is io-mon's HOST for this
      ## action: there is no ``repro internal io monitor`` child in between,
      ## and the monitored tree's root is a direct child of this process. The
      ## handle that owns it lives in the scheduler's ``MonitorHostPool`` at
      ## ``monitorSlot`` — see that type for why it is not a field here.

  RunningAction = object
    id: string
    pool: string
    poolUnits: uint32
    action: BuildAction
    processKind: RunningProcessKind
    process: Process
    directProcess: ReproDirectRunningProcess
    runQuotaProcess: ReproRunQuotaRunningProcess
    queuedRunQuotaProcess: ReproRunQuotaQueuedProcess
    inlineFailure: ActionResult
    resultPath: string
    monitorSlot: int
      ## HM-4. Index into the scheduler's ``MonitorHostPool`` for an
      ## ``rpkMonitorHost`` entry; ``-1`` for every other kind. An INDEX and
      ## not the ``MonitorHandle`` itself: a handle is non-copyable by
      ## construction (IoMon-Decomposed-Host-API DH-2 makes "two owners of one
      ## consumer" unrepresentable), and embedding one here would propagate
      ## that to ``RunningAction`` and to the scheduler's ``seq`` of them —
      ## where ``var item = running[i]`` and ``running.delete(i)`` are both
      ## copies.
    when defined(posix):
      processGroupPid: int
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

proc actionCacheIdentityError*(action: BuildAction): string =
  if action.cacheEntryIdentity.isSome:
    cacheEntryIdentityError(action.cacheEntryIdentity.get())
  else:
    ""

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

proc actionOutputPath(outputRoot, path: string): string =
  if path.isAbsolute or outputRoot.len == 0:
    path
  else:
    outputRoot / path

proc contentHashForActionBlob(blob: CasBlobRef): ContentHash =
  if blob.digest.algorithm != haBlake3_256:
    raise newException(CacheIntegrityError,
      "unsupported CAS digest algorithm for " & digestHex(blob.digest))
  toContentHash(blob.digest.bytes)

proc materializeActionCacheOutputs*(cas: CasStore;
                                    record: ActionResultRecord;
                                    outputRoot = "") =
  ## R11 action-cache restore helper shared by normal hits and hybrid-cutoff
  ## hits. It translates stable RBAR output records into Layer-1
  ## ``CasMaterialization`` requests; ``casMaterialize`` verifies every blob
  ## before touching destinations, so missing/corrupt later blobs cannot leave
  ## earlier outputs partially restored.
  if record.outputPayloadKind != opkCasBlobs:
    raise newException(CacheIntegrityError,
      "cache record does not contain output payloads")
  # Local-CAS-Hardlink-Materialization M2. Only a DIRECTORY output's payload
  # is needed in memory — ``materializeDirectorySnapshotPayload`` parses a
  # snapshot envelope rather than writing bytes to a path. Every other
  # output goes to ``casMaterialize``, which since M1 streams (and, where
  # the filesystem allows, links) each entry without ever holding it.
  #
  # Pre-reading all of them made the facade's O(1)-memory property stop at
  # this boundary: a restore of many large outputs still peaked at the sum
  # of them one layer up. The slots are indexed BY RECORD POSITION, which
  # is why this is a pre-sized ``newSeq`` with holes rather than a filtered
  # append — ``payloads[i]`` below is read with ``i`` from the record.
  #
  # Nothing is weakened by not reading them: ``casMaterialize`` runs its
  # own existence pre-pass over every entry before touching a destination,
  # and hash-verifies each staged result before committing any rename.
  var payloads = newSeq[seq[byte]](record.outputs.len)
  for i, output in record.outputs:
    if output.metadata.kind == ffkDirectory:
      payloads[i] = cas.casGet(contentHashForActionBlob(output.blob))
  var entries: seq[CasMaterialization] = @[]
  for output in record.outputs:
    if output.metadata.kind == ffkDirectory:
      continue
    entries.add(CasMaterialization(
      hash: contentHashForActionBlob(output.blob),
      destination: actionOutputPath(outputRoot, output.path),
      applyPermissions: true,
      permissions: output.permissions))
  cas.casMaterialize(entries)
  for i, output in record.outputs:
    if output.metadata.kind != ffkDirectory:
      continue
    materializeDirectorySnapshotPayload(payloads[i],
      actionOutputPath(outputRoot, output.path), output.permissions)

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

proc enableCachedOutputRestore*(config: var BuildEngineConfig) =
  ## S7 — select the CAS-restore configuration, as ONE call rather than as
  ## three fields a caller has to remember to set together.
  ##
  ## Restoring a deleted output from the local CAS needs all three, and
  ## setting two of them is worse than setting none: blobs stored with
  ## ``rebuildMissingOutputsOnCacheHit = true`` are disk spent on a branch
  ## that can never be taken (the state ``repro build`` was in before S7 —
  ## every published record ``opkMetadataOnly``), and the restore branch
  ## reached without ``requireCompleteOutputEvidence`` is the hazard the
  ## gate exists to stop. Grouping them means a caller cannot pick the
  ## unsafe two.
  ##
  ## * ``deferLocalOutputBlobs = false`` — store the output payloads in the
  ##   local CAS, so there is something to restore FROM;
  ## * ``rebuildMissingOutputsOnCacheHit = false`` — on a hit whose outputs
  ##   are missing, restore them instead of re-running the action;
  ## * ``requireCompleteOutputEvidence = true`` — but only for actions whose
  ##   observed writes their declared outputs actually account for.
  config.deferLocalOutputBlobs = false
  config.rebuildMissingOutputsOnCacheHit = false
  config.requireCompleteOutputEvidence = true

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

proc addCountedMetric(stats: var BuildStats; name: string; count: int;
                      totalUs: float) =
  ## One metric carrying BOTH a call count and the summed duration, so
  ## `totalUs / count` is a real per-call average. `addMetric` alone can only
  ## express one sample at a time.
  for metric in stats.metrics.mitems:
    if metric.name == name:
      metric.count += count
      metric.totalUs += totalUs
      return
  stats.metrics.add(BuildStatsMetric(name: name, count: count,
    totalUs: totalUs))

proc textBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFingerprintFromText*(text: string): ContentDigest =
  blake3DomainDigest(text.textBytes(), hdActionFingerprint)

proc nixStoreRoot(normalized: string): string =
  ## The `/nix/store/<hash>-<name>` root a forward-slashed path lies under.
  ##
  ## Matches the literal prefix and nothing else: `//nix/store`, `/nix/./store`
  ## and symlink aliases are not recognised. That is the conservative
  ## direction — an unrecognised root is elided by nobody and keyed as an
  ## ordinary recorded input — and it is the same literal
  ## `isImmutablePackageStoreRoot` matches.
  const prefix = "/nix/store/"
  if not normalized.startsWith(prefix):
    return ""
  let rest = normalized.substr(prefix.len)
  let slash = rest.find('/')
  if slash < 0:
    normalized
  else:
    prefix & rest[0 ..< slash]

proc isRealizationDirName(name: string): bool =
  ## Does this directory name carry a realization digest?
  ##
  ## `repro_local_store/prefix_paths.realizationDirName` composes
  ## `<version>-<first 16 hex of the BLAKE3 realization hash>`. Recognising
  ## the SHAPE rather than trusting the location is what bounds the damage a
  ## bogus `REPRO_STORE_ROOT` can do — see `reproStoreRootPath`.
  if name.len < 17 or name[name.len - 17] != '-':
    return false
  for i in name.len - 16 ..< name.len:
    if name[i] notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

proc reproStoreRootPath(): string =
  ## Reprobuild's OWN content-addressed store root, forward-slashed and with
  ## any trailing slash stripped, or `""` when it cannot be resolved.
  ##
  ## DERIVED FROM CONFIGURATION, through the same `resolveStoreRoot`
  ## precedence (`$REPRO_STORE_ROOT` > per-OS default) every other store
  ## consumer uses, rather than from a literal — a per-user cache root has no
  ## literal to hard-code.
  ##
  ## `isImmutablePackageStoreRoot` refuses to read the environment at all,
  ## and its reason does not carry over here — the difference is worth stating
  ## because the two look alike. There, the variable moved only the ELISION:
  ## a transient value made a directory exempt, the record was written with
  ## `mtimeNs = 0`, and clearing the variable did not recover because a 0 is
  ## never re-listed. The value poisoned a record permanently. Here the same
  ## value moves the elision AND the key, because `contentAddressedRoot` is
  ## the single function both sides read: change it and every affected edge
  ## fingerprints differently, so the old records are not found rather than
  ## wrongly served. The failure direction is a rebuild.
  ##
  ## What the env var still could do is nominate a MUTABLE tree as
  ## content-addressed within one consistent setting, and that is what
  ## `isRealizationDirName` bounds: the only thing elided under this root is a
  ## directory whose own name states a 16-hex realization digest.
  ##
  ## A ROOT OF `/` NAMES NOTHING AT ALL, which is stronger than the bound
  ## above and worth stating because a reader will look here for it. The
  ## trailing-slash strip maps `"/"` to `""`, and `""` is what
  ## `reproStoreRealizationRoot`'s `root.len == 0` arm refuses — so a store
  ## root of `/` does not exempt `/usr/…/prefixes/…/<version>-<digest>`
  ## either, even though that path IS named like a realization. There used to
  ## be an `if result == "/": result = ""` after the strip presented as the
  ## thing that made this true. It was unreachable: the strip removes EVERY
  ## trailing `/`, so `result` is already `""` by the time it is tested and no
  ## input can make that comparison fire. Deleted rather than kept with a
  ## corrected comment, because a branch no test can redden is one a later
  ## reader takes for load-bearing all over again.
  ##
  ## The `try` is not decoration: `resolveStoreRoot` RAISES a `StoreError`
  ## when it must fall back to the per-user default and neither
  ## `$XDG_CACHE_HOME` nor `$HOME` is set (`$LOCALAPPDATA`/`$USERPROFILE` on
  ## Windows). This function is on the path of every `argv[0]` and every
  ## `PATH` entry of every action, so letting that escape would turn an
  ## unset variable into a build failure. "Cannot resolve a store root" and
  ## "this path is under no store root" are the same answer here.
  try:
    result = resolveStoreRoot().replace('\\', '/').strip(
      leading = false, trailing = true, chars = {'/'})
  except CatchableError:
    return ""

proc reproStoreRealizationRoot(normalized: string): string =
  ## The `<store>/…/prefixes/<package>/<version>-<hash>` realization directory
  ## a forward-slashed path lies under, or `""`.
  ##
  ## The realization directory is the granularity at which the repro store is
  ## content-addressed: `prefixRelativePath` puts the digest in that segment's
  ## name and nowhere above it. `<store>/prefixes` is NOT a content-addressed
  ## root — packages come and go under it — so taking the immediate child of
  ## the store root the way the Nix arm does would elide a mutable tree.
  ##
  ## The `prefixes` segment is searched for rather than required at depth 1
  ## because the store nests one inside itself: tools live under
  ## `<store>/tool-store/prefixes/<package>/<version>-<hash>`.
  # Cheap rejection first. This runs once per `argv[0]` AND once per `PATH` /
  # `NODE_PATH` entry of every action, and resolving the store root allocates;
  # a path with no `prefixes` segment cannot match the layout below, so the
  # overwhelming majority of calls stop here without touching configuration.
  #
  # IT IS A PERFORMANCE GUARD AND NOTHING ELSE — no part of the soundness
  # argument rests on it, and deleting it cannot change an ANSWER. The loop
  # below only ever succeeds with `parts[i] == "prefixes"` and two segments
  # after it, and every such path contains the literal `/prefixes/` (the
  # split is taken after `root & "/"`, so even `i == 0` has a slash in front
  # of it). It is therefore the one conjunct in this chain that no mutation
  # can redden, and it is said here so the next reader does not spend the
  # effort discovering that twice. DA-11 grades every other arm below.
  if not normalized.contains("/prefixes/"):
    return ""
  let root = reproStoreRootPath()
  if root.len == 0 or not normalized.startsWith(root & "/"):
    return ""
  let parts = normalized.substr(root.len + 1).split('/')
  for i in 0 ..< parts.len:
    if parts[i] != "prefixes" or i + 2 >= parts.len:
      continue
    if not isRealizationDirName(parts[i + 2]):
      continue
    result = root
    for j in 0 .. i + 2:
      result.add('/')
      result.add(parts[j])
    return result

proc contentAddressedRoot*(path: string): string =
  ## The content-addressed root a path lies under, or `""`.
  ##
  ## THE ONE PLACE THE ENGINE DECIDES WHAT "CONTENT-ADDRESSED" MEANS, and the
  ## reason it is defined here rather than beside its first consumer: two
  ## opposite operations key off exactly this function and they are only sound
  ## as a PAIR.
  ##
  ## * `toolInputRoots` SUBTRACTS observed reads under such a root from the
  ##   action-cache input set (Dependency-Observation-Attribution.md §Class 1
  ##   — "the path names its own content, the store is immutable, and the
  ##   thing that put it in the key already covers every byte under it").
  ## * `keyedOnContentAddressedToolRoot` below is what makes the second half
  ##   of that sentence TRUE for the action's own image, instead of a claim
  ##   about some caller's fingerprint that the engine never checks.
  ##
  ## Both must read the same root for the same path or the subtraction drops
  ## something the key does not carry. Sharing the function is the structural
  ## form of "same root", and it is why a newly recognised root is added HERE
  ## rather than at either call site.
  ##
  ## ## Why the repro store had to join the Nix store, and why symmetry was
  ## ## not enough on its own
  ##
  ## While this recognised the literal `/nix/store/` and nothing else, a tool
  ## under reprobuild's own CAS store was elided by neither side and mixed by
  ## neither side. The two stayed symmetric, so rule 7 held and the ELISION
  ## hole stayed shut — but the tool then lived on as an ordinary recorded
  ## input, and MEASURED (2026-09-09) that is not enough:
  ##
  ## | | value |
  ## |---|---|
  ## | `weak(A) == weak(B)` for two byte-different repro-store bashes | `true` |
  ## | warm run after swapping `argv[0]` from A to B | **`cdHit`, `launched = false`** |
  ##
  ## Revalidation only re-checks the paths a record already NAMES. `<A>/bin/sh`
  ## still existed and still hashed the same, and nothing looked at the fact
  ## that `argv[0]` had moved to `<B>/bin/sh`. **A content-addressed store
  ## expresses a tool change as a NEW PATH, so recording the old path cannot
  ## catch it — only keying on it can.** Recognising the root is what puts it
  ## in the key (`keyedOnContentAddressedToolRoot`), and because both sides
  ## read this one function, the elision moved with it.
  let normalized = path.replace('\\', '/')
  result = nixStoreRoot(normalized)
  if result.len == 0:
    result = reproStoreRealizationRoot(normalized)

proc keyedOnGoverningLock*(fingerprint: ContentDigest;
                           governingLockIdentity: LockIdentity): ContentDigest =
  ## Named-Lock-Files §7 — mix the governing lock identity into an action's
  ## weak fingerprint.
  ##
  ## §7's requirement: "Every action for an edge, and for that edge's
  ## transitive dependency closure, MUST key on the identity of the lock file
  ## governing it (§6). An edge built under two lock files is two actions with
  ## two cache entries. **Cross-lock reuse of a cache entry is a correctness
  ## bug of the serve-a-stale-artifact class, not a performance regression.**"
  ##
  ## §7.1 records the design fork and its settlement: design **A**, key on the
  ## lock file, rather than **B**, partition the output namespace. Q-7 was
  ## settled on 2026-08-18 on a factual ground — B "requires every action's
  ## outputs to sit under a root Reprobuild controls, and
  ## `Foreign-Provisioner-Contracts.md` exists precisely because some package
  ## instances are materialised by provisioners Reprobuild does not own. **B
  ## is unsound here, not merely less convenient.**"
  ##
  ## ## Why this is applied in the CONSTRUCTOR and not at the call sites
  ##
  ## A's one real weakness is that it can be applied INCOMPLETELY, and §7.2 is
  ## blunt about the consequence: "a single edge whose fingerprint forgets the
  ## governing lock identity is a **silent** poisoning vector — it serves one
  ## lock file's artifacts to another and reports success." §7.2 closes that
  ## "by a **structural check**, not by care".
  ##
  ## So `action()` and `builtinAction()` apply this to whatever fingerprint
  ## they are handed — the default derived from the id, or one the caller
  ## computed itself. A caller cannot opt out by supplying its own
  ## fingerprint, which is the shape "by construction" has to take here: every
  ## `weakFingerprint =` argument in the tree is a caller who computed a
  ## fingerprint over what its edge DOES, and none of them knows about lock
  ## files.
  ##
  ## ## Why it is not simply `hash(text & identity)`
  ##
  ## The mix is over a length-framed two-field rendering, so no two distinct
  ## (fingerprint, identity) pairs can collide by concatenation ambiguity.
  ## §1.3 makes that a hard prerequisite for anything that becomes a key: a
  ## non-canonical rendering "does not fail loudly. It produces two different
  ## keys for one lock file — a silent cache miss and a duplicated build", and
  ## the mirror-image collision serves one lock file's artifacts to another.
  ##
  ## ## When this MOVED the fingerprints
  ##
  ## NLF-M4 landed the carrier field and the whole-graph audit but deliberately
  ## kept the identity OUT of the key, because NLF-STAT-4 required byte-
  ## identical fingerprints across that milestone. NLF-M7 is where §7's keying
  ## becomes effective, and the NLF-STAT-4 baseline fixture moves here — once,
  ## uniformly, for every edge, because every edge acquires the same new
  ## component. What does NOT move is the RELATIVE structure: two edges under
  ## one lock file still key identically, which is NLF-STAT-3.
  var framed = "action-fingerprint\x1e"
  let base = toHex(fingerprint.bytes)
  framed.add($base.len & "\x1f" & base & "\x1e")
  let lock = string(governingLockIdentity)
  framed.add($lock.len & "\x1f" & lock & "\x1e")
  blake3DomainDigest(framed.textBytes(), hdActionFingerprint)

proc actionEnvironmentKeyText*(env: openArray[string];
                               envPassthrough: openArray[string]): string =
  ## The canonical rendering of an action's ENVIRONMENT DECLARATION, in
  ## BuildXL's two classes.
  ##
  ## `Public/Src/Pips/Dll/Graph/PipFingerprinter.cs:360-375` is the whole
  ## of BuildXL's environment fingerprinting, and it is a two-branch
  ## order-independent collection over `Process.EnvironmentVariables`:
  ##
  ## ```csharp
  ## if (env.IsPassThrough)
  ##     fCollection.Add(env.Name.ToString(...), "Pass-through");
  ## else
  ##     AddPipData(fCollection, env.Name.ToString(...), env.Value);
  ## ```
  ##
  ## so — declared contributes name AND value, passthrough contributes
  ## name and a fixed marker. `Documentation/Wiki/Advanced-Features/
  ## Build-Parameters-(Environment-variables).md:30-39` states the
  ## consequence: for a passthrough variable "value is not tracked;
  ## addition or removal is considered for caching", and that holds
  ## "when the value of passthrough variables is explicitly set in
  ## DScript to something other than what is in bxl.exe's environment.
  ## The effect is the same in that the value will not be tracked."
  ## `BaselineTests.cs:1696-1741` (`PerVariablePassThroughIsHonored`) is
  ## the executable proof: same declared value, cache HIT iff passthrough.
  ##
  ## ## Where this rendering DIVERGES from BuildXL, deliberately
  ##
  ## BuildXL puts the literal string `"Pass-through"` in the value slot,
  ## with no separate type tag. A DECLARED variable whose value happens
  ## to render to exactly `Pass-through` therefore produces a
  ## byte-identical contribution to a PASSTHROUGH variable of the same
  ## name — two different actions, one key. That is a latent
  ## serve-a-stale-artifact hole, and there is no reason to inherit it.
  ## Here the class is its own framed field, so no value can impersonate
  ## a class.
  ##
  ## BuildXL also gets order-independence by XOR-ing per-element hashes
  ## and appends the element count to keep the function injective. A
  ## sorted, length-framed rendering gets both properties directly and
  ## stays readable, which matters because this text is what an operator
  ## diffs when two hosts disagree about a key.
  ##
  ## ## Canonicalisation
  ##
  ## Duplicate declarations resolve LAST-WRITE-WINS, because that is what
  ## the spawn-time overlay does (`prependPathDirsToArgvEnv` documents
  ## the same rule: "Last-write-wins matches the StringTableRef merge").
  ## A key that disagreed with the spawn would be keying on an
  ## environment the action never experiences.
  ##
  ## Entries with no `=` or an empty name carry no environment and are
  ## dropped; they cannot become part of a key by accident.
  ##
  ## Names are compared CASE-SENSITIVELY here, while Windows environment
  ## variables are case-insensitive and the spawn path's `PATH` collapse
  ## uses `cmpIgnoreCase`. On Windows, `Path=x` and `PATH=x` therefore
  ## render as two records where the process sees one variable. That is
  ## an OVER-invalidation (two keys for one environment: a redundant
  ## rebuild) and never a false hit, so it is safe in the direction that
  ## matters. Folding case here would have to match the spawn path's
  ## collapse exactly or it would introduce the opposite error, which is
  ## the unsafe one.
  ##
  ## ## This procedure reads NOTHING ambient, and that is load-bearing
  ##
  ## It is a pure function of its arguments. PR #96's `NIX_STORE_DIR`
  ## defect was a transient ambient value entering a cache record
  ## permanently because a key computation called `getEnv`. No `getEnv`
  ## may appear here or in `keyedOnActionEnvironment` below; a test
  ## asserts on the source text of both to keep it that way.
  const US = "\x1f"
  const RS = "\x1e"
  var declared = initOrderedTable[string, string]()
  for entry in env:
    let eq = entry.find('=')
    if eq <= 0:
      continue
    declared[entry[0 ..< eq]] = entry[eq + 1 .. ^1]
  var passthrough = initHashSet[string]()
  for name in envPassthrough:
    if name.len > 0:
      passthrough.incl(name)
  var names: seq[string] = @[]
  for name in declared.keys:
    names.add(name)
  for name in passthrough:
    if not declared.hasKey(name):
      names.add(name)
  names.sort()
  var records: seq[string] = @[]
  for name in names:
    if passthrough.contains(name):
      # The declared value, if any, is deliberately NOT rendered.
      records.add($name.len & US & name & US & "passthrough" & US & "0" & US)
    else:
      let value = declared[name]
      records.add($name.len & US & name & US & "declared" & US &
        $value.len & US & value)
  result = records.join(RS)

proc keyedOnActionEnvironment*(fingerprint: ContentDigest;
                               env: openArray[string];
                               envPassthrough: openArray[string]):
    ContentDigest =
  ## Mix an action's environment DECLARATION into its weak fingerprint.
  ##
  ## Applied in `action()` for the same reason `keyedOnGoverningLock` is
  ## — "by a structural check, not by care". Every `weakFingerprint =`
  ## argument in the tree is a caller who computed a fingerprint over
  ## what its edge DOES, and none of them knows that the engine will
  ## hand the process an environment. A call site that had to remember
  ## to mix the environment in is a call site that will eventually
  ## forget, and forgetting is silent: it serves one environment's
  ## result to another and reports success.
  ##
  ## ## The empty declaration is the IDENTITY, and that is required
  ##
  ## An edge that declares no environment and no passthrough must
  ## fingerprint to exactly what it fingerprinted before this existed.
  ## Otherwise landing this invalidates every action-cache record ever
  ## written — a correctness fix that ships as a total cache wipe. The
  ## early return is the property; a test pins it.
  if env.len == 0 and envPassthrough.len == 0:
    return fingerprint
  let text = actionEnvironmentKeyText(env, envPassthrough)
  if text.len == 0:
    return fingerprint
  # Length-framed two-field mix, same shape and rationale as
  # `keyedOnGoverningLock`: no two distinct (fingerprint, environment)
  # pairs may collide by concatenation ambiguity.
  var framed = "action-environment\x1e"
  let base = toHex(fingerprint.bytes)
  framed.add($base.len & "\x1f" & base & "\x1e")
  framed.add($text.len & "\x1f" & text & "\x1e")
  blake3DomainDigest(framed.textBytes(), hdActionFingerprint)

proc monitorPayloadArgIndex(argv: openArray[string]): int

proc executedImageArgvIndex*(argv: openArray[string]): int =
  ## Index in `argv` of the image the ACTION ITSELF executes, or `-1` when
  ## that cannot be told without guessing.
  ##
  ## ONE ANSWER FOR THREE QUESTIONS, and they used to have two. An action's
  ## argv is not always the recipe's argv: on the wrapped monitor path
  ## `monitoredAction` rewrites it to
  ## `<repro> internal io monitor --depfile <f> -- <argv>`, so `argv[0]`
  ## becomes the ENGINE'S OWN BINARY and the action's real tool moves to the
  ## payload. On the in-process-hosted path it is left alone. Which one a
  ## given action carries is decided by the launch site, not by the action.
  ##
  ## `executedToolImagePath` already knew this. `toolInputRoots` did not, and
  ## MEASURED (2026-09-09) on a real monitored build the disagreement is
  ## visible in both directions:
  ##
  ## * it subtracted nothing for the action's real store-resolved tool,
  ##   because it was reading the wrapper's `argv[0]`; and
  ## * where the engine's own binary is itself a store path — an installed
  ##   reprobuild — it subtracted THAT root instead, which is an elision of
  ##   reads under a root that is in no key at all, since the wrapper argv is
  ##   composed long after the weak fingerprint was computed.
  ##
  ## Both disappear once the subtraction, the key mix and the launcher's
  ## root-image fold ask this one function which argument is the tool.
  ##
  ## Returns `-1` for a monitor-shaped argv whose payload cannot be located,
  ## rather than falling back to index 0. Index 0 there is the launcher, not
  ## the action, and naming the wrong image is worse than naming none: it
  ## would key an edge on the engine binary and elide the reads of whatever
  ## else lives beside it.
  if argv.len == 0:
    return -1
  let payloadIndex = monitorPayloadArgIndex(argv)
  if payloadIndex >= 0:
    return payloadIndex
  if argv.len >= 4 and argv[1] == "internal" and argv[2] == "io" and
      argv[3] == "monitor":
    return -1
  0

proc keyedOnContentAddressedToolRoot*(fingerprint: ContentDigest;
                                     argv: openArray[string]): ContentDigest =
  ## Mix the CONTENT-ADDRESSED ROOT of the image this action executes into its
  ## weak fingerprint — the derived half of the class-1 elision `cacheInputPaths`
  ## performs, and the reason that elision is sound.
  ##
  ## ## The claim this exists to make true
  ##
  ## `toolInputRoots` drops every observed read under
  ## `contentAddressedRoot(argv[0])`
  ## from the action-cache input set. Dependency-Observation-Attribution.md
  ## §Class 1 permits that ONLY on a two-part argument: the root is
  ## content-addressed (the path names its content) AND "its identity is in
  ## the key". The first half is a property of the store. **The second half was
  ## an assumption about whatever fingerprint the caller happened to compute,
  ## and nothing checked it.**
  ##
  ## MEASURED (2026-09-09), engine-default fingerprint
  ## (`weakFingerprintFromText(id)`), monitored cacheable edge, `argv[0]` a
  ## `/nix/store/…-bash-5.2p26/bin/sh`, one observed workspace read:
  ##
  ## | step | decision |
  ## |---|---|
  ## | run 1, tool A | published, `record.inputs = [observed.txt]` |
  ## | warm, tool A | `cdHit` (control) |
  ## | `argv[0]` -> `/nix/store/…-bash-5.3p9/bin/sh` | **`cdHit`, `launched=false`** |
  ##
  ## A DIFFERENT BINARY, and the record published against the first one was
  ## served without running anything. `weak(A) == weak(B)` was `true`: the
  ## engine's default fingerprint is the action id, the lock identity and the
  ## environment declaration, and argv appears in none of them. The strong
  ## fingerprint is `weak + inputs + envInputs` (`computeStrongFingerprint`),
  ## and the tool was subtracted out of `inputs`. So for a store-resolved tool
  ## the executed binary's identity was in NO key at all, and `947c50fc`'s
  ## stated goal — "make the binary an action executes one of its cache
  ## inputs" — was unmet for exactly the tools every NixOS build uses.
  ##
  ## The same measurement with argv mixed into the caller's fingerprint gives
  ## `cdMiss, launched=true`. So the elision is sound precisely when the key
  ## covers `argv[0]`, and the fix is to make that true by construction rather
  ## than to hope each caller arranged it.
  ##
  ## ## The ROOT **and** the path within it, and why the path is not a digest
  ##
  ## The root, because the root is the granularity the subtraction works at:
  ## `cacheInputPaths` drops everything under `contentAddressedRoot(argv[0])`,
  ## so the key has to carry that whole root or the two sets do not line up
  ## (Dependency-Observation-Attribution.md rule 7).
  ##
  ## The path as WELL, because rule 7 bounds the key from BELOW and nothing
  ## bounds it from above. Keying on MORE than the elision drops is the safe
  ## direction — every path the subtraction removed is still covered by the
  ## root component — whereas keying on LESS is the unsound one. The first
  ## version of this mixed the root ALONE and reasoned that splitting the two
  ## programs of one derivation "would key on something the elision does not
  ## bound", which has the argument backwards. MEASURED (2026-09-09), one
  ## coreutils derivation, `argv[0]` swapped `…/bin/cat` -> `…/bin/head`:
  ## **`cdHit`, `launched = false`**. One derivation, two programs, one cache
  ## entry, and the second program served the first one's result.
  ##
  ## The path rather than a digest of the bytes, because for a
  ## content-addressed root the path IS the digest — that is the entire
  ## premise of class 1, and re-hashing the closure would cost a store walk to
  ## re-derive what the name already states. Where the premise does not hold
  ## the mix does not happen: `contentAddressedRoot` returns `""` for every
  ## path outside a recognised store, `toolInputRoots` subtracts nothing
  ## there, and the image stays a content-fingerprinted recorded input via
  ## `collectEvidence`'s root-image fold — which is the case
  ## `t_executed_binary_is_a_recorded_input` has always pinned.
  ##
  ## ## Applied in the CONSTRUCTOR, for `keyedOnGoverningLock`'s reason
  ##
  ## "By a structural check, not by care." Every `weakFingerprint =` argument
  ## in the tree is a caller who computed a fingerprint over what its edge
  ## does; some of them (`weakFingerprintForProfileBuildAction`, the typed-tool
  ## DSL site's `profile.profileFingerprint`) already cover the tool and some
  ## (`weakFingerprintFromText(id)`, the inline-exec site's id + payload) do
  ## not. A subtraction whose soundness depends on which caller you came
  ## through is a subtraction that is unsound somewhere, and the engine cannot
  ## tell the two apart by inspecting an opaque digest.
  ##
  ## ## The empty case is the IDENTITY, and that is required
  ##
  ## An edge whose `argv[0]` is not under a content-addressed root must
  ## fingerprint to exactly what it fingerprinted before this existed —
  ## otherwise a correctness fix ships as a total cache wipe for every user
  ## who does not build on NixOS. NLF-STAT-4's baseline corpus uses
  ## `/usr/bin/cc`, so those recorded bytes do not move; the test pins it.
  ##
  ## ## Where the OTHER `toolInputRoots` roots come from, and why they need no
  ## equivalent
  ##
  ## `toolInputRoots` also collects store roots out of `PATH` and `NODE_PATH`
  ## — but it reads them from `action.env`, the edge's own DECLARED
  ## environment, and `keyedOnActionEnvironment` already mixes every declared
  ## name AND value into this same fingerprint. A passthrough `PATH`
  ## contributes no value to the key, and `envValue` cannot see it either, so
  ## it yields no root to subtract. Those two halves line up by construction
  ## already. `argv[0]` was the one that did not.
  ## ## `-1` is an ANSWER here, not an error
  ##
  ## `executedImageArgvIndex` returns `-1` for an argv whose executed image
  ## cannot be told without guessing, and this is one of the three callers it
  ## says that to. Indexing `argv` with it would raise inside the action
  ## CONSTRUCTOR — every edge in the graph goes through here — so the guard is
  ## the difference between "no image to mix" and a crash while building the
  ## graph. There is no `image.len > 0` test between it and the `root.len`
  ## test below: `contentAddressedRoot("")` is `""`, so that test decided
  ## nothing the next one does not, and a conjunct no mutation can redden is
  ## one a later reader mistakes for load-bearing.
  let imageIndex = executedImageArgvIndex(argv)
  let image =
    if imageIndex >= 0: argv[imageIndex].replace('\\', '/') else: ""
  let root = contentAddressedRoot(image)
  if root.len == 0:
    return fingerprint
  # Length-framed mix, same shape and rationale as `keyedOnGoverningLock` and
  # `keyedOnActionEnvironment`: no two distinct (fingerprint, root, image)
  # triples may collide by concatenation ambiguity.
  var framed = "action-tool-root\x1e"
  let base = toHex(fingerprint.bytes)
  framed.add($base.len & "\x1f" & base & "\x1e")
  framed.add($root.len & "\x1f" & root & "\x1e")
  framed.add($image.len & "\x1f" & image & "\x1e")
  blake3DomainDigest(framed.textBytes(), hdActionFingerprint)

proc weakFingerprintFor*(id: string;
                         governingLockIdentity: LockIdentity): ContentDigest =
  ## The fingerprint `action()` / `builtinAction()` would compute for an edge
  ## with this id under this lock. For the call sites that construct a
  ## `BuildAction` object literally rather than through a constructor — §7.2's
  ## `{.requiresInit.}` field reaches those, but the constructor's mixing
  ## cannot, so they compose it here instead of re-deriving it.
  keyedOnGoverningLock(weakFingerprintFromText(id), governingLockIdentity)

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
             nonDeterminism = ndpUnblessed;
             nonDeterminismJustification = "";
             determinism = none(EdgeDeterminism);
             cacheRetention = forever();
             env: openArray[string] = [];
             envPassthrough: openArray[string] = [];
             requiresElevation = false;
             governingLockIdentity: LockIdentity): BuildAction =
  ## Named-Lock-Files §7.2: `governingLockIdentity` has NO DEFAULT, and that
  ## is the point. "An action constructed without a governing lock identity is
  ## a build-time error, not a default." A default here would be the
  ## convention §7.2 explicitly refuses to rely on.
  let effectiveDependencyPolicy =
    if depfile.len > 0 and monitorDepfile.len == 0 and
        dependencyPolicy.kind == dgAutomaticMonitor:
      legacyDepfileGatheringPolicy(depfile,
        dependencyPolicy.ignoredInputPrefixes)
    else:
      dependencyPolicy
  BuildAction(
    governingLockIdentity: governingLockIdentity,
    kind: bakProcess,
    id: id,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    argv: @argv,
    cwd: cwd,
    env: @env,
    envPassthrough: @envPassthrough,
    pool: pool,
    poolUnits: poolUnits,
    cpuMilli: cpuMilli,
    memoryBytes: memoryBytes,
    commandStatsId: commandStatsId,
    cacheable: cacheable,
    # The environment mix is INSIDE the lock mix, so the two compose in
    # one fixed order for every edge in the tree. An edge that declares
    # no environment is unaffected — `keyedOnActionEnvironment` is the
    # identity on the empty declaration — so this does not move any
    # fingerprint that existed before it.
    #
    # The tool-root mix sits between them, and it is the same kind of
    # thing: an engine-derived component no call site knows to supply.
    # It is the IDENTITY unless `argv[0]` lies under a content-addressed
    # root, which is exactly the condition under which `cacheInputPaths`
    # subtracts that root's contents out of the key — see
    # `keyedOnContentAddressedToolRoot` for the measurement that showed
    # the two halves had never been connected.
    weakFingerprint: keyedOnGoverningLock(
      keyedOnContentAddressedToolRoot(
        keyedOnActionEnvironment(weakFingerprint, env, envPassthrough),
        argv),
      governingLockIdentity),
    actionCachePolicy: actionCachePolicy,
    depfile: depfile,
    dynamicDepsFile: dynamicDepsFile,
    monitorDepfile: monitorDepfile,
    dependencyPolicy: effectiveDependencyPolicy,
    nonDeterminism: nonDeterminism,
    nonDeterminismJustification: nonDeterminismJustification,
    # Edge-Determinism-And-Soft-Rebuild.md §2. `none` + `forever()` is the
    # unlabelled default: every existing call site keeps the exact behaviour
    # it had, writes no determinism sidecar, and takes the same cache path.
    # The `weakFingerprint` above deliberately does NOT mix either field in —
    # §10.2: "The class is NOT part of the cache key (so a relabel from
    # `weak` to `strong` does not invalidate existing entries)."
    determinism: determinism,
    cacheRetention: cacheRetention,
    requiresElevation: requiresElevation)

proc builtinAction*(kind: BuildActionKind; id: string; cwd = "";
                    deps: openArray[string] = [];
                    inputs: openArray[string] = [];
                    outputs: openArray[string] = [];
                    commandStatsId = ""; cacheable = true;
                    weakFingerprint = weakFingerprintFromText(id);
                    actionCachePolicy = ffpTimestamp;
                    text = ""; entries: openArray[string] = [];
                    networkMode = netDenied;
                    netDestinations: openArray[string] = [];
                    governingLockIdentity: LockIdentity): BuildAction =
  ## ``networkMode`` defaults to ``netDenied`` and ``netDestinations`` to the
  ## empty set — Sandbox-And-Monitoring.md §"The Network Dimension" rule 1,
  ## "silence is denial". A caller that wants a fetch edge must say so at the
  ## call site, which is what makes the non-hermeticity greppable.
  if kind == bakProcess:
    raise newException(BuildEngineError, "builtinAction requires a built-in action kind")
  BuildAction(
    governingLockIdentity: governingLockIdentity,
    kind: kind,
    id: id,
    deps: @deps,
    inputs: @inputs,
    outputs: @outputs,
    cwd: cwd,
    commandStatsId: commandStatsId,
    cacheable: cacheable,
    weakFingerprint: keyedOnGoverningLock(weakFingerprint,
      governingLockIdentity),
    actionCachePolicy: actionCachePolicy,
    dependencyPolicy: automaticMonitorGatheringPolicy(),
    builtinText: text,
    builtinEntries: @entries,
    networkMode: networkMode,
    netDestinations: @netDestinations)

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

proc traceCacheIneligibility(result: var BuildRunResult; actionId: string;
                            collection: EvidenceCollection) =
  var reasons: seq[string] = @[]
  for reason in collection.cacheIneligibilityReasons:
    reasons.add($reason)
  if reasons.len == 0:
    reasons.add("unspecified")
  # Keep the existing event for actual loss, not every cache refusal.
  let event =
    if cirMonitorLoss in collection.cacheIneligibilityReasons:
      "cache-skip-monitor-loss"
    else:
      "cache-skip-ineligible"
  result.trace(actionId, event,
    "action-cache publication skipped; reasons=" & reasons.join(","))

proc raiseEngine(message: string) {.noreturn.} =
  raise newException(BuildEngineError, message)

proc normalizeWriteRoot(p: string): string =
  ## M9.R.75 — canonical form for a declared write root path used by
  ## the R7 pairwise-intersection pass. Normalises separators to ``/``
  ## and strips a trailing ``/`` so ``"$b/build"`` and ``"$b/build/"``
  ## compare equal. Empty in → empty out; empty entries are ignored
  ## by the caller.
  if p.len == 0:
    return ""
  var s = p.replace("\\", "/")
  while s.len > 1 and s[^1] == '/':
    s.setLen(s.len - 1)
  s

proc writeRootsOverlap(a, b: string): bool =
  ## M9.R.75 — R7 intersection predicate. Two declared write roots
  ## OVERLAP when they are the same path OR one is a proper directory
  ## prefix of the other (with a ``/`` boundary so ``"$b/build"`` is
  ## not treated as a prefix of ``"$b/buildkit"``).
  if a.len == 0 or b.len == 0:
    return false
  if a == b:
    return true
  if a.len < b.len:
    return b.startsWith(a & "/")
  return a.startsWith(b & "/")

proc pathAtOrUnderRoot(path, root: string): bool =
  ## Directional containment predicate for R6: ``path`` must be equal
  ## to ``root`` or be a descendant of it. A write to a parent of the
  ## read-only root is not a source write.
  if path.len == 0 or root.len == 0:
    return false
  path == root or path.startsWith(root & "/")

proc detectSourceWrites*(readOnlyRoots, monitorWrites: openArray[string]):
    seq[tuple[write: string; root: string]] =
  ## M9.R.75 — R6 (source-write reject) detection helper. Given the
  ## action's declared ``readOnlyRoots`` (nominally-read-only scopes)
  ## and the observed ``monitorWrites`` (io-mon-recorded write paths),
  ## return every ``(write, root)`` pair where the write landed at or
  ## under a read-only root.
  ##
  ## Spec cite: Filesystem-Policy-And-Observed-Inputs.md §"Source
  ## Rewrites" (lines 264-278): "source rewrites are errors" is the
  ## shipping default; the caller is responsible for turning any
  ## non-empty return into a failure.
  ##
  ## Exported so unit tests can grade the detection logic against
  ## synthetic evidence without depending on the full
  ## ``collectEvidence`` scaffold.
  var normalizedRoots: seq[string] = @[]
  for raw in readOnlyRoots:
    let n = normalizeWriteRoot(raw)
    if n.len > 0:
      normalizedRoots.add(n)
  if normalizedRoots.len == 0:
    return
  for rawWrite in monitorWrites:
    let write = normalizeWriteRoot(rawWrite)
    if write.len == 0:
      continue
    for root in normalizedRoots:
      if pathAtOrUnderRoot(write, root):
        result.add((write: write, root: root))
        break

type
  LockIdentityAuditFinding* = object
    ## One edge KIND that failed the §7.2 whole-graph audit, plus the action
    ## ids that failed under it.
    ##
    ## Grouped by kind on purpose. NLF-ID-6's mutation is "remove the field
    ## from one edge kind's construction path; the audit must fail naming that
    ## kind", and a finding list keyed on individual action ids would report
    ## the symptom (fifty nameless actions) instead of the cause (one
    ## construction path). The corpus is explicit about why the whole-graph
    ## shape matters: this failure "is about the one nobody thought to
    ## exercise", so "assert over the whole graph, so a newly added edge kind
    ## cannot quietly opt out".
    kind*: BuildActionKind
    actionIds*: seq[string]

proc auditGoverningLockIdentity*(g: BuildGraph): seq[LockIdentityAuditFinding] =
  ## Named-Lock-Files §7.2's whole-graph fingerprint audit: "A fingerprint
  ## audit enumerates every action in a built graph and asserts the field is
  ## present and non-empty."
  ##
  ## Returns one finding per offending edge KIND, in enum order, with the
  ## offending action ids in graph order. An empty result means the graph
  ## passes.
  ##
  ## "Present and non-empty" is checked as `isValid` — a well-formed
  ## self-describing multihash — rather than as `len > 0`. A whitespace string
  ## or a truncated hex fragment is "non-empty" and would pass a length check
  ## while being just as unusable as a key; §7.2 asks for "a real check from a
  ## lint", and a check that accepts `" "` is the lint.
  var byKind: array[BuildActionKind, seq[string]]
  for action in g.actions:
    if not action.governingLockIdentity.isValid():
      byKind[action.kind].add(action.id)
  result = @[]
  for kind in BuildActionKind:
    if byKind[kind].len > 0:
      result.add(LockIdentityAuditFinding(kind: kind, actionIds: byKind[kind]))

proc formatLockIdentityAudit*(findings: seq[LockIdentityAuditFinding]): string =
  ## The audit's diagnostic. Names the edge KIND first, because that is what a
  ## reader has to go and fix, then up to five action ids as evidence.
  if findings.len == 0:
    return ""
  var total = 0
  for f in findings: total += f.actionIds.len
  result = "governing lock identity missing on " & $total &
    " action(s) — Named-Lock-Files.md §7.2 requires every action fingerprint " &
    "to carry the identity of its governing lock file"
  for f in findings:
    result.add("\n  edge kind " & $f.kind & ": " & $f.actionIds.len &
      " action(s) without a governing lock identity")
    for i, id in f.actionIds:
      if i >= 5:
        result.add("\n      … and " & $(f.actionIds.len - 5) & " more")
        break
      result.add("\n      " & id)

# ---------------------------------------------------------------------------
# Sandbox-And-Monitoring.md §"The Network Dimension" — the graph-level audit.
# ---------------------------------------------------------------------------

const NetworkFetchCapableKinds* = {bakMetadataFetch, bakBinaryCacheSubstitute,
                                   bakForeignProvision}
  ## The edge kinds that may carry ``netFetch``.
  ##
  ## The amendment's closing paragraph asks for exactly this: the
  ## network-touching actions that already exist — ``bakBinaryCacheSubstitute``
  ## (the `fetch:`-block / substituter shape) and ``bakForeignProvision``
  ## (weak-fingerprinted, revalidated against self-reported observed inputs) —
  ## "should be classified under this dimension rather than each carrying an
  ## implicit per-kind exemption", and "the metadata-fetch edges of
  ## `Named-Lock-Files.md` §5.6 are `netFetch` edges by construction".
  ##
  ## An allowlist rather than a free-for-all because rule 3 is a *structural*
  ## claim — "a non-hermetic edge is never a silent input to a build that
  ## believes itself pinned" — and a compile edge that could quietly be marked
  ## ``netFetch`` would make that claim unenforceable.

type
  NetworkPolicyAuditFinding* = object
    ## One action whose network policy is internally inconsistent, plus the
    ## reason. Keyed per ACTION rather than per kind (unlike the lock-identity
    ## audit) because the three failures below are authoring mistakes at a call
    ## site, not a construction path that forgot a field.
    actionId*: string
    kind*: BuildActionKind
    reason*: string

proc auditNetworkPolicy*(g: BuildGraph): seq[NetworkPolicyAuditFinding] =
  ## Assert the network dimension holds together across a whole graph.
  ##
  ## Three checks, one per way the dimension can be stated incoherently:
  ##
  ##   1. ``netFetch`` with no declared destination — a permission with no
  ##      subject. The edge would be cacheable on evidence ("what I retrieved
  ##      from where") whose second half is empty.
  ##   2. ``netDenied`` with declared destinations — an author who believed
  ##      they had granted something. Silence is denial, so this reads as a
  ##      grant and behaves as a denial; that gap is the amendment's rule 1
  ##      failing in the direction it cannot detect at run time.
  ##   3. ``netFetch`` on an edge kind that is not fetch-capable. Rule 3 says
  ##      network-touching edges exist on the generation path only; an
  ##      arbitrary compile or copy edge promoting itself to ``netFetch``
  ##      would put one inside a build that believes itself pinned.
  result = @[]
  for action in g.actions:
    case action.networkMode
    of netFetch:
      if action.kind notin NetworkFetchCapableKinds:
        result.add(NetworkPolicyAuditFinding(actionId: action.id,
          kind: action.kind,
          reason: "edge kind " & $action.kind & " may not declare netFetch"))
      elif action.netDestinations.len == 0:
        result.add(NetworkPolicyAuditFinding(actionId: action.id,
          kind: action.kind,
          reason: "netFetch declares no tracked destination"))
    of netDenied:
      if action.netDestinations.len > 0:
        result.add(NetworkPolicyAuditFinding(actionId: action.id,
          kind: action.kind,
          reason: "netDenied action names " & $action.netDestinations.len &
            " destination(s); silence is denial, so the grant would not hold"))

proc formatNetworkPolicyAudit*(
    findings: seq[NetworkPolicyAuditFinding]): string =
  ## The audit's diagnostic. Rule 4 of the amendment requires the
  ## classification be visible "in logs, debugging output, per-action explain
  ## output"; this is the graph-construction end of that requirement.
  if findings.len == 0:
    return ""
  result = "network policy is incoherent on " & $findings.len &
    " action(s) — Sandbox-And-Monitoring.md §\"The Network Dimension\""
  for f in findings:
    result.add("\n      " & f.actionId & " (" & $f.kind & "): " & f.reason)

# ---------------------------------------------------------------------------
# Package-Model.md §"Rule Generators And Dynamic Rule Discovery" — explicit
# wave expansion.
# ---------------------------------------------------------------------------

const DefaultMaxExpansionWaves* = 8
  ## The bounded iteration policy's bound.
  ##
  ## The quoted requirement is "expand the graph in explicit waves until a
  ## closed frontier is reached, **with cycle detection and a bounded
  ## iteration policy**" — two separate obligations, and this constant is the
  ## second. Cycle detection catches a generator that re-emits an action it
  ## already emitted; the bound catches a generator that emits a NEW action
  ## every wave and therefore never repeats itself, which no cycle detector
  ## can see. Without the bound that case is an infinite loop that looks like
  ## a hang.
  ##
  ## Eight rather than two, because the value has to admit the shapes the
  ## corpus already contemplates (a rule generator producing rule generators)
  ## while still terminating fast enough that a runaway is a failed build
  ## rather than a wedged one. Named-Lock-Files §5.6's own expansion needs
  ## exactly ONE wave — the over-approximated fetch is deliberately not a
  ## fixpoint — so this bound is headroom for other generators, not for it.

type
  WaveExpansion* = object
    ## The record of an explicit wave expansion. Kept as a value rather than
    ## folded into one flat action list because "how many waves" is itself an
    ## asserted property: Named-Lock-Files §5.6 resolves variant-conditioned
    ## ``uses:`` by over-approximation and says so in terms — "One wave, no
    ## iteration" — and a flat list cannot distinguish that from a fixpoint
    ## that happened to converge after one step.
    waves*: seq[seq[BuildAction]]
    closed*: bool
      ## True when expansion stopped because a wave produced nothing further
      ## — the "closed frontier" of the quoted text. False is unreachable
      ## today (both other outcomes raise); the field exists so a caller
      ## reads the reason rather than inferring it from an absence.

  WaveExpansionCycle* = object of BuildEngineError
    ## A rule generator re-emitted an action id an earlier wave already
    ## produced. Distinct from the bound so a caller — and a reader of the
    ## failure — can tell "this generator is looping" from "this generator is
    ## productive but deep".

  WaveExpansionBoundExceeded* = object of BuildEngineError
    ## Expansion did not reach a closed frontier within the bound.

proc actionIds*(actions: seq[BuildAction]): seq[string] =
  result = @[]
  for a in actions: result.add(a.id)

proc expandGraphInWaves*(seed: seq[BuildAction];
                         expand: proc(previousWave: seq[BuildAction]):
                           seq[BuildAction] {.closure.};
                         maxWaves = DefaultMaxExpansionWaves): WaveExpansion =
  ## Expand a graph in explicit waves until a closed frontier is reached.
  ##
  ## `Package-Model.md` §"Rule Generators And Dynamic Rule Discovery":
  ## "Because the output changes graph shape, an action that depends on
  ## generated rules must not run until the relevant rule-generator artifacts
  ## have been materialized and stitched into the graph. If rule generators
  ## can themselves produce more rule-generator actions, the engine should
  ## expand the graph in explicit waves until a closed frontier is reached,
  ## with cycle detection and a bounded iteration policy."
  ##
  ## `seed` is wave 1. `expand` is handed the wave that was just materialized
  ## and returns the actions stitched in behind it; an empty return closes the
  ## frontier. Both failure modes RAISE rather than truncating: a silently
  ## truncated expansion produces a graph that is missing edges and reports
  ## success, which is the silent-wrong-answer direction this campaign
  ## designs against throughout.
  if seed.len == 0:
    raiseEngine("wave expansion requires a non-empty seed wave")
  if maxWaves < 1:
    raiseEngine("wave expansion bound must be at least 1, got " & $maxWaves)
  result = WaveExpansion(waves: @[seed], closed: false)
  var seen = initHashSet[string]()
  for a in seed: seen.incl(a.id)
  while true:
    let next = expand(result.waves[^1])
    if next.len == 0:
      result.closed = true
      return
    for a in next:
      if seen.contains(a.id):
        raise newException(WaveExpansionCycle,
          "rule-generator expansion cycle: action '" & a.id &
          "' was emitted again in wave " & $(result.waves.len + 1) &
          " after an earlier wave already produced it")
      seen.incl(a.id)
    if result.waves.len >= maxWaves:
      raise newException(WaveExpansionBoundExceeded,
        "rule-generator expansion did not reach a closed frontier within " &
        $maxWaves & " wave(s); wave " & $(maxWaves + 1) &
        " would have added " & $next.len & " action(s) (" &
        next.actionIds.join(", ") & ")")
    result.waves.add(next)

proc allActions*(expansion: WaveExpansion): seq[BuildAction] =
  ## Every action across every wave, in wave order then declaration order.
  result = @[]
  for wave in expansion.waves:
    for a in wave: result.add(a)

proc validateGraph(g: BuildGraph) =
  # Named-Lock-Files §7.2 — the second half of the structural check, and the
  # release gate. `{.requiresInit.}` on `BuildAction.governingLockIdentity` is
  # the compile-error half and it reaches every construction expression; this
  # is "a hard failure at graph construction where it cannot" — it catches an
  # identity that was supplied but is empty or malformed, which the type
  # system cannot see.
  #
  # It runs FIRST, before the id / duplicate-output / write-root passes. An
  # action that cannot be keyed correctly is not worth diagnosing further, and
  # a reader who gets the write-root error first will fix that and never learn
  # about the poisoning vector.
  let lockFindings = auditGoverningLockIdentity(g)
  if lockFindings.len > 0:
    raiseEngine(formatLockIdentityAudit(lockFindings))

  # Sandbox-And-Monitoring.md §"The Network Dimension" — the same shape of
  # gate, for the same reason. An incoherent network policy is silent at run
  # time in the dangerous direction: an author who wrote a grant that does not
  # hold gets a hermetic action, and an author who wrote a fetch edge with no
  # destination gets an edge cached on half its evidence.
  let netFindings = auditNetworkPolicy(g)
  if netFindings.len > 0:
    raiseEngine(formatNetworkPolicyAudit(netFindings))

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

  # M9.R.75 — R7 (double-write reject) pairwise write-root
  # intersection pass. Spec cite: Filesystem-Policy-And-Observed-
  # Inputs.md §"Double Writes" (lines 246-262): "double writes are
  # errors" is the shipping default.
  #
  # Dependency-aware relaxation: R7 targets CONCURRENT double writes
  # (two producers racing for the same output). When action B
  # transitively depends on action A, they are SEQUENTIAL — B's writes
  # happen strictly after A's, so a shared write scope is legitimate
  # sequencing (configure → compile → install all writing under the
  # same buildDir is the canonical pattern). The check therefore only
  # fires when neither action reaches the other via ``deps``.
  #
  # Design choice: pairwise O(N*M*K) over the number of
  # declaredOutputs-carrying actions with an on-demand transitive-
  # reachability probe. Fine for real graphs (declaredOutputs is
  # populated only by from-source conventions, so the seq is small).
  # If a graph outgrows this, a topo-order + longest-antichain
  # partitioning is the natural follow-up.
  proc reachable(fromId, toId: string): bool =
    var stack: seq[string] = @[fromId]
    var seen = initHashSet[string]()
    while stack.len > 0:
      let cur = stack.pop()
      if cur == toId:
        return true
      if cur in seen:
        continue
      seen.incl(cur)
      if cur in byId:
        for dep in byId[cur].deps:
          if dep notin seen:
            stack.add(dep)
    false

  var declaredIndex: seq[tuple[actionId: string; root: string]] = @[]
  for action in g.actions:
    for raw in action.declaredOutputs:
      let root = normalizeWriteRoot(raw)
      if root.len == 0:
        continue
      declaredIndex.add((actionId: action.id, root: root))
  for i in 0 ..< declaredIndex.len:
    for j in (i + 1) ..< declaredIndex.len:
      if declaredIndex[i].actionId == declaredIndex[j].actionId:
        continue
      if not writeRootsOverlap(declaredIndex[i].root, declaredIndex[j].root):
        continue
      # Overlap exists — check for a dep chain in either direction.
      # If found, treat as sequential (legitimate configure→compile→
      # install pattern) and skip. Only concurrent writers land as R7.
      if reachable(declaredIndex[i].actionId, declaredIndex[j].actionId) or
         reachable(declaredIndex[j].actionId, declaredIndex[i].actionId):
        continue
      raiseEngine("double-write reject (R7): concurrent actions '" &
        declaredIndex[i].actionId & "' and '" &
        declaredIndex[j].actionId &
        "' declare overlapping write roots ('" &
        declaredIndex[i].root & "' vs '" & declaredIndex[j].root &
        "') with no dependency chain between them. Spec: " &
        "Filesystem-Policy-And-Observed-Inputs.md §\"Double Writes\" " &
        "— default policy is 'double writes are errors'. Add an " &
        "explicit dependency edge to sequentialise the writes, or " &
        "redirect one action to a non-overlapping write root.")

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
  # NLF-M5: a metadata-fetch object and a generated lock are plain files
  # written by their executors, so they take the same readiness rule.
  if action.kind in {bakCopyFile, bakWriteText, bakStamp, bakWorkspaceVcs,
                     bakForeignProvision, bakMetadataFetch, bakSolveLock} and
      symlinkExists(extendedPath(path)):
    return false
  path.pathExists()

proc allOutputsExist(action: BuildAction): bool =
  ## "Is every DECLARED output still on disk?"
  ##
  ## Deliberately FALSE for an action that declares no outputs. Callers use
  ## this answer to take the "the artifacts are already there, call it up to
  ## date" shortcut WITHOUT consulting the action cache; inferring that from
  ## an empty set would let a never-executed edge report itself up to date.
  ## The separate question "may a cache RECORD be reused in place" is
  ## answered by `cachedResultReusableInPlace` below — the two must not be
  ## collapsed into one predicate.
  if action.outputs.len == 0:
    return false
  for output in action.outputs:
    let path = if output.isAbsolute or action.cwd.len == 0: output else: action.cwd / output
    if not action.outputPathReady(path):
      return false
  true

proc declaresNoOutputs(action: BuildAction): bool {.inline.} =
  action.outputs.len == 0

proc determinismClass*(action: BuildAction): EdgeDeterminism {.inline.} =
  ## The class this edge is treated as. `none` is §2.1's unlabelled case and
  ## resolves to `weak`; see `BuildAction.determinism` for why the field is an
  ## `Option`.
  effectiveDeterminism(action.determinism)

proc effectiveRetention*(action: BuildAction): CacheRetention {.inline.} =
  ## Retention applies only to `volatile` edges. §1's table gives every other
  ## class "cache forever" / "cache forever, per host", and honouring a
  ## retention clause that someone attached to a non-volatile edge would be
  ## inventing an invalidation the spec does not admit.
  if action.determinismClass == edVolatile: action.cacheRetention
  else: forever()

proc rebuildSelectorInvalidates*(config: BuildEngineConfig;
                                 action: BuildAction): bool =
  ## `Edge-Determinism-And-Soft-Rebuild.md` §4.1–§4.3 crossed with §4.5.
  ## An edge is invalidated when the invocation's rebuild verb covers its
  ## class AND the `--only` selector (if any) names it.
  if config.rebuildClass == rbNone:
    return false
  if not config.rebuildClass.invalidates(action.determinismClass):
    return false
  matchesOnlySelector(config.rebuildOnly, action.id, action.targetNames)

proc entryDeterminismFor*(config: BuildEngineConfig;
                          action: BuildAction): EntryDeterminism =
  ## The §3 write-column metadata this action stamps onto its cache entry:
  ## the class, the host fingerprint, the wall-clock write time and the
  ## retention clause.
  ##
  ## An UNLABELLED edge stamps nothing. That is the difference between "this
  ## action is `weak`" and "nobody said": the first is a claim a later
  ## substitution decision may rely on, the second is silence, and a cache
  ## that cannot tell them apart will eventually mistake one for the other.
  ## It also means the overwhelming majority of edges write no sidecar and
  ## pay nothing for this milestone existing.
  if action.determinism.isNone:
    return EntryDeterminism()
  declaredDeterminism(action.determinismClass, action.effectiveRetention,
    nowUnix = config.nowUnix, buildEpoch = config.buildEpoch)

proc refusesRecordWithNoInputs*(action: BuildAction): bool =
  ## Is this an edge for which a cache record with NO inputs and NO observed
  ## environment inputs is never legitimate?
  ##
  ## THE SCOPE, factored out because it is read from three places that would
  ## otherwise each carry their own copy: the per-edge lookup
  ## (`unservableCacheRecordReason`), the whole-graph metadata scan (through
  ## `HotMetadataProbe.refuseRecordWithNoInputs`), and the whole-graph
  ## record scan. A predicate whose scope is written down three times is a
  ## predicate that will eventually mean three things.
  ##
  ## Each clause excludes a case where an empty record is CORRECT:
  ##
  ## * `cacheable` — a non-cacheable edge never publishes and always re-runs.
  ## * `bakProcess` — a built-in (write-text, copy-file, stamp) legitimately
  ##   has no file inputs; it is keyed on text its caller mixed into the weak
  ##   fingerprint, and refusing it would make every such edge a permanent
  ##   miss.
  ## * `MonitorPolicyKinds` — this is the class where the ENGINE promised to
  ##   discover the input set, so an empty one is the engine's failure. Where
  ##   the author declares the set (a recognized report), an empty set is the
  ##   author's statement and not ours to overrule.
  action.cacheable and action.kind == bakProcess and
    action.dependencyPolicy.kind in MonitorPolicyKinds

proc unservableCacheRecordReason*(action: BuildAction;
                                  record: ActionResultRecord): string =
  ## Why this RECORD must not be served to this ACTION, or `""`.
  ##
  ## THE LOOKUP-SIDE TWIN OF `gradeKeyedInputSet`, and the reason there is one
  ## at all. The publish-side guard is where the information lives — at publish
  ## time the engine knows what the monitor observed — so it is the primary
  ## defence and this is not a substitute for it. What this adds is POSITION:
  ## it sits on the path every record must cross to be used, whichever
  ## direction it arrived from. A record installed from a LAN peer, restored
  ## from a binary cache, or written by some future launch path that publishes
  ## without going through `collectEvidence` never passes the publish-side
  ## guard at all. It passes here.
  ##
  ## THE PREDICATE IS RECORD-INTRINSIC AND HAS NO FALSE POSITIVES, and both
  ## halves of that matter. A record with no input fingerprints and no observed
  ## environment inputs is keyed on the weak fingerprint alone: the lookup
  ## re-derives its strong fingerprint from its own (empty) input list, finds
  ## nothing to compare against the filesystem, and returns a hit — forever,
  ## for every future build, whatever changes. For a monitored, cacheable
  ## PROCESS edge that state is never legitimate; `gradeKeyedInputSet` refuses
  ## to publish it. The scope is what keeps it honest: a built-in action
  ## (write-text, copy-file, stamp) legitimately has no file inputs and is
  ## keyed on text its caller mixed into the weak fingerprint, and an edge
  ## whose author declares its own input set owns that set.
  ##
  ## WHAT IT DELIBERATELY DOES NOT TRY TO DO. It does not attempt to recognise
  ## the records published during the 2026-09-02..2026-09-08 window. Those
  ## carry ONE input — the root image the engine reconstructed from `argv[0]`
  ## — and are byte-indistinguishable from a record of an edge that genuinely
  ## read that path. The fact that would separate them was destroyed when the
  ## two were merged into one list (Dependency-Observation-Attribution.md rule
  ## 6). Draining those needs a discriminator the record does carry, which is
  ## its version; see `ActionRecordVersion` in `repro_local_store`. Guessing
  ## here instead would refuse sound entries and still miss unsound ones.
  if not action.refusesRecordWithNoInputs():
    return ""
  if record.inputs.len > 0 or record.envInputs.len > 0:
    return ""
  "action '" & action.id & "': refusing a cached record with no recorded " &
    "inputs and no recorded environment inputs. Such a record is keyed on " &
    "the weak fingerprint alone, so it has nothing to revalidate and would " &
    "be served on every future build regardless of what changed. A monitored " &
    "cacheable action never publishes one; this record predates the guard " &
    "that refuses to, or arrived from a producer that lacks it. Re-running. " &
    "Spec: Failure-Semantics.md:11-12, " &
    "Reprobuild-Development.milestones.org M17."

proc cachedResultReusableInPlace(action: BuildAction;
                                 declaredOutputsPresent: bool): bool =
  ## "If the action cache says nothing this action reads has changed, can the
  ## previous result be reused where it already is?"
  ##
  ## Takes `declaredOutputsPresent` rather than calling `allOutputsExist`
  ## itself so the caller pays for exactly one output stat, and so an edge
  ## that declares no outputs is never stat'd at all.
  ##
  ## For an edge that declares outputs, yes only when those outputs are still
  ## present — otherwise `rebuildMissingOutputsOnCacheHit` has to re-execute
  ## to put them back, and the revalidation added in "Revalidate declared
  ## outputs before reusing an action result" still has something to compare
  ## against.
  ##
  ## For an edge that declares NO outputs there is nothing to restore and
  ## nothing to revalidate, so the hit is keyed on inputs alone. Reprobuild
  ## invalidates coarsely: "no input changed since the recorded run" is by
  ## itself a sufficient reason not to re-run, and a run that produces
  ## nothing is not a reason to re-run it. This is what makes a `test` edge —
  ## `ct_test_nim_unittest.run`, which declares `outputs = []` — benefit from
  ## "action-cache reuse, incremental invalidation, named selection, and
  ## watch" as required by Test-Edges-And-Parallel-Runner.milestones.org
  ## initiative goal (1), and what satisfies Incremental-Invalidation.md
  ## §"Validation Criteria": "a warm re-run of an unchanged graph still
  ## executes zero actions".
  ##
  ## NOTE the asymmetry with `allOutputsExist`, and that it is intentional:
  ## reuse here is gated on a cache RECORD whose inputs were just verified
  ## unchanged. `allOutputsExist`'s callers have no such record.
  ##
  ## This is defence in depth rather than the sole barrier: `lookupActionResult`
  ## independently revalidates declared outputs against the record
  ## (`outputStateMismatch`), so forcing this predicate true does not by
  ## itself let a missing or corrupted output be reused. It is what keeps the
  ## engine from asking for a restore it cannot perform, and what keeps an
  ## edge with nothing to restore from being treated as one that failed to.
  action.declaresNoOutputs() or declaredOutputsPresent

proc restoreWouldOverwriteMatchingOutputs(action: BuildAction;
                                          record: ActionResultRecord): bool =
  ## "Is every declared output already exactly what this record describes?"
  ##
  ## Asked on a RESTORE-mode cache hit, immediately before
  ## ``materializeActionCacheOutputs``. The restore path replaces each
  ## declared output from the CAS unconditionally, and it cannot do that
  ## without giving the file a new identity: ``applyPermissions`` excludes the
  ## shared-inode (hardlink) arm, and the reflink/copy arms stage a fresh file
  ## and rename it into place. The destination therefore comes back with a new
  ## mtime and ctime on every build.
  ##
  ## That is invisible for the restored edge itself — nothing downstream of
  ## the restore re-reads its own output metadata — and fatal one edge later.
  ## A consumer of those outputs fingerprints them as INPUTS, and under
  ## ``ffpTimestamp`` (the default policy) a new mtime is a changed input. So a
  ## warm re-run in restore mode re-executed every edge above the leaves,
  ## forever: measured on a four-compile + one-link graph, the four compiles
  ## hit and restored, the link missed with "input changed" and relinked, on
  ## every single build. That contradicts Incremental-Invalidation.md
  ## §"Validation Criteria" — "a warm re-run of an unchanged graph still
  ## executes zero actions" — which is unqualified by mode, and it is the same
  ## clause ``cachedResultReusableInPlace`` above is written to satisfy.
  ##
  ## The mode's own name is what settles the fix. Caching-Architecture.md
  ## §"What is on by default" calls the capability "**Restore an output you no
  ## longer have**", and §"Memoization Layer" contrasts "rebuild missing
  ## outputs" with "restore missing outputs". An output that is present and
  ## matches the record is not missing, so restoring it is work the mode never
  ## promised and whose only observable effect is the cascade above.
  ##
  ## THE COMPARISON IS THE PRODUCTION ONE, not a weaker existence probe.
  ## ``outputStateMismatch`` is Incremental-Invalidation.md Step 3.3 — the
  ## same revalidation the in-place (metadata-only) arm performs before
  ## reusing a record — so an output that was truncated, rewritten, retargeted
  ## or had its tree tampered with still fails this test and is restored. It
  ## costs one ``lstat`` per declared output, on a path that has just paid for
  ## a full CAS blob verification.
  ##
  ## ``allOutputsExist`` is asked first and is not redundant:
  ## ``outputStateMismatch`` skips outputs recorded as ``ffkMissing``, so a
  ## record that describes nothing would otherwise answer "matching"
  ## vacuously. An edge that declares no outputs answers false and keeps the
  ## restore path it has today.
  if action.declaresNoOutputs():
    return false
  if not action.allOutputsExist():
    return false
  outputStateMismatch(record, action.cwd).len == 0

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

proc addUnique(values: var seq[string]; seen: var HashSet[string];
               value, key: string) =
  ## `addUnique` where MEMBERSHIP is keyed differently from what is stored.
  ##
  ## Exists for observed environment names: Windows environment lookup is
  ## case-insensitive, so `PATH` and `Path` are one variable with one value
  ## and must produce one cache-key entry, while the stored spelling stays the
  ## one the program used.
  if value.len == 0:
    return
  if seen.containsOrIncl(key):
    return
  values.add(value)

proc envNameKey*(name: string): string =
  ## The dedup key for an observed environment variable name.
  ##
  ## Upper-cased on Windows ONLY. On POSIX the environment is
  ## case-SENSITIVE -- `Path` and `PATH` really are two variables with two
  ## values -- so folding case there would merge two distinct inputs into one
  ## cache-key entry and lose whichever the merge dropped. The io-mon shims
  ## make the same platform split for the same reason.
  when defined(windows):
    name.toUpperAscii
  else:
    name

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

proc selfConsumedDeclaredPaths*(action: BuildAction): seq[string] =
  ## S5 — the materialized paths this action declares as BOTH an input and
  ## an output, in declaration order.
  ##
  ## Such an action genuinely consumes its own output: an incremental tool
  ## reading the state a previous run left behind. It is therefore NOT
  ## hermetic — its result depends on what was on disk before it ran — and
  ## the one thing it must never do is silently take a cache hit on that
  ## stale state. It does not — and NOT because anything here exempts it.
  ## These paths are NOT exempt from ``selfWrittenOutputKeys``; they are in
  ## that set like any other declared output. The carve-out is STRUCTURAL:
  ## both input folds add ``evidence.declaredInputs`` first and unfiltered,
  ## so such a path is already in the key before the self-write filter is
  ## consulted, and all the filter can still drop is the same file arriving
  ## a second time through an observed channel under another spelling. The
  ## fingerprint keeps tracking it and the action misses on every run in
  ## which its own output changed. A permanent miss is the correct answer
  ## for a non-hermetic action; a hit would be a false one.
  ##
  ## This proc is therefore purely diagnostic — nothing in
  ## ``cacheInputPaths`` branches on its result. ``collectEvidence`` turns a
  ## non-empty result into a diagnostic so the permanent miss that follows
  ## does not read as a caching bug.
  for output in action.outputs:
    let materialized = materialPath(action.cwd, output)
    let key = materialized.replace('\\', '/')
    var declared = false
    for input in action.inputs:
      if materialPath(action.cwd, input).replace('\\', '/') == key:
        declared = true
        break
    if declared and materialized notin result:
      result.add(materialized)

proc isVolatileMonitorPath(path: string): bool =
  ## Runtime pseudo-filesystems describe the monitored process or host at one
  ## instant. They cannot be reopened reliably when the action is fingerprinted
  ## and must never become cache inputs.
  ##
  ## The predicate itself lives in ``repro_core/paths`` and is SHARED with
  ## ``repro_local_store``'s ``isRecordableInput``, which used to carry a
  ## hand-copied duplicate under a "keep this aligned" comment. The two
  ## have to agree exactly: this one decides what reaches the evidence, the
  ## other decides what reaches the cache RECORD, and a path the first
  ## admits and the second drops is fingerprinted as an input the entry
  ## does not carry — the same stale serve, one layer down. A comment
  ## cannot enforce that; one function can.
  isVolatileRuntimeStatePath(path)

proc parseCreateActionRecord(payload, path: string; lineNo: int;
                             governingLockIdentity: LockIdentity): BuildAction =
  ## Decode an M25 ``create-action`` JSON payload into a BuildAction. The
  ## payload format is a single-line JSON object; embedded newlines are
  ## forbidden so the surrounding line-oriented fragment parser stays
  ## simple.
  ##
  ## Named-Lock-Files §4.1/§7.2: `governingLockIdentity` is the identity of
  ## the action that PRODUCED this fragment, and it is a required parameter
  ## rather than a field of the JSON payload. Two reasons, and both matter.
  ##
  ## First, §4.1: "An edge is built under the lock file of the consumer that
  ## pulled it in." A dynamically created action is pulled in by its producer,
  ## so inheriting the producer's identity is the propagation rule, not a
  ## fallback.
  ##
  ## Second, §7.2: a payload field would be OPTIONAL — a fragment written by
  ## an older producer, or by a tool that never heard of lock files, would
  ## simply omit it and the engine would have to invent something. That is the
  ## silent-incompleteness shape the structural check exists to remove. The
  ## producer does not get to decide; the engine supplies it.
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
    weakFingerprint = weakFingerprint, env = env,
    governingLockIdentity = governingLockIdentity)

proc readDynamicGraphFragment(path: string;
                              governingLockIdentity: LockIdentity):
    DynamicGraphFragment =
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
      result.createdActions.add(parseCreateActionRecord(
        rest, path, lineNo + 1, governingLockIdentity))
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

type
  MonitorShimPlatform* = enum
    ## Which io-mon shim a build is running against. Present so the
    ## library-load-floor question below can be answered for EVERY
    ## platform on ANY host — see `monitorShimHasLibraryLoadFloor`.
    mspLinux, mspMacos, mspWindows, mspUnsupported

func monitorShimHasLibraryLoadFloor*(platform: MonitorShimPlatform): bool =
  ## Does this platform's monitor shim emit `mrLibraryLoad` records?
  ##
  ## A FUNCTION OVER A PLATFORM rather than a bare `defined()` constant,
  ## and that is the whole point. As a constant the Windows answer is
  ## unreachable from a Linux test run — `defined(linux) or
  ## defined(macosx)` and a plain `true` are indistinguishable there, so
  ## a mutation that silently claimed a floor everywhere passed every
  ## test. Measured: that exact mutation survived. As data, every
  ## platform's answer is gradeable wherever the suite runs.
  ##
  ## The values come from counting `mrLibraryLoad` emission sites in the
  ## io-mon sibling: `shim/linux_preload.nim` 2,
  ## `shim/macos_interpose.nim` 2, `shim/windows_interpose.nim` 0.
  case platform
  of mspLinux, mspMacos: true
  of mspWindows, mspUnsupported: false

when defined(linux):
  const HostMonitorShimPlatform* = mspLinux
elif defined(macosx):
  const HostMonitorShimPlatform* = mspMacos
elif defined(windows):
  const HostMonitorShimPlatform* = mspWindows
else:
  const HostMonitorShimPlatform* = mspUnsupported

const MonitorHasLibraryLoadFloor* =
  monitorShimHasLibraryLoadFloor(HostMonitorShimPlatform)
  ## The host's answer to `monitorShimHasLibraryLoadFloor`.
  ##
  ## WHAT DEPENDS ON IT. On a platform WITH a floor, every process the
  ## shim can inject reports at least the dynamic loader plus its own
  ## dependent libraries, so "the monitor recorded no observation at all"
  ## is not reachable for an injectable process — the zero-evidence guard
  ## in `collectEvidence` is a backstop against a backend asserting a
  ## completeness it has not earned. WITHOUT a floor, an ordinary
  ## monitored action that performs no interposed read, probe or write
  ## reaches the guard and stops publishing. That is still the correct,
  ## fail-closed direction — it re-runs rather than serving a stale
  ## result — but it is a live operational condition rather than an
  ## unreachable one, so it has to announce itself. See
  ## `zeroEvidenceDiagnostic`.

proc zeroEvidenceDiagnostic*(actionId: string;
                             hasLibraryLoadFloor: bool): string =
  ## The diagnostic for an action whose monitor reported success while
  ## recording nothing. Split out and exported so BOTH branches are
  ## gradeable on any host: the no-floor branch is the one that matters
  ## operationally and it is not reachable on the platform this is
  ## usually built on, so a `when`-guarded string literal would ship
  ## untested.
  result = "action '" & actionId & "': monitor reported success but " &
    "recorded no observation of any kind (no reads, writes, probes or " &
    "enumerations). The recorded input set would be the declared inputs " &
    "alone, which cannot be distinguished from 'the monitor observed " &
    "nothing'. Action-cache publish skipped — an action with no " &
    "monitorable evidence is NON-CACHEABLE per Monitor-Hook-Shim.md " &
    "§\"Failure Semantics\" and Reprobuild-Development.milestones.org " &
    "M17, never complete-on-declared-inputs."
  if hasLibraryLoadFloor:
    result.add(" This platform HAS a library-load floor, so an injectable " &
      "process cannot normally reach this state; suspect the monitor " &
      "backend rather than the action.")
  else:
    result.add(" This platform has NO library-load floor (its shim emits " &
      "no library-load records), so an action that performs no interposed " &
      "read, probe or write reaches this state legitimately and will " &
      "re-run on EVERY build, permanently, until it gains observable " &
      "evidence or is marked `cacheable = false`. If that is not what you " &
      "want, the fix is a library-load floor in the platform's shim, not " &
      "a weaker guard here.")

proc emptyKeyedInputSetDiagnostic*(actionId: string;
                                   observedCount, elidedCount: int): string =
  ## The diagnostic for an action that observed something and keyed on
  ## nothing — the S2 state.
  ##
  ## `zeroEvidenceDiagnostic` above grades what the MONITOR saw.  This one
  ## grades what the RECORD is keyed on, and the two are different sets: the
  ## engine's own tool-root and ignored-prefix subtractions are applied to the
  ## observed channels on the way to `cacheInputPaths`, AFTER the monitor
  ## question has been asked and answered.
  ##
  ## MEASURED (2026-09-09) — monitored cacheable edge, `argv[0]` a
  ## `/nix/store/…-bash-5.2p26/bin/sh`, whose single observed read is a file
  ## under that same store root, declaring nothing:
  ##
  ## | | value |
  ## |---|---|
  ## | `monitorReads` (the guard's set) | 2 entries -> passes, no diagnostic |
  ## | `cacheInputPaths` (the key's set) | `[]` |
  ## | published | **yes**, `record.inputs.len == 0` |
  ## | warm | `cdHit`, `launched = false` |
  ##
  ## A cacheable edge published a record with an entirely empty input set —
  ## precisely the state `zeroEvidenceDiagnostic`'s guard exists to refuse —
  ## and reached it with no diagnostic at all, because the guard graded a
  ## different set than the one that got keyed. That is
  ## Dependency-Observation-Attribution.md rule 7: "the set a guard checks and
  ## the set the key is built from are the same set — or the difference
  ## between them is itself counted and reported". This message is the report,
  ## and `elidedCount` is the count rule 3 asks for.
  "action '" & actionId & "': the monitor observed " & $observedCount &
    " path(s), but " & $elidedCount & " of them were elided by the " &
    "action's own tool roots / ignored prefixes and the action-cache " &
    "input set came out EMPTY. Such a record is keyed on the weak " &
    "fingerprint alone and is indistinguishable from one published by an " &
    "action that observed nothing, which is the state " &
    "Reprobuild-Development.milestones.org M17 and " &
    "Compiles-Are-Normal-Edges.md:269-273 refuse. Action-cache publish " &
    "skipped; the edge re-runs. If the elided paths really are keyed by " &
    "construction, the edge still has nothing of its own in the key and " &
    "wants `cacheable = false`; if they are not, the elision is the bug. " &
    "Spec: Dependency-Observation-Attribution.md rules 3 and 7."

proc monitorEvidenceRequired(action: BuildAction): bool =
  ## Monitor evidence is required for monitored policies once an iomon
  ## (monitor depfile) has actually been wired up for the action. The only
  ## way a monitored action ends up without an iomon now is an engine config
  ## that has no io-monitor wired (``monitorCliPath`` empty): the setup step
  ## emits a "requires an io-monitor driver" diagnostic and falls back to the
  ## statically declared inputs/outputs rather than claiming complete
  ## evidence. (The Windows ``REPRO_MONITOR_BYPASS`` escape hatch that used
  ## to produce this state was removed.)
  action.dependencyPolicy.kind in MonitorPolicyKinds and
    action.monitorDepfile.len > 0

proc needsExecutionForPolicy(action: BuildAction): bool =
  action.dependencyPolicy.kind in MonitorPolicyKinds or
    (not action.cacheable and
      action.dependencyPolicy.kind in RecognizedPolicyKinds) or
    action.kind == bakPreserveTree

type
  EvidenceSeenSets* = object
    # Deferred-D4: side-car membership trackers for the parallel ``seq[string]``
    # fields on ``PathSetEvidence``. Threaded through the per-action evidence
    # aggregation so each ``addUnique`` lookup is O(1) instead of O(N).
    # M9.R.72.3: exported so end-to-end regression tests can drive
    # ``foldMonitorDepFileEvidence`` directly against synthetic iomon depfiles.
    depfileInputs*: HashSet[string]
    monitorReads*: HashSet[string]
    monitorWrites*: HashSet[string]
    monitorProbes*: HashSet[string]
    monitorEnvReads*: HashSet[string]
      ## M10 — case-INSENSITIVE membership on Windows, where `PATH` and `Path`
      ## are one variable. The shim already dedupes that way; this is the
      ## second line, for a merge of fragments from processes that spelled it
      ## differently.

    monitorDirectoryEnumerations*: HashSet[string]

proc monitorProfileEvidenceComplete(detail: string): bool =
  result = true
  for part in detail.split(';'):
    let pair = part.split("=", 1)
    if pair.len == 2 and pair[0] == "evidenceComplete":
      return pair[1] == "true"

const NonDeterminismCapabilityId = "non-determinism"
  ## io-mon's `capabilityId(mcapNonDeterminism)`. Matched against both the
  ## `supported=` list of an `mrBackendProfile` record and the `capability=`
  ## token of an `mrCapabilityGap` record.

proc monitorProfileSupportsNonDeterminism*(detail: string): bool =
  ## M6 — does this `mrBackendProfile` record advertise entropy observation?
  ##
  ## The profile detail is `backend=...;supported=a,b,c;required=...;
  ## evidenceComplete=...` (io-mon `capabilities.backendProfileRecord`). A
  ## profile that does not name `non-determinism` among its supported
  ## capabilities cannot have produced an `mrNonDeterministic` record, so its
  ## silence on entropy is not evidence.
  ##
  ## Note this reads `supported=`, not `required=`: `required` says only
  ## which capabilities the CALLER asked for, which answers a different
  ## question (io-mon `types.MonitorCapabilityGap.inputChannel` makes the same
  ## point about the gap record's `required` flag).
  for part in detail.split(';'):
    let pair = part.split("=", 1)
    if pair.len == 2 and pair[0] == "supported":
      for capability in pair[1].split(','):
        if capability == NonDeterminismCapabilityId:
          return true
      return false
  false

proc capabilityGapIsNonDeterminism*(recordPath, detail: string): bool =
  ## M6 — is this `mrCapabilityGap` record the entropy one?
  ##
  ## io-mon writes the capability id into the record's `path` AND into the
  ## detail's `capability=` token (`capabilities.capabilityGapRecord`). Both
  ## are checked because they are written by different lines and a consumer
  ## that trusted only one would go quiet if either changed.
  if recordPath == NonDeterminismCapabilityId:
    return true
  for part in detail.split(';'):
    let pair = part.split("=", 1)
    if pair.len == 2 and pair[0] == "capability":
      return pair[1] == NonDeterminismCapabilityId
  false

proc entropyCallerOrigin*(detail: string): EntropyCallerOrigin =
  ## M6 — classify an `mrNonDeterministic` record's caller attribution.
  ##
  ## Windows details read `entropy source=<fn> caller=program|system`; the
  ## macOS (`non-deterministic entropy source`) and Linux (`linux
  ## non-deterministic source`) arms carry no `caller=` token because those
  ## shims filter at the hook and only emit the program's own use.
  ##
  ## FAIL-CLOSED ON AMBIGUITY: only a SINGLE `caller=program` token yields
  ## `ecoMainImage`. A duplicated token is attacker-shaped evidence (io-mon's
  ## `trustedDetailToken` refuses to resolve one for the same reason), and
  ## here the safe answer is the one that keeps the observation
  ## consequential.
  var seen = 0
  var value = ""
  for token in detail.split({' ', '\t', '\n', '\r'}):
    if token.startsWith("caller="):
      inc seen
      value = token["caller=".len .. ^1]
  if seen == 0:
    return ecoUnattributed
  if seen == 1 and value == "program":
    return ecoMainImage
  ecoOutsideMainImage

proc describeEntropyOrigin(origin: EntropyCallerOrigin): string =
  case origin
  of ecoMainImage: "the program's own main image (caller=program)"
  of ecoOutsideMainImage:
    "outside the main image (caller=system: ntdll's baseline OR the " &
      "program's own bundled DLL -- indistinguishable)"
  of ecoUnattributed:
    "the program's own code (shim-side attribution, no caller token)"

proc addEntropyObservation(evidence: var PathSetEvidence;
                           source: string; origin: EntropyCallerOrigin) =
  for existing in evidence.entropyObservations:
    if existing.source == source and existing.origin == origin:
      return
  evidence.entropyObservations.add(
    EntropyObservation(source: source, origin: origin))

proc benignRawSyscallLoss*(detail: string): bool =
  ## Recognise the io-mon "raw syscall unsupported" event-loss class and say
  ## whether the syscall in question provably cannot affect the observed-input
  ## set.
  ##
  ## io-mon's Linux preload shim intercepts the libc ``syscall(2)`` wrapper and
  ## decodes inline ``SYSCALL`` traps out of its ring buffer. Numbers it can
  ## model are handled by ``classifyRawFileSyscall``; everything else falls
  ## through to ``recordRawSyscallClassification``, which emits
  ##
  ##     "libc raw syscall unsupported nr=<N> run=<id>"    (libc wrapper route)
  ##     "inline raw syscall unsupported nr=<N> run=<id>"  (inline-trap route)
  ##
  ## (io-mon ``src/io_mon/shim/linux_preload.nim``, ``rawSyscallSourceName`` +
  ## ``recordRawSyscallClassification``, then ``stampRunId`` on the way out of
  ## ``emitRecord``.) Beyond the syscall NUMBER and the run stamp the detail
  ## carries nothing — no arguments, no fds, no paths.
  ##
  ## Such a record means "the shim saw a syscall it does not model", which is
  ## only a correctness problem when the syscall in question could open, read,
  ## write, probe, rename or otherwise name a file. For a small set of numbers
  ## that is decidable from the number alone, so the record carries no lost
  ## filesystem information and the depfile is still Level 0 (complete).
  ##
  ## **This is an allowlist, not an inversion of the default.** Any number not
  ## enumerated below keeps falling through to
  ## ``classifyEventLossDetail``'s fail-closed ``mesUnknownScopeLoss``.
  ##
  ## SYSCALL NUMBERS ARE ARCHITECTURE-SPECIFIC AND THE DETAIL STRING CARRIES NO
  ## ARCHITECTURE TAG. This is load-bearing, not pedantry: on the asm-generic
  ## table used by aarch64/riscv64/loongarch64, nr=39 is ``umount2`` — a
  ## filesystem-namespace mutation — where on x86_64 it is ``getpid``. The
  ## table below is therefore selected by the architecture this engine is
  ## COMPILED for, which is the architecture of the shim that produced the
  ## iomon (iomon depfiles live in the local ``build-engine-cache/monitor-depfiles`` and
  ## are never fetched cross-arch from the shared action cache). Architectures
  ## without a verified table get an empty allowlist and keep failing closed.
  ##
  ## Per-entry justification — each number verified against the kernel uapi
  ## headers (``asm/unistd_64.h`` for x86_64, ``asm-generic/unistd.h`` for
  ## arm64), NOT from memory:
  ##
  ##   * ``getpid`` (x86_64 nr=39, arm64 nr=172) — takes no arguments, touches
  ##     no descriptor and names no path; it copies the caller's pid out of the
  ##     kernel and returns. It cannot introduce a filesystem dependency and it
  ##     cannot hide one, because it mutates no shim state at all.
  ##
  ##   * ``close_range`` (x86_64 and arm64 nr=436) — closes a range of
  ##     descriptors. Closing a descriptor cannot open, read, write or probe a
  ##     path, so no new dependency can be introduced and no content can be
  ##     consumed through it.
  ##
  ##     RESIDUAL, stated rather than waved through: the shim DOES keep fd→path
  ##     state (``updateFdPath`` / ``removeFdPath`` / ``pathForFd`` in
  ##     ``linux_preload.nim``), and a bulk close it does not observe leaves
  ##     stale entries for the closed fds. The consequences of that staleness
  ##     are bounded:
  ##       - an fd number reused by a monitored ``open``/``openat`` is repaired,
  ##         because ``recordOpen`` → ``updateFdPath`` overwrites the entry;
  ##       - an fd number reused by an UNmonitored raw open already emits its
  ##         own unsupported-nr event-loss and so still fails closed here;
  ##       - an fd number reused by a non-path descriptor (socket/pipe/eventfd/
  ##         dup) makes a later read on it attribute to the STALE path, which
  ##         adds a spurious input — the over-approximating, cache-conservative
  ##         direction.
  ##     The one under-approximating corner is an fd that is simultaneously
  ##     marked inherited-at-shim-init AND carries a stale in-tree path AND is
  ##     reused by an opaque descriptor, which would suppress the
  ##     ``recordExternalContent`` Level 2 signal in ``classifyEmptyFdRead``.
  ##
  ##     That corner is NOT closed by leaving nr=436 fail-closed, which is why
  ##     the allowlist entry is still the right call: the shim has no
  ##     ``close_range`` handling of ANY kind — no libc-symbol hook and no raw
  ##     classifier arm (verified against the pinned io-mon revision this build
  ##     links). A program calling glibc's ``close_range()`` SYMBOL produces the
  ##     identical fd→path staleness and NO event-loss record at all, so the
  ##     session stays cacheable today. The nr=436 record therefore covers only
  ##     the minority ``syscall(2)`` route; as a soundness gate it is not
  ##     exhaustive, and all it actually buys is permanent cache loss for the
  ##     callers that happen to use the wrapper. The durable fix is an io-mon
  ##     ``of LinuxSysCloseRange:`` arm that calls ``removeFdPath`` over the
  ##     range plus a ``close_range`` symbol hook; io-mon is a pinned flake
  ##     input here and cannot be changed from this repo. This is recorded as a
  ##     known residual in
  ##     ``reprobuild-specs/Monitor-Loss-Path-Invalidation.md``.
  ##
  ## Deliberately NOT allowlisted, having been considered individually:
  ##   * ``io_uring_setup``/``io_uring_enter`` (x86_64 nr=425/426) — SQEs can
  ##     carry real opens and reads, so the number alone does not decide it.
  ##     io-mon makes its own documented tradeoff for these at the shim layer;
  ##     the engine does not re-endorse it.
  ##   * ``gettid`` (x86_64 nr=186) — provably benign by the same argument as
  ##     ``getpid``, but the pinned io-mon already classifies it at the shim so
  ##     it never reaches this classifier. Left out for lack of evidence that
  ##     any iomon carries it.
  when defined(linux) and defined(amd64):
    const BenignRawSyscallNumbers: seq[int64] = @[
      39'i64,    # getpid      — asm/unistd_64.h
      436'i64,   # close_range — asm/unistd_64.h
    ]
  elif defined(linux) and defined(arm64):
    const BenignRawSyscallNumbers: seq[int64] = @[
      172'i64,   # getpid      — asm-generic/unistd.h
      436'i64,   # close_range — asm-generic/unistd.h
    ]
  else:
    const BenignRawSyscallNumbers: seq[int64] = @[]
  const RawSyscallUnsupportedPrefixes = [
    "libc raw syscall unsupported nr=",
    "inline raw syscall unsupported nr=",
  ]
  # THE NUMBER IS NOT THE END OF THE STRING. Every record the Linux shim
  # emits passes through ``stampRunId`` (io-mon ``linux_preload.nim``),
  # which appends a whitespace-separated ``run=<id>`` token to ``detail``.
  # A real iomon therefore carries
  #
  #     "libc raw syscall unsupported nr=436 run=1787695082.5534084"
  #
  # not "…nr=436". A first cut of this classifier required the remainder
  # after the prefix to be a bare decimal and so matched nothing a real
  # build ever produces: every synthetic unit test passed and the edge it
  # was written to rescue kept re-executing. Parse the remainder as
  # whitespace-separated FIELDS — field 0 is the syscall number, and each
  # remaining field must be a stamping token named below.
  #
  # The trailing-token list is an allowlist for the same reason the number
  # table is. A token this classifier has not reasoned about could carry
  # meaning, so an unrecognised one fails closed. The cost of a future
  # io-mon stamp landing here is cache loss, not unsoundness — and that is
  # the direction this whole classifier is required to err in.
  const BenignTrailingTokenPrefixes = [
    "run=",   # linux_preload.nim `stampRunId` / macos_interpose.nim
  ]
  for prefix in RawSyscallUnsupportedPrefixes:
    if not detail.startsWith(prefix):
      continue
    let fields = detail[prefix.len .. ^1].splitWhitespace()
    if fields.len == 0:
      # "nr=" with nothing after it.
      return false
    for i in 1 ..< fields.len:
      var recognised = false
      for tokenPrefix in BenignTrailingTokenPrefixes:
        # ``len > tokenPrefix.len`` rejects a valueless "run=", which is
        # not a shape the stamper produces.
        if fields[i].startsWith(tokenPrefix) and fields[i].len > tokenPrefix.len:
          recognised = true
          break
      if not recognised:
        return false
    # Require a bare unsigned decimal, which is the only shape io-mon's
    # ``$number`` produces. ``parseInt`` alone is not enough: it accepts a
    # leading '+' or '-', so "nr=+436" would otherwise reach the allowlist.
    # A detail shape this classifier has not reasoned about fails closed.
    for ch in fields[0]:
      if ch notin {'0' .. '9'}:
        return false
    var number: int64
    try:
      # Rejects any value too large for ``int``; fails closed.
      number = int64(parseInt(fields[0]))
    except ValueError:
      return false
    return number in BenignRawSyscallNumbers
  false

# ---------------------------------------------------------------------------
# DA-2 — DERIVED IPC trust: the daemons THIS PROCESS spawned
# (Dependency-Observation-Attribution.md §Class 3, §"Derived beats declared";
#  Dependency-Attribution.milestones.org DA-2)
# ---------------------------------------------------------------------------
#
# THE SYMPTOM. An action that opens an IPC channel to a process outside its own
# monitored tree is graded `mcIncomplete`, so it never publishes a cache entry
# and rebuilds forever. io-mon already has the mechanism —
# `unmonitoredSubtreeLossDetails(records, trustedPeerPids)`, whose own comment
# describes a trusted peer as "a daemon that accounted for its own"
# contribution — and reprobuild passed an empty set, which is why the symptom
# was total rather than occasional.
#
# WHAT MAY BE TRUSTED, AND ONLY THAT. §Class 3 admits exactly two branches, and
# a daemon that satisfies NEITHER does not belong in the set however convenient:
#
#   (a) the peer contributes NO CONTENT to the action, or
#   (b) the peer serves CLASS-1 content — content-addressed bytes whose
#       identity is already in the action key by construction.
#
# WHY THE TRUST IS DERIVED AND NOT DECLARED. §"Derived beats declared": the
# engine SPAWNED the daemon, so it knows the pid as a fact rather than as
# someone's claim, and derived attribution cannot lie. That is why DA-2 lands
# before DA-4's declared trust, and it is why THERE IS NO CONFIGURATION FIELD,
# NO ALLOWLIST AND NO RECIPE SURFACE here: a `BuildEngineConfig` field naming a
# pid would be a declaration, and a declaration needs a check (rule 5) that this
# milestone deliberately does not build. The registry's only production writer
# is `trustDaemonWeSpawned`, whose argument is an `osproc.Process` — a value a
# caller can only hold by having spawned the process it names.
#
# SPAWN-ONLY IS A NARROW REACH, NOT A FORMALITY, and this file is the wrong
# place to learn how narrow: the answer depends on how the host is provisioned,
# so it is written at the ONE production registration site, in
# `repro_cli_support.startAutoRunQuotaIfNeeded`. Read it there before treating
# "reprobuild trusts runquotad" as a statement about any given build.
#
# AND THE PID IS RE-VALIDATED, so a RECYCLED pid cannot inherit trust. A bare
# pid is not an identity: a daemon that dies frees its number for the next
# process on the host, and on Linux the shim stamps NO `peerstart` token on
# `mrIpcConnect` (only macOS does), so io-mon's own (pid, start-time) test
# degrades to the bare pid for this record kind and cannot make the distinction
# for us. `TrustedDaemonPeer.identity` therefore carries the kernel's own answer
# — field 22 (`starttime`) of `/proc/<pid>/stat`, read AT REGISTRATION — and
# `revalidatedTrustedDaemons` re-reads it at grading time, on the way into the
# per-action attribution. A pid whose identity has changed, or whose process is
# gone, is dropped before it can exempt anything.

type
  TrustedDaemonContribution* = enum
    ## Which branch of §Class 3 a trusted daemon satisfies. Stated per daemon,
    ## at the spawn site, so the justification travels with the pid instead of
    ## living in a comment somewhere else.
    tdcNoContent
      ## Branch (a) — the peer contributes NO CONTENT to the action. Its side of
      ## the conversation is a decision or a measurement, never bytes that reach
      ## the action's output. `runquotad` is this case: it grants, queues and
      ## releases leases and accepts telemetry rows, and it never serves file
      ## content to a client (`runquota` protocol: Hello/Acquire/Grant/Release +
      ## the stats extension rows).
    tdcContentAlreadyKeyed
      ## Branch (b) — the peer serves CLASS-1 content: content-addressed blobs
      ## whose identity is already in the action key by construction, so
      ## monitoring the transfer re-derives what the key structurally
      ## guarantees. The repro store daemon is this case.

  TrustedDaemonOrigin* = enum
    ## How this process came to believe the fact. §"Derived beats declared"
    ## makes the distinction load-bearing rather than decorative: one of these
    ## cannot lie and the other can, so an exemption's diagnostic has to say
    ## which it was.
    tdoSpawned
      ## DERIVED (DA-2). This process started the daemon, so the pid is a fact
      ## it holds rather than a claim anyone made. The zero value, so every
      ## `TrustedDaemonPeer` written before DA-4 keeps its meaning.
    tdoDeclaredAndChecked
      ## DECLARED (DA-4). Someone named the daemon and a check independently
      ## established, from facts the kernel supplied, that the peer really is
      ## what was named. See `checkDeclaredDaemon` for exactly what that
      ## proves and — more importantly — what it does not.

  DaemonAssertion* = enum
    ## The assertions a declaration may make about a peer, each of which the
    ## check VERIFIES against the kernel and `revalidatedTrustedDaemons`
    ## RE-verifies at grading time. Modelled as a set so the zero value is
    ## `{}` — "nothing was asserted, so nothing has to be re-checked" — which
    ## is what keeps DA-2's derived peers (and every hand-built fixture value
    ## predating DA-4) meaning exactly what they meant before.
    daImage
      ## `/proc/<pid>/exe` — the file the peer is EXECUTING, resolved by the
      ## kernel. The strongest of the three, and the one a non-privileged
      ## process cannot obtain for a root-owned daemon (see
      ## `checkDeclaredDaemon`).
    daProgram
      ## `/proc/<pid>/stat` field 2 (`comm`). Kernel-recorded, world-readable,
      ## and — this matters — process-SETTABLE via `prctl(PR_SET_NAME)`. It
      ## narrows accidents, not attackers.
    daUid
      ## The peer's uid as `SO_PEERCRED` reports it. Un-forgeable: the kernel
      ## stamps it at connect time and no userspace end contributes to it.

  TrustedDaemonPeer* = object
    ## One trust fact. Public fields so a test can drive
    ## `revalidatedTrustedDaemons` with a hand-built value (which is how the
    ## recycled-pid rejection is graded); the REGISTRY that production reads is
    ## writable only through `trustDaemonWeSpawned` (derived) and
    ## `trustDaemonWeChecked` (declared), and the second of those takes a value
    ## only a completed check can produce.
    pid*: int
    identity*: string
      ## `/proc/<pid>/stat` field 22 at registration time, or "" where the host
      ## cannot supply one. An empty identity means "no re-validation is
      ## possible", which is treated as NOT trustworthy — the conservative
      ## direction, and the one that keeps a non-Linux host at today's
      ## behaviour instead of silently widening trust there.
    name*: string
    contribution*: TrustedDaemonContribution
    origin*: TrustedDaemonOrigin
    declaredSocket*: string
      ## DA-4 — the endpoint the declaration named, carried so the rule-3
      ## diagnostic can say WHERE the claim came from. Empty for a derived
      ## peer, which was not claimed anywhere.
    checked*: set[DaemonAssertion]
      ## DA-4 — which assertions the check VERIFIED. Every member is re-checked
      ## in `revalidatedTrustedDaemons`; a declaration that asserted something
      ## the check could not answer never reaches this type at all.
    checkedImage*: string
    checkedProgram*: string
    checkedUid*: int

proc processStartIdentity*(pid: int): string =
  ## The kernel's identity for a live pid: field 22 (`starttime`) of
  ## `/proc/<pid>/stat`, in clock ticks since boot. Empty when the process does
  ## not exist or the host does not publish it.
  ##
  ## Field 22 is read by counting from the END of the line, not from the start:
  ## field 2 is `comm` in parentheses and may itself contain spaces and
  ## parentheses (`(sh -c "a b")`), so a left-to-right split miscounts for a
  ## process whose name is adversarial. Everything after the closing `)` is
  ## whitespace-separated and fixed-arity, and `starttime` is the 20th of those,
  ## so the parse is anchored on `rfind(')')`.
  if pid <= 0:
    return ""
  when defined(linux):
    let statPath = "/proc/" & $pid & "/stat"
    var raw = ""
    try:
      if not fileExists(statPath):
        return ""
      raw = readFile(statPath)
    except CatchableError:
      return ""
    let close = raw.rfind(')')
    if close < 0:
      return ""
    let fields = raw[close + 1 .. ^1].splitWhitespace()
    # After `)` the fields are state(3) .. starttime(22): index 19 zero-based.
    if fields.len <= 19:
      return ""
    fields[19]
  else:
    ""

proc processImagePath*(pid: int): string =
  ## The file `pid` is EXECUTING, as the kernel resolves it: `/proc/<pid>/exe`.
  ## Empty when the host does not publish it, when the link cannot be read, or
  ## when the image has been unlinked since exec.
  ##
  ## TWO REFUSALS THAT MATTER, both of which fail closed:
  ##
  ## * **Permission.** `readlink("/proc/<pid>/exe")` needs
  ##   `PTRACE_MODE_READ_FSCREDS` — same uid, or `CAP_SYS_PTRACE`. So an
  ##   unprivileged `repro` CANNOT read this for a root-owned daemon, which is
  ##   exactly the shipped host-wide `runquotad` and the Nix daemon. That is a
  ##   real limit on how strong a declared check can be on the topology DA-4
  ##   exists for, and `checkDeclaredDaemon` refuses rather than degrades when
  ##   a declaration asserts an image it cannot read.
  ## * **A deleted image.** The kernel renders an unlinked executable as
  ##   `<path> (deleted)`. The peer is then running bytes that the declared
  ##   path no longer names, so the assertion "the peer executes THIS file" is
  ##   false however the strings compare. Refused, not stripped.
  if pid <= 0:
    return ""
  when defined(linux):
    try:
      let resolved = expandSymlink("/proc/" & $pid & "/exe")
      if resolved.len == 0 or resolved.endsWith(" (deleted)"):
        return ""
      resolved
    except CatchableError:
      ""
  else:
    ""

proc processCommName*(pid: int): string =
  ## `/proc/<pid>/stat` field 2 — the kernel's short name for the process,
  ## taken from the executable's basename at `execve` and truncated to 15
  ## bytes. World-readable, unlike `/proc/<pid>/exe`.
  ##
  ## Parsed between the FIRST `(` and the LAST `)` for the same reason
  ## `processStartIdentity` anchors on `rfind(')')`: `comm` may itself contain
  ## spaces and parentheses, so any split-based reading of this line is wrong
  ## for an adversarially named process.
  ##
  ## **NOT un-forgeable, and nothing here may pretend otherwise.**
  ## `prctl(PR_SET_NAME)` lets a process choose its own `comm`, so this
  ## assertion establishes that the peer CALLS ITSELF the declared name. It
  ## narrows accidents — some unrelated program listening at the declared path
  ## — and it does not bound an attacker who already runs code as the uid that
  ## may bind that path.
  if pid <= 0:
    return ""
  when defined(linux):
    var raw = ""
    try:
      let statPath = "/proc/" & $pid & "/stat"
      if not fileExists(statPath):
        return ""
      raw = readFile(statPath)
    except CatchableError:
      return ""
    let open = raw.find('(')
    let close = raw.rfind(')')
    if open < 0 or close <= open:
      return ""
    raw[open + 1 ..< close]
  else:
    ""

proc processEffectiveUid*(pid: int): int =
  ## The peer's EFFECTIVE uid right now, from `/proc/<pid>/status`'s `Uid:`
  ## line, or -1 where the host will not say.
  ##
  ## THE EFFECTIVE ONE AND NOT THE REAL ONE, because that is the field
  ## `SO_PEERCRED` reports: the kernel fills `struct ucred` at connect time
  ## from `current_euid()`. A re-check that read the REAL uid would compare a
  ## different quantity against `checkedUid` and would fire spuriously on any
  ## daemon that had ever changed one without the other. `/proc/<pid>/status`
  ## renders `Uid:` as four fields — real, effective, saved-set, filesystem —
  ## and the second is the one this returns.
  ##
  ## World-readable, unlike `/proc/<pid>/exe`: this is the same asymmetry
  ## `checkDeclaredDaemon` relies on, so the re-check is available on exactly
  ## the cross-uid topology where the image assertion is not.
  if pid <= 0:
    return -1
  when defined(linux):
    var raw = ""
    try:
      let statusPath = "/proc/" & $pid & "/status"
      if not fileExists(statusPath):
        return -1
      raw = readFile(statusPath)
    except CatchableError:
      return -1
    for line in raw.splitLines():
      if line.startsWith("Uid:"):
        let fields = line["Uid:".len .. ^1].splitWhitespace()
        if fields.len >= 2:
          try:
            return parseInt(fields[1])
          except ValueError:
            return -1
        return -1
    -1
  else:
    -1

var derivedTrustedDaemons: seq[TrustedDaemonPeer]
  ## Every daemon this process trusts as a class-3 IPC peer, derived (DA-2) and
  ## declared-and-checked (DA-4) alike, distinguished by `origin`. A
  ## process-global rather than a `BuildEngineConfig` field on purpose: DA-2
  ## had no declaration surface at all, and DA-4's surface is a MACHINE fact
  ## (`daemons.conf`) rather than a per-invocation knob — see
  ## `loadDeclaredDaemons` for why that layer and not another. It is written
  ## before a build starts and read on the scheduler thread; the worker pool
  ## never touches it.

proc trustDaemonWeSpawned*(process: Process; name: string;
                           contribution: TrustedDaemonContribution) =
  ## Register a daemon THIS PROCESS SPAWNED as a class-3 trusted IPC peer.
  ##
  ## The parameter is the live `Process` and not a bare pid, because that is the
  ## whole soundness argument in one type: a caller can only hold this value by
  ## having started the process, so "trust a daemon of the right name that
  ## someone else started" is not a call that can be written. Holding it also
  ## means the child has not been reaped, so the kernel will not hand its pid to
  ## anyone else while the registration is live — and `revalidatedTrustedDaemons`
  ## re-checks the identity anyway for the case where it has been.
  let pid = processID(process)
  if pid <= 0:
    return
  let identity = processStartIdentity(pid)
  if identity.len == 0:
    # No re-validatable identity ⇒ no trust. See `TrustedDaemonPeer.identity`.
    return
  for existing in derivedTrustedDaemons:
    if existing.pid == pid and existing.identity == identity:
      return
  derivedTrustedDaemons.add(TrustedDaemonPeer(pid: pid, identity: identity,
    name: name, contribution: contribution, origin: tdoSpawned))

proc forgetDerivedTrustedDaemons*() =
  ## Drop every registration, derived and declared alike. For test isolation,
  ## and for a caller that has torn its daemons down.
  derivedTrustedDaemons.setLen(0)

proc derivedTrustedDaemonRegistry*(): seq[TrustedDaemonPeer] =
  ## The DERIVED registrations only — DA-2's set, unchanged, so a test that
  ## grades spawn-only trust cannot be made to pass by a declaration.
  result = @[]
  for peer in derivedTrustedDaemons:
    if peer.origin == tdoSpawned:
      result.add(peer)

proc declaredTrustedDaemonRegistry*(): seq[TrustedDaemonPeer] =
  ## The DECLARED-AND-CHECKED registrations only — DA-4's set.
  result = @[]
  for peer in derivedTrustedDaemons:
    if peer.origin == tdoDeclaredAndChecked:
      result.add(peer)

proc trustedDaemonRegistry*(): seq[TrustedDaemonPeer] =
  ## Every trust fact this process holds, whatever its origin. THIS is what
  ## `collectEvidence` grades an action against; the two accessors above exist
  ## so a test can ask about one origin without the other answering for it.
  derivedTrustedDaemons

proc revalidatedTrustedDaemons*(peers: openArray[TrustedDaemonPeer]):
    seq[TrustedDaemonPeer] =
  ## The subset of `peers` the kernel still agrees with — asked RIGHT NOW,
  ## not at registration. A registration whose process has exited, or whose pid
  ## has been recycled onto a different process, contributes nothing.
  ##
  ## Returns the FACTS and not just the pids because rule 3 needs the `name`
  ## and the `contribution` at the point an exemption is granted: a diagnostic
  ## that cannot name the daemon it forgave, and cannot say which §Class 3
  ## branch let it, has counted the exemption without naming it.
  ##
  ## DA-4 — EVERY ASSERTION A DECLARATION'S CHECK VERIFIED IS RE-VERIFIED HERE,
  ## and the reason is that `(pid, start-time)` does not pin the PROGRAM. It
  ## pins the incarnation: `execve` preserves both, so a process that was
  ## `runquotad` when the check ran and has since exec'd into something else
  ## has the same pid and the same `starttime`, and a start-time-only
  ## re-validation would hand it the exemption. Re-reading `/proc/<pid>/exe`
  ## and `/proc/<pid>/stat`'s `comm` is what closes that.
  ##
  ## `daUid` IS RE-CHECKED TOO, AND AN EARLIER VERSION OF THIS COMMENT ARGUED
  ## IT NEED NOT BE. That argument ran: a surviving `(pid, start-time)` is the
  ## same process `SO_PEERCRED` answered for, and a process "can drop privileges
  ## but cannot acquire them", so the only drift is away from a privileged uid
  ## and re-checking could only reject, never protect. **MEASURED FALSE**
  ## (2026-09-11), sampling `/proc/<pid>` in a tight loop across an `execve`
  ## into setuid-root `sudo`:
  ##
  ##   t=0.000 pid=1183970 comm=execprobe2 starttime=4661947 uid=1007 euid=1007
  ##   t=0.158 pid=1183970 comm=sudo       starttime=4661947 uid=1007 euid=0
  ##
  ## Same pid, same field 22, euid raised in place. `execve` genuinely does
  ## preserve `starttime` — that half was right, and it is precisely why the
  ## preserved pair proves so much less than it looks like it proves. The
  ## general form does not even need an exec: a daemon that started as root and
  ## called `seteuid(user)` keeps root in its SAVED set-user-ID and may
  ## `seteuid(0)` back at any moment, with no exec, no new image and an
  ## unchanged `comm` — so it is the assertion the other two re-checks cannot
  ## stand in for.
  ##
  ## So every assertion the check verified is re-verified here, `daUid`
  ## included, against `/proc/<pid>/status`'s EFFECTIVE uid — the field
  ## `SO_PEERCRED` reported in the first place.
  ##
  ## The set is empty for every derived peer and for every value written before
  ## DA-4, so this loop is exactly DA-2's for them.
  result = @[]
  for peer in peers:
    if peer.pid <= 0 or peer.identity.len == 0:
      continue
    if processStartIdentity(peer.pid) != peer.identity:
      continue
    if daImage in peer.checked and
        (peer.checkedImage.len == 0 or
         processImagePath(peer.pid) != peer.checkedImage):
      continue
    if daProgram in peer.checked and
        (peer.checkedProgram.len == 0 or
         processCommName(peer.pid) != peer.checkedProgram):
      continue
    if daUid in peer.checked and
        (peer.checkedUid < 0 or
         processEffectiveUid(peer.pid) != peer.checkedUid):
      continue
    result.add(peer)

# ---------------------------------------------------------------------------
# DA-4 — DECLARED IPC trust, and the CHECK that makes it a claim
# (Dependency-Observation-Attribution.md §Class 3, §"Derived beats declared",
#  §"Where each declaration lives", rules 3/4/5;
#  Dependency-Attribution.milestones.org DA-4)
# ---------------------------------------------------------------------------
#
# WHAT DA-2 LEFT OPEN, AND WHY IT IS THE CASE THAT MATTERS. DA-2 trusts only a
# daemon THIS PROCESS SPAWNED. Measured, that is live only on an unprovisioned
# Linux host: on a host running the shipped `runquotad` unit,
# `startAutoRunQuotaIfNeeded` finds the host-wide socket already answered,
# adopts the daemon and registers nothing — so DA-2 is entirely inert on
# precisely the topology a shared lease coordinator exists for. Closing that
# means trusting a daemon this process did not start, which by
# §"Derived beats declared" is DECLARED attribution, and
# **a declared attribution needs a check** (rule 5).
#
# THE CHECKED-CLAIM PATTERN, WHICH IS THE POINT OF THE MILESTONE. A declaration
# NAMES a peer. A check must then establish, INDEPENDENTLY OF THE DECLARATION
# AND FROM FACTS THE DECLARER DOES NOT SUPPLY, that the peer really is what was
# named. The design constraint runs check-first: the declaration surface is
# whatever the check can actually verify, and nothing wider. Concretely, this
# is why there is no `contribution =` key below — see `class3Contribution`.
#
# WHAT THE KERNEL WILL VOUCH FOR, WHICH IS THE WHOLE BUDGET.
#
#   * `SO_PEERCRED` on a connected AF_UNIX socket yields the peer's
#     (pid, uid, gid) as of connect. The kernel stamps it; neither end
#     contributes to it; it cannot be forged from userspace. This is the
#     foundation, and it is the same fact io-mon's shim reads at the ACTION's
#     own connect — which is what binds the check to the observation, because
#     the exemption is keyed on that pid and on nothing else.
#   * `/proc/<pid>/stat` field 22 (`starttime`) distinguishes an incarnation
#     from a recycled pid. DA-2 already reads it; DA-4 reuses it verbatim.
#   * `/proc/<pid>/exe` names the file the peer executes — but only to a
#     reader with `PTRACE_MODE_READ_FSCREDS` (same uid, or `CAP_SYS_PTRACE`).
#   * `/proc/<pid>/stat` field 2 (`comm`) is world-readable and
#     process-settable.
#
# WHAT A CHECK CANNOT ESTABLISH, STATED BEFORE THE CODE BECAUSE IT BOUNDS EVERY
# CLAIM BELOW.
#
#   1. **That the declared program deserves trust.** Whether `runquotad`
#      contributes content is a semantic property of the program, and no
#      runtime probe answers it. That is why the class-3 branch is NOT
#      declarable (`class3Contribution` is a closed, compiled-in table) — an
#      operator who could assert a branch for an arbitrary binary would have an
#      exemption from reproducibility, not a declaration.
#   2. **That the socket path is trustworthy.** "Something is listening here"
#      is arrangeable by accident and by an attacker alike, and it is exactly
#      the check this code must not be. Every assertion below is about the
#      PEER, never about the path.
#   3. **That an unprivileged reader can identify a privileged daemon's
#      image.** `/proc/<pid>/exe` is unreadable across a uid boundary, so on
#      the shipped topology — root-owned `runquotad`, root-owned Nix daemon,
#      unprivileged `repro` — the strongest assertion is UNAVAILABLE and the
#      check rests on `daUid` (un-forgeable) plus `daProgram` (not). Declaring
#      an image that cannot be read is REFUSED, not degraded, so an operator
#      learns this from a report rather than from a silent weakening.
#   4. **That the peer the ACTION talked to is the peer the check connected
#      to** — except through the pid, which is precisely how it is established.
#      A socket re-bound by a different process yields a different peer pid at
#      the action's connect and is not in the trust set. A pid recycled onto a
#      different process fails `revalidatedTrustedDaemons`. Neither inherits
#      anything, and both are graded.
#   5. **That the channel the ACTION used is the ENDPOINT that was declared.**
#      THE RESIDUAL. READ THIS BEFORE WIDENING THE VOCABULARY.
#
#      A declaration names an endpoint; the exemption is keyed on a PID. io-mon
#      grants it with `peer in trustedPeerPids` and looks at no path at all
#      (io-mon `src/io_mon/writer.nim:1992-1994`), so what trust buys is
#      "everything this process serves", not "the endpoint that was declared".
#      Under DA-2 the two coincide because the engine spawned the daemon and
#      knows it end to end; under DA-4 they can come apart, and MEASURED they
#      do: on a socket-activated host pid 1 answers `/nix/var/nix/daemon-socket
#      /socket` AND `/run/dbus/system_bus_socket`, so declaring the first
#      registered a pid that forgave the second.
#
#      WHAT NARROWS IT, AND HOW FAR. Requiring a program-identifying assertion
#      (`declarationIdentifiesAProgram`) refuses the activator outright — pid
#      1's `comm` is `systemd`, not `nix-daemon` — and, more generally, turns
#      the trust fact from "pid P" into "pid P, executing declared program X".
#      That is the granularity the class-3 argument is actually stated at:
#      `class3Contribution` is a table from PROGRAM to branch, and "runquotad
#      serves lease decisions and no content" is a claim about the program,
#      true of every channel it serves. So once the program is identified, the
#      endpoint is a LOCATOR for finding the peer rather than a term in the
#      soundness argument, and forgiving X's other channels is forgiving what
#      the branch already licensed.
#
#      WHAT IS LEFT, STATED PLAINLY RATHER THAN IMPLIED. That reduction is
#      exactly as good as the program identification and as the branch table:
#
#        * `daProgram` is `comm`, which the peer sets (`prctl(PR_SET_NAME)`).
#          Against an attacker already running as the uid that may bind the
#          declared path, `program` alone identifies nothing — which is why the
#          documented shape for a privileged daemon is `program` + `uid`, and
#          why a host that can read `/proc/<pid>/exe` should declare `image`.
#        * A program admitted to the vocabulary whose branch is true of only
#          SOME of its channels would be forgiven on all of them. None of the
#          three admitted today is such a program: `runquotad` speaks one
#          lease/telemetry protocol on every endpoint it binds; the Nix daemon
#          and the repro store daemon serve content-addressed store paths on
#          every endpoint they bind. **A fourth kind must be argued at the
#          PROGRAM level, not at the endpoint level, or this residual becomes a
#          hole.**
#
#      THE EXACT FIX, AND WHY IT IS NOT HERE. Keying the exemption on
#      `(pid, endpoint)` would remove the residual outright. It cannot be done
#      from this repository: on Linux `mrIpcConnect` carries no usable path —
#      io-mon's `recordIpcConnect` never sets `record.path` there — so the
#      dedup key io-mon builds for a peer-attributed loss is `pid:<peer>@<start>`
#      with no path term, and the engine has nothing to match an endpoint
#      against. It needs an io-mon change (carry the connect path on Linux),
#      after which this file can compare it to `declaredSocket`, which is
#      already recorded on every declared `TrustedDaemonPeer` for exactly that
#      day. Until then the residual is REAL, BOUNDED BY THE PROGRAM, and
#      graded: see `t_declared_daemon_ipc_trust`'s two-endpoint case, whose
#      second arm asserts the forgiveness of an undeclared endpoint of a
#      declared PROGRAM — so that narrowing this later shows up as a red case
#      to update rather than as a silent change of meaning.
#
# AND CLASS 4 IS NOT REACHABLE FROM HERE (rule 4). A declaration's endpoint
# must be an absolute filesystem path, and `SO_PEERCRED` on anything that is
# not an AF_UNIX socket yields no pid — `checkDeclaredDaemon` refuses pid <= 0
# outright. On the observation side io-mon's own exemption requires
# `peer != 0` (io-mon `writer.nim:1992`) and an INET connect reports peer 0, so
# a network peer stays unattributable whatever this registry contains.

type
  DeclarableDaemonKind* = enum
    ## The CLOSED vocabulary of daemons that may be declared, and the reason it
    ## is closed rather than a name plus a contribution field.
    ##
    ## §Class 3 admits a peer on one of two grounds — it contributes no
    ## content, or it serves content already in the key — and BOTH are claims
    ## about what a program DOES. Nothing the engine can probe at runtime
    ## decides them. So the branch travels with the daemon KIND, compiled in
    ## here beside the argument for it, exactly as `tdcNoContent` travels with
    ## `runquotad` at DA-2's spawn site. What the machine layer supplies is
    ## WHERE the daemon is, which is the part the machine actually knows.
    ##
    ## An unrecognised section name in `daemons.conf` is an ERROR, not an
    ## ignored line: a typo that silently declared nothing would be a
    ## declaration rotting into a no-op, which is the failure mode DA-4's third
    ## test exists to prevent.
    ddkRunQuota
      ## `runquotad` reached over an endpoint this process did not create —
      ## the host-wide `/run/runquota/runquotad.sock` the shipped unit owns,
      ## or an endpoint inherited through `RUNQUOTA_SOCKET`. THE DA-2 GAP.
    ddkNixDaemon
      ## The Nix daemon at `/nix/var/nix/daemon-socket/socket`.
    ddkReproStoreDaemon
      ## reprobuild's own store daemon (`repro store daemon`,
      ## `repro_store_daemon.defaultDevEndpoint`). DA-2 verified that it
      ## satisfies branch (b) and declined it for want of a spawn to derive
      ## from; under a declared-and-checked regime that objection is answered.

  DaemonCheckOutcome* = enum
    ## Why a declaration was or was not turned into a trust fact. Every value
    ## other than `dcoTrusted` is REPORTED — rule 3's "counted and named",
    ## applied to the declarations as well as to the exemptions.
    ##
    ## `dcoNotChecked` IS FIRST, AND THE ORDER IS THE POINT. Nim's zero value
    ## for an enum is its first member, so whichever value sits here is what a
    ## default-constructed `DaemonIdentityCheck` or `DaemonCheckReport` claims
    ## about a peer nobody asked about. With `dcoTrusted` first — which is how
    ## this enum shipped — an un-run check ANNOUNCED A PASS, and
    ## `renderDaemonCheckReport` rendered a zero `DaemonCheckReport` as
    ## "checked and trusted". The safe default has to be the absence of a
    ## verdict, so it is.
    ##
    ## Reordering was verified safe rather than assumed: EVERY use of this
    ## type is `==`, `!=`, `$` or a type annotation — no `ord`, no `succ`, no
    ## indexing, no `<`, no iteration over the enum and no persistence of an
    ## ordinal, so nothing reads the member positions. Keep it that way; the
    ## moment one does, this member's position becomes a wire fact.
    ##
    ## WHERE THE USES ARE: this module and
    ## `tests/integration/t_declared_daemon_ipc_trust.nim`, and nowhere else.
    ## The CLI is NOT a third site — it holds a `DaemonCheckReport` and renders
    ## it, and names neither this type nor any member of it — so a sweep that
    ## goes looking for one there will not find it and should not conclude it
    ## missed something.
    ##
    ## NO COUNT IS STATED, DELIBERATELY — AND NOT BECAUSE THE ONE THAT USED TO
    ## STAND HERE HAD ROTTED. It had not. MEASURED (2026-09-11) across both
    ## files with comments and string literals stripped, "all 56 uses" is still
    ## exactly right — 29 here and 27 in the suite — as it was at `88e3b7e7`
    ## where it was written. The number is dropped because it is a SECOND
    ## claim, one that has to be re-established on every edit, standing beside
    ## the claim that actually carries the argument and can be checked by
    ## reading: that no use reads a member POSITION. Count it yourself when you
    ## re-run the sweep. THE TRAP WHEN YOU DO —
    ## `DependencyOutputKind`'s members share the `dco` prefix
    ## (`dcoReproPathSet`, `dcoRecognizedFormat`) and ARE read ordinally, in
    ## `repro_domain_types/codec.nim` and the CLI's copy of that decoder. Sweep
    ## by TYPE, not by member prefix; a `grep "ord(dco"` hits the other enum
    ## and reports a dependency this one does not have.
    dcoNotChecked
      ## No check has run. The zero value, and never an answer: nothing
      ## produces it, `trustDaemonWeChecked` refuses it, and it renders as
      ## "not checked".
    dcoTrusted
    dcoEndpointNotAbsolute
      ## The endpoint is not an absolute path, so it does not name an AF_UNIX
      ## socket this code can obtain a peer credential from. Rule 4's shape at
      ## the declaration surface: an `host:port` endpoint is refused here
      ## rather than connected to and found unattributable later.
    dcoUnreachable
      ## Nothing accepted a connection. A declaration for a daemon that is not
      ## running is not an error, but it must not be silent either — a stale
      ## declaration that nobody notices is a permanent exemption waiting for
      ## a pid collision.
    dcoNoPeerCredentials
      ## Connected, but the kernel would not name a peer. Includes every
      ## non-AF_UNIX transport that somehow got this far.
    dcoNoKernelIdentity
      ## No `/proc/<pid>/stat` start time, so the trust could never be
      ## re-validated. Every non-Linux host is here today, deliberately.
    dcoNothingAsserted
      ## The declaration named an endpoint and asserted nothing about the peer.
      ## Refused: "something is listening at this path" is not a check.
    dcoNoProgramAssertion
      ## The declaration asserted something about the peer, but nothing that
      ## IDENTIFIES THE PROGRAM it is running — `uid` alone, in practice.
      ## Refused before a connection is attempted. See
      ## `declarationIdentifiesAProgram` for the whole argument.
    dcoImageUnreadable
      ## `image` was asserted and `/proc/<pid>/exe` could not be read — the
      ## cross-uid case above. Refused rather than degraded.
    dcoImageMismatch
    dcoProgramMismatch
    dcoUidMismatch

  DeclaredDaemon* = object
    ## One parsed `daemons.conf` section. A DECLARATION and nothing more: no
    ## field of it is believed until `checkDeclaredDaemon` has answered.
    kind*: DeclarableDaemonKind
    endpoint*: string
      ## Where the daemon listens. Absolute path to an AF_UNIX socket.
    assertions*: set[DaemonAssertion]
    image*: string
    program*: string
    uid*: int
    source*: string
      ## Which file said so, carried into the report so an operator chasing a
      ## refused declaration is told where to edit.

  DaemonIdentityCheck* = object
    ## THE RESULT OF A CHECK, and the only thing `trustDaemonWeChecked` accepts.
    ##
    ## THE FIELDS ARE PRIVATE ON PURPOSE, and it is the same device DA-2 used
    ## when it made `trustDaemonWeSpawned` take an `osproc.Process`: a caller
    ## outside this module can write `DaemonIdentityCheck()` but cannot fill
    ## it, and the zero value carries `outcome = dcoNotChecked` with `pid = 0`
    ## and `verified = {}` — which `trustDaemonWeChecked` refuses on all three
    ## counts. So "trust a peer whose check I did not run" is not a call that
    ## can be written, and a declaration cannot reach the registry except
    ## through the code below.
    outcome: DaemonCheckOutcome
    pid: int
    uid: int
    identity: string
    image: string
    program: string
    verified: set[DaemonAssertion]
    endpoint: string
    detail: string

  DaemonCheckReport* = object
    ## What happened to one declaration, for the build log. Its zero value
    ## carries `dcoNotChecked` and therefore renders as "not checked"; before
    ## `dcoNotChecked` existed it rendered as "checked and trusted", which is a
    ## default-constructed value asserting the strongest thing this type can
    ## say.
    kind*: DeclarableDaemonKind
    endpoint*: string
    outcome*: DaemonCheckOutcome
    detail*: string
    source*: string

proc class3BranchText(contribution: TrustedDaemonContribution): string =
  ## The §Class 3 branch a trusted daemon satisfies, in the words the operator
  ## reading a build log needs — "why was this allowed to be forgiven".
  ##
  ## Defined here rather than beside its first DA-2 consumer because DA-4's
  ## declaration report needs the same sentence, and two spellings of "which
  ## branch let this through" is the shape a later reader has to reconcile.
  case contribution
  of tdcNoContent:
    "branch (a), contributes no content to the action"
  of tdcContentAlreadyKeyed:
    "branch (b), serves class-1 content already in the action key"

proc daemonKindName*(kind: DeclarableDaemonKind): string =
  ## The name a `daemons.conf` section carries, and the name a diagnostic
  ## prints. One function so the two cannot drift.
  case kind
  of ddkRunQuota: "runquotad"
  of ddkNixDaemon: "nix-daemon"
  of ddkReproStoreDaemon: "repro-store-daemon"

proc parseDaemonKind*(name: string): Option[DeclarableDaemonKind] =
  for kind in DeclarableDaemonKind:
    if daemonKindName(kind) == name:
      return some(kind)
  none(DeclarableDaemonKind)

proc class3Contribution*(kind: DeclarableDaemonKind):
    TrustedDaemonContribution =
  ## WHICH §Class 3 BRANCH EACH DECLARABLE DAEMON SATISFIES. Compiled in, one
  ## arm per kind, because this is the half of the attribution that no check
  ## can establish and no operator may assert (see the header above).
  case kind
  of ddkRunQuota:
    ## BRANCH (a) — contributes NO CONTENT. Its protocol is
    ## Hello / Acquire / Grant / Release plus the stats-extension rows: lease
    ## decisions and telemetry. It opens no file on a client's behalf and
    ## returns no bytes that can reach an action's output. Identical to the
    ## argument DA-2 makes at its spawn site, and it does not depend on WHO
    ## started the daemon — which is why the same branch holds for an adopted
    ## one, and why the only thing DA-4 has to add is the identity check.
    tdcNoContent
  of ddkNixDaemon:
    ## BRANCH (b) — serves CLASS-1 content. Every byte it hands back is a
    ## `/nix/store/<hash>-<name>` path, and §Class 1 is exactly the statement
    ## that such a path names its own content and its identity is already in
    ## the action key by construction. `contentAddressedRoot` in this file
    ## recognises that root, `toolInputRoots` elides under it and
    ## `keyedOnContentAddressedToolRoot` keys on it — so the elision this
    ## branch licenses is the SAME elision the store already gets, reached
    ## through the daemon instead of through the filesystem. §Class 3 names
    ## this daemon explicitly.
    tdcContentAlreadyKeyed
  of ddkReproStoreDaemon:
    ## BRANCH (b), for the same reason and over reprobuild's own CAS store:
    ## it realizes and serves prefixes under
    ## `<storeRoot>/…/prefixes/<package>/<version>-<16 hex>`, the second root
    ## `contentAddressedRoot` recognises. DA-2's text names it and DA-2
    ## declined to register it because nothing spawns it — which is a statement
    ## about DERIVATION, not about the branch, and is what a checked
    ## declaration answers.
    tdcContentAlreadyKeyed

when defined(linux):
  type
    SocketPeerCredentials = object
      ## The ABI of `struct ucred` on Linux: `pid_t`, `uid_t`, `gid_t`, all
      ## 32-bit on every architecture Nim targets here.
      ##
      ## Declared rather than `importc`'d, and the reason is specific:
      ## `struct ucred` is behind `__USE_GNU` in glibc's `<sys/socket.h>`, so
      ## importing it would require this file to be compiled with
      ## `-D_GNU_SOURCE` — a translation-unit-wide change to satisfy one
      ## struct. The CONSTANT is not behind that guard, so `SO_PEERCRED` and
      ## `SOL_SOCKET` are imported from the header and only the layout is
      ## restated.
      pid: int32
      uid: uint32
      gid: uint32

  var
    SoPeerCredOpt {.importc: "SO_PEERCRED", header: "<sys/socket.h>".}: cint
    SolSocketLevel {.importc: "SOL_SOCKET", header: "<sys/socket.h>".}: cint

  proc getsockoptRaw(sock: cint; level, optname: cint; optval: pointer;
                     optlen: ptr cuint): cint
                    {.importc: "getsockopt", header: "<sys/socket.h>".}

proc peerCredentialsOfSocket(sock: Socket): tuple[pid, uid: int] =
  ## The kernel's record of the peer's identity on a connected socket, or
  ## `(0, 0)` when it will not supply one.
  ##
  ## THE ONE FACT THIS WHOLE MILESTONE STANDS ON. `SO_PEERCRED` is stamped by
  ## the kernel at connect time from the peer's credentials — its pid and its
  ## EFFECTIVE uid/gid; no byte of it crosses the wire and neither end can
  ## influence it. It is also the SAME mechanism io-mon's shim reads at the
  ## monitored action's own connect (`linux_preload.channelPeerPid`), which is
  ## what lets a pid checked here be compared against a pid observed there at
  ## all. `revalidatedTrustedDaemons` re-reads the effective uid from
  ## `/proc/<pid>/status` for the same reason it is the effective one here.
  ##
  ## AN AF_INET SOCKET DOES NOT FAIL THIS CALL — it SUCCEEDS and answers with a
  ## nobody. MEASURED (2026-09-11) on a connected loopback AF_INET socket:
  ##
  ##   getsockopt rc=0 errno=0 len=12 pid=0 uid=-1 gid=-1
  ##
  ## `rc` is 0 and `optlen` comes back the full `sizeof(struct ucred)`, so
  ## NEITHER guard below is what refuses it — the refusal is `pid == 0` and the
  ## `pid <= 0` arm in `checkDeclaredDaemon` that reads it. An earlier version
  ## of this comment said the `getsockopt` fails. The behaviour is the same
  ## either way, which is exactly why the sentence had to be corrected rather
  ## than left: the next person changing this function will reason from it, and
  ## "the call fails" licenses removing the `pid <= 0` test as redundant.
  ## Rule 4 is held by the pid being zero, not by an error return.
  result = (0, 0)
  when defined(linux):
    var cred = SocketPeerCredentials()
    var size = cuint(sizeof(SocketPeerCredentials))
    if getsockoptRaw(cint(sock.getFd()), SolSocketLevel, SoPeerCredOpt,
        addr cred, addr size) != 0:
      return
    if size.int < sizeof(SocketPeerCredentials):
      return
    result = (int(cred.pid), int(cred.uid))

const ProgramIdentifyingAssertions* = {daImage, daProgram}
  ## The assertions that name WHAT THE PEER IS RUNNING, as opposed to what it
  ## is running AS. `checkDeclaredDaemon` requires at least one; see
  ## `declarationIdentifiesAProgram`.

proc declarationIdentifiesAProgram*(decl: DeclaredDaemon): bool =
  ## Does this declaration assert anything that identifies the peer's PROGRAM?
  ##
  ## WHY THIS IS REQUIRED, AND WHY `uid` ALONE IS NOT A CHECK OF THE THING
  ## §Class 3 IS ABOUT. A class-3 exemption is licensed by a claim about a
  ## PROGRAM: `runquotad` serves lease decisions and no content; the Nix daemon
  ## serves `/nix/store/<hash>-<name>` paths whose identity is already in the
  ## key. `class3Contribution` is a table from PROGRAM to branch. A check that
  ## establishes only "the peer runs as uid 0" has established nothing about
  ## the subject of that claim — every root daemon on the box satisfies it —
  ## so it cannot make the claim true, and rule 5's "a declared attribution has
  ## a check" is not discharged by a check of something else.
  ##
  ## MEASURED, AND THIS IS WHY IT IS A HARD REFUSAL RATHER THAN ADVICE. On a
  ## socket-activated host the process on the far end of a daemon's socket is
  ## the ACTIVATOR, not the daemon:
  ##
  ##   /nix/var/nix/daemon-socket/socket   peer pid=1 uid=0 comm=systemd
  ##   /run/dbus/system_bus_socket         peer pid=1 uid=0 comm=systemd
  ##
  ## A `uid = 0` declaration of `nix-daemon` at the first path passes, and what
  ## it registers is **pid 1** — after which an action that touches D-Bus, or
  ## anything else pid 1 serves, is forgiven and publishes. That was measured
  ## end to end on this host: the declaration passed, pid 1 was registered, and
  ## an unrelated D-Bus edge published and warm-hit. Requiring a
  ## program-identifying assertion is what refuses it, and it refuses it
  ## precisely: `comm` on pid 1 is `systemd`, so `program = nix-daemon` fails
  ## with `dcoProgramMismatch` and the endpoint simply cannot be declared on
  ## that topology. That is the correct answer — the peer really is not the
  ## daemon — and it is a report rather than a silent exemption.
  ##
  ## WHAT IT COSTS. `uid`-only was the only form that worked for a root-owned
  ## daemon read from an unprivileged `repro`, because `image` is unreadable
  ## across a uid boundary (`processImagePath`). What is left there is
  ## `program`, which is kernel-recorded and world-readable but SETTABLE by the
  ## peer via `prctl(PR_SET_NAME)` — it narrows accidents, not attackers. So
  ## the shipped shape for a privileged daemon is `program` + `uid`: `program`
  ## identifies the subject of the class-3 claim, `uid` is the un-forgeable
  ## half, and neither is redundant. Declaring `uid` alone is refused; the
  ## refusal is `dcoNoProgramAssertion` and it happens BEFORE any connection,
  ## so a declaration that cannot discharge rule 5 never even touches the
  ## daemon.
  (decl.assertions * ProgramIdentifyingAssertions) != {}

proc checkDeclaredDaemon*(decl: DeclaredDaemon): DaemonIdentityCheck =
  ## THE CHECK. Connect to the declared endpoint, ask the KERNEL who is on the
  ## other end, and verify every assertion the declaration made against what
  ## the kernel said. Nothing the declaration supplied is used as evidence for
  ## itself.
  ##
  ## Order matters and is deliberate: the endpoint shape and the ADEQUACY OF
  ## THE ASSERTIONS are refused before a connection is attempted, the peer
  ## credential is obtained before any `/proc` read (so a pid of 0 never
  ## becomes a path), and every assertion is a conjunction — one mismatch
  ## refuses the whole declaration rather than trusting the remainder.
  ##
  ## `dcoNothingAsserted` and `dcoNoProgramAssertion` are the two arms that
  ## keep this from being theatre. A declaration carrying only an endpoint
  ## would make "a socket exists at this path" the whole check, and a socket
  ## path is arrangeable by anyone who can write the directory — the exact
  ## shape §"Derived beats declared" calls a wish. A declaration carrying only
  ## a `uid` would make "a root process is listening here" the whole check,
  ## which identifies no program and therefore checks nothing about the claim
  ## §Class 3 actually licenses; see `declarationIdentifiesAProgram`, which
  ## carries the measurement that forced it.
  ##
  ## WHAT IT COSTS THE DAEMON: one accepted connection, closed immediately,
  ## once per declared daemon per build. No protocol is spoken, because the
  ## kernel supplies the peer credential the moment the connection is accepted
  ## and nothing a daemon could SAY would add a fact — a self-reported name is
  ## the declaration again, not a check of it. Every daemon in the closed
  ## vocabulary is an accept-loop server and tolerates an immediate disconnect.
  result.endpoint = decl.endpoint
  if not decl.endpoint.isAbsolute:
    result.outcome = dcoEndpointNotAbsolute
    result.detail = "endpoint is not an absolute path to a unix socket"
    return
  if decl.assertions == {}:
    result.outcome = dcoNothingAsserted
    result.detail = "declaration asserts nothing about the peer; " &
      "'something is listening at this path' is not a check"
    return
  if not decl.declarationIdentifiesAProgram():
    result.outcome = dcoNoProgramAssertion
    result.detail = "declaration asserts nothing that identifies the peer's " &
      "program (declare 'image' or 'program'); the §Class 3 branch is a " &
      "property of the PROGRAM, so a check that identifies no program has " &
      "not established what the branch is about — on a socket-activated host " &
      "the peer of a daemon socket is the activator, and a uid-only " &
      "declaration would trust everything the activator serves"
    return
  var sock: Socket
  try:
    sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
      protocol = IPPROTO_IP)
  except CatchableError:
    result.outcome = dcoUnreachable
    result.detail = "cannot create an AF_UNIX socket"
    return
  var connected = false
  try:
    sock.connectUnix(decl.endpoint)
    connected = true
  except CatchableError:
    result.outcome = dcoUnreachable
    result.detail = "nothing accepted a connection at " & decl.endpoint
  if connected:
    let cred = peerCredentialsOfSocket(sock)
    result.pid = cred.pid
    result.uid = cred.uid
    if result.pid <= 0:
      result.outcome = dcoNoPeerCredentials
      result.detail =
        "the kernel would not name a peer for " & decl.endpoint &
        " (SO_PEERCRED yields no pid for anything but an AF_UNIX socket)"
  try:
    sock.close()
  except CatchableError:
    discard
  if result.outcome != dcoNotChecked or not connected:
    return
  result.identity = processStartIdentity(result.pid)
  if result.identity.len == 0:
    result.outcome = dcoNoKernelIdentity
    result.detail = "no kernel start-time identity for pid " & $result.pid &
      "; the trust could not be re-validated at grading time"
    return
  # `/proc/<pid>/exe` and `comm` are read ONCE here and re-read in
  # `revalidatedTrustedDaemons`. Reading them after the start-time identity is
  # what makes the pair coherent: the identity says which incarnation the
  # readings describe.
  result.image = processImagePath(result.pid)
  result.program = processCommName(result.pid)
  if daImage in decl.assertions:
    if result.image.len == 0:
      result.outcome = dcoImageUnreadable
      result.detail = "cannot read /proc/" & $result.pid & "/exe (a " &
        "cross-uid read needs CAP_SYS_PTRACE, and an unlinked image is " &
        "refused outright); declare 'program' (with 'uid') instead of " &
        "'image' for a daemon running as another user"
      return
    # The DECLARED path is canonicalised before the comparison, because
    # `/proc/<pid>/exe` is the kernel's fully-resolved answer and a provisioned
    # host names its daemons through symlinks — `/run/current-system/sw/bin/…`
    # on NixOS, `/usr/bin/…` into an alternatives tree elsewhere. Without this
    # the strongest assertion would be unusable on exactly the topology DA-4
    # exists for. It does not weaken the check: the comparison TARGET is still
    # the kernel's reading, and canonicalising the claim only decides which
    # file the claim is about.
    var expected = decl.image
    try:
      expected = expandFilename(decl.image)
    except CatchableError:
      discard
    if result.image != expected:
      result.outcome = dcoImageMismatch
      result.detail = "peer pid " & $result.pid & " executes " & result.image &
        ", not the declared " & decl.image &
        (if expected == decl.image: "" else: " (resolving to " & expected & ")")
      return
    result.verified.incl(daImage)
  if daProgram in decl.assertions:
    if result.program.len == 0 or result.program != decl.program:
      result.outcome = dcoProgramMismatch
      result.detail = "peer pid " & $result.pid & " reports comm '" &
        result.program & "', not the declared '" & decl.program & "'"
      return
    result.verified.incl(daProgram)
  if daUid in decl.assertions:
    if result.uid != decl.uid:
      result.outcome = dcoUidMismatch
      result.detail = "peer pid " & $result.pid & " runs as uid " &
        $result.uid & ", not the declared " & $decl.uid
      return
    result.verified.incl(daUid)
  # THE PASS IS STATED, NEVER INHERITED. Every arm above leaves this proc with
  # `dcoNotChecked` still in place unless it set a refusal, so reaching here —
  # having verified every assertion the declaration made — is the only way
  # `dcoTrusted` is ever written. A future arm that returns early without
  # setting an outcome therefore reports "not checked" and is refused, rather
  # than falling through to the enum's zero value and reporting a pass.
  result.outcome = dcoTrusted
  result.detail = "peer pid " & $result.pid & " verified: " &
    ($result.verified).replace("{", "").replace("}", "")

# Read-only accessors. The FIELDS stay private so nothing outside this module
# can construct — or complete — a passing check; the READINGS are published
# because the report and the tests both need them, and publishing a reading
# grants no ability to produce one.
proc checkedDaemonPid*(check: DaemonIdentityCheck): int = check.pid
proc checkedDaemonOutcome*(check: DaemonIdentityCheck): DaemonCheckOutcome =
  check.outcome
proc checkedDaemonDetail*(check: DaemonIdentityCheck): string = check.detail
proc checkedDaemonAssertions*(check: DaemonIdentityCheck):
    set[DaemonAssertion] = check.verified
proc checkedDaemonIdentity*(check: DaemonIdentityCheck): string =
  ## Published so a test can establish that a REFUSED check still carries every
  ## other field `trustDaemonWeChecked`'s guard reads — which is what makes the
  ## `outcome` clause of that guard gradeable in isolation.
  check.identity

proc trustDaemonWeChecked*(kind: DeclarableDaemonKind;
                           check: DaemonIdentityCheck): bool
                          {.discardable.} =
  ## Register a DECLARED daemon whose CHECK PASSED as a class-3 trusted peer.
  ##
  ## The parameter is the check's own result, and the type's fields are private
  ## to this module, so a caller cannot hand in a pass it did not obtain. That
  ## is the structural half of rule 5: the declaration cannot reach the registry
  ## except through the check.
  ##
  ## The class-3 branch comes from `kind` and never from the caller, so the one
  ## thing a check cannot establish is also the one thing nobody may assert.
  ##
  ## THE GUARD BELOW IS THE FLOOR UNDER THE CALLER'S GATE, AND IT IS GRADED AS
  ## SUCH. `applyDeclaredDaemonTrust` also tests `outcome == dcoTrusted` before
  ## calling, so on the production path this guard is a second opinion — but it
  ## is the one that answers for any OTHER caller, including one that hands in
  ## a default-constructed value.
  ##
  ## It was once not graded at all: a mutation deleting the `outcome`,
  ## `identity` and `verified` clauses and keeping only `pid <= 0` left all 13
  ## cases of `t_declared_daemon_ipc_trust` green, because every check the
  ## suite could reach this call with was either a pass or had `pid == 0`. The
  ## case *"a refused check is refused HERE, not only by its caller"* closes
  ## that: it drives the REAL `checkDeclaredDaemon` to a refusal that carries
  ## `pid > 0`, a non-empty `identity` and a non-empty `verified` — a correct
  ## `image` with a wrong `program` produces exactly that — so the `outcome`
  ## clause is the only thing left that can refuse it, and deleting the clauses
  ## reddens.
  ##
  ## The type is the other reason the clauses stay. `DaemonIdentityCheck`'s
  ## zero value is `dcoNotChecked` / `pid = 0` / `verified = {}`, so an un-run
  ## check is refused three times over rather than once.
  if check.outcome != dcoTrusted or check.pid <= 0 or
      check.identity.len == 0 or check.verified == {}:
    return false
  for existing in derivedTrustedDaemons:
    if existing.pid == check.pid and existing.identity == check.identity and
        existing.origin == tdoDeclaredAndChecked:
      return true
  derivedTrustedDaemons.add(TrustedDaemonPeer(
    pid: check.pid,
    identity: check.identity,
    name: daemonKindName(kind),
    contribution: class3Contribution(kind),
    origin: tdoDeclaredAndChecked,
    declaredSocket: check.endpoint,
    checked: check.verified,
    checkedImage: check.image,
    checkedProgram: check.program,
    checkedUid: check.uid))
  true

# --- Where the declaration lives -------------------------------------------
#
# §"Where each declaration lives" gives three layers and says what each one
# KNOWS: the workspace/machine layer knows which roots are content-addressed,
# the tool package knows what a tool does, and the project recipe declares
# NOTHING about monitoring. A host-wide daemon socket is a MACHINE fact — it is
# a property of how this box was provisioned, not of any project built on it,
# and the same recipe must build identically on a box that has no such daemon.
# So the declaration is a machine/user config file and there is deliberately:
#
#   * no `repro.nim` surface — a recipe author must never learn that
#     `runquotad` exists, for the same reason they must not learn that nim
#     reads its stdlib through the store;
#   * no `BuildEngineConfig` field and no command-line flag — those are
#     per-invocation, and "which daemons this host runs" is not;
#   * no environment variable that NOMINATES a daemon. `REPRO_DAEMONS_CONFIG`
#     selects a FILE (which is how the tests reach it) and cannot by itself
#     assert anything about a peer; the file still has to declare, and the
#     declaration still has to pass the check. `isImmutablePackageStoreRoot`
#     in `repro_local_store` records what an ambient variable that nominates
#     an exemption actually cost — a transient value permanently poisoned a
#     record — and that failure mode is why this one selects a file rather
#     than naming a socket.
#
# The layering mirrors `caches_config.nim`, which is the same shape one
# problem over: a system file, then a per-user file that extends and overrides
# it by name, and a default of trusting NOTHING. A user file may declare
# because the exemption it can buy is bounded twice over — by the check, and by
# the fact that a user's declaration only ever affects that user's own builds.

const
  DaemonTrustSystemConfigPath* = "/etc/repro/daemons.conf"
  DaemonTrustUserConfigRelPath* = "repro/daemons.conf"
  DaemonTrustConfigEnvVar* = "REPRO_DAEMONS_CONFIG"

type
  DaemonDeclarationError* = object of CatchableError
    ## A malformed declaration. Raised rather than skipped: an unreadable
    ## declaration that silently declared nothing is the "stale declaration
    ## rots into a permanent no-op" failure this milestone is asked to prevent,
    ## pointed the other way.

proc declarableDaemonNames*(): string =
  ## The declarable vocabulary as a diagnostic renders it, DERIVED from the
  ## enum and from `daemonKindName` rather than restated.
  ##
  ## It was restated once, and the failure mode is the reason this proc exists:
  ## the "unknown daemon" error carried the literal string "runquotad,
  ## nix-daemon, repro-store-daemon", so a fourth `DeclarableDaemonKind` would
  ## have left the sentence telling an operator that their perfectly valid
  ## section name is not declarable — with every case in the suite green,
  ## because nothing compared the sentence to the vocabulary. `daemonKindName`
  ## is the single source of truth everywhere else; now it is here too, and the
  ## suite grades the derivation by requiring every member's name to appear.
  var names: seq[string] = @[]
  for kind in DeclarableDaemonKind:
    names.add(daemonKindName(kind))
  names.join(", ")

proc parseDeclaredDaemonSections(text, source: string): seq[DeclaredDaemon] =
  ## Parse one `daemons.conf`. Every key is known or the file is refused —
  ## a typo must not become a default.
  result = @[]
  var stream = newStringStream(text)
  var parser: CfgParser
  open(parser, stream, source)
  defer: parser.close()
  var current = -1
  while true:
    let event = parser.next()
    case event.kind
    of cfgEof:
      break
    of cfgSectionStart:
      var name = event.section.strip()
      # `[daemon runquotad]` is accepted as sugar for `[runquotad]`, the same
      # allowance `caches_config` makes, because `std/parsecfg` section headers
      # cannot carry quotes.
      if name.startsWith("daemon "):
        name = name["daemon ".len .. ^1].strip()
      let kind = parseDaemonKind(name)
      if kind.isNone:
        raise newException(DaemonDeclarationError,
          source & ": unknown daemon '" & name & "'. Declarable daemons are " &
          declarableDaemonNames() & " — the class-3 branch is " &
          "compiled in per daemon and cannot be asserted by configuration.")
      result.add(DeclaredDaemon(kind: kind.get(), source: source, uid: -1))
      current = result.high
    of cfgKeyValuePair, cfgOption:
      if current < 0:
        raise newException(DaemonDeclarationError,
          source & ": key '" & event.key & "' appears before any [daemon] " &
          "section")
      let value = event.value.strip()
      case event.key.strip().toLowerAscii()
      of "socket", "endpoint":
        result[current].endpoint = value
      of "image":
        result[current].image = value
        result[current].assertions.incl(daImage)
      of "program":
        result[current].program = value
        result[current].assertions.incl(daProgram)
      of "uid":
        var parsed = 0
        try:
          parsed = parseInt(value)
        except ValueError:
          raise newException(DaemonDeclarationError,
            source & ": uid '" & value & "' is not a number")
        result[current].uid = parsed
        result[current].assertions.incl(daUid)
      else:
        raise newException(DaemonDeclarationError,
          source & ": unknown key '" & event.key & "'. Known keys are " &
          "socket, image, program, uid.")
    of cfgError:
      raise newException(DaemonDeclarationError, source & ": " & event.msg)

proc loadDeclaredDaemons*(): seq[DeclaredDaemon] =
  ## Read the machine's daemon declarations, system file then user file, the
  ## user's entry for a given daemon REPLACING the system's rather than adding
  ## to it. `REPRO_DAEMONS_CONFIG`, when set, replaces both.
  ##
  ## A missing file is not an error and yields no declarations, so a host that
  ## declares nothing behaves exactly as it does today — DA-2's reach and no
  ## more. This is the default, and it is the untrusting one.
  result = @[]
  var files: seq[string] = @[]
  let overridePath = getEnv(DaemonTrustConfigEnvVar, "")
  if overridePath.len > 0:
    files.add(overridePath)
  else:
    when not defined(windows):
      files.add(DaemonTrustSystemConfigPath)
    files.add(getConfigDir() / DaemonTrustUserConfigRelPath)
  for file in files:
    if file.len == 0 or not fileExists(file):
      continue
    var text = ""
    try:
      text = readFile(file)
    except CatchableError as exc:
      raise newException(DaemonDeclarationError,
        file & ": cannot be read: " & exc.msg)
    for decl in parseDeclaredDaemonSections(text, file):
      var replaced = false
      for i in 0 .. result.high:
        if result[i].kind == decl.kind:
          result[i] = decl
          replaced = true
          break
      if not replaced:
        result.add(decl)

proc applyDeclaredDaemonTrust*(declarations: openArray[DeclaredDaemon]):
    seq[DaemonCheckReport] =
  ## Check every declaration and register the ones that pass. Returns one
  ## report per declaration, PASS AND FAIL ALIKE.
  ##
  ## Every declaration is reported because a declaration is the thing that can
  ## rot. A daemon that has moved, been renamed, or stopped running leaves a
  ## line in the config that asserts a peer nobody will ever meet; reporting it
  ## every build is what stops that line from sitting there until some future
  ## pid collision makes it mean something. This is rule 3 applied to the
  ## declaration surface rather than only to the exemptions it buys.
  result = @[]
  for decl in declarations:
    let check = checkDeclaredDaemon(decl)
    var outcome = check.outcome
    if outcome == dcoTrusted:
      if not trustDaemonWeChecked(decl.kind, check):
        # Unreachable while `checkDeclaredDaemon` and `trustDaemonWeChecked`
        # agree on what a pass is; reported rather than asserted, because the
        # direction of a disagreement between them must be a refusal.
        outcome = dcoNoPeerCredentials
    result.add(DaemonCheckReport(kind: decl.kind, endpoint: decl.endpoint,
      outcome: outcome, detail: check.detail, source: decl.source))

proc renderDaemonCheckReport*(report: DaemonCheckReport): string =
  ## The build-log line for one declaration. Names the daemon, the endpoint,
  ## the outcome, the §Class 3 branch a PASS bought, and the file that declared
  ## it — so neither a granted exemption nor a rotted declaration is anonymous.
  let name = daemonKindName(report.kind)
  if report.outcome == dcoTrusted:
    "declared ipc peer '" & name & "' at " & report.endpoint &
      " checked and trusted — Dependency-Observation-Attribution.md §Class 3 " &
      class3BranchText(class3Contribution(report.kind)) & " (DA-4); " &
      report.detail & "; declared in " & report.source
  else:
    "declared ipc peer '" & name & "' at " & report.endpoint &
      " NOT trusted (" & $report.outcome & "): " & report.detail &
      "; declared in " & report.source

const
  UnmonitoredSubtreeLossDetailPrefix* =
    "unmonitored subtree/peer (un-injectable spawn child, SETEXEC into a " &
    "hardened image, or IPC connect to an out-of-tree breakaway daemon): "
      ## The EXACT text io-mon's `mergeFragments` prepends to each entry
      ## `unmonitoredSubtreeLossDetails` returned (io-mon writer.nim). Matched
      ## exactly, not by a `find(": ")`: a shape this code has not reasoned
      ## about must fall through to the unchanged Level-2 classification rather
      ## than be parsed on a guess.
  IpcPeerLossDetailPrefix* = "ipc peer outside monitored tree "
      ## The (c) arm's own prefix, inside the wrapper above. The (a) spawn arm
      ## and the (b) exec arm are NOT attributable by a peer pid and are never
      ## considered here.

type
  MonitorPeerAttribution* = object
    ## The per-action state DA-2's attribution needs, carried through the fold.
    ##
    ## WHY THE FOLD CANNOT ANSWER PER RECORD. io-mon's exemption is
    ## `peer != 0 and not duplicatePeerStart and (childIsMonitored(…) or
    ## peer in trustedPeerPids)` — quoted whole because the `childIsMonitored`
    ## disjunct is what makes the recomputation below CONSERVATIVE rather than
    ## merely different: it needs `mrProcessStart` records the buffer does not
    ## carry, so the recomputation exempts strictly LESS than io-mon did, and
    ## `duplicatePeerStart` — a shim identity token appearing twice, which io-mon
    ## treats as attacker-controlled evidence that must fail CLOSED — is NOT
    ## recoverable from the loss text: `trustedDetailToken` returns "" for a
    ## duplicated token, which is also what a Linux record with no token at all
    ## produces. So the decision is deferred to the end of the fold and taken by
    ## re-running io-mon's OWN function over the `mrIpcConnect` records that
    ## produced the losses — twice, with and without the trust set, because the
    ## recomputation is not exact and only the DIFFERENCE between those two
    ## answers is attributable to the trust. See `resolvePeerAttribution`, which
    ## states both divergences. There is exactly one implementation of the
    ## exemption rule and it is io-mon's.
    trusted: HashSet[uint64]
    peers: Table[uint64, TrustedDaemonPeer]
      ## The same trust facts keyed by pid, so an exemption can be NAMED and
      ## not merely counted (rule 3). io-mon's loss text identifies the peer by
      ## a bare pid — on Linux `recordIpcConnect` never sets `record.path` for
      ## an AF_UNIX connect, so the pid is the ONLY identifier in it — and a
      ## build log saying "peer 21894 was forgiven" tells an operator neither
      ## which daemon that was nor why it was allowed to be.
    ipcRecords: seq[MonitorRecord]
      ## The `mrIpcConnect` records, and nothing else. Buffering the whole
      ## record stream would defeat `foldMonitorDepFileEvidence`'s streaming
      ## read (a real `nim c` capture is 124k records); these are a handful per
      ## action. The (a)/(b) arms need spawn/exec records this deliberately does
      ## NOT collect, which is exactly why the comparison below is scoped to the
      ## (c) arm — an entry from either other arm is not in the recomputation
      ## and must never be treated as attributed.
    pendingIpcLosses: seq[string]
    attributed*: int
      ## Rule 3 — every exemption is counted, so a daemon that turns out not to
      ## deserve trust leaves a number behind rather than nothing.

proc initMonitorPeerAttribution*(peers: openArray[TrustedDaemonPeer]):
    MonitorPeerAttribution =
  ## Build one action's attribution state from trust FACTS, re-validating each
  ## against the kernel on the way in. Takes the facts rather than a bare pid
  ## set because both consumers need them: io-mon's parameter wants the pids,
  ## and the rule-3 diagnostic wants the name and the §Class 3 branch.
  result.trusted = initHashSet[uint64]()
  result.peers = initTable[uint64, TrustedDaemonPeer]()
  for peer in revalidatedTrustedDaemons(peers):
    result.trusted.incl(uint64(peer.pid))
    result.peers[uint64(peer.pid)] = peer

proc trustsAnyPeer(attribution: MonitorPeerAttribution): bool =
  attribution.trusted.len > 0

proc classifyEventLossDetail*(detail: string): MonitorEvidenceStatus =
  ## M9.R.72.3 — spec-graded classification of io-mon eventLoss records.
  ##
  ## Maps the ``detail`` string io-mon's writer.nim emits at loss-injection
  ## time to the Failure-Semantics.md monitor-loss ladder level. The detail
  ## strings are documented in io-mon's src/io_mon/writer.nim at the emit
  ## sites:
  ##
  ##   * "process killed with an un-flushed read batch (kill-before-flush)"
  ##     — writer.nim:2205 / :2224. A subprocess died before flushing its
  ##     read-batch tail. The io-mon writer knows precisely which pid/tid
  ##     it lost, and every OTHER record in the iomon is trustworthy.
  ##     Level 1 (known scope): downgrade the session to non-cacheable but
  ##     let the action succeed. Currently treated as Level 2 in this
  ##     initial implementation until the per-class narrow-invalidation of
  ##     Level 1 (Gap II in m9r72_phaseB_gap_enumeration.txt) is scoped.
  ##
  ##   * "unmonitored subtree/peer" — writer.nim:2266. A spawn/exec subtree
  ##     ran under NO monitoring OR the client talked to an out-of-tree
  ##     breakaway daemon. Level 2 (unknown scope for the peer's content).
  ##
  ##   * "ambiguous unstamped fragment record" — writer.nim:2062. Two runs
  ##     shared a pid slot and we can't attribute a record to either.
  ##     Level 2 (unknown scope).
  ##
  ##   * "duplicate identity token in fragment record" — writer.nim:2034 /
  ##     :2068. A shim identity token appeared twice, so record-ordering
  ##     integrity is compromised. Level 2.
  ##
  ##   * "libc raw syscall unsupported nr=<N>" / "inline raw syscall
  ##     unsupported nr=<N>" — linux_preload.nim
  ##     ``recordRawSyscallClassification``. The shim saw a raw syscall it
  ##     does not model. For the small, individually-justified set of
  ##     numbers in ``benignRawSyscallLoss`` the number alone proves the
  ##     call cannot name a path or move content, so the record represents
  ##     no lost filesystem information: Level 0. Every other number stays
  ##     Level 2 via the fail-closed default below.
  ##
  ## Every other unknown detail defaults to mesUnknownScopeLoss to fail
  ## closed conservatively — the spec's R3 general rule for ambiguous
  ## correctness failures.
  const
    # Prefixes below match the exact strings io-mon's src/io_mon/writer.nim
    # emits at the referenced sites. Any addition here MUST also land a
    # row in reprobuild-specs/Monitor-Loss-Path-Invalidation.md, per that
    # memo's "Contract For Future Loss Classes".
    KillBeforeFlushPrefix = "process killed with an un-flushed read batch"
      ## writer.nim:2205, 2224 — Level 1 (known scope).
    UnmonitoredSubtreePrefix = "unmonitored subtree/peer"
      ## writer.nim:2266 — Level 2.
    AmbiguousUnstampedPrefix = "ambiguous unstamped fragment record"
      ## writer.nim:2062 — Level 2.
    DuplicateIdentityPrefix = "duplicate identity token"
      ## writer.nim:2034, 2068 — Level 2.
    OutOfTreeContentChannelPrefix = "out-of-tree content channel consumed"
      ## writer.nim:2282 — Level 2. Replaces the earlier
      ## "external content" placeholder from M9.R.72.3 which was never
      ## an actual io-mon prefix.
    ExternalContentPrefix = "external content"
      ## Legacy alias retained for the M9.R.72.3 unit-test corpus and any
      ## pre-M9.R.73 depfile that might have been produced against an
      ## older io-mon revision. Level 2.
    CorruptFragmentPrefix = "corrupt or partial iomon fragment"
      ## writer.nim:2158 — Level 2. Newly classified in M9.R.73.2.
    BreakawayReportPrefix = "breakaway-report"
      ## Reserved for the authenticated-daemon report Level 2 path;
      ## io-mon currently emits its authentication failures inline
      ## rather than as a distinct event-loss detail prefix, but the
      ## classifier row is retained so a future writer change lands
      ## in a Level 2 conservative bucket by default. See the memo.
  if detail.startsWith(KillBeforeFlushPrefix):
    return mesKnownScopeLoss
  if detail.startsWith(UnmonitoredSubtreePrefix):
    return mesUnknownScopeLoss
  if detail.startsWith(AmbiguousUnstampedPrefix):
    return mesUnknownScopeLoss
  if detail.startsWith(DuplicateIdentityPrefix):
    return mesUnknownScopeLoss
  if detail.startsWith(OutOfTreeContentChannelPrefix):
    return mesUnknownScopeLoss
  if detail.startsWith(ExternalContentPrefix):
    return mesUnknownScopeLoss
  if detail.startsWith(CorruptFragmentPrefix):
    return mesUnknownScopeLoss
  if detail.startsWith(BreakawayReportPrefix):
    return mesUnknownScopeLoss
  # Benign raw-syscall class (Level 0). What makes this arm unable to downgrade
  # a recognised loss class is that the two prefixes it matches are disjoint
  # from every prefix above — not its position, which is defensive only. (No
  # prefix in the const block above is a prefix of "libc raw syscall
  # unsupported nr=" or "inline raw syscall unsupported nr=", nor the reverse,
  # so the dispatch order over this chain is not observable.)
  #
  # The property that actually keeps a mixed iomon fail-closed lives one level
  # up, in ``foldMonitorDepFileEvidence``'s ``worseMonitorStatus`` fold, and is
  # pinned by ``test_m9r72_phaseD_end_to_end.nim``'s "benign raw syscall does
  # not rescue an iomon that also lost a subtree". THIS suite cannot see that
  # property: inverting the fold leaves every classifier check green
  # (mutation-verified) while the phase-D case fails.
  if benignRawSyscallLoss(detail):
    return mesComplete
  # Unknown detail — fail closed conservatively.
  mesUnknownScopeLoss

proc worseMonitorStatus(a, b: MonitorEvidenceStatus): MonitorEvidenceStatus =
  ## Ordering: mesComplete < mesKnownScopeLoss < mesUnknownScopeLoss <
  ## mesMonitorUnavailable. Return whichever is more severe.
  if ord(a) >= ord(b): a else: b

const FailedExecDetailToken = "execstatus=failed"
  ## The token io-mon puts in an `mrProcessExec` record's `detail` when the
  ## exec syscall RETURNED — i.e. it failed and no new image ran. Emitted by
  ## io-mon `src/io_mon/shim/linux_preload.nim` (`repro_hook_execve`, the
  ## M9.R.68.3 follow-up record) as `"execstatus=failed errno=<n>"`, and
  ## consumed by io-mon's own writer to retract the preceding pre-flush exec
  ## from its unmonitored-subtree signal. The engine matches the same token so
  ## a failed exec never becomes a content input. Keep in step with that emit
  ## site; a rename there silently turns absent paths into cache inputs here,
  ## which `t_executed_binary_is_a_recorded_input.nim` pins.

proc ipcPeerLossText(detail: string): string =
  ## The io-mon (c)-arm loss text inside an injected `mrEventLoss` detail, or ""
  ## when this record is not one. Exact prefixes only — see their declarations.
  if not detail.startsWith(UnmonitoredSubtreeLossDetailPrefix):
    return ""
  let inner = detail[UnmonitoredSubtreeLossDetailPrefix.len .. ^1]
  if not inner.startsWith(IpcPeerLossDetailPrefix):
    return ""
  inner

type
  IpcPeerLossIdentity = object
    ## What a (c)-arm loss text identifies, parsed back out of it.
    key: string
      ## io-mon's OWN dedup key for the record that produced the text, or ""
      ## when the text does not parse. See `ipcPeerLossIdentity`.
    peer: uint64
      ## The peer pid the text names, 0 for an unknown (INET) peer.

proc ipcPeerLossIdentity(loss: string): IpcPeerLossIdentity =
  ## Recover io-mon's dedup key, and the peer pid, from a (c)-arm loss text.
  ##
  ## WHY THE KEY AND NOT THE TEXT. `unmonitoredSubtreeLossDetails` keys each
  ## (c) entry on `"pid:" & $peer & "@" & peerStart` when the peer pid is known
  ## and on `"dest:" & r.path` when it is not, and emits the text of the FIRST
  ## NON-EXEMPT record per key. Two records that share a key are therefore
  ## INTERCHANGEABLE in the output: which one's text appears depends on which
  ## of them was exempt, which differs between io-mon's run and the engine's
  ## recomputation. The key is the part that is stable across both, so the key
  ## is what may be compared. Everything else in the text — the CLIENT pid, the
  ## socket path — belongs to whichever record happened to be first.
  ##
  ## io-mon emits `"ipc peer outside monitored tree pid=<osPid> peer=<peer> " &
  ## "peerstart=<peerStart> path=<path>"`. `pid`, `peer` and `peerstart` are
  ## whitespace-free decimal tokens, so the first occurrence of each separator
  ## is the real one; `path` is last and may contain anything.
  result = IpcPeerLossIdentity(key: "", peer: 0)
  if not loss.startsWith(IpcPeerLossDetailPrefix):
    return
  let rest = loss[IpcPeerLossDetailPrefix.len .. ^1]
  const
    PeerSep = " peer="
    PeerStartSep = " peerstart="
    PathSep = " path="
  let peerAt = rest.find(PeerSep)
  let startAt = rest.find(PeerStartSep)
  let pathAt = rest.find(PathSep)
  if peerAt < 0 or startAt < 0 or pathAt < 0:
    return
  if not (peerAt < startAt and startAt < pathAt):
    return
  let peerText = rest[peerAt + PeerSep.len ..< startAt]
  let peerStart = rest[startAt + PeerStartSep.len ..< pathAt]
  let path = rest[pathAt + PathSep.len .. ^1]
  if peerText.len == 0:
    return
  var peer: uint64 = 0
  for ch in peerText:
    if ch notin {'0' .. '9'}:
      return
    peer = peer * 10 + uint64(ord(ch) - ord('0'))
  result.peer = peer
  result.key =
    if peer != 0: "pid:" & peerText & "@" & peerStart
    else: "dest:" & path

proc resolvePeerAttribution(attribution: var MonitorPeerAttribution;
                            evidence: var PathSetEvidence;
                            status: var MonitorEvidenceStatus) =
  ## DA-2 — decide each deferred IPC-peer loss, by asking io-mon TWICE.
  ##
  ## THE RECOMPUTATION IS NOT EXACT, which is what this shape is built around.
  ## It sees only the buffered `mrIpcConnect` records, so it differs from the
  ## run that produced the losses in two MEASURED ways, both of them
  ## fail-OPEN under a "was this text still returned?" test:
  ##
  ##   1. THE RECORDS MAY NOT BE THERE AT ALL. `unmonitoredSubtreeLossDetails`
  ##      over an empty record set returns an empty seq, so an absent-text test
  ##      forgives EVERYTHING. Unreachable while `monitorInterest` returns
  ##      `FullInterest` unconditionally — but `DependencyGatheringPolicy`
  ##      already carries a `captureIpc` switch, and narrowing it would silently
  ##      turn this into a blanket exemption.
  ##   2. THE DEDUP KEY CAN BE CLAIMED BY A DIFFERENT RECORD. io-mon emits the
  ##      text of the first NON-EXEMPT record per key. Without `mrProcessStart`
  ##      records nothing looks in-tree here, so a record io-mon exempted as
  ##      in-tree is flagged by the recomputation and can claim the key FIRST,
  ##      with its own (different) text — and the loss that io-mon actually
  ##      emitted for that key then reads as "no longer returned". The earlier
  ##      claim that "a trusted peer's key is `pid:<peer>@…` and the entries it
  ##      could suppress are its own" does not cover this: the colliding record
  ##      need not belong to a trusted peer, and the trust set need not be
  ##      involved at all.
  ##
  ## SO THE QUESTION IS ASKED AS A DIFFERENCE, NOT AS AN ABSENCE. io-mon's own
  ## function is run over the SAME buffered records twice — once with NO trust
  ## and once with this action's trust set — and a deferred loss is forgiven
  ## only when its dedup key is in the FIRST answer and not in the second. That
  ## reads as: *these records account for this loss, and the trust set is what
  ## removed it.* Both divergences fall closed under it. An absent record is in
  ## neither answer, so the key is not in the difference and the loss
  ## downgrades. A collided key is in BOTH answers — the colliding record is
  ## still flagged in the second — so it is not in the difference either.
  ## Comparing keys is also strictly more conservative than comparing texts:
  ## a text present in the second answer implies its key is, so nothing that
  ## the old test downgraded is forgiven by this one.
  ##
  ## The no-trust run is not a guess at what io-mon did: with no
  ## `mrProcessStart` records and an empty trust set NOTHING is exempt, so it
  ## enumerates exactly the dedup keys the buffered records can account for,
  ## computed by io-mon's dedup rather than by a reimplementation of it here.
  ##
  ## AN EXEMPTION THAT CANNOT BE NAMED IS NOT GRANTED (rule 3). The diagnostic
  ## carries the daemon's name and the §Class 3 branch it satisfies, and the
  ## lookup that supplies them is on the FORGIVING path: a key whose peer pid is
  ## not a registered daemon downgrades instead of being forgiven anonymously.
  ## In practice the lookup cannot fail — the key was removed by the trust set,
  ## so its peer is in that set — which is what makes failing closed there free.
  ##
  ## AND CLASS 4 IS NOT REACHABLE FROM HERE. `SO_PEERCRED` yields a pid for
  ## AF_UNIX and 0 for INET (io-mon `recordIpcConnect`), and io-mon's exemption
  ## requires `peer != 0`. A network peer is therefore unattributable and stays
  ## unattributable no matter what this set contains — rule 4, held by io-mon's
  ## code rather than restated here. Its `dest:<path>` key is in both answers.
  ##
  ## ONE CAPTURE PER CALL. `collectEvidence` reuses a single
  ## `MonitorPeerAttribution` across the recognized-`.iomon`-report loop (one
  ## fold per resolved report path) and the wrapped/hosted monitor fold, so the
  ## buffers are cleared here. Each capture is a separate monitored run and must
  ## be resolved against its OWN `mrIpcConnect` records; carrying them forward
  ## would let one capture's peers forgive another's losses, and would re-grade
  ## losses already decided. `attributed` deliberately does NOT reset — it is
  ## the per-action count.
  if attribution.pendingIpcLosses.len == 0:
    attribution.ipcRecords.setLen(0)
    return
  var accountedKeys = initHashSet[string]()
  for loss in unmonitoredSubtreeLossDetails(attribution.ipcRecords,
      initHashSet[uint64]()):
    let identity = ipcPeerLossIdentity(loss)
    if identity.key.len > 0:
      accountedKeys.incl(identity.key)
  var remainingKeys = initHashSet[string]()
  for loss in unmonitoredSubtreeLossDetails(attribution.ipcRecords,
      attribution.trusted):
    let identity = ipcPeerLossIdentity(loss)
    if identity.key.len > 0:
      remainingKeys.incl(identity.key)
  for loss in attribution.pendingIpcLosses:
    let identity = ipcPeerLossIdentity(loss)
    let removedByTrust = identity.key.len > 0 and
      identity.key in accountedKeys and identity.key notin remainingKeys
    if not removedByTrust or identity.peer notin attribution.peers:
      status = worseMonitorStatus(status, mesUnknownScopeLoss)
    else:
      let peer = attribution.peers[identity.peer]
      inc attribution.attributed
      # DA-4 — the diagnostic states the ORIGIN of the trust, not just the fact
      # of it. §"Derived beats declared" makes the two different kinds of
      # claim: one the engine derived and cannot have got wrong, one somebody
      # declared and a check had to establish. An operator auditing an
      # exemption needs to know which, and for a declared one needs the
      # endpoint that was named and the assertions the check actually verified
      # — "checked" with no statement of what was checked is the wish this
      # milestone exists to replace.
      let provenance =
        case peer.origin
        of tdoSpawned:
          "spawned by this process"
        of tdoDeclaredAndChecked:
          "declared at " & peer.declaredSocket & " and checked (" &
          ($peer.checked).replace("{", "").replace("}", "") &
          "), re-validated against the kernel at grading time"
      let milestone =
        case peer.origin
        of tdoSpawned: " (DA-2); forgave: "
        of tdoDeclaredAndChecked: " (DA-4); forgave: "
      evidence.diagnostics.add(
        "ipc peer attributed to daemon '" & peer.name & "' (pid " &
        $peer.pid & "), " & provenance & " — " &
        "Dependency-Observation-Attribution.md §Class 3 " &
        class3BranchText(peer.contribution) &
        milestone & loss)
  attribution.pendingIpcLosses.setLen(0)
  attribution.ipcRecords.setLen(0)

proc foldOneMonitorRecord(record: MonitorRecord; cwd: string;
                          evidence: var PathSetEvidence;
                          seen: var EvidenceSeenSets;
                          status: var MonitorEvidenceStatus;
                          attribution: var MonitorPeerAttribution) =
  ## Fold ONE decoded iomon record into the engine's path-set evidence.
  ##
  ## THE ONE IMPLEMENTATION OF THE FOLDING RULES, deliberately. Since HM-5
  ## there are two SOURCES of records — the ``.iomon`` bytes on the wrapped
  ## launch paths, and the records ``finishMonitor`` already returned in
  ## memory on the hosted one — and the whole premise of hosting is that
  ## nothing downstream can tell the two apart. Two copies of the rules would
  ## be two chances for them to disagree about what the same observation
  ## means, silently, in the dependency set. So the decode and the fold are
  ## separated here and the fold is shared.

  # DA-2 — the `mrIpcConnect` records are what io-mon's (c)-arm loss text is
  # DERIVED FROM, so they are what `resolvePeerAttribution` re-asks io-mon
  # about. Collected only when this action has a trusted peer at all, so an
  # ordinary build buffers nothing.
  if record.kind == mrIpcConnect and attribution.trustsAnyPeer():
    attribution.ipcRecords.add(record)

  if record.kind == mrEventLoss or record.observationKind == moEventLoss:
    # M9.R.72.3 — classify the loss instead of collapsing to a bool.
    # ``classifyEventLossDetail`` maps io-mon's detail strings to Level
    # 1 (known scope) or Level 2 (unknown scope); ``worseMonitorStatus``
    # keeps the worst observed level across the whole depfile so the
    # caller can decide session cache-skip vs hard-fail conservatively.
    #
    # DA-2 — one shape is DEFERRED rather than classified here: an IPC-peer
    # loss, when this action has a derived trusted peer. The decision needs the
    # `mrIpcConnect` records, which are still arriving, so it is taken in
    # `resolvePeerAttribution` at the end of the fold. Nothing is suppressed:
    # the record stays in the `.iomon` on disk and its loss text is carried
    # here, so a peer that turns out NOT to be trusted downgrades exactly as it
    # does today (attribution, not suppression —
    # Dependency-Observation-Attribution.md §"Attribution, not suppression").
    let ipcLoss =
      if attribution.trustsAnyPeer(): ipcPeerLossText(record.detail) else: ""
    if ipcLoss.len > 0:
      attribution.pendingIpcLosses.add(ipcLoss)
    else:
      let recordStatus = classifyEventLossDetail(record.detail)
      status = worseMonitorStatus(status, recordStatus)
  elif record.kind == mrBackendProfile and
      not monitorProfileEvidenceComplete(record.detail):
    status = worseMonitorStatus(status, mesUnknownScopeLoss)

  # M6 — entropy evidence and the capability declaration that says whether
  # entropy COULD have been evidenced. Neither touches ``status``: an
  # entropy read is not a monitoring loss (io-mon SAW it), and a
  # non-determinism capability gap is not in ``InputEvidenceCapabilities``
  # so it does not move the completeness floor. Both are carried out on
  # ``evidence`` for ``collectEvidence`` to weigh against the invoked
  # tool's blessing.
  #
  # Deliberately BEFORE the `materialPath` / volatile-path guard below:
  # these records' `path` fields are capability ids and entropy source
  # names, not filesystem paths, so nothing about them should be resolved
  # against the action's cwd or tested for volatility.
  case record.kind
  of mrNonDeterministic:
    addEntropyObservation(evidence, record.path,
      entropyCallerOrigin(record.detail))
  of mrBackendProfile:
    # A gap record already seen wins: ``entNotObserved`` is the
    # conservative answer and must not be relaxed by a profile parsed
    # afterwards.
    if evidence.entropyObservability != entNotObserved:
      evidence.entropyObservability =
        if monitorProfileSupportsNonDeterminism(record.detail): entObserved
        else: entNotObserved
  of mrCapabilityGap:
    if capabilityGapIsNonDeterminism(record.path, record.detail):
      evidence.entropyObservability = entNotObserved
  of mrEnvRead:
    # M10 — `record.path` here is a variable NAME, not a path. Resolving it
    # against the action's cwd (as the `materialized` line below does for
    # every other kind) would turn `SOURCE_DATE_EPOCH` into
    # `<cwd>/SOURCE_DATE_EPOCH` and quietly key the cache on a file that
    # does not exist. Handled here, above that line, for the same reason as
    # the entropy arms.
    if record.path.len > 0:
      evidence.monitorEnvReads.addUnique(seen.monitorEnvReads,
        record.path, envNameKey(record.path))
  else:
    discard

  let materialized = materialPath(cwd, record.path)
  if materialized.isVolatileMonitorPath():
    return
  case record.kind
  of mrFileRead:
    evidence.monitorReads.addUnique(seen.monitorReads, materialized)
  of mrLibraryLoad:
    # A library the dynamic loader MAPPED into the action. This is a
    # content dependency and nothing else: change the file, change what
    # the action computes.
    #
    # It needs its own arm because it cannot arrive as an `mrFileRead`.
    # `ld.so` resolves `DT_NEEDED` entries with its own internal open,
    # before the preloaded shim's hooks exist, so a dependent DSO
    # passes through no interposed `open` at all — io-mon emits it from
    # the loaded-object enumeration instead, and the `else: discard`
    # below swallowed every one. Measured on `env true`, a process that
    # touches no file of its own: 18 `mrLibraryLoad` records covering
    # 14 distinct PATHS and 9 distinct SONAMEs, `mesComplete`, and
    # `monitorReads: 0`. The three counts differ for two separate
    # reasons and both are worth knowing: four sonames are emitted
    # twice under the identical path (duplicate records, deduped by
    # `addUnique`), and five appear under two DIFFERENT store paths
    # because `env` exec'd a second image linked against a different
    # glibc. So the fold contributes 14 inputs here, not 18 and not 9.
    #
    # io-mon sets `observationKind = moFileRead` on these deliberately
    # so every consumer keying on the observation kind treats them as
    # content reads (io-mon `types.nim:36`); folding them into
    # `monitorReads` is that contract's consumer half.
    #
    # WHAT ABOUT THE SHIM'S OWN LOAD CLOSURE? io-mon excludes the shim
    # library itself (`shim/linux_preload.nim`, so that "upgrading
    # io-mon would not invalidate every cached action") but not the
    # libraries the shim's own `DT_NEEDED` pulls in, so it is fair to
    # ask whether this fold now puts the monitor's libc into every
    # action's key. Measured, and the answer is no in the case that
    # matters, for a reason worth writing down: the loader maps ONE
    # object per soname, so when the action has its own libc the shim
    # binds to THAT one and adds nothing. On the real
    # `reprobuild.test_execute.t_smoke_ct_test_interface` edge the six
    # recorded libraries are all under the TEST BINARY's glibc
    # (`…-glibc-2.42-51` reached via its own RPATH), none under the
    # shim's separate glibc store path. The shim's closure shows up
    # alone only when the action has no closure of its own — measured
    # on a `-nostdlib` binary, where those six ARE the shim's.
    #
    # So DO NOT "fix" this by dropping the shim's closure by path. In
    # the common case there is nothing there to drop, and on any host
    # where repro and the toolchain resolve to the SAME glibc store
    # path such a filter would drop the action's genuine libc — which
    # is this defect, for the single most consequential library there
    # is. The sound fix is attribution, not filtering: record whether a
    # loaded object is reachable from the MAIN IMAGE's `DT_NEEDED`
    # closure and let the consumer drop only the unreachable ones. That
    # belongs in io-mon, which is the only side that can see the
    # dependency graph. Until it exists, an action whose recorded libc
    # is the shim's rather than its own pays a spurious cross-host
    # cache MISS — an efficiency cost in the fail-closed direction, not
    # a stale hit.
    #
    # UNCONDITIONALLY, with no allowlist for immutable package stores.
    # Sandbox-And-Monitoring.md §"Open Design Questions" left "how much
    # library-load information is required for correctness" open; the
    # answer taken here is "all of it", because an allowlist is exactly
    # what kept this invisible — on NixOS every loaded DSO is a store
    # path, so exempting store paths would leave the fix asserting
    # nothing while a host with a mutable `/usr/lib` still served stale
    # results. Cost: one `lstat` per loaded DSO on the warm path.
    # `cacheInputPaths` still drops the ones under the action's own
    # tool roots, and `isVolatileMonitorPath` above still drops
    # `/run`-resident driver libraries.
    evidence.monitorReads.addUnique(seen.monitorReads, materialized)
  of mrFileOpen:
    case record.observationKind
    of moFileRead, moFileOpen:
      evidence.monitorReads.addUnique(seen.monitorReads, materialized)
    of moFileWrite:
      evidence.monitorWrites.addUnique(seen.monitorWrites, materialized)
    else:
      discard
  of mrFileWrite:
    evidence.monitorWrites.addUnique(seen.monitorWrites, materialized)
  of mrProcessExec:
    # A binary the action EXECUTED. Its bytes decide what the action
    # computes at least as directly as any file it reads, so it is a
    # content dependency and belongs in `monitorReads` beside
    # `mrLibraryLoad`.
    #
    # WHY IT NEEDS ITS OWN ARM. It cannot arrive as an `mrFileRead`: the
    # kernel maps the image, no interposed `open` is involved, and the
    # loaded-object enumeration explicitly EXCLUDES the main executable
    # (io-mon `shim/linux_preload.nim` :: `libraryLoadRecordablePath`,
    # `dlpi_name == ""`), on the stated grounds that it "is already
    # captured as the process image by `mrProcessExec`". Until this arm
    # existed, nothing in this engine referenced `mrProcessExec` at all,
    # so that hand-off landed in the `else: discard` below and the
    # executed binary was in no cache key.
    #
    # Measured before this arm, over four action shapes, all on edges
    # that declare no tool refs. Only the first was covered, and only by
    # accident — a bare name invoked through a shell makes bash `stat`
    # every PATH candidate, and the resolved hit lands as an
    # `mrPathProbe`, which IS folded:
    #
    #   bare name via a shell   -> path-probe + process-exec, in the key
    #   absolute path in the shell command  -> process-exec ONLY, not in the key
    #   the action's own argv[0]            -> NOTHING AT ALL
    #   bare name via glibc `execvp`        -> unresolved name + failed marker
    #
    # Rows 2 and 4 are what this arm addresses. Row 3 cannot be: io-mon's
    # `execve` hook lives in the CHILD, so the launcher's exec of the
    # action's ROOT image precedes the shim constructor and there is no
    # record here to fold. That one is closed on the launcher side by
    # `executedToolImagePath`.
    #
    # TWO GUARDS, both load-bearing.
    #
    # (1) ABSOLUTE PATHS ONLY. `execvp`/`execlp`/`execvpe` record the
    #     name the CALLER passed, unresolved — io-mon's
    #     `dispatch_execvp` emits before handing off to glibc, which
    #     then does the PATH walk internally where no interposer can see
    #     it. Folding `execdep-helper3` would send it through
    #     `materialPath`, which joins a relative path onto the action's
    #     cwd and MANUFACTURES `<cwd>/execdep-helper3` — a path that
    #     does not exist, is not what ran, and would be a fabricated
    #     dependency layered on top of the gap rather than a fix for it.
    #     Skipping is the conservative choice: it leaves the gap exactly
    #     where it was and invents nothing. Resolving here is not
    #     available — the search PATH that glibc used is the CHILD's
    #     environment at the moment of the call, which this fold does
    #     not have and must not guess at.
    # (2) NO FAILED EXECS. io-mon emits a follow-up `mrProcessExec`
    #     carrying `execstatus=failed` when the syscall returned
    #     (`shim/linux_preload.nim`, M9.R.68.3). A failed exec ran no
    #     bytes, and its path frequently does not exist at all — bash's
    #     platform-probe cascade alone execs a dozen absent paths per
    #     `configure`. Existence-of-absent-paths is what `mrPathProbe`
    #     is for; it must not enter the key as a content read.
    if record.path.isAbsolute and
        not record.detail.contains(FailedExecDetailToken):
      evidence.monitorReads.addUnique(seen.monitorReads, materialized)
  of mrPathProbe:
    evidence.monitorProbes.addUnique(seen.monitorProbes, materialized)
  of mrDirectoryEnumerate:
    # Stays in `monitorProbes` (every existing consumer keeps its set) AND
    # is recorded separately, because membership, not existence, is what
    # an enumeration depends on. See `monitorDirectoryEnumerations`.
    evidence.monitorProbes.addUnique(seen.monitorProbes, materialized)
    evidence.monitorDirectoryEnumerations.addUnique(
      seen.monitorDirectoryEnumerations, materialized)
  else:
    discard

# The strictest requirement there is, and therefore the right DEFAULT for
# every fold site that has not been told otherwise: a capture is trusted only
# if it observed every event category and wrote down every lookup, including
# the ones that found nothing.
#
# Being the default is what makes the back-compat story hold in the safe
# direction. A depfile written before DA-1i/DA-1j states neither stamp;
# io-mon's ``effectiveObservedInterest`` / ``effectiveObservedEvidenceScope``
# widen an ABSENT stamp to full on both axes, so such a file still passes this
# requirement unchanged — while a file that STATES a narrowing does not.
# "Silent" and "narrowed" are different facts and only the first one reads as
# full.
const FullMonitorEvidenceRequirement* = MonitorEvidenceRequirement(
  interest: FullInterest, evidenceScope: esFull)

proc monitorScopeRefusal*(dep: MonitorDepFile;
                          required: MonitorEvidenceRequirement): string =
  ## Is this capture's STATED scope enough for what this build requires? The
  ## empty string means yes; anything else is the sentence explaining the
  ## refusal, in the operator's terms.
  ##
  ## THE TWO PARTIAL ORDERS ARE DELEGATED, NOT REPRODUCED. This proc chooses
  ## the required side and phrases the verdict; ``observedEvidenceScopeCovers``
  ## and ``observedInterestCovers`` decide it, in io-mon, beside the enums they
  ## order and beside the three-way not-stated / stated-and-named /
  ## stated-and-unnamable reading that a bare field read gets wrong. A second
  ## copy of "full is stronger than reads-only" here would be a copy that can
  ## drift, and the way it drifts is not symmetric: the failure it produces is
  ## accepting a narrowed capture as complete evidence, which is the cardinal
  ## sin this stamp exists to make impossible.
  ##
  ## THE VERDICT IS NOT A COMPLETENESS VERDICT. A narrowed capture is an honest
  ## answer to a narrower question; ``mcIncomplete`` means the monitor could not
  ## observe something. The caller maps a refusal onto the Level-2 rung of
  ## Failure-Semantics.md's ladder — the action still succeeds, nothing is
  ## published from evidence this build cannot vouch for, and the next build
  ## recomputes locally.
  if not dep.observedEvidenceScopeCovers(required.evidenceScope):
    let stated =
      if dep.statesUnevaluableEvidenceScope:
        "declares evidence scope `" & dep.observedEvidenceScopeToken &
          "`, which this build cannot evaluate"
      else:
        "was captured with evidence scope `" &
          evidenceScopeToken(effectiveObservedEvidenceScope(dep)) & "`"
    return "monitor capture " & stated & ", which does not cover the `" &
      evidenceScopeToken(required.evidenceScope) &
      "` this build requires; its evidence is not trusted and the action-cache " &
      "publish is skipped this session (DA-1i, CLI/build.md " &
      "§Dependency Evidence Scope)"
  if not dep.observedInterestCovers(required.interest):
    let stated =
      if dep.statesUnevaluableInterest:
        "declares event interest `" & dep.observedInterestTokens &
          "`, which this build cannot evaluate"
      else:
        "was captured with event interest `" &
          interestToTokens(effectiveObservedInterest(dep)) & "`"
    return "monitor capture " & stated & ", which does not cover the `" &
      interestToTokens(required.interest) &
      "` this build requires; its evidence is not trusted and the action-cache " &
      "publish is skipped this session (DA-1j)"
  ""

proc gradeCaptureScope(profileRecords: openArray[MonitorRecord];
                       evidence: var PathSetEvidence;
                       required: MonitorEvidenceRequirement):
                       MonitorEvidenceStatus =
  ## Grade a capture's stamps, given the backend-profile records it carried.
  ##
  ## THE STAMPS ARE PARSED BY io-mon, not here. Both ride as `;`-separated keys
  ## on the ``mrBackendProfile`` record's detail — which is why neither needed a
  ## depfile envelope bump — and ``depFileFromRecords`` is the exported door
  ## onto that decode. Handing it only the profile records reproduces io-mon's
  ## own reading exactly (its readers scan for the FIRST profile record and
  ## these arrive in stream order), while keeping the streaming fold's promise
  ## that a 97k-record depfile is never materialized to grade it.
  ##
  ## NO PROFILE RECORD AT ALL grades as full scope on both axes, because
  ## ``depFileFromRecords(@[])`` states neither stamp and io-mon widens an
  ## absent stamp to full. That is the back-compat arm and it is reached by
  ## every depfile written before this shipped.
  let dep = depFileFromRecords(profileRecords)
  let refusal = monitorScopeRefusal(dep, required)
  if refusal.len == 0:
    return mesComplete
  evidence.diagnostics.add(refusal)
  # Level 2 (unknown scope). This build cannot bound WHAT the narrowing left
  # out — for `esReadsOnly` the dropped observations name paths that were never
  # written down, so there is no path set to invalidate narrowly — and the
  # action therefore succeeds and publishes nothing.
  #
  # DELIBERATELY NOT LEVEL 3. The capture is not corrupt and monitoring did not
  # fail. Failing a successful command for a property of its evidence is the
  # same mistake as grading a deliberate narrowing `mcIncomplete`, which DA-1i
  # already discarded — one rung further up the ladder.
  #
  # DELIBERATELY NOT LEVEL 1 EITHER. Level 1 publishes the action's own record
  # and only gates DOWNSTREAM lookups; here it is precisely this action's own
  # input set that is narrower than this build trusts.
  #
  # AND THE COST IS NAMED RATHER THAN ELIDED: Level 2 additionally flips the
  # scheduler's session-wide `sessionCachePublishDisabled`, so one refused
  # capture turns every later lookup in the session into a miss. That is
  # broader than the contract asks for — the untrusted evidence belongs to one
  # action — and it is accepted here rather than papered over, because the
  # alternative is a new rung on Failure-Semantics.md's ladder, which is a
  # change to the shared monitor-loss vocabulary and not to this feature. It is
  # also the rare path: a build reaches it only when it reads a capture SOMEONE
  # ELSE narrowed, since its own captures are taken under exactly the scope it
  # requires (`monitorEvidenceRequirement`).
  mesUnknownScopeLoss

proc foldMonitorDepFileEvidence*(path, cwd: string;
                                 evidence: var PathSetEvidence;
                                 seen: var EvidenceSeenSets;
                                 attribution: var MonitorPeerAttribution;
                                 required = FullMonitorEvidenceRequirement):
                                 MonitorEvidenceStatus =
  ## Fold depfile records directly into build-engine evidence.
  ##
  ## Consumes io-mon's `streamMonitorDepFileRecords`, which OWNS the format's
  ## decode and validation (magic, version, count/length, trailer magic,
  ## record-count agreement, body checksum, canonical 1..N sequence order) and
  ## yields one record at a time without ever materializing the full record seq
  ## — the memory-frugal read a large provider depfile needs (the compiler
  ## touches many source/toolchain files). The engine keeps only path sets +
  ## completeness.
  ##
  ## Reprobuild is a pure CONSUMER of io-mon's format here: it no longer
  ## re-implements the depfile envelope parse or reaches into io-mon's
  ## `codec`/`writer` internals. It only decides what each record MEANS for its
  ## evidence, in `foldOneMonitorRecord`. A missing file, a truncated/corrupt
  ## envelope, a bad checksum or a non-canonical sequence surfaces as io-mon's
  ## `MonitorDepFileReaderError` exactly as before (the hand-rolled reader raised
  ## the same type via `raiseMonitorDepFileReaderError`).
  ##
  ## M9.R.72.3: Returns the WORST-observed ``MonitorEvidenceStatus`` (Level 0-3)
  ## instead of a plain bool. Each ``mrEventLoss`` / ``moEventLoss`` record's
  ## ``detail`` string is fed through ``classifyEventLossDetail`` so the caller
  ## can distinguish Level 1 (known-scope, downgrade session to non-cacheable)
  ## from Level 2 (unknown-scope, disable cache hits) from Level 0 (complete).
  ## Level 3 (monitor entirely unavailable) is asserted at ``collectEvidence``
  ## when the ``monitorDepfile`` path itself is empty.
  ##
  ## DA-2 — `attribution` carries the derived trusted-daemon pid set (empty for
  ## every pre-existing caller, which is exactly today's behaviour) and comes
  ## back carrying how many IPC-peer losses it attributed.
  ##
  ## A READ THAT RAISES MUST NOT LEAVE ITS BUFFERS FOR THE NEXT CAPTURE.
  ## `collectEvidence` reuses ONE `MonitorPeerAttribution` across the
  ## recognized-report loop and catches `MonitorDepFileReaderError` PER RESOLVED
  ## PATH, so a truncated capture would otherwise hand its undecided losses to
  ## the next capture's records — the exact carry-forward `resolvePeerAttribution`
  ## says must not happen, reached by the one path that skips it. Dropping them
  ## is the conservative direction and not a lost downgrade: the caller grades a
  ## read failure as `mesMonitorUnavailable` and refuses the publish, which is
  ## strictly worse than the `mesUnknownScopeLoss` the deferred losses carried.
  ##
  ## DA-1i/DA-1j — `required` is the narrowest capture this build will trust,
  ## and it defaults to the STRICTEST answer so that a caller who has not
  ## thought about it gets the safe one. The backend-profile records carry both
  ## scope stamps, so they are collected as the stream goes past and graded
  ## once at the end by `gradeCaptureScope`; a capture that does not cover the
  ## requirement comes back `mesUnknownScopeLoss` with the reason in
  ## `evidence.diagnostics`, so the action succeeds and publishes nothing.
  result = mesComplete
  # Profile records only — a handful per capture, never the record body. The
  # streaming read exists so a 97k-record depfile is not materialized, and
  # grading its stamps must not undo that.
  var profileRecords: seq[MonitorRecord] = @[]
  try:
    for record in streamMonitorDepFileRecords(path,
        defaultMonitorDepFileReaderOptions()):
      if record.kind == mrBackendProfile:
        profileRecords.add(record)
      foldOneMonitorRecord(record, cwd, evidence, seen, result, attribution)
  except CatchableError:
    attribution.pendingIpcLosses.setLen(0)
    attribution.ipcRecords.setLen(0)
    raise
  resolvePeerAttribution(attribution, evidence, result)
  result = worseMonitorStatus(result,
    gradeCaptureScope(profileRecords, evidence, required))

proc foldMonitorDepFileEvidence*(path, cwd: string;
                                 evidence: var PathSetEvidence;
                                 seen: var EvidenceSeenSets):
                                 MonitorEvidenceStatus =
  ## Trust nothing — the four-argument form every caller predating DA-2 uses.
  var attribution = initMonitorPeerAttribution([])
  foldMonitorDepFileEvidence(path, cwd, evidence, seen, attribution)

proc foldMonitorRecordsEvidence*(records: openArray[MonitorRecord];
                                 cwd: string;
                                 evidence: var PathSetEvidence;
                                 seen: var EvidenceSeenSets;
                                 attribution: var MonitorPeerAttribution;
                                 required = FullMonitorEvidenceRequirement):
                                 MonitorEvidenceStatus =
  ## In-Process-Monitor-Hosting HM-5 — the same fold, over records the engine
  ## ALREADY HAS instead of over a file it has to read back.
  ##
  ## WHY THIS EXISTS, and it corrects the milestone's own premise. HM-5 is
  ## written on the claim that the ``.iomon`` is "a write-only artefact from the
  ## engine's perspective", evidenced by ``readMonitorDepFile`` having zero call
  ## sites. That is true of ``readMonitorDepFile`` and false of the file: the
  ## engine re-reads and re-decodes the ``.iomon`` on every monitored action
  ## through ``foldMonitorDepFileEvidence`` above, which is a hand-rolled iomon
  ## reader written precisely so the depfile object is not retained. So the
  ## flush could not have been made asynchronous on its own — a build that
  ## renamed the file into place behind the scheduler would have raced its own
  ## evidence collection and failed with ``mrMissingFile``.
  ##
  ## On the hosted path ``finishMonitor`` already returns the canonical,
  ## ordered records (``MonitorDepFile.records``, produced by
  ## ``depFileFromOwnedRecords`` from the very seq ``writeCanonicalInPlace``
  ## just wrote), so folding from them is FREE and the read-back is pure waste.
  ## Measured on this machine, a real ``nim c`` action's depfile — 97 217
  ## records, 18 MB — costs ~193 ms to read and decode, per action, on the
  ## scheduler's serial path. A trivial action's 140-record depfile costs
  ## ~0.4 ms.
  ##
  ## The records are borrowed, not retained: the caller drops them as soon as
  ## this returns, so the engine's "path sets + completeness, never a retained
  ## depfile" rule is unchanged.
  ##
  ## DA-1i/DA-1j — the scope stamps are graded here too, from the SAME records
  ## and by the SAME proc the file path uses. The hosted and wrapped paths are
  ## required to produce identical evidence for the same action
  ## (IoMon-Decomposed-Host-API DH-4); a guard wired to one of them is a guard
  ## half of production does not execute.
  result = mesComplete
  var profileRecords: seq[MonitorRecord] = @[]
  for record in records:
    if record.kind == mrBackendProfile:
      profileRecords.add(record)
    foldOneMonitorRecord(record, cwd, evidence, seen, result, attribution)
  resolvePeerAttribution(attribution, evidence, result)
  result = worseMonitorStatus(result,
    gradeCaptureScope(profileRecords, evidence, required))

proc foldMonitorRecordsEvidence*(records: openArray[MonitorRecord];
                                 cwd: string;
                                 evidence: var PathSetEvidence;
                                 seen: var EvidenceSeenSets):
                                 MonitorEvidenceStatus =
  ## Trust nothing — the four-argument form every caller predating DA-2 uses.
  var attribution = initMonitorPeerAttribution([])
  foldMonitorRecordsEvidence(records, cwd, evidence, seen, attribution)

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
    for enumerated in pathSet.enumerations:
      # Mirrors the ``mrDirectoryEnumerate`` arm of
      # ``foldMonitorDepFileEvidence``: an enumeration is BOTH an
      # existence dependency (so it stays in ``monitorProbes``, which
      # every existing consumer reads) AND a membership dependency (so it
      # is recorded separately for ``cacheEnumeratedDirectories``). A
      # converter-reported enumeration must land in exactly the same two
      # places as a monitor-reported one, or the two evidence sources
      # would disagree about what the same observation means.
      evidence.monitorProbes.addUnique(seen.monitorProbes, enumerated)
      evidence.monitorDirectoryEnumerations.addUnique(
        seen.monitorDirectoryEnumerations, enumerated)
  for diagnostic in pathSet.diagnostics:
    evidence.diagnostics.add(diagnostic)

proc collectConvertedEvidence(action: BuildAction;
                              specs: openArray[PostBuildDependencyConverterSpec];
                              evidence: var PathSetEvidence;
                              seen: var EvidenceSeenSets): bool

proc applyEntropyBlessingPolicy(action: BuildAction;
                                collection: var EvidenceCollection) =
  ## Windows-Build-Correctness M6 — the consumer half of the entropy
  ## blessing.
  ##
  ## io-mon reports THAT an executable consumed randomness and refuses to
  ## decide what it means: `mrNonDeterministic` deliberately does not force
  ## `mcIncomplete`, because the read WAS observed, so nothing is missing
  ## from the capture. This is the caller policy io-mon defers to.
  ##
  ## THE CONSEQUENCE, and why it is this one. An unblessed tool that read
  ## entropy loses its action-cache PUBLICATION (`disableCacheHits`) and
  ## nothing else. The action still runs, still succeeds, and its outputs
  ## are still used by everything downstream — which is right, because
  ## nothing about this evidence says the outputs are wrong. What it says is
  ## that they may not be REPRODUCIBLE, and a cache entry is a promise that
  ## re-running the same inputs yields the same bytes. Refusing to make that
  ## promise costs a rebuild; making it falsely serves the wrong bytes
  ## forever. Note also what is NOT done: `publishable` stays true (a
  ## non-deterministic action is not a failed action) and
  ## `monitorStatus` is untouched, so this does NOT trip the scheduler's
  ## session-wide `sessionCachePublishDisabled` — one tool's randomness must
  ## not make every other action in the build uncacheable.
  ##
  ## HOW `caller=system` IS HANDLED, which is the load-bearing decision.
  ## io-mon's Windows attribution token distinguishes main-EXE-image from
  ## everything else, NOT program from system (see `EntropyCallerOrigin`).
  ## Filtering `caller=system` away as "the loader's baseline" would silently
  ## grade an unblessed program deterministic whenever its randomness came
  ## through its own bundled DLL — a false clean, the exact failure this
  ## campaign exists to prevent. So EVERY origin is consequential here; the
  ## origin is recorded and reported but never used to excuse an observation.
  ##
  ## That is affordable because the feared cost did not materialise. Measured
  ## on this host against the M5 shim: a monitored `cmd /c ver` (39 records),
  ## `where.exe cmd` (336 records) and a full `nim c` compile driving gcc and
  ## ld (25 206 records, `mcComplete`, `eventLoss=0`) each produced ZERO
  ## `mrNonDeterministic` records — the ntdll startup baseline that would have
  ## flagged everything is not in fact reported for these programs. What did
  ## report was `powershell -NoProfile -Command 1+1`: three sources
  ## (`ProcessPrng`, `RtlGenRandom`, `CryptGenRandom`), all `caller=system`,
  ## i.e. a .NET interpreter host drawing randomness through its own runtime
  ## — precisely the case a `caller=system` filter would have excused.
  ##
  ## ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE. If the capture's own
  ## backend profile says entropy could not be observed, "no entropy records"
  ## carries no information, and an unblessed action is treated exactly as if
  ## it had read entropy. This is what makes the whole policy fail closed
  ## against an older shim or a backend without the capability, and it is
  ## read from the machinery M4/M5 built for it: the profile record's
  ## `supported=` list and the `mrCapabilityGap` records.
  if not action.cacheable:
    # An action that never publishes has nothing to withhold, and saying so
    # in its diagnostics would be noise on every fetch edge.
    return
  let observations = collection.evidence.entropyObservations
  if action.nonDeterminism == ndpEntropyBlessed:
    if observations.len > 0:
      var sources: seq[string] = @[]
      for observation in observations:
        sources.add(observation.source)
      collection.evidence.diagnostics.add(
        "entropy observed (" & sources.join(", ") & ") but the invoking " &
        "tool is blessed in its CLI spec, so it is not treated as a " &
        "determinism problem: " & action.nonDeterminismJustification &
        " Spec: Windows-Build-Correctness-Bitness-And-Capabilities." &
        "milestones.org M6.")
    return
  if observations.len > 0:
    var described: seq[string] = @[]
    for observation in observations:
      described.add(observation.source & " from " &
        describeEntropyOrigin(observation.origin))
    collection.evidence.diagnostics.add(
      "action-cache publish skipped: this action's process tree read " &
      "entropy (" & described.join("; ") & ") and the tool it invokes is " &
      "not blessed. Declare `nonDeterminism entropyBlessed, justification " &
      "= \"...\"` in the tool's CLI spec if its randomness cannot reach " &
      "its output. Note that caller attribution is one-way: an entropy " &
      "read reported from outside the main image is NOT evidence that the " &
      "program itself drew none. Spec: " &
      "Windows-Build-Correctness-Bitness-And-Capabilities.milestones.org M6.")
    collection.disableCacheHits = true
    collection.cacheIneligibilityReasons.incl(cirUnblessedEntropy)
    return
  if collection.evidence.entropyObservability != entObserved:
    collection.evidence.diagnostics.add(
      "action-cache publish skipped: the capture's backend " &
      (if collection.evidence.entropyObservability == entNotObserved:
         "declares that entropy reads are not observable"
       else:
         "is not declared at all (no backend-profile record), so entropy " &
         "observability is unknown") &
      ", and the tool this action invokes is not blessed. No " &
      "`mrNonDeterministic` record is therefore not evidence that no " &
      "randomness was consumed. Spec: " &
      "Windows-Build-Correctness-Bitness-And-Capabilities.milestones.org M6.")
    collection.disableCacheHits = true
    collection.cacheIneligibilityReasons.incl(
      if collection.evidence.entropyObservability == entNotObserved:
        cirEntropyUnobservable
      else:
        cirEntropyObservabilityUnknown)

proc monitorObservedNoReads(col: EvidenceCollection): bool {.inline.} =
  ## "Did the monitor report no read at all?" — as distinct from "is the read
  ## set empty", which it is not required to be for the answer to be yes.
  ##
  ## `collectEvidence` folds exactly one read no monitor reported, the
  ## action's own root image (`executedToolImagePath`). O(1) by construction:
  ## that entry is the FIRST thing added to the set, so a set with one element
  ## is the only one it can be alone in.
  ##
  ## ITS ONE BLIND SPOT, MEASURED RATHER THAN REASONED ABOUT, so that the next
  ## reader inherits the number instead of the argument. The set is a set: when
  ## a monitor really DID observe the action's own root image and nothing else
  ## — a nested exec of the same image on a platform with no library-load floor
  ## — `addUnique` collapses the observation and the reconstruction into one
  ## entry, this returns true, and the edge is refused a publish although it
  ## observed something. Measured on this host with a capture carrying one
  ## `mrFileRead` of `/bin/sh` against an `argv[0]` of `/bin/sh`: no record
  ## published, and the diagnostic told the operator to "suspect the monitor
  ## backend", which in that case is the wrong place to look.
  ##
  ## It is the FAIL-CLOSED direction — a lost cache hit and a re-run, never a
  ## stale artifact — so it is a cost, not a soundness hole, and it is not
  ## reachable on Linux or macOS, where the loader floor puts other paths in
  ## the set. Recorded here because a one-slot attribution cannot express "this
  ## path is both", and the fix if it ever matters is to make the attribution
  ## per-entry rather than to widen this predicate.
  case col.evidence.monitorReads.len
  of 0: true
  of 1:
    col.engineSuppliedRootImage.len > 0 and
      col.evidence.monitorReads[0] == col.engineSuppliedRootImage
  else: false

proc applyMonitorEvidenceStatus(action: BuildAction;
                                status: MonitorEvidenceStatus;
                                col: var EvidenceCollection) =
  ## Fold a monitor-evidence ``status`` (Level 0-3) into ``col``. Extracted
  ## so that two producers of monitor evidence share ONE mapping into
  ## ``monitorStatus`` / ``publishable`` / ``disableCacheHits`` /
  ## ``invalidatedPaths`` / diagnostics: the wrapped-or-hosted monitor path
  ## (which reads ``action.monitorDepfile`` or in-memory hosted records) and
  ## the ``iomon``-recognized-report path (an edge whose command PRODUCES its
  ## own ``.iomon`` dependency capture, consumed as the edge's evidence).
  col.monitorStatus = worseMonitorStatus(col.monitorStatus, status)
  case status
  of mesComplete:
    # An action that observed NOTHING is not cacheable, even though
    # the monitor reported success.
    #
    # This is the engine predicate that
    # `repro_core/dependency_gathering.nim` has documented since M17
    # ("actions with no monitorable evidence ... are made
    # NON-CACHEABLE, never marked complete-on-declared-inputs") and
    # that nothing enforced. It was documentation plus two
    # hand-applied `cacheable = false` call sites; an action that
    # reached this point with an empty observation set published a
    # record keyed on its declared inputs alone and was reused
    # against every change to everything else it touched.
    #
    # WHY IT MATTERS NOW. A zero-output edge used to be an
    # unconditional cache miss, so such an action re-ran regardless
    # of what its record said. Once test-execute edges became
    # cacheable on their recorded inputs alone, the record became the
    # only thing standing between the edge and a stale skip.
    #
    # WHY `disableCacheHits` AND NOT `publishable = false`.
    # Monitor-Hook-Shim.md:501 offers two arms — "fail the monitored
    # action OR make it non-cacheable, depending on policy". Failing
    # a successful, exit-0 action to punish its monitor is the wrong
    # one: it breaks builds for a soundness property that the
    # cheaper arm secures completely. Skipping the publish means the
    # action succeeds now and re-executes next time, which IS
    # non-cacheable.
    #
    # WHY NO "THIS ACTION DECLARES IT READS NOTHING" ESCAPE HATCH.
    # Three reasons, in order of weight. (a) The declaration is
    # unfalsifiable exactly where it is load-bearing: it only takes
    # effect when the evidence is empty, i.e. when the monitor cannot
    # corroborate it. (b) No such concept exists in the specs, and
    # its nearest neighbour — a declared-only gathering mode — is
    # explicitly prohibited and has been re-introduced by agents more
    # than once (see the note in
    # `repro_core/dependency_gathering.nim`). (c) On a platform with
    # a library-load floor it is not needed: measured on this host,
    # every process the shim can inject reports at least the loader
    # plus its dependent libraries (6 records for a `-nostdlib`
    # dynamic binary; 18 records naming 14 distinct paths / 9
    # distinct sonames for `env true`), and a process the shim CANNOT
    # inject — a static binary — already trips `mrEventLoss` and
    # lands on the Level 2 arm below. An edge that genuinely needs to
    # run without evidence already has a sanctioned answer with no
    # new soundness surface: `cacheable = false`.
    #
    # READ (c) NARROWLY — it is platform-conditional and the
    # condition is real. `MonitorHasLibraryLoadFloor` is false on
    # Windows, whose shim emits no library-load records at all, so
    # there an ordinary monitored action that performs no interposed
    # read, probe or write DOES reach this branch and stops
    # publishing for good. The guard is deliberately NOT scoped away
    # from such platforms: scoping it off would hand exactly the
    # platform with no floor the original soundness hole AND no
    # signal that it has it. Instead the diagnostic says which regime
    # it is in — see `zeroEvidenceDiagnostic` — so the outcome is a
    # report rather than a silent permanent non-publish. The
    # behaviour is the fail-closed direction on every platform; only
    # its reachability differs.
    #
    # The test is deliberately narrow — no observation of ANY kind
    # from ANY source, including a recognized report's
    # `depfileInputs`. An action with one recorded probe has said
    # something about the world and keeps its record.
    #
    # OBSERVED reads, not every read in the set. `collectEvidence` folds
    # ONE entry nobody observed: the action's own root image, which
    # `executedToolImagePath` reconstructs from argv precisely because
    # the launcher's exec precedes the shim's constructor and leaves no
    # record ("a reconstruction of the launcher's resolution, not an
    # observation of the kernel's"). It is a correct cache input and a
    # wrong answer to "did the monitor see anything": it resolves for
    # essentially every monitored action, so counting it left this guard
    # unable to fire at all from the day that fold landed.
    # `engineSuppliedRootImage` is what distinguishes the two, and
    # `t_zero_evidence_edge_is_not_cacheable` is what holds them apart.
    #
    # THE SAME QUESTION HAS TO BE ASKED OF EVERY CHANNEL BELOW. Any
    # future path by which the ENGINE contributes to one of these sets
    # from its own bookkeeping answers this question on the monitor's
    # behalf and silently retires the guard, exactly as the root-image
    # fold did. Record such a contribution the way
    # `engineSuppliedRootImage` records this one — attribution, not a
    # subtraction and not an ordering, per
    # `../reprobuild-specs/Dependency-Observation-Attribution.md`.
    if action.cacheable and
        col.monitorObservedNoReads() and
        col.evidence.monitorWrites.len == 0 and
        col.evidence.monitorProbes.len == 0 and
        col.evidence.monitorDirectoryEnumerations.len == 0 and
        col.evidence.depfileInputs.len == 0:
      col.evidence.diagnostics.add(
        zeroEvidenceDiagnostic(action.id, MonitorHasLibraryLoadFloor))
      col.disableCacheHits = true
      col.cacheIneligibilityReasons.incl(cirEmptyEvidence)
  of mesKnownScopeLoss:
    # M9.R.73.2 — spec Level 1 narrow path-set invalidation per
    # ``reprobuild-specs/Monitor-Loss-Path-Invalidation.md``. The
    # sole class io-mon currently emits at Level 1 is
    # kill-before-flush, whose invalidated-path predicate is the
    # action's own declared outputs (the soundness proof in the
    # memo). Populate ``invalidatedPaths`` with the materialized
    # output paths and let the scheduler fold them into a
    # session-scoped accumulator that gates DOWNSTREAM cache
    # lookups. The current action still publishes its own cache
    # entry — the narrow invalidation covers downstream consumers
    # of its outputs, not the action itself.
    col.evidence.diagnostics.add(
      "monitor depfile has known-scope loss; downstream cache " &
      "lookups intersecting this action's outputs will be skipped " &
      "this session per Failure-Semantics.md §Monitoring Failures " &
      "and Monitor-Loss-Path-Invalidation.md")
    if action.cacheable:
      for output in action.outputs:
        col.invalidatedPaths.incl(materialPath(action.cwd, output))
  of mesUnknownScopeLoss:
    # Spec Level 2: session cache-skip, action succeeds. Diagnostic
    # preserved for ``repro why``. ``publishable`` stays true so the
    # scheduler does NOT flip status to asFailed; ``disableCacheHits``
    # tells the scheduler to skip THIS action's
    # ``cache.recordActionResult`` publish. The unknown-scope
    # semantic is fully realized by the scheduler by observing this
    # ``mesUnknownScopeLoss`` status and flipping its own
    # ``sessionCachePublishDisabled`` bit — see the scheduler.
    col.evidence.diagnostics.add(
      "monitor depfile is incomplete (unknown-scope loss); " &
      "action-cache publish skipped this session per " &
      "Failure-Semantics.md §Monitoring Failures")
    if action.cacheable:
      col.disableCacheHits = true
      col.cacheIneligibilityReasons.incl(cirMonitorLoss)
  of mesMonitorUnavailable:
    # Unreachable from foldMonitorDepFileEvidence today (Level 3 is
    # asserted here only when the iomon path was empty), but future
    # readers may promote decode errors to Level 3 — keep the branch.
    col.evidence.diagnostics.add("monitor depfile is incomplete")
    if action.cacheable:
      col.publishable = false

proc preparedRunQuotaCommand(action: BuildAction;
                             config: BuildEngineConfig;
                             shellUmaskWrap = true): ReproCommandSpec
# Forward-declared so `collectEvidence` can grade THE SET THAT GETS KEYED
# rather than the set the monitor filled in — see `gradeKeyedInputSet`. The
# definitions stay beside the other key-construction helpers further down;
# only the visibility ordering moves.
proc cacheInputPaths*(action: BuildAction;
                      evidence: PathSetEvidence): seq[string]
proc evidenceInputPaths(action: BuildAction;
                        evidence: PathSetEvidence): seq[string]
# DA-1i/DA-1j — forward-declared for the same reason: `collectEvidence` has to
# state what it requires of a capture before it trusts one, and the definition
# belongs beside `monitorInterest`, which answers half of it. Two procs, one
# for each direction of the same contract (what we ASK io-mon for, what we
# DEMAND of what comes back), kept adjacent so they cannot drift apart.
proc monitorEvidenceRequirement(action: BuildAction;
                                config: ptr BuildEngineConfig):
                                MonitorEvidenceRequirement

proc isExecutableFile(path: string): bool =
  ## `execvp`'s candidate test, as close as a consumer can get to it: the
  ## entry must exist and carry an execute bit. `execvp` itself asks the
  ## kernel and keeps walking on `EACCES`; asking for any execute bit is the
  ## same decision for every candidate a build action can plausibly hit, and
  ## it never opens the file.
  if not fileExists(extendedPath(path)):
    return false
  try:
    let perms = getFilePermissions(extendedPath(path))
    {fpUserExec, fpGroupExec, fpOthersExec} * perms != {}
  except OSError, IOError:
    false

proc executedToolImagePath(action: BuildAction;
                           config: ptr BuildEngineConfig): string =
  ## The on-disk image this action's OWN root command names, resolved the way
  ## the launcher resolves it.
  ##
  ## WHY THE LAUNCHER HAS TO ANSWER THIS. io-mon's `execve` hook lives in the
  ## CHILD — it is installed by the preloaded shim's constructor, which runs
  ## only once the new image is already mapped. The launcher's exec of the
  ## action's ROOT image therefore happens strictly BEFORE any hook exists, so
  ## `mrProcessExec` covers NESTED execs and nothing else. Measured: an action
  ## whose `argv[0]` IS the tool produced a 19-record depfile containing that
  ## binary's six glibc shared objects and NOT the binary itself. No arm in
  ## `foldOneMonitorRecord` can close that, because there is no record.
  ##
  ## This is the untyped analogue of `resolvedExecutableDigest`
  ## (`repro_tool_profiles`), which already pins exactly this fact for
  ## DECLARED tools — the profile keys on what the resolution found rather
  ## than on the search path that found it. An edge that declares no tool refs
  ## had no equivalent, so its root image was in no cache key at all.
  ##
  ## RESOLUTION, AND WHAT IT IS AND IS NOT.
  ##
  ## * An absolute name needs no resolution and no environment — the launcher
  ##   execs exactly that path.
  ## * A name containing a separator is resolved against the action's `cwd`,
  ##   which is what POSIX `exec` does with it and what the launcher's own
  ##   `chdir` makes true.
  ## * A BARE name is the only case that needs a search, and the search runs
  ##   over the PATH that `preparedRunQuotaCommand` — the single authority
  ##   every launch path shares for the child's argv+env contract — puts in
  ##   the child's environment. Same string, same POSIX first-match rule.
  ##   It is a reconstruction of the launcher's resolution, not an observation
  ##   of the kernel's; `t_executed_binary_is_a_recorded_input.nim` is what
  ##   holds the two together end to end on a real build.
  ##
  ## `shellUmaskWrap = false` deliberately: the `/bin/sh -c 'umask 022 && …'`
  ## the wrapped launch paths add is the ENGINE's own scaffolding, sits ABOVE
  ## the monitor, and is identical for every action. Recording it would put
  ## one constant in every key and say nothing about the action.
  ##
  ## Returns "" when the image cannot be identified without guessing — a
  ## monitored argv that is not the canonical `repro internal io monitor … --`
  ## shape, a bare name that no PATH entry supplies, or no config to ask.
  ## Returning nothing leaves the pre-existing gap exactly as it was; it never
  ## invents a path.
  # `executedImageArgvIndex` is the shared answer to "which argument is the
  # action's own image", and it returns -1 for a monitor-wrapped argv whose
  # payload cannot be located — there the root image would be the `repro`
  # binary, which is the launcher and not the action, so say nothing rather
  # than record the wrong thing. `toolInputRoots` and
  # `keyedOnContentAddressedToolRoot` read the same function, which is what
  # keeps the elision, the key and this fold talking about one image.
  let base = executedImageArgvIndex(action.argv)
  if base < 0 or base >= action.argv.len:
    return ""
  let name = action.argv[base]
  if name.len == 0:
    return ""
  if name.isAbsolute:
    return name
  if name.contains(DirSep) or name.contains(AltSep):
    return os.normalizedPath(materialPath(action.cwd, name))
  if config == nil:
    return ""
  var searchPath = ""
  try:
    let command = preparedRunQuotaCommand(action, config[],
      shellUmaskWrap = false)
    for entry in command.env:
      if entry.startsWith("PATH="):
        searchPath = entry.substr("PATH=".len)
  except CatchableError:
    return ""
  if searchPath.len == 0:
    return ""
  for dir in searchPath.split(PathSep):
    # POSIX: an empty PATH element names the current working directory.
    let dirBase = if dir.len == 0: action.cwd else: dir
    if dirBase.len == 0:
      continue
    let candidate = materialPath(action.cwd, dirBase) / name
    if isExecutableFile(candidate):
      return os.normalizedPath(candidate)
  ""

proc gradeKeyedInputSet(action: BuildAction; col: var EvidenceCollection) =
  ## The zero-evidence guard, applied to the set the RECORD IS KEYED ON.
  ##
  ## `applyMonitorEvidenceStatus` asks "did the monitor observe anything?" of
  ## `evidence.monitorReads` and friends. That is the right question about the
  ## MONITOR, and it stays where it is. It is not the question about the KEY,
  ## because two engine-side subtractions run between those channels and
  ## `cacheInputPaths`: `toolInputRoots` (the action's own store roots) and
  ## `ignoredInputRoots` (author-declared prefixes, expanded against the
  ## engine's environment when `action.env` is silent). An action can therefore
  ## satisfy the first question and still publish a record keyed on nothing —
  ## measured, and quantified in `emptyKeyedInputSetDiagnostic`.
  ##
  ## IT MUST RUN AFTER EVERY CONTRIBUTOR TO THE KEY, the root-image fold at
  ## the head of `collectEvidence` included, or it grades a draft. That is not
  ## in tension with the sibling guard's rule, which is that a predicate over
  ## OBSERVED evidence must not read a channel the engine seeded: they are the
  ## same instruction — *ask each question of the final state of the set that
  ## question is about* — and the sets are different, which is exactly why the
  ## guard needs two call sites and not one. The sibling guard resolves its
  ## half by ATTRIBUTION rather than by ordering
  ## (`EvidenceCollection.engineSuppliedRootImage`), so this one is free to sit
  ## at the end without disarming it.
  ##
  ## SCOPED TO `monitorEvidenceRequired`, deliberately: that is the precondition
  ## of the guard this mirrors, so the two cover the same class of edge and a
  ## change to the scope moves both. An edge outside it is either declaring its
  ## own input set (where an empty key is the author's statement, not the
  ## engine's failure) or is not monitored at all.
  ##
  ## The `observed` denominator is what makes this a REPORT rather than a
  ## duplicate: when the observed channels were empty too, the monitor guard
  ## has already fired with its own, more specific message, and firing again
  ## would tell an operator the same thing twice in different words.
  if not action.cacheable or not action.monitorEvidenceRequired():
    return
  let observed = action.evidenceInputPaths(col.evidence).len
  if observed == 0:
    return
  let keyed = action.cacheInputPaths(col.evidence)
  if keyed.len > 0:
    return
  col.evidence.diagnostics.add(
    emptyKeyedInputSetDiagnostic(action.id, observed, observed))
  col.disableCacheHits = true

proc collectEvidence(action: BuildAction; strict: bool;
                     hostedRecords: ptr seq[MonitorRecord] = nil;
                     config: ptr BuildEngineConfig = nil):
                     EvidenceCollection =
  ## ``hostedRecords`` (HM-5) is the in-memory record set for an action the
  ## engine hosted the monitor for. When it is non-nil the monitor evidence is
  ## folded from it and the ``.iomon`` is NOT read back — which is what lets the
  ## file be published asynchronously, behind this call. It is a ``ptr`` rather
  ## than an ``openArray`` because the parameter has to be OPTIONAL: every
  ## other caller is a launch path with no records in hand, and a default is
  ## what keeps this one seam from spreading to all four of them. The pointee
  ## is a scheduler local that outlives the call, and the engine has no worker
  ## threads (see ``beginMonitorSpawnContext``), so there is no aliasing
  ## question here.
  result.publishable = true
  result.evidence.declaredInputs = action.inputs
  result.evidence.declaredOutputs = action.outputs
  # S5 — an action that declares the same path as BOTH an input and an
  # output consumes its own output: an incremental tool reading the state
  # a previous run left behind. That action is not hermetic, and the one
  # thing it must never do is silently take a cache hit on stale state.
  # It does not: ``cacheInputPaths`` adds the DECLARED inputs first and
  # unfiltered, so the path is in the key before the self-write filter is
  # consulted (see ``selfWrittenOutputKeys``). The fingerprint keeps
  # tracking it and the action misses on every run in which its own output
  # changed. Say that out loud rather than letting a permanent miss look
  # like a caching bug.
  for materialized in action.selfConsumedDeclaredPaths():
    result.evidence.diagnostics.add(
      "action declares '" & materialized & "' as both an input and an " &
      "output, so it consumes its own output and is not hermetic; the " &
      "path is retained in the action-cache input set (a stale hit " &
      "would be worse than a permanent miss). Spec: " &
      "Filesystem-Policy-And-Observed-Inputs.md §\"Source Rewrites\".")
  # Deferred-D4: track membership in side-car ``HashSet``s so adding the
  # k-th unique evidence entry costs O(1) instead of O(k). Monitor
  # records on a single action can exceed several thousand entries; the
  # legacy linear ``find`` made the per-action wrap-up the dominant
  # term on the 14-app / ~1044-action collections from B1/B3/B5.
  var seen: EvidenceSeenSets
  # DA-2/DA-4 — the class-3 trust this action's evidence is graded against:
  # every daemon THIS PROCESS SPAWNED (derived, DA-2) plus every daemon a
  # machine declaration named AND a check established the identity of
  # (declared, DA-4). Both are re-validated against the kernel on the way in,
  # so a dead pid, a recycled pid, or a peer that has exec'd into a different
  # program since it was checked exempts nothing.
  #
  # Shared by BOTH fold sites below — the recognized-`.iomon`-report arm and the
  # wrapped/hosted monitor arm — because an edge that produces its own capture
  # talks to the same daemons as one the engine monitors, and a guard wired at
  # one of two sites is a guard half of production does not execute.
  var attribution = initMonitorPeerAttribution(trustedDaemonRegistry())
  # DA-1i/DA-1j — what this build demands of a capture before it trusts one.
  # Shared by BOTH fold sites below for exactly the reason `attribution` is: an
  # edge that PRODUCES its own `.iomon` is the likeliest source of a capture
  # this build did not take — a teammate's, a CI runner's, an inner `ct test`'s
  # — so the arm that consumes such a file is the last one that may go
  # ungraded. See `monitorEvidenceRequirement`.
  let scopeRequirement = monitorEvidenceRequirement(action, config)
  # SCOPED TO THE AUTOMATIC-MONITOR CLASS on purpose. That is the class where
  # the ENGINE promises to discover the input set, so a missing input is the
  # engine's defect. On an edge whose inputs are declared by its author, the
  # author owns that set and the engine adding an undeclared path to the key
  # behind their back is a different decision, with a different blast radius,
  # and it is not the one this change makes.
  if action.dependencyPolicy.kind in MonitorPolicyKinds:
    let rootImage = executedToolImagePath(action, config)
    if rootImage.len > 0 and not rootImage.isVolatileMonitorPath():
      result.evidence.monitorReads.addUnique(seen.monitorReads, rootImage)
      # Remembered, not just added: the zero-evidence guard downstream asks
      # what the MONITOR saw, and this entry is a reconstruction rather than
      # an observation. See `EvidenceCollection.engineSuppliedRootImage`.
      result.engineSuppliedRootImage = rootImage
  let reports = action.reportSpecsForPolicy()
  if action.dependencyPolicy.kind in RecognizedPolicyKinds and reports.len == 0:
    result.evidence.diagnostics.add(
      "dependency policy requires a recognized report but none is declared")
    result.publishable = false
  for report in reports:
    if report.formatName == DependencyFormatName(IomonFormatName):
      # An edge whose command PRODUCES its own ``.iomon`` dependency
      # capture — e.g. ``ct test`` writing the io-mon record set of the
      # files it actually read — and the engine consumes THAT file as the
      # edge's evidence instead of monitoring the orchestrator process.
      # The text ``readRecognizedDependencyReport`` readers know nothing
      # about io-mon's binary record format, so this branch folds the file
      # through ``foldMonitorDepFileEvidence`` and maps the returned
      # ``MonitorEvidenceStatus`` through the SAME handling the wrapped /
      # hosted monitor path uses (``applyMonitorEvidenceStatus``). Path
      # resolution (literal / glob / required-missing) mirrors the
      # make-depfile branch below.
      for output in report.outputs:
        let path = action.expectedPath(output)
        let isGlob = '*' in path or '?' in path or '[' in path
        var resolvedPaths: seq[string] = @[]
        if isGlob:
          for resolved in walkPattern(path):
            resolvedPaths.add(resolved)
          if output.required and resolvedPaths.len == 0:
            result.evidence.diagnostics.add(
              "dependency report glob produced no matches: " & path)
            result.publishable = false
        elif output.required and not fileExists(extendedPath(path)):
          result.evidence.diagnostics.add("dependency report missing: " & path)
          result.publishable = false
        elif fileExists(extendedPath(path)):
          resolvedPaths.add(path)
        for resolved in resolvedPaths:
          try:
            let status = foldMonitorDepFileEvidence(resolved, action.cwd,
              result.evidence, seen, attribution, scopeRequirement)
            applyMonitorEvidenceStatus(action, status, result)
          except MonitorDepFileReaderError as err:
            result.evidence.diagnostics.add(
              "monitor depfile read failed: " & err.msg)
            result.monitorStatus = worseMonitorStatus(result.monitorStatus,
              mesMonitorUnavailable)
            if action.cacheable:
              result.publishable = false
      continue
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
    # M9.R.60.2 — for a non-cacheable action, monitor evidence completeness
    # can only be a DIAGNOSTIC signal, never a hard failure. No cache
    # entry's soundness depends on the completeness of a non-cacheable
    # action's evidence (the action always re-runs), so failing here
    # merely blocks the rebuild for zero soundness gain. This mirrors the
    # non-cacheable carve-out that ``setupMonitorDepfile`` already applies
    # on the missing-monitor-CLI path at repro_build_engine.nim:1731-1746
    # ("sanctioned home for pure network actions with no monitorable file
    # evidence -- e.g. workspace sync's git fetch (cacheable = false)").
    # The canonical trip is a fetch action's ``curl`` making an
    # ipc-connect to an out-of-tree HTTP peer (github.com,
    # freedesktop.org, ...): io-mon injects one synthetic mrEventLoss per
    # unmonitored-subtree/peer (writer.nim:1007-1036 class (c)), which
    # forced every from-source recipe's fetch action to fail regardless
    # of the fact that its exit code was 0. See M9.R.60.1's Phase A
    # characterization.
    # M9.R.72.3 — implement the spec's monitor-loss ladder from
    # Failure-Semantics.md §"Monitoring Failures":
    #   Level 0 (mesComplete):        publish action-cache record.
    #   Level 1 (mesKnownScopeLoss):  disable cache hits for this session
    #                                 (skip action-cache publish) but let
    #                                 the action succeed; a KNOWN scope
    #                                 loss (e.g. kill-before-flush of a
    #                                 specific pid) currently uses the same
    #                                 Level-2 handling until Gap II's
    #                                 narrow path-set invalidation ships.
    #   Level 2 (mesUnknownScopeLoss): disable cache hits for the session.
    #                                 Same handling as Level 1: succeed
    #                                 without publishing.
    #   Level 3 (mesMonitorUnavailable): fail closed. Only when the iomon
    #                                 path itself is absent OR the reader
    #                                 hits a decode error — genuine
    #                                 "monitoring unavailable" per spec.
    #
    # The previous ``mustFailOnIncompleteEvidence = action.cacheable`` flag
    # collapsed all of Levels 1/2/3 into Level 3, causing exit=0 actions
    # to flip to asFailed whenever io-mon injected even a single synthetic
    # mrEventLoss record. See M9.R.60.D + M9.R.68 + M9.R.70 characterizations
    # and recipes/reproos-image/run-evidence/m9r72/m9r72_phaseB_gap_enumeration.txt
    # Gap I.
    # There is no `monitorDepfile.len == 0` arm here, and there must not
    # be one: `monitorEvidenceRequired` — the condition guarding this
    # whole block — already requires `monitorDepfile.len > 0`, so such a
    # branch is unreachable. It existed and was dead. The Level 3
    # "monitoring unavailable" case it claimed to cover is decided
    # EARLIER and differently: `monitoredAction` returns a
    # "requires an io-monitor driver" diagnostic for a cacheable action
    # with no monitor CLI, and the scheduler turns a non-empty
    # `plan.diagnostic` into `asFailed`. That is the FAIL arm, not the
    # non-cacheable arm; do not describe it as the latter.
    try:
      # HM-5 — two SOURCES, one set of folding rules (``foldOneMonitorRecord``).
      # The hosted arm never touches the filesystem, so the ``.iomon`` may still
      # be in flight behind this call; the wrapped arm is byte-for-byte what it
      # always was, because on that path the engine has no records — a separate
      # ``repro internal io monitor`` process produced them.
      let status =
        if hostedRecords != nil:
          foldMonitorRecordsEvidence(hostedRecords[], action.cwd,
            result.evidence, seen, attribution, scopeRequirement)
        else:
          foldMonitorDepFileEvidence(action.monitorDepfile,
            action.cwd, result.evidence, seen, attribution, scopeRequirement)
      applyMonitorEvidenceStatus(action, status, result)
      applyEntropyBlessingPolicy(action, result)
    except MonitorDepFileReaderError as err:
      result.evidence.diagnostics.add("monitor depfile read failed: " & err.msg)
      # A decode error means the iomon file is corrupt — cannot classify the
      # loss scope, must fail closed on a cacheable action.
      result.monitorStatus = worseMonitorStatus(result.monitorStatus,
        mesMonitorUnavailable)
      if action.cacheable:
        result.publishable = false
  # M9.R.75 — R6 (source-write reject) post-hoc monitor-evidence check.
  # Spec cite: reprobuild-specs Filesystem-Policy-And-Observed-Inputs.md
  # §"Source Rewrites" (lines 264-278): "source rewrites are errors" is
  # the shipping default. For every write recorded in monitorWrites
  # whose path lies inside a declared readOnlyRoots entry, fail the
  # action with a structured "source-write attempt" error.
  #
  # This is Shape B (post-hoc monitor check) from the M9.R.75 Phase A
  # audit. Shape A (bwrap sandbox) would be the primary Linux
  # enforcement; Shape B is the cross-platform fallback (and the only
  # option on Windows). Both approaches read from the same readOnlyRoots
  # declaration on ``BuildAction`` — this check is the immediate
  # milestone deliverable; the bwrap wrapper can be layered on top
  # later without changing the DSL surface.
  #
  # Fetch actions leave readOnlyRoots empty per R6's "action explicitly
  # owns the target location" carve-out, so the check no-ops for them.
  # Legacy actions predate the field and also see an empty seq (v21
  # payload compatibility), so they are unaffected.
  if action.readOnlyRoots.len > 0 and result.evidence.monitorWrites.len > 0:
    let offenders = detectSourceWrites(action.readOnlyRoots,
      result.evidence.monitorWrites)
    for offender in offenders:
      result.evidence.diagnostics.add(
        "source-write attempt (R6): action wrote to '" & offender.write &
        "' which lies under nominally-read-only root '" & offender.root &
        "'. Spec: Filesystem-Policy-And-Observed-Inputs.md " &
        "§\"Source Rewrites\" — default policy is 'source " &
        "rewrites are errors'.")
    if offenders.len > 0:
      result.publishable = false
  # LAST OF ALL, after every contributor to the key — the root-image fold at
  # the head of this proc included — grade the set the key is actually built
  # from. Rule 7. See `gradeKeyedInputSet`.
  gradeKeyedInputSet(action, result)
  if strict and not result.publishable:
    discard

proc selfWrittenOutputKeys(action: BuildAction): HashSet[string] =
  ## S5 — the action's OWN declared output paths, keyed in the normalized
  ## (forward-slash, materialized) form the input folds compare on. The
  ## observed-evidence channels are filtered against this set before they
  ## reach the action-cache key.
  ##
  ## Why an own declared output is never an input: a linker, an archiver
  ## and a compiler all OPEN the file they are writing (and stat/probe it
  ## first), and the monitor faithfully records that access as a read.
  ## Those bytes are bytes the action produced *in this same run* — the
  ## content that was there before cannot affect a hermetic result, so
  ## the prior content is not an input. Recording it as one makes the
  ## action depend on itself: the fingerprint can never match once the
  ## output exists or changes, which costs a hit on every relink and
  ## makes CAS restore of a deleted output structurally impossible.
  ## Spec: ``reprobuild-specs/Filesystem-Policy-And-Observed-Inputs.md``
  ## §"Writable Output Scopes" — a declared output is a writable scope,
  ## not a dependency-relevant read scope.
  ##
  ## The exclusion is deliberately as narrow as it can be: EXACT declared
  ## output paths of THIS action, matched by string equality after
  ## materialization. No directory containment, no prefix rule, no
  ## "looks like an output" heuristic — an over-broad filter here would
  ## drop a genuine input that merely lives next to an output, and
  ## dropping a genuine input is a false cache hit, the cardinal sin.
  ##
  ## There is one case where an own declared output IS a real input: an
  ## incremental tool that reads the state a previous run left behind,
  ## declaring the same path as input and output. That action is not
  ## hermetic and must NOT silently get a hit. It doesn't, and NOT because
  ## of anything in this set — the carve-out is structural. Both folds
  ## below add ``evidence.declaredInputs`` FIRST and UNFILTERED, so a path
  ## the author declared as an input is in the key before this set is ever
  ## consulted. Declaration outranks every filter; that is the same
  ## principle ``cacheInputPaths``' ``declaredMaterialized`` retention
  ## encodes for the tool-root filter. ``selfConsumedDeclaredPaths`` +
  ## ``collectEvidence`` name such an action in a diagnostic so the
  ## permanent miss that follows does not read as a caching bug.
  result = initHashSet[string]()
  for output in action.outputs:
    result.incl(materialPath(action.cwd, output).replace('\\', '/'))

proc evidenceInputPaths(action: BuildAction;
                        evidence: PathSetEvidence): seq[string] =
  # Deferred-D4: side-car ``HashSet`` keeps the per-action wrap-up linear
  # in N rather than quadratic. The output ``seq`` preserves insertion
  # order — callers downstream of action-cache key construction (see
  # ``cacheInputPaths``) depend on it for stable fingerprints.
  #
  # S5: the observed channels are filtered against the action's own
  # declared outputs; see ``selfWrittenOutputKeys``. Declared inputs are
  # never filtered.
  let selfWritten = action.selfWrittenOutputKeys()
  var seen = initHashSet[string]()
  for input in evidence.declaredInputs:
    result.addUnique(seen, input)
  for input in evidence.depfileInputs:
    if selfWritten.contains(materialPath(action.cwd, input).replace('\\', '/')):
      continue
    result.addUnique(seen, input)
  for input in evidence.monitorReads:
    if selfWritten.contains(materialPath(action.cwd, input).replace('\\', '/')):
      continue
    result.addUnique(seen, input)
  for probe in evidence.monitorProbes:
    if selfWritten.contains(materialPath(action.cwd, probe).replace('\\', '/')):
      continue
    result.addUnique(seen, probe)

proc addContentAddressedRoot(roots: var seq[string]; path: string) =
  ## AN EMPTY ROOT MUST NEVER ENTER THIS SEQUENCE, and `addUnique` is what
  ## stops it: its first statement is `if value.len == 0: return`.
  ##
  ## The consequence is worth stating because it is severe and silent. These
  ## roots reach `isUnderAnyRoot`, which answers `startsWith(root & "/")` — so
  ## a single `""` in here matches EVERY absolute path, `cacheInputPaths`
  ## subtracts the entire observed set, and the record is keyed on nothing.
  ## `contentAddressedRoot` returns `""` for the overwhelming majority of the
  ## paths handed to it (every `PATH` entry of every non-store action), so
  ## this is the common case, not an edge one.
  ##
  ## There used to be an `if root.len > 0:` here as well. It could not change
  ## an answer — `addUnique` had already made `""` mean "add nothing" — and a
  ## conjunct no mutation can redden is one a later reader takes for
  ## load-bearing. The guarantee is named here instead of duplicated.
  roots.addUnique(contentAddressedRoot(path))

proc envValue(action: BuildAction; name: string): string =
  let prefix = name & "="
  for item in action.env:
    if item.startsWith(prefix):
      return item.substr(prefix.len)

proc toolInputRoots(action: BuildAction): seq[string] =
  ## The content-addressed roots whose contents `cacheInputPaths` may elide
  ## from the action-cache key, and — read together with the note below —
  ## the reason it may.
  ##
  ## EVERY ROOT THIS RETURNS IS IN THE WEAK FINGERPRINT BY CONSTRUCTION.
  ## Dependency-Observation-Attribution.md §Class 1 allows the elision only
  ## when the root is content-addressed AND its identity is in the key, and
  ## for a long time this function supplied the first half and merely assumed
  ## the second. The two halves are now connected, per source:
  ##
  ## * `argv[0]` — `keyedOnContentAddressedToolRoot`, applied in `action()`
  ##   over exactly this `contentAddressedRoot` call, so the root subtracted
  ##   here is the root mixed there. Before that existed, a monitored edge
  ##   under the engine-default fingerprint took a `cdHit` after its
  ##   `/nix/store` shell was swapped for a different store path — measured;
  ##   see that proc. The key additionally carries the image's own path
  ##   within the root, which is strictly more than this drops.
  ## * `PATH` / `NODE_PATH` — `keyedOnActionEnvironment`, also applied in
  ##   `action()`, which mixes every DECLARED name and value. `envValue` reads
  ##   `action.env`, the same declaration, so a value that yields a root here
  ##   is a value that is in the key there. A passthrough variable is in
  ##   neither: the key carries only its name, and `envValue` returns "".
  ##
  ## An elision that stops being covered by one of those is a soundness
  ## regression, not a tuning change. `gradeKeyedInputSet` is the backstop
  ## that reports the case where the subtraction empties the key entirely.
  ##
  ## `executedImageArgvIndex` rather than a bare `argv[0]`, because by the time
  ## this runs the argv may be the monitor wrapper's — see that proc for what
  ## reading index 0 through the wrapper subtracted, and failed to subtract.
  let imageIndex = executedImageArgvIndex(action.argv)
  if imageIndex >= 0:
    result.addContentAddressedRoot(action.argv[imageIndex])
  for value in action.envValue("PATH").split(PathSep):
    result.addContentAddressedRoot(value)
  for value in action.envValue("NODE_PATH").split(PathSep):
    result.addContentAddressedRoot(value)

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

proc cacheInputPaths*(action: BuildAction; evidence: PathSetEvidence): seq[string] =
  ## The action-cache key's input path set: the paths whose content or
  ## metadata a later run compares against to decide ``cdHit`` /
  ## ``cdMiss``. Exported for the regression tests that pin the two
  ## properties below directly (same precedent as ``EvidenceSeenSets`` /
  ## ``foldMonitorDepFileEvidence``); the engine's three publish sites
  ## are the only production callers.
  ##
  ## Two filters apply, and they are NOT the same rule:
  ##
  ## * the tool-root / ignored-prefix filter drops observed reads under
  ##   the toolchain's own store roots. ``declaredMaterialized`` exempts
  ##   anything the action DECLARED as an input from that filter — the
  ##   declaration is the author's statement that this path is a real
  ##   dependency, and a heuristic must not overrule it (a declared
  ##   input that happens to live inside a ``/nix/store`` tool root, for
  ##   instance, would otherwise be silently dropped from the key).
  ## * S5's self-write filter drops the action's OWN declared outputs
  ##   from the OBSERVED channels only — see ``selfWrittenOutputKeys``
  ##   for why those are provably not inputs, and for the
  ##   declared-input carve-out that keeps the two filters from
  ##   colliding. Declared inputs are never dropped by either filter.
  let toolRoots = action.toolInputRoots()
  let ignoredRoots = action.ignoredInputRoots()
  let selfWritten = action.selfWrittenOutputKeys()
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
    let key = path.replace('\\', '/')
    if selfWritten.contains(key):
      continue
    if not declaredMaterialized.contains(key) and
        (path.isUnderAnyRoot(toolRoots) or path.isUnderAnyRoot(ignoredRoots)):
      continue
    result.addUnique(seen, path)
  for input in evidence.monitorReads:
    let path = materialPath(action.cwd, input)
    let key = path.replace('\\', '/')
    if selfWritten.contains(key):
      continue
    if not declaredMaterialized.contains(key) and
        (path.isUnderAnyRoot(toolRoots) or path.isUnderAnyRoot(ignoredRoots)):
      continue
    result.addUnique(seen, path)
  for probe in evidence.monitorProbes:
    let path = materialPath(action.cwd, probe)
    let key = path.replace('\\', '/')
    if selfWritten.contains(key):
      continue
    if not declaredMaterialized.contains(key) and
        (path.isUnderAnyRoot(toolRoots) or path.isUnderAnyRoot(ignoredRoots)):
      continue
    result.addUnique(seen, path)

proc actionEnvLookup*(action: BuildAction; name: string):
    tuple[present: bool, value: string] =
  ## The value the ACTION would see for `name`, and whether it is set at all.
  ##
  ## Resolved against `action.env` -- the environment the engine composed for
  ## this action -- and NOT against the daemon's own process environment,
  ## which is a different set entirely. `envValue` above answers "" for both
  ## unset and set-to-empty; the cache has to tell them apart, because a
  ## program branching on "is this variable defined" sees the difference.
  let prefix = name & "="
  when defined(windows):
    # Case-insensitive, matching how Windows itself resolves a lookup.
    let wanted = prefix.toUpperAscii
    for item in action.env:
      if item.len >= wanted.len and item[0 ..< wanted.len].toUpperAscii == wanted:
        return (true, item.substr(wanted.len))
  else:
    for item in action.env:
      if item.startsWith(prefix):
        return (true, item.substr(prefix.len))
  (false, "")

proc cacheEnvInputs*(action: BuildAction; evidence: PathSetEvidence):
    seq[EnvFingerprint] =
  ## The action-cache key's OBSERVED ENVIRONMENT set: each variable io-mon saw
  ## the action read, paired with the value it held at the time.
  ##
  ## This is the consumer half of io-mon's `mcapObservedEnv`. The shim records
  ## that the build ASKED for a variable; only the engine knows what it
  ## answered, and only the engine can re-read it on the next lookup to decide
  ## whether the recorded result still applies.
  ##
  ## Sorted by key so two runs that observed the same variables in different
  ## orders produce the SAME strong fingerprint. The file-input list gets its
  ## determinism from a fixed traversal order; observed env reads arrive in
  ## whatever order the program happened to make them, which for a threaded
  ## build is not stable across runs -- and an unstable key is a permanent
  ## cache miss, indistinguishable from a correct invalidation.
  var names = evidence.monitorEnvReads
  names.sort(proc (a, b: string): int = cmp(envNameKey(a), envNameKey(b)))
  for name in names:
    let resolved = action.actionEnvLookup(name)
    result.add(EnvFingerprint(name: name, present: resolved.present,
      value: resolved.value))

proc actionEnvResolver*(action: BuildAction): EnvResolver =
  ## `cacheEnvInputs`' counterpart for the LOOKUP side: how the action cache
  ## re-reads a recorded variable when deciding hit or miss.
  ##
  ## A closure over a COPY of the action's env, because the resolver outlives
  ## this call and the store calls it while walking records.
  let env = action.env
  result = proc(name: string): tuple[present: bool, value: string]
      {.gcsafe, raises: [].} =
    let prefix = name & "="
    when defined(windows):
      let wanted = prefix.toUpperAscii
      for item in env:
        if item.len >= wanted.len and
            item[0 ..< wanted.len].toUpperAscii == wanted:
          return (true, item.substr(wanted.len))
    else:
      for item in env:
        if item.startsWith(prefix):
          return (true, item.substr(prefix.len))
    (false, "")

proc honouredDerivedPrefixes*(action: BuildAction): seq[string] =
  ## S7 — the subset of the action's ``ignoredInputPrefixes`` that the
  ## restore gate may read as "machine-local derived state, not product",
  ## materialized against the action's ``cwd``.
  ##
  ## *This proc exists because the two readings of ``ignoredInputPrefixes``
  ## are not the same claim, and conflating them silently loses build
  ## products.* The field's established meaning is about the cache KEY:
  ## "do not treat what I read under here as a discovered input". The
  ## reason recipes reach for it is usually self-invalidation — see
  ## ``cmake_package.nim``'s install edge, whose comment says so in as many
  ## words: *"Treating either mutable tree as a discovered input makes the
  ## install edge depend on its own previous writes and miss on every warm
  ## build."* That is a statement about inputs. It says nothing whatsoever
  ## about whether the bytes under the prefix are part of what the action
  ## PRODUCES, and the restore gate needs the second claim, not the first.
  ##
  ## Where the two come apart is not hypothetical, and it is not a corner:
  ## it is the shape of every from-source package edge in the stdlib. The
  ## ``cmake --install`` edge declares ``outputs = @[installStamp]``, a
  ## single stamp file; its real product is the staged install tree under
  ## ``effectiveDestRoot``; and it lists that very same
  ## ``effectiveDestRoot`` as an ignored input prefix. Read naively, the
  ## exclusion below would exempt the entire product, the gate would see
  ## nothing unaccounted for, the record would be published WITH payloads,
  ## and a later build would report ``cdHit`` / ``restored`` having put back
  ## only the stamp. Reproduced through a real ``runBuild`` during review:
  ## green build, reported cache hit, install tree gone.
  ## ``meson_package.nim``'s setup / compile / install edges have the
  ## identical shape.
  ##
  ## The rule, therefore: *a derived-state prefix is honoured only where it
  ## is DISJOINT from everything the action has declared as its own
  ## product.* An author who says both "my product goes here" and "ignore
  ## what I write here" has made the KEY claim, not the PRODUCT claim, and
  ## the gate must not upgrade one into the other on their behalf. Two
  ## declarations count as product:
  ##
  ## * ``action.declaredOutputs`` — the M9.R.75 write ROOTS. Overlap is
  ##   tested with ``writeRootsOverlap``, the same predicate M9.R.75's own
  ##   R7 pairwise pass uses, and in BOTH directions, because two directory
  ##   subtrees intersect exactly when one contains the other. Both
  ##   directions are load-bearing: ``cmake-install`` names the write root
  ##   itself as a prefix (equal), and also names the build directory ABOVE
  ##   it (prefix contains root), and the second would exempt the staged
  ##   tree just as thoroughly as the first.
  ## * ``action.outputs`` — the declared product FILES, for actions that
  ##   carry no write-root declaration at all. A prefix containing a
  ##   declared output is not describing scratch space; the file itself
  ##   stays exempt through ``selfWrittenOutputKeys`` either way, so all
  ##   this costs is that its undeclared NEIGHBOURS are seen again.
  ##
  ## Note the asymmetry with ``ignoredInputRoots``' use in
  ## ``cacheInputPaths``: this side materializes the prefix against
  ## ``action.cwd`` while the input side compares raw, so a RELATIVE prefix
  ## is honoured here and inert there. That difference is deliberate and it
  ## is this side that is right — a recipe spells its scratch directory the
  ## way it spells its outputs, and a declaration the author wrote must not
  ## be honoured or ignored depending on whether they happened to write it
  ## absolute. Aligning the input side would drop paths that are in cache
  ## KEYS today, so it is a separable change and is not made here.
  ##
  ## Nothing here weakens the nimcache declaration this milestone added to
  ## ``nim.nim``: a ``nim c`` edge carries no ``declaredOutputs``, and its
  ## nimcache (``build/nimcache/<name>``) contains none of its declared
  ## outputs (``build/bin/<name>.exe``), so the prefix is disjoint from the
  ## product and stays honoured. That is the same fact stated as a rule
  ## rather than as a coincidence — and it is what makes the ``nimcache =``
  ## passthrough safe: a recipe that pointed a nimcache at its own output
  ## directory would lose the exemption and fail closed instead of silently
  ## exempting its binary's neighbours.
  proc coverageKey(path: string): string =
    ## Case-FOLDED on Windows, unlike every other comparison in this family.
    ## The direction is what decides it: the other comparisons ask "is this
    ## observed write one of my outputs?", where a case-folded match could
    ## exempt a path that is not the output and hand back a hit, so they
    ## stay case-sensitive. This one asks "does this prefix cover my
    ## product?", where a MISSED match re-enables the exemption and loses
    ## the product. Folding is the fail-closed direction here and the
    ## strict spelling is the fail-closed direction there.
    let normalized = normalizeWriteRoot(path)
    when defined(windows): normalized.toLowerAscii()
    else: normalized

  var productRoots: seq[string] = @[]
  for root in action.declaredOutputs:
    let normalized = coverageKey(materialPath(action.cwd, root))
    if normalized.len > 0:
      productRoots.add(normalized)
  var productFiles: seq[string] = @[]
  for output in action.outputs:
    let normalized = coverageKey(materialPath(action.cwd, output))
    if normalized.len > 0:
      productFiles.add(normalized)
  for raw in action.ignoredInputRoots():
    let materialized = materialPath(action.cwd, raw)
    let prefix = coverageKey(materialized)
    if prefix.len == 0:
      continue
    var covers = false
    for root in productRoots:
      if writeRootsOverlap(prefix, root):
        covers = true
        break
    if not covers:
      for file in productFiles:
        if pathAtOrUnderRoot(file, prefix):
          covers = true
          break
    if covers:
      continue
    result.add(materialized)

proc undeclaredSurvivingWrites*(action: BuildAction;
                                evidence: PathSetEvidence): seq[string] =
  ## S7 — the paths this action was OBSERVED to write that its declared
  ## outputs do not account for and that are still on disk when the action
  ## finishes. A non-empty result means "restoring this action's declared
  ## outputs is NOT equivalent to re-running it", and the engine responds by
  ## publishing the record without payloads so the restore branch cannot be
  ## taken for it. See ``BuildEngineConfig.requireCompleteOutputEvidence``.
  ##
  ## Three exclusions, and each of them is a claim about the path being
  ## irrelevant to a restore rather than a convenience:
  ##
  ## * the action's own DECLARED outputs — those are exactly what a restore
  ##   puts back, so writing them is the action doing its job.
  ##   ``selfWrittenOutputKeys`` supplies the same normalized, exact-match
  ##   set S5's input filter uses, for the same reason: no directory rule,
  ##   no prefix rule.
  ## * anything at or under one of the action's HONOURED derived prefixes —
  ##   see ``honouredDerivedPrefixes``, which is where the whole of that
  ##   exclusion's safety argument lives. It is NOT simply
  ##   ``ignoredInputPrefixes``: a prefix that overlaps the action's own
  ##   declared product is dropped, because such a prefix is a statement
  ##   about the cache KEY and not about the PRODUCT.
  ## * writes that no longer exist, or that are DIRECTORIES.
  ##
  ## The last one is not an optimization, it is required for the gate to
  ## mean anything. The monitor records a directory creation as a write, so
  ## a real ``nim c`` edge reports ``build/``, ``build/bin/`` and every
  ## intermediate above them — including the parent of its own declared
  ## output. Measured through the real CLI on the reference program (a
  ## one-file ``hello.nim`` whose body is one ``echo``; see ``nim.nim``'s
  ## ``compileDependencyPolicy`` for the full invocation, which is the one
  ## measurement this milestone quotes anywhere it needs a number): *41
  ## observed writes*, of which the gate reports 15 once directories,
  ## transients and the declared binary are set aside — and those 15 are
  ## the nimcache, which is what the ``nim.nim`` declaration is for. A
  ## restore that materializes a declared output creates its parent
  ## directories on the way (``casMaterialize`` does), and a directory with
  ## no files in it is not a product, so nothing is lost by skipping them —
  ## an undeclared product inside a directory is caught by the FILES it
  ## contains, which is how the motivating clone-tree case is caught.
  ## Transient files are the same argument in a different shape: a tool that
  ## writes a temp file and unlinks it has produced nothing to restore.
  ##
  ## Note what is NOT excluded. ``action.declaredOutputs`` — the M9.R.75
  ## write ROOTS — does not exempt anything, and must not: the motivating
  ## failure is an action that wrote its real product INSIDE its own write
  ## root without declaring the product itself. Exempting write roots would
  ## make the gate blind to precisely the case it exists for. It is read
  ## here only in the OPPOSITE direction, to DISQUALIFY a derived prefix
  ## that covers one.
  ##
  ## Comparison is by exact string equality after separator normalization,
  ## and is therefore case-SENSITIVE even on Windows. That direction is the
  ## safe one: a declared output observed under a different case spelling is
  ## reported here, which costs the action its blobs and a rebuild. The
  ## reverse — case-folding, and so matching a path that is not the declared
  ## output — would hand back a hit.
  let selfWritten = action.selfWrittenOutputKeys()
  let derivedRoots = action.honouredDerivedPrefixes()
  var seen = initHashSet[string]()
  for write in evidence.monitorWrites:
    let path = materialPath(action.cwd, write)
    if selfWritten.contains(path.replace('\\', '/')):
      continue
    if path.isUnderAnyRoot(derivedRoots):
      continue
    if dirExists(path) or not fileExists(path):
      continue
    result.addUnique(seen, path)

proc cacheEnumeratedDirectories(action: BuildAction;
                                evidence: PathSetEvidence): seq[string] =
  ## The subset of this action's recorded inputs that it ENUMERATED, in the
  ## same materialised form `cacheInputPaths` produces, so the record side
  ## can match them by path.
  ##
  ## Filtered by the same tool/ignored-root rules as `cacheInputPaths`: a
  ## path excluded from the inputs must not be handed over as an enumerated
  ## one either, or the record would carry membership for something it does
  ## not record at all.
  let toolRoots = action.toolInputRoots()
  let ignoredRoots = action.ignoredInputRoots()
  var declaredMaterialized = initHashSet[string]()
  for input in evidence.declaredInputs:
    declaredMaterialized.incl(
      materialPath(action.cwd, input).replace('\\', '/'))
  var seen = initHashSet[string]()
  for dir in evidence.monitorDirectoryEnumerations:
    let path = materialPath(action.cwd, dir)
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

proc monitorInterest(action: BuildAction): set[EventCategory] =
  ## The event categories `action` asks io-mon for — ONE definition, read by
  ## BOTH hosting forms, and today the answer is always `FullInterest`.
  ##
  ## THIS IS ONE PROC BECAUSE THE TWO PATHS DIVERGING WAS A LIVE DEFECT, not
  ## because two copies of four lines offended anyone. The reduction used to be
  ## spelled once in `monitorHostRequest`, where it took effect, and once in
  ## `launchChildEnv` as a `REPRO_MONITOR_INTEREST` env seed that io-mon's
  ## `childEnv` overwrote before any shim could read it — so the same action
  ## asked for `{file, proc, lib}` when the engine hosted io-mon in-process and
  ## got everything when it spawned `repro internal io monitor`.
  ## (Engine-Threadpool FINDING 2, as corrected.) Both call sites now read this
  ## proc, and the wrapped path forwards the answer to the CLI with
  ## `--interest`, a channel io-mon does not own and therefore cannot overwrite.
  ##
  ## WHY THE ANSWER IS "EVERYTHING", when the reduction it replaces looked so
  ## reasonable. The old comment said a build edge wants file/process/library
  ## dependencies and not "the clock/env/sysctl/entropy or IPC a tool
  ## incidentally touches". That is true of what those records DESCRIBE and
  ## false of what this engine DOES with them. io-mon's categories are
  ## deliberately coarse — five buckets, no per-kind filtering
  ## (io-mon/docs/contributors/event-interest-filter.md §7) — and each of the
  ## two categories the reduction dropped carries a record kind this engine
  ## reads to make a cache-correctness decision:
  ##
  ##   * `ecNonDeterminism` carries `mrEnvRead`, which lands in
  ##     `PathSetEvidence.monitorEnvReads` and reaches the STRONG FINGERPRINT
  ##     through `cacheEnvInputs`. Without the category, an action that reads
  ##     `PWD` / `SOURCE_DATE_EPOCH` and produces different bytes for different
  ##     values keys identically for all of them — the false-hit class the
  ##     observed-env cache key exists to close.
  ##   * `ecNonDeterminism` also carries `mrNonDeterministic`, which lands in
  ##     `entropyObservations`. Without the category `applyEntropyBlessingPolicy`
  ##     sees zero observations while `entropyObservability` still says
  ##     `entObserved` — the backend-profile record is META and `recordWanted`
  ##     never gates it — so it PUBLISHES. "Observable, and nothing observed" is
  ##     verbatim the false clean that policy's own doc comment says it exists
  ##     to prevent, reached by asking the monitor not to look.
  ##   * `ecIpc` carries `mrIpcConnect` and `ecNonDeterminism` also carries
  ##     `mrExternalContent`, and BOTH are completeness-bearing. io-mon's
  ##     `mergeFragments` turns each out-of-tree IPC peer
  ##     (`unmonitoredSubtreeLossDetails`) and each unpaired external content
  ##     channel (`externalContentLossCount`) into a synthetic `mrEventLoss`,
  ##     which is what forces `mcIncomplete` on an edge whose tree consumed
  ##     something the monitor could not see. The shim's interest gate drops
  ##     those records at `emitRecord` — BEFORE `mergeFragments` runs — so
  ##     suppressing either category does not merely hide records, it turns an
  ##     `mcIncomplete` edge into an `mcComplete` one. That is the cardinal
  ##     sin. io-mon's own §6 ("disabling a category is a consumer choice, not
  ##     data loss") is stated for the whole feature and is simply not true of
  ##     these two kinds; the loss markers they generate are never gated, but
  ##     they are also never generated.
  ##
  ## So there is no reduction available at this granularity that is safe for a
  ## reprobuild edge, and this proc says so in one place instead of three.
  ## Narrowing it again needs io-mon to change first — `mrEnvRead` and
  ## `mrNonDeterministic` split out of `ecNonDeterminism`, and `mrIpcConnect`
  ## made ungateable like the other completeness-bearing kinds — and this
  ## change deliberately does not make that call.
  ##
  ## THIS IS NOT A WIDENING RELATIVE TO WHAT SHIPS. `monitorHosting` defaults to
  ## `mhmNever`, so every action ships through the wrapped path — and the
  ## wrapped path has been running at full interest all along, precisely because
  ## the request the engine wrote never arrived. What changes is the HOSTED
  ## path, which stops losing the three record kinds above.
  ##
  ## `DependencyGatheringPolicy.captureNonDeterminism` / `captureIpc` are
  ## therefore SUBSUMED: an edge that sets either still gets what it asked for,
  ## and an edge that sets neither now gets it too. They are left in place
  ## rather than deleted because they are declared DSL surface with recipes and
  ## tests behind them, and retiring a public field is its own change with its
  ## own blast radius.
  FullInterest

proc monitorEvidenceScope(config: BuildEngineConfig): EvidenceScope =
  ## The evidence scope `config` asks io-mon for — ONE definition, read by BOTH
  ## hosting forms, for exactly the reason `monitorInterest` above is one proc:
  ## the two paths carrying different answers for the same action was a live
  ## defect on the interest axis, and this axis has the identical two-channel
  ## shape (an argv flag on the wrapped path, a request field on the hosted
  ## one).
  ##
  ## Straight through from the operator, with no policy of its own. There is no
  ## per-action narrowing and there must not be one invented here: DA-1i's
  ## hazard is something the OPERATOR accepts for a whole build after reading
  ## what it costs, not something an engine heuristic may decide on their
  ## behalf for the edges it guesses are cheap.
  config.evidenceScope

proc monitorEvidenceFlag(scope: EvidenceScope): seq[string] =
  ## The wrapped path's argv spelling of `scope`.
  ##
  ## `evidenceScopeToken` is io-mon's codec and the ONLY speller of these
  ## tokens. THERE IS NO EMPTY-TOKEN CASE LEFT TO HANDLE, on either of the two
  ## grounds the deleted guard rested on:
  ##
  ## * "a future `EvidenceScope` member added without a wire token" is now a
  ##   COMPILE ERROR in io-mon rather than a possibility here.
  ##   `evidenceScopeToken` is an exhaustive `case`, and a `static:` block
  ##   beside it asserts over the whole enum that `esUnrecognized` is the only
  ##   member whose token is empty (and that every other member's token
  ##   survives the wire and decodes back to itself). Graded by io-mon's
  ##   `tests/portable/test_io_mon_evidence_scope.nim`, which mutates a copy of
  ##   `types.nim` and reads the real compiler's exit code.
  ## * `esUnrecognized` itself cannot reach this proc: `parseEvidenceScope`
  ##   refuses it, `monitorEvidenceScope` passes `config.evidenceScope` straight
  ##   through with no policy of its own, and that field's zero value is
  ##   `esFull`.
  ##
  ## The guard that stood here returned `@[]` on an empty token. Its own
  ## docstring already conceded it was unreachable, and deleting it was MEASURED
  ## to redden nothing. A branch no test can redden is one the next reader takes
  ## for load-bearing again — the precedent set for the `run`-verb skip.
  ##
  ## And if a library caller outside the CLI ever did hand this an unspellable
  ## scope, omitting the flag is the WEAKER answer, not the safer one: io-mon
  ## would then capture full evidence silently. Passing the empty value instead
  ## makes io-mon refuse it in the scope vocabulary and exit non-zero — measured
  ## at the real binary. Loud beats silent here too.
  @["--evidence", evidenceScopeToken(scope)]

proc monitorEvidenceRequirement(action: BuildAction;
                                config: ptr BuildEngineConfig):
                                MonitorEvidenceRequirement =
  ## The narrowest capture this build will TRUST for `action` — the consumer
  ## side of the same two axes `monitorInterest` / `monitorEvidenceScope`
  ## request, which is why it is spelled here and not at the fold sites.
  ##
  ## The two sides are deliberately the SAME VALUE and not merely compatible
  ## ones. A build that asks io-mon for reads-only evidence and then demands
  ## full evidence of what comes back would refuse its own captures; a build
  ## that asks for full and accepts reads-only would silently consume a
  ## teammate's narrowed record. Deriving both from one place makes the pair
  ## consistent by construction.
  ##
  ## `config == nil` is every caller that does not have one (the direct-engine
  ## API, most of the suite) and it requires FULL evidence. Fail-closed: the
  ## cost of being wrong that way is a re-capture, and the cost of the other
  ## way is publishing a narrowed capture as complete.
  MonitorEvidenceRequirement(
    interest: monitorInterest(action),
    evidenceScope:
      if config != nil: monitorEvidenceScope(config[]) else: esFull)

proc monitoredAction(action: BuildAction; config: BuildEngineConfig;
                     cacheRoot: string;
                     hostInProcess: bool): tuple[action: BuildAction;
                                                 diagnostic: string;
                                                 capturePath: string;
                                                 hostInProcess: bool] =
  ## SEAM 1 of two (the other is ``preparedRunQuotaCommand``): everything that
  ## decides whether an action is monitored, and how, happens here.
  ##
  ## In-Process-Monitor-Hosting HM-4 — ``hostInProcess`` says the launch site
  ## about to run this action is one the ENGINE spawns, so the engine can be
  ## io-mon's host itself. When it is true the argv is left ALONE and only the
  ## evidence path is selected; when it is false the historical
  ## ``<repro> internal io monitor --depfile <f> -- <argv>`` wrapper is
  ## prepended and a second ``repro`` process does the hosting.
  ##
  ## The caller decides, not this proc, because "which launch path" is not
  ## knowable from an action: see the launch decision in ``runBuild``, which
  ## is now taken BEFORE the monitor plan for exactly this reason.
  ##
  ## Both forms select the SAME depfile path and both produce the SAME
  ## evidence — ``finishMonitor`` writes the canonical iomon that
  ## ``foldMonitorDepFileEvidence`` reads, byte for byte what the CLI wrote
  ## (IoMon-Decomposed-Host-API DH-4), so nothing downstream of
  ## ``action.monitorDepfile`` can tell the two apart.
  result.action = action
  if action.dependencyPolicy.kind notin MonitorPolicyKinds:
    return
  # Built-in actions (``kind != bakProcess`` — copy-file, write-text, stamp,
  # workspace-vcs, preserve-tree, binary-cache-substitute) run entirely
  # in-process via ``executeBuiltinAction``: there is no child process to
  # interpose on, so there is nothing for the io-monitor to monitor and
  # nothing to gain from wrapping ``argv``. Their dependency evidence is the
  # statically declared inputs/outputs (and, for recognized/converter
  # policies, the post-build reports) — ``monitorEvidenceRequired`` already
  # returns false for them because no iomon is ever wired. ``builtinAction``
  # tags every such action with the default ``automaticMonitorGatheringPolicy``
  # (a ``MonitorPolicyKinds`` member), so without this guard a built-in would
  # incorrectly fall into the monitor wiring below and fail with a spurious
  # "requires an io-monitor driver" diagnostic on any host without the monitor
  # wired (e.g. the hermetic workspace/VCS integration tests). Only
  # ``bakProcess`` actions spawn a monitorable subprocess.
  if action.kind != bakProcess:
    return
  # Direct engine callers may provide a monitor depfile path for actions that
  # produce iomon evidence themselves. Preserve that prewired evidence path
  # instead of wrapping the command and overwriting it with monitor output.
  if action.monitorDepfile.len > 0:
    return
  # Windows: automatic monitor dependency gathering now works on Windows via
  # the IAT-patching shim + CreateRemoteThread injection (see the shared
  # io-mon sibling: io_mon/shim/windows_interpose.nim and
  # io_mon/windows_injector.nim — Incremental-Test-Runner M7 relocated these
  # from reprobuild's former repro_monitor_shim / repro_monitor_depfile libs).
  # The same io-monitor driver is used as on macOS — only the underlying
  # injection mechanism differs.
  # Monitor-Hook-Shim.md:501 — when monitoring cannot be performed, the
  # failure semantics are "fail the monitored action OR make it non-cacheable,
  # depending on policy". A non-cacheable action may run without monitor
  # evidence only when the monitor is unavailable; when a monitor driver is
  # configured, still gather evidence so integration tests and build reports
  # can inspect the real runtime reads/writes.
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
        "automatic monitor dependency gathering requires an io-monitor driver"
      return
    let depfile = cacheRoot / "monitor-depfiles" /
      (sanitizeActionId(action.id) & ".iomon")
    result.action.monitorDepfile = depfile
    if hostInProcess:
      # HM-4 — the ENGINE is the host. The argv stays exactly what the recipe
      # wrote, because io-mon spawns it directly; the wrapper below exists
      # only to put a hosting process in between, and there no longer is one.
      # ``monitorCliPath`` is still what gates monitoring on/off (an
      # unconfigured driver still means "no monitor is wired"), so this branch
      # changes WHO hosts and nothing about WHETHER an action is monitored —
      # PROVIDED the launch site the caller had in mind actually hosts.
      # Stripping the wrapper is half of a two-part handshake and this proc
      # cannot check the other half, so the OTHER half is enforced at the
      # launch site instead of being documented here: ``runBuild`` refuses a
      # hosted plan that arrives at a launch path
      # ``launchPathHostsMonitorInProcess`` does not cover, with
      # ``monitorHostingRefusal``'s diagnostic. There is therefore no
      # configuration in which this branch's unwrapped argv reaches a site
      # that starts no host — it fails the action instead of running it.
      result.hostInProcess = true
    else:
      # The diagnostic path is shared by action ID, even across builds. Never
      # consume it as this execution's evidence: another monitor can truncate
      # or replace it after our child exits. Capture privately on the same
      # filesystem, then fold before atomically publishing the diagnostic.
      try:
        createDir(depfile.parentDir)
        let capture = createTempFile("." & depfile.extractFilename & ".capture-",
          ".tmp", depfile.parentDir)
        capture.cfile.close()
        result.capturePath = capture.path
      except CatchableError as err:
        result.diagnostic = "cannot create monitor capture: " & err.msg
        return
      # ``--interest`` is how the engine's event-interest REQUEST survives the
      # hop into a second process. It travels on the ARGV and not through the
      # environment because `REPRO_MONITOR_INTEREST` is io-mon's own channel to
      # the shim: `childEnv` writes it last, after the caller's `request.env`
      # and after the injected pairs, so that a caller cannot redirect or
      # disarm monitoring. An engine seeding it into the action's environment
      # was therefore writing into a variable io-mon overwrites, which is what
      # made this path's request silently different from the hosted path's —
      # see ``monitorInterest``.
      # DA-1i — `--evidence` travels on the ARGV for the same reason
      # `--interest` does: `REPRO_MONITOR_EVIDENCE` is io-mon's OWN channel to
      # the shim, written last by `childEnv`, so an engine that seeded it into
      # the action's environment would be writing into a variable io-mon
      # overwrites before any shim could read it. The flag is a channel io-mon
      # does not own and therefore cannot overwrite.
      result.action.argv = @[monitorCli] & config.monitorCliArgs &
        @["--depfile", result.capturePath,
          "--interest", interestToTokens(monitorInterest(action))] &
        monitorEvidenceFlag(monitorEvidenceScope(config)) &
        @["--"] & action.argv
    # M9.R.13c.2: shim-library env seed is layered at LAUNCH time via
    # ``launchChildEnv`` (NOT here on ``result.action.env``). The seed
    # MUST NOT enter the action's fingerprint — the absolute path of
    # ``librepro_monitor_shim.{dll,so,dylib}`` is machine-specific
    # (varies by repro install location) so including it in ``env``
    # would make the action ID non-reproducible across machines and
    # invalidate the binary-cache lookup. See ``launchChildEnv`` for
    # the launch-time injection.

when defined(posix):
  proc assignProcessGroup(process: Process): int =
    ## Best-effort process-group isolation for externally launched actions.
    ## It lets cancellation tear down shell wrappers together with their
    ## children instead of only signalling the top-level monitor/helper.
    let pid = processID(process)
    if pid <= 0:
      return 0
    if setpgid(Pid(pid), Pid(pid)) == 0:
      pid
    else:
      0

  when defined(linux):
    proc childPids(pid: int): seq[int] =
      let path = "/proc" / $pid / "task" / $pid / "children"
      if not fileExists(path):
        return @[]
      for token in readFile(path).splitWhitespace:
        try:
          result.add(parseInt(token))
        except ValueError:
          discard

    proc collectDescendants(pid: int; seen: var HashSet[int];
                            descendants: var seq[int]) =
      for child in childPids(pid):
        if seen.contains(child):
          continue
        seen.incl(child)
        collectDescendants(child, seen, descendants)
        descendants.add(child)

    proc signalDescendants(pid: int; sig: cint) =
      var seen = initHashSet[int]()
      var descendants: seq[int] = @[]
      collectDescendants(pid, seen, descendants)
      for child in descendants:
        discard kill(Pid(child), sig)

  proc signalRunningAction(item: RunningAction; sig: cint) =
    let pid = processID(item.process)
    if pid <= 0:
      return
    when defined(linux):
      signalDescendants(pid, sig)
    if item.processGroupPid > 0:
      discard kill(Pid(-item.processGroupPid), sig)
    else:
      discard kill(Pid(pid), sig)

  proc terminateRunningAction(item: var RunningAction) =
    if item.process.running():
      item.signalRunningAction(SIGTERM)
      for _ in 0 ..< 20:
        if not item.process.running():
          break
        sleep(10)
    item.signalRunningAction(SIGKILL)

else:
  proc terminateRunningAction(item: var RunningAction) =
    if item.process.running():
      item.process.terminate()

when defined(windows):
  proc ensureRunningProcessHandle(item: var RunningAction): Handle =
    ## Lazily open a SYNCHRONIZE-only HANDLE for the running child process,
    ## suitable for WaitForMultipleObjects. Cached on the RunningAction so
    ## each process is opened once and reused across wait iterations.
    if item.processWaitHandle != 0:
      return item.processWaitHandle
    let pid =
      case item.processKind
      of rpkHelperProcess:
        processID(item.process)
      of rpkBypassProcess:
        item.directProcess.processId()
      else:
        0
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
      sleep(timeoutMs)
      return -1
    let ret = waitForMultipleObjects(DWORD(count), addr handles,
                                     WINBOOL(0), DWORD(timeoutMs))
    const WAIT_OBJECT_0_DWORD = DWORD(0)
    const WAIT_TIMEOUT_DWORD = DWORD(0x102)
    const WAIT_FAILED_DWORD = cast[DWORD](0xFFFFFFFF'u32)
    if ret == WAIT_TIMEOUT_DWORD:
      return -1
    if ret == WAIT_FAILED_DWORD:
      sleep(timeoutMs)
      return -1
    let signaled = int(ret - WAIT_OBJECT_0_DWORD)
    if signaled < 0 or signaled >= count:
      return -1
    indices[signaled]

type
  ActionPathDeclaration* = enum
    ## How one lowered action declared its ``PATH``, read back off the
    ## ``BuildAction`` rather than off the lowering that produced it.
    ##
    ## Reading it back is the point. The lowering's own opinion is not
    ## evidence — three sites held the opinion "an empty prefix falls
    ## through to inheritance" while emitting an entry that did the
    ## opposite. This classifies the ARTIFACT, so a census over it says
    ## what the actions carry.
    apdAbsent
      ## No ``PATH`` entry and no ``PATH`` passthrough name. The launcher
      ## falls back to ``getEnv("PATH")`` (see ``prependPathDirsToArgvEnv``
      ## below), so the action inherits — silently, with nothing in the
      ## key recording that it did.
    apdInherited
      ## ``PATH`` is named in ``envPassthrough``: the value is the
      ## caller's, the name is keyed, the value is not.
    apdHermetic
      ## A non-empty ``PATH`` value that is NOT passthrough — composed
      ## from solved-graph tool directories and keyed by value.
    apdEmpty
      ## ``PATH=`` with an empty value. The action runs with no ``PATH``.
      ## Must never occur; see ``EnvironmentInheritanceCensus.emptyPathActions``.

proc classifyActionPath*(action: BuildAction): ActionPathDeclaration =
  ## Classify ``action``'s ``PATH`` declaration. Shared by the engine's
  ## own census and by ``repro graph --view=env`` so the build header and
  ## the graph instrument can never disagree about the same graph.
  var pathValue = ""
  var pathSeen = false
  for entry in action.env:
    let eq = entry.find('=')
    if eq <= 0:
      continue
    if cmpIgnoreCase(entry[0 ..< eq], "PATH") == 0:
      # Last-write-wins, matching ``prependPathDirsToArgvEnv``.
      pathValue = entry[eq + 1 .. ^1]
      pathSeen = true
  var passthrough = false
  for name in action.envPassthrough:
    if cmpIgnoreCase(name, "PATH") == 0:
      passthrough = true
  if pathSeen and pathValue.len == 0:
    return apdEmpty
  if not pathSeen:
    return if passthrough: apdInherited else: apdAbsent
  if passthrough: apdInherited else: apdHermetic

proc prependPathDirsToArgvEnv(env: seq[string];
                              binDirs: openArray[string]): seq[string] =
  ## Walk an argv-style ``KEY=VALUE`` env list, collapse any
  ## case-variant ``PATH`` entries into one, and prepend ``binDirs``
  ## to the resulting ``PATH`` value. Used by the RunQuota helper-
  ## spawn path (which carries env as ``seq[string]`` rather than a
  ## ``StringTableRef``) so the same M9.N Batch B behaviour applies
  ## to the daemon-backed launch as well as the bypass launch.
  ##
  ## ## AN ``action.env`` ``PATH`` REPLACES; IT DOES NOT MERGE
  ##
  ## The tail this proc appends after ``binDirs`` is ``pathValue`` — the
  ## value the ACTION declared — whenever the action declared one, and
  ## ``getEnv("PATH")`` only when it did not (the ``if pathSeen`` at the
  ## bottom of the body). So:
  ##
  ##   * no ``PATH`` entry  -> the caller's ``$PATH`` is the tail;
  ##   * ``PATH=<dirs>``    -> ``<dirs>`` is the tail, the caller's is gone;
  ##   * ``PATH=``          -> the tail is EMPTY, and the child runs with
  ##                           ``PATH=`` (or just ``binDirs``) — it does
  ##                           NOT fall through to the caller's.
  ##
  ## The third row is worth stating because a lowering comment once
  ## asserted the opposite ("the launcher layers ``action.env`` OVER the
  ## inherited environment rather than replacing it") and emitted an
  ## empty ``PATH`` on 1372 of this repository's 2753 process edges on
  ## the strength of it. ``repro_cli_support.actionPathDecision`` is the
  ## single place that can no longer produce that value.
  ##
  ## ## THE FIRST ROW IS NOW MOSTLY UNREACHABLE FROM THE LOWERING SITES
  ##
  ## The ``else: getEnv("PATH")`` fallback below is still correct and
  ## still exercised — by any action that neither declares ``PATH`` nor
  ## names it passthrough — but it is NOT how a lowered non-declaring
  ## edge gets its ``PATH`` any more. ``actionPathDecision``'s inherited
  ## branch names ``PATH`` in ``envPassthrough``, and ``launchChildEnv``
  ## resolves value-less passthrough names out of the host BEFORE this
  ## proc sees the list (the ``if action.envPassthrough.len > 0`` block
  ## near the end of ``launchChildEnv``). By the time an inherited edge
  ## reaches here the list already carries ``PATH=<host value>``, so
  ## ``pathSeen`` is true and row two is what runs. Same bytes, same
  ## launch-time read; different proc. Recorded because a comment in
  ## this file citing a mechanism that no longer fires is exactly how
  ## the empty-``PATH`` defect above shipped.
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
  # RunQuota action children inherit from runquotad, not from the invoking
  # `repro build`; when action env overrides are present, materialise PATH
  # even when there is nothing to prepend.
  if binDirs.len == 0 and env.len == 0:
    return env
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
  ## Each declared ref's resolved executable directory is promoted before
  ## any transitive bin directories. A later explicit tool can therefore
  ## override an earlier ref's transitive dependency without changing the
  ## direct tools' declaration order.
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
  var resolvedIdentities: seq[ResolvedToolIdentity] = @[]
  for i, refName in action.toolIdentityRefs:
    let kind = kindForRef(action, i)
    let resolved = resolver(refName, kind)
    if resolved.isNone:
      continue
    resolvedIdentities.add(resolved.get())
  var promotedDirs = initHashSet[string]()
  for resolved in resolvedIdentities:
    if resolved.resolvedExecutablePath.len == 0:
      continue
    let directDir = parentDir(resolved.resolvedExecutablePath)
    if directDir.len > 0 and directDir notin promotedDirs:
      promotedDirs.incl(directDir)
      result.add(directDir)
  for resolved in resolvedIdentities:
    for binDir in resolved.binDirs:
      if binDir.len > 0 and binDir notin promotedDirs:
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
    nimPathDirs*: seq[string]
      ## Cross-Repo-Source-Consumption SC-11 (§4.2a.3) — the accumulated Nim
      ## library source roots. Unlike the four C/C++ lists above (each threaded
      ## onto a dedicated env var), these are projected onto the action's
      ## ``nim c`` argv as ``--path:<dir>`` compiler flags via
      ## ``applyNimPathArgs`` at launch, through the SAME aux-projection seam.

proc collectResolvedAuxPaths*(action: BuildAction;
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
  var seenNimPath: HashSet[string] = initHashSet[string]()
  # Target libraries and headers must precede the native toolchain's
  # transitive sysroot. Otherwise a compiler profile can expose a kernel
  # UAPI header before the matching userspace library header (for example
  # linux/drm.h before libdrm's drm.h). Keep each dependency class stable,
  # but collect host-side channels before build-machine tools.
  for priorityKind in [dkBuild, dkRuntime, dkNative]:
    for i, refName in action.toolIdentityRefs:
      let kind = kindForRef(action, i)
      if kind != priorityKind:
        continue
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
      # SC-11 (§4.2a.3): accumulate the Nim library source roots in-order,
      # deduped, exactly as the four C/C++ lists above.
      for d in r.nimPathDirs:
        if d.len > 0 and d notin seenNimPath:
          seenNimPath.incl(d)
          result.nimPathDirs.add(d)

proc isUnsafeRuntimeLibDir(path: string): bool =
  ## Dependency profiles may propagate libc or language-runtime libraries
  ## alongside ordinary libraries. Globally interposing one of those runtimes
  ## can replace the runtime selected by an executable's own RPATH. Keep the
  ## directories available to the linker, but never inject them into a process
  ## runtime search path.
  # Compiler bootstrap prefixes can carry libc startup files even when the
  # owning package is GCC rather than glibc. Detect the runtime by content so
  # federated catalogs and staged compiler package names remain safe.
  if fileExists(path / "libc.so.6"):
    return true
  let normalized = path.replace('\\', '/')
  const sourceMarker = "/packages/source/"
  let sourceIndex = normalized.find(sourceMarker)
  if sourceIndex >= 0:
    let packageStart = sourceIndex + sourceMarker.len
    let packageEnd = normalized.find('/', packageStart)
    let packageName =
      if packageEnd < 0: normalized[packageStart .. ^1]
      else: normalized[packageStart ..< packageEnd]
    if packageName == "glibc" or packageName == "readline" or
        packageName == "perl" or packageName == "python3" or
        packageName.startsWith("python3-"):
      return true
  const storePrefix = "/nix/store/"
  if not normalized.startsWith(storePrefix):
    return false
  let relative = normalized[storePrefix.len .. ^1]
  let slash = relative.find('/')
  if slash <= 0:
    return false
  let storeEntry = relative[0 ..< slash]
  let hashSeparator = storeEntry.find('-')
  if hashSeparator < 0 or hashSeparator + 1 >= storeEntry.len:
    return false
  let packageName = storeEntry[hashSeparator + 1 .. ^1]
  packageName == "glibc" or packageName.startsWith("glibc-") or
    packageName == "readline" or packageName.startsWith("readline-") or
    packageName == "perl" or packageName.startsWith("perl-") or
    packageName == "python3" or packageName.startsWith("python3-")

proc runtimeSafeLibDirs(paths: ResolvedAuxPaths): seq[string] =
  for path in paths.libDirs:
    if not isUnsafeRuntimeLibDir(path):
      result.add(path)

type
  CompilerIncludePaths = object
    regularDirs: seq[string]
    systemDirs: seq[string]

proc partitionCompilerIncludePaths(paths: ResolvedAuxPaths):
    CompilerIncludePaths =
  ## GCC's C++ forwarding headers use ``#include_next`` to reach libc.
  ## Putting a source libc in CPATH makes it appear before GCC's intrinsic
  ## C++ headers, so include_next cannot find it. Keep package headers in
  ## CPATH, but place source libc and kernel UAPI roots after GCC's intrinsic
  ## headers with ``-idirafter``. GCC's own propagated include tree is omitted
  ## because the selected compiler already contributes it intrinsically.
  const sourceMarker = "/packages/source/"
  var glibcRoots: seq[string] = @[]
  var linuxRoots: seq[string] = @[]
  for path in paths.includeDirs:
    var normalized = path.replace('\\', '/')
    while normalized.len > 1 and normalized.endsWith("/"):
      normalized.setLen(normalized.len - 1)
    let marker = normalized.find(sourceMarker)
    if marker < 0:
      result.regularDirs.add(path)
      continue
    let packageStart = marker + sourceMarker.len
    let packageEnd = normalized.find('/', packageStart)
    let packageName =
      if packageEnd < 0: normalized[packageStart .. ^1]
      else: normalized[packageStart ..< packageEnd]
    case packageName
    of "gcc":
      discard
    of "glibc":
      if normalized.endsWith("/usr/include") and
          normalized notin glibcRoots:
        glibcRoots.add(normalized)
    of "linux-headers":
      if normalized.endsWith("/usr/include") and
          normalized notin linuxRoots:
        linuxRoots.add(normalized)
    else:
      result.regularDirs.add(path)
  result.systemDirs = glibcRoots
  result.systemDirs.add(linuxRoots)

proc compilerSystemIncludeFlags(systemDirs: openArray[string]): seq[string] =
  for path in systemDirs:
    if path.len > 0:
      result.add("-idirafter")
      result.add(path)

proc prependEnvFlags(table: StringTableRef; varName: string;
                     flags: openArray[string]) =
  if table == nil or flags.len == 0:
    return
  let prefix = @flags.join(" ")
  let inherited =
    if table.hasKey(varName): table[varName]
    else: getEnv(varName)
  table[varName] =
    if inherited.len > 0: prefix & " " & inherited
    else: prefix

proc prependEnvFlagsToArgvEnv(env: seq[string]; varName: string;
                              flags: openArray[string]): seq[string] =
  if flags.len == 0:
    return env
  var inherited = getEnv(varName)
  result = newSeqOfCap[string](env.len + 1)
  for entry in env:
    let equals = entry.find('=')
    if equals > 0 and entry[0 ..< equals] == varName:
      inherited = entry[equals + 1 .. ^1]
    else:
      result.add(entry)
  let prefix = @flags.join(" ")
  result.add(varName & "=" &
    (if inherited.len > 0: prefix & " " & inherited else: prefix))

proc compilerStemWithoutVersion(stem: string): string =
  result = stem.toLowerAscii
  let separator = result.rfind('-')
  if separator < 0 or separator + 1 >= result.len:
    return
  var isVersion = true
  for ch in result[separator + 1 .. ^1]:
    if ch notin {'0'..'9', '.'}:
      isVersion = false
      break
  if isVersion:
    result.setLen(separator)

proc isGccFamilyCompiler(stem: string): bool =
  let candidate = compilerStemWithoutVersion(stem)
  for compiler in ["gcc", "g++", "cc", "c++", "cpp"]:
    if candidate == compiler or candidate.endsWith("-" & compiler):
      return true

proc applyCompilerSystemIncludeArgs*(argv: openArray[string];
                                     systemDirs: openArray[string]):
    seq[string] =
  ## Environment flags cover build-system compiler launches. Mirror them onto
  ## direct GCC-family actions, including io-monitor-wrapped commands.
  result = @argv
  if systemDirs.len == 0 or argv.len == 0:
    return
  var base = 0
  for i in countdown(argv.len - 1, 0):
    if argv[i] == "--":
      base = i + 1
      break
  if base >= argv.len or not isGccFamilyCompiler(extractFilename(argv[base])):
    return
  let flags = compilerSystemIncludeFlags(systemDirs)
  if flags.len == 0:
    return
  result = @[]
  for i in 0 .. base:
    result.add(argv[i])
  result.add(flags)
  for i in base + 1 ..< argv.len:
    result.add(argv[i])

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
  var pkgConfigCompatDirs = paths.pkgConfigDirs
  let pathSep =
    when defined(windows): ';'
    else: ':'
  for varName in ["PKG_CONFIG_PATH_FOR_TARGET", "PKG_CONFIG_PATH_FOR_BUILD"]:
    let inherited =
      if env.hasKey(varName): env[varName]
      else: getEnv(varName)
    for entry in inherited.split(pathSep):
      if entry.len > 0:
        pkgConfigCompatDirs.add(entry)
  prependEnvDirs(env, "PKG_CONFIG_PATH", pkgConfigCompatDirs)
  prependEnvDirs(env, "PKG_CONFIG_PATH_FOR_TARGET", paths.pkgConfigDirs)
  prependEnvDirs(env, "PKG_CONFIG_PATH_FOR_BUILD", paths.pkgConfigDirs)
  prependEnvDirs(env, "CMAKE_PREFIX_PATH", paths.cmakePrefixDirs)
  # Qt deliberately ignores CMAKE_PREFIX_PATH while resolving separately
  # installed modules. Mirror the same declared package roots onto its
  # companion channel so split Qt package profiles remain composable.
  prependEnvDirs(env, "QT_ADDITIONAL_PACKAGES_PREFIX_PATH",
    paths.cmakePrefixDirs)
  let includePaths = partitionCompilerIncludePaths(paths)
  prependEnvDirs(env, "CPATH", includePaths.regularDirs)
  let systemFlags = compilerSystemIncludeFlags(includePaths.systemDirs)
  # Build-machine helper programs need the same source sysroot as target
  # objects. Several Autotools projects compile those helpers through the
  # *_FOR_BUILD variables during a later make action.
  for varName in ["CPPFLAGS", "CFLAGS", "CXXFLAGS",
                  "HOSTCFLAGS", "HOSTCXXFLAGS",
                  "CPPFLAGS_FOR_BUILD", "CFLAGS_FOR_BUILD",
                  "CXXFLAGS_FOR_BUILD"]:
    prependEnvFlags(env, varName, systemFlags)
  prependEnvDirs(env, "LIBRARY_PATH", paths.libDirs)
  # LD_LIBRARY_PATH covers run-time test execution; LIBRARY_PATH covers
  # link-time. Glibc outputs are link-only: loading an arbitrary dependency's
  # libc into the action process can cross GLIBC_PRIVATE ABIs.
  let runtimeLibDirs = runtimeSafeLibDirs(paths)
  prependEnvDirs(env, "LD_LIBRARY_PATH", runtimeLibDirs)
  prependEnvDirs(env, "REPRO_NIM_PATH_DIRS", paths.nimPathDirs)
  when defined(macosx):
    # macOS' dynamic loader ignores LD_LIBRARY_PATH; DYLD_LIBRARY_PATH is the
    # run-time counterpart needed by tools that dlopen libraries by leaf name.
    prependEnvDirs(env, "DYLD_LIBRARY_PATH", runtimeLibDirs)

proc applyResolvedAuxPathsArgv*(env: seq[string];
                                paths: ResolvedAuxPaths): seq[string] =
  ## Argv-style env mutator. Used by the RunQuota-helper-spawn +
  ## inline-runquota paths. See ``applyResolvedAuxPathsTable`` for
  ## the rationale on ``PKG_CONFIG_PATH_FOR_{TARGET,BUILD}``.
  result = env
  var pkgConfigCompatDirs = paths.pkgConfigDirs
  let pathSep =
    when defined(windows): ';'
    else: ':'
  for varName in ["PKG_CONFIG_PATH_FOR_TARGET", "PKG_CONFIG_PATH_FOR_BUILD"]:
    var inherited = getEnv(varName)
    for item in env:
      let equals = item.find('=')
      if equals > 0 and item[0 ..< equals] == varName:
        inherited = item[equals + 1 .. ^1]
    for entry in inherited.split(pathSep):
      if entry.len > 0:
        pkgConfigCompatDirs.add(entry)
  result = prependEnvDirsToArgvEnv(result, "PKG_CONFIG_PATH",
    pkgConfigCompatDirs)
  result = prependEnvDirsToArgvEnv(result, "PKG_CONFIG_PATH_FOR_TARGET",
    paths.pkgConfigDirs)
  result = prependEnvDirsToArgvEnv(result, "PKG_CONFIG_PATH_FOR_BUILD",
    paths.pkgConfigDirs)
  result = prependEnvDirsToArgvEnv(result, "CMAKE_PREFIX_PATH", paths.cmakePrefixDirs)
  result = prependEnvDirsToArgvEnv(result,
    "QT_ADDITIONAL_PACKAGES_PREFIX_PATH", paths.cmakePrefixDirs)
  let includePaths = partitionCompilerIncludePaths(paths)
  result = prependEnvDirsToArgvEnv(result, "CPATH",
    includePaths.regularDirs)
  let systemFlags = compilerSystemIncludeFlags(includePaths.systemDirs)
  for varName in ["CPPFLAGS", "CFLAGS", "CXXFLAGS",
                  "HOSTCFLAGS", "HOSTCXXFLAGS",
                  "CPPFLAGS_FOR_BUILD", "CFLAGS_FOR_BUILD",
                  "CXXFLAGS_FOR_BUILD"]:
    result = prependEnvFlagsToArgvEnv(result, varName, systemFlags)
  result = prependEnvDirsToArgvEnv(result, "LIBRARY_PATH", paths.libDirs)
  let runtimeLibDirs = runtimeSafeLibDirs(paths)
  result = prependEnvDirsToArgvEnv(result, "LD_LIBRARY_PATH", runtimeLibDirs)
  result = prependEnvDirsToArgvEnv(result, "REPRO_NIM_PATH_DIRS", paths.nimPathDirs)
  when defined(macosx):
    result = prependEnvDirsToArgvEnv(result, "DYLD_LIBRARY_PATH", runtimeLibDirs)

proc shellScriptArgIndex(argv: openArray[string]): int =
  ## Return the script argument consumed by a POSIX shell's ``-c`` option.
  ## Monitored actions carry ``repro internal io monitor ... --`` before the
  ## real command, so use the same last-separator rule as ``applyNimPathArgs``.
  if argv.len < 3:
    return -1
  var base = 0
  for i in countdown(argv.len - 1, 0):
    if argv[i] == "--":
      base = i + 1
      break
  if base >= argv.len - 1:
    return -1
  var stem = extractFilename(argv[base]).toLowerAscii
  when defined(windows):
    if stem.endsWith(".exe"):
      stem.setLen(stem.len - 4)
  const shells = ["sh", "bash", "dash", "ash", "ksh", "mksh", "zsh"]
  if stem notin shells:
    return -1
  for i in base + 1 ..< argv.len - 1:
    let option = argv[i]
    if option == "-c" or
        (option.len > 2 and option[0] == '-' and option[1] != '-' and
         'c' in option[1 .. ^1]):
      return i + 1
  -1

proc isRuntimeLibraryEnv(name: string): bool {.inline.} =
  name == "LD_LIBRARY_PATH" or name == "DYLD_LIBRARY_PATH"

proc applyExplicitRuntimeLibraryEnvOverrides*(env: seq[string];
    actionEnv: openArray[string]): seq[string] =
  ## Runtime search paths assembled from dependency profiles are useful for
  ## most actions, but they can also make a provisioned tool load a different
  ## ABI-compatible-by-name library than the one it was built against. Allow a
  ## recipe to take ownership of the loader environment explicitly. Reapply
  ## only runtime-library variables here; the other auxiliary channels remain
  ## dependency-first by design.
  result = @[]
  for entry in env:
    result.add(entry)
  for entry in actionEnv:
    let eq = entry.find('=')
    if eq <= 0 or not isRuntimeLibraryEnv(entry[0 ..< eq]):
      continue
    let name = entry[0 ..< eq]
    var retained = newSeqOfCap[string](result.len)
    for existing in result:
      let itemEq = existing.find('=')
      if itemEq <= 0 or existing[0 ..< itemEq] != name:
        retained.add(existing)
    result = retained
    result.add(entry)

proc applyExplicitRuntimeLibraryEnvOverrides*(env: StringTableRef;
    actionEnv: openArray[string]) =
  ## StringTable counterpart for the direct RunQuota-bypass launcher.
  if env == nil:
    return
  for entry in actionEnv:
    let eq = entry.find('=')
    if eq > 0 and isRuntimeLibraryEnv(entry[0 ..< eq]):
      env[entry[0 ..< eq]] = entry[eq + 1 .. ^1]

proc monitorPayloadArgIndex(argv: openArray[string]): int =
  ## Return the first argument of an io-monitor payload, or -1 when argv is
  ## not the canonical ``repro internal io monitor ... -- <command>`` shape.
  ##
  ## THE SCAN IS BOUNDED TO THE WRAPPER'S OWN ARGUMENTS, and it has to be.
  ## It used to scan the WHOLE argv backwards for the LAST ``--``, which is
  ## the wrapper's separator only when the payload contains no ``--`` of its
  ## own. ``cargo test -- <args>``, ``sh -c <script> -- <arg>`` and
  ## ``git … -- <path>`` all do, and MEASURED (2026-09-09) on the production
  ## key builder a payload of
  ## ``/usr/bin/env runner -- /nix/store/…-data-1.0/input.txt`` answered index
  ## 12 — the store path after the ACTION's ``--`` — where the unwrapped argv
  ## answers index 0. ``toolInputRoots`` then elided everything under a root
  ## the weak fingerprint carries nothing about, because the wrapper argv is
  ## composed long after that fingerprint was computed
  ## (Dependency-Observation-Attribution.md rule 9, in a new shape).
  ##
  ## Scanning FORWARD from the first wrapper argument and stopping at the
  ## FIRST ``--`` is not merely the opposite convention: it is the grammar the
  ## RECEIVING parser applies. io-mon's ``parseRun``
  ## (io-mon/src/io_mon/fs_snoop.nim) walks its arguments in order and
  ## ``break``s on the first ``--``, taking everything after it as the
  ## command. So this now names the argument io-mon will actually execute,
  ## rather than a second answer free to disagree with it.
  ##
  ## THE OPTIONAL LEADING ``run`` VERB NEEDS NO SPECIAL CASE, and there used
  ## to be one here presented as required for agreement with
  ## ``parseFsSnoopCommand``. It was dead: the loop below steps over every
  ## token that is not ``--``, and ``run`` never is, so skipping it cannot
  ## change the answer. MEASURED (2026-09-09) — deleting the skip left both
  ## files that grade this function green, which is the definition of a branch
  ## nothing can observe. It is removed rather than kept with a corrected
  ## comment, because a branch no test can redden is one a later reader will
  ## take for a load-bearing one all over again.
  if argv.len < 8 or argv[1] != "internal" or argv[2] != "io" or
      argv[3] != "monitor":
    return -1
  var i = 4
  while i < argv.len:
    if argv[i] == "--":
      return (if i + 1 < argv.len: i + 1 else: -1)
    inc i
  -1

when defined(macosx):
  proc resolveNonSipShell*(): string

proc wrapMonitoredPayloadWithRuntimeEnv(argv: openArray[string];
                                        payloadIndex: int;
                                        exportPrefix: string): seq[string] =
  result = newSeqOfCap[string](argv.len + 4)
  for i in 0 ..< payloadIndex:
    result.add(argv[i])
  var shell = "/bin/sh"
  when defined(macosx):
    # The monitor itself has already started without the dependency-provided
    # loader paths. Keep that protection while avoiding a SIP boundary before
    # the real payload: macOS' /bin/sh strips the injected monitor shim, which
    # makes the whole child subtree unobservable and forces every otherwise
    # cacheable automatic-monitor action to skip publishing its record.
    let nonSipShell = resolveNonSipShell()
    if nonSipShell.len > 0:
      shell = nonSipShell
  result.add(shell)
  result.add("-c")
  result.add(exportPrefix & "exec \"$@\"")
  result.add("sh")
  for i in payloadIndex ..< argv.len:
    result.add(argv[i])

proc deferRuntimeLibraryEnvForShell*(argv, env: seq[string]):
    tuple[argv: seq[string], env: seq[string]] =
  ## A dependency's runtime library directory may contain a SONAME also used
  ## by the shell itself. Starting a Nix shell with a source-built readline
  ## directory in ``LD_LIBRARY_PATH``, for example, can make the dynamic
  ## loader pair Bash with an incompatible readline before ``-c`` runs.
  ##
  ## Shell actions do not need these variables until their program begins.
  ## Move explicit loader-path entries from the process environment into
  ## exports at the start of that program. The monitor and interpreter then
  ## start against their own libraries, while every command run by the action
  ## receives the same loader paths. A monitor-wrapped direct command is
  ## replaced by a tiny shell payload that exports the paths only after the
  ## monitor has started; an ordinary non-shell argv remains unchanged.
  result.argv = @[]
  for arg in argv:
    result.argv.add(arg)
  result.env = @[]
  for entry in env:
    result.env.add(entry)
  when defined(posix):
    let scriptIndex = shellScriptArgIndex(argv)
    let payloadIndex = monitorPayloadArgIndex(argv)
    if scriptIndex < 0 and payloadIndex < 0:
      return
    var values: array[2, string]
    var found: array[2, bool]
    const names = ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]
    for entry in env:
      let eq = entry.find('=')
      if eq <= 0:
        continue
      let name = entry[0 ..< eq]
      for i, candidate in names:
        if name == candidate:
          values[i] = entry[eq + 1 .. ^1]
          found[i] = true
    if not found[0] and not found[1]:
      return
    result.env.setLen(0)
    for entry in env:
      let eq = entry.find('=')
      if eq <= 0 or not isRuntimeLibraryEnv(entry[0 ..< eq]):
        result.env.add(entry)
    var prefix = ""
    for i, name in names:
      if found[i]:
        prefix.add("export " & name & "=" & quoteShell(values[i]) & "; ")
    if scriptIndex >= 0:
      result.argv[scriptIndex] = prefix & result.argv[scriptIndex]
    else:
      result.argv = wrapMonitoredPayloadWithRuntimeEnv(argv, payloadIndex,
        prefix)

proc deferRuntimeLibraryEnvForShell*(argv: seq[string];
                                     env: StringTableRef): seq[string] =
  ## StringTable counterpart for the direct RunQuota-bypass launcher.
  result = @[]
  for arg in argv:
    result.add(arg)
  when defined(posix):
    let scriptIndex = shellScriptArgIndex(argv)
    let payloadIndex = monitorPayloadArgIndex(argv)
    if (scriptIndex < 0 and payloadIndex < 0) or env == nil:
      return
    const names = ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]
    var prefix = ""
    for name in names:
      if env.hasKey(name):
        prefix.add("export " & name & "=" & quoteShell(env[name]) & "; ")
        env.del(name)
    if prefix.len > 0:
      if scriptIndex >= 0:
        result[scriptIndex] = prefix & result[scriptIndex]
      else:
        result = wrapMonitoredPayloadWithRuntimeEnv(argv, payloadIndex,
          prefix)

proc applyNimPathArgs*(argv: openArray[string];
                       nimPathDirs: openArray[string]): seq[string] =
  ## Cross-Repo-Source-Consumption SC-11 (§4.2a.3) — the Nim library-source
  ## channel's argv projection. Where the C/C++ channels prepend an ENV VAR,
  ## the Nim channel prepends a compiler FLAG: for each sibling Nim library
  ## source root in ``nimPathDirs`` it inserts a ``--path:<dir>`` argument onto
  ## the consumer's ``nim c`` invocation so ``import <sibmod>`` resolves
  ## through the threaded search path — the same aux-projection seam, driven
  ## off the same ``ProducerAuxPaths.nimPathDirs``.
  ##
  ## The insert is gated on the argv being a Nim compile: the command token
  ## (``argv[base]``) has basename ``nim`` (the standard ``nim c ...`` /
  ## ``buildNimUnittest`` shape) and a compile subcommand token (``c``/``cc``/
  ## ``compile``/``compileToC``/``c++``/``cpp``/``js``/``e``) appears at
  ## ``argv[base+1]``. The flags are inserted immediately AFTER that subcommand
  ## token (Nim accepts options anywhere after the command, so this is
  ## order-safe against the trailing ``--out:``/positional source). An empty
  ## ``nimPathDirs`` or a non-Nim argv is the identity transform, so every
  ## non-Nim-library-consumer action is byte-for-byte unchanged.
  ##
  ## The engine wraps a monitored action's argv in an io-monitor prefix
  ## (``<repro> internal io monitor --depfile <f> -- <real argv>``,
  ## ``maybeWrapWithMonitor``). ``base`` is the index just past that ``--``
  ## separator when present, so the Nim compile is recognised whether or not
  ## the action was monitor-wrapped; the ``--path:`` flags are always inserted
  ## into the REAL ``nim c`` argv, never into the monitor prefix.
  result = @[]
  for a in argv: result.add(a)
  if nimPathDirs.len == 0 or argv.len < 2:
    return
  # Locate the real command start, skipping a leading io-monitor wrapper by
  # finding the LAST ``--`` argument separator (the monitor CLI ends its own
  # options with ``--``; a plain ``nim c`` argv has none). ``base`` is the
  # first token after it, else 0.
  var base = 0
  for i in countdown(argv.len - 1, 0):
    if argv[i] == "--":
      base = i + 1
      break
  if base >= argv.len - 1:
    return
  let exeBase = extractFilename(argv[base])
  let stem =
    when defined(windows):
      (if exeBase.toLowerAscii.endsWith(".exe"):
        exeBase[0 ..< exeBase.len - 4] else: exeBase).toLowerAscii
    else:
      exeBase
  if stem != "nim":
    return
  const compileSubcommands = ["c", "cc", "compile", "compiletoc",
    "c++", "cpp", "js", "e"]
  if argv[base + 1].toLowerAscii notin compileSubcommands:
    return
  var flags: seq[string] = @[]
  for d in nimPathDirs:
    if d.len > 0:
      flags.add("--path:" & d)
  if flags.len == 0:
    return
  # Insert the ``--path:`` flags right after the subcommand token
  # (``base + 1``), preserving the monitor prefix (if any) and the trailing
  # ``--out:``/positional source.
  result = @[]
  for i in 0 .. base + 1:
    result.add(argv[i])
  for f in flags:
    result.add(f)
  for i in base + 2 ..< argv.len:
    result.add(argv[i])

const MonitorShimLibStem* = "librepro_monitor_shim"
  ## The shim's file stem, without the platform's dynamic-library
  ## extension. Named once so the engine's seed, ``repro_cli_support``'s
  ## develop-mode resolver and the packaging recipe that ships the file
  ## cannot drift apart.

const HostDynamicLibraryExt* =
  when defined(windows): "dll"
  elif defined(macosx):  "dylib"
  else:                  "so"
  ## The host's dynamic-library extension, without a leading dot.

proc monitorShimLibInLibraryPath*(runtimeLibraryPath, dllExt: string;
                                  probe: proc(path: string): bool): string =
  ## THE INSTALLED-PACKAGE ARM: probe each entry of a
  ## ``PathSep``-separated ``$REPROBUILD_RUNTIME_LIBRARY_PATH`` for
  ## ``librepro_monitor_shim.<ext>`` and return the first hit.
  ##
  ## The extension and the existence probe are both parameters, for the
  ## same reason ``runtime_contract.runtimeRpathCompilerFlags`` takes a
  ## target rather than reading ``defined(...)``: the situation this arm
  ## exists for is an INSTALLED PREFIX, which by construction is not the
  ## layout of the machine running the test, and a resolver that could
  ## only be exercised by installing a package would be verified by the
  ## packaging gate alone -- which is the state that let the gap ship.
  if runtimeLibraryPath.len == 0:
    return ""
  let leaf = MonitorShimLibStem & "." & dllExt
  for entry in runtimeLibraryPath.split(PathSep):
    let dir = entry.strip()
    if dir.len == 0:
      continue
    let candidate = dir / leaf
    if probe(candidate):
      return candidate
  ""

proc resolveMonitorShimLibForInstall*(): string =
  ## io-mon's four discovery arms, then the package's private libdir.
  ##
  ## THIS IS THE RESOLVER THAT DECIDES WHETHER AN INSTALLED PACKAGE CAN
  ## BUILD, and finding that out took measuring rather than reading.
  ## ``repro_cli_support.resolveMonitorShimLibPath`` looks like the
  ## resolver -- it has the develop-mode arms and the doc comment -- but
  ## its answer only ever reaches the DEV-ENV engine. The ordinary build
  ## path seeds ``REPRO_MONITOR_SHIM_LIB`` from HERE, and until this proc
  ## existed it seeded it from ``io_mon.findShimLibrary`` alone.
  ##
  ## io-mon's four arms are an env override, ``<appDir>/../lib``,
  ## ``<appDir>/`` (Windows side-by-side) and ``<cwd>/build/lib``. The
  ## second is the FLAKE's layout exactly -- ``$out/bin`` beside
  ## ``$out/lib`` -- which is why this never came up under Nix. A native
  ## package cannot use it: at prefix ``/usr`` it resolves to
  ## ``/usr/lib/librepro_monitor_shim.so``, and a package that dropped a
  ## private library straight into ``/usr/lib`` would be doing the thing
  ## ``ReprobuildPrivateLibSubdir`` exists to prevent. So the shim lives
  ## in the private libdir and this arm is how it is found there.
  ##
  ## LAST, so a develop checkout and an operator's explicit override both
  ## keep winning. Empty means "monitoring not configured", which the
  ## caller turns into a bypass rather than into a failure.
  result = findShimLibrary()
  if result.len > 0:
    return result
  result = monitorShimLibInLibraryPath(
    getEnv("REPROBUILD_RUNTIME_LIBRARY_PATH"),
    HostDynamicLibraryExt,
    proc(path: string): bool = fileExists(extendedPath(path)))

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
  ## The RunQuota process launcher layers these entries over the inherited
  ## environment, so a host value the action does not itself declare
  ## survives. A value it DOES declare replaces the inherited one — for
  ## ``PATH`` that is spelled out in ``prependPathDirsToArgvEnv``, and it
  ## is why an edge that declares no tools must still be given a ``PATH``
  ## it can use rather than an empty one. The value here
  ## is constant, so it does not perturb the action-cache fingerprint, and is
  ## inert for the ~99% of actions (plain ``nim c`` compiles) whose children
  ## never invoke ``repro``. Any explicit ``action.env`` entry wins (appended
  ## after).
  result = @["REPROBUILD_NO_RUNQUOTA=1", "IO_MON_MUTE=1"]
  # In-Process-Monitor-Hosting P6 — **``PWD`` is the action's working
  # directory, on every launch path**, because otherwise the LAUNCHER's
  # working directory leaks into the ACTION's dependency evidence.
  #
  # WHAT WAS MEASURED, and it is not what P6 guessed. The wrapped arm
  # recorded the run root's whole ancestor chain in ``monitorProbes``
  # (``/tmp``, each intermediate directory, the run root, the work root) and
  # the hosted arm did not. It is NOT a directory-creation walk by the
  # engine or by io-mon: ``createDir(depDest.parentDir)`` in
  # ``startMonitorHost``, and io-mon's ``createLocalTempDir`` /
  # ``ensureParentDir``, all run in a process that is OUTSIDE the monitored
  # tree on BOTH paths, so none of them can be recorded at all (a monitored
  # ``repro internal io monitor`` run over a one-``open`` C binary records
  # zero probes, and with the shm set disabled every chain probe carries the
  # monitored ROOT's pid, not the host's).
  #
  # The walk is the action's OWN root process — any POSIX shell, including
  # the Nix ``gcc`` wrapper script — validating an inherited ``PWD`` that
  # names its own working directory: bash resolves that path component by
  # component (one stat per ancestor ⇒ one probe per ancestor). Two
  # controls, both run: (a) an action whose root is a plain C binary records
  # NO probes on either path, and (b) the HOSTED arm reproduces the whole
  # chain, entry for entry, as soon as the ENGINE is invoked from the
  # action's own work directory. What differed between the arms was never
  # the monitor — it was ``PWD``: the wrapped path interposes
  # ``umaskWrappedArgv``'s ``/bin/sh -c 'umask 022 && …'`` ABOVE the monitor
  # and that shell exports ``PWD=<action cwd>``, while the hosted path has no
  # wrapper shell and the child inherited the ENGINE's ``PWD``.
  #
  # So the same action recorded different evidence depending on which
  # directory the user happened to run ``repro build`` from — a launcher
  # fact reaching a cache-invalidation input — and the two launch paths
  # disagreed for the same reason. Handing every action a ``PWD`` that
  # agrees with its own ``cwd`` fixes both: it is what a POSIX shell would
  # have set anyway, it is a function of the action rather than of the
  # invocation, and it makes the hosted and wrapped forms produce the same
  # probes. Pinned by ``evidence is identical across launch paths`` in
  # ``tests/integration/t_every_launch_path_is_monitored.nim``, whose
  # fixture now PRODUCES the walk instead of comparing two empty sets.
  #
  # Only when the action names a ``cwd``: with none, the child's working
  # directory IS the engine's, so the inherited ``PWD`` already agrees with
  # it and there is no chdir for a shell to notice. An explicit
  # ``action.env`` entry still wins — it is appended after this one.
  #
  # ``OLDPWD`` travels with it, and for the same reason rather than for
  # tidiness: a shell validates that one too, so the directory the engine's
  # own parent shell happened to come FROM was landing in the action's probe
  # set (measured: one ``prExistingOther`` for it, which disappears when
  # ``OLDPWD`` is unset). It cannot be unset from here — this list is layered
  # OVER the inherited environment, so there is no removal channel — so it is
  # pointed at the same directory as ``PWD``, which costs the action nothing
  # (``cd -`` returns where it already is) and puts no launcher path in the
  # evidence.
  if action.cwd.len > 0:
    let actionPwd = absolutePath(action.cwd)
    result.add("PWD=" & actionPwd)
    result.add("OLDPWD=" & actionPwd)
  # M9.R.13c.2 — **shim-library env seed**. Inject
  # ``REPRO_MONITOR_SHIM_LIB`` at launch time so the daemon-spawned
  # ``repro internal io monitor`` subprocess deterministically locates
  # ``librepro_monitor_shim.{dll,so,dylib}`` without having to inherit
  # the user's shell environment. The seed lives HERE — not in
  # ``result.action.env`` — because the absolute shim path is machine-
  # specific (varies by repro install location); putting it in the
  # action's env would make the action ID non-reproducible across
  # machines and invalidate the binary-cache lookup. The seed is
  # constant across actions on the same machine (one repro install
  # surface) so it does not perturb action-ordering or partitioning.
  # An explicit ``action.env`` override wins because the action env is
  # appended after the seed and the process launcher's overlay is
  # last-write-wins.
  #
  # NOT SEEDED when the edge's policy sets ``suppressMonitorShimSeed``.
  # Suppressing the monitor WRAP is not sufficient on its own to keep an action
  # shim-free: io-mon's preload runtime propagates itself to child processes by
  # prepending the library named in ``REPRO_MONITOR_SHIM_LIB`` to their
  # ``LD_PRELOAD``. An action that builds its own interposer from that same
  # runtime therefore re-injects OUR shim into its children even though the
  # engine never wrapped it — which is exactly how a self-interposing test ends
  # up with two interposers again and livelocks.
  #
  # Measured: with the wrap suppressed but the seed still present, the
  # stackable-hooks fixture came up with
  # ``LD_PRELOAD=<monitor shim>:<test shim>`` and spun at 92% CPU. The two
  # must be gated together — a policy that says "do not monitor this action"
  # has to also mean "do not hand this action the means to monitor itself".
  #
  # The gate is an explicit per-edge OPT-OUT rather than "any kind outside
  # ``MonitorPolicyKinds``". Several non-monitored kinds — ``dgRecognizedFormat``
  # (every ``makeDepfilePolicy`` edge), ``dgPostBuildConverter`` — are seeded
  # today, and withdrawing the variable from all of them would be a silent
  # behaviour change across the whole depfile population. Only an edge that
  # asks loses it; the default is false.
  let shimLib =
    if action.dependencyPolicy.suppressMonitorShimSeed: ""
    else: resolveMonitorShimLibForInstall()
  if shimLib.len > 0:
    result.add("REPRO_MONITOR_SHIM_LIB=" & shimLib)
    # NO ``REPRO_MONITOR_INTEREST`` SEED HERE, DELIBERATELY. There used to be
    # one, with a comment claiming it gave this path "the same event-interest as
    # the hosted path". It did not, and it could not:
    #
    #   * ``REPRO_MONITOR_INTEREST`` is io-mon's channel to its own shim, not an
    #     input a caller supplies. `childEnv` (io-mon `fs_snoop.nim`) composes
    #     the monitored child's whole environment as host env, then
    #     `request.env`, then the injected pairs, and writes the interest
    #     variable LAST — the injection must win, or a caller could redirect
    #     `REPRO_MONITOR_SHIM_LIB` and silently disarm monitoring. All three
    #     platform arms call that one proc. So a value seeded here was
    #     overwritten before any shim could read it, on both hosting forms.
    #   * The one case where a shim reads an INHERITED value — a process that
    #     picked the shim up from an enclosing monitor's `LD_PRELOAD` rather
    #     than from an injection of ours — is a process whose records belong to
    #     THAT monitor's request. Seeding this action's narrower set there would
    #     have re-scoped a live outer capture, which is worse than doing
    #     nothing.
    #
    # The request now travels on the ARGV (`--interest`, see
    # ``monitorInterest`` and ``monitoredAction``), which is a channel io-mon
    # does not own and therefore cannot overwrite.
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
  # BuildXL `PipEnvironment.GetEffectiveEnvironmentVariables`
  # (`Public/Src/Engine/ProcessPipExecutor/PipEnvironment.cs:116-152`)
  # resolves every passthrough variable that carries NO declared value
  # by NAME out of the build engine's own process environment, and
  # silently drops the ones the host does not have. That is what this
  # does, and it is the half of the passthrough contract that lives at
  # LAUNCH time rather than at key time:
  #
  #   * the NAME was recorded in the weak fingerprint by
  #     `keyedOnActionEnvironment` when the graph was built;
  #   * the VALUE is read HERE, from the host, per launch.
  #
  # A variable the action already declares is left alone — the declared
  # value wins, exactly as in BuildXL's layering, where declared values
  # are overridden onto the base set before the by-name passthrough
  # resolution runs and only value-less passthroughs reach it.
  #
  # Today this is very nearly a no-op: the RunQuota launcher layers
  # these entries OVER the inherited environment, so an undeclared
  # passthrough already reaches the child by plain inheritance. It is
  # written explicitly anyway because inheritance is the channel
  # Reprobuild does not control and does not record, and when that
  # channel is closed this is the mechanism that keeps a declared
  # passthrough working.
  if action.envPassthrough.len > 0:
    var declaredNames = initHashSet[string]()
    for entry in action.env:
      let eq = entry.find('=')
      if eq > 0:
        declaredNames.incl(entry[0 ..< eq])
    var emitted = initHashSet[string]()
    for name in action.envPassthrough:
      if name.len == 0 or declaredNames.contains(name) or
          emitted.contains(name):
        continue
      emitted.incl(name)
      if not existsEnv(name):
        continue
      result.add(name & "=" & getEnv(name))

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

  const nonSipShellCandidateNames* = ["sh", "bash", "dash", "ash", "zsh"]
    ## Executable names accepted as the non-SIP wrapper shell, most-preferred
    ## first. ``sh`` stays first so a host that does expose one keeps its
    ## previous behaviour exactly; the rest exist because Nix and Homebrew put
    ## ``bash`` on PATH and (almost) never a bare ``sh``.

  proc resolveNonSipShell*(): string =
    ## Resolve a non-SIP POSIX shell suitable for wrapping a monitored
    ## action's redirection (`sh -c "<argv> > out 2> err"`). Resolution order:
    ##
    ## 1. ``<CT_SANDBOX_TOOLS_DIR>/bin/sh`` — the drop-in the io-mon monitor
    ##    populates (``populateReproSandboxTools``). This is the canonical
    ##    SIP-rewrite target (``rewriteSipPath("/bin/sh", dir)``), so reusing it
    ##    keeps the engine's wrapper shell identical to the one the monitor's
    ##    own exec-redirect would pick.
    ## 2. The first non-SIP shell on ``PATH``, tried under each of
    ##    ``nonSipShellCandidateNames`` in order. ``isSipProtected`` rejects
    ##    ``/bin``, ``/sbin``, ``/usr/bin``, ``/usr/sbin`` candidates so a SIP
    ##    shell is never selected here.
    ##
    ##    Probing more than ``sh`` is not a convenience. The doc above names
    ##    "the dev shell's Nix/Homebrew bash" as the intended fallback, but a
    ##    Nix profile links only ``bin/bash`` into a PATH directory — the
    ##    ``bin/sh`` symlink stays behind in the package's own store output,
    ##    which nothing puts on PATH. So on a stock Nix macOS host (CI runner or
    ##    developer laptop) the only ``sh`` reachable by name is the SIP
    ##    ``/bin/sh``, this proc returned ``""``, and every monitored action
    ##    failed the fail-safe below. Each name here is invoked identically, as
    ##    ``<shell> -c "umask 022 && <argv> > out 2> err"`` — plain POSIX that
    ##    bash, dash, ash and zsh all honour.
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
    for name in nonSipShellCandidateNames:
      for entry in pathEnv.split(PathSep):
        if entry.len == 0:
          continue
        let candidate = entry / name
        if not fileExists(candidate):
          continue
        if sip_propagation.isSipProtected(candidate):
          continue
        return candidate
    ""

  proc nonSipShellSearchReport*(): string =
    ## Human-readable account of what ``resolveNonSipShell`` just looked at.
    ##
    ## The fail-safe this feeds is unconditional and fatal, so its message has
    ## to carry enough to diagnose the host it fired on. Without this, the error
    ## says only "put a Nix/Homebrew sh on PATH" and the reader cannot tell
    ## whether PATH was empty, whether CT_SANDBOX_TOOLS_DIR pointed somewhere
    ## that lacks the drop-in, or whether shells were found and all rejected as
    ## SIP-protected.
    let sandboxDir = getEnv("CT_SANDBOX_TOOLS_DIR")
    var parts: seq[string] = @[]
    if sandboxDir.len == 0:
      parts.add("CT_SANDBOX_TOOLS_DIR unset")
    else:
      let dropInSh = sip_propagation.rewriteSipPath("/bin/sh", sandboxDir)
      parts.add("CT_SANDBOX_TOOLS_DIR=" & sandboxDir & " (no " & dropInSh & ")")
    var pathDirs = 0
    var rejected: seq[string] = @[]
    for entry in getEnv("PATH").split(PathSep):
      if entry.len == 0:
        continue
      inc pathDirs
      for name in nonSipShellCandidateNames:
        let candidate = entry / name
        if fileExists(candidate) and sip_propagation.isSipProtected(candidate):
          rejected.add(candidate)
    parts.add("searched " & $pathDirs & " PATH dir(s) for " &
      nonSipShellCandidateNames.join("/"))
    if rejected.len == 0:
      parts.add("no shell of any candidate name found on PATH")
    else:
      parts.add("rejected as SIP-protected: " & rejected.join(", "))
    parts.join("; ")

proc bypassActionStdoutLogPath(cacheRoot, actionId: string): string =
  bypassActionLogDir(cacheRoot) / (actionId & ".stdout.log")

proc bypassActionStderrLogPath(cacheRoot, actionId: string): string =
  bypassActionLogDir(cacheRoot) / (actionId & ".stderr.log")

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
    var shell = "/bin/sh"
    when defined(macosx):
      # RunQuota launches this argv directly. Using SIP-protected /bin/sh here
      # strips DYLD_* before the monitored command starts, so daemon-hosted
      # macOS actions lose both monitor injection and loader search paths.
      let nonSipShell = resolveNonSipShell()
      if nonSipShell.len > 0:
        shell = nonSipShell
    result.add(shell)
    result.add("-c")
    result.add("umask 022 && " & quoted)
  else:
    for entry in argv: result.add(entry)

proc preparedRunQuotaCommand(action: BuildAction;
                             config: BuildEngineConfig;
                             shellUmaskWrap = true): ReproCommandSpec =
  ## Build one argv/env contract for direct, helper, and inline launches.
  ## Sharing this prevents bypass execution from drifting away from normal
  ## RunQuota execution as tool-path and compiler flags evolve.
  ##
  ## In-Process-Monitor-Hosting HM-4 — ``shellUmaskWrap = false`` is the
  ## in-process host's form. The 0022 mask still applies; it is set around the
  ## spawn (``beginMonitorSpawnContext``) instead of by a wrapping
  ## ``/bin/sh -c 'umask 022 && …'``. That matters for EVIDENCE and not for
  ## tidiness: with the engine hosting, a wrapper shell would itself be inside
  ## the monitored tree, and its own reads and probes would land in the
  ## action's dependency set — where today the shell sits outside the monitor,
  ## one process above it.
  when defined(macosx):
    if action.monitorDepfile.len > 0 and resolveNonSipShell().len == 0:
      raiseEngine("SIP-safe monitored launch requires a non-SIP shell; " &
        "configure CT_SANDBOX_TOOLS_DIR or put a Nix/Homebrew sh on PATH " &
        "[" & nonSipShellSearchReport() & "]")
  let mergedEnv = mergeActionEnvWithMsvc(launchChildEnv(action, config))
  let toolBinDirs = resolvedToolBinDirs(action, config.toolIdentityResolver)
  let auxPaths = collectResolvedAuxPaths(action, config.toolIdentityResolver)
  var threadedEnv = prependPathDirsToArgvEnv(mergedEnv, toolBinDirs)
  threadedEnv = applyResolvedAuxPathsArgv(threadedEnv, auxPaths)
  threadedEnv = applyExplicitRuntimeLibraryEnvOverrides(threadedEnv,
    action.env)
  let nimAdjustedArgv = applyNimPathArgs(action.argv, auxPaths.nimPathDirs)
  let includePaths = partitionCompilerIncludePaths(auxPaths)
  let adjustedArgv = applyCompilerSystemIncludeArgs(nimAdjustedArgv,
    includePaths.systemDirs)
  let deferred = deferRuntimeLibraryEnvForShell(adjustedArgv, threadedEnv)
  ReproCommandSpec(
    argv: (if shellUmaskWrap: umaskWrappedArgv(deferred.argv)
           else: deferred.argv),
    cwd: action.cwd,
    env: deferred.env,
    stdoutLimit: config.stdoutLimit,
    stderrLimit: config.stderrLimit)

# ---------------------------------------------------------------------------
# In-Process-Monitor-Hosting HM-4 — the engine hosts io-mon's consumer itself.
#
# WHAT THIS IS. A monitored action is normally launched as
# ``<repro> internal io monitor --depfile <f> -- <argv>``: the engine spawns a
# SECOND ``repro`` process whose only job is to be io-mon's host, and that
# process spawns the real command. When ``BuildEngineConfig.monitorHosting``
# is above ``mhmNever``, the launch paths the engine spawns skip that: the engine drives
# io-mon's decomposed host API directly (``startMonitor`` -> ``pollMonitor`` ->
# ``finishMonitor``, IoMon-Decomposed-Host-API DH-2) and the monitored tree's
# root is a direct child of the engine.
#
# IT IS OFF BY DEFAULT, on measurement, and the measurement is at the bottom of
# this block. Everything below describes what happens when it is ON.
#
# WHICH PATHS, AND WHY NOT ALL FOUR. io-mon OWNS the spawn — DH-4 says plainly
# that "spawn supplied by the caller is not delivered and should not be
# expected", because a host that owned the spawn would be back to the §4.1
# hand-rolled-host hazard the whole decomposition exists to close. So a launch
# path can host the monitor only if the ENGINE is the process that spawns:
#
#   * L1 bypass — the engine spawns. HOSTED.
#   * L2 RunQuota helper — the engine spawns ``repro
#     __repro-runquota-helper …`` and THAT process spawns the action, two
#     processes deep. There is no spawn here to hand to io-mon, so this path
#     keeps the CLI wrapper. ``repro internal io monitor`` is therefore still
#     a PRODUCTION path and not only a debugging entry point.
#   * L3 / L3b inline RunQuota — the engine spawns, but not directly:
#     ``offerWithRunQuotaBatch`` and ``startGrantedWithRunQuota`` spawn the
#     child THEMSELVES as part of binding it to the granted lease
#     (``lease.markRunning(childProcessId, processGroupId, …)``). Hosting
#     there needs a RunQuota lease that can adopt a child the caller already
#     spawned, which is a change to the RunQuota adapter's contract and not to
#     this file. They keep the CLI wrapper for now.
#
# A path that keeps the wrapper is NOT degraded — it is monitored exactly as
# it was, by the same io-mon code, and ``evidence is identical across launch
# paths`` in tests/integration/t_every_launch_path_is_monitored.nim is what
# holds the two forms to the same evidence.
#
# AND THE LIST ABOVE IS NOT PROSE — it is ``launchPathHostsMonitorInProcess``,
# an exhaustive ``case`` over ``MonitorLaunchPath`` that the hosting decision
# in ``runBuild`` reads and that a new launch path does not compile without.
# It used to be a bare ``bypassRunQuota`` conjunct on the decision line, with
# this comment carrying the reasoning, and that arrangement had a dormant
# cardinal-sin hazard in it: the inline launch site is staged and ``continue``s
# before the branch that consults ``plan.hostInProcess``, so widening the
# conjunct would have stripped the wrapper from an inline action that no site
# was going to host — an unmonitored, successful, publishing action with an
# empty dependency set and no diagnostic. In-Process-Monitor-Hosting P3 turned
# that into a REFUSAL: ``runBuild`` fails any action whose plan says hosted and
# whose launch path is not L1, with ``monitorHostingRefusal``'s sentence. The
# unmonitored state is no longer reachable by widening a boolean; it takes a
# launch site that actually starts a host.
#
# WHEN THE SCHEDULER FINISHES A MONITOR: on the poll pass that first observes
# the root's exit, for EVERY monitor that has exited, not only the one the
# scheduler goes on to reap. This is a deliberate choice with an evidence
# consequence, measured by DH-4 (item 3 of its landing record): the §4.1
# detached-descendant grace window OPENS when ``finishMonitor`` runs, so a
# monitor left sitting in the queue grades a descendant that dies in the
# interval ``mcComplete`` where the reference (batch) form grades it
# ``mcIncomplete`` — on identical inputs, with nothing wrong. Finishing on the
# observing pass pins the window's opening to root-exit DETECTION, so it is
# one poll interval (~1 ms) after the real exit and does not vary with how
# many other actions happen to be in flight.
#
# ENGINE-THREADPOOL TP-2 CHANGED WHERE THAT WORK RUNS AND NOT WHEN IT STARTS.
# The pass that first observes the exit now HANDS THE MONITOR OFF to a worker
# (``handOffMonitorFinish``) instead of finishing it inline; the outcome comes
# back through ``drainMonitorFinishesInto`` on a later pass. The paragraph
# above is unchanged in substance and is now MEASURED rather than argued: the
# interval between the pass's start and the worker entering ``finishMonitor``
# is stamped on every finish (``MonitorFinishOutcome.openDelayNs``) and
# ``a pooled finish does not widen the grace window`` asserts it stays under
# one §4.1 grace, against a one-worker sensitivity control that shows the same
# instrument reporting a delay of several.
#
# What that removed is the cost this comment used to end with: a monitor whose
# descendants are still alive no longer blocks the loop for the grace window
# (500 ms by default) — it blocks a worker, exactly as the spawned form
# blocked a separate process, and the k-th monitor of a pass no longer waits
# for its k-1 predecessors.
#
# AND THIS IS WHY ``BuildEngineConfig.monitorHosting`` DEFAULTS TO ``mhmNever``.
# The case for hosting is latency: one process spawn per monitored action
# removed. That spawn IS removed and it IS worth something — but the monitor's
# end-of-action work moves with it, out of N concurrent monitor processes and
# into this one loop, where it is paid SERIALLY. Which of the two dominates is
# a question about the workload, and it was measured rather than argued.
#
# Linux, 32 cores, ~850 live processes, hosted and wrapped arms compiled from
# the same source and run INTERLEAVED so machine drift cancels. Milliseconds
# per action, 3-5 samples per cell, spread shown:
#
#   40 trivial actions           hosted        wrapped
#     parallelism 1              26-46         58-64      hosting ~2x FASTER
#     parallelism 4              15-27         18-24      a wash
#
#   120 trivial actions          hosted        wrapped
#     parallelism 8 (default)    14-18         6-11       hosting ~2x SLOWER
#     parallelism 16             11-26         5-10       hosting ~2-3x SLOWER
#     parallelism 32             13-26         4-11       hosting ~2-3x SLOWER
#
#   80 actions, parallelism 8, per-action work varied:
#     ~0 ms of work              15-33         8-13       hosting ~2-3x SLOWER
#     ~100 ms of work            26-35         21-23      hosting ~20% slower
#     ~500 ms of work            76-82         72-81      indistinguishable
#
# The mechanism is arithmetic. `startMonitor` is cheap; `finishMonitor` costs
# ~14 ms per action here, and a hosted build pays it one action at a time —
# 120 actions x ~14 ms is the ~1.7 s the parallelism-8 row shows, and it does
# not improve with more parallelism because nothing about it is parallel. The
# wrapped form pays the same ~14 ms inside N concurrent processes. So hosting
# wins whenever there is nothing to overlap (parallelism 1), and loses whenever
# an action is cheaper than `parallelism x 14 ms` of real work.
#
# The absolute numbers belong to one machine at one moment and are NOT a
# specification; the SHAPE is the finding, and the shape is that the default
# parallelism is 8 and typical actions are cheaper than ~112 ms of work.
#
# WHAT WOULD CHANGE THE ANSWER: `finishMonitor` leaving the scheduler's serial
# path. Its cost is already down an order of magnitude from where this
# milestone started — the io-mon revision pinned in flake.nix cut the §4.1
# descendant sweep from ~105 ms to ~6 ms, which is what turned a hard ceiling
# of 5-6 actions/second into the ~70/second measured above. That was enough to
# make hosting viable and not enough to make it preferable. An async flush, or
# a finish that does not block the poll loop, is the remaining item; re-measure
# at the parallelism the build actually uses before flipping the default.
#
# BOTH OF THOSE HAVE NOW SHIPPED — HM-5's async flush and TP-2's pooled finish
# — SO THE NUMBERS ABOVE ARE A RECORD OF THE FORM THAT WAS MEASURED AND NOT OF
# THE ONE THAT SHIPS. They are deliberately left as they were: re-measuring
# them is Engine-Threadpool TP-3's acceptance, which inherits HM-6's controls
# (interleaved arms, rotating order, a drift control and a sensitivity
# control) precisely because a null from a blind instrument is worthless.
# Nothing here should be read as a claim that hosting is now faster, and
# `monitorHosting` stays `mhmNever` by default until TP-3 says otherwise.
#
# ---------------------------------------------------------------------------
# In-Process-Monitor-Hosting HM-5 — the depfile flush, and WHAT IT COULD AND
# COULD NOT MOVE.
#
# HM-5 asks for the `.iomon` to be written asynchronously and atomically so the
# scheduler can hand an action's evidence onward before the file lands. Both
# halves of its premise turned out to be wrong about this code, and both
# corrections are load-bearing:
#
# 1. "THE `.iomon` IS A WRITE-ONLY ARTEFACT." It is not. `readMonitorDepFile`
#    genuinely has zero call sites, but the engine reads the file anyway,
#    through `foldMonitorDepFileEvidence` — a hand-rolled iomon reader written
#    so the depfile OBJECT is not retained. Evidence collection therefore had a
#    hard dependency on the file existing by the time the action was reaped, and
#    an async flush alone would have raced it into `mrMissingFile`. The fix is
#    `foldMonitorRecordsEvidence`: on the hosted path the engine folds the
#    records `finishMonitor` already returned and never reads the file.
#
# 2. "THE FLUSH IS THE ENGINE'S TO MOVE." It is not. io-mon owns the canonical
#    write inside `finishMonitor` (`collectMonitorEvidence` -> `mergeFragments`
#    -> `writeCanonicalInPlace`) and exposes no way to obtain the records
#    without it. What the engine can decide is WHERE that write goes and WHEN
#    it becomes the published depfile — so io-mon is pointed at a scratch
#    sibling of the destination and the flush worker publishes it with a
#    rename.
#
# MEASURED (this machine, io-mon 30e5499, under load; absolute numbers are not
# a specification, the ratios are the finding). Per monitored action:
#
#   depfile size            encode+write   of which real I/O   read-back+decode
#   97 217 records / 18 MB  ~584 ms        ~114 ms             ~193 ms
#      140 records / 25 KB  ~1.1 ms        negligible          ~0.4 ms
#
# The 97k-record row is a real `nim c` provider compile out of this repo's own
# cache; the 140-record row is a trivial monitored action, which is the regime
# HM-4's enable/disable measurement ran in.
#
# SO WHAT HM-5 CHANGES, exactly:
#   * the ~193 ms decode leaves the serial path entirely (correction 1);
#   * the publication leaves it (this milestone's mechanism);
#   * the ~584 ms encode+write DOES NOT, because it is io-mon's.
#
# AND WHAT IT DOES NOT CHANGE: HM-4's verdict. In HM-4's regime the whole
# encode+write is ~1.1 ms of a ~14 ms `finishMonitor`, i.e. under a tenth, and
# the decode is ~0.4 ms. Removing all of it still leaves ~12 ms paid serially
# per action, so hosting is still slower than the wrapper at parallelism 8.
# `monitorHosting` stays `mhmNever` by default.
#
# THAT WAS ALSO MEASURED END TO END rather than only argued from the parts: 60
# trivial actions at parallelism 8, hosted and wrapped arms interleaved, three
# rounds, before and after this milestone. The HOSTED/WRAPPED RATIO is the
# figure to read — the machine was at load average ~67 throughout (other work
# on the same host), so the absolute numbers move by 2x between rounds while
# the ratio does not. Before: 1.74, 1.25, 2.04. After: 2.08, 1.29, 1.54.
# Indistinguishable. Re-measure on a quiet machine before HM-6 concludes
# anything from the absolute numbers; the ratio is what carries.
#
# WHAT WOULD ACTUALLY MOVE THE NUMBER, for whoever takes HM-6: one field on
# io-mon's `FsSnoopRequest` — "produce the evidence but do not write the file".
# `writeCanonicalInPlace` is two `encodeFrame` passes over every record and it
# is four fifths of the write; skipping it, with the engine already folding
# from records and publishing asynchronously, would take a real action's
# serial wrap-up from ~780 ms to the merge alone. That is an io-mon change, so
# it is named here rather than worked around: pointing io-mon at `/dev/null`
# and re-encoding on the flush worker was measured and rejected — it saves the
# ~114 ms of I/O and spends ~470 ms of duplicated CPU per action to do it.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Engine-Threadpool TP-2 — ``finishMonitor`` moved off the scheduler's poll
# loop and onto the engine's worker pool.
#
# WHY THIS LIVES IN THIS MODULE AND NOT IN A LEAF ONE OF ITS OWN, which is
# the shape HM-5's flush established and the shape this was first written in.
# The tenant has to name ``MonitorHandle``, ``MonitorRecord`` and
# ``finishMonitor``, i.e. it has to import ``io_mon`` and CALL a spawn
# primitive — and ``t_every_launch_path_is_monitored`` forbids both outside
# this file, twice over and deliberately: ``io_mon`` is a
# ``SpawnCapabilityModule`` only this module may import, and every call site
# of ``finishMonitor`` (a ``SpawnPrimitive``, because on the Windows arm the
# spawn is DEFERRED into it) must be in this module. A leaf module would have
# reddened that gate on both rules, and the fix for that is not to widen the
# gate — the audit exists because a launch path outside the enumeration is
# the failure it was written for. So the tenant sits next to the
# ``MonitorHostPool`` it serves.
#
# WHAT THIS IS FOR. HM-4 measured in-process monitor hosting as a null at the
# default parallelism and a 1.5-2.4x REGRESSION on cheap actions, and TP-2's
# milestone attributes both to one cause: the SPAWNED form pays its post-exit
# evidence assembly inside N concurrent monitor PROCESSES, while the hosted
# form pays it serially on one poll loop. ``finishMonitor`` costs ~6 ms fixed
# (the §4.1 ``/proc`` sweep) plus 13-19 µs per record, and a hosted build paid
# that one action at a time. This module is the second tenant of TP-1's pool
# and the thing that buys the concurrency back.
#
# ===========================================================================
# THE HANDOFF: OPTION (b), A SHARED-MEMORY CARRIER, AND WHY NOT (a) OR (c)
# ===========================================================================
#
# ``MonitorHandle`` cannot cross a thread boundary the obvious way:
# ``=copy`` is ``{.error.}`` and DH-2's verification measured that even
# ``createThread(t, worker, move(h))`` is refused, because ``typedthreads``'s
# ``param`` is not ``sink``. The milestone names three ways out.
#
#   (a) THE WORKER OWNS THE HANDLE FOR ITS WHOLE LIFE — ``startMonitor`` on
#       the worker too, so nothing crosses. REJECTED, and not on taste.
#       ``startMonitor`` must run inside ``beginMonitorSpawnContext``'s
#       window (``repro_build_engine.nim``), which ``dup2``s descriptors
#       0/1/2 onto this action's stdio captures and sets ``umask(0022)``.
#       Both are PROCESS-global. Opening that window on a worker would make
#       every OTHER thread's ``stdout``/``stderr`` — the scheduler's own
#       diagnostics included — land in some action's capture file, and two
#       workers opening it concurrently would interleave two actions' stdio
#       irrecoverably. Serialising the window with a lock does not rescue
#       (a) either: the window would then be held across a spawn while the
#       main thread is blocked out of its own output. (a) is a redesign of
#       how a hosted action captures stdio (``posix_spawn`` file actions,
#       which io-mon does not expose), not a handoff.
#
#   (c) MAKE ``param`` ``sink``-COMPATIBLE UPSTREAM. Out of this repository,
#       and unnecessary: TP-1's pool does not hand a worker a
#       ``createThread`` payload at all. Its jobs are intrusive nodes in
#       ``allocShared0`` memory reached through a ``ptr``, so the
#       ``typedthreads`` limitation is not on this path.
#
#   (b) A SHARED-MEMORY CARRIER IN ``monitor_flush``'s STYLE. CHOSEN. The
#       scheduler ``move``s the handle out of its slot and into a node this
#       module allocates; a worker ``move``s it out of the node and into
#       ``finishMonitor``; the node carries the evidence back. Nothing is
#       copied at any step, so the type's refusal is never even approached.
#
# ===========================================================================
# LF-2 IS STILL STRUCTURAL, NOT MERELY UNLIKELY
# ===========================================================================
#
# LF-2 — "a producer never runs without a consumer" — is held by DH-2 through
# two properties of ``MonitorHandle``, and this module RELAXES NEITHER:
#
#   1. ``=copy`` is ``{.error.}``, so two owners of one consumer cannot be
#      WRITTEN DOWN. That is what makes an orphan unrepresentable rather than
#      forbidden, and it propagates into this module unchanged: the handle
#      field of ``MonitorFinishNodeObj`` is reached only by ``move``, and
#      every alternative — reading it out by value, assigning one node's
#      handle to another's, taking it as a by-value parameter, or handing it
#      to ``createThread`` — is a COMPILE ERROR. That is pinned out of
#      process, by driving the compiler and reading its exit code, in
#      ``test_monitor_finish_handoff_is_exclusive.nim``: ``compiles()``
#      cannot see a ``{.error.}`` ``=copy`` (DH-2 correction 3), so an
#      in-process ``static: doAssert not compiles(…)`` would be a test that
#      cannot fail.
#
#   2. ``=destroy`` runs ``endMonitor`` — reap the root, THEN release the
#      consumer. Unchanged, and it is what makes every exit path from this
#      module safe rather than merely intended. The carrier is
#      ``allocShared0`` memory, whose deallocation runs NO destructor, so
#      ``dropMonitorFinishNode`` below ``move``s the handle into an ordinary
#      Nim binding and lets THAT die — the destructor runs on the ordinary
#      binding, exactly as it does for a handle a scheduler slot drops. A
#      node is destroyed through that one proc and no other, so the "the
#      handle field was forgotten" defect is not reachable by adding an exit
#      path.
#
# The ordering that makes the whole thing safe is unchanged from HM-4's:
# a job is submitted only AFTER ``pollMonitor`` has answered true, so the
# monitored root has already been reaped by ``recordRootExit`` before the
# handle leaves the scheduler's thread. A worker therefore never waits for a
# root, and ``MonitorHandle.process`` — the only ``ref`` the type carries on
# an arm that hosts — is already ``nil`` when the handle crosses. (The Windows
# arm has a second, ``spawnEnv: StringTableRef``; that arm does not host at
# all, see ``InProcessMonitorHostSupported``.)
#
# ===========================================================================
# THE ONE PLACE THIS MODULE BREAKS TP-1's RULE, AND THE EVIDENCE FOR IT
# ===========================================================================
#
# ``worker_pool.nim``'s header says a ``{.cast(gcsafe).}`` in it would be a
# defect, and that is still true OF IT. This module needs one, in exactly one
# place — ``runMonitorFinishJob``'s call to ``finishMonitor`` — because
# **io-mon's ``finishMonitor`` is not ``gcsafe``** and no amount of care on
# this side changes that. Measured, not assumed: a ``{.nimcall, gcsafe.}``
# proc calling it fails ``nim check`` with
# ``'finishMonitor' is not GC-safe as it calls 'collectMonitorEvidence'``.
#
# WHAT THE CAST IS COVERING, ENUMERATED EXHAUSTIVELY RATHER THAN ARGUED. The
# compiler names only ONE offending global per proc, so reading its warnings
# is not an enumeration. The set was obtained by CONSTRUCTION instead: a
# writable copy of the pinned io-mon source, with each global the compiler
# named turned into a ``{.threadvar.}`` and the check re-run, until the probe
# compiled clean. Three rounds, three globals, all in io-mon's ``writer.nim``,
# and all three are PRODUCER-side state that a HOST process never attaches:
#
#   1. ``setProducer`` and 2. ``setElemImage`` — reached through
#      ``settleMonitorDescendants`` → ``waitForLinuxInjectedDescendants`` →
#      ``appendLauncherEventLoss`` → ``appendFragmentRecord``. Both are read
#      and written only under ``if setProducerAttached:``, and
#      ``setProducerAttached`` is set by ``attachDepQueueForShim``, whose only
#      caller is the SHIM — i.e. code running in the monitored child, not in
#      the engine. On Linux ``appendLauncherEventLoss`` does not even reach
#      ``appendFragmentRecord``: it publishes the loss through a
#      STACK-LOCAL ``SetProducer`` (``emitLauncherLossToSet`` attaches, emits
#      and detaches) and returns, because ``hostUsesFileFallback`` is
#      ``not defined(linux)``.
#   3. ``fragmentRunToken`` — reached through ``mergeFragments`` →
#      ``closeFragmentSlot`` → ``clearReadingSentinel`` →
#      ``writeReadTailMarker``, which returns at its FIRST statement unless
#      ``fragmentSlot.isOpen``. ``fragmentSlot`` is a ``{.threadvar.}``, zero
#      on a thread that has never opened a fragment, which no engine thread
#      does. Its only writer is ``setFragmentRunToken``, whose only caller in
#      the tree is the macOS shim's init.
#
# So on the host side none of the three is ever WRITTEN, and the only one
# that is even read is behind a per-thread gate that is false. The runtime
# half of that is not left as prose: ``depSetIsActive()`` is io-mon's own
# exported reading of ``setProducerAttached and setProducer.available``, and
# the tests assert it is false in the engine's process.
#
# Two further procs the compiler flags on this path — ``fragmentPath`` and
# ``fragmentHandleIsCurrent`` / ``reopenFragmentHandle`` — access no global
# at all; they are forward-declared without ``gcsafe``, which the analysis
# treats conservatively. Annotating the three forward declarations and the
# three globals upstream would let the cast be deleted outright, and that is
# the io-mon change worth asking for.
#
# NOTHING REFERENCE-COUNTED CROSSES, so HM-3's finding does not apply here.
# ORC's counts are atomic only under ``-d:gcAtomicArc``, and HM-3 shipped a
# ``ref`` across six threads and got 12 TSAN races on ``nimIncRef``. What
# crosses this boundary is a ``MonitorHandle`` (strings, a ``seq``, an
# ``FsSnoopRequest`` of strings, a ``SetHost`` of strings and a ``seq``) and a
# ``seq[MonitorRecord]`` (``MonitorRecord`` is PODs plus two ``string``s).
# Strings and seqs are unique-owner value types under ORC with no shared
# refcount; the one ``ref`` in ``MonitorHandle`` — ``process`` — is ``nil``
# before the handle crosses, because ``recordRootExit`` closed and cleared it
# when ``pollMonitor`` observed the exit. Every crossing is a MOVE, so no
# value is ever reachable from two threads at once.
#
# ===========================================================================
# THE OBLIGATION TP-1 HANDED THE SECOND TENANT, DISCHARGED
# ===========================================================================
#
# ``worker_pool.nim`` states plainly that its ``dup2``/``umask`` reasoning
# holds because its FIRST tenant creates no file, and that "a future tenant
# that opens or creates a file re-opens both questions". This tenant does
# create a file: ``finishMonitor`` writes the canonical iomon through
# ``writeCanonicalInPlace``. Both questions, answered:
#
#   * ``dup2`` on 0/1/2 — ``dup2`` never leaves a standard descriptor
#     closed, so an ``open`` on a worker inside the window cannot be handed
#     1 or 2, and the file io-mon writes is named by an absolute path the
#     scheduler chose. The residual is the OTHER direction: io-mon's
#     ``=destroy`` writes ONE warning line to ``stderr`` if a dropped handle
#     cannot be released, and a line emitted inside the window would land in
#     some action's captured stderr. It is an error-only path that no test
#     and no normal build reaches; it is DECLARED here rather than hidden.
#   * ``umask(0022)`` — a depfile io-mon creates while the window is open is
#     masked with 0022 instead of the ambient mask. 0022 is the canonical
#     mask this repository pins for every spawned tool (``umaskWrappedArgv``,
#     M9.R.36.3), so the difference can only ever make the artefact MORE
#     canonical, never less; and the artefact is a debugging depfile in the
#     cache root, not a secret. Declared, bounded, and not worth a
#     process-global lock that would serialise the very spawn this milestone
#     exists to speed up.
#
# LIKE THE FLUSH WORKER, THE FINISH WORKER NEVER WRITES TO ``stdout`` — see
# above for the single ``stderr`` residual. Failures come back as outcomes.
#
# ===========================================================================
# WHY THE NODE OUTLIVES ITS ``EnginePoolRelease``
# ===========================================================================
#
# TP-1's ``EnginePoolRelease`` is documented as "free the tenant's own node".
# This tenant's release hook does NOT free it — it hands it to a
# tenant-owned completed list that the SCHEDULER drains. The reason is the
# payload: a flush reports one ``cstring``, which the pool's own outcome can
# carry, while a finish reports a ``seq[MonitorRecord]`` — up to 97 000
# records and 18 MB for a real ``nim c`` action — that must reach the
# scheduler as a Nim value without a copy. So the node is the carrier in both
# directions and the pool's outcome is used only for what it is good at:
# the pending count that makes ``awaitEnginePoolTenantIdle`` mean something,
# and the fault attribution.
#
# The hook chosen is ``release`` and not the tail of the task, deliberately:
# ``runOneEnginePoolJob`` calls ``release`` on EVERY path, including after a
# task raised, so a node cannot be stranded by a fault. That is what keeps
# the scheduler from waiting forever for a slot whose worker died.
# ---------------------------------------------------------------------------


type
  MonitorFinishOutcome = object
    ## One completed ``finishMonitor``, as the SCHEDULER learns about it.
    actionId: string
    slot: int
      ## The ``MonitorHostPool`` slot this finish belongs to. Carried back so
      ## the scheduler does not have to keep a side table keyed on action id.
    exitCode: int
    failure: string
      ## Empty on success. Non-empty is the same
      ## ``io-monitor host failed: …`` sentence the serial form produced, so
      ## the fault surface an action sees is unchanged by where the work ran.
    records: seq[MonitorRecord]
      ## The canonical records ``finishMonitor`` returned. MOVED all the way
      ## from the worker: allocated on the worker's heap, transferred through
      ## the node, and moved out here. Never copied — a real provider compile
      ## carries 18 MB of them.
    openDelayNs: int64
      ## THE EVIDENCE-TIMING NUMBER, not a performance counter. DH-3/DH-4
      ## measured that the §4.1 detached-descendant grace window OPENS when
      ## ``finishMonitor`` runs, so a monitor left sitting grades a descendant
      ## that dies in the interval ``mcComplete`` where the batch reference
      ## grades it ``mcIncomplete`` — on identical inputs, with nothing wrong.
      ## This is the interval between the START of the poll pass that first
      ## observed the root's exit and the moment the worker entered
      ## ``finishMonitor``: the amount by which hosting delays the window's
      ## opening, measured the same way for a pool of one worker and a pool of
      ## many. It is what
      ## ``a pooled finish does not widen the grace window`` reads.
    queueDelayNs: int64
      ## The handoff alone — submit to worker entry. ``openDelayNs`` minus
      ## this is the time the poll pass itself took to reach the submit.

  MonitorFinishNode = ptr MonitorFinishNodeObj
  MonitorFinishNodeObj = object
    ## One pending finish, in ``allocShared0`` memory.
    ##
    ## ``base`` MUST be first: the pool hands a task a ``ptr
    ## EnginePoolJobObj`` and the task casts it back to this type, which is an
    ## identity on the address only while the header sits at offset 0. The
    ## ``static`` assertion below makes a reordering a compile error rather
    ## than a memory-corruption bug.
    base: EnginePoolJobObj
    handle: MonitorHandle
      ## THE CARRIER. Written once, by ``move``, on the scheduler's thread;
      ## consumed once, by ``move``, on a worker. Never read by value — that
      ## is a compile error, and the point (see the header's LF-2 section).
    nextCompleted: MonitorFinishNode
    slot: int
    actionId: cstring
    failure: cstring
    records: seq[MonitorRecord]
    exitCode: int
    passStartedAtNs: int64
    submittedAtNs: int64
    startedAtNs: int64

static:
  doAssert offsetOf(MonitorFinishNodeObj, base) == 0,
    "the pool job header must be the first field of MonitorFinishNodeObj"

var finishLock: Lock
var completedHead: MonitorFinishNode = nil
var statSamples: int = 0
var statMaxOpenDelayNs: int64 = 0
var statMaxQueueDelayNs: int64 = 0

initLock(finishLock)

let monitorFinishTenant = registerEnginePoolTenant("monitor-finish")

proc monotonicNowNs(): int64 =
  ## The clock BOTH sides of the handoff are stamped with. Monotonic on
  ## purpose: ``openDelayNs`` is a duration measured across threads, and a
  ## wall clock that steps backwards would report a negative grace-window
  ## delay rather than a real one.
  cast[int64]((getMonoTime() - MonoTime()).inNanoseconds)

proc runMonitorFinishJob(job: EnginePoolJob): cstring {.nimcall, gcsafe.} =
  ## THE WORK, on a pool worker: consume the handle, produce the evidence.
  ##
  ## The ``{.cast(gcsafe).}`` is the one the header enumerates and justifies.
  ## It is deliberately as SMALL as it can be — it wraps the ``finishMonitor``
  ## call and nothing else — so that any other global this module ever grew
  ## would still be caught by the compiler.
  let node = cast[MonitorFinishNode](job)
  node.startedAtNs = monotonicNowNs()
  try:
    {.cast(gcsafe).}:
      var outcome = finishMonitor(move(node.handle))
      node.exitCode = outcome.exitCode
      # MOVE, not copy: this is the seq ``writeCanonicalInPlace`` just
      # emitted, and it is the engine's whole evidence source on this path.
      node.records = move(outcome.depFile.records)
  except CatchableError as err:
    # A monitor fault must fail ONE action, never the host. The sentence is
    # byte-identical to the one the serial form produced, so
    # ``t_monitor_fault_fails_the_action_not_the_daemon`` keeps its meaning
    # now that the fault happens on another thread.
    node.failure = sharedDup("io-monitor host failed: " & err.msg)
  except Exception as err:
    # A ``Defect`` under the default ``--panics:off``. The pool would catch
    # this too and attribute it to the JOB, but a job-level error has no route
    # into the ACTION's result — so it is caught here, where it becomes the
    # same action failure any other monitor fault is. Letting the pool have it
    # would leave the slot finished with exit code 0, i.e. a silently
    # successful action whose evidence never arrived.
    node.failure = sharedDup("io-monitor host failed (defect): " &
      $err.name & ": " & err.msg)
  # The pool's own outcome carries no error: a finish that failed is not a
  # POOL fault, it is an ACTION failure, and it travels in ``node.failure``
  # so the scheduler attributes it to the action exactly as before.
  nil

proc releaseMonitorFinishJob(job: EnginePoolJob) {.nimcall, gcsafe.} =
  ## Hand the node to the scheduler rather than freeing it — see the header.
  ##
  ## Called on EVERY path, including after ``runMonitorFinishJob`` raised
  ## something it did not catch (a ``Defect`` under ``--panics:off``), which is
  ## exactly why the transfer is here and not at the tail of the task: a node
  ## stranded by a fault would leave the scheduler waiting forever for a slot
  ## that never finishes.
  let node = cast[MonitorFinishNode](job)
  let openDelay = node.startedAtNs - node.passStartedAtNs
  let queueDelay = node.startedAtNs - node.submittedAtNs
  acquire(finishLock)
  node.nextCompleted = completedHead
  completedHead = node
  inc statSamples
  if openDelay > statMaxOpenDelayNs: statMaxOpenDelayNs = openDelay
  if queueDelay > statMaxQueueDelayNs: statMaxQueueDelayNs = queueDelay
  release(finishLock)

proc dropMonitorFinishNode(node: MonitorFinishNode) =
  ## THE ONE PLACE A NODE IS DESTROYED, and the reason it is one place.
  ##
  ## ``deallocShared`` runs no destructor, so the ``MonitorHandle`` in the
  ## node has to be destroyed EXPLICITLY — by moving it into an ordinary Nim
  ## binding whose scope ends here. For a node whose task completed, that
  ## handle was already consumed by ``finishMonitor`` and the destructor is a
  ## no-op; for a node whose task faulted before reaching it, the destructor
  ## runs ``endMonitor`` (reap the root, THEN release the consumer) and LF-2
  ## holds on the fault path for the same reason it holds everywhere else.
  ## Freeing a node anywhere but here is how that would stop being true.
  block:
    let orphan = move(node.handle)
    discard orphan.live
  # ``move`` leaves the source default-initialised, so nothing below is
  # holding a payload the deallocation would strand.
  var records = move(node.records)
  records.setLen(0)
  sharedFree(node.actionId)
  sharedFree(node.failure)
  deallocShared(node)

proc submitMonitorFinish(actionId: string; slot: int;
                          handle: sink MonitorHandle;
                          passStartedAtNs: int64) =
  ## Hand one finish to the pool. Returns as soon as it is queued.
  ##
  ## ``passStartedAtNs`` is the start of the poll pass that OBSERVED the
  ## root's exit, not the time of this call: what the grace-window property is
  ## about is how long after the scheduler noticed the window opens, and a
  ## serial settle loop spends that interval inside its predecessors'
  ## ``finishMonitor`` calls rather than in a queue. Stamping at the pass makes
  ## the two shapes measurable on one scale.
  let node = cast[MonitorFinishNode](allocShared0(sizeof(MonitorFinishNodeObj)))
  node.slot = slot
  node.actionId = sharedDup(actionId)
  node.passStartedAtNs = passStartedAtNs
  node.submittedAtNs = monotonicNowNs()
  # THE HANDOFF ITSELF. A move, into zeroed shared memory whose ``=destroy``
  # for the destination is a no-op on an inactive handle. There is no copy
  # here and the type would refuse one.
  node.handle = move(handle)
  submitEnginePoolJob(monitorFinishTenant, actionId, addr node.base,
    runMonitorFinishJob, releaseMonitorFinishJob)

proc takeCompleted(alreadyTaken: seq[EnginePoolOutcome] = @[]):
    seq[MonitorFinishOutcome] =
  ## SCHEDULER-THREAD ONLY. The ``Table`` below is a local of an ordinary Nim
  ## proc, not a global a worker could reach, so it does not weaken anything
  ## the header claims about what crosses the boundary.
  ##
  ## The POOL's own outcome list is drained here as well as this module's, for
  ## two reasons. It should never carry an error — ``runMonitorFinishJob``
  ## catches both arms itself, precisely so the sentence an action sees is the
  ## one the serial form produced — but a pool-level fault that WAS somehow
  ## produced must not be dropped on the floor, and an undrained list would
  ## otherwise grow one node per monitored action for the length of a build.
  var poolErrors = initTable[string, string]()
  for outcome in alreadyTaken:
    if outcome.error.len > 0:
      poolErrors[outcome.key] = outcome.error
  for outcome in drainEnginePoolOutcomes(monitorFinishTenant):
    if outcome.error.len > 0:
      poolErrors[outcome.key] = outcome.error

  var head: MonitorFinishNode = nil
  acquire(finishLock)
  head = completedHead
  completedHead = nil
  release(finishLock)

  # The list is built head-first by the workers, so walking it yields
  # newest-first; the reversal below puts outcomes in completion order,
  # because a diagnostic naming several actions should read in the order they
  # happened.
  var collected: seq[MonitorFinishOutcome] = @[]
  var node = head
  while node != nil:
    let nxt = node.nextCompleted
    let actionId = $node.actionId
    let failure =
      if node.failure != nil: $node.failure
      else: poolErrors.getOrDefault(actionId, "")
    collected.add MonitorFinishOutcome(
      actionId: actionId,
      slot: node.slot,
      exitCode: node.exitCode,
      failure: failure,
      records: move(node.records),
      openDelayNs: node.startedAtNs - node.passStartedAtNs,
      queueDelayNs: node.startedAtNs - node.submittedAtNs)
    dropMonitorFinishNode(node)
    node = nxt
  result = @[]
  for i in countdown(collected.len - 1, 0):
    result.add move(collected[i])

proc drainMonitorFinishes(): seq[MonitorFinishOutcome] =
  ## Every finish that has COMPLETED since the last drain, without blocking on
  ## the ones that have not. This is what the scheduler's poll loop calls.
  takeCompleted()

proc monitorFinishPending(): int =
  ## Finishes queued or in flight. Zero does NOT mean "drained" — a completed
  ## node waits on this module's own list until the scheduler takes it.
  enginePoolPending(monitorFinishTenant)

proc awaitMonitorFinishes(timeoutSeconds = 120.0): seq[MonitorFinishOutcome] =
  ## Wait for every queued finish and return the outcomes not yet drained.
  ##
  ## Called at the end of a build and before a slot is abandoned. The timeout
  ## is a guard against a worker wedged on a hung filesystem and is generous
  ## on purpose: a real finish is bounded below by the §4.1 grace window (500
  ## ms by default) and above by the record count, and a build that has
  ## already succeeded must not be failed because a depfile merge was slow.
  # The pool's outcomes are TAKEN by the wait, not left for the drain below,
  # so they are passed in rather than discarded: a pool-level fault reported
  # for one of them would otherwise be swallowed by the very call that waited
  # for it.
  takeCompleted(awaitEnginePoolTenantIdle(monitorFinishTenant, timeoutSeconds))

proc awaitMonitorFinish(actionId: string; timeoutSeconds = 120.0):
    seq[MonitorFinishOutcome] =
  ## Wait until ONE named action's finish has completed, then drain everything
  ## that has accumulated. Returns early when nothing of this tenant's is in
  ## flight, for ``awaitEnginePoolOutcome``'s reason: with nothing pending, the
  ## outcome was either drained by an earlier call or never queued, and
  ## waiting longer would answer neither.
  takeCompleted(
    awaitEnginePoolOutcome(monitorFinishTenant, actionId, timeoutSeconds))

var serialFinishKnob = -1

proc monitorFinishForcedSerial(): bool =
  ## MEASUREMENT SEAM, Engine-Threadpool TP-3 — when
  ## ``REPROBUILD_FORCE_SERIAL_MONITOR_FINISH=1`` is set, the settle pass
  ## BLOCKS on each handed-off finish instead of letting the pass continue.
  ## That reproduces the pre-TP-2 shape (the k-th monitor of a pass waits for
  ## its k-1 predecessors) so the two hosted forms can be measured against
  ## each other in one binary, which is the only way an A/B is not also a
  ## comparison of two builds.
  ##
  ## IT IS NOT A PRODUCT SWITCH. Nothing in ``apps/`` or ``libs/`` sets it and
  ## no default reaches it: the environment is read ONCE, lazily, and the
  ## result is a single ``bool`` load on the one line per action that can see
  ## it. The wrapped path never constructs a ``MonitorHostPool`` at all, so
  ## the seam is unreachable there rather than merely inert.
  if serialFinishKnob < 0:
    serialFinishKnob =
      if getEnv("REPROBUILD_FORCE_SERIAL_MONITOR_FINISH") == "1": 1 else: 0
  serialFinishKnob == 1

proc resetMonitorFinishStats*() =
  ## Forget the handoff timings. Exists so a test that measures one build's
  ## grace-window delay does not read another's.
  acquire(finishLock)
  statSamples = 0
  statMaxOpenDelayNs = 0
  statMaxQueueDelayNs = 0
  release(finishLock)

proc monitorFinishStats*(): tuple[samples: int; maxOpenDelayNs: int64;
                                  maxQueueDelayNs: int64] =
  ## The timing evidence, accumulated across every finish since the last
  ## reset. Read by ``a pooled finish does not widen the grace window``.
  acquire(finishLock)
  result = (samples: statSamples, maxOpenDelayNs: statMaxOpenDelayNs,
            maxQueueDelayNs: statMaxQueueDelayNs)
  release(finishLock)

proc monitorFinishTenantIsAttachedToADepSet*(): bool =
  ## io-mon's OWN reading of the two globals the ``{.cast(gcsafe).}`` above
  ## covers — ``setProducerAttached and setProducer.available``. It must be
  ## false in a HOST process, which is the runtime half of the header's
  ## argument that the cast covers nothing a worker can race. Exported so a
  ## test asserts it rather than a comment claiming it. Deliberately io-mon's
  ## predicate and not a reimplementation of it.
  depSetIsActive()

const InProcessMonitorHostSupported* = defined(linux) or defined(macosx)
  ## Windows is deliberately excluded. ``pollMonitor`` BLOCKS on that arm
  ## (DH-2: ``runWithMonitorShim`` spawns and waits in one call, so the first
  ## poll performs the whole run), and an N-way poll loop over blocking polls
  ## executes serially — hosting in-process there would turn a parallel build
  ## into a sequential one. The wrapper stays on Windows until
  ## nim-stackable-hooks grows a non-blocking spawn.

func launchPathHostsMonitorInProcess*(path: MonitorLaunchPath): bool =
  ## THE ONE TABLE that says which launch paths the engine can host io-mon
  ## on, and the only thing the hosting decision in ``runBuild`` reads.
  ##
  ## Exhaustive ``case``, no ``else``: a launch path added to
  ## ``MonitorLaunchPath`` does not compile until somebody classifies it,
  ## which is the point — the old shape let a launch path exist without
  ## anyone deciding whether it hosts.
  ##
  ## WIDENING A ROW HERE DOES NOT ENABLE HOSTING ON THAT PATH. The refusal in
  ## ``runBuild`` is keyed on the launch variables that select the spawn, not
  ## on this table, so a row flipped to ``true`` without teaching the
  ## corresponding launch site to start a host makes the action FAIL with
  ## ``monitorHostingRefusal``'s sentence instead of running unmonitored. See
  ## In-Process-Monitor-Hosting P4 for what the inline row actually needs.
  case path
  of mlpBypassRunQuota: true
  of mlpInlineRunQuota: false
  of mlpRunQuotaHelper: false

func monitorHostingRequested*(mode: MonitorHostingMode;
                              path: MonitorLaunchPath): bool =
  ## Whether ``mode`` asks for a hosted plan on ``path``. ``mhmRequired``
  ## says yes on every path ON PURPOSE: that is what carries an impossible
  ## request as far as the launch site, where it is refused with a
  ## diagnostic, instead of being silently downgraded to the wrapper where
  ## no test could ever see the difference.
  case mode
  of mhmNever: false
  of mhmWhereSupported: launchPathHostsMonitorInProcess(path)
  of mhmRequired: true

func monitorHostingRefusal*(path: MonitorLaunchPath): string =
  ## The diagnostic an action fails with when its monitor plan says the
  ## engine hosts io-mon and the launch site about to start it does not.
  ## Empty for a path that does host, so
  ## ``monitorHostingRefusal(p).len > 0`` and
  ## ``not launchPathHostsMonitorInProcess(p)`` are the same statement.
  const Why =
    "; refusing to launch it. A hosted plan carries the recipe's own argv " &
    "with NO `repro internal io monitor` wrapper, so an action that reaches " &
    "a launch site which starts no host runs completely unmonitored: no " &
    "iomon, an empty dependency set, and a successful, cache-publishing " &
    "action that reports nothing wrong. Teaching this path to host needs a " &
    "RunQuota lease that can adopt an already-spawned child " &
    "(In-Process-Monitor-Hosting P4), not a wider hosting decision."
  case path
  of mlpBypassRunQuota:
    ""
  of mlpInlineRunQuota:
    "in-process monitor hosting was requested for an action on the inline " &
    "RunQuota launch path, which binds the child to its granted lease by " &
    "spawning it itself" & Why
  of mlpRunQuotaHelper:
    "in-process monitor hosting was requested for an action on the RunQuota " &
    "helper launch path, which starts the action from a separate " &
    "`repro __repro-runquota-helper` process" & Why

const MonitorHostingEnvVar* = "REPROBUILD_MONITOR_HOSTING"
  ## The environment spelling of ``--monitor-hosting``
  ## (In-Process-Monitor-Hosting P1, option (b)). Same vocabulary, same
  ## parser, same default — see ``configuredMonitorHostingMode``.

func parseMonitorHostingMode*(value, source: string): MonitorHostingMode =
  ## In-Process-Monitor-Hosting P1(b) — the OPERATOR SURFACE for
  ## ``BuildEngineConfig.monitorHosting``.
  ##
  ## WHY IT LIVES HERE rather than beside the CLI's other flag parsers. The
  ## default this decodes is a MEASURED verdict, not a UI preference, and
  ## ``test_umask_wrap_both_spawn_paths``'s "in-process hosting is off in
  ## every shipped configuration" pins it by scanning the shipped sources
  ## for the field name. Keeping the ``mhm*`` literals in the module that
  ## DECLARES them — the one module the scan exempts, because the first two
  ## checks of that case pin its only construction site at RUNTIME instead —
  ## means the CLI never has to spell an enabling mode to offer the flag.
  ## ``--monitor-hosting`` is therefore plumbing, not a shipped enable, and
  ## the pin can say so precisely.
  ##
  ## ``source`` is the spelling to blame in the diagnostic, exactly as
  ## ``parseBuildDaemonMode(value, source)`` uses it: the flag on the command
  ## line, the variable name in the environment.
  case value.toLowerAscii()
  of "never", "off":
    mhmNever
  of "where-supported", "wheresupported", "auto":
    mhmWhereSupported
  of "required", "require":
    mhmRequired
  else:
    raise newException(ValueError,
      "unsupported " & source & "=" & value &
        " (expected never, where-supported, or required)")

func parseEvidenceScope*(value, source: string): EvidenceScope =
  ## DA-1i — the OPERATOR SURFACE for ``BuildEngineConfig.evidenceScope``:
  ## ``repro build --evidence=full|reads-only``.
  ##
  ## THE VOCABULARY IS io-mon's AND IS NOT RESTATED. ``parseEvidenceScopeToken``
  ## is the single codec for both channels the token travels on (the
  ## ``--evidence`` flag this decodes, and the ``evidence=`` stamp a depfile
  ## carries), so the value an operator types and the value a reader later
  ## compares against cannot come from two tables that drift.
  ##
  ## TWO VALUES ARE REJECTED THAT ``parseEvidenceScopeToken`` ACCEPTS or
  ## PRODUCES, and both rejections are the point of this wrapper:
  ##
  ## * the EMPTY string. On the env channel an absent ``REPRO_MONITOR_EVIDENCE``
  ##   means "write everything down", so io-mon widens it to ``esFull``. On a
  ##   command line ``--evidence=`` is a typo, and answering a typo with the
  ##   default is how an operator who meant ``reads-only`` gets ``full``
  ##   silently — or, far worse, believes they got the narrowing they asked for.
  ## * anything io-mon cannot name, which parses to ``esUnrecognized``. That is
  ##   a READING of a stamp from a newer io-mon, never a scope this build can
  ##   ask for; it covers nothing, so accepting it here would build with a
  ##   scope whose own captures this build then refuses to trust.
  ##
  ## ``source`` is the spelling to blame in the diagnostic, exactly as
  ## ``parseMonitorHostingMode(value, source)`` uses it.
  let scope = parseEvidenceScopeToken(value)
  if value.strip().len == 0 or scope == esUnrecognized:
    raise newException(ValueError,
      "unsupported " & source & "=" & value &
        " (expected full or reads-only)")
  scope

proc configuredMonitorHostingMode*(): MonitorHostingMode =
  ## The environment default for ``--monitor-hosting``. ``mhmNever`` when
  ## unset, which is the same value ``BuildEngineConfig``'s zero value gives,
  ## so an operator who never heard of this knob gets byte-identical
  ## behaviour to the pre-P1 engine.
  let configured = getEnv(MonitorHostingEnvVar, "")
  if configured.len == 0:
    return mhmNever
  parseMonitorHostingMode(configured, MonitorHostingEnvVar)

type
  MonitorHostRecord = object
    ## Per-slot bookkeeping for one hosted monitor. Everything here is plain
    ## data; the ``MonitorHandle`` itself lives in a parallel ``seq`` because
    ## it is non-copyable and this record is not.
    inUse: bool
    finished: bool
    actionId: string
      ## TP-2 — the key this slot's finish is submitted to the pool under, and
      ## what the returning outcome is checked against before it is applied.
      ## Kept on the slot because the handoff outlives the scheduler local the
      ## id used to come from.
    finishPending: bool
      ## TP-2 — this slot's handle has been MOVED into a pool job and the
      ## finish has not come back yet. Distinct from ``finished`` (the outcome
      ## has been applied) and from ``handleLive`` (the slot still owns a
      ## consumer): between the handoff and the drain the slot owns NEITHER a
      ## handle nor an outcome, and a slot in that state must not be released,
      ## re-polled, or handed off a second time.
    handleLive: bool
      ## This slot's ``MonitorHandle`` still owns a consumer and a monitored
      ## tree — i.e. it has NOT been moved into ``finishMonitor`` and has not
      ## been dropped.
      ##
      ## Tracked separately from ``finished`` because the two come apart on
      ## the failure paths: ``pollMonitor`` raising marks the slot finished
      ## WITHOUT consuming the handle, and so does ``rootPid`` raising after a
      ## successful ``startMonitor``. Keying teardown off ``finished`` would
      ## then free a slot whose handle is still live, and the next action to
      ## recycle that slot would assign over it — running io-mon's drop
      ## teardown, which WAITS for a monitored root nobody has killed. That is
      ## a build that stops making progress, so the invariant "a slot is only
      ## released once its handle is dead" is maintained explicitly here.
    failure: string
    exitCode: int
    rootPid: int
    stdoutPath: string
    stderrPath: string
    depTempPath: string
      ## HM-5 — where io-mon was told to write this action's canonical iomon: a
      ## scratch sibling of ``depDestPath``, never the destination itself and
      ## never ``getTempDir()``. See ``monitorFlushTempPath``.
    depDestPath: string
      ## ``action.monitorDepfile`` — the published path. Nothing writes it
      ## directly on this path; the flush worker renames ``depTempPath`` onto
      ## it, which is the only way it ever appears or changes.
    records: seq[MonitorRecord]
      ## The canonical records ``finishMonitor`` returned, held only until the
      ## scheduler has folded them into evidence and dropped them. This is the
      ## engine's evidence source on the hosted path — see
      ## ``foldMonitorRecordsEvidence`` for why the file cannot be.

  MonitorHostPool = object
    ## The scheduler's in-flight monitors.
    ##
    ## A ``seq[MonitorHandle]`` is legal and a copy out of one is not: DH-2
    ## makes ``=copy`` a compile error so that "two owners of one consumer"
    ## cannot be written down, and that propagates through ``seq``. Every
    ## access below therefore either indexes in place or ``move``s out. Slots
    ## are recycled but NEVER deleted — ``seq.delete`` shifts elements by
    ## assignment, which is exactly the copy the type refuses.
    handles: seq[MonitorHandle]
    records: seq[MonitorHostRecord]
    flushNonce: int
      ## HM-5 — uniquifies the scratch file each action's depfile is written
      ## to. A slot index would not: slots are RECYCLED, and a recycled slot
      ## can be handed to the next action while the previous action's
      ## publication is still in flight, which is exactly the overlap this
      ## milestone exists to create.

proc allocMonitorHostSlot(pool: var MonitorHostPool): int =
  for i in 0 ..< pool.records.len:
    if not pool.records[i].inUse:
      pool.records[i] = MonitorHostRecord(inUse: true)
      return i
  pool.handles.add(MonitorHandle())
  pool.records.add(MonitorHostRecord(inUse: true))
  pool.records.len - 1

proc monitorHostRequest(action: BuildAction;
                        command: ReproCommandSpec;
                        depFilePath: string;
                        evidenceScope: EvidenceScope): FsSnoopRequest =
  ## Project the ONE argv+env contract every launch path shares onto io-mon's
  ## request. Both sides layer over the hosting process's own environment
  ## (``ReproCommandSpec.env`` through RunQuota's process backend,
  ## ``FsSnoopRequest.env`` through io-mon's ``childEnv``), so the monitored
  ## child sees the same variables it saw when a second ``repro`` process was
  ## in between — which is what makes the two hosting forms comparable at all.
  ##
  ## ``depFilePath`` is the caller's, not ``action.monitorDepfile``. Since HM-5
  ## the hosted path hands io-mon a SCRATCH sibling of the real depfile and
  ## publishes it with a rename, so io-mon's write — which it owns, and which
  ## no request field can switch off — never lands on the path anything else
  ## reads. Passing it explicitly is what keeps that decision at the one call
  ## site that makes it, instead of leaving a second proc quietly able to
  ## write the destination in place.
  # The event-interest request. ONE definition, shared with the wrapped path
  # (which forwards the same answer to `repro internal io monitor` as
  # `--interest`), so the two hosting forms cannot ask io-mon for different
  # categories for the same action — see ``monitorInterest``.
  #
  # DA-1i — the evidence scope arrives as an ARGUMENT rather than being read
  # from a config here, because this proc has no config and the caller
  # (``startMonitorHost``) does. It is ``monitorEvidenceScope``'s answer, the
  # same one the wrapped path spells as ``--evidence``, so the two hosting
  # forms cannot narrow differently for the same action.
  result = FsSnoopRequest(
    command: command.argv,
    depFilePath: depFilePath,
    cwd: command.cwd,
    streamMode: fsoNone,
    interest: monitorInterest(action),
    evidenceScope: evidenceScope,
    passthroughChildStdout: true,
    passthroughChildStderr: true)
  for entry in command.env:
    let eq = entry.find('=')
    if eq <= 0:
      continue
    result.env.add((entry[0 ..< eq], entry[eq + 1 .. ^1]))

when defined(posix):
  type MonitorSpawnContext = object
    savedIn: cint
    savedOut: cint
    savedErr: cint
    nullFile: File
    outFile: File
    errFile: File
    savedMask: Mode
    active: bool

  proc beginMonitorSpawnContext(outPath, errPath: string): MonitorSpawnContext =
    ## Re-establish, across io-mon's spawn, the three things the retired
    ## ``/bin/sh -c 'umask 022 && <repro> internal io monitor …'`` wrapper and
    ## RunQuota's process backend used to provide for free.
    ##
    ## STDIO. io-mon spawns with ``poParentStreams``, so the monitored child
    ## inherits THIS process's descriptors 0, 1 and 2 — for the engine, the
    ## user's terminal, not a per-action capture. Pointing 1 and 2 at two
    ## per-action files across the spawn gives the engine back separate
    ## ``stdout`` and ``stderr``, and does it WITHOUT the monitored tree
    ## opening anything: the child inherits descriptors that are already open,
    ## so no ``open`` of a log path enters its dependency evidence. (A shell
    ## redirect inside the monitored command would have put both log paths
    ## into ``monitorWrites`` — which is why this is done here and not there.)
    ##
    ## STDIN, and it is descriptor 0 that makes this a correctness fix rather
    ## than a capture convenience. EVERY other launch path gives the child
    ## ``/dev/null`` on descriptor 0 — RunQuota's POSIX backend opens it
    ## explicitly before ``execvp`` (``runquota_process.nim``), so an action
    ## that reads stdin sees immediate EOF. ``poParentStreams`` hands the child
    ## the ENGINE's stdin instead, which in a normal ``repro build`` is the
    ## user's terminal: a monitored action that reads stdin would block the
    ## build waiting for a keystroke, or worse, eat one. Redirecting it here
    ## makes the hosted path answer EOF like every other path.
    ##
    ## UMASK. ``umaskWrappedArgv`` (M9.R.36.3) pins every spawned tool to the
    ## canonical 0022 mask by wrapping the argv in a shell. A hosted action has
    ## no wrapper shell to carry it, and monitoring one would add the shell's
    ## own reads to the action's evidence, so the mask is set here and restored
    ## immediately; a child inherits it across ``fork``.
    ##
    ## SAFE BECAUSE THE SCHEDULER IS SINGLE-THREADED, AND BECAUSE THE ONLY
    ## OTHER THREADS OPEN NOTHING. The engine runs N concurrent child
    ## PROCESSES from one poll loop, not N threads, so no other SCHEDULER code
    ## can observe the window between this call and
    ## ``endMonitorSpawnContext``.
    ##
    ## The qualification is Engine-Threadpool TP-1's, and the previous version
    ## of this comment — "``createThread`` has zero occurrences in this
    ## library" — was already wrong when it was written: HM-5's flush worker
    ## was in ``repro_build_engine/monitor_flush.nim``, inside this library.
    ## The claim that MATTERS was never the thread count anyway, it is what
    ## those threads do, and it is checked rather than assumed in
    ## ``worker_pool.nim``'s header: a pool worker opens no file and creates
    ## no file, so neither the ``dup2`` on 0/1/2 nor the ``umask`` can be
    ## observed by one. A future pool tenant that opens or creates a file
    ## re-opens both questions, and it breaks by interleaving one action's
    ## output into another's.
    flushFile(stdout)
    flushFile(stderr)
    result.savedIn = dup(cint(0))
    result.savedOut = dup(cint(1))
    result.savedErr = dup(cint(2))
    if result.savedIn < 0 or result.savedOut < 0 or result.savedErr < 0:
      if result.savedIn >= 0: discard close(result.savedIn)
      if result.savedOut >= 0: discard close(result.savedOut)
      if result.savedErr >= 0: discard close(result.savedErr)
      raiseEngine("in-process monitor host: cannot duplicate stdio")

    proc closeSaved(ctx: MonitorSpawnContext) =
      discard close(ctx.savedIn)
      discard close(ctx.savedOut)
      discard close(ctx.savedErr)

    if not open(result.nullFile, "/dev/null", fmRead):
      closeSaved(result)
      raiseEngine("in-process monitor host: cannot open /dev/null")
    if not open(result.outFile, outPath, fmWrite):
      close(result.nullFile)
      closeSaved(result)
      raiseEngine("in-process monitor host: cannot open stdout capture " &
        outPath)
    if not open(result.errFile, errPath, fmWrite):
      close(result.nullFile)
      close(result.outFile)
      closeSaved(result)
      raiseEngine("in-process monitor host: cannot open stderr capture " &
        errPath)
    discard dup2(cint(getFileHandle(result.nullFile)), cint(0))
    discard dup2(cint(getFileHandle(result.outFile)), cint(1))
    discard dup2(cint(getFileHandle(result.errFile)), cint(2))
    result.savedMask = umask(Mode(0o022))
    result.active = true

  proc endMonitorSpawnContext(ctx: var MonitorSpawnContext) =
    if not ctx.active:
      return
    ctx.active = false
    discard umask(ctx.savedMask)
    flushFile(stdout)
    flushFile(stderr)
    discard dup2(ctx.savedIn, cint(0))
    discard dup2(ctx.savedOut, cint(1))
    discard dup2(ctx.savedErr, cint(2))
    discard close(ctx.savedIn)
    discard close(ctx.savedOut)
    discard close(ctx.savedErr)
    close(ctx.nullFile)
    close(ctx.outFile)
    close(ctx.errFile)
else:
  type MonitorSpawnContext = object
    active: bool

  proc beginMonitorSpawnContext(outPath, errPath: string): MonitorSpawnContext =
    discard outPath
    discard errPath

  proc endMonitorSpawnContext(ctx: var MonitorSpawnContext) =
    discard ctx

proc monitorHostStdioStem(actionId: string): string =
  sanitizeActionId(actionId) & "-" & actionIdFileSuffix(actionId)

proc releaseMonitorHostSlot(pool: var MonitorHostPool; slot: int) =
  ## Return one slot to the pool, killing and dropping its monitor first if the
  ## handle is still live.
  ##
  ## THE ONLY WAY A SLOT IS FREED. Every caller goes through here so the pool's
  ## one invariant — a recyclable slot's handle is dead — cannot be broken by
  ## adding another exit path. The root is killed BEFORE the handle is dropped
  ## because dropping runs io-mon's teardown, which waits for the monitored
  ## root before releasing the consumer (IoMon-Decomposed-Host-API DH-2): that
  ## ordering is what makes an orphaned producer unrepresentable, and it is
  ## also what would otherwise let a still-running child hold the build open
  ## for as long as it liked.
  ## TP-2 — a slot whose finish is IN FLIGHT is not releasable and this is not
  ## the place that waits for it. The two callers that can reach such a slot
  ## (``finishMonitorHostAction`` and ``abandonMonitorHost``) call
  ## ``awaitMonitorHostFinished`` first; the guard below is what makes a third
  ## caller that forgot fail loudly — by leaving the slot allocated — instead
  ## of recycling a slot whose ``MonitorHandle`` is living inside a pool job.
  if slot < 0 or slot >= pool.records.len: return
  if pool.records[slot].finishPending: return
  if pool.records[slot].handleLive:
    when defined(posix):
      let pid = pool.records[slot].rootPid
      if pid > 0:
        when defined(linux):
          signalDescendants(pid, SIGKILL)
        discard kill(Pid(pid), SIGKILL)
    block:
      let handle = move(pool.handles[slot])
      discard handle.live
  pool.records[slot] = MonitorHostRecord()

proc startMonitorHost(pool: var MonitorHostPool; action: BuildAction;
                      config: BuildEngineConfig; cacheRoot: string): int =
  ## Bring io-mon's consumer up and launch the monitored tree, returning the
  ## pool slot that owns both. Raises like any other launch primitive; the
  ## caller turns a raise into the same ``process launch failed`` result the
  ## other paths produce.
  let command = preparedRunQuotaCommand(action, config, shellUmaskWrap = false)
  if command.argv.len == 0:
    raiseEngine("in-process monitor host: action has empty argv: " & action.id)
  let logDir = bypassActionLogDir(cacheRoot)
  createDir(extendedPath(logDir))
  let stem = monitorHostStdioStem(action.id)
  let outPath = logDir / (stem & ".host.stdout")
  let errPath = logDir / (stem & ".host.stderr")
  # HM-5 — io-mon writes HERE, and the scheduler publishes it with a rename.
  # ``createDir`` on the depfile's own directory is what makes the sibling
  # placement work on the first action of a build; io-mon's own
  # ``ensureParentDir`` would create it too, but only once it is about to
  # write, and the temp path is decided before that.
  inc pool.flushNonce
  let depDest = action.monitorDepfile
  let depTemp = monitorFlushTempPath(depDest, pool.flushNonce)
  if depDest.len > 0:
    createDir(extendedPath(depDest.parentDir))
  var ctx = beginMonitorSpawnContext(outPath, errPath)
  var slot = -1
  try:
    slot = allocMonitorHostSlot(pool)
    # TP-2 — the key this slot's finish will be submitted under, recorded
    # before anything can raise so the failure paths below release a slot the
    # drain can still recognise.
    pool.records[slot].actionId = action.id
    pool.records[slot].stdoutPath = outPath
    pool.records[slot].stderrPath = errPath
    pool.records[slot].depTempPath = depTemp
    pool.records[slot].depDestPath = depDest
    pool.handles[slot] = startMonitor(monitorHostRequest(action, command,
      depTemp, monitorEvidenceScope(config)))
    pool.records[slot].handleLive = true
    pool.records[slot].rootPid = int(rootPid(pool.handles[slot]))
  except CatchableError:
    if slot >= 0:
      # Never release a slot whose handle is still live — see
      # ``MonitorHostRecord.handleLive``. ``startMonitor`` may have succeeded
      # and a later statement raised.
      releaseMonitorHostSlot(pool, slot)
    raise
  finally:
    endMonitorSpawnContext(ctx)
  slot

proc handOffMonitorFinish(pool: var MonitorHostPool; slot: int;
                          passStartedAtNs: int64) =
  ## Engine-Threadpool TP-2 — GIVE the handle to a pool worker, which runs
  ## ``finishMonitor`` and hands the evidence back.
  ##
  ## THIS IS THE WHOLE MILESTONE, and what it replaces is a synchronous
  ## ``finishMonitor`` call on this line. ``finishMonitor`` costs ~6 ms fixed
  ## (the §4.1 ``/proc`` sweep) plus 13-19 µs per record, and the settle pass
  ## below runs over EVERY hosted monitor, so a serial finish made the k-th
  ## monitor of a pass wait for its k-1 predecessors. The spawned form paid
  ## the same work inside N concurrent monitor PROCESSES; this buys that
  ## concurrency back for the price of a thread handoff.
  ##
  ## THE MOVE IS THE HANDOFF AND IT IS ALSO THE SAFETY ARGUMENT.
  ## ``MonitorHandle``'s ``=copy`` is ``{.error.}`` (DH-2), so "the scheduler
  ## kept a second owner" is not a state that can be WRITTEN DOWN, here or in
  ## ``monitor_finish``. ``move`` leaves the slot's handle inactive, which is
  ## why ``handleLive`` drops on this line and not on the outcome's return.
  ##
  ## ``passStartedAtNs`` is stamped by the caller at the START of the settle
  ## pass, not here: see ``MonitorFinishOutcome.openDelayNs`` for why the
  ## grace window's opening is measured from there.
  if slot < 0 or slot >= pool.records.len: return
  if not pool.records[slot].inUse: return
  if pool.records[slot].finished or pool.records[slot].finishPending: return
  pool.records[slot].handleLive = false
  pool.records[slot].finishPending = true
  submitMonitorFinish(pool.records[slot].actionId, slot,
    move(pool.handles[slot]), passStartedAtNs)

proc applyMonitorFinishOutcome(pool: var MonitorHostPool;
                               outcome: var MonitorFinishOutcome) =
  ## Fold one returned finish back into its slot. The scheduler's poll loop
  ## calls this immediately after the settle pass, so a monitor is reapable on
  ## the very next iteration once its worker is done.
  ##
  ## The action id is checked as well as the slot index because slots are
  ## RECYCLED. It cannot mismatch today — a slot with ``finishPending`` set is
  ## never released, which is the invariant ``releaseMonitorHostSlot`` and
  ## ``abandonMonitorHost`` maintain — and the check is here so that a future
  ## release path which broke it would produce a diagnostic rather than
  ## silently attribute one action's evidence to another.
  let slot = outcome.slot
  if slot < 0 or slot >= pool.records.len: return
  if not pool.records[slot].inUse: return
  if pool.records[slot].actionId != outcome.actionId: return
  pool.records[slot].finishPending = false
  if outcome.failure.len > 0:
    # A monitor fault must fail ONE action, never the host — see
    # tests/integration/t_monitor_fault_fails_the_action_not_the_daemon.nim,
    # which states that as a property of the engine precisely so it keeps its
    # meaning now that the process boundary is gone. The sentence is built on
    # the worker so it is byte-identical to the one the serial form produced.
    pool.records[slot].failure = outcome.failure
  else:
    pool.records[slot].exitCode = outcome.exitCode
    # HM-5 — take the canonical records ``finishMonitor`` already built. This
    # is a MOVE, not a decode and not a copy: it is the very seq
    # ``writeCanonicalInPlace`` emitted, carried across the handoff without a
    # copy, so the engine's evidence source costs nothing here and the
    # ``.iomon`` stops being read back at all.
    pool.records[slot].records = move(outcome.records)
  pool.records[slot].finished = true

proc drainMonitorFinishesInto(pool: var MonitorHostPool) =
  ## ``mitems`` and a ``var`` parameter, not a ``for`` value: the outcome
  ## carries the action's whole record set — 18 MB for a real provider
  ## compile — and it is MOVED into the slot. A by-value loop variable would
  ## copy it.
  var outcomes = drainMonitorFinishes()
  for outcome in outcomes.mitems:
    applyMonitorFinishOutcome(pool, outcome)

proc settleMonitorHost(pool: var MonitorHostPool; slot: int;
                       passStartedAtNs: int64): bool =
  ## Advance one hosted monitor without blocking, and HAND ITS FINISH OFF the
  ## moment its root has exited. See the header for why the handoff is not
  ## deferred to the point where the scheduler reaps the action.
  ##
  ## Returns whether the slot is REAPABLE, which since TP-2 is no longer the
  ## same statement as "its root has exited": a handed-off monitor is neither
  ## polled again nor finished here, and becomes reapable when its outcome is
  ## drained.
  if slot < 0 or slot >= pool.records.len: return false
  if not pool.records[slot].inUse: return false
  if pool.records[slot].finished: return true
  if pool.records[slot].finishPending: return false
  var exited = false
  try:
    exited = pollMonitor(pool.handles[slot])
  except CatchableError as err:
    pool.records[slot].failure = "io-monitor poll failed: " & err.msg
    pool.records[slot].finished = true
    return true
  if not exited:
    return false
  handOffMonitorFinish(pool, slot, passStartedAtNs)
  if monitorFinishForcedSerial():
    # TP-3 arm 2 — see ``monitorFinishForcedSerial``. Reached once per hosted
    # action and only when the seam is armed.
    var named = awaitMonitorFinish(pool.records[slot].actionId)
    for outcome in named.mitems:
      applyMonitorFinishOutcome(pool, outcome)
    return pool.records[slot].finished
  false

proc awaitMonitorHostFinished(pool: var MonitorHostPool; slot: int) =
  ## Block until this slot's handed-off finish has come back, then fold it in.
  ##
  ## The scheduler does not normally reach this: it selects a hosted action
  ## only once ``records[slot].finished`` is set, which the poll loop's drain
  ## does. It exists for the two paths that do not go through the poll loop —
  ## reaping and abandonment — so neither can free a slot whose handle is
  ## living inside a pool job.
  if slot < 0 or slot >= pool.records.len: return
  if not pool.records[slot].inUse: return
  if not pool.records[slot].finishPending: return
  var named = awaitMonitorFinish(pool.records[slot].actionId)
  for outcome in named.mitems:
    applyMonitorFinishOutcome(pool, outcome)
  if pool.records[slot].finishPending:
    # The named outcome was not among what the wait returned. Fall back to the
    # whole-tenant drain, which is bounded by the same guard and cannot leave
    # the slot half-owned.
    var rest = awaitMonitorFinishes()
    for outcome in rest.mitems:
      applyMonitorFinishOutcome(pool, outcome)

proc readCapturedStdio(path: string; limit: int): string =
  ## Read back one of the in-process host's stdio captures, applying the same
  ## HEAD truncation RunQuota's process backend applies while draining a pipe
  ## (``runquota_process.appendBounded`` keeps the first ``limit`` bytes), and
  ## then REWRITE the file at that size.
  ##
  ## The rewrite is not tidiness. RunQuota's capture is bounded in MEMORY while
  ## the child runs — everything past the limit is drained and dropped — but a
  ## redirected descriptor has no such bound, so an action that writes gigabytes
  ## writes gigabytes into the cache root. Truncating on read bounds what
  ## SURVIVES the action to ``limit``; what it cannot bound is the peak, and
  ## that difference is a real one against the spawned form. A ``cacheRoot`` on
  ## a small filesystem plus a runaway monitored action is the shape to watch.
  if path.len == 0 or not fileExists(extendedPath(path)):
    return ""
  try:
    result = readFile(extendedPath(path))
  except CatchableError:
    return ""
  if limit > 0 and result.len > limit:
    result = result[0 ..< limit]
    try:
      writeFile(extendedPath(path), result)
    except CatchableError:
      discard

proc finishMonitorHostAction(pool: var MonitorHostPool; id: string; slot: int;
                             config: BuildEngineConfig;
                             cacheRoot: string;
                             hostedRecords: var seq[MonitorRecord]):
                             ActionResult =
  ## Turn a hosted monitor into the same ``ActionResult`` shape the direct
  ## RunQuota-bypass launch produces, including the historical per-action log
  ## files diagnostics and focused engine tests read.
  ##
  ## HM-5 — this is the seam where the action's outcome and its evidence go
  ## FORWARD and the ``.iomon`` goes SIDEWAYS. ``hostedRecords`` is moved out to
  ## the caller (a scheduler local it drops as soon as evidence is collected)
  ## and the publication is queued on the flush worker, so by the time this
  ## returns the scheduler owns everything it needs and the file has not
  ## necessarily landed.
  ##
  ## TP-2 — the finish itself already ran, on a pool worker, and its outcome
  ## was folded into the slot by the poll loop's drain. The wait below is
  ## therefore normally a no-op; it is here because the scheduler is not the
  ## only way a hosted action gets reaped, and a slot released while its
  ## handle is inside a pool job would be a use-after-free of the very handle
  ## LF-2 is about.
  awaitMonitorHostFinished(pool, slot)
  hostedRecords = @[]
  result = ActionResult(
    id: id,
    launched: true,
    runQuotaBackend: "runquota-bypass")
  if slot < 0 or slot >= pool.records.len:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = "in-process monitor host: no slot for " & id
    return
  # MOVE, never copy: a real ``nim c`` action's record set is ~97 000 records /
  # 18 MB, and ``let record = pool.records[slot]`` used to copy the whole
  # ``MonitorHostRecord``. Taking the records out first keeps that copy cheap
  # again and leaves the slot's own seq empty for ``releaseMonitorHostSlot``.
  hostedRecords = move(pool.records[slot].records)
  let record = pool.records[slot]
  # The flush is queued BEFORE the slot is released and before the caller
  # collects evidence. The job owns copies of both paths, so recycling this
  # slot into the next action — which the release below makes possible
  # immediately — cannot disturb a publication still in flight.
  #
  # NOT queued when the monitor itself faulted: ``finishMonitor`` raised, so
  # there is no canonical depfile at the scratch path to publish and queuing
  # one would report a flush failure for a fault that has already failed the
  # action on its own terms. The scratch file, if the fault left one, is
  # removed here rather than left to accumulate in the depfile directory.
  if record.depDestPath.len > 0 and record.failure.len == 0:
    enqueueMonitorFlush(MonitorFlushJob(
      actionId: id,
      tempPath: record.depTempPath,
      destPath: record.depDestPath))
  elif record.depTempPath.len > 0:
    try:
      removeFile(extendedPath(record.depTempPath))
    except CatchableError:
      discard
  # The handoff above normally leaves the handle dead, but not when
  # ``settleMonitorHost`` already marked the slot finished on a POLL failure —
  # that path never consumed it. ``releaseMonitorHostSlot`` is what closes that
  # gap; going through it is why this is not a bare record reset.
  releaseMonitorHostSlot(pool, slot)
  let capturedOut = readCapturedStdio(record.stdoutPath, config.stdoutLimit)
  let capturedErr = readCapturedStdio(record.stderrPath, config.stderrLimit)
  try:
    writeFile(extendedPath(bypassActionStdoutLogPath(cacheRoot, id)),
      capturedOut)
  except CatchableError:
    discard
  try:
    writeFile(extendedPath(bypassActionStderrLogPath(cacheRoot, id)),
      capturedErr)
  except CatchableError:
    discard
  result.stdout = stripMonitorBanner(capturedOut)
  result.stderr = stripMonitorBanner(capturedErr)
  if record.failure.len > 0:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = [result.stderr, record.failure].join("\n").strip()
  else:
    result.exitCode = record.exitCode
    result.status = if record.exitCode == 0: asSucceeded else: asFailed

proc abandonMonitorHost(pool: var MonitorHostPool; slot: int) =
  ## Tear a hosted monitor down on cancellation or shutdown. Kills the
  ## monitored root and drops the handle — see ``releaseMonitorHostSlot``,
  ## which owns that ordering and is the only place a slot is freed. This
  ## exists as a named call site so the scheduler's shutdown path reads the
  ## same as its helper-path neighbour, ``terminateRunningAction``.
  ##
  ## HM-5 — an abandoned action never reaches ``finishMonitorHostAction``, so
  ## its scratch depfile was never queued for publication and nothing else will
  ## ever look at it. Remove it here; a cancelled build must not leave the
  ## depfile directory growing dot-files nobody collects.
  ##
  ## TP-2 — a monitor whose finish is already on a worker is WAITED FOR rather
  ## than abandoned. It cannot be killed out from under the worker (the root
  ## has already exited; that is the precondition for the handoff) and its
  ## handle is not the scheduler's to drop any more, so the only honest
  ## teardown is to let the finish complete and fold its outcome in. That is
  ## also what keeps the scratch depfile removal below correct: the finish is
  ## what creates it.
  if slot < 0 or slot >= pool.records.len: return
  if not pool.records[slot].inUse: return
  awaitMonitorHostFinished(pool, slot)
  let temp = pool.records[slot].depTempPath
  if temp.len > 0:
    try:
      removeFile(extendedPath(temp))
    except CatchableError:
      discard
  releaseMonitorHostSlot(pool, slot)

proc startBypassRunQuotaProcess(action: BuildAction;
                                config: BuildEngineConfig):
    ReproDirectRunningProcess =
  ## Use RunQuota's native process backend without acquiring a lease. On
  ## Windows this preserves argument boundaries instead of expanding valid
  ## percent signs, carets, quotes, and backslashes through ``cmd.exe``.
  if action.argv.len == 0:
    raiseEngine("bypassRunQuota: action has empty argv: " & action.id)
  createDir(extendedPath(bypassActionLogDir(config.cacheRoot)))
  for path in [
      bypassActionStdoutLogPath(config.cacheRoot, action.id),
      bypassActionStderrLogPath(config.cacheRoot, action.id)]:
    try:
      writeFile(extendedPath(path), "")
    except CatchableError:
      discard
  return startDirect(preparedRunQuotaCommand(action, config))

proc startRunQuotaProcess(action: BuildAction; config: BuildEngineConfig;
                          resultPath: string): Process =
  let rq = ReproResourceRequest(
    label: action.id,
    commandStatsId: action.commandStatsId,
    cpuMilli: action.cpuMilli,
    memoryBytes: action.memoryBytes,
    namedPool: action.pool,
    namedPoolUnits: action.poolUnits)
  let command = preparedRunQuotaCommand(action, config)
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
  preparedRunQuotaCommand(action, config)

proc finishBypassRunQuotaProcess(id: string;
                                 process: var ReproDirectRunningProcess;
                                 cacheRoot: string): ActionResult =
  ## Finish the argv-preserving direct launch and retain the historical
  ## per-action log files used by diagnostics and focused engine tests.
  result = ActionResult(
    id: id,
    launched: true,
    runQuotaBackend: "runquota-bypass")
  try:
    let execution = process.finishCompleted()
    let stdoutPayload = stripMonitorBanner(execution.stdout)
    let stderrPayload = stripMonitorBanner(execution.stderr)
    try:
      writeFile(extendedPath(bypassActionStdoutLogPath(cacheRoot, id)),
        execution.stdout)
    except CatchableError:
      discard
    try:
      writeFile(extendedPath(bypassActionStderrLogPath(cacheRoot, id)),
        execution.stderr)
    except CatchableError:
      discard
    result.exitCode = execution.exitCode
    result.stdout = stdoutPayload
    result.stderr = stderrPayload
    result.status =
      if execution.exited and execution.exitCode == 0: asSucceeded
      else: asFailed
  except CatchableError as err:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = "direct process finish failed: " & err.msg

proc finishRunQuotaProcess(id: string; process: Process; resultPath: string;
                           cacheRoot: string): ActionResult =
  result = ActionResult(
    id: id,
    launched: true,
    runQuotaBackend: "runquota-helper")
  let helperExit = process.waitForExit()
  var helperOutput = ""
  if process.outputStream != nil:
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
    var node: JsonNode
    var attempts = 0
    while true:
      try:
        node = parseFile(extendedPath(resultPath))
        break
      except IOError as e:
        attempts += 1
        if attempts >= 20:
          raise e
        sleep(5)

    result.leaseId = node{"lease_id"}.getBiggestInt(0).uint64
    result.exitCode = node{"exit_code"}.getInt(1)
    result.stdout = node{"stdout"}.getStr("")
    result.stderr = stripMonitorBanner(node{"stderr"}.getStr(""))
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
    result.stderr = stripMonitorBanner(execution.stderr)
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

  MetadataFetchExecutor* = proc(action: BuildAction): ActionResult {.gcsafe.}
    ## Named-Lock-Files NLF-M5: hook installed by ``repro_lock_gen``. The
    ## engine routes every ``bakMetadataFetch`` action through the registered
    ## executor, which retrieves the object over the IN-PROCESS fetch path
    ## and writes it to the action's single output.
    ##
    ## Indirect dispatch is load-bearing here beyond the usual layering
    ## reason. The generation path needs the solver (to know what to fetch
    ## for) and the solver loads ``libclingo`` through a ``{.dynlib.}`` FFI at
    ## module-init; making the engine dispatch directly would give every
    ## engine binary a clingo runtime dependency, which
    ## ``repro_lock/identity.nim``'s header exists to prevent.

  SolveLockExecutor* = proc(action: BuildAction): ActionResult {.gcsafe.}
    ## Named-Lock-Files NLF-M5: hook installed by ``repro_lock_gen`` for the
    ## ``bakSolveLock`` rule-generator edge. The executor reads the metadata
    ## its upstream ``bakMetadataFetch`` edges retrieved, runs the solve, and
    ## writes the LOCK — the generated rule-set artifact — to the action's
    ## single output.

var workspaceVcsExecutor {.threadvar.}: WorkspaceVcsExecutor
var binaryCacheSubstituteExecutor {.threadvar.}: BinaryCacheSubstituteExecutor
var metadataFetchExecutor {.threadvar.}: MetadataFetchExecutor
var solveLockExecutor {.threadvar.}: SolveLockExecutor

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

proc registerMetadataFetchExecutor*(executor: MetadataFetchExecutor) =
  ## Register the per-thread executor for ``bakMetadataFetch`` actions
  ## (NLF-M5). ``repro_lock_gen`` calls this; tests that drive the generation
  ## path in-process call it explicitly.
  metadataFetchExecutor = executor

proc clearMetadataFetchExecutor*() =
  metadataFetchExecutor = nil

proc registerSolveLockExecutor*(executor: SolveLockExecutor) =
  ## Register the per-thread executor for the ``bakSolveLock`` rule-generator
  ## edge (NLF-M5).
  solveLockExecutor = executor

proc clearSolveLockExecutor*() =
  solveLockExecutor = nil

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

proc builtinCopyDestinationMatches(source, destination: string): bool =
  let sourcePath = extendedPath(source)
  let destinationPath = extendedPath(destination)
  if not fileExists(destinationPath) or
      not sameFileContent(sourcePath, destinationPath):
    return false
  when defined(posix):
    getFilePermissions(sourcePath) == getFilePermissions(destinationPath)
  else:
    true

const busyReplacedSuffix = ".repro-replaced-"
  ## Names a destination file that had to be renamed out of the way because a
  ## live process still had it mapped. Deliberately appended AFTER the original
  ## extension: a displaced ``libcrypto-3-x64.dll`` becomes
  ## ``libcrypto-3-x64.dll.repro-replaced-1234-0``, which no longer matches the
  ## ``*.dll`` sweep in ``stageHostDynlibsBesideBinary`` and so cannot be
  ## re-staged into a scratch tree as if it were a real library.

proc sweepBusyReplacedLeftovers(destination: string) =
  ## Best-effort reaping of ``<destination>.repro-replaced-*`` files.
  ##
  ## The rename in ``copyFileReplacingBusyDestination`` always succeeds, but the
  ## subsequent DELETE of the displaced file cannot: Windows refuses to unlink a
  ## file that is still mapped as an image, and during the very build that
  ## displaced it, it always is — the process holding it is that build's own
  ## driver. So the delete is retried here, at the start of the next staging
  ## attempt, by which time the holder has exited. This is the only place the
  ## leftovers ever get collected, so it must also run on the no-op path where
  ## the destination already matches and no copy happens at all.
  let dir = destination.splitPath.head
  let leaf = destination.extractFilename
  if dir.len == 0 or leaf.len == 0 or not dirExists(extendedPath(dir)):
    return
  # Prefix match over walkDir, NOT a ``walkFiles`` glob. ``walkFiles`` carries a
  # FindFirstFile workaround (std/private/osdirs.nim: "Windows bug/gotcha:
  # 't*.nim' matches 'tfoo.nims'") that treats everything after the last dot in
  # the PATTERN as an extension and then demands the match have an extension of
  # the same length. ``libcrypto-3-x64.dll.repro-replaced-*`` therefore matches
  # NOTHING — the sweep appears to run and silently reaps zero files forever.
  # Verified the hard way: the first cut of this used the glob and left the real
  # displaced DLLs sitting in build/bin across repeated green builds.
  let prefix = leaf & busyReplacedSuffix
  let dirExt = extendedPath(dir)
  for kind, entry in walkDir(dirExt, relative = true):
    if kind == pcFile and entry.startsWith(prefix):
      discard tryRemoveFile(dirExt / entry)

proc copyFileReplacingBusyDestination(source, destination: string) =
  ## ``copyFileWithPermissions``, but able to replace a destination that a live
  ## process still has open.
  ##
  ## Why this is needed at all: reprobuild stages its Windows runtime DLLs INTO
  ## the same ``build/bin`` tree its own binaries run from (see the B5 block in
  ## ``repro.nim``). Every one of those libraries is dlopen'd by leaf name, and
  ## Win32's LoadLibrary searches the running .exe's own directory FIRST — that
  ## co-location is the whole point of staging. The consequence is a genuine
  ## self-conflict: ``build/bin/repro.exe`` (and the workers it spawns, and any
  ## resident ``repro-daemon``) map ``build/bin/libcrypto-3-x64.dll``, and then
  ## the build graph that same process is executing tries to overwrite that file.
  ##
  ## In the steady state ``builtinCopyDestinationMatches`` makes this a no-op, so
  ## the conflict is invisible. It becomes a HARD WEDGE the moment the source
  ## content changes — an OpenSSL bump, a re-provisioned toolchain. From then on
  ## the copy is genuinely required, the destination is genuinely mapped, and the
  ## staging action fails on EVERY build, forever: the driver cannot release a
  ## library it needs in order to run. Stopping the daemon does not help, because
  ## the driver itself is a holder. That is not a race to narrow; it is a
  ## deadlock, and it must be broken rather than retried.
  ##
  ## The way out is a Windows asymmetry that is easy to miss: a mapped image
  ## cannot be OPENED for writing or DELETED, but it CAN be RENAMED. Renaming it
  ## aside leaves the holders running happily against the displaced file (Windows
  ## tracks the mapping, not the name) and frees the name for the new content.
  ## Note that plain write-to-temp-then-replace is NOT sufficient on its own:
  ## replacing still has to unlink the mapped destination, which fails exactly as
  ## the direct copy does. The rename is the load-bearing step.
  ##
  ## Sequenced as copy-to-temp, rename-away, rename-into-place so the destination
  ## flips from old content to new in a single atomic step. It is never absent
  ## and never partially written, which matters because concurrent workers are
  ## loading that very path while this runs.
  ##
  ## The fallback is entered only after a plain copy fails with a sharing error.
  ## That keeps the ordinary path — and all of POSIX — on exactly the code it
  ## was on before, and it is safe to attempt second because a failed copy of a
  ## mapped destination fails at the OPEN: it cannot have truncated anything.
  when not defined(windows):
    copyFileWithPermissions(extendedPath(source), extendedPath(destination))
  else:
    const
      errorAccessDenied = 5'i32
      errorSharingViolation = 32'i32
      errorUserMappedFile = 1224'i32

    sweepBusyReplacedLeftovers(destination)
    try:
      copyFileWithPermissions(extendedPath(source), extendedPath(destination))
      return
    except OSError as err:
      if err.errorCode notin
          [errorAccessDenied, errorSharingViolation, errorUserMappedFile] or
          not fileExists(extendedPath(destination)):
        # Not a busy destination — a missing source, a bad path, a full disk.
        # Renaming would only obscure the real diagnostic.
        raise

    let incoming = destination & ".repro-incoming-" & $getCurrentProcessId()
    discard tryRemoveFile(extendedPath(incoming))
    copyFileWithPermissions(extendedPath(source), extendedPath(incoming))

    # Pick a displaced name that is free. Leftovers from a still-running holder
    # can legitimately be sitting there, so this cannot assume attempt 0 is
    # available; the bound just refuses to spin forever on a pathological dir.
    var displaced = ""
    for attempt in 0 ..< 1024:
      let candidate = destination & busyReplacedSuffix &
        $getCurrentProcessId() & "-" & $attempt
      if not fileExists(extendedPath(candidate)):
        displaced = candidate
        break
    if displaced.len == 0:
      discard tryRemoveFile(extendedPath(incoming))
      raiseEngine("could not find a free name to displace a busy output: " &
        destination)

    try:
      moveFile(extendedPath(destination), extendedPath(displaced))
    except OSError:
      discard tryRemoveFile(extendedPath(incoming))
      raise
    try:
      moveFile(extendedPath(incoming), extendedPath(destination))
    except OSError:
      # The output must never be left missing: restore what we displaced before
      # surfacing the failure.
      moveFile(extendedPath(displaced), extendedPath(destination))
      discard tryRemoveFile(extendedPath(incoming))
      raise
    # Expected to fail while a holder still has the displaced image mapped; the
    # sweep above collects it on the next build.
    discard tryRemoveFile(extendedPath(displaced))

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

type
  NixDaemonCandidate* = object
    ## ONE PLACE ``bakForeignProvision`` WILL LOOK FOR
    ## ``reprobuild-nix-daemon``, carrying the label its refusal prints.
    path*: string
    label*: string

const NixDaemonRelativePaths*: array[4, string] = [
  # The dev tree's CHECKED-IN helper, relative to the REPOSITORY ROOT.
  "tools/reprobuild-nix-daemon/reprobuild-nix-daemon",
  # The dev tree's BUILT helper, relative to the REPOSITORY ROOT.
  "build/reprobuild-nix-daemon",
  # The flake's install layout: ``$out/libexec/reprobuild-nix-daemon``
  # (flake.nix installs it there and also exports
  # ``REPROBUILD_NIX_DAEMON_BIN``; this candidate is what answers when the
  # wrapper's environment did not survive).
  "libexec/reprobuild-nix-daemon",
  # The PACKAGED layout: ``<prefix>/libexec/<distribution>/reprobuild-nix-daemon``
  # -- see ``reprobuild_dist.nim``, which stages the helper under
  # ``libexec/<dist.name>``. The reprobuild distribution's name is
  # ``reprobuild``; a third distribution that renamed itself would need its
  # own entry, which is why the wrapper variable stays the primary route.
  "libexec/reprobuild/reprobuild-nix-daemon",
]

proc nixDaemonSearchRoots*(cwd, exePath, envSourceRoot: string): seq[
    tuple[root: string; label: string]] =
  ## THE ROOTS THE DAEMON SEARCH IS ANCHORED ON, AND WHY THERE ARE TWO
  ## EXE-DERIVED ONES RATHER THAN ONE.
  ##
  ## This used to be a single expression -- ``getAppFilename().parentDir.parentDir``
  ## -- justified as "the prefix for an installed ``<prefix>/bin/repro``".
  ## It is that. It is ALSO ``<root>/build`` for the dev tree's
  ## ``build/bin/repro``, and neither candidate built from ``<root>/build``
  ## exists: the helper lives at ``<root>/tools/reprobuild-nix-daemon/`` and
  ## the built one at ``<root>/build/reprobuild-nix-daemon``. So every dev-tree
  ## build whose ``action.cwd`` is not the repository root -- the packaging
  ## dogfood fixture, for one -- fell through the whole chain to a bare
  ## ``reprobuild-nix-daemon`` on ``PATH``, and the engine then reported
  ## ``No such file or directory / Additional info: reprobuild-nix-daemon``.
  ## That cost this campaign a pass and a wrong diagnosis (M1's N24/N28).
  ##
  ## THE EXECUTABLE IS NOT A RELIABLE ANCHOR AT ALL, and that is the part
  ## that took a measurement to learn rather than a reading. Almost every
  ## build in a dev tree is DAEMON-HOSTED, and the user daemon does not run
  ## the tree's binary: it runs a STAGED COPY of it under
  ## ``~/.local/state/repro/daemon/dev-bin/dev-start-<generation>/repro-daemon``
  ## (``repro daemon status`` prints both as ``source-image-path`` and
  ## ``running-image-path``). So inside the engine ``getAppFilename()``
  ## answers a path in the state directory, whose ancestors contain no
  ## reprobuild checkout at all -- and an exe-anchored fix alone still
  ## resolves nothing. Measured: with the exe anchors in place and no cwd
  ## walk, the Linux dogfood build failed IDENTICALLY.
  ##
  ## So the primary anchor is ``action.cwd`` AND ITS ANCESTORS. The build's
  ## own directory is inside the tree that owns the helper, whatever process
  ## is hosting the engine and wherever that process's image was staged.
  ## Eight levels, which is the same walk ``repro_cli_support`` already does
  ## to find a sibling ``runquotad``.
  ##
  ## The executable's grandparent (an install prefix) and great-grandparent
  ## (the repository root when the binary IS the tree's own
  ## ``build/bin/repro``) are kept AFTER it: they are right for an installed
  ## layout and for a direct non-daemon run, and every candidate has to EXIST
  ## on disk, so an extra root adds reach and not risk.
  ##
  ## ``REPROBUILD_SOURCE_ROOT`` stays FIRST when it is set -- it is an
  ## explicit statement of the source root, exported by codetracer's
  ## build-once.sh and forwarded by the daemon -- but it no longer SUPPRESSES
  ## everything else, because a wrong or stale value used to turn an explicit
  ## hint into a silent dead end.
  ##
  ## Filesystem roots are dropped: ``/usr/bin/repro``'s great-grandparent is
  ## ``/``, and ``/tools/...`` is not a layout, it is noise in the refusal.
  var seen = initHashSet[string]()
  # A TEMPLATE rather than a nested proc: `result` is a seq and Nim refuses
  # to let a closure capture it.
  template consider(rootExpr, labelExpr: string) =
    block:
      let root = rootExpr
      # `parentDir` never leaves a trailing separator, so the raw string is
      # already the dedupe key; normalising it here is what put a stray
      # character literal in this file once.
      if root.len > 0 and not isRootDir(root) and
          not seen.containsOrIncl(root):
        result.add((root: root, label: labelExpr))
  consider(envSourceRoot, "REPROBUILD_SOURCE_ROOT")
  if cwd.len > 0:
    var dir = cwd
    for _ in 0 .. 8:
      consider(dir, "cwd-ancestor")
      let parent = dir.parentDir
      if parent.len == 0 or parent == dir:
        break
      dir = parent
  if exePath.len > 0:
    consider(exePath.parentDir.parentDir, "app-prefix")
    consider(exePath.parentDir.parentDir.parentDir, "app-repo-root")

proc nixDaemonCandidates*(cwd, exePath, envSourceRoot: string): seq[
    NixDaemonCandidate] =
  ## THE FULL, ORDERED CANDIDATE LIST -- pure, so it can be pinned by a test
  ## without a daemon, a socket or a build.
  ##
  ## The first three entries are the historical ``action.cwd``-relative ones
  ## and keep their historical labels and their historical ORDER; everything
  ## after them is the root x relative-path product from
  ## ``nixDaemonSearchRoots`` and ``NixDaemonRelativePaths``.
  var seen = initHashSet[string]()
  template consider(pathExpr, labelExpr: string) =
    block:
      let path = pathExpr
      if path.len > 0 and not seen.containsOrIncl(path):
        result.add(NixDaemonCandidate(path: path, label: labelExpr))
  if cwd.len > 0:
    consider(cwd / "build" / "reprobuild-nix-daemon",
      "local reprobuild-nix-daemon")
    consider(cwd / "tools" / "reprobuild-nix-daemon" /
      "reprobuild-nix-daemon", "local tools reprobuild-nix-daemon")
    consider(cwd.parentDir / "reprobuild-nix-daemon" / "build" /
      "reprobuild-nix-daemon", "sibling reprobuild-nix-daemon")
  for entry in nixDaemonSearchRoots(cwd, exePath, envSourceRoot):
    for rel in NixDaemonRelativePaths:
      consider(entry.root / rel, entry.label & " " & rel)

proc nixDaemonExecutableFile*(path: string): bool =
  ## Exists AND is executable. On Windows the executable bit is not a thing
  ## the filesystem answers, so existence is the whole test.
  if path.len == 0 or not fileExists(path):
    return false
  when defined(posix):
    let perms = getFilePermissions(path)
    result = fpUserExec in perms or fpGroupExec in perms or
      fpOthersExec in perms
  else:
    result = true

proc shebangInterpreter*(firstLine: string): string =
  ## The ABSOLUTE interpreter path a ``#!`` line names, or ``""``.
  ##
  ## Pure, and split out from the file check below so the parsing has a
  ## test that needs no filesystem. Only an absolute path is answered:
  ## ``#!/usr/bin/env python3`` names ``/usr/bin/env``, which is what
  ## the kernel actually execs, and a relative or empty shebang is not
  ## something this predicate is entitled to have an opinion about.
  if not firstLine.startsWith("#!"):
    return ""
  var rest = firstLine[2 .. ^1]
  rest = rest.strip()
  if rest.len == 0 or rest[0] != '/':
    return ""
  let sp = rest.find({' ', '\t'})
  if sp >= 0: rest[0 ..< sp] else: rest

proc unresolvableScriptInterpreter*(path: string): string =
  ## If ``path`` is a script whose ``#!`` names an absolute interpreter
  ## that is NOT on this host, answer that interpreter; otherwise ``""``.
  ##
  ## WHY THE ENGINE CHECKS THIS AT ALL (M1's N33). Every Linux package
  ## shipped ``libexec/reprobuild/reprobuild-nix-daemon`` with a
  ## ``/nix/store/...`` shebang, and this resolver accepted it: the file
  ## exists, the file is 0755, so the override was honoured and the
  ## process died in ``execve`` with ``ENOENT`` -- reported by
  ## ``startProcess`` as a failure to spawn, then by the caller as
  ## "Failed to connect or spawn reprobuild-nix-daemon at <socket>",
  ## which is the EXACT opaque failure ``flake.nix``'s comment says the
  ## interpreter substitution was introduced to fix. ``ENOENT`` for a
  ## missing interpreter is indistinguishable from ``ENOENT`` for a
  ## missing image unless something looks at the first line, so this
  ## looks at the first line.
  ##
  ## The packaging layer is where this is FIXED
  ## (``DistComponent.scriptInterpreter``); this is where it is
  ## DIAGNOSED, which is a different job: the engine also runs against a
  ## source checkout, a Nix profile and a hand-set
  ## ``REPROBUILD_NIX_DAEMON_BIN``, none of which the packaging layer
  ## ever touches.
  # WINDOWS HAS NO SHEBANG MECHANISM: its loader does not read the
  # first line of a file, so a `#!` there is a comment and a refusal
  # built on it would refuse correct helpers. Answered "" by
  # construction rather than left to the parser to get right by
  # accident.
  when not defined(posix):
    return ""
  if path.len == 0 or not fileExists(path):
    return ""
  var first = ""
  # ``f.open(...)`` rather than ``open(path)``: this module also imports
  # ``repro_local_store``, whose sqlite binding exports an ``open(path:
  # string, ...)``, and the bare call is AMBIGUOUS -- the nix build
  # refused it before it refused anything else.
  var f: File
  if not f.open(path, fmRead):
    return ""
  try:
    # A binary is not a script and must not be misread as one: the
    # first "line" of an ELF image is whatever precedes the first
    # newline, and it does not start with ``#!``.
    discard f.readLine(first)
  except CatchableError:
    first = ""
  finally:
    f.close()
  let interp = shebangInterpreter(first)
  if interp.len > 0 and not fileExists(interp): interp else: ""

proc resolveNixDaemonExecutable*(cwd, exePath, envSourceRoot,
    envBin: string): string =
  ## RESOLVE ``reprobuild-nix-daemon``, or answer the bare name so that
  ## ``poUsePath`` gets its turn.
  ##
  ## ``REPROBUILD_NIX_DAEMON_BIN`` is the documented override and is a HARD
  ## error when it names something that is not there -- an override that
  ## silently falls back is an override nobody can debug.
  if envBin.len > 0:
    if not fileExists(envBin):
      raiseEngine("REPROBUILD_NIX_DAEMON_BIN does not exist: " & envBin)
    if not nixDaemonExecutableFile(envBin):
      raiseEngine("REPROBUILD_NIX_DAEMON_BIN exists but is not executable: " &
        envBin)
    # EXISTS AND IS EXECUTABLE IS NOT ENOUGH, and believing it was is
    # what let a package ship a file that could not run. See
    # ``unresolvableScriptInterpreter``.
    let missing = unresolvableScriptInterpreter(envBin)
    if missing.len > 0:
      raiseEngine("REPROBUILD_NIX_DAEMON_BIN is a script whose #! " &
        "interpreter is not on this host: " & envBin & " names " & missing &
        "; execve answers ENOENT for a missing interpreter exactly as it " &
        "does for a missing image, so this would have surfaced only as a " &
        "failure to spawn the daemon")
    return envBin
  for candidate in nixDaemonCandidates(cwd, exePath, envSourceRoot):
    if not fileExists(candidate.path):
      continue
    if not nixDaemonExecutableFile(candidate.path):
      raiseEngine(candidate.label & " exists but is not executable: " &
        candidate.path)
    let missing = unresolvableScriptInterpreter(candidate.path)
    if missing.len > 0:
      raiseEngine(candidate.label & " is a script whose #! interpreter is " &
        "not on this host: " & candidate.path & " names " & missing)
    return candidate.path
  "reprobuild-nix-daemon"

proc executeBuiltinAction*(action: BuildAction): ActionResult =
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
      let destinationMatches =
        builtinCopyDestinationMatches(source, destination)
      if destinationMatches:
        # The no-op path is the ONLY moment a wedged staging action ever gets
        # back to steady state, so it is also where the displaced files from an
        # earlier busy replacement finally become deletable. See
        # ``sweepBusyReplacedLeftovers``.
        when defined(windows):
          sweepBusyReplacedLeftovers(destination)
      else:
        createDir(extendedPath(destination.splitPath.head))
        prepareBuiltinFileOutput(destination)
        # Preserve the source file's mode bits — plain ``copyFile`` creates the
        # destination with the process umask default (typically 0644), which
        # silently drops the executable bit. CodeTracer's recipe copies the
        # cargo-built ``replay-server`` / ``session-manager`` binaries through
        # this action; without the exec bit they fail to launch (exit 126).
        copyFileReplacingBusyDestination(source, destination)
    of bakEnsureDir:
      if action.outputs.len != 1:
        raiseEngine("ensureDir action requires exactly one output: " & action.id)
      createDir(extendedPath(action.builtinPath(action.outputs[0])))
    of bakWriteText:
      if action.outputs.len != 1:
        raiseEngine("writeText action requires exactly one output: " & action.id)
      let destination = action.builtinPath(action.outputs[0])
      let destExt = extendedPath(destination)
      let text = action.builtinText
      if fileExists(destExt) and readFile(destExt) == text:
        discard
      else:
        createDir(extendedPath(destination.splitPath.head))
        prepareBuiltinFileOutput(destination)
        writeFile(destExt, text)
    of bakEnsureLine:
      if action.outputs.len != 1:
        raiseEngine("ensureLine action requires exactly one output: " & action.id)
      let destination = action.builtinPath(action.outputs[0])
      let destExt = extendedPath(destination)
      let lineToEnsure = action.builtinText
      var content = ""
      var linesList: seq[string] = @[]
      if fileExists(destExt):
        content = readFile(destExt)
        linesList = content.splitLines()
      var found = false
      let lineToEnsureStrip = lineToEnsure.strip()
      for l in linesList:
        if l.strip() == lineToEnsureStrip:
          found = true
          break
      if not found:
        createDir(destExt.splitPath.head)
        prepareBuiltinFileOutput(destination)
        var newContent = content
        if newContent.len > 0 and not newContent.endsWith("\n") and not newContent.endsWith("\r"):
          newContent.add("\n")
        newContent.add(lineToEnsure)
        newContent.add("\n")
        writeFile(destExt, newContent)
    of bakEnsureSnippet:
      if action.outputs.len != 1:
        raiseEngine("ensureSnippet action requires exactly one output: " & action.id)
      if action.builtinEntries.len < 5:
        raiseEngine("ensureSnippet action requires openSentinel, closeSentinel, openSearch, closeSearch, and snippet")
      let destination = action.builtinPath(action.outputs[0])
      let destExt = extendedPath(destination)
      let openSentinel = action.builtinEntries[0]
      let closeSentinel = action.builtinEntries[1]
      let openSearch = action.builtinEntries[2]
      let closeSearch = action.builtinEntries[3]
      let snippet = action.builtinEntries[4]
      var content = ""
      if fileExists(destExt):
        content = readFile(destExt)
      let newBlock = openSentinel & "\n" & snippet & "\n" & closeSentinel
      var startIdx = -1
      var endIdx = -1
      let linesList = content.splitLines()
      for i, l in linesList:
        if l.strip().startsWith(openSearch):
          startIdx = i
        elif l.strip().startsWith(closeSearch) and startIdx != -1:
          endIdx = i
          break
      var newLinesList: seq[string] = @[]
      if startIdx != -1 and endIdx != -1:
        for i in 0 ..< startIdx:
          newLinesList.add(linesList[i])
        newLinesList.add(newBlock)
        for i in (endIdx + 1) ..< linesList.len:
          newLinesList.add(linesList[i])
      else:
        newLinesList = linesList
        if newLinesList.len > 0 and newLinesList[^1].strip().len > 0:
          newLinesList.add("")
        newLinesList.add(newBlock)
      let newContent = newLinesList.join("\n") & "\n"
      if content != newContent:
        createDir(destExt.splitPath.head)
        prepareBuiltinFileOutput(destination)
        writeFile(destExt, newContent)
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
          # may contain executables. It mirrors DLLs too, and unlike bakCopyFile
          # it has no identical-destination guard, so it re-copies every build —
          # which makes the busy-destination hazard strictly worse here.
          copyFileReplacingBusyDestination(source, destination)
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
    of bakMetadataFetch:
      # NLF-M5 dispatch. Fail CLOSED when nothing is registered: a
      # metadata-fetch edge that quietly no-ops would leave the solve edge
      # downstream of it reading an empty version universe and reporting a
      # lock, which is the silent-wrong-answer direction.
      if metadataFetchExecutor.isNil:
        raiseEngine(
          "bakMetadataFetch action requires registerMetadataFetchExecutor " &
          "before runBuild: " & action.id)
      let mdRes = metadataFetchExecutor(action)
      result.status = mdRes.status
      result.exitCode = mdRes.exitCode
      result.stdout = mdRes.stdout
      result.stderr = mdRes.stderr
      result.reason = mdRes.reason
      result.launched = mdRes.launched
      result.runQuotaBackend = if mdRes.runQuotaBackend.len > 0:
        mdRes.runQuotaBackend else: "metadata-fetch"
      return
    of bakSolveLock:
      if solveLockExecutor.isNil:
        raiseEngine(
          "bakSolveLock action requires registerSolveLockExecutor before " &
          "runBuild: " & action.id)
      let solveRes = solveLockExecutor(action)
      result.status = solveRes.status
      result.exitCode = solveRes.exitCode
      result.stdout = solveRes.stdout
      result.stderr = solveRes.stderr
      result.reason = solveRes.reason
      result.launched = solveRes.launched
      result.runQuotaBackend = if solveRes.runQuotaBackend.len > 0:
        solveRes.runQuotaBackend else: "solve-lock"
      return
    of bakForeignProvision:
      when defined(windows):
        raiseEngine("bakForeignProvision is not supported on Windows")
      else:
        # Nix evaluation daemon or scoop provisioning action
        let provisioner = if action.argv.len > 0: action.argv[0] else: ""
        let selector = if action.argv.len > 1: action.argv[1] else: ""
        if provisioner.len == 0 or selector.len == 0:
          raiseEngine("bakForeignProvision action requires provisioner and selector in argv: " & action.id)
        if action.outputs.len != 1:
          raiseEngine("bakForeignProvision action requires exactly one output receipt: " & action.id)
        
        let receiptPath = action.builtinPath(action.outputs[0])
        if provisioner != "nix":
          raiseEngine("Unsupported provisioner: " & provisioner)
        
        let socketPath = "/tmp/reprobuild-nix-daemon-" & getEnv("USER", "default") & ".sock"
        var sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
        var connected = false
        try:
          sock.connectUnix(socketPath)
          connected = true
        except CatchableError:
          # Spawn daemon process detached.
          #
          # THE CANDIDATE LIST IS A PURE FUNCTION -- `nixDaemonCandidates` --
          # so that the resolution order is pinned by a test rather than by
          # this `elif` chain. It anchors on `action.cwd` (three historical
          # candidates, for a build run from the reprobuild tree itself), on
          # `REPROBUILD_SOURCE_ROOT` when set, and on BOTH the executable's
          # grandparent (an install prefix) and its great-grandparent (a dev
          # tree's repository root, where `repro` sits two levels down at
          # `build/bin/repro`). The single grandparent anchor this replaces
          # resolved NEITHER layout's real location and fell through to a
          # bare name on PATH -- M1's N24/N28.
          let daemonExe = resolveNixDaemonExecutable(
            cwd = action.cwd,
            exePath = getAppFilename(),
            envSourceRoot = getEnv("REPROBUILD_SOURCE_ROOT"),
            envBin = getEnv("REPROBUILD_NIX_DAEMON_BIN"))
          discard startProcess(daemonExe, args = ["--idle-exit-ms=300000"],
            options = {poDaemon, poUsePath})
          for i in 0 .. 40:
            sleep(50)
            try:
              sock = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM, protocol = IPPROTO_IP)
              sock.connectUnix(socketPath)
              connected = true
              break
            except CatchableError:
              discard
        if not connected:
          raiseEngine("Failed to connect or spawn reprobuild-nix-daemon at " & socketPath)
        
        let req = %*{
          "action": "resolve",
          "selector": selector,
          "workspaceRoot": action.cwd
        }
        sock.send($req & "\n")
        var respLine = ""
        sock.readLine(respLine)
        sock.close()
        
        if respLine.len == 0:
          raiseEngine("Received empty response from reprobuild-nix-daemon")
        
        let resp = parseJson(respLine)
        if resp.getOrDefault("status").getStr() != "success":
          raiseEngine("Daemon resolution error: " & resp.getOrDefault("error").getStr())
        
        let paths = resp.getOrDefault("paths")
        if paths.len == 0:
          raiseEngine("Daemon returned no materialized paths for selector: " & selector)
        
        let outPath = paths[0].getStr()
        createDir(extendedPath(receiptPath.splitPath.head))
        prepareBuiltinFileOutput(receiptPath)
        writeFile(extendedPath(receiptPath), outPath)
        
        var observedReads: seq[string] = @[]
        if resp.hasKey("dependencies"):
          for depNode in resp["dependencies"]:
            let depPath = depNode.getOrDefault("path").getStr()
            if depPath.len > 0:
              observedReads.add(relativePath(depPath, action.cwd))
              
        result.status = asSucceeded
        result.exitCode = 0
        result.evidence = PathSetEvidence(
          declaredInputs: action.inputs,
          declaredOutputs: action.outputs,
          monitorReads: observedReads
        )
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
  # The action cache is now the per-edge disk store (no global append-log).
  # An `ActionCache` holds no in-memory record snapshot — every lookup reads
  # the current `hot-records/<key>` file straight from disk — so a warmed
  # handle can never go stale against on-disk writes. We key the warm entry
  # on the `hot-records` directory's own metadata purely to reuse the handle
  # (and its `createDir` work) for the same root within a process.
  durableEvidence(root / "hot-records")

proc warmActionCacheFor(root: string; attachShm = true): WarmActionCache =
  let key = root & "\0" & (if attachShm: "shm" else: "disk")
  let evidence = actionCacheDurableEvidence(root)
  if processWarmActionCaches.hasKey(key):
    let warm = processWarmActionCaches[key]
    if warm.evidence == evidence:
      return warm
  result = WarmActionCache(
    cache: openActionCache(root, attachShm = attachShm),
    evidence: evidence)
  processWarmActionCaches[key] = result

proc publishMaterializedBinaryCacheEntries*(g: BuildGraph;
    publisher: BinaryCachePublisher): BuildRunResult =
  ## Publish tagged public-interface roots that are already materialized,
  ## without scheduling or launching build actions. This is an explicit
  ## operator backfill path: graph identities still select the cache keys,
  ## while the existing filesystem trees provide the payloads.
  for action in g.actions:
    if not action.publishToBinaryCache or action.cacheEntryIdentity.isNone:
      continue
    var item = ActionResult(
      id: action.id,
      status: asFailed,
      cacheDecision: cdNotCacheable,
      reason: "materialized-binary-cache-identity-incomplete")
    let identityError = actionCacheIdentityError(action)
    if identityError.len > 0:
      item.exitCode = 1
      item.stderr = identityError
      result.results.add(item)
      continue
    item.reason = "materialized-binary-cache-publish key=" &
      deriveActionCacheKeyHex(action)
    let prefix =
      if action.declaredOutputs.len == 1:
        action.declaredOutputs[0]
      elif action.outputs.len > 0:
        action.outputs[0]
      else:
        ""
    if publisher == nil:
      item.stderr = "binary-cache publisher is not configured"
      result.results.add(item)
      continue
    if not action.allOutputsExist():
      item.stderr =
        "materialized binary-cache action outputs are incomplete: " &
        (if action.outputs.len > 0: action.outputs.join(", ") else: "<none>")
      result.results.add(item)
      continue
    if prefix.len == 0 or
        (not fileExists(prefix) and not dirExists(prefix)):
      item.stderr = "materialized binary-cache prefix does not exist: " &
        (if prefix.len > 0: prefix else: "<empty>")
      result.results.add(item)
      continue
    var identity = action.cacheEntryIdentity.get()
    let platformTag =
      if action.cachePlatformTag.len == 0: NativeTriple
      else: action.cachePlatformTag
    identity.addOption(CachePlatformTagOptionKey, platformTag)
    let request = BinaryCachePublishRequest(
      actionId: action.id,
      weakFingerprint: action.weakFingerprint,
      identity: identity,
      cwd: action.cwd,
      publishPrefix: prefix,
      declaredOutputs: action.outputs,
      recordOutputs: @[])
    let publishResult =
      try: publisher(request)
      except CatchableError as e:
        BinaryCachePublishResult(
          ok: false,
          statusCode: 0,
          error: "binary-cache publisher raised: " & e.msg)
    if publishResult.ok:
      item.status = asUpToDate
      item.reason = "materialized-binary-cache-published key=" &
        deriveActionCacheKeyHex(action)
    else:
      item.exitCode = publishResult.statusCode
      item.stderr = publishResult.error
    result.results.add(item)
  if result.results.len == 0:
    result.results.add(ActionResult(
      id: "binary-cache-materialized",
      status: asFailed,
      cacheDecision: cdNotCacheable,
      reason: "materialized-binary-cache-no-entries",
      stderr: "no tagged materialized binary-cache entries in selected graph"))

# ---------------------------------------------------------------------------
# ``ext_repro_action`` (M17)
# ---------------------------------------------------------------------------

proc actionKindName(kind: BuildActionKind): string =
  ($kind).replace("bak", "").toLowerAscii()

proc measuredOutputBytes(action: BuildAction): int64 =
  ## Total size of the action's declared outputs, MEASURED after the
  ## action settled. Missing outputs contribute nothing rather than
  ## failing the row: an observation must never fail the work.
  for output in action.outputs:
    let path =
      if output.isAbsolute or action.cwd.len == 0: output
      else: action.cwd / output
    try:
      if fileExists(extendedPath(path)):
        result += int64(getFileSize(extendedPath(path)))
    except CatchableError:
      discard

proc emitActionExtensionRows(session: ReproRunQuotaSession;
                             runResult: BuildRunResult;
                             actionsById: Table[string, BuildAction]) =
  ## One ``ext_repro_action`` row per execution RunQuota admitted.
  ##
  ## ROWS EXIST FOR EXECUTIONS, NOT FOR ACTIONS, and the difference is
  ## not a shortcut. RunQuota's spine records executions; a cache HIT is
  ## precisely the case where nothing executed, so there is no spine row
  ## for an extension row to be joined to. What the rows therefore carry
  ## is the cache decision that LED TO a launch -- miss, refused,
  ## not-cacheable, hybrid cutoff -- together with the reason, which is
  ## the "why did this rebuild" question the store exists to answer.
  ## A reader counting hits from this table alone would undercount them,
  ## and ``docs/stats.md`` says so where a reader will find it.
  ##
  ## BEST EFFORT, ALWAYS. Nothing here may fail a build (OS-4), and
  ## nothing here may block it (OS-1): the declaration is one round trip
  ## made once per build after every action has settled, and each row is
  ## a single buffered write with no reply.
  if session.isNil or not session.active:
    return
  var declared = false
  for item in runResult.results:
    if not item.launched or item.leaseId == 0:
      continue
    if item.id notin actionsById:
      continue
    let action = actionsById[item.id]
    if not declared:
      # Declared lazily: a build that admitted nothing should not create
      # a table for rows it will never write.
      let refusal = session.declareRunQuotaExtension(
        ReproActionExtensionId, ReproActionExtensionOwner,
        ReproActionSchemaVersion, reproActionMigrations())
      if refusal.len > 0:
        return
      declared = true
    let toolIdentity = action.toolIdentityRefs.join(",")
    let toolKind =
      if action.toolIdentityRefs.len > 0: action.toolIdentityRefs[0]
      else: ""
    let cacheOutcome =
      case item.cacheDecision
      of cdNotCacheable: racNotCacheable
      of cdMiss: racMiss
      of cdHit: racHit
      of cdHybridCutoff: racHybridCutoff
      of cdRejected: racRefused
    let compatibility = compatibilityKey(
      actionKindName(action.kind), action.commandStatsId, toolKind,
      toolIdentity, action.argv, action.outputs)
    session.recordRunQuotaExtensionRow(
      item.leaseId, ReproActionExtensionId, ReproActionSchemaVersion,
      reproActionColumns(),
      @[
        extText(item.id),
        extText(actionKindName(action.kind)),
        extText(compatibility),
        extText($cacheOutcome),
        (if item.cacheMissReason.len > 0: extText(item.cacheMissReason)
         else: extNull()),
        extText(toHex(action.weakFingerprint.bytes)),
        (if item.strongFingerprintHex.len > 0:
           extText(item.strongFingerprintHex)
         else: extNull()),
        (if action.pool.len > 0: extText(action.pool) else: extNull()),
        extInt(int64(action.poolUnits)),
        extInt(measuredOutputBytes(action)),
        # SUBSTITUTION IS A PROPERTY OF THE ACTION KIND, not a flag some
        # other code path has to remember to set. The one launched form
        # of substitution is the binary-cache substitute edge; a
        # peer-cache install settles as a HIT and therefore has no
        # execution row at all, so a boolean on the result would have
        # been false on every row that exists.
        extInt(if action.kind == bakBinaryCacheSubstitute: 1'i64 else: 0'i64),
        (if toolKind.len > 0: extText(toolKind) else: extNull()),
        (if toolIdentity.len > 0: extText(toolIdentity) else: extNull()),
        extInt(int64(item.evidence.declaredInputs.len)),
        extInt(int64(item.evidence.declaredOutputs.len)),
        extInt(int64(item.evidence.depfileInputs.len)),
        extInt(int64(item.evidence.monitorReads.len)),
        extInt(int64(item.evidence.monitorWrites.len)),
        extInt(int64(item.evidence.monitorProbes.len))
      ])

proc runBuild*(g: BuildGraph; config: BuildEngineConfig): BuildRunResult =
  # Process-global accumulators; zero them so this build reports its own cost
  # rather than its own plus every earlier build in this process.
  resetOutputStateCheckStats()
  var stats: BuildStats
  proc statStart(): float =
    if config.statsEnabled:
      epochTime()
    else:
      0.0
  proc finishStat(name: string; started: float) =
    if config.statsEnabled:
      stats.addMetric(name, (epochTime() - started) * 1_000_000.0)

  proc finishOutputStateCheckStats() =
    ## Emit the TOTAL cost of output revalidation, counted inside
    ## `outputStateMismatch` itself so it covers all three call sites (the
    ## whole-build fast-noop scan and the two per-edge paths inside
    ## repro_local_store) rather than the one that happens to sit in this
    ## file. `dir walk` / `dir entries` make the O(tree-entries) cost of a
    ## directory output visible instead of hidden inside the total.
    if not config.statsEnabled:
      return
    let osc = outputStateCheckStats()
    # count == calls and totalUs == the summed cost, so a per-call average is
    # meaningful. Emitting one sample carrying the cumulative total (count=1)
    # made every average wrong by a factor of `calls`.
    stats.addCountedMetric("repro output revalidate", osc.calls,
      float(osc.nanos) / 1000.0)
    stats.addCounterMetric("repro output revalidate dir walks",
      osc.revalidateDirWalks)
    stats.addCounterMetric("repro output revalidate dir entries",
      int(osc.revalidateDirEntries))
    # Recording a directory output walks its tree too. That is EXECUTION cost,
    # not revalidation cost, and keeping it in its own counter is what makes a
    # cold build report zero revalidation walks.
    stats.addCounterMetric("repro output record dir walks", osc.recordDirWalks)
    stats.addCounterMetric("repro output record dir entries",
      int(osc.recordDirEntries))
    # The byte-scaled half of the cost model, beside the count-scaled half
    # above. Caching-Architecture.md §"Known Limit: The Default Policy Can
    # Serve A Stale Result" is a claim about which of the two a consultation
    # pays; without these rows the claim is
    # unobservable, and a warm no-op that quietly started hashing artifacts
    # would look identical to one that did not. Zero rows are not rendered,
    # so on the default local build they cost a reader nothing.
    #
    # `addCountedMetric`, not `addCounterMetric`: the latter appends one
    # sample per unit, and the byte figure is measured in millions.
    let ccd = casContentDigestStats()
    stats.addCountedMetric("repro cas content digest", ccd.calls, 0.0)
    stats.addCountedMetric("repro cas content digest bytes",
      int(ccd.bytes), 0.0)
    # Action-Cache-Per-Edge-Store.md §5.5. C1's whole claim is that a
    # consultation decodes the ONE candidate it evaluates rather than every
    # candidate the edge has, and C4's is that each decoded record is smaller.
    # Both are counts of work performed, so both are visible under ambient
    # load, which a wall-clock row on a shared machine is not.
    let ard = actionRecordDecodeStats()
    stats.addCountedMetric("repro action record decode", ard.records, 0.0)
    stats.addCountedMetric("repro action record decode bytes",
      int(ard.bytes), 0.0)
    stats.addCountedMetric("repro per-edge container read",
      ard.containerReads, 0.0)
    stats.addCountedMetric("repro per-edge sidecar read",
      ard.sidecarReads, 0.0)
    # Action-Cache-Per-Edge-Store.md §11. The Tier-2 index is an ACCELERATOR
    # and fails silently by design, which is exactly why its health has to be
    # legible: a silently bypassed accelerator is indistinguishable from a
    # healthy idle one. `growthFailed` says the chain is saturated and every
    # completeness claim is void; `unresolvedReferences` says Tier-1 retention
    # and index retirement have drifted apart; `bypassWrites` says something
    # wrote Tier 1 without telling the index. On a healthy root all three are
    # zero, and a zero row is not rendered, so a working tier costs a reader
    # nothing.
    #
    # The row this replaces counted records REFUSED for their size. That
    # admission decision no longer exists: the index holds 84-byte references,
    # so a record's size never enters it, and there is nothing left to refuse.
    let aix = actionIndexStats()
    stats.addCountedMetric("repro action index negative hit",
      aix.negativeHits, 0.0)
    stats.addCountedMetric("repro action index resolved hit",
      aix.resolvedHits, 0.0)
    stats.addCountedMetric("repro action index union fallback",
      aix.unionFallbacks, 0.0)
    stats.addCountedMetric("repro action index unresolved reference",
      aix.unresolvedReferences, 0.0)

  proc finishMetadataCacheStats(cache: FileMetadataCache) =
    if not config.statsEnabled:
      return
    finishOutputStateCheckStats()
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
  # STAGE 2 census — count, do not change. Taken over the graph as it
  # will actually be scheduled, after dependency inference, so the number
  # describes the build that runs rather than the graph as authored.
  for censusAction in buildGraph.actions:
    if censusAction.kind != bakProcess:
      # Built-in actions do not fork, so they have no environment to
      # inherit and do not belong in this denominator.
      continue
    inc runResult.environmentInheritance.totalActions
    if censusAction.env.len > 0:
      inc runResult.environmentInheritance.declaringActions
    if censusAction.envPassthrough.len > 0:
      inc runResult.environmentInheritance.passthroughActions
    if censusAction.env.len == 0 and censusAction.envPassthrough.len == 0:
      inc runResult.environmentInheritance.undeclaredActions
    case classifyActionPath(censusAction)
    of apdHermetic: inc runResult.environmentInheritance.hermeticPathActions
    of apdInherited: inc runResult.environmentInheritance.inheritedPathActions
    of apdEmpty: inc runResult.environmentInheritance.emptyPathActions
    of apdAbsent: discard
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
  # back to `cacheRoot` so the single-root layout still works. Only the
  # explicit shared root attaches the shm hot tier: local/workspace scratch
  # roots must stay fully synchronous Tier-1 stores so no detached cache daemon
  # can outlive the command and write back into a directory the caller is
  # immediately deleting.
  let sharedRoot = if config.actionCacheRoot.len > 0:
      config.actionCacheRoot
    else:
      cacheRoot
  let casOpenStart = statStart()
  var cas = openCasStore(sharedRoot)
  finishStat("repro cas open", casOpenStart)
  let actionCacheOpenStart = statStart()
  let attachActionCacheShm = config.actionCacheRoot.len > 0
  let warmCache = warmActionCacheFor(sharedRoot / "action-cache",
    attachShm = attachActionCacheShm)
  var cache = warmCache.cache
  finishStat("repro action cache open", actionCacheOpenStart)
  defer:
    cas.close()
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
    # `Edge-Determinism-And-Soft-Rebuild.md` §3 / §5 / §10.4. A peer cache is
    # a binary-cache topology, and a `host-bound` or `volatile` entry is one
    # host's realization: no consumer on another machine can verify it, and
    # §10.4 says an advertiser of one is treated as MISCONFIGURED. The honest
    # place to enforce that is the advertiser, not the consumer, so such an
    # entry is never published in the first place.
    #
    # Read from the RECORD rather than from a `BuildAction`, because this
    # hook is also reached with a record loaded from the cache. An
    # UNDECLARED record is `weak` by §2.1's default and publishes as it
    # always has -- this gate narrows nothing that was previously published
    # unless someone labelled the edge.
    if record.determinism.declared and
        not record.determinism.class.allowsCrossMachineSubstitution():
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
      let payload = cas.casGet(contentHashForActionBlob(output.blob))
      if uint64(payload.len) != output.blob.sizeBytes:
        raise newException(CacheIntegrityError, "CAS size mismatch for " &
          digestHex(output.blob.digest))
      bundleBytes.writeU32Le(uint32(payload.len))
      for b in payload: bundleBytes.add(b)
    config.peerCacheActionPublisher(weakFingerprint, bundleBytes)
    finishStat("repro peer-cache publish", publishStart)

  proc publishBinaryCacheBundle(action: BuildAction;
                                record: ActionResultRecord;
                                allowMaterializedOutputs = false) =
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
    ##   * ``record.outputPayloadKind != opkCasBlobs`` — unless the caller
    ##     explicitly verified that the outputs are currently materialized.
    ##     The binary-cache publisher packages declared filesystem outputs;
    ##     unlike the peer-cache publisher it does not read local CAS blobs.
    if config.binaryCachePublisher == nil:
      return
    # L3 PUBLISH-SCOPE — per-(action, cache) publish decision:
    #   publish IF (cache scope == intermediate)
    #          OR (action produces a public-interface artifact — i.e. it
    #              carries ``publishToBinaryCache = true`` + an identity).
    #
    # RELEASE cache (default): only tagged public-interface members ship.
    # INTERMEDIATE cache: EVERY successful cacheable action with CAS
    # blobs ships, including untagged intermediate artefacts — the
    # engine synthesises a per-action identity for those (keyed on the
    # action id + weak fingerprint so intermediate entries are stable
    # and distinct without a recipe-declared identity).
    let isPublicInterface =
      action.publishToBinaryCache and action.cacheEntryIdentity.isSome
    if not isPublicInterface and not config.binaryCacheIntermediateScope:
      return
    if isPublicInterface:
      let identityError = actionCacheIdentityError(action)
      if identityError.len > 0:
        stats.addCounterMetric("repro binary-cache incomplete identities", 1)
        runResult.trace(action.id, "binary-cache-identity-incomplete",
          identityError)
        return
    if record.outputPayloadKind != opkCasBlobs and
        not allowMaterializedOutputs:
      return
    # §10.3's "Preferred Publishing Model" edit: "An action classified
    # `host-bound` or `volatile` MAY be cached locally BUT MUST NOT be
    # published to a binary cache." Here the ACTION is in hand, so the class
    # comes from the declaration rather than from whatever a record happens
    # to carry -- an action labelled `volatile` must not publish even if the
    # record it produced somehow lost its sidecar.
    if not action.determinismClass.allowsCrossMachineSubstitution():
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
    var folded =
      if isPublicInterface:
        action.cacheEntryIdentity.get()
      else:
        # Intermediate, untagged action: synthesise a stable identity
        # from the action id + weak fingerprint. Toolchain tag
        # ``"intermediate"`` keeps these keys namespaced away from
        # release (public-interface) entries so the two scopes never
        # collide on the same cache.
        publicInterfaceIdentity(
          packageName = "intermediate:" & action.id,
          packageVersion = "",
          toolchainName = "intermediate",
          providerRevision = toHex(action.weakFingerprint.bytes))
    let foldedTag =
      if action.cachePlatformTag.len == 0: NativeTriple
      else: action.cachePlatformTag
    folded.addOption(CachePlatformTagOptionKey, foldedTag)
    let req = BinaryCachePublishRequest(
      actionId: action.id,
      weakFingerprint: action.weakFingerprint,
      identity: folded,
      cwd: action.cwd,
      publishPrefix:
        if action.publishToBinaryCache and action.declaredOutputs.len == 1:
          action.declaredOutputs[0]
        else:
          "",
      declaredOutputs: action.outputs,
      recordOutputs: recordOutputs)
    let res =
      try: config.binaryCachePublisher(req)
      except CatchableError as e:
        BinaryCachePublishResult(ok: false, statusCode: 0,
          error: "binary-cache publisher raised: " & e.msg)
    if not res.ok:
      stats.addCounterMetric("repro binary-cache publish failures", 1)
      var detail = "status=" & $res.statusCode
      if res.error.len > 0:
        detail.add(" error=" & res.error)
      runResult.trace(action.id, "binary-cache-publish-failed", detail)
    else:
      stats.addCounterMetric("repro binary-cache publish ok", 1)
      stats.addCounterMetric("repro binary-cache publish bytes uploaded",
        res.bytesUploaded)
      runResult.trace(action.id, "binary-cache-published",
        "status=" & $res.statusCode & " bytes=" & $res.bytesUploaded)
    finishStat("repro binary-cache publish", publishStart)

  proc fastNoopReuseReason(action: BuildAction): string =
    ## The whole-graph fast scan and the regular scheduler decide the SAME
    ## state — "the record revalidated and the declared outputs (if any)
    ## are already on disk" — so they must report it the same way. The
    ## scheduler calls that state `asUpToDate` / `cdHit` with reason
    ## `outputs-present` or `no-declared-outputs` (see the `aclHit` /
    ## `reusableInPlace` branch below). The fast scan used to call it
    ## `asCacheHit` / `cdHit` with an EMPTY reason, which is the
    ## scheduler's vocabulary for something else entirely: a record whose
    ## outputs were MISSING and had to be materialized out of the CAS
    ## (reason `restored`). Two different events wearing one label is
    ## exactly what makes a status field unreadable.
    if action.declaresNoOutputs(): "no-declared-outputs"
    else: "outputs-present"

  proc tryFastNoopCacheHits(): Option[BuildRunResult] =
    # Backfill needs each full action-cache record so it can publish the
    # validated, materialized output. The regular scheduler already performs
    # that lookup and keeps publish failures soft.
    if config.publishCachedResults:
      return none(BuildRunResult)
    if not config.rebuildMissingOutputsOnCacheHit:
      return none(BuildRunResult)
    if config.progressCallback != nil:
      return none(BuildRunResult)
    # A forced rebuild is a request to re-execute, and `config.forceRebuild`
    # is read in exactly one place: the scheduler's per-action cache
    # decision. A whole-graph short-circuit that returns before the
    # scheduler runs therefore silently DISCARDS the request — every edge
    # comes back `asCacheHit` / `cdHit` / `launched = false` and nothing
    # re-runs. `repro build --force-rebuild` never exposed this only
    # because rendering progress installs a callback, which the bail-out
    # above already catches; an engine-API caller that renders nothing got
    # the flag dropped on the floor.
    if config.forceRebuild:
      return none(BuildRunResult)
    # The `--soft-rebuild` family has EXACTLY the defect described above, and
    # for exactly the same reason: `rebuildClass` is read only in the
    # scheduler's per-action decision, so a whole-graph short-circuit that
    # returns before the scheduler runs discards the request and reports
    # every edge as a cache hit. Retention is the same story — an expired
    # `volatile` entry must become a miss (§4.4), and this path never
    # consults a retention clause. Bail out for both.
    if config.rebuildClass != rbNone:
      return none(BuildRunResult)
    for action in buildGraph.actions:
      if action.effectiveRetention.kind != crkForever:
        return none(BuildRunResult)
    var fastResult: BuildRunResult
    fastResult.traceEnabled = not config.suppressTrace
    var metadataCache = initFileMetadataCache()
    if config.skipCacheHitEvidence:
      var hotProbes: seq[HotMetadataProbe] = @[]
      # M10 — parallel to `hotProbes`, so a record that observed environment
      # variables can have them re-read on THIS path too. Without it the
      # whole-graph shortcut below would serve a hit for an action whose
      # environment moved, and nothing downstream would look again.
      var hotEnvResolvers: seq[EnvResolver] = @[]
      for action in buildGraph.actions:
        if (not action.cacheable) or action.dynamicDepsFile.len > 0:
          return none(BuildRunResult)
        # An edge that declares no outputs has nothing to stat and nothing
        # to restore; its record is reusable on unchanged inputs alone
        # (`cachedResultReusableInPlace`). Bailing out of the fast path for
        # such an edge dragged every graph containing a `test` edge onto the
        # slow scheduler.
        if not action.declaresNoOutputs():
          let outputStatStart = statStart()
          let outputsPresent = action.allOutputsExist()
          finishStat("repro output stat", outputStatStart)
          if not outputsPresent:
            return none(BuildRunResult)
        hotProbes.add(HotMetadataProbe(
          weakFingerprint: action.weakFingerprint,
          policy: action.actionCachePolicy,
          outputRoot: action.cwd,
          # This arm never runs the scheduler, so the per-edge refusal at the
          # `lookupActionResult` seam is not on this path at all. The probe
          # carries the scope so the scan can apply it where it already has
          # the record in hand. See `refusesRecordWithNoInputs`.
          refuseRecordWithNoInputs: action.refusesRecordWithNoInputs()))
        hotEnvResolvers.add(action.actionEnvResolver())
      let lookupStart = statStart()
      let navigatorStart = statStart()
      let scan = cache.scanHotIndexMetadataInputsUnchanged(hotProbes,
        addr metadataCache, hotEnvResolvers)
      finishStat("repro hot index navigator scan", navigatorStart)
      finishStat("repro cache lookup", lookupStart)
      case scan.status
      of hmssHit:
        let resultMaterializeStart = statStart()
        for action in buildGraph.actions:
          fastResult.results.add(ActionResult(
            id: action.id,
            status: asUpToDate,
            cacheDecision: cdHit,
            reason: fastNoopReuseReason(action),
            dependencyPolicyKind: action.dependencyPolicy.kind))
        finishStat("repro cache hit result materialize", resultMaterializeStart)
        finishMetadataCacheStats(metadataCache)
        fastResult.stats = stats
        return some(fastResult)
      of hmssMissingRecord, hmssInputChanged, hmssOutputChanged:
        # `hmssOutputChanged` is a declared output that no longer matches the
        # record that claims to have produced it. Falling back to the full
        # scheduler is the fail-closed answer: it re-consults each edge and
        # re-executes the ones whose outputs were disturbed.
        return none(BuildRunResult)
      of hmssUnavailable, hmssCorrupt:
        discard

    var hotRecords: seq[ActionResultRecord] = @[]
    # M10 — parallel to `hotRecords`; see `hotEnvResolvers` above.
    var hotRecordEnvResolvers: seq[EnvResolver] = @[]
    for action in buildGraph.actions:
      if (not action.cacheable) or action.dynamicDepsFile.len > 0:
        return none(BuildRunResult)
      # See the note above: no declared outputs means nothing to stat.
      if not action.declaresNoOutputs():
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
      # Outputs exist, but "exists" is not "is the artifact this record
      # describes" (Incremental-Invalidation.md §"Minimum check set"
      # Step 3.3). Fall back to the full scheduler when it is not.
      # Timing is accumulated inside `outputStateMismatch` and reported once
      # as "repro output revalidate"; a timer here would have measured this
      # call site only.
      if outputStateMismatch(hotRecord.get(), action.cwd).len > 0:
        return none(BuildRunResult)
      # The other whole-graph arm, and the same reason as the probe field
      # above: reaching `hmssHit` here also means the scheduler never runs, so
      # the per-edge refusal never gets a turn. Falling back to the full
      # scheduler is enough — it re-consults this edge, refuses the record
      # there, and states the reason once.
      if action.unservableCacheRecordReason(hotRecord.get()).len > 0:
        return none(BuildRunResult)
      hotRecords.add(hotRecord.get())
      hotRecordEnvResolvers.add(action.actionEnvResolver())
    let lookupStart = statStart()
    let inputScanStart = statStart()
    let inputsUnchanged =
      hotMetadataRecordInputsUnchanged(hotRecords, addr metadataCache,
        hotRecordEnvResolvers)
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
        status: asUpToDate,
        cacheDecision: cdHit,
        reason: fastNoopReuseReason(action),
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
  var dynamicDepsLoaded = initHashSet[string]()
  var fileMetadataCache = initFileMetadataCache()
  var inlineRunQuotaSession: ReproRunQuotaSession
  var inlineRunQuotaSessionOpen = false

  # M9.R.73.2 — session-scoped state for the spec-graded monitor-loss
  # ladder from ``reprobuild-specs/Failure-Semantics.md`` §"Monitoring
  # Failures" plus the per-loss-class table in
  # ``reprobuild-specs/Monitor-Loss-Path-Invalidation.md``.
  #
  # ``sessionInvalidatedPaths`` — accumulator of the certainly-invalidated
  # + ambiguous paths from EVERY completed Level 1 (known-scope) loss in
  # this session. Grows monotonically; downstream cache LOOKUPS whose
  # action.inputs (materialized to cwd) intersect this set are skipped
  # as ``cdMiss`` with reason ``"monitor-loss-narrow-invalidation"``.
  # Empty in the healthy case, so the intersection test is a cheap
  # ``len == 0`` short-circuit.
  #
  # ``sessionCachePublishDisabled`` — set to ``true`` on the FIRST Level
  # 2 (unknown-scope) loss observed in this session. Realizes the spec's
  # "disable cache hits for the affected session" language: all
  # subsequent cache lookups are treated as ``cdMiss``. Level 1 does NOT
  # set this bit — its narrow ``sessionInvalidatedPaths`` accumulator is
  # the whole story.
  var sessionInvalidatedPaths = initHashSet[string]()
  var sessionCachePublishDisabled = false

  proc registerEvidenceInvalidation(evidence: EvidenceCollection) =
    ## M9.R.73.2 — fold a completed action's evidence into the
    ## session-scoped invalidation state.
    for path in evidence.invalidatedPaths:
      sessionInvalidatedPaths.incl(path)
    if evidence.monitorStatus == mesUnknownScopeLoss:
      sessionCachePublishDisabled = true

  proc cacheLookupBlockedByMonitorLoss(action: BuildAction): bool =
    ## M9.R.73.2 — return ``true`` when ``action``'s declared inputs
    ## intersect the session-wide ``sessionInvalidatedPaths`` accumulator
    ## OR ``sessionCachePublishDisabled`` is set (a Level 2 loss has
    ## fired earlier in the session). The scheduler treats such a
    ## lookup as ``cdMiss`` with reason ``"monitor-loss-invalidation"``.
    ## The check is defensive against the common healthy path: when
    ## both accumulators are empty/false this returns immediately.
    if sessionCachePublishDisabled:
      return true
    if sessionInvalidatedPaths.len == 0:
      return false
    for input in action.inputs:
      let materialized = materialPath(action.cwd, input)
      if sessionInvalidatedPaths.contains(materialized):
        return true
    false

  proc invalidateCachedPath(path: string) =
    fileMetadataCache.invalidate(path)

  proc invalidateCachedOutputs(action: BuildAction) =
    for output in action.outputs:
      invalidateCachedPath(materialPath(action.cwd, output))

  proc invalidateCachedWrites(action: BuildAction; evidence: PathSetEvidence) =
    for output in evidence.monitorWrites:
      invalidateCachedPath(materialPath(action.cwd, output))

  proc storeOutputBlobsFor(action: BuildAction;
                           evidence: PathSetEvidence): bool =
    ## Whether this action's output PAYLOADS go into the local CAS, as
    ## opposed to a metadata-only record.
    ##
    ## The three publish sites (elevated, builtin, process) asked this
    ## question with three copies of the same expression; S7 needed to add a
    ## second clause to all three, and three copies of a SAFETY condition is
    ## how one of them ends up without it. One closure now, so the gate
    ## cannot be present at two sites and absent at the third.
    let wanted = (not config.deferLocalOutputBlobs) or
      config.peerCacheActionPublisher != nil or
      (config.binaryCachePublisher != nil and
        (action.publishToBinaryCache or config.binaryCacheIntermediateScope))
    if not wanted:
      return false
    if not config.requireCompleteOutputEvidence:
      return true
    # S7's gate. A payload-less record cannot serve a restore, so withholding
    # the blobs is exactly "this action must re-run rather than be restored".
    let unaccounted = action.undeclaredSurvivingWrites(evidence)
    if unaccounted.len == 0:
      return true
    runResult.trace(action.id, "cache-output-blobs-withheld",
      "undeclared surviving writes: " & unaccounted.join(", "))
    let idx = idToIndex.resultIndex(action.id)
    runResult.results[idx].evidence.diagnostics.add(
      "output payloads withheld (S7): action wrote " & $unaccounted.len &
      " path(s) its declared outputs do not account for — " &
      unaccounted.join(", ") & ". Restoring only the declared outputs " &
      "would serve an incomplete tree, so the record is published without " &
      "payloads and the action re-runs instead. Declare the path as an " &
      "output, or as an ignored (machine-local derived) prefix, if it " &
      "should not gate the restore.")
    false

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
  # In-Process-Monitor-Hosting HM-4 — the in-flight io-mon consumers this
  # build hosts itself. A build-scoped local rather than a module global: the
  # pool owns live consumers and live monitored trees, and its teardown is the
  # ``finally`` below, so its lifetime has to be exactly this build's.
  var monitorHosts = MonitorHostPool()
  # HM-5 — every depfile publication that came back FAILED, by action id.
  # Consulted before an action's cache entry is published and reported again at
  # the end of the build for the publications that had not finished by then.
  var monitorFlushFailures = initTable[string, string]()
  var wrappedMonitorCaptures = initTable[string, string]()
  var launchedSucceeded = initHashSet[string]()
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
    ## True when a running entry needs periodic ``pollCompletion`` calls to
    ## drain its output. The Windows event-driven wait cannot include these
    ## entries, so cap its timeout while one is active.
    for item in running:
      if item.processKind in {rpkInlineRunQuota, rpkInlineRunQuotaPending,
                              rpkInlineRunQuotaFailed, rpkBypassProcess,
                              rpkMonitorHost}:
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

  proc recordCacheLookupFacts(id: string; lookup: ActionCacheLookup) =
    ## M17: pin the ACTION-CACHE KEY and the miss reason at the only
    ## moment they exist.
    ##
    ## ``reason`` alone will not do: ``completeSuccess`` overwrites it
    ## with the settle detail, so for exactly the actions that go on to
    ## LAUNCH -- the ones that get an ``ext_repro_action`` row -- the
    ## reason the cache missed is gone by the time the row is built.
    ## The strong fingerprint is worse still: it is not stored on the
    ## action at all, only on the record the lookup compared against.
    let idx = idToIndex.resultIndex(id)
    runResult.results[idx].cacheMissReason = lookup.message
    runResult.results[idx].strongFingerprintHex =
      if lookup.record.strongFingerprint.bytes == default(array[32, byte]):
        ""
      else:
        toHex(lookup.record.strongFingerprint.bytes)

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
    # Named-Lock-Files §4.1: a dynamically created edge inherits the
    # governing lock identity of the action that pulled it in.
    let fragment = readDynamicGraphFragment(
      fragmentPath, action.governingLockIdentity)
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
        # Set when the cache rejected the record because a DECLARED OUTPUT on
        # disk no longer matches what the record says the action produced.
        # It has to suppress the "outputs are present, call it up to date"
        # shortcut further down: that shortcut only asks whether the paths
        # exist, and here they exist and are wrong. Without this the reject
        # would be recorded as `cdRejected` and then immediately overridden
        # by `asUpToDate`, and the corrupt artifact would survive.
        var cacheRejectedOutput = false
        # Set when the cache was bypassed by DETERMINISM POLICY rather than by
        # anything observable on disk: a `--soft-rebuild`-family selector
        # covering this edge's class (§4.1–§4.3), or a `volatile` entry past
        # its `cacheRetention` window (§4.4). It must suppress the same
        # "outputs are present, call it up to date" shortcut
        # `cacheRejectedOutput` does, and for a sharper version of the same
        # reason: here the outputs exist AND are internally consistent, and
        # the operator has asked for a fresh realization anyway. Reusing
        # `cacheMissInputChanged` for this would have worked mechanically and
        # then lied in every diagnostic that reads it.
        var cacheInvalidatedByPolicy = false
        var dependencyLaunched = false
        var outputsPresentBeforeLookup = false
        var outputsPresentKnown = false
        # "May a cache record for this action be reused where its result
        # already is?" — see `cachedResultReusableInPlace`. Distinct from
        # `outputsPresentBeforeLookup`, which stays a pure statement about
        # DECLARED outputs so the no-record "outputs-present" shortcut below
        # cannot fire for an edge that declares none.
        var reusableInPlace = false
        for dep in action.deps:
          if launchedSucceeded.contains(dep):
            dependencyLaunched = true
            break
        # A launched dependency does not by itself invalidate this action.
        # The normal cache lookup below fingerprints declared and monitored
        # inputs after dependencies settle, so changed outputs still miss while
        # byte-identical producer reruns leave consumers reusable.
        if config.forceRebuild:
          runResult.results[idToIndex.resultIndex(id)].cacheDecision =
            if action.cacheable: cdMiss else: cdNotCacheable
          runResult.results[idToIndex.resultIndex(id)].reason = "force-rebuild"
          runResult.trace(id, "cache-skipped", "force-rebuild")
        elif config.rebuildSelectorInvalidates(action):
          # `Edge-Determinism-And-Soft-Rebuild.md` §4.1–§4.3. The shape
          # mirrors `forceRebuild` above, but the REASON names the class that
          # earned the invalidation, so an operator reading the trace can see
          # why `--soft-rebuild` re-ran this edge and left its neighbour
          # cached. That distinction is the whole point of the verb.
          #
          # `cacheInvalidatedByPolicy` is set for the same reason
          # `aclMissInputChanged` sets `cacheMissInputChanged`: without it,
          # the "outputs are present, call it up to date" shortcut further
          # down re-declares this action up to date and the rebuild silently
          # does NOTHING. That shortcut only asks whether the declared output
          # paths exist, and after a `--soft-rebuild` they all still do —
          # which is precisely the case where the operator asked for a fresh
          # realization of bytes that are already sitting there.
          runResult.results[idToIndex.resultIndex(id)].cacheDecision =
            if action.cacheable: cdMiss else: cdNotCacheable
          let reason = config.rebuildClass.flagSpelling & " " &
            $action.determinismClass
          runResult.results[idToIndex.resultIndex(id)].reason = reason
          runResult.trace(id, "cache-skipped", reason)
          cacheInvalidatedByPolicy = true
        elif action.cacheable and cacheLookupBlockedByMonitorLoss(action):
          # M9.R.73.2 — an earlier action in this session hit a monitor
          # loss whose invalidated-path set intersects this action's
          # declared inputs, OR a Level 2 (unknown-scope) loss disabled
          # cache hits session-wide. Force a miss so the action
          # re-executes rather than trusting evidence that pre-dates
          # the invalidation. See ``registerEvidenceInvalidation``.
          runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
          runResult.results[idToIndex.resultIndex(id)].reason =
            if sessionCachePublishDisabled: "monitor-loss-session-disabled"
            else: "monitor-loss-narrow-invalidation"
          runResult.trace(id, "cache-skipped",
            runResult.results[idToIndex.resultIndex(id)].reason)
        elif action.cacheable:
          if config.rebuildMissingOutputsOnCacheHit:
            if not action.declaresNoOutputs():
              # Skipped entirely when nothing is declared: no declared output
              # can be missing, and `outputsPresentBeforeLookup` must stay
              # false so the no-record "outputs-present" shortcut below
              # cannot fire for such an edge.
              let outputStatStart = statStart()
              outputsPresentBeforeLookup = action.allOutputsExist()
              outputsPresentKnown = true
              finishStat("repro output stat", outputStatStart)
            reusableInPlace =
              action.cachedResultReusableInPlace(outputsPresentBeforeLookup)
          let lookupStart = statStart()
          var lookup = cache.lookupActionResult(cas.inner, action.weakFingerprint,
            action.actionCachePolicy,
            verifyOutputBlobs = not reusableInPlace,
            allowMetadataOnlyHit = config.rebuildMissingOutputsOnCacheHit and
              reusableInPlace,
            metadataCache = addr fileMetadataCache,
            envResolver = action.actionEnvResolver(),
            outputRoot = action.cwd,
            retention = action.effectiveRetention,
            nowUnix = config.nowUnix,
            buildEpoch = config.buildEpoch)
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
                lookup = cache.lookupActionResult(cas.inner, action.weakFingerprint,
                  action.actionCachePolicy,
                  verifyOutputBlobs = not reusableInPlace,
                  allowMetadataOnlyHit =
                    config.rebuildMissingOutputsOnCacheHit and
                    reusableInPlace,
                  metadataCache = addr fileMetadataCache,
                  envResolver = action.actionEnvResolver(),
                  outputRoot = action.cwd,
                  retention = action.effectiveRetention,
                  nowUnix = config.nowUnix,
                  buildEpoch = config.buildEpoch)
                finishStat("repro peer-cache lookup-retry", retryStart)
                runResult.trace(id, "peer-cache-hit", $lookup.status)
              else:
                runResult.trace(id, "peer-cache-install-failed",
                  install.reason)
          # ONE seam for BOTH lookups above — the local one and the
          # peer-installed retry — and deliberately placed after the retry so
          # a record that arrived from a peer is graded exactly like one that
          # was already on disk. See `unservableCacheRecordReason` for what it
          # refuses and, just as importantly, what it does not try to.
          if lookup.status in {aclHit, aclHybridCutoff}:
            let refusal = action.unservableCacheRecordReason(lookup.record)
            if refusal.len > 0:
              runResult.trace(id, "cache-record-refused", refusal)
              lookup = ActionCacheLookup(status: aclMissNoRecord,
                message: refusal)
          case lookup.status
          of aclHit:
            if config.rebuildMissingOutputsOnCacheHit and reusableInPlace:
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              if config.publishCachedResults:
                publishBinaryCacheBundle(action, lookup.record,
                  allowMaterializedOutputs = true)
              completeSuccess(id, asUpToDate, cdHit, false,
                if action.declaresNoOutputs(): "no-declared-outputs"
                else: "outputs-present")
              inc completed
              launchedAny = true
              continue
            if config.rebuildMissingOutputsOnCacheHit:
              runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
              runResult.results[idToIndex.resultIndex(id)].reason =
                "missing-output"
              runResult.trace(id, "cache-skipped", "missing-output")
            else:
              # Nothing to restore when the outputs are already the recorded
              # ones — see `restoreWouldOverwriteMatchingOutputs`. Restoring
              # them anyway gives every one a new mtime and re-runs every
              # consumer of them on every warm build.
              let alreadyInPlace =
                restoreWouldOverwriteMatchingOutputs(action, lookup.record)
              if not alreadyInPlace:
                let restoreStart = statStart()
                cas.materializeActionCacheOutputs(lookup.record, action.cwd)
                fileMetadataCache.clear()
                finishStat("repro cache restore", restoreStart)
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              if config.publishCachedResults:
                publishBinaryCacheBundle(action, lookup.record,
                  allowMaterializedOutputs = true)
              completeSuccess(id, asCacheHit, cdHit, false,
                if alreadyInPlace: "outputs-present" else: "restored")
              inc completed
              launchedAny = true
              continue
          of aclHybridCutoff:
            if config.rebuildMissingOutputsOnCacheHit and reusableInPlace:
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              if config.publishCachedResults:
                publishBinaryCacheBundle(action, lookup.record,
                  allowMaterializedOutputs = true)
              completeSuccess(id, asUpToDate, cdHybridCutoff, false,
                if action.declaresNoOutputs(): "no-declared-outputs"
                else: "outputs-present")
              inc completed
              launchedAny = true
              continue
            if config.rebuildMissingOutputsOnCacheHit:
              runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
              runResult.results[idToIndex.resultIndex(id)].reason =
                "missing-output"
              runResult.trace(id, "cache-skipped", "missing-output")
            else:
              # Same reasoning as the `aclHit` arm above.
              let alreadyInPlace =
                restoreWouldOverwriteMatchingOutputs(action, lookup.record)
              if not alreadyInPlace:
                let restoreStart = statStart()
                cas.materializeActionCacheOutputs(lookup.record, action.cwd)
                fileMetadataCache.clear()
                finishStat("repro cache restore", restoreStart)
              runResult.results[idToIndex.resultIndex(id)].evidence =
                cacheHitEvidence(action, lookup.record)
              if config.publishCachedResults:
                publishBinaryCacheBundle(action, lookup.record,
                  allowMaterializedOutputs = true)
              completeSuccess(id, asCacheHit, cdHybridCutoff, false,
                if alreadyInPlace: "outputs-present" else: "restored")
              inc completed
              launchedAny = true
              continue
          of aclRejectedCorruptOutput:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdRejected
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message else: "corrupt-output"
            cacheRejectedOutput = true
            runResult.trace(id, "cache-rejected",
              runResult.results[idToIndex.resultIndex(id)].reason)
            recordCacheLookupFacts(id, lookup)
          of aclMissInputChanged:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message else: "input-changed"
            recordCacheLookupFacts(id, lookup)
            cacheMissInputChanged = true
          of aclMissRetentionExpired:
            # §4.4's one automatic invalidation: nothing changed, the cached
            # realization simply aged out of its declared window. It must set
            # `cacheInvalidatedByPolicy` — the outputs are all still on disk
            # and internally consistent, so the up-to-date shortcut below
            # would otherwise swallow the expiry whole and serve the stale
            # realization forever.
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message
              else: "retention-expired"
            runResult.trace(id, "cache-expired",
              runResult.results[idToIndex.resultIndex(id)].reason)
            recordCacheLookupFacts(id, lookup)
            cacheInvalidatedByPolicy = true
          else:
            runResult.results[idToIndex.resultIndex(id)].cacheDecision = cdMiss
            runResult.results[idToIndex.resultIndex(id)].reason =
              if lookup.message.len > 0: lookup.message else: $lookup.status
            recordCacheLookupFacts(id, lookup)
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
            not cacheRejectedOutput and
            not cacheInvalidatedByPolicy and
            not dependencyLaunched and
            not config.forceRebuild and
            not action.needsExecutionForPolicy():
          let evidenceStart = statStart()
          let evidence = collectEvidence(action, strict = true,
            config = addr config)
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
            let evidence = collectEvidence(action, strict = true,
              config = addr config)
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
            # M9.R.73.2 — fold Level 1 invalidated-path set (or Level 2
            # session-disable flag) into the session-scoped accumulator
            # so downstream cache LOOKUPS can skip narrowly.
            registerEvidenceInvalidation(evidence)
            # Cache ineligibility withholds publication, not successful outputs.
            if action.cacheable and not evidence.disableCacheHits:
              let recordStart = statStart()
              let storeOutputBlobs =
                storeOutputBlobsFor(action, evidence.evidence)
              let record = cache.recordActionResult(cas.inner,
                action.weakFingerprint,
                action.actionCachePolicy,
                action.cacheInputPaths(evidence.evidence),
                action.outputs, action.cwd,
                storeOutputBlobs = storeOutputBlobs,
                metadataCache = addr fileMetadataCache,
                envInputs = action.cacheEnvInputs(evidence.evidence),
                # An elevated edge reaches this site instead of the
                # monitored one, and it used to record every directory
                # input with NO membership digest. That is not "less
                # precise": a recorded `mtimeNs = 0` means "not
                # membership-tracked", such a directory is never
                # re-listed, and the hit path does not re-record — so the
                # record was PERMANENTLY existence-only
                # (Incremental-Invalidation.md:814-821). The evidence was
                # already collected two lines up; only the hand-off was
                # missing.
                enumeratedDirectories =
                  action.cacheEnumeratedDirectories(evidence.evidence),
                determinism = entryDeterminismFor(config, action))
              finishStat("repro cache record", recordStart)
              writeActionResultRecordFile(
                dependencyEvidencePath(cacheRoot, action.id), record)
              publishPeerCacheBundle(action.weakFingerprint, record)
              publishBinaryCacheBundle(action, record)
            elif action.cacheable and evidence.disableCacheHits:
              runResult.traceCacheIneligibility(id, evidence)
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

        # In-Process-Monitor-Hosting HM-4 — the launch decision is taken HERE,
        # before the monitor is planned, because only a path the ENGINE spawns
        # can host io-mon in-process and the monitor plan is what records that
        # choice. It used to sit just above the spawn, ~130 lines below.
        #
        # Guarded on ``bakProcess`` so nothing changes for a built-in action:
        # ``tryEnsureInlineRunQuotaSession`` opens a real session, and a
        # built-in never launches anything that would use one. The two
        # variables are consumed unchanged at the spawn site; only the point
        # at which they are computed moved.
        var bypassRunQuota = false
        var inlineRunQuota = false
        if action.kind == bakProcess:
          if config.inlineRunQuota and not effectiveBypassRunQuota:
            inlineRunQuota = tryEnsureInlineRunQuotaSession()
            bypassRunQuota = not inlineRunQuota
          else:
            bypassRunQuota = launchBypassesRunQuota()
        # In-Process-Monitor-Hosting P3 — "which launch path" is now ONE
        # value, and it is the only input to the hosting decision besides the
        # config. It used to be a bare ``bypassRunQuota`` conjunct on the line
        # below, which read like a scope note and was in fact the only thing
        # standing between an inline action and a completely unmonitored run
        # (see the refusal further down, and ``monitorHostingRefusal``).
        let launchPath =
          if bypassRunQuota: mlpBypassRunQuota
          elif inlineRunQuota: mlpInlineRunQuota
          else: mlpRunQuotaHelper
        # Saying "hosted" here does two independent things: it tells
        # ``monitoredAction`` to leave the argv ALONE (no
        # ``repro internal io monitor`` wrapper), and it tells the launch
        # site below to start an in-process host instead. Under
        # ``mhmWhereSupported`` the two are matched by
        # ``launchPathHostsMonitorInProcess``; under ``mhmRequired`` a plan
        # is hosted on every path DELIBERATELY, so that a request the launch
        # sites cannot satisfy fails loudly at the site instead of being
        # silently downgraded where nothing could observe it.
        let hostMonitorInProcess = InProcessMonitorHostSupported and
          action.kind == bakProcess and
          monitorHostingRequested(config.monitorHosting, launchPath)

        let monitorPlanStart = statStart()
        let plan = monitoredAction(action, config, cacheRoot,
          hostMonitorInProcess)
        if plan.capturePath.len > 0:
          wrappedMonitorCaptures[id] = plan.capturePath
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
          # M17: the cache-lookup facts were recorded BEFORE the action
          # ran and would be wiped by this assignment. They are carried
          # for the same reason the cache decision is -- the settled
          # result describes the execution, not the lookup that led to
          # it, and the lookup is the only place either fact exists.
          let previousMissReason = runResult.results[idx].cacheMissReason
          let previousStrongFingerprint =
            runResult.results[idx].strongFingerprintHex
          runResult.results[idx] = finished
          runResult.results[idx].cacheMissReason = previousMissReason
          runResult.results[idx].strongFingerprintHex =
            previousStrongFingerprint
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
            let evidence = collectEvidence(plan.action, strict = true,
              config = addr config)
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
            # M9.R.73.2 — fold Level 1 invalidated-path set (or Level 2
            # session-disable flag) into the session-scoped accumulator
            # so downstream cache LOOKUPS can skip narrowly.
            registerEvidenceInvalidation(evidence)
            # Cache ineligibility withholds publication, not successful outputs.
            if plan.action.cacheable and not evidence.disableCacheHits:
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
              let storeOutputBlobs =
                storeOutputBlobsFor(plan.action, evidence.evidence)
              let record = cache.recordActionResult(cas.inner,
                plan.action.weakFingerprint,
                plan.action.actionCachePolicy, plan.action.cacheInputPaths(evidence.evidence),
                plan.action.outputs, plan.action.cwd,
                storeOutputBlobs = storeOutputBlobs,
                metadataCache = addr fileMetadataCache,
                envInputs = plan.action.cacheEnvInputs(evidence.evidence),
                # Same omission as the elevated site above, reached by
                # builtin edges and by anything whose plan is not a
                # `bakProcess`. A builtin cannot be wrapped in the
                # io-monitor, so its enumeration evidence arrives either
                # from a converter path set or from a monitor depfile a
                # direct engine caller prewired — both of which
                # `collectEvidence` has already folded by this point.
                enumeratedDirectories =
                  plan.action.cacheEnumeratedDirectories(evidence.evidence),
                determinism = entryDeterminismFor(config, plan.action))
              finishStat("repro cache record", recordStart)
              writeActionResultRecordFile(
                dependencyEvidencePath(cacheRoot, plan.action.id), record)
              publishPeerCacheBundle(plan.action.weakFingerprint, record)
              publishBinaryCacheBundle(plan.action, record)
            elif plan.action.cacheable and evidence.disableCacheHits:
              runResult.traceCacheIneligibility(finished.id, evidence)
            completeSuccess(finished.id, asSucceeded,
              runResult.results[idx].cacheDecision, true, "builtin")
          else:
            runResult.trace(finished.id, "failed", finished.stderr)
            blockClosure(finished.id, finished.id)
            emitProgress(bpkActionCompleted, finished.id)
          inc completed
          launchedAny = true
          continue

        # In-Process-Monitor-Hosting P3 — A HOSTED PLAN MAY ONLY REACH A
        # LAUNCH SITE THAT HOSTS. This is the enforcement half of the
        # handshake ``monitoredAction`` cannot check from where it stands.
        #
        # ``monitoredAction`` strips the ``repro internal io monitor``
        # wrapper when the plan says hosted, so a hosted plan arriving at a
        # site that starts no host runs the recipe's argv NAKED: no wrapper,
        # no host, no iomon, an empty dependency set, and a successful,
        # cache-publishing action that reports nothing wrong. Only the L1
        # branch below honours ``plan.hostInProcess``; an inline launch is
        # staged and ``continue``s above that branch, and the helper path
        # hands the whole argv to another process.
        #
        # THE CONDITION IS KEYED ON ``bypassRunQuota`` — the same variable
        # that selects the spawn a few lines below — and NOT on
        # ``launchPathHostsMonitorInProcess``. That is the difference
        # between a guard and a restatement: flipping the inline row of that
        # table to ``true`` in the hope of enabling hosting there does not
        # walk past this check, it makes every inline action fail with the
        # sentence below until the staging site has actually learned to
        # start a host (In-Process-Monitor-Hosting P4).
        if plan.hostInProcess and not bypassRunQuota:
          let refusal = monitorHostingRefusal(launchPath)
          statuses[id] = asFailed
          let refusedIdx = idToIndex.resultIndex(id)
          runResult.results[refusedIdx].status = asFailed
          runResult.results[refusedIdx].dependencyPolicyKind =
            plan.action.dependencyPolicy.kind
          runResult.results[refusedIdx].monitorDepfilePath =
            plan.action.monitorDepfile
          runResult.results[refusedIdx].stderr = refusal
          runResult.trace(id, "failed", refusal)
          blockClosure(id, id)
          emitProgress(bpkActionCompleted, id)
          completed = terminalCount()
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
        # ``bypassRunQuota`` / ``inlineRunQuota`` were decided above the
        # monitor plan (HM-4). Their consumption is unchanged.
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
          #
          # NOTE THE ``continue``: this path leaves before the launch
          # branch below, so it never reaches the code that would start an
          # in-process host. An unwrapped argv staged here would run
          # completely unmonitored — which is why the guard above refuses a
          # hosted plan on any path that is not L1, and why this assertion
          # stands here as well.
          #
          # SECOND LINE OF DEFENCE, and it is not redundant with the guard.
          # The guard's coverage of this site rests on nothing but source
          # ORDER: move this staging block above it — which is exactly the
          # shape this code had before P3 — and the guard silently stops
          # covering the inline path. The assertion is attached to the
          # staging itself, so it travels with the block and cannot be
          # separated from it by moving code around. It is unreachable while
          # the guard is in place; that is the intended state, not an excuse
          # for leaving it out.
          doAssert not plan.hostInProcess,
            monitorHostingRefusal(mlpInlineRunQuota)
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
        var directProcess: ReproDirectRunningProcess
        var monitorSlot = -1
        var processKind =
          if plan.hostInProcess: rpkMonitorHost
          elif bypassRunQuota: rpkBypassProcess
          else: rpkHelperProcess
        let startEvent = "launched"
        let startDetail = "pool=" & poolName
        var launchFailure = ""
        try:
          if plan.hostInProcess:
            # HM-4 — the engine IS io-mon's host for this action. Reached only
            # when the monitor plan said so, which it only does for a launch
            # path the engine spawns.
            monitorSlot = startMonitorHost(monitorHosts, plan.action, config,
              cacheRoot)
          elif bypassRunQuota:
            directProcess = startBypassRunQuotaProcess(plan.action, config)
          else:
            process = startRunQuotaProcess(plan.action, config, resultPath)
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
        var runningAction = RunningAction(
          id: id,
          pool: poolName,
          poolUnits: units,
          action: plan.action,
          processKind: processKind,
          process: process,
          directProcess: directProcess,
          resultPath: resultPath,
          monitorSlot: monitorSlot
        )
        when defined(posix):
          if not bypassRunQuota and not plan.hostInProcess:
            runningAction.processGroupPid = assignProcessGroup(process)
        running.add(runningAction)
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
        except ReproRunQuotaDeadlockError:
          # A whole frontier blocked by requests the authority cannot ever
          # admit is a build-level scheduler deadlock, not an action process
          # failure. Preserve the typed outcome for the CLI diagnostic.
          raise
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
              resultPath: staged.resultPath,
              monitorSlot: -1
            ))
            runResult.trace(staged.id, startEvent, startDetail)
            emitProgress(bpkActionStarted, staged.id)
            launchedAny = true

      if completed >= buildGraph.actions.len:
        break

      if running.len == 0:
        if ready.len > 0 and not launchedAny:
          raiseEngine("ready queue is blocked by pool capacity")
        # The graph can advance no further: nothing is running, ready, or
        # launchable, yet ``completed < total``. Historically this raised
        # with ONLY the ``asPending`` ids — but when the stall is caused by
        # a failed action whose dependents were cascaded to ``asBlocked``
        # (e.g. a dev-env provisioning/activation action whose tool couldn't
        # be resolved), none of the survivors are ``asPending``, so the list
        # was EMPTY and hid the real cause. Reconstruct the terminal
        # failures — the failed actions with their reason/stderr and the
        # blocked actions with their blocker — so the diagnostic names what
        # actually went wrong. The message keeps the historical
        # "build graph made no progress" prefix and a "pending actions:"
        # segment so existing prefix/substring consumers still match.
        var pending: seq[string] = @[]
        var failedActions: seq[string] = @[]
        var blockedActions: seq[string] = @[]
        for action in buildGraph.actions:
          case statuses[action.id]
          of asPending:
            pending.add(action.id)
          of asFailed:
            let res = runResult.results[idToIndex.resultIndex(action.id)]
            var detail = res.stderr.strip()
            if detail.len == 0:
              detail = res.reason.strip()
            if detail.len == 0:
              detail = "exit " & $res.exitCode
            failedActions.add(action.id & " (" & detail & ")")
          of asBlocked:
            let res = runResult.results[idToIndex.resultIndex(action.id)]
            if res.blockedBy.len > 0 and res.blockedBy != action.id:
              blockedActions.add(action.id & " (blocked by " &
                res.blockedBy & ")")
            else:
              blockedActions.add(action.id)
          else:
            discard
        var segments: seq[string] = @[]
        if failedActions.len > 0:
          segments.add("failed actions: " & failedActions.join("; "))
        if blockedActions.len > 0:
          segments.add("blocked actions: " & blockedActions.join(", "))
        segments.add("pending actions: " & pending.join(", "))
        raiseEngine("build graph made no progress; " & segments.join("; "))

      var runIndex = -1
      let waitStart = statStart()
      var nextGrantPoll = 0.0
      var lastTickTime = epochTime()
      while runIndex < 0:
        raiseIfCancelled()
        let now = epochTime()
        if now - lastTickTime >= 0.1:
          lastTickTime = now
          for item in running:
            emitProgress(bpkActionStarted, item.id)
        if hasPendingInlineRunQuota() and epochTime() >= nextGrantPoll:
          runIndex = pollInlineRunQuotaGrants()
          nextGrantPoll = epochTime() + 0.025
          if runIndex >= 0:
            break
        # In-Process-Monitor-Hosting HM-4 — settle EVERY hosted monitor whose
        # root has exited before choosing which action to reap, and settle
        # them in their own pass so the choice cannot skip any.
        #
        # This is the timing decision the milestone asks to be made
        # deliberately. ``settleMonitorHost`` runs ``finishMonitor`` as soon as
        # ``pollMonitor`` answers true, and the §4.1 detached-descendant grace
        # window opens at that call (DH-4). Doing it inside the selection loop
        # below would leave every monitor after the first one in the pass
        # unfinished until the scheduler got round to it, so a descendant that
        # died in between would be graded ``mcComplete`` here and
        # ``mcIncomplete`` by the reference form — a divergence produced by
        # queue depth rather than by anything about the action.
        #
        # Engine-Threadpool TP-2 — the settle pass now HANDS OFF rather than
        # finishing. What has not changed is WHEN: the handoff still happens
        # on the pass that first observes the exit, and the pass's own start
        # is the instant every finish's grace-window delay is measured from
        # (``MonitorFinishOutcome.openDelayNs``). What has changed is that the
        # k-th monitor of a pass no longer waits for its k-1 predecessors'
        # ``finishMonitor`` calls before its own window opens, which is the
        # direction the evidence wants: waiting longer errs toward
        # ``mcComplete``.
        let settlePassStartedAtNs = monotonicNowNs()
        for j in 0 ..< running.len:
          if running[j].processKind == rpkMonitorHost:
            discard settleMonitorHost(monitorHosts, running[j].monitorSlot,
              settlePassStartedAtNs)
        # Fold back every finish a worker has completed. Done in its own pass,
        # immediately after the handoffs, so a monitor whose worker was
        # already done becomes reapable on this iteration rather than the next.
        drainMonitorFinishesInto(monitorHosts)
        # Cheap inline-only checks first: queued/failed inline-runquota
        # entries are not handle-based and the OS won't wake us for them.
        # Inline-RunQuota processes do their own pipe / handle wait in
        # `pollCompletion`, which is non-blocking here.
        for j in 0 ..< running.len:
          case running[j].processKind
          of rpkInlineRunQuotaPending:
            discard
          of rpkMonitorHost:
            if monitorHosts.records[running[j].monitorSlot].finished:
              runIndex = j
              break
          of rpkInlineRunQuota:
            if running[j].runQuotaProcess.pollCompletion():
              runIndex = j
              break
          of rpkInlineRunQuotaFailed:
            runIndex = j
            break
          of rpkBypassProcess:
            if running[j].directProcess.pollCompletion():
              runIndex = j
              break
          of rpkHelperProcess:
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
          else:
            let nextTickInMs = int((lastTickTime + 0.1 - epochTime()) * 1000.0)
            max(10, min(250, nextTickInMs))
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
      # HM-5 — the hosted path's evidence, in memory, for exactly one
      # iteration. Declared here and re-assigned per action so it is dropped
      # (and its ~18 MB for a real provider compile freed) as soon as
      # ``collectEvidence`` below has folded it.
      var hostedMonitorRecords: seq[MonitorRecord] = @[]
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
        of rpkMonitorHost:
          finishMonitorHostAction(
            monitorHosts,
            runningItem.id,
            runningItem.monitorSlot,
            config,
            cacheRoot,
            hostedMonitorRecords)
        of rpkBypassProcess:
          finishBypassRunQuotaProcess(
            runningItem.id,
            runningItem.directProcess,
            cacheRoot)
        of rpkHelperProcess:
          finishRunQuotaProcess(
            runningItem.id,
            runningItem.process,
            runningItem.resultPath,
            cacheRoot)
      finishStat("repro runquota finish", finishStart)
      if runIndex < 0:
        raiseEngine("internal missing running action: " & finished.id)
      if runningItem.processKind == rpkHelperProcess:
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
      # M17: see the built-in merge above. Recorded at lookup time,
      # carried across the settle.
      let previousMissReason = runResult.results[idx].cacheMissReason
      let previousStrongFingerprint =
        runResult.results[idx].strongFingerprintHex
      runResult.results[idx] = finished
      runResult.results[idx].cacheMissReason = previousMissReason
      runResult.results[idx].strongFingerprintHex = previousStrongFingerprint
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
        var evidenceAction = action
        let wrappedCapture = wrappedMonitorCaptures.getOrDefault(finished.id)
        if wrappedCapture.len > 0:
          evidenceAction.monitorDepfile = wrappedCapture
        var evidence =
          if runningItem.processKind == rpkMonitorHost:
            # HM-5 — fold from the records the host already has. The ``.iomon``
            # for this action may not exist yet; that is the point.
            collectEvidence(action, strict = true,
              hostedRecords = addr hostedMonitorRecords,
              config = addr config)
          else:
            collectEvidence(evidenceAction, strict = true,
              config = addr config)
        hostedMonitorRecords = @[]
        finishStat("repro evidence collect", evidenceStart)
        if wrappedCapture.len > 0:
          enqueueMonitorFlush(MonitorFlushJob(actionId: finished.id,
            tempPath: wrappedCapture, destPath: action.monitorDepfile))
        # HM-5 — a publication that FAILED means this action's ``.iomon`` never
        # landed. Nothing is wrong with the action or its evidence, which came
        # from memory; what is missing is the artefact ``repro why`` and CI
        # read for the cache entry about to be published. So the entry is not
        # published and the next build MISSES and re-runs — the same "fail
        # toward a re-execution" direction IM-3's missing-create case takes.
        #
        # A CACHEABLE hosted action WAITS for its own publication here, and
        # that is the one place this milestone gives its asynchrony back on
        # purpose. A non-blocking drain makes the conservative direction a
        # RACE between a rename and this wrap-up — measured going both ways
        # while mutation-checking, which is how it was found — and a
        # conservative direction that holds "usually" is not one. What is
        # waited for is a ``rename`` on a file io-mon finished writing before
        # the action was reaped, after evidence collection and the converters
        # have already run; see ``awaitMonitorFlush``. Everything else — every
        # non-cacheable action, and every action's next edges up to this point
        # — still proceeds without waiting.
        let flushOutcomes =
          if (runningItem.processKind == rpkMonitorHost or
              wrappedCapture.len > 0) and action.cacheable:
            awaitMonitorFlush(finished.id)
          else:
            drainMonitorFlushOutcomes()
        for outcome in flushOutcomes:
          if outcome.error.len == 0: continue
          monitorFlushFailures[outcome.actionId] = outcome.error
        if monitorFlushFailures.hasKey(finished.id):
          evidence.disableCacheHits = true
          evidence.cacheIneligibilityReasons.incl(cirMonitorFlushFailed)
          evidence.evidence.diagnostics.add(
            "monitor depfile flush failed; action-cache publish skipped so " &
            "the next build re-executes: " & monitorFlushFailures[finished.id])
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
        # M9.R.73.2 — fold Level 1 invalidated-path set (or Level 2
        # session-disable flag) into the session-scoped accumulator
        # so downstream cache LOOKUPS can skip narrowly.
        registerEvidenceInvalidation(evidence)
        # Cache ineligibility withholds publication, not successful outputs.
        if action.cacheable and not evidence.disableCacheHits:
          let recordStart = statStart()
          # M9.L.4-refactor Step A: force output-blob retention when
          # either the peer-cache publisher OR the binary-cache
          # publisher (with this action opted in) needs to read the
          # blob payloads back out of the local CAS.
          let storeOutputBlobs = storeOutputBlobsFor(action, evidence.evidence)
          let record = cache.recordActionResult(cas.inner, action.weakFingerprint,
            action.actionCachePolicy, action.cacheInputPaths(evidence.evidence),
            action.outputs, action.cwd,
            storeOutputBlobs = storeOutputBlobs,
            metadataCache = addr fileMetadataCache,
            envInputs = action.cacheEnvInputs(evidence.evidence),
            enumeratedDirectories =
              action.cacheEnumeratedDirectories(evidence.evidence),
            determinism = entryDeterminismFor(config, action))
          finishStat("repro cache record", recordStart)
          writeActionResultRecordFile(
            dependencyEvidencePath(cacheRoot, action.id), record)
          publishPeerCacheBundle(action.weakFingerprint, record)
          publishBinaryCacheBundle(action, record)
        elif action.cacheable and evidence.disableCacheHits:
          runResult.traceCacheIneligibility(finished.id, evidence)
        completeSuccess(finished.id, asSucceeded, runResult.results[idx].cacheDecision,
          true, "exit=0")
      else:
        let wrappedCapture = wrappedMonitorCaptures.getOrDefault(finished.id)
        if wrappedCapture.len > 0:
          enqueueMonitorFlush(MonitorFlushJob(actionId: finished.id,
            tempPath: wrappedCapture,
            destPath: runningItem.action.monitorDepfile))
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
    # Engine-Threadpool TP-2 — every handed-off finish comes back BEFORE the
    # teardown below touches a slot. A worker owns a ``MonitorHandle`` for the
    # length of its job, so abandoning a slot whose finish is in flight would
    # be a release of a handle this thread does not own; and the finish is
    # what creates the scratch depfile ``abandonMonitorHost`` removes, so
    # abandoning first would leave one behind. This runs on the unwinding path
    # too, which is the case that makes it load-bearing rather than tidy.
    var pendingFinishes = awaitMonitorFinishes()
    for outcome in pendingFinishes.mitems:
      applyMonitorFinishOutcome(monitorHosts, outcome)
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
      of rpkMonitorHost:
        # HM-4 — kill the monitored root, then let the handle go. Dropping it
        # reaps the root before releasing the consumer, so no producer is ever
        # left publishing into a released set (LF-2); killing first is what
        # keeps that reap from blocking shutdown indefinitely.
        abandonMonitorHost(monitorHosts, item.monitorSlot)
      of rpkBypassProcess:
        if item.directProcess.active and not item.directProcess.completed:
          discard item.directProcess.cancelAndWait()
      of rpkHelperProcess:
        terminateRunningAction(item)
        item.process.close()
    if inlineRunQuotaSessionOpen:
      emitActionExtensionRows(inlineRunQuotaSession, runResult, actionsById)
      inlineRunQuotaSession.close()
    # HM-5 — the build does not end while a depfile publication is still in
    # flight. Not for correctness of the build (the evidence was folded from
    # memory and every cacheable action already waited for its own
    # publication before publishing); for the ARTEFACT. A process that exited
    # with a rename queued would leave a dot-prefixed scratch file next to a
    # depfile that never appeared, and the next build would find neither.
    #
    # What can still be learned only HERE is narrow and is named rather than
    # rounded up: a NON-cacheable action's failure, which withholds nothing
    # because there was no entry to withhold, and a cacheable action whose
    # ``awaitMonitorFlush`` hit its 30-second guard — a filesystem that has
    # stopped answering, where the build has larger problems than a missing
    # debugging artefact.
    for outcome in awaitMonitorFlushes():
      if outcome.error.len == 0: continue
      monitorFlushFailures[outcome.actionId] = outcome.error
      let lateIdx = idToIndex.getOrDefault(outcome.actionId, -1)
      if lateIdx >= 0 and lateIdx < runResult.results.len:
        runResult.results[lateIdx].evidence.diagnostics.add(
          "monitor depfile flush failed after the action-cache entry was " &
          "published: " & outcome.error)
      runResult.trace(outcome.actionId, "monitor-flush-failed", outcome.error)
    # Engine-Threadpool TP-1 — and EVERY OTHER tenant of the engine's worker
    # pool drains here too, not just the flush above.
    #
    # This is inside the ``finally``, which is the whole of the guarantee: an
    # exception unwinding out of the scheduling loop — a raising
    # ``progressCallback``, say — must not leave a worker mid-job while the
    # process tears down around it. ``the pool drains when an exception
    # unwinds out of the build`` pins that, and moving this line (or the
    # flush drain above it) out of the ``finally`` is the mutation that
    # reddens it — measured red on both of that case's assertions: the
    # depfile never appeared and the dot-prefixed scratch file was left
    # behind.
    #
    # TP-2's monitor finish is the second tenant and is already drained above
    # — by ``awaitMonitorFinishes``, which has to run BEFORE the teardown
    # because it also folds evidence back into slots. This line is what keeps
    # the guarantee whole for the tenant AFTER that one.
    awaitEnginePoolIdle()
    # Launch, converter and cancellation failures may never enqueue a flush.
    # Only this build's exclusive capture files belong to this cleanup.
    for capture in wrappedMonitorCaptures.values:
      try:
        removeFile(capture)
      except CatchableError as err:
        runResult.trace("", "monitor-capture-cleanup-failed", err.msg)
  finishStat("repro scheduler total", totalStart)
  finishMetadataCacheStats(fileMetadataCache)
  runResult.stats = stats
  result = runResult
