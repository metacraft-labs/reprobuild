## Effective-configuration resolution for the home profile intent
## layer.
##
## This is a thin function intended as the seam for the M63 apply
## pipeline: it answers "given a parsed profile, this host's activity
## selection, and the host's `default + hosts[host]` activities, which
## packages are enabled and which `config:` overrides apply?"
##
## The intent layer does NOT realize package state; it only tells
## downstream layers which overrides matter and which are inert.
## An override for a package not enabled by any active activity
## resolves to `inert` per the spec:
##
##   A configuration override for a package that is not enabled by any
##   active activity is a no-op. Silently inert.

import std/[sets, tables]

import ./model
import ./predicate

type
  EffectiveConfig* = object
    enabledPackages*: HashSet[string]
    ## Set of package identifiers enabled on this host (union of all
    ## active activities, after `when`/`if` evaluation against
    ## `HostContext`).
    overrides*: OrderedTable[string, OrderedTable[string, string]]
    ## `<package> -> (<configurable> -> <value-source>)`. For every
    ## override declared in `config:` whose package is enabled. Inert
    ## overrides are filtered OUT here; they live in `inertOverrides`.
    inertOverrides*: OrderedTable[string, OrderedTable[string, string]]
    ## Overrides for packages NOT enabled by any active activity. The
    ## spec calls these "silently inert"; the apply pipeline may log
    ## them but must not act on them.
    activeActivities*: HashSet[string]
    ## Activities that contributed packages to this resolution.

# ---------------------------------------------------------------------------
# Guard walkers: the one place that decides which guarded resources and
# config entries a host gets. The planner (`repro_home_apply`), the
# effective-config resolver below, `repro home get` and
# `repro home export --target` all call these.
# ---------------------------------------------------------------------------

proc collectApplicable(nodes: seq[IntentNode]; leaf: NodeKind;
                       ctx: HostContext; userEval: UserPredicateEvaluator;
                       into: var seq[IntentNode]) =
  for node in nodes:
    if node.kind == leaf:
      into.add node
    elif node.kind == nkCondBlock:
      if predicateHolds(node.predicateAst, ctx, userEval):
        collectApplicable(node.condChildren, leaf, ctx, userEval, into)
    else:
      raise newException(ValueError, "internal: unexpected " & $node.kind &
        " where a " & $leaf & " or a guarded block was expected")

proc hasActivityScopedResource*(nodes: seq[IntentNode]): bool =
  ## Whether any `nkResourceEntry` of a `resources:` block body, guarded or
  ## not, belongs to an activity (GM9) -- i.e. whether selecting the
  ## resources needs the host's activity selection at all.
  for node in nodes:
    case node.kind
    of nkResourceEntry:
      if node.resourceActivity.len > 0:
        return true
    of nkCondBlock:
      if hasActivityScopedResource(node.condChildren):
        return true
    else:
      discard
  false

proc applicableResourceEntries*(nodes: seq[IntentNode]; ctx: HostContext;
                                activities: HashSet[string];
                                userEval: UserPredicateEvaluator = nil):
    seq[IntentNode] =
  ## The `nkResourceEntry`s of a `resources:` block body (or of a guarded
  ## block inside one) that apply on `ctx`, in declaration order: an entry
  ## inside an `nkCondBlock` is included only when the guard holds, and an
  ## activity-scoped entry (GM9, `resourceActivity`) only when `activities`
  ## -- the host's enabled activities, `enabledActivitiesFor` in the
  ## planner -- contains its activity. A profile-wide entry ignores
  ## `activities`. The parameter is required, not defaulted, so no caller
  ## can plan an activity-scoped resource without deciding the selection.
  var guarded: seq[IntentNode]
  collectApplicable(nodes, nkResourceEntry, ctx, userEval, guarded)
  for entry in guarded:
    if entry.resourceActivity.len == 0 or
        entry.resourceActivity in activities:
      result.add entry

proc applicableConfigPackages*(cfg: IntentNode; ctx: HostContext;
                               userEval: UserPredicateEvaluator = nil):
    seq[IntentNode] =
  ## The `nkConfigPackage` blocks of a `config:` block that apply on `ctx`,
  ## in declaration order: a package block inside a guard chain around
  ## package blocks is included only when the guard holds. Walk each
  ## result's entries with `applicableConfigEntries`.
  doAssert cfg.kind == nkConfigBlock
  collectApplicable(cfg.configPackages, nkConfigPackage, ctx, userEval,
    result)

proc applicableConfigEntries*(pkg: IntentNode; ctx: HostContext;
                              userEval: UserPredicateEvaluator = nil):
    seq[IntentNode] =
  ## The `nkConfigEntry`s of one `config:` package block that apply on
  ## `ctx`, in declaration order (guarded entries only when the guard
  ## holds).
  doAssert pkg.kind == nkConfigPackage
  collectApplicable(pkg.configEntries, nkConfigEntry, ctx, userEval, result)

type
  ConfigAssignment* = object
    ## The resolved assignment of one `<pkg>.<key>` on a host.
    entry*: IntentNode
      ## The `nkConfigEntry` that wins: the LAST applicable assignment.
    overridden*: seq[IntentNode]
      ## Earlier applicable assignments of the same key, in declaration
      ## order, which `entry` overrides on this host.

proc effectiveConfigAssignments*(profile: Profile; ctx: HostContext;
                                 userEval: UserPredicateEvaluator = nil):
    OrderedTable[string, OrderedTable[string, ConfigAssignment]] =
  ## `<package> -> (<configurable> -> assignment)` for every `config:`
  ## assignment that applies on `ctx`. THE resolution rule for a profile's
  ## config overrides, shared by `resolveEffectiveConfig` and
  ## `repro home get` so they cannot disagree: equal-priority scalar
  ## contributions resolve last-write-wins, per key, across every package
  ## block of the package (Configurable-System.md §Priorities And
  ## Contributions), which is also the order the compiled profile's
  ## `configOverrides` carry. `overridden` lists the shadowed sites, for the
  ## diagnostic the same section asks for.
  for ch in profile.root.children:
    if ch.kind != nkConfigBlock:
      continue
    for pkg in applicableConfigPackages(ch, ctx, userEval):
      let name = pkg.configPackageName
      if name notin result:
        result[name] = initOrderedTable[string, ConfigAssignment]()
      for entry in applicableConfigEntries(pkg, ctx, userEval):
        var assignment = ConfigAssignment(entry: entry)
        if entry.configKey in result[name]:
          let previous = result[name][entry.configKey]
          assignment.overridden = previous.overridden & @[previous.entry]
        result[name][entry.configKey] = assignment

proc walkBody(children: seq[IntentNode]; ctx: HostContext;
              userEval: UserPredicateEvaluator;
              outPkgs: var HashSet[string]) =
  for ch in children:
    case ch.kind
    of nkPackageRef:
      outPkgs.incl ch.packageName
    of nkCondBlock:
      if predicateHolds(ch.predicateAst, ctx, userEval):
        walkBody(ch.condChildren, ctx, userEval, outPkgs)
    else: discard

proc collectActivityPackages(node: IntentNode; ctx: HostContext;
                             userEval: UserPredicateEvaluator;
                             outPkgs: var HashSet[string]) =
  ## Walk an activity's body, evaluating `when` / `if` blocks against
  ## `ctx` and adding every reachable package reference to `outPkgs`.
  case node.kind
  of nkActivity: walkBody(node.activityChildren, ctx, userEval, outPkgs)
  of nkCondBlock: walkBody(node.condChildren, ctx, userEval, outPkgs)
  else: discard

proc resolveEffectiveConfig*(profile: Profile;
                            host: string;
                            ctx: HostContext;
                            userEval: UserPredicateEvaluator = nil):
    EffectiveConfig =
  ## Compute the effective configuration for `host`. `default` is
  ## always active per the spec; the `hosts:` entry for `host` (if any)
  ## adds the remaining activities. Predicates inside activity bodies
  ## are evaluated against `ctx`.
  result.enabledPackages = initHashSet[string]()
  result.overrides = initOrderedTable[string, OrderedTable[string, string]]()
  result.inertOverrides =
    initOrderedTable[string, OrderedTable[string, string]]()
  result.activeActivities = initHashSet[string]()
  # 1. Compute the active activity set.
  var activeNames: HashSet[string] = initHashSet[string]()
  activeNames.incl "default"
  for ch in profile.root.children:
    if ch.kind == nkHostsBlock:
      for e in ch.hostsEntries:
        if e.hostName == host:
          for a in e.hostActivities:
            activeNames.incl a
  result.activeActivities = activeNames
  # 2. Union package references from each active activity.
  for ch in profile.root.children:
    if ch.kind == nkActivity and ch.activityName in activeNames:
      collectActivityPackages(ch, ctx, userEval, result.enabledPackages)
  # 3. Bucket config overrides (last-write-wins per key, see
  #    `effectiveConfigAssignments`).
  for pkgName, assignments in effectiveConfigAssignments(profile, ctx,
      userEval):
    var table = initOrderedTable[string, string]()
    for key, assignment in assignments:
      table[key] = assignment.entry.configValueSource
    if pkgName in result.enabledPackages:
      result.overrides[pkgName] = table
    else:
      result.inertOverrides[pkgName] = table
