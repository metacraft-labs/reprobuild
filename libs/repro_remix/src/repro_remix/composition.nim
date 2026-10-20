## Deterministic composition of Remix releases (spec §"Composition").
##
## `compose` takes verified member releases, optional variant values, and
## resolution artifacts, and produces:
##
## - the canonical composition record and its `CompositionId`;
## - every conflict, classified by the closed vocabulary of §"Conflict
##   classes", each marked resolved (by which resolution) or open;
## - a lowered plan: the deterministic patch sequence per target, the
##   merged configuration contributions, the union of graph fragments,
##   declared permissions, tests, health checks and data migrations, and
##   the safety inputs (members and all their ancestors).
##
## Order independence (Invariant I-12) is by construction: members and
## resolutions are canonicalised (sorted by digest) before anything else
## looks at them, and every derived list is sorted by a total key. Where a
## result would otherwise depend on order, that is a conflict.
##
## What composition can and cannot see. It works from signed manifests and
## patch blobs, before any build. The `symbol`, `file-ownership`,
## `service` and `port` classes depend on what the built graph exports and
## installs, so they are not judged here; `Composition.deferredChecks`
## names them so the install planner (M6) runs them on the built graph
## rather than anyone assuming they passed.

import std/[algorithm, sets, strutils, tables]

import ssz_serialization

import ./types
import ./wire
import ./identity
import ./verify
import ./lineage
import ./patchdiff

const
  MaxResolutions* = 1024
  MaxVariantValues* = 256

type
  ConflictClass* = enum
    ## §"Conflict classes"; closed v1 vocabulary.
    ccSource = 1
    ccPatch = 2
    ccSymbol = 3
    ccPackageVersion = 4
    ccConfiguration = 5
    ccFileOwnership = 6
    ccPermission = 7
    ccService = 8
    ccPort = 9
    ccDataMigration = 10
    ccLicense = 11
    ccLineage = 12
    ccBlocked = 13

  ResolutionKind* = enum
    rsSelectMember = 1
      ## Only the selected member's contribution to the subject applies.
    rsReplacementPatch = 2
      ## A new patch replaces every conflicting member patch on the subject
      ## file; it must touch only that file.
    rsReplacementValue = 3
      ## A new configuration value replaces the conflicting contributions.

  Resolution* = object
    ## A declarative, attributable resolution (§"Resolutions"). The
    ## composition envelope must carry `author`'s signature.
    class*: ConflictClass
    members*: seq[Digest32]
      ## The conflicting members, ascending.
    subject*: string
      ## What the conflict is about: repository, `target:path`, package,
      ## configurable, or store.
    kind*: ResolutionKind
    selected*: Digest32
      ## `rsSelectMember` only; zero otherwise.
    blob*: BlobRef
      ## `rsReplacementPatch` / `rsReplacementValue` only.
    author*: Digest32
      ## `KeyId` of the user or agent that authored the resolution.

  VariantValue* = object
    configurable*: string
    value*: BlobRef

  MemberSpec* = object
    release*: VerifiedManifest
    variant*: seq[VariantValue]

  Conflict* = object
    class*: ConflictClass
    members*: seq[Digest32]
    subject*: string
    resolvable*: bool
      ## False for `blocked`, `license`, `permission` (needs a grant, not an
      ## artifact) and incomplete lineage.
    resolvedBy*: int
      ## Index into the canonical resolutions, or -1.

  PatchStep* = object
    member*: Digest32
      ## The contributing release, or a resolution author's `KeyId` for a
      ## replacement patch.
    patch*: Patch
      ## `appliesTo*` index the member's own manifest; for a replacement
      ## patch they are meaningless and `target` is authoritative.
    target*: string
      ## Canonical target key: `<package>@<fingerprint hex>` or
      ## `source:<repo>`.

  ConfigStep* = object
    member*: Digest32
    contribution*: ConfigContribution

  Plan* = object
    ## The lowered composition. Rendered by product surfaces, never
    ## recomputed by them (Remix-Experience-Journeys.md §"Principles").
    members*: seq[Digest32]
    ancestors*: seq[Digest32]
      ## Safety inputs beyond the members themselves (union, ascending).
    targets*: seq[OriginalRef]
    dependenciesAdded*: seq[OriginalRef]
    sources*: seq[SourceTree]
    patches*: seq[PatchStep]
    configuration*: seq[ConfigStep]
    graphFragments*: seq[BlobRef]
    permissions*: seq[Permission]
    tests*: seq[(Digest32, TestRef)]
    healthChecks*: seq[(Digest32, HealthCheck)]
    dataMigrations*: seq[(Digest32, DataMigration)]
    licenses*: seq[string]

  CompositionStatus* = enum
    csReady            ## no open conflict; plan is installable input
    csNeedsResolution  ## open resolvable conflicts; nothing to install
    csRefused          ## an unresolvable conflict; nothing to install

  ComposeInputs* = object
    members*: seq[MemberSpec]
    resolutions*: seq[Resolution]
    baseLock*: Digest32
    blobs*: proc (id: Digest32): (bool, seq[byte])
      ## Patch blobs are needed for `patch` conflict detection.
    parents*: ParentResolver
    isBlocked*: proc (id: Digest32): bool
      ## True for a release, ancestor or signing key under a blocking
      ## verdict or revocation (Invariant I-7). Supplied by trust policy.
    grantedPermissions*: seq[Permission]
    admittedLicenses*: seq[string]
      ## SPDX license ids policy admits.

  Composition* = object
    id*: Digest32
    envelope*: Envelope
      ## Unsigned; resolution authors sign it with `signEnvelope`.
    resolutions*: seq[Resolution]
      ## Canonical (sorted) order; `Conflict.resolvedBy` indexes this.
    conflicts*: seq[Conflict]
    status*: CompositionStatus
    plan*: Plan
    deferredChecks*: seq[ConflictClass]

  # --- wire ---------------------------------------------------------------
  VariantValueW = object
    configurable: SszName
    value: BlobRefW

  MemberW = object
    release: Digest32
    variant: List[VariantValueW, MaxVariantValues]

  ResolutionW = object
    class: uint8
    members: List[Digest32, MaxParents]
    subject: SszText
    kind: uint8
    selected: Digest32
    blob: BlobRefW
    author: Digest32

  CompositionW = object
    members: List[MemberW, MaxParents]
    resolutions: List[ResolutionW, MaxResolutions]
    baseLock: Digest32

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------

proc cmpD(a, b: Digest32): int =
  for i in 0 ..< 32:
    if a[i] != b[i]:
      return cmp(a[i], b[i])
  0

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc targetKey(o: OriginalRef): string =
  o.package & "@" & toHex(o.interfaceFingerprint)

proc sortedMembers(xs: seq[Digest32]): seq[Digest32] =
  result = xs
  result.sort(cmpD)

proc toW(b: BlobRef): BlobRefW =
  BlobRefW(id: b.id, mediaType: SszName.init(bytesOf(b.mediaType)), size: b.size)

proc resolutionKey(r: Resolution): seq[byte] =
  ## Total order on resolutions: their canonical encoding.
  var mw = List[Digest32, MaxParents].init(r.members)
  SSZ.encode(ResolutionW(class: uint8(ord(r.class)), members: mw,
    subject: SszText.init(bytesOf(r.subject)), kind: uint8(ord(r.kind)),
    selected: r.selected, blob: toW(r.blob), author: r.author))

proc cmpBytes(a, b: seq[byte]): int =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]:
      return cmp(a[i], b[i])
  cmp(a.len, b.len)

# ---------------------------------------------------------------------------
# Version ranges for the package-version class.
#
# A range is space-separated `<op><version>` terms (op in >= > <= < =),
# versions are dotted non-negative integers. Anything else is compared as
# an opaque string: identical strings are compatible, different ones
# conflict. That is conservative — it can report a conflict a smarter
# solver would not — and never the reverse.
# ---------------------------------------------------------------------------

type
  Bound = object
    present: bool
    version: seq[int]
    inclusive: bool

proc parseVersion(s: string): (bool, seq[int]) =
  if s.len == 0: return (false, @[])
  var v: seq[int]
  for part in s.split('.'):
    if part.len == 0 or part.len > 9: return (false, @[])
    for c in part:
      if c notin {'0'..'9'}: return (false, @[])
    v.add parseInt(part)
  (true, v)

proc cmpVersion(a, b: seq[int]): int =
  for i in 0 ..< max(a.len, b.len):
    let x = (if i < a.len: a[i] else: 0)
    let y = (if i < b.len: b[i] else: 0)
    if x != y: return cmp(x, y)
  0

proc parseRange(s: string): (bool, Bound, Bound) =
  ## Returns (ok, lower, upper).
  var lo, hi: Bound
  for term in s.split(' '):
    var op, rest: string
    for candidate in [">=", "<=", ">", "<", "="]:
      if term.startsWith(candidate):
        op = candidate
        rest = term[candidate.len .. ^1]
        break
    let (ok, v) = parseVersion(rest)
    if op.len == 0 or not ok:
      return (false, lo, hi)
    proc tighterLo(b: Bound) =
      if not lo.present or cmpVersion(b.version, lo.version) > 0 or
         (cmpVersion(b.version, lo.version) == 0 and not b.inclusive):
        lo = b
    proc tighterHi(b: Bound) =
      if not hi.present or cmpVersion(b.version, hi.version) < 0 or
         (cmpVersion(b.version, hi.version) == 0 and not b.inclusive):
        hi = b
    case op
    of ">=": tighterLo(Bound(present: true, version: v, inclusive: true))
    of ">": tighterLo(Bound(present: true, version: v, inclusive: false))
    of "<=": tighterHi(Bound(present: true, version: v, inclusive: true))
    of "<": tighterHi(Bound(present: true, version: v, inclusive: false))
    else:
      tighterLo(Bound(present: true, version: v, inclusive: true))
      tighterHi(Bound(present: true, version: v, inclusive: true))
  (true, lo, hi)

proc rangesIntersect(a, b: string): bool =
  if a == b: return true
  let (okA, loA, hiA) = parseRange(a)
  let (okB, loB, hiB) = parseRange(b)
  if not okA or not okB: return false
  # Tightest lower and upper bound over both.
  var lo = loA
  if loB.present and (not lo.present or cmpVersion(loB.version, lo.version) > 0 or
     (cmpVersion(loB.version, lo.version) == 0 and not loB.inclusive)):
    lo = loB
  var hi = hiA
  if hiB.present and (not hi.present or cmpVersion(hiB.version, hi.version) < 0 or
     (cmpVersion(hiB.version, hi.version) == 0 and not hiB.inclusive)):
    hi = hiB
  if not lo.present or not hi.present: return true
  let c = cmpVersion(lo.version, hi.version)
  c < 0 or (c == 0 and lo.inclusive and hi.inclusive)

# ---------------------------------------------------------------------------
# SPDX license expressions (license class).
#
# A deliberately small evaluator over the operators SPDX defines
# (https://spdx.github.io/spdx-spec/v2.3/SPDX-license-expressions/):
# `OR` is admitted if either side is, `AND` if both are, parentheses group,
# and `X WITH E` is treated as the single id "X WITH E" so an exception
# must be admitted explicitly. Malformed expressions are not admitted.
# ---------------------------------------------------------------------------

proc licenseAdmitted(expr: string; admitted: HashSet[string]): bool =
  var tokens: seq[string]
  for raw in expr.multiReplace(("(", " ( "), (")", " ) ")).splitWhitespace():
    tokens.add raw
  var pos = 0
  proc parseOr(): bool
  proc parsePrimary(): bool =
    if pos >= tokens.len: raise newException(ValueError, "truncated")
    if tokens[pos] == "(":
      inc pos
      result = parseOr()
      if pos >= tokens.len or tokens[pos] != ")":
        raise newException(ValueError, "unbalanced")
      inc pos
    else:
      var id = tokens[pos]
      if id in ["AND", "OR", "WITH", ")"]:
        raise newException(ValueError, "operator in id position")
      inc pos
      if pos + 1 < tokens.len and tokens[pos] == "WITH":
        id = id & " WITH " & tokens[pos + 1]
        pos += 2
      result = id in admitted
  proc parseAnd(): bool =
    result = parsePrimary()
    while pos < tokens.len and tokens[pos] == "AND":
      inc pos
      let r = parsePrimary()
      result = result and r
  proc parseOr(): bool =
    result = parseAnd()
    while pos < tokens.len and tokens[pos] == "OR":
      inc pos
      let r = parseAnd()
      result = result or r
  try:
    result = parseOr()
    if pos != tokens.len: return false
  except ValueError:
    return false

# ---------------------------------------------------------------------------
# Record encoding.
# ---------------------------------------------------------------------------

proc encodeRecord(members: seq[MemberSpec]; resolutions: seq[Resolution];
                  baseLock: Digest32): seq[byte] =
  var mws: seq[MemberW]
  for m in members:
    var vws: seq[VariantValueW]
    for v in m.variant:
      vws.add VariantValueW(configurable: SszName.init(bytesOf(v.configurable)),
                            value: toW(v.value))
    if vws.len > MaxVariantValues:
      refuse(rrBound, "variant has too many values")
    mws.add MemberW(release: Digest32(m.release.id),
                    variant: List[VariantValueW, MaxVariantValues].init(vws))
  var rws: seq[ResolutionW]
  for r in resolutions:
    rws.add ResolutionW(class: uint8(ord(r.class)),
      members: List[Digest32, MaxParents].init(r.members),
      subject: SszText.init(bytesOf(r.subject)), kind: uint8(ord(r.kind)),
      selected: r.selected, blob: toW(r.blob), author: r.author)
  SSZ.encode(CompositionW(members: List[MemberW, MaxParents].init(mws),
    resolutions: List[ResolutionW, MaxResolutions].init(rws), baseLock: baseLock))

# ---------------------------------------------------------------------------
# compose.
# ---------------------------------------------------------------------------

proc compose*(input: ComposeInputs): Composition =
  if input.members.len == 0:
    refuse(rrMalformed, "a composition needs at least one member")
  if input.members.len > MaxParents:
    refuse(rrBound, "composition has " & $input.members.len & " members")
  if input.resolutions.len > MaxResolutions:
    refuse(rrBound, "composition has too many resolutions")

  # 1. Canonicalise. Everything below reads only these.
  var members = input.members
  members.sort(proc (a, b: MemberSpec): int =
    cmpD(Digest32(a.release.id), Digest32(b.release.id)))
  for i in 1 ..< members.len:
    if members[i - 1].release.id == members[i].release.id:
      refuse(rrDuplicate, "a release is listed twice as a member")
  for m in members.mitems:
    m.variant.sort(proc (a, b: VariantValue): int = cmp(a.configurable, b.configurable))
    for i in 1 ..< m.variant.len:
      if m.variant[i - 1].configurable == m.variant[i].configurable:
        refuse(rrDuplicate, "a variant sets one configurable twice")
    for v in m.variant:
      var exposed = false
      for e in m.release.manifest.exposedConfigurables:
        if e.name == v.configurable: exposed = true
      if not exposed:
        refuse(rrDanglingReference, "variant sets " & v.configurable &
               ", which the release does not expose")
  var resolutions = input.resolutions
  for r in resolutions.mitems:
    r.members = sortedMembers(r.members)
  resolutions.sort(proc (a, b: Resolution): int =
    cmpBytes(resolutionKey(a), resolutionKey(b)))
  for i in 1 ..< resolutions.len:
    if resolutionKey(resolutions[i - 1]) == resolutionKey(resolutions[i]):
      refuse(rrDuplicate, "a resolution is listed twice")
  var memberIds: seq[Digest32]
  for m in members:
    memberIds.add Digest32(m.release.id)
  result.resolutions = resolutions

  # 2. Identity.
  let body = encodeRecord(members, resolutions, input.baseLock)
  result.envelope = Envelope(schemaVersion: RemixSchemaVersion,
    requiredFeatures: 0, recordKind: rkComposition, body: body)
  result.id = envelopeIdentity(result.envelope)

  var conflicts: seq[Conflict]
  proc add(class: ConflictClass; ms: seq[Digest32]; subject: string;
           resolvable = true) =
    conflicts.add Conflict(class: class, members: sortedMembers(ms),
                           subject: subject, resolvable: resolvable,
                           resolvedBy: -1)

  # 3. Lineage and blocking (Invariant I-7, §"Lineage").
  var ancestors = initHashSet[Digest32]()
  var lineages = initTable[Digest32, Lineage]()
  for m in members:
    let mid = Digest32(m.release.id)
    let l = walkLineage(m.release.id, input.parents)
    lineages[mid] = l
    if not l.isComplete:
      add(ccLineage, @[mid], "incomplete-lineage", resolvable = false)
    for a in l.ancestors:
      ancestors.incl Digest32(a)
    var blocked = input.isBlocked(mid)
    for a in l.ancestors:
      if input.isBlocked(Digest32(a)): blocked = true
    for k in m.release.authors:
      if input.isBlocked(Digest32(k)): blocked = true
    if blocked:
      add(ccBlocked, @[mid], "blocked", resolvable = false)
  for m in members:
    for other in members:
      if m.release.id != other.release.id and
         lineages[Digest32(other.release.id)].isAncestor(m.release.id):
        add(ccLineage, @[Digest32(m.release.id), Digest32(other.release.id)],
            "ancestor-member")

  # 4. Sources: one repository, one revision.
  var sourceRevs = initTable[string, seq[(Digest32, string)]]()
  for m in members:
    for s in m.release.manifest.sources:
      sourceRevs.mgetOrPut(s.repo, @[]).add (Digest32(m.release.id), s.revision)
  for repo, uses in sourceRevs:
    var revs = initHashSet[string]()
    var ms: seq[Digest32]
    for (mid, rev) in uses:
      revs.incl rev
      ms.add mid
    if revs.len > 1:
      add(ccSource, ms, repo)

  # 5. Package versions: same package, incompatible pins.
  var byPackage = initTable[string, seq[(Digest32, Target)]]()
  for m in members:
    for t in m.release.manifest.targets:
      byPackage.mgetOrPut(t.original.package, @[]).add (Digest32(m.release.id), t)
  for pkg, uses in byPackage:
    for i in 0 ..< uses.len:
      for j in i + 1 ..< uses.len:
        let (ma, ta) = uses[i]
        let (mb, tb) = uses[j]
        if ma == mb: continue
        var compatible = true
        if ta.original.catalogRevision != tb.original.catalogRevision or
           ta.original.catalogRemote != tb.original.catalogRemote:
          compatible = false
        elif ta.constraintKind == ckExactFingerprint and
             tb.constraintKind == ckExactFingerprint:
          compatible = ta.original.interfaceFingerprint == tb.original.interfaceFingerprint
        elif ta.constraintKind == ckVersionRange and tb.constraintKind == ckVersionRange:
          compatible = rangesIntersect(ta.constraint, tb.constraint)
        else:
          # An exact pin against a range cannot be judged without the
          # catalog's version of that fingerprint; refuse to guess.
          compatible = false
        if not compatible:
          add(ccPackageVersion, @[ma, mb], pkg)

  # 6. Patches: overlapping hunks on one file of one target.
  type Touch = object
    member: Digest32
    hunks: seq[Hunk]
  var touches = initTable[string, seq[Touch]]()
  for m in members:
    let man = m.release.manifest
    for p in man.patches:
      let tkey =
        if p.appliesToKind == ptTarget: targetKey(man.targets[p.appliesToIndex].original)
        else: "source:" & man.sources[p.appliesToIndex].repo
      let (found, bytes) = input.blobs(p.blob.id)
      if not found:
        refuse(rrMissingBlob, "patch blob " & toHex(p.blob.id) & " is unavailable")
      if blobId(bytes) != p.blob.id:
        refuse(rrDigestMismatch, "patch blob does not match its digest")
      for fp in parseUnifiedDiff(strOf(bytes), int(p.strip)):
        touches.mgetOrPut(tkey & ":" & fp.path, @[]).add Touch(
          member: Digest32(m.release.id), hunks: fp.hunks)
  for file, ts in touches:
    var involved: seq[Digest32]
    for i in 0 ..< ts.len:
      for j in i + 1 ..< ts.len:
        if ts[i].member == ts[j].member: continue
        block pair:
          for a in ts[i].hunks:
            for b in ts[j].hunks:
              if overlaps(a, b):
                if ts[i].member notin involved: involved.add ts[i].member
                if ts[j].member notin involved: involved.add ts[j].member
                break pair
    if involved.len > 0:
      add(ccPatch, involved, file)

  # 7. Configuration: schema mismatch, or order-dependent equal-priority
  # contributions (two replaces with different values, or replace + append).
  var byConfig = initTable[string, seq[(Digest32, ConfigContribution)]]()
  for m in members:
    for c in m.release.manifest.configuration:
      byConfig.mgetOrPut(c.configurable, @[]).add (Digest32(m.release.id), c)
  for name, uses in byConfig:
    var involved: seq[Digest32]
    for i in 0 ..< uses.len:
      for j in i + 1 ..< uses.len:
        let (ma, ca) = uses[i]
        let (mb, cb) = uses[j]
        if ma == mb: continue
        var clash = ca.schemaFingerprint != cb.schemaFingerprint
        if ca.priority == cb.priority:
          if ca.operation == coReplace and cb.operation == coReplace and
             ca.value.id != cb.value.id:
            clash = true
          if ca.operation != cb.operation:
            clash = true
        if clash:
          if ma notin involved: involved.add ma
          if mb notin involved: involved.add mb
    if involved.len > 0:
      add(ccConfiguration, involved, name)

  # 8. Data migrations: one store, one migrating member.
  var byStore = initTable[string, seq[Digest32]]()
  for m in members:
    for d in m.release.manifest.dataMigrations:
      byStore.mgetOrPut(d.store, @[]).add Digest32(m.release.id)
  for store, ms in byStore:
    if ms.len > 1:
      add(ccDataMigration, ms, store)

  # 9. Permissions: the union must be granted (a grant, not an artifact).
  var granted = initHashSet[(PermissionKind, string)]()
  for g in input.grantedPermissions:
    granted.incl (g.kind, g.scope)
  for m in members:
    for p in m.release.manifest.permissions:
      if (p.kind, p.scope) notin granted:
        add(ccPermission, @[Digest32(m.release.id)],
            $p.kind & (if p.scope.len > 0: ":" & p.scope else: ""),
            resolvable = false)

  # 10. Licenses: each member's expression must be admitted by policy.
  var admitted = initHashSet[string]()
  for l in input.admittedLicenses:
    admitted.incl l
  for m in members:
    if not licenseAdmitted(m.release.manifest.license, admitted):
      add(ccLicense, @[Digest32(m.release.id)], m.release.manifest.license,
          resolvable = false)

  # 11. Match resolutions to conflicts. A resolution that matches nothing,
  # or tries to resolve an unresolvable class, is refused: an unused
  # resolution would still change the composition identity silently.
  var used = newSeq[bool](resolutions.len)
  for c in conflicts.mitems:
    for i, r in resolutions:
      if r.class == c.class and r.members == c.members and r.subject == c.subject:
        if not c.resolvable:
          refuse(rrForbiddenContent, "a resolution targets an unresolvable " &
                 $c.class & " conflict")
        case r.kind
        of rsSelectMember:
          if r.selected notin c.members:
            refuse(rrDanglingReference, "resolution selects a member outside the conflict")
        of rsReplacementPatch:
          if c.class != ccPatch:
            refuse(rrForbiddenContent, "a replacement patch resolves only a patch conflict")
          # It must touch exactly the conflicting file and nothing else, or
          # a resolution could smuggle unrelated changes past review.
          let (found, bytes) = input.blobs(r.blob.id)
          if not found:
            refuse(rrMissingBlob, "replacement patch blob is unavailable")
          if blobId(bytes) != r.blob.id:
            refuse(rrDigestMismatch, "replacement patch does not match its digest")
          let files = parseUnifiedDiff(strOf(bytes), 1)
          let colon = c.subject.rfind(':')
          if files.len != 1 or files[0].path != c.subject[colon + 1 .. ^1]:
            refuse(rrForbiddenContent, "replacement patch touches more than the conflicting file")
        of rsReplacementValue:
          if c.class != ccConfiguration:
            refuse(rrForbiddenContent, "a replacement value resolves only a configuration conflict")
        c.resolvedBy = i
        used[i] = true
  for i, u in used:
    if not u:
      refuse(rrDanglingReference, "resolution " & $i & " matches no conflict")

  conflicts.sort(proc (a, b: Conflict): int =
    result = cmp(ord(a.class), ord(b.class))
    if result == 0: result = cmp(a.subject, b.subject)
    if result == 0:
      for k in 0 ..< min(a.members.len, b.members.len):
        result = cmpD(a.members[k], b.members[k])
        if result != 0: return
      result = cmp(a.members.len, b.members.len))
  result.conflicts = conflicts

  result.status = csReady
  for c in conflicts:
    if c.resolvedBy < 0:
      if not c.resolvable:
        result.status = csRefused
        break
      result.status = csNeedsResolution
  result.deferredChecks = @[ccSymbol, ccFileOwnership, ccService, ccPort]

  # 12. Lower the plan. Built even when not ready, so a surface can show
  # what would happen; `status` alone says whether it may be installed.
  var plan = Plan(members: memberIds)
  var anc: seq[Digest32]
  for a in ancestors:
    if a notin memberIds: anc.add a
  plan.ancestors = sortedMembers(anc)

  let finalConflicts = result.conflicts
  let finalResolutions = result.resolutions
  proc droppedBy(mid: Digest32; class: ConflictClass; subject: string): bool =
    ## Whether a resolution removes this member's contribution to `subject`.
    for c in finalConflicts:
      if c.class == class and c.subject == subject and c.resolvedBy >= 0 and
         mid in c.members:
        let r = finalResolutions[c.resolvedBy]
        case r.kind
        of rsSelectMember: return r.selected != mid
        else: return true
    false

  var targetSeen = initHashSet[string]()
  var depSeen = initHashSet[string]()
  for m in members:
    let mid = Digest32(m.release.id)
    let man = m.release.manifest
    for t in man.targets:
      if targetSeen.containsOrIncl(targetKey(t.original)) == false:
        plan.targets.add t.original
    for d in man.dependenciesAdded:
      if depSeen.containsOrIncl(targetKey(d)) == false:
        plan.dependenciesAdded.add d
    for s in man.sources:
      if not droppedBy(mid, ccSource, s.repo):
        var dup = false
        for x in plan.sources:
          if x == s: dup = true
        if not dup: plan.sources.add s
    for p in man.patches:
      let tkey =
        if p.appliesToKind == ptTarget: targetKey(man.targets[p.appliesToIndex].original)
        else: "source:" & man.sources[p.appliesToIndex].repo
      var drop = false
      let (_, bytes) = input.blobs(p.blob.id)
      for fp in parseUnifiedDiff(strOf(bytes), int(p.strip)):
        if droppedBy(mid, ccPatch, tkey & ":" & fp.path): drop = true
      if not drop:
        plan.patches.add PatchStep(member: mid, patch: p, target: tkey)
    for c in man.configuration:
      if not droppedBy(mid, ccConfiguration, c.configurable):
        plan.configuration.add ConfigStep(member: mid, contribution: c)
    for f in man.graphFragments:
      if f notin plan.graphFragments: plan.graphFragments.add f
    for p in man.permissions:
      if p notin plan.permissions: plan.permissions.add p
    for t in man.tests: plan.tests.add (mid, t)
    for h in man.healthChecks: plan.healthChecks.add (mid, h)
    for d in man.dataMigrations:
      if not droppedBy(mid, ccDataMigration, d.store):
        plan.dataMigrations.add (mid, d)
    if man.license notin plan.licenses: plan.licenses.add man.license
    # Variant values enter as set-priority replacements from the member.
    for v in m.variant:
      for e in man.exposedConfigurables:
        if e.name == v.configurable:
          plan.configuration.add ConfigStep(member: mid, contribution:
            ConfigContribution(configurable: v.configurable,
              schemaFingerprint: e.schemaFingerprint, priority: cpSet,
              operation: coReplace, value: v.value))
  # Resolution content enters as the resolver's own declarative content.
  for r in result.resolutions:
    case r.kind
    of rsReplacementValue:
      var schema: Digest32
      for (_, c) in byConfig.getOrDefault(r.subject):
        schema = c.schemaFingerprint
      plan.configuration.add ConfigStep(member: r.author, contribution:
        ConfigContribution(configurable: r.subject, schemaFingerprint: schema,
          priority: cpOverride, operation: coReplace, value: r.blob))
    of rsReplacementPatch:
      let colon = r.subject.rfind(':')
      plan.patches.add PatchStep(member: r.author, target: r.subject[0 ..< colon],
        patch: Patch(appliesToKind: ptTarget, appliesToIndex: 0, blob: r.blob,
                     strip: 1, order: 0))
    of rsSelectMember: discard

  # Total orders on every plan list.
  plan.targets.sort(proc (a, b: OriginalRef): int = cmp(targetKey(a), targetKey(b)))
  plan.dependenciesAdded.sort(proc (a, b: OriginalRef): int = cmp(targetKey(a), targetKey(b)))
  plan.sources.sort(proc (a, b: SourceTree): int = cmp(a.repo & a.revision, b.repo & b.revision))
  plan.patches.sort(proc (a, b: PatchStep): int =
    result = cmp(a.target, b.target)
    if result == 0: result = cmpD(a.member, b.member)
    if result == 0: result = cmp(int(a.patch.order), int(b.patch.order)))
  plan.configuration.sort(proc (a, b: ConfigStep): int =
    result = cmp(a.contribution.configurable, b.contribution.configurable)
    if result == 0: result = cmp(ord(a.contribution.priority), ord(b.contribution.priority))
    if result == 0: result = cmpD(a.member, b.member))
  plan.graphFragments.sort(proc (a, b: BlobRef): int = cmpD(a.id, b.id))
  plan.permissions.sort(proc (a, b: Permission): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0: result = cmp(a.scope, b.scope))
  plan.licenses.sort()
  result.plan = plan

proc requiredSigners*(c: Composition): seq[Digest32] =
  ## The resolution authors, ascending and unique: who must sign.
  for r in c.resolutions:
    if r.author notin result: result.add r.author
  result.sort(cmpD)

proc verifyCompositionSignatures*(c: Composition) =
  ## Every resolution is attributable: its author signed the record, and
  ## nobody else did (§"Resolutions").
  verifySignatures(c.envelope, c.requiredSigners)
