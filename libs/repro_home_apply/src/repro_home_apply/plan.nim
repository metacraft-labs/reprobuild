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
import repro_profile/concerns

import ./errors
import ./package_catalog

type
  PlannedPackage* = object
    ## One realized-package request. The package id is the raw name
    ## as it appeared in the profile; resolution (GM4b:
    ## `package_catalog.resolveProfilePackage`) happens in `./realize.nim`.
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
                                       ## the `path` realization kind (the
                                       ## host's PATH) when the
                                       ## package name doesn't match the
                                       ## binary name. Empty seq preserves
                                       ## pre-2026-06 behavior: the adapter
                                       ## probes the package id itself.
                                       ## When the selection places an
                                       ## application, every name must be
                                       ## a command the record declares,
                                       ## or the apply is refused
                                       ## (`pipeline.addApplicationCommands`).

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
    ## A user-visible command this profile exports. Every installed
    ## package contributes one launcher named after its package id
    ## (``buildPlan``). An application package additionally contributes
    ## one launcher per command its realization declares
    ## (``extraExecutable`` on an ``app-bundle`` record), added once the
    ## references are resolved (``pipeline.addApplicationCommands``).
    commandName*: string
    fromPackageId*: string
    executableRelPath*: string
      ## The executable this launcher runs, relative to the realized
      ## prefix (``Visual Studio Code.app/Contents/Resources/app/bin/code``).
      ## "" runs the package's resolved executable (``executablePath``).

  EPlanCycleDetected* = object of CatchableError
    ## The exported topological-sort utility found a cycle in its caller's
    ## dependency graph. Carries the packages that could not be ordered.
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
      ## The profile's selection policy (GM4b), copied through from the
      ## parsed `Profile.adapterPreference`. Keys are canonical OS tags
      ## (`"windows"`, `"linux"`, `"darwin"`); values are the ordered
      ## realization kinds (`tarball` — `builtin` is its former spelling —
      ## `nix`, `scoop`, `path`). Empty table when the profile carries no
      ## `adapterPreference:` block — resolution then uses
      ## `DefaultSelectionPolicy`, the same on every platform.
    catalogImports*: seq[string]
      ## The contribution catalogs the profile's `catalogs:` section
      ## imports (profile-relative module paths), copied through from
      ## `Profile.catalogImports` for the resolution context
      ## (`catalog_projection`).
    ## Order: packages by `packageId`, generated files by
    ## `(absoluteOutputPath, sourceKind, contributingPackage)`, launchers
    ## by `commandName`. The planner enforces this; `compareEqual`
    ## confirms it.

# ---------------------------------------------------------------------------
# Activity expansion
# ---------------------------------------------------------------------------

proc declaredHosts*(profile: Profile): seq[string] =
  ## The hosts the profile's `hosts:` registry names, in declaration order;
  ## empty for a profile without a registry (or with an empty one).
  let hostsOpt = findHostsBlock(profile)
  if hostsOpt.isNone:
    return
  for entry in hostsOpt.get.hostsEntries:
    result.add entry.hostName

proc enabledActivitiesFor*(profile: Profile; host: string): HashSet[string] =
  ## `default` is always active; `hosts:` adds host-specific ones.
  ##
  ## THE host-selection rule. `buildPlan` applies it, and every other caller
  ## that needs to know which activities a host runs — `repro home list` /
  ## `why`, `repro home export` / `facts` — calls this proc rather than
  ## keeping its own copy, so what they report is what the planner does.
  ##
  ## Undeclared hosts (Gradual-Nix-To-Reprobuild-Migration.md Open question
  ## 6, answered by GM8): a profile that declares a `hosts:` registry
  ## declares every host it may be applied to. A host it does not name is
  ## refused with `EUndeclaredHost` instead of getting `default` alone --
  ## a typo or a new machine must not silently plan a much smaller home
  ## (Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped). The
  ## explicit opt-in for `default` alone is an entry naming only `default`.
  ## A profile with no registry (or an empty one) is host-agnostic and
  ## selects `default` on every host. The Nix reader of the export
  ## (`nix/lib/intent.nix`, `evaluate`) applies the same rule.
  result = initHashSet[string]()
  result.incl "default"
  let declared = declaredHosts(profile)
  if declared.len == 0:
    return
  let hostsOpt = findHostsBlock(profile)
  for entry in hostsOpt.get.hostsEntries:
    if entry.hostName == host:
      for a in entry.hostActivities:
        result.incl a
      return
  var e = newException(EUndeclaredHost, "host `" & host &
    "` is not declared in the profile's hosts: registry (declared: " &
    sorted(declared).join(", ") & "). Add an entry for it -- `\"" & host &
    "\": [default]` selects only the `default` activity, `repro home " &
    "enable <activity> --host " & host & " --no-apply` adds one -- or " &
    "select a declared host with --host / $REPRO_HOST")
  e.step = 1
  e.stepName = "load_intent"
  e.profilePath = profile.path
  e.host = host
  e.declaredHosts = declared
  raise e

type
  AppliedConcerns* = object
    ## The concerns `repro home apply` applies on one host
    ## (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply).
    concerns*: ConcernSet
    declared*: bool
      ## The host's `hosts:` entry declares `applies:`. False: every concern
      ## (the behaviour of a profile without a declaration).

proc appliedConcernsFor*(profile: Profile; host: string): AppliedConcerns =
  ## THE concern-selection rule: the concerns the host's `hosts:` entry lists
  ## under `applies:`, or every concern when it lists none (or the host has
  ## no entry). `repro home apply`, `--plan`, `repro home plan`, the host
  ## facts and the export all call this, so they cannot disagree. A name the
  ## vocabulary does not know raises `ValueError` (the macro and the adapter
  ## already refuse one; this is the last line for a profile that reached
  ## the planner another way).
  result = AppliedConcerns(concerns: AllHomeConcerns, declared: false)
  let hostsOpt = findHostsBlock(profile)
  if hostsOpt.isNone:
    return
  for entry in hostsOpt.get.hostsEntries:
    if entry.hostName == host and entry.hostAppliesDeclared:
      let problem = concernListProblem(entry.hostApplies)
      if problem.len > 0:
        raise newException(ValueError, "hosts entry \"" & host &
          "\": applies: " & problem)
      return AppliedConcerns(concerns: toConcernSet(entry.hostApplies),
        declared: true)

proc describeAppliedConcerns*(applied: AppliedConcerns; host: string): string =
  ## One line for plan / apply output: which concerns are applied and why.
  if not applied.declared:
    "all (hosts entry for " & host & " declares no `applies:`)"
  elif applied.concerns.card == 0:
    "none (hosts." & host & ".applies is empty)"
  else:
    concernNames(applied.concerns).join(", ") & " (hosts." & host &
      ".applies)"

proc evaluateHostPredicate*(predicateAst: PredNode; ctx: HostContext): bool =
  ## Evaluate a profile predicate against the host facts selected for
  ## this apply. For normal local applies `ctx` is the current host; for
  ## M71 Phase B local bundle evaluation it is an explicit target host.
  predicateHolds(predicateAst, ctx)

proc evaluateHostPredicate*(predicateAst: PredNode; host: string): bool =
  ## Compatibility wrapper for older call sites that only provide a
  ## host identity. Platform/arch default to the current build host,
  ## preserving the pre-M71 local behavior.
  var ctx = currentHostContext()
  ctx.host = host
  evaluateHostPredicate(predicateAst, ctx)

type
  OriginState* = enum
    ## Why one package reference of an activity body is, or is not, planned
    ## on a host -- the planner's rule, stated per reference so `repro home
    ## list` / `why` report exactly what `buildPlan` does.
    osPlanned            ## the activity is selected and its guard (if any)
                         ## holds: `buildPlan` plans it
    osActivityNotSelected
                         ## the host's selection does not enable the activity
    osGuardFalse         ## the activity is selected; one of its enclosing
                         ## `when`s (nested guards conjoin) does not hold
                         ## for the host facts

  PackageOrigin* = object
    ## One package reference of an activity body and its `OriginState`.
    packageId*: string
    fromActivity*: string
    predicateText*: string   ## the enclosing guard ("" for none); nested
                             ## guards as `(outer) and (inner)`
    requestedVersion*: string
    binaries*: seq[string]
    state*: OriginState

proc guardText(guards: seq[string]): string =
  ## How an origin names the guards around it: "" for none, the predicate
  ## for one, `(outer) and (inner)` for nested ones (they conjoin).
  if guards.len == 1:
    guards[0]
  else:
    var parts: seq[string]
    for g in guards:
      parts.add "(" & g & ")"
    parts.join(" and ")

proc collectOrigins(body: seq[IntentNode]; activity: string; selected: bool;
                    guards: seq[string]; holds: bool; ctx: HostContext;
                    into: var seq[PackageOrigin]) =
  ## `holds`: every guard in `guards` holds on `ctx` (true for none).
  for child in body:
    case child.kind
    of nkPackageRef:
      into.add PackageOrigin(packageId: child.packageName,
        fromActivity: activity, predicateText: guardText(guards),
        requestedVersion: child.packageVersion,
        binaries: child.packageBinaries,
        state: (if not selected: osActivityNotSelected
                elif holds: osPlanned
                else: osGuardFalse))
    of nkCondBlock:
      # Nested guards conjoin (Home-Profile-Intent-Layer.md §`when` and
      # `if` predicates: "`when` blocks nest"). An inner guard is evaluated
      # only where everything around it holds, as an unselected activity's
      # guards are never evaluated: a guard the planner would not reach
      # cannot fail the plan.
      let inner = holds and selected and
        evaluateHostPredicate(child.predicateAst, ctx)
      collectOrigins(child.condChildren, activity, selected,
        guards & @[child.predicateSource], inner, ctx, into)
    else:
      discard

proc packageOriginsFromBody*(body: seq[IntentNode]; activity: string;
                             selected: bool;
                             ctx: HostContext): seq[PackageOrigin] =
  ## Every package reference of one activity body with its state on the
  ## host `ctx` describes; `selected` is whether the host's selection
  ## (`enabledActivitiesFor`) enables the activity. THE package rule:
  ## `buildPlan` plans exactly the `osPlanned` origins, and `repro home
  ## list` / `why` report all of them, so neither can disagree with the
  ## other. A reference is planned where every `when` around it holds --
  ## nested guards conjoin, at any depth (reprobuild-pm issue
  ## 2026-10-18-home-planner-drops-packages-under-nested-activity-guards;
  ## `nix/lib/intent.nix` `bodyPackages` applies the same rule). A guard is
  ## evaluated only for a selected activity (an unselected one is never
  ## evaluated by the planner either). Elements other than package
  ## references and guard blocks are not package references and are
  ## skipped, as the planner skips them.
  collectOrigins(body, activity, selected, @[], true, ctx, result)

proc collectPackagesFromBody(body: seq[IntentNode]; activity: string;
                            ctx: HostContext;
                            outSeq: var seq[PlannedPackage]) =
  ## Walk one (selected) activity's body, emitting one `PlannedPackage` per
  ## planned reference (`packageOriginsFromBody`).
  for o in packageOriginsFromBody(body, activity, true, ctx):
    if o.state == osPlanned:
      outSeq.add(PlannedPackage(packageId: o.packageId,
        fromActivity: activity, predicateText: o.predicateText,
        requestedVersion: o.requestedVersion,
        binaries: o.binaries))

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Deterministic package ordering and the legacy topological-sort utility
# ---------------------------------------------------------------------------
#
# Installer helpers are dependencies of the common provisioning edge. They
# do not depend on a separately listed home package, its order, or ambient
# discovery. Home packages therefore use alphabetical order. The exported
# Kahn utility remains available to callers supplying their own dependency
# graph, with alphabetical ties and an explicit cycle diagnostic.

type
  ExtractorDepsCallback* =
    proc (p: PlannedPackage): seq[string] {.closure.}
    ## A caller-supplied dependency graph for the exported sort utility.

proc profileExtractorDeps*(target: RealizationTarget; policy: SelectionPolicy):
    ExtractorDepsCallback =
  ## Compatibility callback: home packages have no cross-package extractor
  ## dependencies. Each tarball's provisioning graph realizes its own helpers.
  ## Target/policy remain arguments for callers of the historical API.
  result = proc (p: PlannedPackage): seq[string] = @[]

proc topologicallySortPackages*(packages: seq[PlannedPackage];
                                depsOf: ExtractorDepsCallback):
    seq[PlannedPackage] =
  ## Kahn's algorithm over the caller's package dependency graph.
  ## Ready packages tie alphabetically; dependencies outside the input set
  ## are ignored. Raises EPlanCycleDetected with the unordered participants
  ## if no remaining package can be emitted. Production helper provisioning
  ## uses its own action graph, independently of this compatibility utility.

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
        # archive realizer's discovery will pick the extractor up via PATH
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

proc collectConfigContributions(profile: Profile; ctx: HostContext):
    seq[ConfigContribution] =
  ## The `config:` overrides that apply on `ctx`: a guarded override (GM3)
  ## contributes only where its guard holds (`applicableConfigEntries`).
  for ch in profile.root.children:
    if ch.kind != nkConfigBlock:
      continue
    for pkgNode in applicableConfigPackages(ch, ctx):
      for entry in applicableConfigEntries(pkgNode, ctx):
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
  # GM4b: ``adapterPreference:`` is the profile's selection policy
  # (Provisioning-Contributions.md §"Selection policy"). Copied so the
  # realize + preview call sites build their resolution context without
  # re-loading the profile; an empty table selects the default policy.
  result.adapterPreference = profile.adapterPreference
  result.catalogImports = profile.catalogImports
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
  # Preserve plan-time validation of the target's selection policy. A target
  # the resolver cannot name is still diagnosed by package realization.
  let policyTarget =
    try:
      some(profileRealizationTarget(ctx.platform, ctx.arch, isHost = false))
    except ValueError:
      none(RealizationTarget)
  if policyTarget.isSome:
    discard selectionPolicyFor(profile.adapterPreference, policyTarget.get.os)
  # Helpers belong to each package's provisioning graph, so package ordering
  # needs no profile-level dependency projection.
  result.packages = deduped
  result.packages.sort(proc(a, b: PlannedPackage): int =
    cmp(a.packageId, b.packageId))
  # Phase A: every package contributes one launcher with the same name.
  for p in result.packages:
    result.launchers.add(PlannedLauncher(commandName: p.packageId,
      fromPackageId: p.packageId))
  result.launchers.sort(proc(a, b: PlannedLauncher): int =
    cmp(a.commandName, b.commandName))
  # Harvest `config:` block contributions for the suppression layer.
  result.configContributions = collectConfigContributions(profile, ctx)
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
    # A launcher that runs a declared command rather than the package's
    # executable carries its path after a NUL, which no command name
    # contains, so the encoding stays unambiguous while every pre-existing
    # plan (no such launchers) keeps its bytes and its generation id.
    if l.executableRelPath.len > 0:
      result.addStr(l.commandName & "\0" & l.executableRelPath)
    else:
      result.addStr(l.commandName)
    result.addStr(l.fromPackageId)

proc samePlan*(a, b: ApplyPlan): bool =
  ## Used by tests to confirm two derivations of the same source
  ## profile produce identical plans.
  canonicalPlanBytes(a) == canonicalPlanBytes(b)
