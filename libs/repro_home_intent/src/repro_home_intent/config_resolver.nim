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

proc walkBody(children: seq[IntentNode]; ctx: HostContext;
              userEval: UserPredicateEvaluator;
              outPkgs: var HashSet[string]) =
  for ch in children:
    case ch.kind
    of nkPackageRef:
      outPkgs.incl ch.packageName
    of nkCondBlock:
      if evaluateBool(ch.predicateAst, ctx, userEval):
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
  # 3. Bucket config overrides.
  for ch in profile.root.children:
    if ch.kind == nkConfigBlock:
      for pkg in ch.configPackages:
        var table = initOrderedTable[string, string]()
        for entry in pkg.configEntries:
          table[entry.configKey] = entry.configValueSource
        if pkg.configPackageName in result.enabledPackages:
          result.overrides[pkg.configPackageName] = table
        else:
          result.inertOverrides[pkg.configPackageName] = table
