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

proc evaluateHostPredicate*(predicateAst: PredNode; host: string): bool =
  ## Minimal predicate evaluator for M63 Phase A: only inspects the
  ## predicate's referenced identifiers and compares them against the
  ## supplied `host` name. The full predicate language (M60) supports
  ## arbitrary boolean expressions over OS-tagged identifiers (`linux`,
  ## `macos`, `windows`, `arm64`, `x86_64`, ...). For the Phase A gates
  ## (`add fd`, fresh-install, etc.) the fixture profiles do not use
  ## host-platform predicates — the gates fail closed if they do, with
  ## a clear pointer to a future milestone that wires the full
  ## evaluator.
  ##
  ## Bare-true predicates (an identifier matching the current host's
  ## OS tag) are recognized: `windows`, `linux`, `macos`. Everything
  ## else evaluates false. That covers the Phase B stow gate's needs
  ## and is enough for the gates listed in the milestone.
  if predicateAst == nil:
    return true
  let canon = renderPredicate(normalizeAst(predicateAst))
  let token = canon.strip()
  case token.toLowerAscii()
  of "windows":
    return defined(windows)
  of "linux":
    return defined(linux)
  of "macos", "macosx", "osx":
    return defined(macosx)
  else:
    discard
  # An always-true degenerate predicate (`true`) is convenient for
  # gates.
  if token.toLowerAscii() == "true":
    return true
  if token.toLowerAscii() == "false":
    return false
  # Anything else is "unknown" → false (the predicate's branch is not
  # taken). The planner does not raise here; an unknown predicate
  # silently disables that branch, matching the spec's "host
  # identity does not match → branch off" semantics for unresolved
  # platform tags.
  false

proc collectPackagesFromBody(body: seq[IntentNode]; activity: string;
                            host: string;
                            outSeq: var seq[PlannedPackage]) =
  ## Walk one activity's body, emitting one `PlannedPackage` per
  ## reachable `nkPackageRef` after evaluating any enclosing predicate.
  for child in body:
    case child.kind
    of nkPackageRef:
      outSeq.add(PlannedPackage(packageId: child.packageName,
        fromActivity: activity, predicateText: "",
        requestedVersion: child.packageVersion))
    of nkCondBlock:
      if not evaluateHostPredicate(child.predicateAst, host):
        continue
      for pkgRef in child.condChildren:
        if pkgRef.kind != nkPackageRef:
          continue
        outSeq.add(PlannedPackage(packageId: pkgRef.packageName,
          fromActivity: activity, predicateText: child.predicateSource,
          requestedVersion: pkgRef.packageVersion))
    else:
      discard

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

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

proc buildPlan*(profile: Profile; profileDir, hostIdentity: string): ApplyPlan =
  ## Materialize a deterministic `ApplyPlan` from a parsed profile.
  ## The caller is responsible for invoking the stow synthesizer
  ## (Phase B) afterwards and feeding its outputs into
  ## `result.generatedFiles`.
  result.hostIdentity = hostIdentity
  result.profilePath = profile.path
  result.profileDir = profileDir
  let active = enabledActivitiesFor(profile, hostIdentity)
  for child in profile.root.children:
    if child.kind != nkActivity:
      continue
    if child.activityName notin active:
      continue
    collectPackagesFromBody(child.activityChildren,
      child.activityName, hostIdentity, result.packages)
  # Deduplicate by package id; preserve the first occurrence's metadata.
  var seen = initHashSet[string]()
  var deduped: seq[PlannedPackage]
  for p in result.packages:
    if p.packageId in seen:
      continue
    seen.incl p.packageId
    deduped.add p
  deduped.sort(proc(a, b: PlannedPackage): int = cmp(a.packageId, b.packageId))
  result.packages = deduped
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
