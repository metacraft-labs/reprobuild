## What the solver receives from a Nimble index (NPC-AREQ17): for each
## package a closure reaches, its candidate versions, each with ITS OWN
## requirement list (NPC-AREQ31) evaluated for one platform pair, in the
## solver's constraint language. Read from the root and the shards of the
## names reached -- no source is fetched, no `.nimble` read, nothing run.
##
## A record that cannot be offered is kept with the reason
## (``exclusions``), so a resolution failure can say a candidate was
## excluded for being unreadable, platform limited, and so on
## (NPC-AREQ18).
##
## Not done here (the solver's side): one version per name, the `nim`
## toolchain constraint join, `#head` / `#<commit>` requirements, feature
## activation for the root package. ``perVersionDependencies`` is the shape
## the solver's encoder needs to take per-version dependency lists.

import std/[algorithm, sequtils, sets, tables]

import repro_domain_types/nimble_index
import repro_nimble_reader/conditions
import repro_solver/version_constraints
from repro_solver/version_encoder import DependencyDecl, newDependency

import ./reader
import ./from_reader

type
  NimblePlatform* = object
    id*: string
      ## the platform pair's name, as a probe records it on a
      ## `platform_limited` record
    targetOs*, targetCpu*, hostOs*, hostCpu*: string
      ## lower-case Nim names (`linux`, `amd64`, ...)

  ExclusionKind* = enum
    exUnreadable = "unreadable"
    exPlatformLimited = "platform-limited"
    exGitlinks = "gitlinks"
    exVersionShape = "version-shape"
      ## a fourth or later non-zero component: the solver's versions have
      ## three
    exLabel = "label"
      ## a tag that is not a version: reachable by exact commit only
    exPseudoVersion = "pseudo-version"
      ## `#head`, a branch or a commit: offered only to a requirement that
      ## names it
    exUntranslatable = "untranslatable"
      ## a requirement range the solver's parser refuses

  Exclusion* = object
    kind*: ExclusionKind
    detail*: string

  SolverRequirement* = object
    entry*: RequirementEntry
    package*: string ## the target as written; "" for a URL target
    range*: string   ## solver range text; "" for any version
    features*: seq[string]

  NimbleCandidate* = object
    package*: string  ## canonical name
    identity*: string ## `nimble:<canonical name>`
    version*: string  ## solver version text; "" unless the record is a version
    record*: VersionRecord
    requires*: seq[SolverRequirement]
      ## the record's own requirements active on the platform
    features*: seq[(string, seq[SolverRequirement])]
      ## each non-root feature's requirements active on the platform
    devRequires*: seq[SolverRequirement]
      ## root-only (`dev`) features: for the package being developed only
    nim*: seq[string] ## the active `nim` ranges (a toolchain constraint)
    exclusions*: seq[Exclusion]

  NimbleSolverPackage* = object
    name*: string
    identity*: string
    candidates*: seq[NimbleCandidate] ## in the record order of the shard
    features*: seq[string] ## features some requirer in the closure named

  NimbleSolverInput* = object
    platform*: NimblePlatform
    packages*: seq[NimbleSolverPackage] ## sorted by name
    canonical*: Table[string, string]   ## nameKey of a name reached -> canonical
    missing*: seq[string]  ## names reached that the index does not hold, sorted
    urlTargets*: seq[string] ## URL requirements (resolved by commit, not here)

proc offered*(c: NimbleCandidate): bool = c.exclusions.len == 0

proc identityOf*(canonicalName: string): string = "nimble:" & canonicalName

proc solverVersion*(v: RecordVersion; text: var string): bool =
  ## The solver's three-component version text for a tag version: missing
  ## components are 0, as Nimble compares them; trailing zero components
  ## beyond the third are dropped. False for any other shape.
  if v.kind != rvkTag or v.components.len == 0:
    return false
  for i in 3 ..< v.components.len:
    if v.components[i] != 0:
      return false
  var c = v.components
  while c.len < 3: c.add 0
  for x in c[0 .. 2]:
    if x > uint64(high(int32)):
      return false
  text = $c[0] & "." & $c[1] & "." & $c[2]
  true

proc activeOn*(nodes: seq[ConditionNode]; p: NimblePlatform): bool =
  ## Whether a record condition holds on platform ``p`` (as Nim's
  ## `isDefined` answers for the target, see ``conditions.evaluate``).
  evaluate(conditionOf(nodes), p.targetOs, p.targetCpu, p.hostOs, p.hostCpu)

proc solverRequirement(e: RequirementEntry;
                       exclusions: var seq[Exclusion]): SolverRequirement =
  result = SolverRequirement(entry: e, features: e.features)
  if e.targetKind == rtPackage:
    result.package = e.target
  case e.versionKind
  of rvAny: discard
  of rvRange:
    try:
      discard parseSemverRange(e.constraint)
      result.range = e.constraint
    except ESemverParse as err:
      exclusions.add Exclusion(kind: exUntranslatable,
        detail: e.source & ": " & err.msg)
  of rvHead, rvCommit, rvRef:
    discard

proc activeRequirements(es: seq[RequirementEntry]; p: NimblePlatform;
                        exclusions: var seq[Exclusion]): seq[SolverRequirement] =
  for e in es:
    if activeOn(e.condition, p):
      result.add solverRequirement(e, exclusions)

proc candidate*(pkg: PackageEnvelope; r: VersionRecord;
                p: NimblePlatform): NimbleCandidate =
  ## One record as a solver candidate on platform ``p``.
  result = NimbleCandidate(package: pkg.name, identity: identityOf(pkg.name),
    record: r)
  if flUnreadable in r.flags:
    result.exclusions.add Exclusion(kind: exUnreadable,
      detail: "the `.nimble` of " & r.version.tag & " (" & $r.readerClass &
        ") was not read statically and no override or probe supplied it")
  if flPlatformLimited in r.flags and r.probePlatform != p.id:
    result.exclusions.add Exclusion(kind: exPlatformLimited,
      detail: "read by a probe on " & r.probePlatform & " only; this " &
        "solve is for " & p.id)
  if flGitlinks in r.flags:
    result.exclusions.add Exclusion(kind: exGitlinks,
      detail: "the tree has submodules, which are not offered")
  case r.version.kind
  of rvkTag:
    var t = ""
    if solverVersion(r.version, t):
      result.version = t
    else:
      result.exclusions.add Exclusion(kind: exVersionShape,
        detail: "tag " & r.version.tag & " has " & $r.version.components.len &
          " components; the solver's versions have three")
  of rvkLabel:
    result.exclusions.add Exclusion(kind: exLabel,
      detail: "tag " & r.version.tag & " is not a version")
  of rvkHead, rvkRef, rvkCommit:
    result.exclusions.add Exclusion(kind: exPseudoVersion,
      detail: versionText(r.version))
  result.requires = activeRequirements(r.requires, p, result.exclusions)
  for f in r.features:
    let reqs = activeRequirements(f.requires, p, result.exclusions)
    if f.rootOnly: result.devRequires.add reqs
    else: result.features.add (f.name, reqs)
  for e in r.nim:
    if activeOn(e.condition, p):
      var ignored: seq[Exclusion]
      let s = solverRequirement(e, ignored)
      if ignored.len > 0:
        result.exclusions.add ignored
      result.nim.add s.range

proc candidatesOf*(pkg: PackageEnvelope; p: NimblePlatform): seq[NimbleCandidate] =
  for r in pkg.versions:
    result.add candidate(pkg, r, p)

proc solverInput*(idx: var NimbleIndex; roots: openArray[string];
                  p: NimblePlatform): NimbleSolverInput =
  ## The candidates of every package reachable from ``roots`` through the
  ## requirements of offered candidates (every version's, and every feature
  ## a requirer names). Reads the root's shards for exactly the names
  ## reached.
  result.platform = p
  type Work = tuple[name: string, features: seq[string]]
  var queue: seq[Work]
  var byKey = initTable[string, NimbleSolverPackage]()
  var followed = initTable[string, HashSet[string]]()
    ## canonical key -> features whose requirements were followed
  var missing = initHashSet[string]()
  var urls = initHashSet[string]()
  for r in roots: queue.add (r, newSeq[string]())
  var i = 0
  while i < queue.len:
    let (name, wanted) = queue[i]
    inc i
    let key = nameKey(name)
    if key in result.canonical:
      let ck = nameKey(result.canonical[key])
      if ck in byKey and wanted.allIt(it in followed[ck]):
        continue
    let found = lookupPackage(idx, name)
    if not found.found:
      missing.incl name
      continue
    let canon = found.package.name
    let ck = nameKey(canon)
    result.canonical[key] = canon
    result.canonical[ck] = canon
    var toFollow: seq[SolverRequirement]
    if ck notin byKey:
      var pkg = NimbleSolverPackage(name: canon, identity: identityOf(canon),
        candidates: candidatesOf(found.package, p))
      for c in pkg.candidates:
        if c.offered: toFollow.add c.requires
      byKey[ck] = pkg
      followed[ck] = initHashSet[string]()
    for f in wanted:
      if f in followed[ck]:
        continue
      followed[ck].incl f
      byKey[ck].features.add f
      for c in byKey[ck].candidates:
        if not c.offered: continue
        for (fname, freqs) in c.features:
          if fname == f: toFollow.add freqs
    byKey[ck].features.sort()
    for r in toFollow:
      if r.entry.targetKind == rtUrl:
        urls.incl r.entry.target
        continue
      if nameKey(r.package) == "nim":
        continue
      queue.add (r.package, r.features)
  for _, pkg in byKey: result.packages.add pkg
  result.packages.sort(proc (a, b: NimbleSolverPackage): int =
    cmp(a.name, b.name))
  for m in missing: result.missing.add m
  result.missing.sort()
  for u in urls: result.urlTargets.add u
  result.urlTargets.sort()

proc perVersionDependencies*(input: NimbleSolverInput;
                             pkg: NimbleSolverPackage):
    seq[(string, seq[DependencyDecl])] =
  ## For each offered candidate: its solver version and its own dependency
  ## list as the solver's ``DependencyDecl`` (target named by its
  ## `nimble:` identity, through the canonical names the closure resolved;
  ## features the closure activated included). The encoder's per-package
  ## ``PackageDecl.depends`` cannot hold per-version lists; this is the
  ## shape it has to take.
  ##
  ## A requirement on a name the index does not hold is kept, under the name
  ## as written: the solver then finds no candidate for it and the version
  ## cannot be chosen, where dropping it would let the version be chosen
  ## with a requirement nothing satisfies. A `#head`, `#<commit>` or
  ## `#<branch>` requirement has no range here (its ``DependencyDecl``
  ## admits any version); matching it to the pseudo-version it names is the
  ## solver's (NPC-M6), from ``SolverRequirement.entry``.
  for c in pkg.candidates:
    if not c.offered:
      continue
    var deps: seq[DependencyDecl]
    var reqs = c.requires
    for (fname, freqs) in c.features:
      if fname in pkg.features:
        reqs.add freqs
    for r in reqs:
      if r.entry.targetKind != rtPackage:
        continue
      let tk = nameKey(r.package)
      if tk == "nim":
        continue
      let target =
        if tk in input.canonical: input.canonical[tk] else: r.package
      deps.add newDependency(identityOf(target), r.range)
    result.add (c.version, deps)
