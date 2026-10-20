## ``repro_lock_gen`` — lock generation as a build-graph computation.
##
## Named-Lock-Files NLF-M5, design §5.6:
##
## > **Requirement.** Lock generation is performed by ordinary, cacheable
## > build-graph edges: **metadata-fetch edges upstream, a solve edge
## > downstream of them, a lock file as the output artifact.** `repro lock
## > solve`, a `--strategy` invocation, an implicit solve during `repro
## > build`, and a hidden lock are the **same edges** reached through
## > different entry points — one path, several doors, not three
## > implementations.
##
## ## Where this library sits, and why it is not where the ledger said
##
## `Named-Lock-Files.milestones.org` NLF-M5 §"Key Source Files" names
## `libs/repro_build_engine/src/repro_build_engine/` (a directory holding only
## `platform.nim`) and `libs/repro_solver/src/repro_solver/`. Neither can hold
## this code, and the reason is structural rather than tidiness:
##
##   * the engine must NOT import the solver. `repro_lock/identity.nim`'s
##     header states the constraint and the cost of breaking it — the solver
##     loads `libclingo` through a `{.dynlib.}` FFI at module-init, so an
##     engine that imported it would give every engine binary a clingo runtime
##     dependency;
##   * the solver must NOT import the engine, or the dependency becomes a
##     cycle the moment the engine wants a solved graph.
##
## So the generation path is a leaf ABOVE both: it imports the engine (for
## `BuildAction` and the two NLF-M5 edge kinds), the solver (to run the solve)
## and `repro_lock` (to write the lock). Nothing imports it except the CLI.
##
## ## The two waves
##
## `Configurable-System.md` §"The Solve Is A Rule-Generator Edge, Not A
## Pre-Graph Phase" (amended 2026-08-21) restates the stage numbering as an
## ordering of RESULTS:
##
## > Stage 2 is the **first expansion wave**: metadata-fetch edges, then the
## > solve edge that consumes them. … Stages 4 and 5 are the **second wave**,
## > stitched in only once the lock has been materialized.
##
## `generateLock` builds and runs wave 1. Its output — the lock — is the
## rule-set artifact the second wave is expanded from; the second wave is the
## ordinary build graph and is not this library's business.
##
## ## What governs these edges, and why it is the empty graph
##
## Every action here carries `emptySolvedGraphIdentity(request.platform)` as
## its `governingLockIdentity`, and the choice is forced rather than
## convenient. §5.6's second circularity is **fingerprint inversion**:
## `Caching-Architecture.md` puts solved package instance identities inside the
## weak fingerprint of every action, so "no downstream edge can be keyed until
## the solve has a result: the solve edge is upstream of the fingerprint
## algebra itself, not a peer within it." A generation edge governed by the
## lock it produces would be keyed on its own output.
##
## `repro_lock/identity.lockIdentityOutsideSolvedGraph` documents exactly this
## population — "a dev-environment materialisation that runs before any solve"
## — and is a real recompute over the empty graph rather than a sentinel. This
## library uses the platform-parameterised `emptySolvedGraphIdentity` instead
## of that host-parameterised alias for one reason: a generation request
## carries its own `platform` (`repro lock refresh --platform`), and an edge
## generating an `arm64-darwin` lock on an `amd64-linux` host is honestly
## governed by the empty graph FOR THE PLATFORM IT IS SOLVING, not for the
## host it happens to run on.
##
## That leaves one question the identity must NOT answer: two generations
## differing in strategy or constraints share this identity, so what keeps
## their cache entries apart? Their **weak fingerprints**, which cover the
## static inputs of wave 1 (`Locking-And-Solver.md` §"Solver Cache", amended
## 2026-08-21) including the strategy. That is §6.2's own instruction for this
## situation — "the correct response is to find the missing input and add it —
## never to add the label."
##
## ## Over-approximation, not a fixpoint
##
## §5.6: "every arm of a variant-conditioned `uses:` is statically enumerable
## from the recipe source, so the first wave fetches metadata for *all* arms
## and the solve selects among them. One wave, no iteration." `fetchPlan`
## enumerates arms and unions them; it does NOT iterate to convergence, and
## `generateLock` asserts the resulting expansion closed in one wave rather
## than trusting that it did.

import std/[algorithm, options, os, strutils, tables]

import repro_build_engine
import repro_hash
import repro_lock
import repro_solver

import repro_lock_gen/metadata_objects
import repro_lock_gen/solve_path_set
import repro_lock_gen/upstream_archives

export metadata_objects
export solve_path_set
export upstream_archives

type
  LockStrategy* = enum
    ## `Named-Lock-Files.md` §5.5's strategy set. A strategy is "a rule for
    ## producing one answer", and `default` is named explicitly "so 'no
    ## strategy given' is a value rather than a hole".
    ##
    ## The strategy is a first-class input: it is in the solve edge's weak
    ## fingerprint, "because two strategies over identical constraints are two
    ## different computations" (`Locking-And-Solver.md` §"Solver Cache").
    ##
    ## ## What NLF-M6 changed about what these MEAN
    ##
    ## NLF-M5 implemented `lowest`/`highest` by narrowing each package's
    ## candidate universe to its extreme published version before encoding.
    ## That ignores declared ranges, and it does not fail quietly: `libfoo`
    ## publishing 1.0 … 1.9 under `uses: ">=1.2 <2.0"` narrowed to `{1.0}` and
    ## the solve reported UNSAT for a workspace with a good answer at 1.2.
    ##
    ## NLF-M6 replaces the narrowing with a SOLVER OBJECTIVE
    ## (`VersionPreference`): the full universe is encoded, the declared ranges
    ## remain hard constraints, and the strategy only ORDERS what is
    ## admissible. `lowest-direct` ships alongside, which the narrowing form
    ## could not express at all.
    lsDefault = "default"
    lsLowest = "lowest"
    lsHighest = "highest"
    lsLowestDirect = "lowest-direct"
      ## Direct dependencies take their lowest admissible version; anything
      ## reached only transitively takes its highest. Cargo's
      ## `-Z direct-minimal-versions` shape. See `VersionPreference` for why
      ## the asymmetry is the point rather than a compromise.

  LockGenerationEntryPoint* = enum
    ## The four doors §5.6 requires to be one path.
    ##
    ## They differ in WHERE the lock lands and whether it is committed, and in
    ## nothing else. §5.4: "the only difference from `repro lock solve
    ## --lowest --write` is *where the file lands and whether it is
    ## committed*." Carried on the request so a diagnostic can say which door
    ## was used — it deliberately does NOT enter the weak fingerprint, because
    ## a lock produced through one door and a lock produced through another
    ## from the same inputs are the same lock (§5.4: "Identity is automatic").
    lgeLockSolve = "repro lock solve"
    lgeImplicitBuildSolve = "implicit solve during repro build"
    lgeStrategyHiddenLock = "--strategy hidden lock"
    lgeLockRefresh = "repro lock refresh"

  LockGenerationRequest* = object
    ## The STATIC inputs of the first expansion wave.
    ##
    ## §5.6: "Constructing the first wave needs only **static** inputs — the
    ## `uses:` constraint declarations parsed from recipe source". Everything
    ## here is known before anything is solved or fetched, which is what lets
    ## the wave exist at all.
    variants*: seq[VariantDecl]
    packages*: seq[PackageDecl]
    inputsText*: string
      ## The rendered solver-inputs text, recorded as the lock's
      ## `inputs_digest` provenance. Not a key (see `repro_lock/identity`).
    platform*: string
    strategy*: LockStrategy
    endpoints*: seq[string]
      ## The repository set — metadata index base URLs, most-preferred first.
      ## Empty means "consult no registry": the declared candidate versions in
      ## `packages` are the whole universe, no `netFetch` edge is emitted, and
      ## the generation is hermetic. That is the ordinary case for a project
      ## whose recipe pins its universe, and it is why an empty plan is not an
      ## error.
    workDir*: string
      ## Where the wave's artifacts land: one file per retrieved object, plus
      ## the generated lock. For a hidden lock this is a scratch directory; for
      ## `repro lock solve` the caller copies the result to the committed path.
    extraDeps*: seq[LockedDep]
      ## Locked dependencies the CALLER observed and the solve does not
      ## produce: the workspace's participating VCS checkouts, with their
      ## coordinates and integrity (MO-8 / FUP-M).
      ##
      ## Carried on the request rather than folded in afterwards so that
      ## `repro lock refresh` — which has them — and `repro lock solve` — which
      ## does not — are the same call with different arguments instead of two
      ## writers. A second assembly site is how the committed lock acquired a
      ## v1-emitting writer alongside a v2 reader; see
      ## `repro_lock.serializeSolvedGraphLock`.
    entryPoint*: LockGenerationEntryPoint
    objectKinds*: set[MetadataObjectKind]
      ## Which `Repository-And-Index-Format.md` object kinds wave 1 retrieves.
      ##
      ## Empty means `{mokVersionList}` — the one kind NLF-M5 shipped — so
      ## every pre-NLF-M6 caller's fetch plan is byte-unchanged and the
      ## NLF-GEN-5/6/7 fetch counts do not move. A caller that wants the richer
      ## objects asks for them. This is a request field rather than a global
      ## because which objects a repository publishes is a property of the
      ## repository, not of the build.
    cacheRoot*: string
      ## The PERSISTENT root of the solve edge's two-phase path-set store
      ## (§5.7). Empty means `workDir / "solve-cache"`, which is
      ## per-invocation and therefore never hits — correct for a one-shot
      ## generation and useless for measuring materiality, so the NLF-M6 tests
      ## give it a stable value. Deliberately NOT `workDir`: the wave's
      ## artifacts are scratch and the CLI deletes them, while the path-set
      ## store is exactly the thing that must survive between invocations.
    nimReleaseBase*: string
      ## Where the upstream-archive edges look for official Nim release
      ## archives and their ``.sha256`` files. Empty means
      ## ``upstream_archives.NimReleaseBase`` (nim-lang.org). A request field
      ## so a test can serve the release tree from a loopback listener and
      ## an air-gapped site from its own mirror; whatever base is used, the
      ## URL it resolved to is what the lock records.
    recordCertificatePolicy*: bool
      ## Test-Certificates TC-9b: whether this generation records the
      ## ``[certificate_policy]`` snapshot (``certificatePolicySection``) in
      ## the document it writes. Set by the CLI for the writing doors, which
      ## are the ones that evaluated the provider for it; false keeps every
      ## other caller's document exactly as it was.
    certificatePolicySection*: string
      ## The snapshot to record when ``recordCertificatePolicy``: rendered
      ## from the policy the recipe enacts, "" when it enacts none (so the
      ## snapshot of a policy that was removed leaves the lock).

  MetadataFetchPlanEntry* = object
    ## One planned `bakMetadataFetch` edge — one retrieved object.
    kind*: MetadataObjectKind
    subject*: string
      ## The object's key within its kind. For `mokVersionList` this is the
      ## package name; for `mokIndexShard` the shard letter; for
      ## `mokAcquisitionRecord` `<package>@<version>`; empty for the two
      ## repository-wide kinds.
    packageName*: string
      ## The package this object belongs to, or `""` for a repository-wide
      ## object. Equal to `subject` for `mokVersionList`, which is the field's
      ## NLF-M5 meaning and is preserved.
    arms*: seq[string]
      ## Every variant arm that asks for this package, as `variant=value`,
      ## sorted; `"*"` for an unconditioned `uses:`. Recorded rather than
      ## discarded because over-approximation is only defensible if it is
      ## legible: a reader (and corpus case NLF-GEN-6) must be able to see that
      ## metadata was fetched for an arm the solve may never select.
    url*: string
    destination*: string
    objectPath*: string
    actionId*: string
    version*: string
      ## ``mokUpstreamArchive`` only: the candidate version the record is
      ## for, so the solve can pick the record of the version it selected.
    requestText*: string
      ## ``mokUpstreamArchive`` only: the edge's ``builtinText``, an
      ## ``upstream_archives`` request naming package, version, platform and
      ## release base. Every other kind's edge text is its ``url``.

  LockGenerationResult* = object
    entryPoint*: LockGenerationEntryPoint
    lockDocument*: string
      ## The generated lock's bytes. The artifact of the rule-generator edge.
    lockIdentity*: LockIdentity
    solveWeakFingerprint*: string
      ## The solve edge's weak fingerprint, lowercase hex.
    fetchWaves*: seq[seq[string]]
      ## The metadata-fetch action ids issued, grouped by wave. Length 1 is
      ## the over-approximation property NLF-GEN-6 asserts.
    fetchAttempts*: int
      ## Attempts made during this generation, read off the in-process
      ## fetcher's counter.
    lockPath*: string
    solveExecuted*: bool
      ## Whether the CLINGO SOLVE ran, as distinct from whether a lock was
      ## produced. NLF-GEN-3 requires assertion on this and says why: "Assert
      ## on whether the solve RAN, not only on lock content, or the raw
      ## fallback passes as though it were the target." A raw path set
      ## invalidates on every upstream publication, re-solves, and produces a
      ## byte-identical lock — so every content assertion still passes while
      ## the property under test is absent.
    pathSetHitIndex*: int
      ## Which recorded path set served this generation, or `-1` when the
      ## solve ran. Distinguishes "hit the entry we wrote last time" from "hit
      ## an OLDER entry", which is the only observable difference between a
      ## two-phase store and a one-entry cache.
    pathSetsRecorded*: int
      ## How many path sets the weak fingerprint carries after this
      ## generation.
    pathSet*: SolvePathSet
      ## The observations this generation recorded (or matched). Read by the
      ## folded criterion that the object KIND is distinguishable in the
      ## recorded path set.
    strategyReport*: string
      ## Non-empty when the requested strategy had NO candidate universe to
      ## narrow, naming why.
      ##
      ## NLF-M6's third folded criterion: NLF-M5 found `--strategy` "accepted,
      ## printed in the run summary, and silently inert on every project in
      ## this workspace, because none configures a registry. The fix landed;
      ## the *class* has not been closed." A strategy that cannot take effect
      ## must SAY SO. Empty for `lsDefault`, which is not a narrowing rule and
      ## therefore cannot fail to be one.

const
  LockGenerationPool* = "lock-generation"
  MaxGenerationWaves* = 2
    ## The bound `expandGraphInWaves` runs under for THIS expansion.
    ##
    ## Two, not `DefaultMaxExpansionWaves`, and deliberately tight. §5.6 says
    ## the generation expansion is one wave by construction — over-approximate
    ## the fetch, then solve — so a bound of 2 leaves exactly one wave of slack
    ## and turns "somebody made the fetch a fixpoint" into a loud failure
    ## instead of a quiet performance regression. A generous bound here would
    ## make the over-approximation claim unfalsifiable.

# ---------------------------------------------------------------------------
# The static inputs, canonically rendered
# ---------------------------------------------------------------------------

proc hexOf(digest: ContentDigest): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(digest.bytes.len * 2)
  for b in digest.bytes:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

proc framed(label: string; items: openArray[string]): string =
  ## Length-prefixed framing, so no two distinct input sets can render to one
  ## string by concatenation ambiguity — the §1.3 hazard, which for a cache key
  ## "does not fail loudly: it produces two different keys for one lock file".
  result = label & "[" & $items.len & "]"
  for item in items:
    result.add("\x1f" & item)
  result.add("\x1e")

proc renderVariantDecl(v: VariantDecl): string =
  var contribs: seq[string] = @[]
  for c in v.contributions:
    contribs.add($c.priority & "=" & c.value)
  contribs.sort()
  var constraints: seq[string] = @[]
  for c in v.constraints:
    constraints.add($c.kind & ":" & c.sourceValue & "->" & c.target & "=" &
      c.targetValue)
  constraints.sort()
  result = "name=" & v.name & "\x1e" & "kind=" & $v.kind & "\x1e"
  result.add(framed("values", v.allowedValues))
  result.add(framed("contribs", contribs))
  result.add(framed("constraints", constraints))
  result.add("pinned=" & v.pinnedValue & "\x1e")

proc renderPackageDecl(p: PackageDecl): string =
  var deps: seq[string] = @[]
  for d in p.depends:
    let gate =
      if d.conditional.isSome:
        d.conditional.get().variantName & "=" & d.conditional.get().triggerValue
      else:
        "*"
    deps.add(d.name & "|" & d.range & "|" & gate)
  deps.sort()
  result = "name=" & p.name & "\x1e"
  result.add(framed("versions", p.versions))
  result.add(framed("depends", deps))
  result.add("source=" & p.source & "\x1e")
  result.add("pinned=" & (if p.pinned: "1" else: "0") & "\x1e")

proc canonicalSolveInputs*(req: LockGenerationRequest): string =
  ## The solve edge's WEAK fingerprint material — "what is known before it
  ## runs", per `Locking-And-Solver.md` §"Solver Cache" as amended on
  ## 2026-08-21. That section enumerates it and this proc follows the
  ## enumeration:
  ##
  ##   * root package set, and the version constraints (`uses:`) — **including
  ##     every arm of a variant-conditioned `uses:`**, which falls out of
  ##     rendering every `DependencyDecl` with its gate rather than only the
  ##     active ones;
  ##   * option assignments, variant contributions and overrides;
  ##   * platform facts declared as solver inputs;
  ##   * the solver **strategy** in force, "because two strategies over
  ##     identical constraints are two different computations";
  ##   * the repository set.
  ##
  ## What is deliberately absent: the ENTRY POINT, the destination path, and
  ## the retrieved metadata. The first two because §5.4 makes a hidden lock and
  ## a committed one with identical content the same lock; the third because it
  ## is not static — it belongs to the STRONG fingerprint (§5.7), which is
  ## NLF-M6.
  var vs: seq[string] = @[]
  for v in req.variants: vs.add(renderVariantDecl(v))
  vs.sort()
  var ps: seq[string] = @[]
  for p in req.packages: ps.add(renderPackageDecl(p))
  ps.sort()
  var eps = req.endpoints
  eps.sort()
  result = "reprobuild.lock-generation.v1\x1e"
  result.add("platform=" & req.platform & "\x1e")
  result.add("strategy=" & $req.strategy & "\x1e")
  result.add(framed("variants", vs))
  result.add(framed("packages", ps))
  result.add(framed("repositories", eps))
  # Only when set, so every request that leaves it at the default keeps the
  # weak fingerprint (and the action ids derived from it) it had before
  # upstream-archive edges existed.
  if req.nimReleaseBase.len > 0:
    result.add("nim-release-base=" & req.nimReleaseBase & "\x1e")

proc solveInputsDigestHex*(req: LockGenerationRequest): string =
  hexOf(weakFingerprintFromText(canonicalSolveInputs(req)))

# ---------------------------------------------------------------------------
# Wave 1, part 1: the over-approximated metadata-fetch plan
# ---------------------------------------------------------------------------

proc effectiveNimReleaseBase*(req: LockGenerationRequest): string =
  if req.nimReleaseBase.len > 0: req.nimReleaseBase else: NimReleaseBase

proc upstreamArchivePlan(req: LockGenerationRequest; digest: string):
    seq[MetadataFetchPlanEntry] =
  ## One ``mokUpstreamArchive`` edge per (store-sourced package with an
  ## upstream route, DECLARED candidate version): reprobuild-specs
  ## Distribution-And-Packaging, M5 "pin the provider-compile toolchain".
  ##
  ## Planned over the declared universe, not the solved version, for the
  ## reason ``mokAcquisitionRecord`` is: which version wins is the solve's
  ## output, and a plan that waited for it would be the fixpoint §5.6
  ## dissolves. A compiler pin is an exact ``==V``, so its universe is that
  ## one version and the over-approximation costs nothing. A platform
  ## upstream publishes nothing for gets no edge, and its lock entry no
  ## archive (realization then names the manual install).
  ##
  ## Independent of ``endpoints`` and ``objectKinds``: those describe a
  ## reprobuild repository, and this object comes from the package's
  ## upstream.
  let base = req.effectiveNimReleaseBase()
  var names: seq[string]
  for p in req.packages:
    if parsePackageSource(p.source).kind == pskStore and
        hasUpstreamArchives(p.name) and p.name notin names:
      names.add(p.name)
  names.sort()
  for name in names:
    var versions: seq[string]
    for p in req.packages:
      if p.name == name:
        for v in p.versions:
          if v notin versions: versions.add(v)
    versions.sort()
    for v in versions:
      let candidates =
        try: nimReleaseCandidates(v, req.platform, base)
        except UpstreamArchiveError as err:
          raise newException(UpstreamArchiveError,
            "cannot pin " & name & " " & v & " for " & req.platform & ": " &
            err.msg)
      if candidates.len == 0:
        continue
      let subject = name & "@" & v
      result.add(MetadataFetchPlanEntry(
        kind: mokUpstreamArchive,
        subject: subject,
        packageName: name,
        arms: @[],
        url: candidates[0].sha256Url,
        destination: base.strip(leading = false, chars = {'/'}) & "/",
        objectPath: req.workDir / "metadata" /
          metadataObjectFileName(mokUpstreamArchive, subject),
        actionId: "lockgen/" & digest & "/fetch/" & $mokUpstreamArchive &
          "/" & subject,
        version: v,
        requestText: renderUpstreamArchiveRequest(name, v, req.platform,
          base)))

proc fetchPlan*(req: LockGenerationRequest): seq[MetadataFetchPlanEntry] =
  ## Every metadata object wave 1 retrieves, over-approximated across variant
  ## arms.
  ##
  ## `Reprobuild-Standard-Library.md` §"`uses:` Resolution Under Variants"
  ## lets a `uses:` be variant-conditioned, so which package a recipe depends
  ## on can depend on a variant the solver has not yet chosen. §5.6: "Naively
  ## that needs a fixpoint. It is resolved by **over-approximation**: every arm
  ## of a variant-conditioned `uses:` is statically enumerable from the recipe
  ## source, so the first wave fetches metadata for *all* arms and the solve
  ## selects among them. One wave, no iteration."
  ##
  ## Concretely: this walks every `DependencyDecl` of every declared package
  ## and IGNORES its `conditional` gate when deciding whether to fetch, while
  ## RECORDING the gate in `arms`. A gate-respecting walk is the fixpoint this
  ## must not be — it could only respect a gate whose variant is already
  ## resolved, and resolving it is the solve this fetch precedes.
  ##
  ## Over-fetching costs metadata bandwidth, not correctness. §5.7 shrinks even
  ## that: metadata for an arm the solve never consulted must not invalidate
  ## anything.
  ##
  ## NLF-M6 extends the plan past the single version-list kind NLF-M5 shipped.
  ## The additional kinds are the same edge shape and are planned from STATIC
  ## inputs only, so the wave stays closed after one round:
  ##
  ##   * `mokRootManifest` / `mokCuratorSnapshotIndex` — one repository-wide
  ##     object each;
  ##   * `mokIndexShard` — one per first-letter partition of the package names
  ##     the plan already knows about;
  ##   * `mokAcquisitionRecord` — one per (package, DECLARED candidate
  ##     version). Over-approximated over the recipe's declared universe, for
  ##     the same reason the version-list plan over-approximates variant arms:
  ##     which version will be selected is the solve's output, so a plan that
  ##     waited for it would be the fixpoint §5.6 dissolves. A package whose
  ##     universe comes only from the registry contributes no acquisition
  ##     record in wave 1 — stated rather than implied, because that is a real
  ##     limit of planning acquisition from static inputs.
  ##
  ## Before all of these, and whether or not a repository is configured:
  ## one ``mokUpstreamArchive`` per store-sourced package with an upstream
  ## route (``upstreamArchivePlan``).
  result = @[]
  let digest = req.solveInputsDigestHex()
  result.add(upstreamArchivePlan(req, digest))
  if req.endpoints.len == 0:
    return
  let kinds =
    if req.objectKinds == {}: {mokVersionList} else: req.objectKinds
  let endpoint = req.endpoints[0]
  let destination = metadataDestinationOf(endpoint)

  proc entry(kind: MetadataObjectKind; subject, packageName: string;
             arms: seq[string]): MetadataFetchPlanEntry =
    MetadataFetchPlanEntry(
      kind: kind,
      subject: subject,
      packageName: packageName,
      arms: arms,
      url: metadataObjectUrl(endpoint, kind, subject),
      destination: destination,
      objectPath: req.workDir / "metadata" /
        metadataObjectFileName(kind, subject),
      # The KIND is in the action id, and it has to be: a package named `a`
      # and an index shard `a` would otherwise be one edge with two outputs.
      # This moves the version-list fetch edges' ids (and therefore their weak
      # fingerprints) from their NLF-M5 spelling. No frozen fixture covers
      # them — NLF-STAT-4's corpus carries `bakMetadataFetch` under its own
      # hand-written id — and a generation-path edge id is not a migration
      # surface, but the change is stated rather than left to be discovered.
      actionId: "lockgen/" & digest & "/fetch/" & $kind &
        (if subject.len > 0: "/" & subject else: ""))

  var arms = initTable[string, seq[string]]()
  var order: seq[string] = @[]
  proc note(name, arm: string) =
    if not arms.hasKey(name):
      arms[name] = @[]
      order.add(name)
    if arm notin arms[name]:
      arms[name].add(arm)
  for p in req.packages:
    if not p.pinned:
      note(p.name, "*")
    for d in p.depends:
      let arm =
        if d.conditional.isSome:
          d.conditional.get().variantName & "=" & d.conditional.get().triggerValue
        else:
          "*"
      note(d.name, arm)
  order.sort()

  # Repository-wide objects first: they are what a real client reads before it
  # knows where anything else lives.
  if mokRootManifest in kinds:
    result.add(entry(mokRootManifest, "", "", @[]))
  if mokCuratorSnapshotIndex in kinds:
    result.add(entry(mokCuratorSnapshotIndex, "", "", @[]))
  if mokIndexShard in kinds:
    var shards: seq[string] = @[]
    for name in order:
      let shard = indexShardOf(name)
      if shard notin shards: shards.add(shard)
    shards.sort()
    for shard in shards:
      result.add(entry(mokIndexShard, shard, "", @[]))
  if mokVersionList in kinds:
    for name in order:
      var armList = arms[name]
      armList.sort()
      result.add(entry(mokVersionList, name, name, armList))
  if mokAcquisitionRecord in kinds:
    var declared = initTable[string, seq[string]]()
    for p in req.packages:
      declared[p.name] = p.versions
    for name in order:
      var versions = declared.getOrDefault(name, @[])
      versions.sort()
      for v in versions:
        result.add(entry(mokAcquisitionRecord, name & "@" & v, name, @[]))

proc generatedLockPath*(req: LockGenerationRequest): string =
  req.workDir / "generated.lock"

proc solveActionId*(req: LockGenerationRequest): string =
  "lockgen/" & req.solveInputsDigestHex() & "/solve"

proc solvePathSetRoot*(req: LockGenerationRequest): string =
  ## Where the solve edge's two-phase path-set store lives for this request.
  ##
  ## `workDir / "solve-cache"` when the request names no persistent root, which
  ## is per-invocation and therefore always a miss. That default is honest
  ## rather than convenient: a one-shot `repro lock solve` into a temp
  ## directory genuinely has nothing to hit, and inventing a shared location
  ## for it would make one invocation's answer depend on another's scratch.
  if req.cacheRoot.len > 0: req.cacheRoot else: req.workDir / "solve-cache"

# ---------------------------------------------------------------------------
# Wave 1, as build actions
# ---------------------------------------------------------------------------

proc generationWaveOne*(req: LockGenerationRequest): seq[BuildAction] =
  ## The first expansion wave: one `bakMetadataFetch` edge per retrieved
  ## object, then the `bakSolveLock` rule-generator edge that consumes them.
  ##
  ## The fetch edges are `cacheable = true` and carry `netFetch` plus the
  ## destination they may reach. §5.6 is explicit that cacheability here is
  ## earned and not asserted — "the ordering is forced: **evidence first,
  ## cacheability second**" — and the evidence is the fetched object written to
  ## the edge's declared output plus the recorded destination set. These are
  ## NEW edges, so they are not blocked by the existing `cacheable = false`
  ## declarations on Nim compiles.
  let identity = emptySolvedGraphIdentity(req.platform)
  result = @[]
  var deps: seq[string] = @[]
  var inputs: seq[string] = @[]
  for entry in req.fetchPlan():
    result.add(builtinAction(bakMetadataFetch, entry.actionId,
      governingLockIdentity = identity,
      outputs = [entry.objectPath],
      cacheable = true,
      text = (if entry.requestText.len > 0: entry.requestText else: entry.url),
      networkMode = netFetch,
      netDestinations = [entry.destination]))
    deps.add(entry.actionId)
    inputs.add(entry.objectPath)
  # The solve edge itself is `netDenied`. It reads what the fetch edges
  # retrieved and reaches nothing: amendment rule 3 ("a non-hermetic edge is
  # never a silent input to a build that believes itself pinned") is easier to
  # hold when exactly one edge kind in the wave is non-hermetic.
  result.add(builtinAction(bakSolveLock, req.solveActionId(),
    governingLockIdentity = identity,
    deps = deps,
    inputs = inputs,
    outputs = [req.generatedLockPath()],
    cacheable = true,
    weakFingerprint = weakFingerprintFromText(canonicalSolveInputs(req)),
    text = $req.strategy,
    networkMode = netDenied))

# ---------------------------------------------------------------------------
# The executors
# ---------------------------------------------------------------------------

proc versionPreferenceOf*(strategy: LockStrategy): VersionPreference =
  ## Map a user-facing lock strategy onto the solver's version objective.
  ##
  ## The whole of NLF-M6's strategy semantics is this one function plus
  ## `encodeVersionPreference`. NLF-M5's `applyStrategy` — which narrowed each
  ## candidate universe to its extreme published version before encoding — is
  ## GONE, and its removal is the fix rather than a refactor: narrowing ignores
  ## the declared ranges, so `>=1.2 <2.0` over a universe of 1.0 … 1.9 narrowed
  ## to `{1.0}` under `lowest` and the solve reported UNSAT. A preference is a
  ## soft objective over the FULL universe; the ranges stay hard constraints
  ## and decide admissibility, and the strategy only orders what survives them.
  case strategy
  of lsDefault: vpNone
  of lsLowest: vpLowest
  of lsHighest: vpHighest
  of lsLowestDirect: vpLowestDirect

proc mergeFetchedVersions(req: LockGenerationRequest;
                          plan: seq[MetadataFetchPlanEntry]):
                            seq[PackageDecl] =
  ## Fold the retrieved version lists into the declared package set.
  ##
  ## A package the registry knows about but the recipe never declared becomes
  ## a declaration with the fetched universe — that is how a transitively
  ## required package acquires candidates. A package the recipe declared and
  ## the registry also carries has its universe REPLACED by what was retrieved:
  ## the registry is the authority on what is published, and keeping stale
  ## in-recipe versions alongside it would let the solve select a version the
  ## registry does not carry.
  ##
  ## **The strategy is NOT applied here.** NLF-M5 narrowed each universe to its
  ## extreme published version at this point; NLF-M6 removed that and moved the
  ## whole of strategy semantics into the solver's objective
  ## (`versionPreferenceOf` → `encodeVersionPreference`). The reason is not
  ## tidiness: narrowing happens BEFORE the declared ranges are applied, so
  ## `>=1.2 <2.0` over a published universe of 1.0 … 1.9 narrowed to `{1.0}`
  ## and the solve reported UNSAT for a workspace whose answer is 1.2. The
  ## universe this proc produces is now the FULL consulted universe, which is
  ## also what §5.7's interval filter must be replayed against — a narrowed
  ## universe would have made the recorded interval a filter over a set the
  ## registry never published.
  ##
  ## A PINNED package is untouched, and must be: its version is OBSERVED rather
  ## than selected (NLF-M2), so there is no choice for a selection rule to
  ## make.
  ##
  ## Only `mokVersionList` objects contribute. The other kinds are documents
  ## (`isEnumerationKind`), and a document carries no candidate versions to
  ## fold in — parsing one as a version list would invent candidates out of
  ## whatever lines it happened to contain.
  var byName = initTable[string, int]()
  result = @[]
  for p in req.packages:
    byName[p.name] = result.len
    result.add(p)
  for entry in plan:
    if entry.kind != mokVersionList:
      continue
    if not fileExists(entry.objectPath):
      continue
    let fetched = parseVersionList(readFile(entry.objectPath))
    if fetched.len == 0:
      continue
    if byName.hasKey(entry.packageName):
      let idx = byName[entry.packageName]
      if not result[idx].pinned:
        result[idx].versions = fetched
    else:
      result.add(PackageDecl(name: entry.packageName, versions: fetched,
        depends: @[], variants: @[], source: "", pinned: false))

proc attachUpstreamArchives(deps: var seq[LockedDep];
                            plan: seq[MetadataFetchPlanEntry]) =
  ## Copy the upstream-archive record of each lifted store dependency's
  ## SOLVED version into its lock entry. A record that was planned but is
  ## absent or unreadable fails the generation: writing the entry without
  ## its archive would commit a pin no reprobuild can realize, and the edge
  ## that should have produced it has already reported why it did not.
  for i in 0 ..< deps.len:
    if deps[i].coordinates.kind != ckStore:
      continue
    var planned: seq[string]
    for entry in plan:
      if entry.kind != mokUpstreamArchive or
          entry.packageName != deps[i].name:
        continue
      planned.add(entry.version)
      if entry.version != deps[i].version:
        continue
      if not fileExists(entry.objectPath):
        raise newException(UpstreamArchiveError,
          "the upstream-archive edge for " & entry.subject &
          " produced no record at " & entry.objectPath)
      deps[i].archive = parseUpstreamArchiveRecord(readFile(entry.objectPath))
      break
    if planned.len > 0 and not deps[i].archive.isPinned:
      # The platform has an upstream route (edges were planned) but the
      # solve chose a version none of them was for: writing the entry
      # without an archive would be the unrealizable pin this refuses.
      raise newException(UpstreamArchiveError,
        "the solve chose " & deps[i].name & " " & deps[i].version &
        ", but upstream archives were resolved only for " &
        planned.join(", ") & " (the declared candidates)")

proc renderLockDocument(req: LockGenerationRequest;
                        sol: UnifiedSolution;
                        plan: seq[MetadataFetchPlanEntry]): string =
  ## The rule-set artifact: a canonical `reprobuild.solved-graph-lock.v3`
  ## document.
  ##
  ## Produced through the SAME writer `repro lock refresh` uses
  ## (`solutionToLock` → `lockedDepsFromSolved` → `serializeLockedDependencies`
  ## → the MO-11 lift), because "one path, several doors" has to mean the
  ## bytes too. `serializeSolvedGraphLock` delegates to
  ## `serializeLockedDependencies` for the same reason
  ## (`libs/repro_lock/tests/t_lock_writer_output_reads_back.nim` is the
  ## regression), and a second hand-written body here would reintroduce exactly
  ## the writer/reader drift that fix removed.
  var solved = solutionToLock(sol, req.platform, req.inputsText)
  var declaredSource = initTable[string, string]()
  for decl in req.packages:
    if decl.source.len > 0:
      declaredSource[decl.name] = decl.source
  for i in 0 ..< solved.packages.len:
    let s = declaredSource.getOrDefault(solved.packages[i].name, "")
    if s.len > 0:
      solved.packages[i].source = s
  var ld = lockedDepsFromSolved(solved)
  ld.schema = SolvedGraphLockSchemaV3
  ld.deps = req.extraDeps
  var lifted = lockedDepsFromPackages(ld.packages, req.platform)
  attachUpstreamArchives(lifted, plan)
  ld.deps.add(lifted)
  serializeLockedDependencies(ld)

var solveExecutionCount {.threadvar.}: int
  ## How many times a CLINGO SOLVE has actually run on this thread.
  ##
  ## The counterpart to `metadataFetchAttempts`, and it exists for the reason
  ## NLF-GEN-3 states: "Assert on whether the solve RAN, not only on lock
  ## content, or the raw fallback passes as though it were the target." A raw
  ## path set invalidates on every upstream publication, re-solves, and emits a
  ## byte-identical lock — so a test that only compares locks reports success
  ## for an implementation with no filtered interval in it at all.
  ##
  ## Incremented immediately BEFORE `solve` is called, so a solve that raised
  ## still counts. "Tried to solve" is the property; "produced an answer" is a
  ## different one and is carried by the result.

proc solveExecutions*(): int =
  ## The running solve count for this thread.
  solveExecutionCount

proc resetSolveExecutions*() =
  solveExecutionCount = 0

var lastPathSetHitIndex {.threadvar.}: int
var lastPathSet {.threadvar.}: SolvePathSet
  ## The observations the most recent solve edge recorded or matched, handed
  ## back to `generateLock` out of band.
  ##
  ## Out of band because the engine's `ActionResult` carries stdout/stderr and
  ## an exit code, not a typed payload, and encoding a path set through stdout
  ## would need a second serializer for it — a second thing to drift, which is
  ## the reason `installGenerationExecutors` is a closure rather than data in
  ## `builtinText` in the first place. Sound for the same reason that is:
  ## the executor hooks are `{.threadvar.}` and the generation wave runs at
  ## `maxParallelism = 1`.

proc installGenerationExecutors*(req: LockGenerationRequest) =
  ## Bind the two NLF-M5 executors to `req` for the duration of one
  ## generation.
  ##
  ## Closures rather than data smuggled through `builtinText`, and the
  ## precedent is the engine's own: `registerBinaryCacheSubstituteExecutor`'s
  ## documentation describes callers installing "an executor bound to a fresh
  ## `ClientContext` + `HttpPool` + `ClientIndex`". The alternative — encoding
  ## the whole solver-input set into an action's text field — would need a
  ## second serializer for the solver inputs, which is a second thing to drift.
  let plan = req.fetchPlan()

  registerMetadataFetchExecutor(proc(action: BuildAction): ActionResult
      {.gcsafe.} =
    result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
      launched: true, runQuotaBackend: "metadata-fetch")
    try:
      # Under `-d:ssl` the in-process fetch path reaches `http_pool`'s cached
      # `SslContext` global, so it is not gcsafe. The cast is narrowed to the
      # retrieval and is sound for the reason the solve executor's is: the
      # executor hooks are per-thread (`{.threadvar.}`) and the generation
      # wave runs at `maxParallelism = 1`.
      var retrieved: RetrievedMetadata
      {.cast(gcsafe).}:
        retrieved =
          if isUpstreamArchiveRequest(action.builtinText):
            resolveUpstreamArchive(action.builtinText)
          else:
            fetchMetadataObject(action.builtinText)
      let outPath = action.outputs[0]
      createDir(parentDir(outPath))
      writeFile(outPath, retrieved.body)
      # The edge's evidence, recorded next to the object: the digest of what
      # was ACTUALLY retrieved (content-addressed after the fact, §5.6) and the
      # destination that produced it. Written as a sidecar rather than folded
      # into the object so the object stays byte-identical to what the server
      # served — a re-run that retrieves identical bytes must produce an
      # identical output and therefore cut off early.
      writeFile(outPath & ".evidence",
        "url=" & retrieved.url & "\nintegrity=" & retrieved.integrity & "\n")
      result.stdout = retrieved.integrity & " " & retrieved.url
    except CatchableError as err:
      result.status = asFailed
      result.exitCode = 1
      result.stderr = err.msg
  )

  let weakHex = req.solveInputsDigestHex()
  let pathSetRoot = req.solvePathSetRoot()

  registerSolveLockExecutor(proc(action: BuildAction): ActionResult
      {.gcsafe.} =
    result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
      launched: true, runQuotaBackend: "solve-lock")
    lastPathSetHitIndex = -1
    lastPathSet = SolvePathSet(observations: @[])
    try:
      # `solve` reaches clingo through a `{.dynlib.}` FFI and is not marked
      # gcsafe. The cast is narrowed to this statement and is sound for the
      # reason the engine's own scheduler relies on: the executor hooks are
      # per-thread (`{.threadvar.}`), and the generation wave runs at
      # `maxParallelism = 1`, so no second thread is inside the solver while
      # this one is.
      {.cast(gcsafe).}:
        let outPath = action.outputs[0]
        createDir(parentDir(outPath))

        # ---- Phase 2 (§5.7): replay the recorded path sets ----------------
        #
        # This runs INSIDE the solve edge rather than in place of it, and the
        # ordering is what makes it correct: the metadata-fetch edges upstream
        # have already run, so `objectPath` holds LIVE metadata and the
        # amendment's "tried in order against live metadata" is literally what
        # happens. A lookup performed before the fetch would be replaying the
        # recorded filter against the state that produced it.
        var livePaths = initTable[string, string]()
        for entry in plan:
          livePaths[observationLocator(entry.kind, entry.subject)] =
            entry.objectPath
        let lookup = lookupPathSet(pathSetRoot, weakHex, livePaths)
        if lookup.hit:
          writeFile(outPath, lookup.lockDocument)
          lastPathSetHitIndex = lookup.index
          lastPathSet = parsePathSet(
            readFile(pathSetDir(pathSetRoot, weakHex) /
              (align($lookup.index, 4, '0') & ".pathset")))
          result.stdout = "solve-lock: path-set hit #" & $lookup.index &
            " after " & $lookup.candidatesTried & " candidate(s)"
          return

        # ---- The solve ----------------------------------------------------
        let packages = mergeFetchedVersions(req, plan)
        let preference = versionPreferenceOf(req.strategy)
        inc solveExecutionCount
        let sol = solve(req.variants, packages, preference)
        let document = renderLockDocument(req, sol, plan)
        writeFile(outPath, document)

        # ---- Record what the solve consulted ------------------------------
        #
        # The intervals come from the SOLVER (it knows the selection, the
        # ranges it searched and, since NLF-M9, which instances anything
        # selected). The path set pairs them with the objects wave 1 actually
        # retrieved, so the recorded fact is over what was read rather than
        # over what was declared.
        let intervals = deriveConsultedIntervals(packages, sol, preference)
        var byPackage = initTable[string, ConsultedInterval]()
        for iv in intervals:
          byPackage[iv.packageName] = iv
        var ps = SolvePathSet(observations: @[])
        for entry in plan:
          if not fileExists(entry.objectPath):
            continue
          if entry.kind == mokVersionList:
            # A version list for a package the solve did not consult —
            # unselected, pinned, or absent from the graph — contributes NO
            # observation. That is §5.7's whole claim, and NLF-M9 is what makes
            # it statable: the metadata was fetched (over-approximation) and
            # then not consulted, so keying on it would over-invalidate on a
            # publication that cannot move the answer.
            if not byPackage.hasKey(entry.packageName):
              continue
            ps.observations.add(observeObject(entry.kind, entry.subject,
              entry.objectPath, byPackage[entry.packageName]))
          else:
            # A document kind is read whole. `observeObject` classifies it and
            # ignores the interval it is handed, so passing an empty one is
            # honest rather than a placeholder.
            ps.observations.add(observeObject(entry.kind, entry.subject,
              entry.objectPath, ConsultedInterval(kind: mfRaw)))
        lastPathSet = ps
        lastPathSetHitIndex = -1
        discard recordPathSet(pathSetRoot, weakHex, ps, document)
        result.stdout = "solve-lock: solved; recorded " &
          $ps.observations.len & " observation(s)"
    except CatchableError as err:
      result.status = asFailed
      result.exitCode = 1
      result.stderr = err.msg
  )

proc clearGenerationExecutors*() =
  clearMetadataFetchExecutor()
  clearSolveLockExecutor()

proc strategyEffectivenessReport*(req: LockGenerationRequest): string =
  ## `""` when the requested strategy had something to decide; otherwise a
  ## diagnostic saying it did not.
  ##
  ## NLF-M6's third folded criterion, quoted because the wording is the
  ## requirement: NLF-M5 found `--strategy` "accepted, printed in the run
  ## summary, and silently inert on every project in this workspace, because
  ## none configures a registry. The fix landed; the *class* has not been
  ## closed. A test must assert that a strategy with no candidate universe to
  ## narrow is **reported**, not accepted quietly."
  ##
  ## "Something to decide" is measured, not assumed: it is whether ANY
  ## non-pinned package's consulted candidate universe holds more than one
  ## version, AFTER the fetch. A universe of one is a universe a selection rule
  ## cannot rank; a universe of none is worse. Both are the state in which a
  ## user who asked for `lowest` gets whatever `default` would have produced,
  ## and gets it silently.
  ##
  ## Deliberately measured over the CONSULTED universe rather than over the
  ## request, because the defect NLF-M5 hit was exactly the gap between the two:
  ## the strategy was a live field on a request that then had no candidates for
  ## it to act on.
  ##
  ## `lsDefault` reports nothing. It is not a narrowing rule, so "it could not
  ## narrow anything" is not a claim about it — and a warning on every default
  ## invocation would be noise that trains readers to ignore the real one.
  if req.strategy == lsDefault:
    return ""
  let packages = mergeFetchedVersions(req, req.fetchPlan())
  var rankable = 0
  var singletons: seq[string] = @[]
  for p in packages:
    if p.pinned: continue
    if p.versions.len > 1:
      inc rankable
    else:
      singletons.add(p.name & "(" & $p.versions.len & ")")
  if rankable > 0:
    return ""
  singletons.sort()
  result = "strategy '" & $req.strategy & "' had no candidate universe to " &
    "rank: no unpinned package offers more than one version"
  if req.endpoints.len == 0:
    result.add("; no registry is configured, so the declared versions are " &
      "the whole universe")
  if singletons.len > 0:
    result.add(" [" & singletons.join(", ") & "]")

# ---------------------------------------------------------------------------
# The one path
# ---------------------------------------------------------------------------

proc generateLock*(req: LockGenerationRequest): LockGenerationResult =
  ## Run the first expansion wave and return its rule-set artifact.
  ##
  ## THE one path. All four entry points below are this call with a different
  ## `entryPoint` tag and a different destination; nothing else about them
  ## differs, which is what makes §5.4's "Identity is automatic" a fact about
  ## the code rather than an aspiration.
  if req.workDir.len == 0:
    raise newException(ValueError,
      "lock generation requires a workDir for the wave's artifacts")
  if req.platform.len == 0:
    raise newException(ValueError,
      "lock generation requires a platform; a solved graph is solved FOR one")
  createDir(req.workDir)
  createDir(req.workDir / "metadata")
  let before = metadataFetchAttempts()
  let solvesBefore = solveExecutions()
  # Reset the out-of-band executor channel BEFORE the build, not after. The
  # engine's own action cache may serve the solve edge without calling the
  # executor at all (same weak fingerprint, unchanged file inputs), and a
  # leftover value from an earlier generation in the same process would then be
  # reported as this one's.
  lastPathSetHitIndex = -1
  lastPathSet = SolvePathSet(observations: @[])

  # Wave expansion, under the engine's explicit-wave driver. The expander
  # returns nothing: §5.6's generation expansion is closed after one wave BY
  # CONSTRUCTION (over-approximate the fetch, then solve), and running it
  # through the real driver under a bound of 2 is what turns that from a claim
  # into a checked property — a future edit that made the fetch a fixpoint
  # would raise `WaveExpansionBoundExceeded` here rather than quietly costing a
  # second round-trip.
  let expansion = expandGraphInWaves(generationWaveOne(req),
    proc(previousWave: seq[BuildAction]): seq[BuildAction] = @[],
    maxWaves = MaxGenerationWaves)

  installGenerationExecutors(req)
  try:
    var cfg = defaultBuildEngineConfig(req.workDir / "cache")
    cfg.maxParallelism = 1
    cfg.bypassRunQuota = true
    cfg.deferLocalOutputBlobs = false
    let outcome = runBuild(graph(expansion.allActions()), cfg)
    for res in outcome.results:
      if res.status == asFailed:
        raise newException(BuildEngineError,
          "lock generation edge '" & res.id & "' failed: " & res.stderr)
  finally:
    clearGenerationExecutors()

  let lockPath = req.generatedLockPath()
  if not fileExists(lockPath):
    raise newException(BuildEngineError,
      "lock generation produced no lock at " & lockPath)
  let document = readFile(lockPath)

  var waves: seq[seq[string]] = @[]
  for wave in expansion.waves:
    var ids: seq[string] = @[]
    for a in wave:
      if a.kind == bakMetadataFetch: ids.add(a.id)
    if ids.len > 0: waves.add(ids)

  let weakHex = hexOf(weakFingerprintFromText(canonicalSolveInputs(req)))
  LockGenerationResult(
    entryPoint: req.entryPoint,
    lockDocument: document,
    lockIdentity: lockIdentityOf(parseLockedDependencies(document)),
    solveWeakFingerprint: weakHex,
    fetchWaves: waves,
    fetchAttempts: metadataFetchAttempts() - before,
    lockPath: lockPath,
    solveExecuted: solveExecutions() > solvesBefore,
    pathSetHitIndex: lastPathSetHitIndex,
    pathSetsRecorded: recordedPathSetCount(req.solvePathSetRoot(), weakHex),
    pathSet: lastPathSet,
    strategyReport: strategyEffectivenessReport(req))

# ---------------------------------------------------------------------------
# The four doors
# ---------------------------------------------------------------------------

proc withCertificatePolicy(req: LockGenerationRequest; document: string):
    string =
  ## Test-Certificates TC-9b: `document` with the request's policy snapshot
  ## recorded, when the request records one. Applied to the finished document
  ## rather than inside the solve edge, so a solve served from a recorded path
  ## set (§5.7) records the CURRENT policy too, and the lock identity -- which
  ## the policy is not part of -- is untouched.
  if not req.recordCertificatePolicy:
    return document
  var ld = parseLockedDependencies(document)
  ld.certificatePolicySection = req.certificatePolicySection
  serializeLockedDependencies(ld)

proc landLockDocument(writeTo, document: string) =
  ## Write the committed lock only when its bytes change, so a refresh that
  ## finds nothing new leaves the file -- and its mtime -- alone.
  if fileExists(writeTo):
    try:
      if readFile(writeTo) == document:
        return
    except IOError:
      discard
  createDir(parentDir(writeTo))
  writeFile(writeTo, document)

proc runLockSolve*(req: LockGenerationRequest; writeTo: string):
    LockGenerationResult =
  ## `repro lock solve [--write]` — generate, then land the lock at the
  ## committed path when one is given.
  var r = req
  r.entryPoint = lgeLockSolve
  result = generateLock(r)
  result.lockDocument = withCertificatePolicy(r, result.lockDocument)
  if writeTo.len > 0:
    landLockDocument(writeTo, result.lockDocument)
    result.lockPath = writeTo

proc runImplicitBuildSolve*(req: LockGenerationRequest):
    LockGenerationResult =
  ## The implicit solve `repro build` performs when no lock is present —
  ## "ordinary commands solve implicitly when no lock is present". The lock
  ## stays where the wave produced it; the build consumes the solved graph.
  var r = req
  r.entryPoint = lgeImplicitBuildSolve
  generateLock(r)

proc runStrategyHiddenLock*(req: LockGenerationRequest;
                            strategy: LockStrategy): LockGenerationResult =
  ## `repro test --strategy <s>` — §5.4: "generate a lock file under the given
  ## strategy into a **hidden, uncommitted** location, then use it. Nothing
  ## else."
  ##
  ## It NEVER writes back, and that is a decision §5.5 records rather than an
  ## omission here: "a strategy-produced graph is an experiment, not the
  ## project's intended state. Under `lowest` a write-back would downgrade the
  ## whole project as a side effect of running a test."
  var r = req
  r.entryPoint = lgeStrategyHiddenLock
  r.strategy = strategy
  generateLock(r)

proc runLockRefresh*(req: LockGenerationRequest; writeTo: string):
    LockGenerationResult =
  ## `repro lock refresh` — re-solve and re-pin.
  ##
  ## A refresh must RE-SOLVE, never re-affirm; the request handed here must
  ## therefore carry the recipe's own constraints and not the incumbent lock's
  ## pins. That is the caller's obligation (the CLI already strips
  ## `REPRO_LOCK_PINS` for its provider probe, NLF-M3), and it is stated here
  ## because a refresh that inherited the pins would be a fixed point that
  ## looks like a successful refresh.
  var r = req
  r.entryPoint = lgeLockRefresh
  result = generateLock(r)
  result.lockDocument = withCertificatePolicy(r, result.lockDocument)
  if writeTo.len > 0:
    landLockDocument(writeTo, result.lockDocument)
    result.lockPath = writeTo

# ---------------------------------------------------------------------------
# The targeted re-pin (`repro lock refresh --repin=<package>[,<package>…]`)
# ---------------------------------------------------------------------------
#
# `Locking-And-Solver.md` §"Targeted re-pin", settled by reprobuild-pm issue
# 2026-10-14 ("declaring a sibling producer imports its toolchain floor into
# the consumer's committed-lock solve"). A NEW constraint — a `uses:` added to
# the project or to a sibling it consumes after the lock was written — makes
# the committed lock contradict the recipe, and the build refuses. Admitting
# one new floor by re-solving the whole lock re-solves every version pin and
# every sibling revision pin and publishes the result; the issue records the
# narrow alternative being performed BY HAND three times in one lock. This is
# that narrow alternative, done by the tool that owns the file.
#
# Three pieces, each a library proc so the rules are testable without a CLI:
#
#   * `holdCommittedPins` turns every committed version and variant value,
#     except the named packages', into a HARD pin on the request — the same
#     pins a build applies — after checking that none of them contradicts a
#     declared range (a held pin that does is reported, never widened);
#   * the solve runs exactly as a full refresh's does (`generateLock`);
#   * `mergeRepinnedLock` writes back ONLY what the spec allows to move: the
#     named packages' entries, and additions for packages the committed lock
#     does not record.

proc repinVariantConflict(lockDescription, name, value: string;
                          decl: VariantDecl): string =
  ## A held variant value outside the universe the recipe now declares. The
  ## build refuses the same lock with the same finding
  ## (`variants.lockedValueFor`); without this check the held value would
  ## reach the solve as a fact and come back as an unexplained UNSAT.
  "the " & lockDescription & " pins variant '" & name & "' to '" & value &
    "', which is outside the values the recipe now declares for it" &
    (if decl.kind == vkBool: " (true, false)"
     else: " (" & decl.allowedValues.join(", ") & ")") &
    ". `repro lock refresh --repin` holds every variant the lock records; " &
    "re-solve it with a full `repro lock refresh`."

proc heldVariantFits(decl: VariantDecl; value: string): bool =
  case decl.kind
  of vkBool: value in ["true", "false"]
  else: decl.allowedValues.len == 0 or value in decl.allowedValues

proc holdVariant(v: var VariantDecl; pins: LockPins;
                 lockDescription: string) =
  ## Hold ``v`` at the value the committed lock records, if it records one
  ## and nothing (a develop sibling's own pin) already decided it.
  if v.pinnedValue.len > 0 or v.name notin pins.variants: return
  let value = pins.variants[v.name]
  if not heldVariantFits(v, value):
    raise newException(ELockConflict,
      repinVariantConflict(lockDescription, v.name, value, v))
  v.pinnedValue = value

proc holdCommittedPins*(req: var LockGenerationRequest;
                        committed: LockedDependencies;
                        repin: openArray[string];
                        lockPath: string;
                        crossRepoProducer: proc (pkg: string): bool) =
  ## Pin every package version and variant value ``committed`` records, other
  ## than the packages named in ``repin``, onto ``req`` as hard pins, so the
  ## solve answers only for the named packages (and for packages the lock does
  ## not record at all, which have no pin to hold).
  ##
  ## Raises ``ELockConflict`` — the build's own diagnostic, rendered by the
  ## same `lockConflictDiagnostic` — when a held version contradicts an
  ## unconditional declared range, and for a held variant value outside its
  ## declared universe. Spec: "When a held pin also contradicts a declared
  ## range, the re-pin fails with that pin's `ELockConflict`, writes nothing,
  ## and the caller adds the package to `--repin`. The flag never silently
  ## re-solves a package it does not name."
  ##
  ## The checks mirror the build's (`variants.assertLockedVersionsSatisfy
  ## DeclaredRanges`): only UNCONDITIONAL edges bind (a gated arm may be off
  ## precisely because of the pin), a package whose version is already OBSERVED
  ## (a develop checkout, `pinned` on arrival) is neither checked nor
  ## re-pinned (develop overrides layer above the lock), and a side that is
  ## not semver-shaped proves nothing.
  ##
  ## ``crossRepoProducer`` answers whether a declaring package is another
  ## repository's, for the diagnostic only.
  let solution = lockToSolution(solvedPartOf(committed))
  var pins = initLockPins()
  pins.packages = solution.packages
  pins.variants = solution.variants
  pins.lockPath = lockPath
  let lockDescription = lockSourceDescription(pins)
  var observed: seq[string] = @[]
  for decl in req.packages:
    if decl.pinned: observed.add(decl.name)
  # Sorted so that, of several conflicts, the one reported does not depend on
  # the fold's arrival order.
  var order: seq[(string, int)] = @[]
  for i in 0 ..< req.packages.len: order.add((req.packages[i].name, i))
  order.sort()
  for (_, i) in order:
    let decl = req.packages[i]
    for dep in decl.depends:
      if dep.conditional.isSome: continue
      if dep.name in repin or dep.name in observed: continue
      if dep.name notin pins.packages: continue
      let locked = pins.packages[dep.name]
      var satisfied = true
      try:
        satisfied = satisfies(parseSemver(locked), parseSemverRange(dep.range))
      except ESemverParse:
        continue
      if not satisfied:
        raise newException(ELockConflict, lockConflictDiagnostic(
          lockDescription, dep.name, locked, decl.name, dep.range,
          declarerRecorded = pins.lockRecordsPackage(decl.name),
          crossRepoProducer = crossRepoProducer(decl.name)))
  for v in req.variants.mitems: holdVariant(v, pins, lockDescription)
  for decl in req.packages.mitems:
    for v in decl.variants.mitems: holdVariant(v, pins, lockDescription)
    if decl.pinned or decl.name in repin: continue
    if decl.name notin pins.packages: continue
    decl.pinned = true
    decl.versions = @[pins.packages[decl.name]]

proc isLiftedPackageDep(d: LockedDep): bool =
  ## A `deps` entry the MO-11 lift derived from a solved PACKAGE (store or
  ## registry coordinates), as opposed to a repository the lock pins.
  d.coordinates.kind in {ckStore, ckRegistry}

proc mergeRepinnedLock*(committed, generated: LockedDependencies;
                        repin: openArray[string]): LockedDependencies =
  ## The lock a targeted re-pin writes: ``committed`` with only the changes
  ## `Locking-And-Solver.md` §"Targeted re-pin" permits taken from
  ## ``generated`` (the pinned solve's output).
  ##
  ##   * ``packages``: a named package's entry is the generated one; a package
  ##     the committed lock does not record is ADDED; every other committed
  ##     entry is kept verbatim — never changed, never removed, even when the
  ##     current solve no longer has it.
  ##   * ``variants``: kept verbatim (they were held); a variant the committed
  ##     lock does not record is added.
  ##   * ``deps``: carried forward. Two exceptions, both derived from entries
  ##     the re-pin is allowed to write: the lifted store/registry entry of a
  ##     re-pinned or added package follows that package, and the ROOT's own
  ##     entry (``path = "."``) is the freshly observed one. The root entry is
  ##     not a sibling revision pin: it records the revision of the tree the
  ##     lock was solved from, which this solve has just re-read, and keeping a
  ##     stale one would make `repro lock validate` refuse the lock for source
  ##     drift the re-pin itself observed. Every sibling revision pin the
  ##     committed lock records is carried byte-for-byte; a sibling it does NOT
  ##     record is ADDED from the solve, by the same rule as a package. That is
  ##     the issue's own case: a newly declared producer has no revision pin to
  ##     hold, and leaving it out would write a lock whose lock-pinned mode
  ##     cannot fetch the producer whose floor the re-pin just admitted.
  ##   * ``inputsDigest`` / ``optimal``: the generated ones — they describe the
  ##     solve that produced the written lock, and a digest of the OLD inputs
  ##     would mark the lock stale against the recipe it was just solved from.
  ##   * the certificate-policy snapshot and ``platform``: the committed ones.
  result = committed
  result.inputsDigest = generated.inputsDigest
  result.optimal = generated.optimal
  var changed: seq[string] = @[]
  var committedNames: seq[string] = @[]
  for p in committed.packages: committedNames.add(p.name)
  result.packages = @[]
  for p in committed.packages:
    if p.name notin repin:
      result.packages.add(p)
      continue
    for g in generated.packages:
      if g.name == p.name:
        result.packages.add(g)
        changed.add(g.name)
        break
  for g in generated.packages:
    if g.name notin committedNames:
      result.packages.add(g)
      changed.add(g.name)
  result.packages.sort(proc (a, b: LockedPackage): int = cmp(a.name, b.name))
  var committedVariants: seq[string] = @[]
  for v in committed.variants: committedVariants.add(v.name)
  for g in generated.variants:
    if g.name notin committedVariants:
      result.variants.add(g)
  result.variants.sort(proc (a, b: LockedVariant): int = cmp(a.name, b.name))
  result.deps = @[]
  for d in committed.deps:
    if isSelfLockedDep(d):
      var fresh = d
      for g in generated.deps:
        if isSelfLockedDep(g): fresh = g
      result.deps.add(fresh)
    elif isLiftedPackageDep(d) and d.name in changed:
      for g in generated.deps:
        if isLiftedPackageDep(g) and g.name == d.name:
          result.deps.add(g)
          break
    else:
      result.deps.add(d)
  for g in generated.deps:
    if isLiftedPackageDep(g):
      if g.name notin changed: continue
      var present = false
      for d in result.deps:
        if isLiftedPackageDep(d) and d.name == g.name: present = true
      if not present: result.deps.add(g)
    else:
      # A repository pin is matched by NAME — the identity a lock records,
      # unique in `deps` — OR by where THIS machine has it checked out:
      # either one already recorded means the committed lock pins that
      # sibling, and its entry was carried above (or, for the root,
      # refreshed). The location is never one a lock recorded: the committed
      # entries are placed locally by the caller (`parseLockedDepsAt`) and
      # the generated ones were observed by this run, so a sibling the
      # committed lock names one way and this machine observed under another
      # name is still one checkout. Matching against the entries written so
      # far rather than the committed ones also keeps a sibling the solve
      # lists twice from being added twice.
      var present = false
      for d in result.deps:
        if not isLiftedPackageDep(d) and (d.name == g.name or
            (g.path.len > 0 and d.path == g.path)):
          present = true
      if not present: result.deps.add(g)

proc runLockRepin*(req: LockGenerationRequest;
                   committed: LockedDependencies;
                   repin: openArray[string]; writeTo: string):
    LockGenerationResult =
  ## `repro lock refresh --repin=<package>[,<package>…]`: generate through the
  ## same one path every door uses, from a request whose unnamed pins the
  ## caller has already held (`holdCommittedPins`), then write the merged
  ## lock (`mergeRepinnedLock`).
  ##
  ## The certificate-policy snapshot is CARRIED, not re-evaluated: the spec
  ## carries it forward unchanged, so ``req.recordCertificatePolicy`` is
  ## ignored here.
  var r = req
  r.entryPoint = lgeLockRefresh
  r.recordCertificatePolicy = false
  result = generateLock(r)
  let merged = mergeRepinnedLock(committed,
    parseLockedDependencies(result.lockDocument), repin)
  result.lockDocument = serializeLockedDependencies(merged)
  result.lockIdentity = lockIdentityOf(merged)
  if writeTo.len > 0:
    landLockDocument(writeTo, result.lockDocument)
    result.lockPath = writeTo

# ---------------------------------------------------------------------------
# The pinned path
# ---------------------------------------------------------------------------

type
  SolvedGraphSource* = enum
    ## Where a build's solved graph came from.
    sgsPinnedLock = "pinned-lock"
    sgsGenerated = "generated"
    sgsNone = "none"

  ResolvedSolvedGraph* = object
    solution*: UnifiedSolution
    source*: SolvedGraphSource
    lockPath*: string
    identity*: LockIdentity

proc resolveSolvedGraph*(lockPath: string;
                         req: LockGenerationRequest): ResolvedSolvedGraph =
  ## The chokepoint a build goes through to obtain its solved graph.
  ##
  ## `Repository-And-Index-Format.md` §"Refresh Is Performed By Graph Edges":
  ## "**A pinned build refreshes nothing.** A lock file pins the *result* of
  ## these fetches. Once pinned, a build consumes the lock and evaluates no
  ## metadata-fetch edge, so a `repro build` against a committed lock must
  ## succeed with the network unavailable."
  ##
  ## The lock check comes FIRST and returns, so the generation wave — and with
  ## it every `netFetch` edge — is not merely skipped at run time but never
  ## constructed. Corpus case NLF-GEN-7 asserts the counter, not the exit
  ## code, precisely because "the build succeeded" is satisfied by an
  ## implementation that fetched and then ignored the result.
  if lockPath.len > 0 and fileExists(lockPath):
    let ld = parseLockedDependencies(readFile(lockPath))
    return ResolvedSolvedGraph(
      solution: lockToSolution(solvedPartOf(ld)),
      source: sgsPinnedLock,
      lockPath: lockPath,
      identity: lockIdentityOf(ld))
  if req.packages.len == 0 and req.variants.len == 0:
    return ResolvedSolvedGraph(
      solution: UnifiedSolution(variants: initTable[string, string](),
                                packages: initTable[string, string](),
                                optimal: false),
      source: sgsNone, lockPath: lockPath,
      identity: emptySolvedGraphIdentity(req.platform))
  let generated = runImplicitBuildSolve(req)
  let ld = parseLockedDependencies(generated.lockDocument)
  ResolvedSolvedGraph(
    solution: lockToSolution(solvedPartOf(ld)),
    source: sgsGenerated,
    lockPath: generated.lockPath,
    identity: generated.lockIdentity)
