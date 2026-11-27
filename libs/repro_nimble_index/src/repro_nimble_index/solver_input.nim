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
import repro_solver/nimble_versions
from repro_solver/version_encoder import DependencyDecl, newDependency,
  rangeAdmits

import ./reader
import ./from_reader

export Truth, NimVersionValue, parseNimVersionValue, nimVersionText

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
      ## a `gitlinks` record without a `submodules` list (from a generator
      ## before submodule sources)
    exVersionShape = "version-shape"
      ## no longer produced: a tag version of any number of components is
      ## offered and compared as Nimble compares it (NPC-AREQ6). Kept so the
      ## reason's spelling stays reserved
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
    exNimVersionUnknown = "nim-version-unknown"
      ## an active requirement holds under a Nim-version condition, and the
      ## solve declares no `nim` toolchain package to decide it (NPC-AREQ7)
    exSnapshotRetired = "snapshot-retired"
      ## a snapshot of a package that has a `tag` record: the upstream has
      ## adopted versioning, and no resolution offers its snapshots
      ## (NPC-AREQ31 item 5)
    exSnapshotSuperseded = "snapshot-superseded"
      ## a snapshot of a package that has a newer one: only the newest
      ## snapshot is offered (NPC-AREQ31 item 5)
    exRevivedOrigin = "revived-origin"
      ## a record first seen after the package's origin was revived -- it
      ## answered again holding none of the recorded commits (NPC-AREQ4
      ## `revived`) -- which the project has not accepted: a revival is
      ## reviewed like a repoint (NPC-AREQ16, threat model G41)

  Exclusion* = object
    kind*: ExclusionKind
    detail*: string

  SolverRequirement* = object
    entry*: RequirementEntry
    package*: string ## the target as written; "" for a URL target
    range*: string   ## solver range text; "" for any version
    features*: seq[string]
    nimGated*: bool
      ## the condition holds on the platform for some Nim versions and not
      ## others (NPC-AREQ7): the requirement binds only when the Nim the
      ## solve chooses makes it true (``nimGateIdentity``)

  NimbleCandidate* = object
    package*: string  ## canonical name
    identity*: string ## `nimble:<canonical name>`
    version*: string
      ## solver version text: `1.2.0` for a tag version, `#head`,
      ## `#ref/<branch>` or `#commit/<id>` for a pseudo-version (offered only
      ## to a requirement naming it), `#snapshot/<YYYYMMDD>/<commit>` for a
      ## snapshot (admitted by "any version" and by its commit, never by a
      ## range); "" for a label
    record*: VersionRecord
    requires*: seq[SolverRequirement]
      ## the record's own requirements active on the platform
    features*: seq[(string, seq[SolverRequirement])]
      ## each non-root feature's requirements active on the platform
    devRequires*: seq[SolverRequirement]
      ## root-only (`dev`) features: for the package being developed only
    nim*: seq[string] ## the active `nim` ranges (a toolchain constraint)
    nimGatedNim*: seq[SolverRequirement]
      ## `nim` ranges whose condition depends on the Nim version: each
      ## applies at a Nim version that makes its condition true
    exclusions*: seq[Exclusion]

  NimbleSolverPackage* = object
    name*: string
    identity*: string
    origins*: seq[PackageOrigin] ## the envelope's (a record names one)
    candidates*: seq[NimbleCandidate] ## in the record order of the shard
    features*: seq[string] ## features some requirer in the closure named

  NimbleSolveOptions* = object
    nimDeclared*: bool
      ## the solve declares the project's `nim` toolchain package, so a
      ## Nim-version condition is decided by the Nim it chooses; without
      ## one, a candidate with an active requirement under such a condition
      ## is excluded (`nim-version-unknown`, NPC-AREQ7)
    excludeNewer*: int64
      ## Unix seconds: a record first seen later is excluded (`newer`);
      ## negative for no bound
    acceptedOrigins*: Table[string, string]
      ## nameKey of a canonical name -> the origin URL (with `?subdir=`)
      ## the project's lock already records for it. A package not listed
      ## (and not in ``acceptances``) takes the first origin its envelope
      ## names -- the one it had before any repoint. Records of every other
      ## origin are excluded as `repointed-origin` or `revived-origin`
    acceptedCommits*: Table[string, string]
      ## nameKey -> the commit the lock row records. A revival entry shares
      ## its URL with the origin it revives, so when several entries match
      ## the row's URL, the one whose record holds this commit is the
      ## origin the lock records
    acceptances*: Table[string, SourceAcceptance]
      ## nameKey of a package (an origin acceptance) or of an alias (a
      ## target acceptance) -> the project's committed acceptance of a
      ## source the index records for it (NPC-AREQ16): a `[[policy]]` of
      ## `repro-catalogs.toml`, or an `[[override]]` of the index's source
      ## set. It decides before ``acceptedOrigins``: it is how a project
      ## moves off the source its lock records
    indexRepo*: string
      ## the `repo` of the `nimble-index` import read, for the `[[policy]]`
      ## table a remedy prints
    catalogsFile*: string
      ## the project's `repro-catalogs.toml`, named by the remedies
    roots*: seq[RootRequirement]
      ## the requirements the closure starts from, with their ranges, for
      ## the requirement chain a diagnostic prints; ``solverInput``'s
      ## ``roots`` names are enough to compute the closure

  SourceAcceptance* = object
    ## A project's acceptance of one source the pinned index records for a
    ## name (NPC-AREQ16): an origin of a package (a repoint's new origin, or
    ## a revival entry) or a target of an alias (its recorded target or its
    ## candidate). Exactly one of ``origin`` and ``target`` is set.
    package*: string   ## the package or alias, as the acceptance spells it
    origin*: string    ## origin URL, `?subdir=` kept; "" for an alias
    revivedAt*: uint64 ## the revival entry's time; 0 for a registry origin
    target*: string    ## the accepted alias target; "" for an origin
    at*: string        ## where it is written: `<file>:<line>`
    what*: string      ## `[[policy]]` or `[[override]]`, for messages
    fromOverride*: bool
      ## from the index's source set, which may name packages the index
      ## does not hold (a source set with roots): those are not refused

  AliasCandidate* = object
    ## An alias the closure resolved whose registry entry now names another
    ## package than its recorded target (NPC-AREQ3 `alias-retargeted`): the
    ## solve keeps the recorded target, and the new one is a candidate the
    ## project accepts explicitly (NPC-AREQ16) -- or did (``acceptedAt``).
    alias*: string     ## the alias as the index spells it
    target*: string    ## the recorded target
    candidate*: string ## the registry's new target ("" when the entry has none)
    taken*: string     ## the target the solve takes
    acceptedAt*: string
      ## the acceptance that chose ``taken`` (`<file>:<line>`); "" when the
      ## solve took the recorded target on its own

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
    aliasCandidates*: seq[AliasCandidate]
      ## every alias the closure resolved that has a candidate target,
      ## sorted by alias

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
  ## A solver device of a Nimble package -- a feature's package or a Nim
  ## gate (``nimGateIdentity``) -- never a package of the lock.
  name.endsWith("]") and '[' in name

const NimGateMarker = "[nim "

proc nimGateIdentity*(owner, version: string): string =
  ## The solver package that decides the Nim-version conditions of
  ## ``owner``'s candidate ``version`` (``owner`` a `nimble:` identity or a
  ## feature's, NPC-AREQ7): `nimble:lib[nim 1.2.0]`. It is active exactly
  ## when that version is chosen, and its versions mirror the `nim`
  ## toolchain package's: version `<n>` requires `nim` at exactly `<n>` and
  ## the requirements whose conditions hold at Nim `<n>`. So the chosen Nim
  ## picks the gate's version, and with it which of those requirements
  ## bind. A space cannot occur in a feature name, so it names no feature.
  owner & NimGateMarker & version & "]"

proc isNimGateIdentity*(name: string): bool =
  name.endsWith("]") and NimGateMarker in name

proc solverVersion*(v: RecordVersion; text: var string): bool =
  ## The solver version text of a tag version (NPC-AREQ6, "Versions with
  ## any number of components"). When every component after the third is
  ## zero: three components, missing ones 0 (`v1.2` is `1.2.0`, `v1.0.0.0`
  ## is `1.0.0`), as before Nimble's longer versions were compared. When
  ## one of them is not: every component of the tag (`v0.7.0.8.0` is
  ## `0.7.0.8.0`). The solve compares them in Nimble's order
  ## (``repro_solver/nimble_versions``), so two spellings of one version
  ## (`0.6.0.3`, `0.6.0.3.0`) are the same version (``equalVersionExclusions``).
  ## False for any other kind.
  if v.kind != rvkTag or v.components.len == 0:
    return false
  var long = false
  for i in 3 ..< v.components.len:
    if v.components[i] != 0:
      long = true
  var c = v.components
  if long:
    text = nimbleVersionText(c)
    return true
  while c.len < 3: c.add 0
  text = $c[0] & "." & $c[1] & "." & $c[2]
  true

proc nimbleVersionOf*(version: string): Option[NimbleVersion] =
  ## A candidate's solver version in Nimble's order; none for a `#` version
  ## or a label.
  try: some(parseNimbleVersion(version))
  except ESemverParse: none(NimbleVersion)

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

proc decideOn*(nodes: seq[ConditionNode]; p: NimblePlatform;
               nim = none(NimVersionValue)): Truth =
  ## A record condition on platform ``p`` (as Nim's `isDefined` answers for
  ## the target) and, when given, at Nim ``nim`` (see ``conditions.decide``).
  ## ``tUnknown`` when it depends on a Nim version and none is given.
  decide(conditionOf(nodes), p.targetOs, p.targetCpu, p.hostOs, p.hostCpu,
    nim)

proc activeOn*(nodes: seq[ConditionNode]; p: NimblePlatform;
               nim = none(NimVersionValue)): bool =
  ## Whether a record condition holds on platform ``p`` (at Nim ``nim``):
  ## ``decideOn`` is ``tTrue``. A caller that may meet a Nim-version
  ## condition without a Nim version asks ``decideOn``.
  decideOn(nodes, p, nim) == tTrue

proc nimVersionValueOf*(text: string): Option[NimVersionValue] =
  ## A Nim toolchain version as the compiler's three fields; none when it
  ## does not read as `<major>.<minor>.<patch>`.
  var v: NimVersionValue
  if parseNimVersionValue(text, v): some(v) else: none(NimVersionValue)

proc solverRequirement(e: RequirementEntry;
                       exclusions: var seq[Exclusion];
                       toolchain = false): SolverRequirement =
  ## ``toolchain``: a `nim` range, which constrains the `nim` toolchain
  ## package and is read as a semver range; any other range constrains a
  ## `nimble:` package and is read in Nimble's order (NPC-AREQ6).
  result = SolverRequirement(entry: e, features: e.features)
  if e.targetKind == rtPackage:
    result.package = e.target
  case e.versionKind
  of rvAny: discard
  of rvRange:
    try:
      if toolchain: discard parseSemverRange(e.constraint)
      else: discard parseNimbleRange(e.constraint)
      result.range = e.constraint
    except ESemverParse as err:
      exclusions.add Exclusion(kind: exUntranslatable,
        detail: e.source & ": " & err.msg)
  of rvHead, rvCommit, rvRef:
    discard

proc activeRequirements(es: seq[RequirementEntry]; p: NimblePlatform;
                        exclusions: var seq[Exclusion]): seq[SolverRequirement] =
  ## The requirements active on ``p``: those whose condition holds there,
  ## and, marked ``nimGated``, those whose condition holds there for some
  ## Nim versions only.
  for e in es:
    case decideOn(e.condition, p)
    of tTrue: result.add solverRequirement(e, exclusions)
    of tUnknown:
      var s = solverRequirement(e, exclusions)
      s.nimGated = true
      result.add s
    of tFalse: discard

proc nimUnknownExclusion(owner: string; reqs: seq[SolverRequirement]):
    Exclusion =
  ## `nim-version-unknown`: naming each requirement and its condition, and
  ## the remedy.
  var parts: seq[string]
  for r in reqs:
    parts.add "`" & r.entry.source & "` when `" &
      renderCondition(r.entry.condition) & "`"
  Exclusion(kind: exNimVersionUnknown,
    detail: owner & parts.join(", ") & " depend" &
      (if reqs.len == 1: "s" else: "") & " on the Nim version, and this " &
      "solve declares no `nim` to decide it: declare `uses: nim` (the " &
      "project's Nim toolchain) so the solve chooses a Nim and evaluates " &
      "the condition against it")

proc gated(rs: seq[SolverRequirement]): seq[SolverRequirement] =
  for r in rs:
    if r.nimGated: result.add r

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
  if flGitlinks in r.flags and r.submodules.len == 0:
    # A record from a generator before submodule sources: its tree is the
    # superproject's alone. One with its `submodules` list is offered: its
    # tree includes every submodule's (spec § 6.1, "Submodule sources").
    result.exclusions.add Exclusion(kind: exGitlinks,
      detail: "the record has gitlinks and no submodules list: it is from " &
        "a generator before submodule sources, and its source lacks the " &
        "submodule trees")
  case r.version.kind
  of rvkTag:
    var t = ""
    discard solverVersion(r.version, t)
    result.version = t
  of rvkLabel:
    result.exclusions.add Exclusion(kind: exLabel,
      detail: "tag " & r.version.tag & " is not a version")
  of rvkSnapshot:
    # Offered under an exact `#` version no range admits (NPC-AREQ31 item
    # 5); retirement and supersession depend on the package's other
    # records and are decided in ``snapshotExclusions``.
    result.version = snapshotVersionText(r.version, r.commit)
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
    let t = decideOn(e.condition, p)
    if t != tFalse:
      var ignored: seq[Exclusion]
      var s = solverRequirement(e, ignored, toolchain = true)
      if ignored.len > 0:
        result.exclusions.add ignored
      if t == tTrue:
        result.nim.add s.range
      else:
        s.nimGated = true
        result.nimGatedNim.add s
  let needsNim = gated(result.requires) & result.nimGatedNim
  if needsNim.len > 0 and not options.nimDeclared:
    result.exclusions.add nimUnknownExclusion(versionText(r.version) &
      " of " & pkg.name & ": ", needsNim)

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
  # Nimble equality (NPC-AREQ6): versions are grouped by Nimble's order, so
  # trailing zero components never matter (`0.6.0.3` and `0.6.0.3.0` are
  # one version). Each group is then put back in record order.
  var tags: seq[(NimbleVersion, int)]
  for i, c in cs:
    if c.offered and c.record.version.kind == rvkTag:
      tags.add (c.record.version.components, i)
  tags.sort(proc (a, b: (NimbleVersion, int)): int = cmpNimble(a[0], b[0]))
  var groups: seq[seq[int]]
  for k, t in tags:
    if k > 0 and cmpNimble(tags[k - 1][0], t[0]) == 0:
      groups[^1].add t[1]
    else:
      groups.add @[t[1]]
  for g in groups.mitems: g.sort()
  for idx in groups:
    if idx.len < 2: continue
    let v = cs[idx[0]].version
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

proc newerSnapshot*(a, b: VersionRecord): bool =
  ## Whether snapshot ``a`` is newer than snapshot ``b``: first seen later,
  ## then (for one generation's two sightings, which cannot happen for one
  ## origin) the greater commit. A snapshot's date is the UTC date of its
  ## first sighting, so this orders by date first, as the spec's "by date
  ## and then by commit" does, and within a day by the sighting itself.
  if a.firstSeen != b.firstSeen: a.firstSeen > b.firstSeen
  else: a.commit > b.commit

proc snapshotExclusions*(cs: var seq[NimbleCandidate]; accepted: int;
                         originCount: int) =
  ## NPC-AREQ31 item 5, computed from the records alone. Once the package
  ## has any `tag` record -- even one that is itself excluded -- every
  ## snapshot is `snapshot-retired`, naming the first tag record. Otherwise
  ## every snapshot but the newest of the accepted origin is
  ## `snapshot-superseded`, naming the newest. Records are never dropped,
  ## so a lock that pins an excluded snapshot still finds its record.
  var firstTag = -1
  for i, c in cs:
    if c.record.version.kind == rvkTag:
      firstTag = i
      break
  if firstTag >= 0:
    let t = cs[firstTag].record
    for c in cs.mitems:
      if c.record.version.kind == rvkSnapshot:
        c.exclusions.add Exclusion(kind: exSnapshotRetired,
          detail: c.version & " is retired: the package has the tag record " &
            t.version.tag & " (" & t.commit & "), so no resolution offers " &
            "its snapshots")
    return
  var newest = -1
  for i, c in cs:
    if c.record.version.kind != rvkSnapshot: continue
    if originCount > 1 and int(c.record.origin) != accepted: continue
    if newest < 0 or newerSnapshot(c.record, cs[newest].record):
      newest = i
  if newest < 0: return
  for i, c in cs.mpairs:
    if c.record.version.kind == rvkSnapshot and i != newest and
        (originCount <= 1 or int(c.record.origin) == accepted):
      c.exclusions.add Exclusion(kind: exSnapshotSuperseded,
        detail: c.version & " is superseded by the newer snapshot " &
          cs[newest].version)

proc offeredSnapshot*(pkg: NimbleSolverPackage): int =
  ## The candidate a requirement of "any version" admits when the package
  ## has no `tag` record (NPC-AREQ31 item 5): its offered snapshot. -1 when
  ## the package has a tag record or offers no snapshot.
  for c in pkg.candidates:
    if c.record.version.kind == rvkTag: return -1
  for i, c in pkg.candidates:
    if c.record.version.kind == rvkSnapshot and c.offered: return i
  -1

proc originUrl(o: PackageOrigin): string =
  o.url & (if o.subdir.len > 0: "?subdir=" & o.subdir else: "")

proc originIdentityText(url: string): string =
  ## An origin URL without scheme, case, trailing `/` and `.git`: the
  ## identity the generator compares origins by (``assemble.sameOrigin``),
  ## so an acceptance spelled `https://h/o/r.git` names `https://h/o/r`.
  result = url.toLowerAscii()
  let sep = result.find("://")
  if sep >= 0: result = result[sep + 3 .. ^1]
  let q = result.find('?')
  var query = ""
  if q >= 0:
    query = result[q .. ^1]
    result.setLen(q)
  while result.endsWith("/"): result.setLen(result.len - 1)
  if result.endsWith(".git"): result.setLen(result.len - 4)
  result.add query

proc sameOriginText*(a, b: string): bool =
  ## Whether two origin URLs (`?subdir=` kept) name one origin by the
  ## generator's identity.
  originIdentityText(a) == originIdentityText(b)

proc originOf*(pkg: PackageEnvelope; origin: string; revivedAt: uint64): int =
  ## The entry of ``pkg.origins`` an acceptance names: the origin URL
  ## (`?subdir=` kept) spelled as recorded, else of the same identity, and
  ## the revival time (0 for an entry the registry named). -1 when the
  ## envelope records no such entry.
  for i, o in pkg.origins:
    if originUrl(o) == origin and o.revivedAt == revivedAt: return i
  for i, o in pkg.origins:
    if originIdentityText(originUrl(o)) == originIdentityText(origin) and
        o.revivedAt == revivedAt: return i
  -1

proc acceptedOrigin*(pkg: PackageEnvelope; options: NimbleSolveOptions): int =
  ## The index in ``pkg.origins`` of the origin the solve may take records
  ## from: the one an acceptance (``options.acceptances``) names for the
  ## package, else the one ``options.acceptedOrigins`` (the lock) names --
  ## of entries sharing its URL, the one whose record holds the commit
  ## ``options.acceptedCommits`` names -- else the first (the origin the name had before any repoint). -1 when
  ## the accepted origin is not an origin of the envelope.
  let k = nameKey(pkg.name)
  if k in options.acceptances and options.acceptances[k].origin.len > 0:
    let a = options.acceptances[k]
    return originOf(pkg, a.origin, a.revivedAt)
  if k in options.acceptedOrigins:
    let url = options.acceptedOrigins[k]
    result = -1
    for i, o in pkg.origins:
      if originUrl(o) == url:
        result = i
        break
    if result >= 0 and k in options.acceptedCommits:
      # The entry whose record holds the locked commit: a row taken from a
      # revival entry keeps it after the acceptance is removed, as a
      # repointed origin's row keeps its origin.
      let commit = options.acceptedCommits[k]
      for r in pkg.versions:
        if r.commit == commit and int(r.origin) < pkg.origins.len and
            originUrl(pkg.origins[int(r.origin)]) == url:
          return int(r.origin)
    return
  if pkg.origins.len > 0: 0 else: -1

proc acceptanceOf*(options: NimbleSolveOptions; name: string):
    Option[SourceAcceptance] =
  let k = nameKey(name)
  if k in options.acceptances: some(options.acceptances[k])
  else: none(SourceAcceptance)

proc policyTable*(package, repo: string; origin = ""; revivedAt = 0'u64;
                  target = ""): string =
  ## The `[[policy]]` table of `repro-catalogs.toml` that accepts, for
  ## `nimble:<package>` read through the import ``repo``, the origin
  ## ``origin`` (a revival entry when ``revivedAt`` is set) or the alias
  ## target ``target`` (NPC-AREQ16). Every remedy prints it whole.
  result = "[[policy]]\npackage = " & ("nimble:" & package).escape() &
    "\nrepo = " & repo.escape()
  if target.len > 0:
    result.add "\ntarget = " & ("nimble:" & target).escape()
  else:
    result.add "\norigin = " & origin.escape()
    if revivedAt != 0:
      result.add "\nrevived = " & formatTime(int64(revivedAt)).escape()

proc indented(text, by: string): string =
  let lines = text.splitLines()
  for i, l in lines:
    if i > 0: result.add "\n"
    result.add by & l

proc acceptRemedy(options: NimbleSolveOptions; table: string): string =
  ## "to take it, add to <file>:" and the table, indented under the line.
  let file = if options.catalogsFile.len > 0: options.catalogsFile
             else: "repro-catalogs.toml"
  "to take it, add to " & file & ":\n" & indented(table, "          ")

proc repoOf(options: NimbleSolveOptions): string =
  if options.indexRepo.len > 0: options.indexRepo
  else: "<the nimble-index import's repo>"

proc candidatesOf*(pkg: PackageEnvelope; p: NimblePlatform;
                   options = NimbleSolveOptions(excludeNewer: -1)):
    seq[NimbleCandidate] =
  let accepted = acceptedOrigin(pkg, options)
  for r in pkg.versions:
    var c = candidate(pkg, r, p, options)
    if pkg.origins.len > 1 and int(r.origin) != accepted and
        int(r.origin) < pkg.origins.len and
        pkg.origins[int(r.origin)].revivedAt != 0:
      let o = pkg.origins[int(r.origin)]
      c.exclusions.add Exclusion(kind: exRevivedOrigin,
        detail: "first seen after " & originUrl(o) & " was revived " &
          formatTime(int64(o.revivedAt)) & " (it answered again holding " &
          "none of the recorded commits); the project takes " & pkg.name &
          " from " & (if accepted >= 0: originUrl(pkg.origins[accepted]) &
                        (if pkg.origins[accepted].revivedAt != 0:
                           " as revived " &
                             formatTime(int64(pkg.origins[accepted].revivedAt))
                         else: " as recorded before the revival")
                      else: "an origin this index does not record") &
          ". A revived origin is reviewed like a repoint: the project keeps " &
          "the origin the lock records (or, with no lock row, the one it had " &
          "first) until it accepts the new one; " &
          acceptRemedy(options, policyTable(pkg.name, repoOf(options),
            originUrl(o), o.revivedAt)))
    elif pkg.origins.len > 1 and int(r.origin) != accepted:
      let theirs = if int(r.origin) < pkg.origins.len:
                     originUrl(pkg.origins[int(r.origin)]) else: "?"
      c.exclusions.add Exclusion(kind: exOtherOrigin,
        detail: "a record of " & theirs & "; the project takes " & pkg.name &
          " from " & (if accepted >= 0: originUrl(pkg.origins[accepted])
                      else: "an origin this index does not record") &
          ". A repointed name keeps the origin the lock records (or, with no " &
          "lock row, the one it had before the repoint), or the one the " &
          "project accepts; " &
          (if int(r.origin) < pkg.origins.len:
             acceptRemedy(options, policyTable(pkg.name, repoOf(options),
               theirs, pkg.origins[int(r.origin)].revivedAt))
           else: "the record names no origin of the envelope"))
    result.add c
  equalVersionExclusions(result)
  snapshotExclusions(result, accepted, pkg.origins.len)

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
      if c.record.commit == commits[0] and c.record.version.kind == rvkSnapshot:
        return PseudoMatch(found: true, index: i, range: c.version)
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
  var nameMap: Option[NimbleNameMap]
  var candidates = initTable[string, AliasCandidate]()
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
    var package = found.package
    if found.alias.len > 0:
      let ak = nameKey(found.alias)
      let accepted = options.acceptanceOf(found.alias)
      if accepted.isSome and accepted.get.target.len > 0:
        # NPC-AREQ16: the project accepts a target of the alias (its
        # candidate, or the recorded one), so every requirement that
        # reaches the package through the alias takes it.
        # ``acceptanceRefusals`` has checked the name map records it.
        let t = lookupPackage(idx, accepted.get.target)
        if t.found and t.alias.len == 0:
          package = t.package
        if ak notin candidates:
          if nameMap.isNone: nameMap = some(loadNameMap(idx))
          for e in nameMap.get.entries:
            if nameKey(e.name) == ak:
              candidates[ak] = AliasCandidate(alias: e.name, target: e.target,
                candidate: e.candidate, taken: package.name,
                acceptedAt: accepted.get.at)
      elif ak notin candidates:
        # NPC-AREQ3: the alias resolves to its recorded target; a candidate
        # the registry names now is reported, never taken. Only a solve that
        # meets an alias reads the name map.
        if nameMap.isNone: nameMap = some(loadNameMap(idx))
        for e in nameMap.get.entries:
          if nameKey(e.name) == ak and e.candidate.len > 0:
            candidates[ak] = AliasCandidate(
              alias: e.name, target: e.target, candidate: e.candidate,
              taken: e.target)
    let canon = package.name
    let ck = nameKey(canon)
    result.canonical[key] = canon
    result.canonical[ck] = canon
    if ck notin byKey:
      byKey[ck] = NimbleSolverPackage(name: canon, identity: identityOf(canon),
        origins: package.origins,
        candidates: candidatesOf(package, p, options))
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
  # A requested feature whose requirements depend on the Nim version cannot
  # be decided without a declared `nim` (NPC-AREQ7): the candidate is
  # excluded with the others.
  if not options.nimDeclared:
    for _, pkg in byKey.mpairs:
      for c in pkg.candidates.mitems:
        for (fname, freqs) in c.features:
          let g = gated(freqs)
          if fname in pkg.features and g.len > 0:
            c.exclusions.add nimUnknownExclusion("feature " & fname & " of " &
              versionText(c.record.version) & " of " & pkg.name & ": ", g)
  for _, pkg in byKey: result.packages.add pkg
  result.packages.sort(proc (a, b: NimbleSolverPackage): int =
    cmp(a.name, b.name))
  for m in missing: result.missing.add m
  result.missing.sort()
  for u in urls: result.urlTargets.add u
  result.urlTargets.sort()
  for _, c in candidates: result.aliasCandidates.add c
  result.aliasCandidates.sort(proc (a, b: AliasCandidate): int =
    cmp(nameKey(a.alias), nameKey(b.alias)))

proc aliasCandidateNotes*(input: NimbleSolverInput): seq[string] =
  ## One note per alias the closure resolved that the registry has
  ## retargeted, or whose target the project accepts (NPC-AREQ3,
  ## NPC-AREQ16): which target the solve took, and, when it took the
  ## recorded one on its own, the `[[policy]]` table that takes the new one.
  for c in input.aliasCandidates:
    if c.acceptedAt.len > 0:
      result.add "nimble:" & c.alias & " resolves to nimble:" & c.taken &
        ", the target " & c.acceptedAt & " accepts (the alias was first " &
        "recorded with nimble:" & c.target &
        (if c.candidate.len > 0: "; the registry now names nimble:" &
           c.candidate & ", alias-retargeted" else: "") & ")"
    else:
      result.add "nimble:" & c.alias & " resolves to nimble:" & c.target &
        ", the target it was first recorded with; the registry now names " &
        "nimble:" & c.candidate & " (alias-retargeted), a separate " &
        "candidate the project accepts explicitly; " &
        acceptRemedy(input.options, policyTable(c.alias,
          repoOf(input.options), target = c.candidate))

proc originLabel*(origins: seq[PackageOrigin]; i: int;
                 registryOrigin = -1): string =
  let o = origins[i]
  result = originUrl(o)
  var tags: seq[string]
  # Every entry after the first is a repoint's new origin or a revival
  # (NPC-AREQ4): the envelope keeps each origin the name has had.
  if o.revivedAt != 0: tags.add "revived " & formatTime(int64(o.revivedAt))
  elif i > 0: tags.add "repointed"
  if i == 0: tags.add "the first recorded"
  if i == registryOrigin: tags.add "the registry's now"
  if tags.len > 0: result.add " (" & tags.join(", ") & ")"

proc recordedOrigins*(pkg: PackageEnvelope): seq[string] =
  ## Every origin entry of the envelope, labelled: its URL, its revival
  ## time, whether it is the first and whether the registry names it now.
  for i in 0 ..< pkg.origins.len:
    result.add originLabel(pkg.origins, i, int(pkg.registryOrigin))

proc originCandidateNotes*(input: NimbleSolverInput): seq[string] =
  ## One note per origin of a package the closure reached whose records the
  ## solve excluded because the project has not accepted that origin
  ## (`repointed-origin`, `revived-origin`): the versions it offers, the
  ## origin the solve took, and the `[[policy]]` table that takes the other
  ## one (NPC-AREQ16). A package the project has accepted an origin for gets
  ## none: it has chosen.
  for pkg in input.packages:
    if input.options.acceptanceOf(pkg.name).isSome: continue
    var byOrigin = initOrderedTable[int, seq[string]]()
    var taken = ""
    for c in pkg.candidates:
      let oi = int(c.record.origin)
      if oi >= pkg.origins.len: continue
      if c.exclusions.anyIt(it.kind in {exOtherOrigin, exRevivedOrigin}):
        let v = if c.version.len > 0: c.version else: versionText(c.record.version)
        byOrigin.mgetOrPut(oi, @[]).add v
      elif taken.len == 0:
        taken = originUrl(pkg.origins[oi])
    for oi, versions in byOrigin:
      let o = pkg.origins[oi]
      result.add pkg.identity & ": the index records the origin " &
        originLabel(pkg.origins, oi) & ", offering " & versions.join(", ") &
        ", which the solve does not take" &
        (if taken.len > 0: " (it takes " & pkg.identity & " from " & taken & ")"
         else: "") & "; " &
        acceptRemedy(input.options, policyTable(pkg.name,
          repoOf(input.options), originUrl(o), o.revivedAt))

proc acceptanceRefusals*(idx: var NimbleIndex; options: NimbleSolveOptions;
                         indexLabel: string): seq[string] =
  ## Every acceptance of ``options.acceptances`` that names a source the
  ## index does not record for its name (NPC-AREQ16): an origin no entry of
  ## the package's envelope is, a target that is neither the alias's
  ## recorded target nor its candidate, a package or alias the index does
  ## not hold, or an origin accepted for an alias (or a target for a
  ## package). Each names where the acceptance is written. Never ignored:
  ## an acceptance the solve could not apply would leave the project on a
  ## source it did not choose, with nothing said. A source-set override of
  ## a package the index does not hold is not refused (``fromOverride``).
  var keys: seq[string]
  for k in options.acceptances.keys: keys.add k
  keys.sort()
  var nameMap: Option[NimbleNameMap]
  for k in keys:
    let a = options.acceptances[k]
    let head = a.at & ": " & a.what & " accepts "
    let found = lookupPackage(idx, a.package)
    if not found.found:
      if not a.fromOverride:
        result.add head & (if a.target.len > 0: "a target for the alias "
                           else: "an origin for ") & "nimble:" & a.package &
          ", which " & indexLabel & " does not hold; remove the table, or " &
          "name the package as the index spells it"
      continue
    if a.origin.len > 0:
      if found.alias.len > 0:
        result.add head & "the origin " & a.origin & " for nimble:" &
          a.package & ", which " & indexLabel & " records as an alias of " &
          "nimble:" & found.package.name & "; accept an origin of nimble:" &
          found.package.name & ", or a target of the alias with `target`"
        continue
      if originOf(found.package, a.origin, a.revivedAt) < 0:
        result.add head & "the origin " & a.origin &
          (if a.revivedAt != 0: " revived " & formatTime(int64(a.revivedAt))
           else: "") & " for nimble:" & found.package.name & ", which " &
          indexLabel & " does not record for it; it records " &
          recordedOrigins(found.package).join(", ") &
          ". Name one of them" &
          (if found.package.origins.anyIt(it.revivedAt != 0):
             " (a revival entry with its `revived` time)" else: "")
    else:
      if found.alias.len == 0:
        result.add head & "the target nimble:" & a.target & " for nimble:" &
          a.package & ", which " & indexLabel & " records as a package, not " &
          "an alias; an alias target is accepted only for an alias"
        continue
      if nameMap.isNone: nameMap = some(loadNameMap(idx))
      var recorded: seq[string]
      for e in nameMap.get.entries:
        if nameKey(e.name) == nameKey(found.alias):
          recorded.add e.target
          if e.candidate.len > 0: recorded.add e.candidate
      if not recorded.anyIt(nameKey(it) == nameKey(a.target)):
        var named: seq[string]
        for r in recorded: named.add "nimble:" & r
        result.add head & "the target nimble:" & a.target & " for the alias " &
          "nimble:" & found.alias & ", which " & indexLabel & " does not " &
          "record for it; its name map records " & named.join(" and ") &
          " (the recorded target" &
          (if named.len > 1: ", then the registry's new one" else: "") & ")"

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

proc anyVersionRange*(input: NimbleSolverInput; name: string): string =
  ## What "any version" of ``name`` lowers to: the exact range of the
  ## package's offered snapshot when it has no `tag` record (NPC-AREQ31
  ## item 5), else ``AnyVersionRange``, which admits every tag version and
  ## no `#` version.
  let k = nameKey(name)
  if k in input.canonical:
    let canon = input.canonical[k]
    for p in input.packages:
      if p.name == canon:
        let i = offeredSnapshot(p)
        if i >= 0: return p.candidates[i].version
        break
  AnyVersionRange

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
  if r.entry.versionKind == rvAny:
    let any = anyVersionRange(input, canon)
    if any != AnyVersionRange: rangeText = any
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

proc lowered*(input: NimbleSolverInput; reqs: seq[SolverRequirement]):
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
  ## A ``nimGated`` requirement is not here either: it is the candidate's
  ## Nim gate's (``nimGateVersionDependencies``).
  for c in pkg.candidates:
    if not c.offered:
      continue
    var plain: seq[SolverRequirement]
    for r in c.requires:
      if not r.nimGated: plain.add r
    result.add (c.version, lowered(input, plain))

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
        var plain: seq[SolverRequirement]
        for r in freqs:
          if not r.nimGated: plain.add r
        deps.add lowered(input, plain)
    result.add (c.version, deps)

proc candidateNimGated*(c: NimbleCandidate): bool =
  ## Whether the candidate has a requirement or a `nim` range under a
  ## Nim-version condition, so that its own dependencies need a Nim gate.
  gated(c.requires).len > 0 or c.nimGatedNim.len > 0

proc featureNimGated*(c: NimbleCandidate; feature: string):
    seq[SolverRequirement] =
  ## The requirements of ``feature`` at candidate ``c`` under a Nim-version
  ## condition.
  for (fname, freqs) in c.features:
    if fname == feature: result.add gated(freqs)

proc nimGateVersionDependencies*(input: NimbleSolverInput;
                                 reqs, nimRanges: seq[SolverRequirement];
                                 toolchainNim: string;
                                 nimVersions: seq[string]):
    seq[(string, seq[DependencyDecl])] =
  ## The versions of one Nim gate (``nimGateIdentity``) and the dependencies
  ## of each: for every candidate version ``n`` of the `nim` toolchain
  ## package, `nim` at exactly ``n``, then every requirement of ``reqs``
  ## whose condition holds at Nim ``n`` (evaluated as Nim evaluates it,
  ## ``conditions.evaluateNim``). A version at which a ``nimRanges`` range
  ## whose condition holds does not admit ``n`` is left out: the candidate
  ## cannot be chosen with that Nim. So is a `nim` version that does not
  ## read as `<major>.<minor>.<patch>`, whose conditions cannot be
  ## evaluated.
  for n in nimVersions:
    let v = nimVersionValueOf(n)
    if v.isNone:
      continue
    var admitted = true
    for r in nimRanges:
      if evaluate(conditionOf(r.entry.condition), input.platform.targetOs,
          input.platform.targetCpu, input.platform.hostOs,
          input.platform.hostCpu, v.get) and r.range.len > 0 and
          not rangeAdmits(r.range, n):
        admitted = false
    if not admitted:
      continue
    var active: seq[SolverRequirement]
    for r in reqs:
      if evaluate(conditionOf(r.entry.condition), input.platform.targetOs,
          input.platform.targetCpu, input.platform.hostOs,
          input.platform.hostCpu, v.get):
        active.add r
    result.add (n, @[newDependency(toolchainNim, "=" & n)] &
      lowered(input, active))
