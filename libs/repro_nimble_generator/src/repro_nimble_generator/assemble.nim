## The publisher's computation for one package: what the `shard` edge does
## with the fetch edges' outputs and the previous generation's shard.
##
## Pure. Its inputs are the previous envelope and observation of the package
## (from the previous root), what the origin answered now (`refs`, and the
## history when one was fetched), the `source` and `read` outputs of the
## versions sighted now, and the generation's parameters. Its outputs are the
## package's new envelope and observation and the origin events of this
## generation (NPC-AREQ4).
##
## * **Records are never edited.** Every record of the previous envelope is
##   copied unchanged; a record is only ever added. A moved tag's new commit
##   is a new record beside the old one, a removed tag's record stays, and a
##   repointed package keeps its old origin, which its old records name.
## * **First sighting.** A version's `first_seen` is the generation time at
##   which this generator first saw its commit (NPC-AREQ11), never a date the
##   origin supplies. Under `cooldown_days` a version is held -- recorded in
##   the observation with its first sighting, not in the index -- until it
##   has been observable that long (threat model G8).
## * **Snapshots** (NPC-AREQ31 item 5). A package whose origin lists no tag
##   that reads as a version, and that has no `tag` record, is sighted at the
##   commit its `HEAD` names, as a `snapshot` dated by its first sighting.
##   It is held and admitted like any version. A later `HEAD` is another
##   sighting and so another record; the earlier ones stay, like every
##   record, and the solver input decides which one is offered.
## * **Events** compare the previous observation with this one: the origin
##   the registry names (`repointed`), whether it answers (`gone`), the
##   commit each recorded tag names (`tag-moved`, `tag-removed`) and, when
##   the previous `HEAD` is no longer on any branch, which recorded commits
##   are no longer reachable from the branches (`history-rewritten`).

import std/[algorithm, options, sets, strutils, tables]

import repro_domain_types/nimble_index
import repro_nimble_index/builder
import repro_nimble_reader/requirements except nameKey

import ./edge_objects
import ./source_set
import ./source_tree
import ./submodules

type
  Sighting* = object
    ## A version the origin offers now: a tag, `HEAD` (`track_head`), or a
    ## commit an override or a `#<commit>` requirement names.
    version*: RecordVersion
    commit*: string

  VersionBuild* = object
    ## The `source` and `read` outputs of one sighted commit.
    source*: SourceAnswer
    read*: Option[VersionRecord]
      ## the record as the `read` edge read it from the `.nimble`; none when
      ## the tree has no single `.nimble`

  ExpansionKind* = enum
    exFull, exAmbiguous, exNone, exUnavailable

  Expansion* = object
    kind*: ExpansionKind
    full*: string
    candidates*: seq[string]

  PackageInput* = object
    name*: string
    origin*: PackageOrigin
    listed*: bool
      ## the registry or the source set names the package now
    unlisted*: bool
      ## an unlisted source (a URL requirement) indexed under
      ## `unlisted = "allow"`
    previous*: Option[PackageEnvelope]
    previousObservation*: Option[PackageObservation]
    refs*: Option[RefsAnswer]
    history*: Option[HistoryAnswer]
    sightings*: seq[Sighting]
    builds*: Table[string, VersionBuild] ## by commit
    overrides*: seq[OverrideRecord]      ## this package's requirement overrides

  GenerationParams* = object
    generatedAt*: uint64
    cooldownSeconds*: uint64
    expansions*: Table[string, Expansion]
      ## `<target name key>#<abbreviation>` -> its expansion
    resolveName*: proc(name: string): string {.gcsafe.}
      ## a requirement's package name -> the canonical name the index uses,
      ## or "" when the index has none

  PackageOutput* = object
    envelope*: Option[PackageEnvelope]
    observation*: PackageObservation
    events*: seq[OriginEvent]
    diagnostics*: seq[string]

proc sightingKey*(v: RecordVersion; commit: string): string =
  $chr(ord(v.kind)) & v.tag & "\0" & commit

proc expansionKey*(targetName, abbreviation: string): string =
  nameKey(targetName) & "#" & abbreviation

proc originLabel(o: PackageOrigin): string =
  o.url & (if o.subdir.len > 0: "?subdir=" & o.subdir else: "")

proc sameOrigin*(a, b: PackageOrigin): bool =
  ## Origin identity: the URL compared without scheme case, a trailing
  ## `.git` or `/`, and the subdirectory.
  proc norm(u: string): string =
    result = u.toLowerAscii()
    let sep = result.find("://")
    if sep >= 0: result = result[sep + 3 .. ^1]
    while result.endsWith("/"): result.setLen(result.len - 1)
    if result.endsWith(".git"): result.setLen(result.len - 4)
  norm(a.url) == norm(b.url) and a.subdir.strip(chars = {'/'}) ==
    b.subdir.strip(chars = {'/'}) and a.vcs == b.vcs

proc validTagName*(t: string): bool =
  ## A tag name the index can record: printable ASCII without spaces,
  ## within the name bound.
  if t.len == 0 or t.len > MaxNameBytes: return false
  for c in t:
    if ord(c) < 0x21 or ord(c) > 0x7e: return false
  true

proc versionOfTag*(tag: string): RecordVersion =
  var comps: seq[uint64]
  if parseTagVersion(tag, comps):
    RecordVersion(kind: rvkTag, components: comps, tag: tag)
  else:
    RecordVersion(kind: rvkLabel, tag: tag)

proc hexToId(hex: string; id: var array[32, byte]): bool =
  if hex.len != 64: return false
  for i in 0 ..< 32:
    try: id[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError: return false
  true

proc versionLabel(r: VersionRecord): string =
  if r.version.tag.len > 0: r.version.tag else: r.commit

proc hasTagRecord*(records: openArray[VersionRecord]): bool =
  ## Whether a package has a `tag` record: then it gets no new snapshot
  ## (NPC-AREQ31 item 5).
  for r in records:
    if r.version.kind == rvkTag: return true
  false

proc datedAt(v: RecordVersion; firstSeen: uint64): RecordVersion =
  ## A sighted version as it is held or recorded: a snapshot takes the UTC
  ## date of its first sighting; any other kind is unchanged.
  if v.kind == rvkSnapshot: snapshotVersion(firstSeen) else: v

# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

proc overrideFor(input: PackageInput; tag: string): Option[OverrideRecord] =
  for o in input.overrides:
    if o.hasRequires and o.tag == tag: return some(o)
  for o in input.overrides:
    if o.hasRequires and o.tag.len == 0: return some(o)
  none(OverrideRecord)

proc entryFrom(r: Requirement): RequirementEntry =
  case r.target.kind
  of tkPackage:
    result.targetKind = rtPackage
    result.target = r.target.name
  of tkUrl:
    result.targetKind = rtUrl
    result.target = r.target.url
    result.subdir = r.target.subdir
  case r.version.kind
  of vkAny: result.versionKind = rvAny
  of vkHead: result.versionKind = rvHead
  of vkRange:
    result.versionKind = rvRange
    result.constraint = r.version.normalized
  of vkCommit:
    result.versionKind = rvCommit
    result.constraint = r.version.commit
  of vkRef:
    result.versionKind = rvRef
    result.constraint = r.version.refName
  result.features = r.features
  result.source = r.source

proc expandCommits(entries: var seq[RequirementEntry]; params: GenerationParams;
                   label: string; unreadable: var bool;
                   diagnostics: var seq[string]) =
  ## Threat model G15: an abbreviated `#<commit>` is expanded to the one
  ## commit of the target's origin it names; an abbreviation naming two or
  ## more, or none, is refused (the requiring version is not offered) and
  ## the refusal names every candidate.
  for e in entries.mitems:
    if e.versionKind != rvCommit or e.constraint.len in [40, 64]:
      continue
    let target =
      if e.targetKind == rtPackage and params.resolveName != nil:
        params.resolveName(e.target)
      else: ""
    let key = expansionKey(if target.len > 0: target else: e.target,
      e.constraint)
    let x = params.expansions.getOrDefault(key,
      Expansion(kind: exUnavailable))
    case x.kind
    of exFull:
      e.constraint = x.full
    of exAmbiguous:
      unreadable = true
      diagnostics.add label & ": requirement " & e.source.escape() &
        " is refused: abbreviation " & e.constraint & " names " &
        $x.candidates.len & " commits of " & e.target & ": " &
        x.candidates.join(", ")
    of exNone:
      unreadable = true
      diagnostics.add label & ": requirement " & e.source.escape() &
        " is refused: no commit of " & e.target & " starts with " &
        e.constraint
    of exUnavailable:
      unreadable = true
      diagnostics.add label & ": requirement " & e.source.escape() &
        " is refused: the commits of " & e.target & " could not be listed " &
        "to expand " & e.constraint

proc buildRecord*(input: PackageInput; params: GenerationParams;
                  s: Sighting; b: VersionBuild; originIndex: uint16;
                  firstSeen: uint64; diagnostics: var seq[string]):
                    VersionRecord =
  ## The record of one admitted version.
  let label = input.name & "@" & (if s.version.tag.len > 0: s.version.tag
                                  else: s.commit)
  let f = b.source.facts
  if b.read.isSome:
    result = b.read.get
  else:
    result = VersionRecord(readerClass: rrcUnreadable,
      resolutionClass: rrcUnreadable, flags: {flUnreadable})
    case f.nimble
    of nlNone: diagnostics.add label & ": the tree has no `.nimble` file"
    of nlAmbiguous:
      diagnostics.add label & ": the tree has " & $f.nimbleCandidates.len &
        " `.nimble` files: " & f.nimbleCandidates.join(", ")
    of nlFound: discard
  result.version = s.version
  result.commit = s.commit
  discard hexToId(f.treeDigest, result.tree)
  discard hexToId(f.archiveSha256, result.archiveSha256)
  result.size = uint64(max(f.archiveSize, 0))
  result.firstSeen = firstSeen
  result.origin = originIndex
  result.layout.modules = modulesUnder(f.files, result.layout.srcDir)
  if result.layout.modules.len > MaxModules:
    # More top-level modules than a record holds: without the list, the
    # closure's module collisions (G16) could not be checked.
    diagnostics.add label & ": " & $result.layout.modules.len &
      " top-level modules under srcDir, more than a record holds (" &
      $MaxModules & "); the version is unreadable"
    result.layout.modules = @[]
    result.flags.incl flUnreadable
  var linkOut = false
  for l in f.links:
    if l.verdict == lvOutside:
      linkOut = true
      diagnostics.add label & ": symbolic link " & l.path.escape() &
        " points outside the tree (" & l.target.escape() & "); stored as a " &
        "link, never followed, and the version is unreadable"
  if f.gitlinks.len > 0:
    # The source object includes the submodule trees (`source-compose`);
    # the record names them, as provenance (spec § 6.1).
    result.flags.incl flGitlinks
    for sm in f.submodules:
      diagnostics.add label & ": gitlink " & sm.path.escape() & " url " &
        sm.url.escape() & ": " & sm.verdict
    for p in b.source.pins:
      result.submodules.add RecordSubmodule(path: p.path, url: p.url,
        commit: p.commit)
    result.submodules.sort(proc (a, b: RecordSubmodule): int =
      cmp(a.path, b.path))
  if input.unlisted:
    result.flags.incl flUnlisted
  # NPC-AREQ8 step 2: an override supplies what the reader could not read.
  let readable = result.readerClass in {rrcPlain, rrcClosedWhen, rrcFeature} and
    result.nimbleFile.isSome
  if not readable:
    let o = overrideFor(input, s.version.tag)
    if o.isSome:
      var nimEntries, reqs: seq[RequirementEntry]
      var bad = false
      for text in o.get.requires:
        let reading = readRequirements(text)
        for err in reading.errors:
          bad = true
          diagnostics.add label & ": override requirement " &
            err.input.escape() & " is " & $err.kind & ": " & err.reason
        for r in reading.requirements:
          if isNimTarget(r): nimEntries.add entryFrom(r)
          else: reqs.add entryFrom(r)
      if not bad:
        result.nim = nimEntries
        result.requires = reqs
        result.features = @[]
        result.flags.incl flOverrideApplied
        result.flags.excl flUnreadable
  var unreadable = false
  expandCommits(result.requires, params, label, unreadable, diagnostics)
  for feat in result.features.mitems:
    expandCommits(feat.requires, params, label, unreadable, diagnostics)
  if linkOut or unreadable:
    result.flags.incl flUnreadable

# ---------------------------------------------------------------------------
# One package
# ---------------------------------------------------------------------------

proc assemblePackage*(input: PackageInput; params: GenerationParams):
    PackageOutput =
  let now = params.generatedAt
  var origins: seq[PackageOrigin]
  var prevRecords: seq[VersionRecord]
  var prevOriginIndex = -1
  if input.previous.isSome:
    origins = input.previous.get.origins
    prevRecords = input.previous.get.versions
    prevOriginIndex = int(input.previous.get.registryOrigin)
  var originIndex = -1
  for i, o in origins:
    if sameOrigin(o, input.origin):
      originIndex = i
      break
  if originIndex < 0:
    origins.add input.origin
    originIndex = origins.high
  let repointed = prevOriginIndex >= 0 and prevOriginIndex != originIndex
  if repointed:
    result.events.add OriginEvent(kind: oeRepointed, package: input.name,
      before: originLabel(origins[prevOriginIndex]),
      after: originLabel(input.origin), observedAt: now)

  # ---- the observation ------------------------------------------------------
  var obs = PackageObservation(name: input.name, origin: input.origin,
    state: osGone)
  let prevObs = input.previousObservation
  let comparable = prevObs.isSome and not repointed and
    sameOrigin(prevObs.get.origin, input.origin)
  if input.listed and input.refs.isSome:
    let r = input.refs.get
    case r.state
    of anOk:
      obs.state = osAnswering
      obs.headRef = if validTagName(r.headRef): r.headRef else: ""
      obs.head = r.head
      for (t, c) in r.tags:
        if validTagName(t):
          obs.tags.add ObservedTag(name: t, commit: c)
        else:
          result.diagnostics.add input.name & ": tag " & t.escape() &
            " cannot be recorded (not printable ASCII, or too long)"
    of anFailed: obs.state = osGone
    of anRefused: obs.state = osRefused
  if comparable and prevObs.get.state == osAnswering and
      obs.state != osAnswering:
    result.events.add OriginEvent(kind: oeGone, package: input.name,
      before: "answering",
      after: (if not input.listed: "not listed by the registry"
              elif obs.state == osRefused: "refused by the egress policy"
              else: "no answer"),
      observedAt: now)

  var recordedTags = initOrderedTable[string, string]()
  for r in prevRecords:
    if r.version.kind in {rvkTag, rvkLabel} and int(r.origin) == originIndex:
      recordedTags[r.version.tag] = r.commit
  if comparable and prevObs.get.state == osAnswering and
      obs.state == osAnswering:
    var before = initTable[string, string]()
    for t in prevObs.get.tags: before[t.name] = t.commit
    var now2 = initTable[string, string]()
    for t in obs.tags: now2[t.name] = t.commit
    var tags: seq[string]
    for t in recordedTags.keys: tags.add t
    tags.sort()
    for t in tags:
      let b = before.getOrDefault(t, "")
      let a = now2.getOrDefault(t, "")
      if b == a: continue
      if a.len == 0:
        result.events.add OriginEvent(kind: oeTagRemoved, package: input.name,
          version: t, before: b, after: "", observedAt: now)
      else:
        result.events.add OriginEvent(kind: oeTagMoved, package: input.name,
          version: t, before: b, after: a, observedAt: now)
    if input.history.isSome and input.history.get.state == anOk and
        prevObs.get.head.len > 0:
      let h = input.history.get
      let onBranches = toHashSet(h.branchCommits)
      if prevObs.get.head notin onBranches:
        var seen = initHashSet[string]()
        for r in prevRecords:
          if int(r.origin) == originIndex and r.commit notin onBranches and
              r.commit notin seen:
            seen.incl r.commit
            result.events.add OriginEvent(kind: oeHistoryRewritten,
              package: input.name, version: versionLabel(r),
              before: r.commit, after: "", observedAt: now)
  elif comparable and obs.state == osAnswering:
    # The origin answers again after an observation that did not answer
    # (gone or refused): that observation lists no tag and no `HEAD`, so
    # the records are the comparison. A tag recorded for a version that now
    # names another commit is `tag-moved`, one that is no longer listed is
    # `tag-removed` (NPC-AREQ4). An origin whose branches now reach none of
    # the recorded commits -- a re-registered name serving other history --
    # is `history-rewritten` for each recorded commit it no longer holds at
    # all. A commit a tag still holds may never have been on a branch (a
    # tag cut from a branch deleted since), so with no earlier answer to
    # compare with it is not reported: an origin that comes back unchanged
    # records nothing.
    var recordedCommits = initTable[string, seq[string]]()
    var latest = initTable[string, (uint64, string)]()
    for r in prevRecords:
      if r.version.kind in {rvkTag, rvkLabel} and int(r.origin) == originIndex:
        recordedCommits.mgetOrPut(r.version.tag, @[]).add r.commit
        if r.version.tag notin latest or
            latest[r.version.tag][0] <= r.firstSeen:
          latest[r.version.tag] = (r.firstSeen, r.commit)
    var now2 = initTable[string, string]()
    for t in obs.tags: now2[t.name] = t.commit
    var tags: seq[string]
    for t in recordedCommits.keys: tags.add t
    tags.sort()
    for t in tags:
      let b = latest[t][1]
      let a = now2.getOrDefault(t, "")
      if a in recordedCommits[t]: continue
      if a.len == 0:
        result.events.add OriginEvent(kind: oeTagRemoved, package: input.name,
          version: t, before: b, after: "", observedAt: now)
      else:
        result.events.add OriginEvent(kind: oeTagMoved, package: input.name,
          version: t, before: b, after: a, observedAt: now)
    if input.history.isSome and input.history.get.state == anOk:
      let onBranches = toHashSet(input.history.get.branchCommits)
      let held = toHashSet(input.history.get.allCommits)
      var mine: seq[VersionRecord]
      var anyReached = false
      for r in prevRecords:
        if int(r.origin) == originIndex:
          mine.add r
          if r.commit in onBranches: anyReached = true
      if not anyReached:
        var seen = initHashSet[string]()
        for r in mine:
          if r.commit notin seen and r.commit notin held:
            seen.incl r.commit
            result.events.add OriginEvent(kind: oeHistoryRewritten,
              package: input.name, version: versionLabel(r),
              before: r.commit, after: "", observedAt: now)

  # ---- versions -------------------------------------------------------------
  var records = prevRecords
  var have = initHashSet[string]()
  for r in prevRecords: have.incl sightingKey(r.version, r.commit)
  var heldBefore = initTable[string, uint64]()
  var prevTags = initTable[string, string]()
  if prevObs.isSome:
    for h in prevObs.get.held:
      heldBefore[sightingKey(h.version, h.commit)] = h.firstSeen
    for t in prevObs.get.tags: prevTags[t.name] = t.commit
  if obs.state != osAnswering:
    # Nothing is sighted from an origin that did not answer; what was held
    # stays held, so its first sighting survives an outage.
    if prevObs.isSome: obs.held = prevObs.get.held
  else:
    var seenNow = initHashSet[string]()
    let tagged = hasTagRecord(prevRecords)
    for sighted in input.sightings:
      if sighted.version.kind == rvkSnapshot and tagged:
        # The upstream adopted versioning: its snapshots are retired, and
        # no new one is taken.
        continue
      let key = sightingKey(sighted.version, sighted.commit)
      if key in have or key in seenNow: continue
      seenNow.incl key
      let firstSeen = heldBefore.getOrDefault(key, now)
      let s = Sighting(version: datedAt(sighted.version, firstSeen),
        commit: sighted.commit)
      let admitted = firstSeen + params.cooldownSeconds <= now
      let label = input.name & "@" & (if s.version.tag.len > 0: s.version.tag
                                      else: s.commit)
      if not admitted:
        obs.held.add HeldVersion(version: s.version, commit: s.commit,
          firstSeen: firstSeen)
        continue
      if s.commit notin input.builds:
        result.diagnostics.add label & ": no source was fetched"
        continue
      let b = input.builds[s.commit]
      if b.source.state != anOk:
        # Reported once: at the generation that first admits the version.
        # When the previous observation already offered this tag at this
        # commit and the tag was neither held nor recorded, that generation
        # could not fetch it either and reported it then. (A `HEAD` or
        # commit pseudo-version is reported at each generation that fails
        # to fetch it: whether the previous one tried is not observed.)
        let offeredBefore = comparable and
          prevObs.get.state == osAnswering and key notin heldBefore and
          s.version.kind in {rvkTag, rvkLabel} and
          prevTags.getOrDefault(s.version.tag) == s.commit
        result.diagnostics.add label & ": the source could not be fetched: " &
          b.source.detail
        for sm in b.source.facts.submodules:
          result.diagnostics.add label & ": gitlink " & sm.path.escape() &
            " url " & sm.url.escape() & ": " & sm.verdict
        if offeredBefore:
          continue
        # A submodule that cannot be obtained names itself and the reason
        # (spec § 6.1, "What is not offered").
        let after =
          if b.source.unobtainable.len > 0:
            eventPhrase(b.source.unobtainable[0])
          elif b.source.state == anRefused: "refused by the egress policy"
          else: "the source could not be fetched"
        result.events.add OriginEvent(kind: oeGone, package: input.name,
          version: (if s.version.tag.len > 0: s.version.tag else: s.commit),
          before: s.commit, after: after, observedAt: now)
        continue
      records.add buildRecord(input, params, s, b, uint16(originIndex),
        firstSeen, result.diagnostics)
      have.incl key
  obs.held.sort(proc (a, b: HeldVersion): int =
    cmp(heldSortKey(a), heldSortKey(b)))
  result.observation = obs
  if records.len > 0 or input.previous.isSome:
    result.envelope = some(PackageEnvelope(name: input.name, origins: origins,
      registryOrigin: uint16(originIndex), versions: records))
  # One package must not stop the index: what an origin lists (its tags,
  # its versions, the origins its name was moved to) can pass a bound of
  # the index format, and a shard holding it would be refused, and with it
  # the whole generation. Such a package keeps what the previous generation
  # recorded; nothing new of it is admitted, and its events are still
  # reported. Its observation says `refused`, not the previous answer: a
  # package held at old versions is visible as such, by a `gone` event when
  # it answered before, and the generation after it fits again compares
  # with the records as after any refusal.
  try:
    discard buildShard(0, 0,
      (if result.envelope.isSome: @[result.envelope.get] else: @[]), @[],
      @[result.observation])
  except NimbleIndexError as e:
    result.diagnostics.add input.name & ": " & e.msg & "; the package " &
      "keeps the records of the previous generation, nothing new of it is " &
      "admitted, and its origin is recorded refused"
    result.envelope = input.previous
    result.observation = PackageObservation(name: input.name,
      origin: input.origin, state: osRefused)
    if comparable and prevObs.get.state == osAnswering:
      var already = false
      for ev in result.events:
        if ev.kind == oeGone and ev.version.len == 0: already = true
      if not already:
        result.events.add OriginEvent(kind: oeGone, package: input.name,
          before: "answering", after: "past a bound of the index format",
          observedAt: now)

proc sightingsOf*(name: string; refs: RefsAnswer; trackHead: bool;
                  pinnedCommit: string;
                  requestedCommits: seq[string];
                  hasTagRecord = false): seq[Sighting] =
  ## What a package offers now. A package an override pins to one commit
  ## offers that commit only. A package whose origin lists no tag that
  ## reads as a version, and that has no `tag` record (``hasTagRecord``),
  ## offers a snapshot of the commit its `HEAD` names (NPC-AREQ31 item 5);
  ## its date is set when it is first sighted.
  if pinnedCommit.len > 0:
    return @[Sighting(version: RecordVersion(kind: rvkCommit),
      commit: pinnedCommit)]
  if refs.state != anOk:
    return
  var listed = 0
  for (t, c) in refs.tags:
    if validTagName(t): inc listed
  if listed > MaxObservedTags:
    # More tags than an observation holds: the package cannot be observed
    # (``assemblePackage`` keeps its previous generation), so nothing of it
    # is fetched.
    return
  var commits = initHashSet[string]()
  var versionTag = false
  for (t, c) in refs.tags:
    if validTagName(t):
      let v = versionOfTag(t)
      if v.kind == rvkTag: versionTag = true
      result.add Sighting(version: v, commit: c)
      commits.incl c
  if not versionTag and not hasTagRecord and refs.head.len > 0:
    result.add Sighting(version: RecordVersion(kind: rvkSnapshot),
      commit: refs.head)
  if trackHead and refs.head.len > 0:
    result.add Sighting(version: RecordVersion(kind: rvkHead,
      tag: (if validTagName(refs.headRef): refs.headRef else: "HEAD")),
      commit: refs.head)
    commits.incl refs.head
  for c in requestedCommits:
    if c notin commits:
      result.add Sighting(version: RecordVersion(kind: rvkCommit), commit: c)
      commits.incl c
