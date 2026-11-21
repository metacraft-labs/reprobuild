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
## NPC-M6 adds, for the solve (``resolution`` lowers this to the solver):
## a pseudo-version record (`#head`, a branch, a commit) is offered only to
## a requirement that names it, under a ``#``-spelled solver version no
## ordinary range admits; a requirement given as a URL is resolved to the
## unlisted source the index holds for it; ``--exclude-newer`` excludes a
## record first seen after the bound; and two tags of one package that read
## as the same solver version are decided before they reach the encoder
## (``equalVersionExclusions``). Every name the closure reaches is recorded
## with the requirement it was reached by, so a failure can name the chain.

import std/[algorithm, options, sequtils, sets, strutils, tables, times]

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
    exNewer = "newer"
      ## first seen after the solve's `--exclude-newer` bound (NPC-AREQ18)
    exEqualVersion = "equal-version"
      ## another tag of the package reads as the same solver version at
      ## another commit (`v1.0` and `1.0.0`): which one a range means is not
      ## decidable, so neither is offered under it (NPC-M6 item d)
    exOtherOrigin = "repointed-origin"
      ## a record of an origin the name was repointed to (or from), which
      ## the project has not accepted: a repoint is never applied silently
      ## (NPC-AREQ16, threat model G7)
    exDuplicateTag = "duplicate-tag"
      ## another tag of the package reads as the same solver version at the
      ## SAME commit: the same source, offered once, under the first tag

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
    version*: string
      ## solver version text: `1.2.0` for a tag version, `#head`,
      ## `#ref/<branch>` or `#commit/<id>` for a pseudo-version (offered only
      ## to a requirement naming it); "" for a label
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
    origins*: seq[PackageOrigin] ## the envelope's (a record names one)
    candidates*: seq[NimbleCandidate] ## in the record order of the shard
    features*: seq[string] ## features some requirer in the closure named

  NimbleSolveOptions* = object
    excludeNewer*: int64
      ## Unix seconds: a record first seen later is excluded (`newer`);
      ## negative for no bound
    acceptedOrigins*: Table[string, string]
      ## nameKey of a canonical name -> the origin URL (with `?subdir=`)
      ## the project accepts for it: the one its lock already records. A
      ## package not listed accepts the first origin its envelope names --
      ## the one it had before any repoint. Records of every other origin
      ## are excluded as `repointed-origin`
    roots*: seq[RootRequirement]
      ## the requirements the closure starts from, with their ranges, for
      ## the requirement chain a diagnostic prints; ``solverInput``'s
      ## ``roots`` names are enough to compute the closure

  RootRequirement* = object
    requirer*: string ## who states it (the project's package)
    name*: string     ## the Nimble name as written
    range*: string    ## the range as written ("" for any)

  ReachedBy* = object
    ## How a name entered the closure: the requirement and who stated it.
    requirer*: string  ## `<identity> <version>` of a candidate, or a root's
    requirement*: string ## the requirement as written

  NimbleSolverInput* = object
    platform*: NimblePlatform
    options*: NimbleSolveOptions
    packages*: seq[NimbleSolverPackage] ## sorted by name
    canonical*: Table[string, string]   ## nameKey of a name reached -> canonical
    missing*: seq[string]  ## names reached that the index does not hold, sorted
    urlTargets*: seq[string]
      ## URL requirements reached, as written; each is resolved to the
      ## unlisted source the index holds under ``unlistedSourceName``
    reachedBy*: Table[string, seq[ReachedBy]]
      ## nameKey of a name as reached (canonical, missing or a URL's
      ## unlisted name) -> the requirements that reached it, in order

proc offered*(c: NimbleCandidate): bool = c.exclusions.len == 0

proc identityOf*(canonicalName: string): string = "nimble:" & canonicalName

proc featureIdentity*(identity, feature: string): string =
  ## The solver package that stands for ``feature`` of the Nimble package
  ## ``identity`` being active: `nimble:lib[extra]`. Its versions mirror the
  ## package's, each pinned to that version of the package and carrying the
  ## feature's requirements at it, and it is active only when a CHOSEN
  ## version requires `lib[extra]` (NPC-AREQ7: a feature is active only
  ## when the requirer names it). It is a solver device, never a package of
  ## the lock.
  identity & "[" & feature & "]"

proc isFeatureIdentity*(name: string): bool =
  name.endsWith("]") and '[' in name

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

proc pseudoVersionText*(v: RecordVersion; commit: string): string =
  ## The solver version a pseudo-version record is offered under: spelled
  ## with ``#`` so no ordinary range admits it, and only the exact range a
  ## requirement naming it is lowered to (``repro_solver``'s
  ## ``rangeAdmits``) selects it. "" for any other kind.
  case v.kind
  of rvkHead: "#head"
  of rvkRef: "#ref/" & v.tag
  of rvkCommit: "#commit/" & commit
  else: ""

proc unlistedSourceName*(url, subdir: string): string =
  ## The name an unlisted source -- one a requirement gives as a URL -- is
  ## indexed under (spec § 4.4, amendment NPC-M4): the URL lower case,
  ## without its scheme, trailing `/` and `.git`, with `?subdir=` kept. The
  ## generator indexes it under this name, and resolution looks it up here.
  var u = url.toLowerAscii()
  let sep = u.find("://")
  if sep >= 0: u = u[sep + 3 .. ^1]
  while u.endsWith("/"): u.setLen(u.len - 1)
  if u.endsWith(".git"): u.setLen(u.len - 4)
  u & (if subdir.len > 0: "?subdir=" & subdir else: "")

proc requirementTargetName*(e: RequirementEntry): string =
  ## The index name a requirement targets: the package name, or for a URL
  ## requirement the unlisted source's name.
  if e.targetKind == rtUrl: unlistedSourceName(e.target, e.subdir)
  else: e.target

proc isPseudoRequirement*(e: RequirementEntry): bool =
  e.versionKind in {rvHead, rvRef, rvCommit}

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

proc formatTime(t: int64): string =
  ## A Unix time as UTC ISO 8601, for diagnostics.
  fromUnix(t).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc candidate*(pkg: PackageEnvelope; r: VersionRecord;
                p: NimblePlatform;
                options = NimbleSolveOptions(excludeNewer: -1)):
    NimbleCandidate =
  ## One record as a solver candidate on platform ``p``.
  result = NimbleCandidate(package: pkg.name, identity: identityOf(pkg.name),
    record: r)
  if options.excludeNewer >= 0 and int64(r.firstSeen) > options.excludeNewer:
    result.exclusions.add Exclusion(kind: exNewer,
      detail: "first seen " & formatTime(int64(r.firstSeen)) & ", after " &
        "the --exclude-newer bound " & formatTime(options.excludeNewer))
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
    # Offered only to a requirement that names it: ``solverInput`` lifts
    # this exclusion for exactly that record (``admitPseudo``).
    result.version = pseudoVersionText(r.version, r.commit)
    result.exclusions.add Exclusion(kind: exPseudoVersion,
      detail: versionText(r.version) & " is offered only to a requirement " &
        "that names it")
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

proc equalVersionExclusions*(cs: var seq[NimbleCandidate]) =
  ## NPC-M6 item d. ``solverVersion`` reads `v1.0`, `1.0.0` and `1.0.0.0`
  ## as one solver version, so two records of one package can offer the
  ## same version. Decided here, before the encoder sees them:
  ##
  ## * all at ONE commit: the same source; the first in the shard's record
  ##   order is offered and the others are excluded as `duplicate-tag`;
  ## * at two or more commits: a range cannot say which it means, and
  ##   choosing by tag spelling would let a tag the origin adds later
  ##   silently change what an existing range resolves to. None of them is
  ##   offered under the version (`equal-version`); each stays reachable by
  ##   a `#<commit>` requirement.
  ##
  ## Only records still offered take part, so an unreadable `1.0.0` beside a
  ## readable `v1.0` leaves `v1.0` offered.
  var byVersion = initOrderedTable[string, seq[int]]()
  for i, c in cs:
    if c.offered and c.record.version.kind == rvkTag:
      byVersion.mgetOrPut(c.version, @[]).add i
  for v, idx in byVersion:
    if idx.len < 2: continue
    var commits: seq[string]
    for i in idx:
      if cs[i].record.commit notin commits: commits.add cs[i].record.commit
    if commits.len == 1:
      for i in idx[1 .. ^1]:
        cs[i].exclusions.add Exclusion(kind: exDuplicateTag,
          detail: "tag " & cs[i].record.version.tag & " reads as " & v &
            " at the same commit as tag " & cs[idx[0]].record.version.tag &
            ", which is offered")
    else:
      var tags: seq[string]
      for i in idx:
        tags.add cs[i].record.version.tag & " (" &
          cs[i].record.commit[0 ..< min(12, cs[i].record.commit.len)] & ")"
      for i in idx:
        cs[i].exclusions.add Exclusion(kind: exEqualVersion,
          detail: "tags " & tags.join(", ") & " all read as " & v &
            " at different commits; a range cannot choose between them. " &
            "Name the one meant by `#<commit>`")

proc originUrl(o: PackageOrigin): string =
  o.url & (if o.subdir.len > 0: "?subdir=" & o.subdir else: "")

proc acceptedOrigin*(pkg: PackageEnvelope; options: NimbleSolveOptions): int =
  ## The index in ``pkg.origins`` of the origin the solve may take records
  ## from: the one ``options.acceptedOrigins`` names for the package, else
  ## the first (the origin the name had before any repoint). -1 when the
  ## accepted URL is not an origin of the envelope.
  let k = nameKey(pkg.name)
  if k in options.acceptedOrigins:
    for i, o in pkg.origins:
      if originUrl(o) == options.acceptedOrigins[k]: return i
    return -1
  if pkg.origins.len > 0: 0 else: -1

proc candidatesOf*(pkg: PackageEnvelope; p: NimblePlatform;
                   options = NimbleSolveOptions(excludeNewer: -1)):
    seq[NimbleCandidate] =
  let accepted = acceptedOrigin(pkg, options)
  for r in pkg.versions:
    var c = candidate(pkg, r, p, options)
    if pkg.origins.len > 1 and int(r.origin) != accepted:
      let theirs = if int(r.origin) < pkg.origins.len:
                     originUrl(pkg.origins[int(r.origin)]) else: "?"
      c.exclusions.add Exclusion(kind: exOtherOrigin,
        detail: "a record of " & theirs & "; the project takes " & pkg.name &
          " from " & (if accepted >= 0: originUrl(pkg.origins[accepted])
                      else: "an origin this index does not record") &
          ". A repointed name keeps the origin the lock records (or, with no " &
          "lock row, the one it had before the repoint); accepting another " &
          "origin is not implemented yet")
    result.add c
  equalVersionExclusions(result)

type PseudoMatch* = object
  ## What a `#head`, `#<branch>` or `#<commit>` requirement names in a
  ## package's records.
  found*: bool
  index*: int     ## the candidate it selects
  range*: string  ## the solver range that selects exactly it
  why*: string    ## when not found: why

proc matchPseudo*(pkg: NimbleSolverPackage; e: RequirementEntry): PseudoMatch =
  ## The record a pseudo-version requirement names (NPC-AREQ17):
  ##
  ## * `#head` -> the package's `head` record;
  ## * `#<name>` -> the `ref` record of that branch, else a tag version
  ##   spelled exactly so (Nimble's `#<tag>`);
  ## * `#<commit>` (full or abbreviated) -> the record of that commit: its
  ##   `commit` pseudo-version, else the tag version at that commit. An
  ##   abbreviation that matches two commits names none.
  ##
  ## The range is the exact ``#...`` text of a pseudo-version, or `=<v>`
  ## for a tag version, so it admits that record alone.
  proc tagRange(i: int): PseudoMatch =
    PseudoMatch(found: true, index: i, range: "=" & pkg.candidates[i].version)
  case e.versionKind
  of rvHead:
    for i, c in pkg.candidates:
      if c.record.version.kind == rvkHead:
        return PseudoMatch(found: true, index: i, range: c.version)
    PseudoMatch(why: "the index records no `#head` of " & pkg.name &
      " (the source set's `track_head` does not list it)")
  of rvRef:
    for i, c in pkg.candidates:
      if c.record.version.kind == rvkRef and c.record.version.tag == e.constraint:
        return PseudoMatch(found: true, index: i, range: c.version)
    for i, c in pkg.candidates:
      if c.record.version.kind == rvkTag and
          c.record.version.tag == e.constraint and c.version.len > 0:
        return tagRange(i)
    PseudoMatch(why: "the index records no branch or tag " &
      e.constraint.escape() & " of " & pkg.name)
  of rvCommit:
    let want = e.constraint.toLowerAscii()
    var commits: seq[string]
    for c in pkg.candidates:
      if c.record.commit.startsWith(want) and c.record.commit notin commits:
        commits.add c.record.commit
    if commits.len == 0:
      return PseudoMatch(why: "the index records no commit " & want &
        " of " & pkg.name)
    if commits.len > 1:
      return PseudoMatch(why: "the abbreviation " & want & " matches " &
        $commits.len & " commits of " & pkg.name & " (" &
        commits.join(", ") & ")")
    for i, c in pkg.candidates:
      if c.record.commit == commits[0] and c.record.version.kind == rvkCommit:
        return PseudoMatch(found: true, index: i, range: c.version)
    for i, c in pkg.candidates:
      if c.record.commit == commits[0] and c.record.version.kind == rvkTag and
          c.version.len > 0:
        return tagRange(i)
    for i, c in pkg.candidates:
      if c.record.commit == commits[0] and c.record.version.kind in
          {rvkHead, rvkRef}:
        return PseudoMatch(found: true, index: i, range: c.version)
    PseudoMatch(why: "commit " & commits[0] & " of " & pkg.name &
      " is recorded only under a label, which no requirement can select")
  else:
    PseudoMatch(why: "not a pseudo-version requirement")

proc onlyEqualVersionExcluded(c: NimbleCandidate): bool =
  c.exclusions.len > 0 and
    c.exclusions.allIt(it.kind in {exEqualVersion, exDuplicateTag})

proc admitPseudo*(pkg: var NimbleSolverPackage; e: RequirementEntry):
    PseudoMatch =
  ## Offer the record a pseudo-version requirement names (``matchPseudo``)
  ## by lifting its `pseudo-version` exclusion; its other exclusions (an
  ## unreadable record, another platform) still hold. A tag version that
  ## `#<commit>` names while it is held back only as an `equal-version` is
  ## offered once more under that commit's pseudo-version, so the commit
  ## stays nameable. Returns the match; ``range`` is what the requirement
  ## lowers to.
  result = matchPseudo(pkg, e)
  if not result.found:
    return
  var c = pkg.candidates[result.index]
  if c.record.version.kind in {rvkHead, rvkRef, rvkCommit}:
    pkg.candidates[result.index].exclusions.keepItIf(
      it.kind != exPseudoVersion)
  elif e.versionKind == rvCommit and onlyEqualVersionExcluded(c):
    let text = "#commit/" & c.record.commit
    for i, other in pkg.candidates:
      if other.version == text:
        result.index = i
        result.range = text
        return
    c.version = text
    c.exclusions = @[]
    pkg.candidates.add c
    result.index = pkg.candidates.len - 1
    result.range = text

proc solverInput*(idx: var NimbleIndex; roots: openArray[string];
                  p: NimblePlatform;
                  options = NimbleSolveOptions(excludeNewer: -1)):
    NimbleSolverInput =
  ## The candidates of every package reachable from ``roots`` through the
  ## requirements of offered candidates (every version's, and every feature
  ## a requirer names). Reads the root's shards for exactly the names
  ## reached. A pseudo-version a reached requirement names is offered, and
  ## its own requirements followed; a URL requirement reaches the unlisted
  ## source the index holds for it. ``options.roots`` (when given) supply
  ## the requirement text for the chain of a root.
  result.platform = p
  result.options = options
  type Work = object
    name: string             ## index name (a URL's unlisted name)
    features: seq[string]
    pseudo: Option[RequirementEntry]
    by: ReachedBy
  var queue: seq[Work]
  var byKey = initTable[string, NimbleSolverPackage]()
  var followed = initTable[string, HashSet[string]]()
    ## canonical key -> features whose requirements were followed
  var followedCandidates = initTable[string, HashSet[int]]()
    ## canonical key -> candidates whose requirements were followed
  var missing = initHashSet[string]()
  var urls = initHashSet[string]()
  for r in roots:
    var by = ReachedBy(requirer: "the project", requirement: "nimble:" & r)
    for rr in options.roots:
      if nameKey(rr.name) == nameKey(r):
        by = ReachedBy(requirer: rr.requirer, requirement: "nimble:" & rr.name &
          (if rr.range.len > 0: " " & rr.range else: ""))
    queue.add Work(name: r, by: by)

  proc enqueue(c: NimbleCandidate; reqs: seq[SolverRequirement]) =
    for r in reqs:
      let target = requirementTargetName(r.entry)
      if r.entry.targetKind == rtUrl:
        urls.incl r.entry.target
      elif nameKey(target) == "nim":
        continue
      queue.add Work(name: target, features: r.features,
        pseudo: (if isPseudoRequirement(r.entry): some(r.entry)
                 else: none(RequirementEntry)),
        by: ReachedBy(requirer: c.identity & " " & versionText(c.record.version),
          requirement: r.entry.source))

  var i = 0
  while i < queue.len:
    let w = queue[i]
    inc i
    let key = nameKey(w.name)
    if w.by notin result.reachedBy.getOrDefault(key):
      result.reachedBy.mgetOrPut(key, @[]).add w.by
    if key in result.canonical:
      let ck = nameKey(result.canonical[key])
      if ck in byKey and w.pseudo.isNone and
          w.features.allIt(it in followed[ck]):
        continue
    let found = lookupPackage(idx, w.name)
    if not found.found:
      missing.incl w.name
      continue
    let canon = found.package.name
    let ck = nameKey(canon)
    result.canonical[key] = canon
    result.canonical[ck] = canon
    if ck notin byKey:
      byKey[ck] = NimbleSolverPackage(name: canon, identity: identityOf(canon),
        origins: found.package.origins,
        candidates: candidatesOf(found.package, p, options))
      followed[ck] = initHashSet[string]()
      followedCandidates[ck] = initHashSet[int]()
    if w.pseudo.isSome:
      discard admitPseudo(byKey[ck], w.pseudo.get)
    var newFeatures: seq[string]
    for f in w.features:
      if f notin followed[ck]:
        followed[ck].incl f
        byKey[ck].features.add f
        newFeatures.add f
    byKey[ck].features.sort()
    # Follow every offered candidate not yet followed, and the requirements
    # of every followed feature (for every offered candidate).
    let pkg = byKey[ck]
    for ci, c in pkg.candidates:
      if not c.offered: continue
      var reqs: seq[SolverRequirement]
      if ci notin followedCandidates[ck]:
        followedCandidates[ck].incl ci
        reqs.add c.requires
        for (fname, freqs) in c.features:
          if fname in followed[ck]: reqs.add freqs
      else:
        for (fname, freqs) in c.features:
          if fname in newFeatures: reqs.add freqs
      enqueue(c, reqs)
  for _, pkg in byKey: result.packages.add pkg
  result.packages.sort(proc (a, b: NimbleSolverPackage): int =
    cmp(a.name, b.name))
  for m in missing: result.missing.add m
  result.missing.sort()
  for u in urls: result.urlTargets.add u
  result.urlTargets.sort()

proc packageOf*(input: NimbleSolverInput; name: string): int =
  ## The index in ``input.packages`` of the package ``name`` reached (by
  ## any spelling or alias), or -1.
  let k = nameKey(name)
  if k notin input.canonical: return -1
  let canon = input.canonical[k]
  for i, p in input.packages:
    if p.name == canon: return i
  -1

const AnyVersionRange* = ">=0.0.0"
  ## What "any version" lowers to: the solver's empty range admits nothing,
  ## and every tag version is at least 0.0.0. A pseudo-version (``#...``)
  ## is not admitted by it, which is the point.

const UnresolvedRangePrefix* = "#unresolved:"
  ## The range a pseudo-version requirement lowers to when the index holds
  ## nothing it names: it admits no candidate, so the requiring version
  ## cannot be chosen (the diagnostics say why).

proc dependencyOf*(input: NimbleSolverInput; r: SolverRequirement):
    Option[DependencyDecl] =
  ## The solver dependency one requirement lowers to: its target named by
  ## the `nimble:` identity (through the canonical name the closure
  ## resolved, else the name as written, which then has no candidate), and
  ## its range in the solver's grammar ("" for any version, which
  ## ``lowerToSolver`` turns into ``AnyVersionRange``) -- a pseudo-version
  ## requirement's
  ## exact ``#...`` range, `=<version>` for a tag it names, or an
  ## ``#unresolved:`` range admitting nothing. None for `nim`, which
  ## constrains the toolchain, not a package.
  let target = requirementTargetName(r.entry)
  let tk = nameKey(target)
  if tk == "nim" and r.entry.targetKind == rtPackage:
    return none(DependencyDecl)
  let canon = if tk in input.canonical: input.canonical[tk] else: target
  var rangeText = r.range
  if isPseudoRequirement(r.entry):
    let pi = input.packageOf(canon)
    if pi < 0:
      rangeText = UnresolvedRangePrefix & r.entry.source
    else:
      let m = matchPseudo(input.packages[pi], r.entry)
      var rng = m.range
      if m.found and r.entry.versionKind == rvCommit and
          onlyEqualVersionExcluded(input.packages[pi].candidates[m.index]):
        rng = "#commit/" & input.packages[pi].candidates[m.index].record.commit
      rangeText = if m.found: rng else: UnresolvedRangePrefix & r.entry.source
  some(newDependency(identityOf(canon), rangeText))

proc lowered(input: NimbleSolverInput; reqs: seq[SolverRequirement]):
    seq[DependencyDecl] =
  ## ``reqs`` as solver dependencies (``dependencyOf``), each requirement
  ## that names features (`lib[extra]`) followed by a dependency on each
  ## feature's package (``featureIdentity``) under the same range, so the
  ## feature is active exactly when a version stating it is chosen.
  for r in reqs:
    let d = dependencyOf(input, r)
    if d.isNone:
      continue
    result.add d.get
    if r.features.len > 0 and input.packageOf(requirementTargetName(r.entry)) >= 0:
      for f in r.features:
        result.add newDependency(featureIdentity(d.get.name, f), d.get.range)

proc perVersionDependencies*(input: NimbleSolverInput;
                             pkg: NimbleSolverPackage):
    seq[(string, seq[DependencyDecl])] =
  ## For each offered candidate: its solver version and its own dependency
  ## list as the solver's ``DependencyDecl`` (``lowered``) -- the shape the
  ## encoder takes as ``PackageDecl.versionDepends`` (NPC-M6). A feature's
  ## requirements are not here: they are the feature package's
  ## (``featureVersionDependencies``), active only when a chosen version
  ## names the feature.
  ##
  ## A requirement on a name the index does not hold is kept, under the name
  ## as written: the solver then finds no candidate for it and the version
  ## cannot be chosen, where dropping it would let the version be chosen
  ## with a requirement nothing satisfies.
  for c in pkg.candidates:
    if not c.offered:
      continue
    result.add (c.version, lowered(input, c.requires))

proc exactRange*(version: string): string =
  ## The range that admits exactly the candidate ``version``.
  if version.startsWith("#"): version else: "=" & version

proc featureVersionDependencies*(input: NimbleSolverInput;
                                 pkg: NimbleSolverPackage; feature: string):
    seq[(string, seq[DependencyDecl])] =
  ## The per-version dependencies of ``feature``'s package
  ## (``featureIdentity``): for each offered candidate of ``pkg``, the
  ## package itself at exactly that version, then the feature's
  ## requirements at that version (none when that version has no such
  ## feature).
  for c in pkg.candidates:
    if not c.offered:
      continue
    var deps = @[newDependency(pkg.identity, exactRange(c.version))]
    for (fname, freqs) in c.features:
      if fname == feature:
        deps.add lowered(input, freqs)
    result.add (c.version, deps)
