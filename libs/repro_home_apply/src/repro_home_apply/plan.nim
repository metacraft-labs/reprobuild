## Apply-pipeline planner: translates the parsed M60 profile intent
## into a typed `ApplyPlan` that downstream pipeline steps consume.
##
## The planner does NOT perform any side effects. It walks the parsed
## profile, expands the activated activities for the current host,
## evaluates conditional predicates against the host facts, and emits:
##
##   * a deduplicated list of `PlannedPackage` entries
##   * one `PlannedGeneratedFile` per package-driven file output
##   * one `PlannedGeneratedFile` per stow file (Phase B; in Phase A
##     this list is empty unless `discoverStowEntries` is invoked)
##   * a stable per-host-identity ordering so two identical applies
##     produce the same plan bytes and therefore the same generation id
##
## The two-synthesizer split (package outputs in this module, stow walk
## in `./stow.nim`) is deliberate: in Phase A the planner only emits
## package outputs; in Phase B the stow synthesizer feeds additional
## records into the same list and the suppression layer
## (`./suppression.nim`) deduplicates by absolute target path.

import std/[algorithm, options, os, sets, strutils, tables]

import repro_home_intent

import ./errors
import ./package_catalog
import ./catalog_lookup
import repro_dsl_stdlib/packages_schema

type
  PlannedPackage* = object
    ## One realized-package request. The package id is the raw name
    ## as it appeared in the profile; resolution to an adapter happens
    ## in `./realize.nim`.
    packageId*: string
    fromActivity*: string
    predicateText*: string             ## "" when the package appeared
                                       ## directly in the activity body
    requestedVersion*: string          ## M69: the pinned version literal
                                       ## from `package(<id>, "<version>")`,
                                       ## or "" when the reference was bare
                                       ## (defaultVersion will resolve at
                                       ## realize time).
    binaries*: seq[string]             ## 2026-06-09: explicit binary names
                                       ## the package installs, used by
                                       ## the path-based catalog adapter
                                       ## (the Linux fallback) when the
                                       ## package name doesn't match the
                                       ## binary name. Empty seq preserves
                                       ## pre-2026-06 behavior: the adapter
                                       ## probes the package id itself.

  PlannedGeneratedFileSource* = enum
    pgfsPackageOutput = "package-output"
    pgfsStowFile = "stow-file"

  PlannedGeneratedFile* = object
    ## A single file the pipeline plans to write into `$HOME`.
    absoluteOutputPath*: string        ## the live host filesystem path
    relativeHomePath*: string          ## path relative to $HOME (the
                                       ## suppression key — Phase B)
    sourceKind*: PlannedGeneratedFileSource
    contributingPackage*: string       ## "" for stow files
    stowSourcePath*: string            ## absolute path under
                                       ## `<profile-dir>/stow/`; empty
                                       ## when not a stow file
    contentBytes*: seq[byte]           ## the bytes that will be written
                                       ## for `package-output`. For stow
                                       ## files this is the source content
                                       ## (used only for cache-key /
                                       ## drift digests; the live
                                       ## materialization is a link).

  PlannedLauncher* = object
    ## A user-visible command this profile exports. For Phase A every
    ## installed package contributes one launcher named after its
    ## package id (the typical case for the fixture profile).
    commandName*: string
    fromPackageId*: string

  EPlanCycleDetected* = object of CatchableError
    ## M0 (Realize-Layer-Plumbing-Closures spec): the planner's
    ## topological sort over realize ops detected a cycle in the
    ## extractor-discovery graph. Cycles are a catalog-authoring error
    ## (the M0 hard-coded extractor map cannot loop with the current
    ## enum-keyed mapping — discovery of a cycle therefore means a
    ## future schema-driven ``requires_for_realize:`` field has been
    ## mis-authored, OR a test deliberately injected one). The
    ## exception carries the cycle participants so the operator can
    ## name the offending catalog packages directly.
    cycleParticipants*: seq[string]

  ConfigContribution* = object
    ## One `config: <pkg>: <key> = <value>` entry harvested from the
    ## profile. Phase B's suppression layer reads `packageName` and
    ## `configKey` to name "dead config keys" in WStowOverridesShadowed.
    packageName*: string
    configKey*: string
    configValue*: string

  ApplyPlan* = object
    ## The diff-against-current input the rest of the pipeline consumes.
    ## All sequences are sorted into a deterministic order so the
    ## generation-id derivation is stable.
    hostIdentity*: string
    profilePath*: string
    profileDir*: string
    packages*: seq[PlannedPackage]
    generatedFiles*: seq[PlannedGeneratedFile]
    launchers*: seq[PlannedLauncher]
    configContributions*: seq[ConfigContribution]
    diagnostics*: seq[StowDiagnostic]
    adapterPreference*: OrderedTable[string, seq[string]]
      ## M2.5: per-OS adapter preference copied through from the parsed
      ## `Profile.adapterPreference`. Keys are canonical OS tags
      ## (`"windows"`, `"linux"`, `"darwin"`); values are the ordered
      ## adapter chain (each entry drawn from the closed set
      ## `{"builtin", "scoop", "nix", "path"}`). Empty table when the
      ## profile carries no `adapterPreference:` block — realize +
      ## preview then fall back to the M65 platform default chain.
    ## Order: packages by `packageId`, generated files by
    ## `(absoluteOutputPath, sourceKind, contributingPackage)`, launchers
    ## by `commandName`. The planner enforces this; `compareEqual`
    ## confirms it.

# ---------------------------------------------------------------------------
# Activity expansion
# ---------------------------------------------------------------------------

proc enabledActivitiesFor(profile: Profile; host: string): HashSet[string] =
  ## `default` is always active; `hosts:` adds host-specific ones.
  result = initHashSet[string]()
  result.incl "default"
  let hostsOpt = findHostsBlock(profile)
  if hostsOpt.isNone:
    return
  for entry in hostsOpt.get.hostsEntries:
    if entry.hostName == host:
      for a in entry.hostActivities:
        result.incl a

proc evaluateHostPredicate*(predicateAst: PredNode; ctx: HostContext): bool =
  ## Evaluate a profile predicate against the host facts selected for
  ## this apply. For normal local applies `ctx` is the current host; for
  ## M71 Phase B local bundle evaluation it is an explicit target host.
  if predicateAst == nil:
    return true
  evaluateBool(predicateAst, ctx)

proc evaluateHostPredicate*(predicateAst: PredNode; host: string): bool =
  ## Compatibility wrapper for older call sites that only provide a
  ## host identity. Platform/arch default to the current build host,
  ## preserving the pre-M71 local behavior.
  var ctx = currentHostContext()
  ctx.host = host
  evaluateHostPredicate(predicateAst, ctx)

proc collectPackagesFromBody(body: seq[IntentNode]; activity: string;
                            ctx: HostContext;
                            outSeq: var seq[PlannedPackage]) =
  ## Walk one activity's body, emitting one `PlannedPackage` per
  ## reachable `nkPackageRef` after evaluating any enclosing predicate.
  for child in body:
    case child.kind
    of nkPackageRef:
      outSeq.add(PlannedPackage(packageId: child.packageName,
        fromActivity: activity, predicateText: "",
        requestedVersion: child.packageVersion,
        binaries: child.packageBinaries))
    of nkCondBlock:
      if not evaluateHostPredicate(child.predicateAst, ctx):
        continue
      for pkgRef in child.condChildren:
        if pkgRef.kind != nkPackageRef:
          continue
        outSeq.add(PlannedPackage(packageId: pkgRef.packageName,
          fromActivity: activity, predicateText: child.predicateSource,
          requestedVersion: pkgRef.packageVersion,
          binaries: pkgRef.packageBinaries))
    else:
      discard

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# M0 (Realize-Layer-Plumbing-Closures spec) — topological sort over realize ops
# ---------------------------------------------------------------------------
#
# Why topological?
#
# Pre-M0 the planner sorted ``PlannedPackage`` entries alphabetically by
# ``packageId``. That is latent-buggy when a home profile bundles BOTH
# an extractor catalog package and a consumer that needs the extractor
# pre-realized (the M3 bundling-posture decision from the
# Realize-Closure-And-Catalog-Expansion predecessor campaign): the
# alphabetical order may schedule the consumer first, which then fails
# closed because its extractor's prefix does not yet exist on disk.
#
# Concrete example surfaced by the predecessor campaign's M11 LIVE
# smoke: a profile containing both ``package(7zip)`` and
# ``package(lessmsi)`` alphabetically sorts ``7zip`` < ``lessmsi``, but
# ``packages/sevenzip.nim`` uses ``imInstallerMsi`` which needs
# ``lessmsi.exe`` pre-realized OR on PATH. The smoke side-stepped the
# bug by using a single-package profile; M0 closes it for real.
#
# Algorithm: Kahn's topological sort over the discovery graph. For each
# package, ``extractorDependencies`` (in ``./package_catalog.nim``)
# returns the set of catalog-package names that must precede it. If a
# dep packageId is NOT in the plan (the operator didn't bundle the
# extractor; PATH discovery satisfies it), the edge is silently
# dropped — the dep is satisfied externally. Among multiple ready
# packages (no remaining unfulfilled deps), ties break alphabetically.
# This preserves byte-identical output for plans with no extractor
# edges (the M71 reference profile is the load-bearing stability case).
#
# Cycle detection: if any packages remain after Kahn's outer loop
# exhausts the ready queue, the residue is the cycle (or cycles). The
# planner raises ``EPlanCycleDetected`` naming the participants — the
# spec calls cycles a catalog-authoring error so failing closed is
# the right behaviour.

type
  ExtractorDepsCallback* =
    proc (p: PlannedPackage): seq[string] {.closure.}
    ## M0 test seam: callers (production AND the M0 hermetic test gate)
    ## supply a callback computing each package's extractor deps. The
    ## production callback (``defaultExtractorDeps``) looks the package
    ## up in the built-in catalog registry; the test gate can inject a
    ## synthetic dep map to exercise the cycle-detection arm.

proc defaultExtractorDeps*(p: PlannedPackage): seq[string] =
  ## Production extractor-dep resolver: looks ``p`` up in the M65
  ## catalog registry, reads the resolved slice's
  ## ``archive_format`` + ``install_method``, and delegates to
  ## ``extractorDependencies``. Returns ``@[]`` for any package whose
  ## catalog lookup fails (the M0 topo sort then treats the package as
  ## edge-free — Scoop / PATH adapters handle their own extraction;
  ## an unregistered package was already going to fail at realize time
  ## with a clearer diagnostic than a planner-side error here).
  try:
    let slice = lookupCatalogSlice(p.packageId, p.requestedVersion)
    # Synthesize a minimal CatalogResolution carrying just the fields
    # ``extractorDependencies`` reads. The full resolution carries the
    # post-chain adapter; at plan-time we ASSUME cakBuiltin (the M65
    # Windows / Linux defaults' primary). If the operator overrode
    # ``adapterPreference:`` to put cakScoop / cakPath first, the
    # extractor edge is spurious (the consumer realizes via Scoop /
    # PATH and skips the cakBuiltin extractor path) — but the edge
    # only matters when BOTH the consumer AND the extractor are in
    # the plan AND the consumer resolves via cakBuiltin. The
    # plan-time approximation is safe: a spurious edge enforces an
    # ordering that is harmless when the consumer no longer needs it.
    let resolution = CatalogResolution(
      adapter: cakBuiltin,
      archiveFormat: slice.slice.archive_format,
      installMethod: slice.slice.install_method)
    return extractorDependencies(p.packageId, resolution)
  except CatchableError:
    return @[]

proc topologicallySortPackages*(packages: seq[PlannedPackage];
                                depsOf: ExtractorDepsCallback):
    seq[PlannedPackage] =
  ## M0: Kahn's algorithm over the extractor-discovery graph.
  ##
  ## Stability: among packages with no remaining unfulfilled deps,
  ## ties break by alphabetical ``packageId`` — so a plan with no
  ## discovery edges (the M71 reference profile is the canonical
  ## case) sorts byte-identically to the pre-M0 alphabetical order.
  ##
  ## Edges to packageIds NOT in the input ``packages`` set are
  ## silently dropped (the dep is satisfied externally — PATH, Scoop,
  ## or simply already-installed). The spec calls this out
  ## explicitly: "If a dep packageId is NOT in the plan ... the dep
  ## is satisfied externally (PATH) and not modeled as a graph edge".
  ##
  ## Raises ``EPlanCycleDetected`` when a cycle is detected — that
  ## means a catalog-authoring error (or a test deliberately injected
  ## a cycle). The exception's ``cycleParticipants`` lists the
  ## packageIds the algorithm could not schedule.

  # Index of packageId → (input order, package). Input order is used
  # only as a defensive secondary tiebreak; the primary tiebreak is
  # alphabetical so the stability gate against the M71 reference
  # profile holds.
  var byId = initTable[string, PlannedPackage]()
  for p in packages:
    byId[p.packageId] = p

  # Build the dep graph in BOTH directions.
  #   ``unfulfilled[pkg]``   = set of in-plan deps still pending for `pkg`.
  #   ``consumers[extractor]`` = set of packages that depend on `extractor`.
  # We only model edges whose endpoint is ALSO in the input plan; deps
  # pointing outside the plan are dropped (satisfied externally).
  var unfulfilled = initTable[string, HashSet[string]]()
  var consumers = initTable[string, HashSet[string]]()
  for p in packages:
    unfulfilled[p.packageId] = initHashSet[string]()
  for p in packages:
    let deps = depsOf(p)
    for d in deps:
      if d notin byId:
        # External dep — drop the edge silently. The realize loop's
        # cakBuiltin discovery will pick the extractor up via PATH
        # (M3 bundling-posture decision: extractors live on PATH when
        # not bundled in the home profile).
        continue
      if d == p.packageId:
        # Defensive: a self-edge would deadlock Kahn's algorithm.
        # ``extractorDependencies`` already filters self-edges, but
        # double-belt the test-seam callback path.
        continue
      unfulfilled[p.packageId].incl d
      if d notin consumers:
        consumers[d] = initHashSet[string]()
      consumers[d].incl p.packageId

  # Kahn's outer loop. ``ready`` is the set of packages whose
  # unfulfilled-deps set is empty. We re-sort it alphabetically each
  # pass so the output order is deterministic.
  var emitted: seq[PlannedPackage] = @[]
  var remaining = packages.len
  while remaining > 0:
    var ready: seq[string] = @[]
    for id, deps in unfulfilled.pairs:
      if deps.len == 0:
        ready.add(id)
    if ready.len == 0:
      # No ready packages but still entries in ``unfulfilled`` → cycle.
      var cycle: seq[string] = @[]
      for id in unfulfilled.keys:
        cycle.add(id)
      cycle.sort(cmp[string])
      var e = newException(EPlanCycleDetected,
        "plan.nim topological sort detected a cycle in the " &
        "extractor-discovery graph among packages: [" &
        cycle.join(", ") & "]. The M0 extractor-provider map is " &
        "acyclic by construction, so reaching this branch means a " &
        "catalog-authoring error introduced a circular dependency " &
        "(or a hermetic test deliberately injected one).")
      e.cycleParticipants = cycle
      raise e
    ready.sort(cmp[string])
    let pick = ready[0]
    emitted.add(byId[pick])
    unfulfilled.del(pick)
    # Relax every consumer of ``pick``.
    if pick in consumers:
      for c in consumers[pick]:
        if c in unfulfilled:
          unfulfilled[c].excl pick
    dec remaining
  emitted

proc collectConfigContributions(profile: Profile): seq[ConfigContribution] =
  for ch in profile.root.children:
    if ch.kind != nkConfigBlock:
      continue
    for pkgNode in ch.configPackages:
      if pkgNode.kind != nkConfigPackage:
        continue
      for entry in pkgNode.configEntries:
        if entry.kind != nkConfigEntry:
          continue
        result.add(ConfigContribution(
          packageName: pkgNode.configPackageName,
          configKey: entry.configKey,
          configValue: entry.configValueSource))

proc buildPlan*(profile: Profile; profileDir: string;
                ctx: HostContext): ApplyPlan =
  ## Materialize a deterministic `ApplyPlan` from a parsed profile.
  ## The caller is responsible for invoking the stow synthesizer
  ## (Phase B) afterwards and feeding its outputs into
  ## `result.generatedFiles`.
  result.hostIdentity = ctx.host
  result.profilePath = profile.path
  result.profileDir = profileDir
  # M2.5: copy the per-host adapter preference so the realize + preview
  # call sites can honour it without re-loading the profile. An empty
  # `Profile.adapterPreference` (no DSL block) becomes an empty
  # `ApplyPlan.adapterPreference` — the realize/preview helpers then
  # fall back to the M65 platform default chain.
  result.adapterPreference = profile.adapterPreference
  let active = enabledActivitiesFor(profile, ctx.host)
  for child in profile.root.children:
    if child.kind != nkActivity:
      continue
    if child.activityName notin active:
      continue
    collectPackagesFromBody(child.activityChildren,
      child.activityName, ctx, result.packages)
  # Deduplicate by package id; preserve the first occurrence's metadata.
  var seen = initHashSet[string]()
  var deduped: seq[PlannedPackage]
  for p in result.packages:
    if p.packageId in seen:
      continue
    seen.incl p.packageId
    deduped.add p
  # M0 (Realize-Layer-Plumbing-Closures spec): replace the pre-M0
  # alphabetical sort with a topological sort over the
  # extractor-discovery graph. Stability for plans with no extractor
  # edges (the M71 reference profile) is preserved by breaking ties
  # alphabetically inside Kahn's algorithm. See the long comment block
  # above ``topologicallySortPackages`` for the WHY.
  result.packages = topologicallySortPackages(deduped, defaultExtractorDeps)
  # Phase A: every package contributes one launcher with the same name.
  for p in result.packages:
    result.launchers.add(PlannedLauncher(commandName: p.packageId,
      fromPackageId: p.packageId))
  result.launchers.sort(proc(a, b: PlannedLauncher): int =
    cmp(a.commandName, b.commandName))
  # Harvest `config:` block contributions for the suppression layer.
  result.configContributions = collectConfigContributions(profile)
  # `generatedFiles` is empty in Phase A unless a package output
  # synthesizer fills it. The stow synthesizer (Phase B) populates it
  # too; both feed into the same list and the suppression pass
  # deduplicates by `absoluteOutputPath`.

proc buildPlan*(profile: Profile; profileDir, hostIdentity: string): ApplyPlan =
  ## Compatibility entry point: evaluate predicates with current-host
  ## platform/arch facts while using the supplied host identity.
  var ctx = currentHostContext()
  ctx.host = hostIdentity
  buildPlan(profile, profileDir, ctx)

proc canonicalPlanBytes*(plan: ApplyPlan): seq[byte] =
  ## Deterministic byte rendering of the plan, used as one of the
  ## inputs to the generation-id BLAKE3 derivation.
  proc addStr(b: var seq[byte]; s: string) =
    let n = uint32(s.len)
    for k in 0 ..< 4:
      b.add(byte((n shr (k * 8)) and 0xff))
    for ch in s:
      b.add(byte(ord(ch)))
  proc addU32(b: var seq[byte]; n: int) =
    let v = uint32(n)
    for k in 0 ..< 4:
      b.add(byte((v shr (k * 8)) and 0xff))
  result.add(byte('R'))
  result.add(byte('B'))
  result.add(byte('P'))
  result.add(byte('L'))
  result.addStr(plan.hostIdentity)
  result.addStr(plan.profilePath)
  result.addU32(plan.packages.len)
  for p in plan.packages:
    result.addStr(p.packageId)
    result.addStr(p.fromActivity)
    result.addStr(p.predicateText)
    result.addStr(p.requestedVersion)
  result.addU32(plan.generatedFiles.len)
  for g in plan.generatedFiles:
    result.addStr(g.relativeHomePath)
    result.addStr($g.sourceKind)
    result.addStr(g.contributingPackage)
    result.addStr(g.stowSourcePath)
    result.addU32(g.contentBytes.len)
    for b in g.contentBytes:
      result.add(b)
  result.addU32(plan.launchers.len)
  for l in plan.launchers:
    result.addStr(l.commandName)
    result.addStr(l.fromPackageId)

proc samePlan*(a, b: ApplyPlan): bool =
  ## Used by tests to confirm two derivations of the same source
  ## profile produce identical plans.
  canonicalPlanBytes(a) == canonicalPlanBytes(b)
