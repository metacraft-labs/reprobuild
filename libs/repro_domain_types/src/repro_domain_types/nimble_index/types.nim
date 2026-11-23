## Domain types of the Nimble package index: the root, the shards (package
## envelopes holding version records), the name map and the origin events.
##
## These are the values a reader works with. Their binary form is defined in
## ``wire.nim`` (an SSZ mirror whose every list and text is bounded) and
## ``codec.nim`` (the RBSZ frame, validation and the canonical-form check).
## Nothing here touches a file, a process or the network.

import std/[options, strutils]

const
  # -------------------------------------------------------------------------
  # Object kinds, versions and sizes
  # -------------------------------------------------------------------------
  NimbleIndexSchemaVersion* = 1'u16
    ## The payload schema every object kind carries as its first field. A
    ## reader refuses any other value before decoding the rest.
  NimbleShardSubmodulesSchema* = 2'u16
    ## The shard schema whose version records carry a ``submodules`` list
    ## (spec § 4.4, the NPC-M13 amendment). A shard is written in this
    ## schema exactly when one of its records has a non-empty list, and in
    ## ``NimbleIndexSchemaVersion`` otherwise, so a reader from before
    ## submodule sources refuses such a shard as an unknown schema instead
    ## of reading its records without their submodules.
  NimbleShardConditionsSchema* = 3'u16
    ## The shard schema whose condition nodes may be the NPC-AREQ7 terms the
    ## operator's A3 ruling added -- a Nim-version comparison and an
    ## OS-family symbol (spec § 4.4, the NPC-M14 amendment). Its records
    ## carry the ``submodules`` list as schema 2's do, and its condition
    ## nodes carry the comparison's field, operator and literal. A shard is
    ## written in this schema exactly when one of its condition nodes is of
    ## such a kind, so a reader from before NPC-M14 refuses it as an unknown
    ## schema instead of misreading the condition.
  NimbleShardSnapshotsSchema* = 4'u16
    ## The shard schema whose version records and held versions may be of
    ## kind ``rvkSnapshot`` (NPC-AREQ31 item 5, the operator's A5 ruling;
    ## spec § 4.4, the NPC-M10 amendment). Its layout is schema 3's: the
    ## kind is a value of the version's existing kind byte, and the
    ## snapshot's date is its one component. A shard is written in this
    ## schema exactly when it holds a snapshot, so a reader from before
    ## snapshots refuses it as an unknown schema instead of reading a kind
    ## it does not know.

  RootTypeId* = 0x1201'u16      ## RBSZ type id of a root object.
  ShardTypeId* = 0x1202'u16     ## RBSZ type id of a shard.
  NameMapTypeId* = 0x1203'u16   ## RBSZ type id of the name map.
  EventsTypeId* = 0x1204'u16    ## RBSZ type id of an origin-event list.

  MaxRootBytes* = 8 * 1024 * 1024
  MaxShardBytes* = 16 * 1024 * 1024
  MaxNameMapBytes* = 16 * 1024 * 1024
  MaxEventsBytes* = 16 * 1024 * 1024

  # -------------------------------------------------------------------------
  # Count bounds. Each is enforced by the decoder BEFORE the list is
  # allocated (the SSZ list limit), so a hash-valid hostile object cannot
  # make a reader allocate more than a constant multiple of its byte size.
  # -------------------------------------------------------------------------
  MaxShardBits* = 16
  MaxShards* = 1 shl MaxShardBits
  MaxPackagesPerShard* = 4096
  MaxAliasesPerShard* = 4096
  MaxOrigins* = 16
  MaxVersionsPerPackage* = 4096
  MaxRequirements* = 512
  MaxNimEntries* = 32
  MaxFeatures* = 64
  MaxRequirementFeatures* = 32
  MaxConditionNodes* = 64
  MaxLayoutEntries* = 512
  MaxModules* = 1024
  MaxConditionalFields* = 128
  MaxBinaries* = 256
  MaxForeign* = 64
  MaxVersionComponents* = 8
  MaxNames* = 1 shl 17
  MaxEvents* = 1 shl 17
  MaxObservedTags* = 4096
    ## tags one observation records (the bound of a package's versions)
  MaxHeldVersions* = 4096
  MaxSubmodules* = 256
    ## submodules one version record lists, at any depth (spec § 6.1,
    ## "Submodule sources"; threat model G38)
  MaxSubmoduleDepth* = 8
    ## nesting levels of submodules a source object may have (G38)

  # Text bounds, in bytes.
  MaxNameBytes* = 256
  MaxTextBytes* = 2048
  MaxPathBytes* = 1024
  MaxConstraintBytes* = 256
  MaxConditionNameBytes* = 32
  MaxNimVersionTextBytes* = 64
    ## the string literal a `NimVersion` comparison holds
  MaxNimVersionInts* = 3
    ## the integer literals of a Nim-version comparison (a tuple of three)
  MaxCommitBytes* = 32

  ShardKeyDomain* = "reprobuild.nimble-index.shard-key.v1"
    ## Domain separation of the shard keying hash (``shardBucket``).

type
  IndexObjectId* = array[32, byte]
    ## The identity of an index object: BLAKE3-256 of its bytes, the key the
    ## content-addressed store files it under.

  Sha256Digest* = array[32, byte]

  NimbleIndexRefusal* = enum
    ## Stable reason codes of a refused index object.
    nrTruncated = "truncated"
    nrBadMagic = "bad-magic"
    nrUnknownFrameVersion = "unknown-frame-version"
    nrUnknownKind = "unknown-record-kind"
    nrLengthMismatch = "length-mismatch"
    nrOversize = "oversize"
    nrUnknownSchema = "unknown-schema"
    nrMalformed = "malformed"
    nrBound = "bound-exceeded"
    nrNonCanonical = "non-canonical"
    nrUnsorted = "unsorted"
    nrDuplicate = "duplicate"
    nrInvalidText = "invalid-text"
    nrUnknownVocabulary = "unknown-vocabulary"
    nrInconsistent = "inconsistent"
    nrHashMismatch = "hash-mismatch"
    nrSizeMismatch = "size-mismatch"
    nrMissingObject = "missing-object"
    nrWrongShard = "wrong-shard"

  NimbleIndexError* = object of CatchableError
    ## An index object refused. ``reason`` is stable; the message names the
    ## object and the field.
    reason*: NimbleIndexRefusal

  NimbleObjectKind* = enum
    nokRoot = "root"
    nokShard = "shard"
    nokNameMap = "name-map"
    nokEvents = "events"

  # -------------------------------------------------------------------------
  # Conditions (NPC-AREQ7), flattened in prefix order
  # -------------------------------------------------------------------------
  ConditionNodeKind* = enum
    cnDefinedOs = "defined-os"    ## `defined(<os>)`
    cnDefinedCpu = "defined-cpu"  ## `defined(<cpu>)`
    cnHostOs = "host-os"          ## `hostOS == "<os>"`
    cnHostCpu = "host-cpu"        ## `hostCPU == "<cpu>"`
    cnAnd = "and"
    cnOr = "or"
    cnNot = "not"
    cnOsFamily = "os-family"
      ## `defined(posix)`, `defined(unix)`, `defined(bsd)`: shard schema 3
    cnNimVersion = "nim-version"
      ## a comparison of the Nim version with a literal: shard schema 3

  NimVersionTerm* = enum
    ## The left-hand side of a Nim-version comparison (field on the left).
    ## ``nvNone`` on every node that is not a ``cnNimVersion``.
    nvNone = "none"
    nvMajor = "NimMajor"
    nvMinor = "NimMinor"
    nvPatch = "NimPatch"
    nvVersion = "NimVersion"
    nvMajorMinor = "(NimMajor, NimMinor)"
    nvMajorMinorPatch = "(NimMajor, NimMinor, NimPatch)"

  ConditionOp* = enum
    ## The comparison of a ``cnNimVersion`` node; ``opNone`` on every other.
    opNone = "none"
    opEq = "=="
    opNe = "!="
    opLt = "<"
    opLe = "<="
    opGt = ">"
    opGe = ">="

  ConditionNode* = object
    ## One node of a condition in prefix (Polish) order: `and a b` is
    ## `[and, a, b]`. A target term carries the lower-case Nim target name,
    ## an OS-family term its symbol; an operator carries none. A
    ## ``cnNimVersion`` node carries ``term``, ``op`` and the literal
    ## (``ints``, or ``text`` for `NimVersion`) and no name. An empty node
    ## list is "unconditional".
    kind*: ConditionNodeKind
    name*: string
    term*: NimVersionTerm
    op*: ConditionOp
    ints*: seq[uint64]
    text*: string

  # -------------------------------------------------------------------------
  # Requirement entries (NPC-AREQ5 / NPC-AREQ6)
  # -------------------------------------------------------------------------
  RequirementTargetKind* = enum
    rtPackage = "package" ## a package name, resolved through the catalog
    rtUrl = "url"         ## an origin given directly

  RequirementVersionKind* = enum
    rvAny = "any"       ## a bare name: any version
    rvRange = "range"   ## `constraint` is a range in the solver's grammar
    rvHead = "head"     ## `#head`
    rvCommit = "commit" ## `constraint` is lower-case hex, 4 to 64 digits
    rvRef = "ref"       ## `constraint` is a branch or tag name

  RequirementEntry* = object
    ## `(condition, target, range, features)` of spec § 4.2, plus the
    ## requirement as written (diagnostics; it is part of the record).
    condition*: seq[ConditionNode]
    targetKind*: RequirementTargetKind
    target*: string
    subdir*: string
    versionKind*: RequirementVersionKind
    constraint*: string
    features*: seq[string]
    source*: string

  RecordFeature* = object
    name*: string
    rootOnly*: bool ## the `dev` feature
    requires*: seq[RequirementEntry]

  # -------------------------------------------------------------------------
  # Layout and binaries
  # -------------------------------------------------------------------------
  RecordField* = enum
    ## The `.nimble` fields a conditional assignment may set.
    rfVersion = "version"
    rfSrcDir = "srcDir"
    rfBinDir = "binDir"
    rfBin = "bin"
    rfNamedBin = "namedBin"
    rfBackend = "backend"
    rfInstallDirs = "installDirs"
    rfInstallFiles = "installFiles"
    rfInstallExt = "installExt"
    rfSkipDirs = "skipDirs"
    rfSkipFiles = "skipFiles"
    rfSkipExt = "skipExt"
    rfPaths = "paths"

  NamedBin* = object
    key*: string
    value*: string

  RecordConditionalField* = object
    ## A layout or binary field assigned under a closed condition.
    field*: RecordField
    append*: bool
    values*: seq[string]
    pairs*: seq[NamedBin]
    condition*: seq[ConditionNode]

  RecordLayout* = object
    srcDir*: string
    installDirs*, installFiles*, installExt*: seq[string]
    skipDirs*, skipFiles*, skipExt*, paths*: seq[string]
    modules*: seq[string]
      ## the top-level module names under `srcDir`, sorted
    conditional*: seq[RecordConditionalField]

  RecordBinaries* = object
    bin*: seq[string]
    namedBin*: seq[NamedBin]
    binDir*: string
    backend*: string

  ForeignDependency* = object
    name*: string
    condition*: seq[ConditionNode]

  RecordFlag* = enum
    flHasTasks = "has_tasks"
    flHasHooks = "has_hooks"
    flUsesProbe = "uses_probe"
    flPlatformLimited = "platform_limited"
    flUnreadable = "unreadable"
    flGitlinks = "gitlinks"
      ## the source object includes submodule trees (its ``submodules``
      ## list names them); with an empty list, a record from before
      ## submodule sources
    flOverrideApplied = "override_applied"
    flUnlisted = "unlisted"
      ## the source is outside the registry and the source set's own
      ## declarations (a URL requirement), indexed under `unlisted = "allow"`

  RecordReaderClass* = enum
    ## The static reader's class of the `.nimble` the record was read from.
    rrcPlain = "plain"
    rrcClosedWhen = "closed-when"
    rrcFeature = "feature"
    rrcNeedsOverride = "needs-override"
    rrcNeedsProbe = "needs-probe"
    rrcUnreadable = "unreadable"

  # -------------------------------------------------------------------------
  # Versions and records
  # -------------------------------------------------------------------------
  RecordVersionKind* = enum
    rvkTag = "tag"       ## a tag that parses as a version
    rvkLabel = "label"   ## a tag that does not; reachable by commit only
    rvkHead = "head"     ## the origin's default branch (`#head`)
    rvkRef = "ref"       ## a named branch (`#<branch>`)
    rvkCommit = "commit" ## a commit a requirement names (`#<commit>`)
    rvkSnapshot = "snapshot"
      ## the commit `HEAD` named when the package had no tag that reads as
      ## a version (NPC-AREQ31 item 5): shard schema 4 only

  RecordVersion* = object
    kind*: RecordVersionKind
    components*: seq[uint64]
      ## the numeric components of a `rvkTag`, as many as the tag has (up
      ## to ``MaxVersionComponents``); for a `rvkSnapshot` exactly one, its
      ## date as the decimal number `YYYYMMDD` (the UTC date of the
      ## record's `first_seen`); empty for every other kind
    tag*: string
      ## the source tag (`rvkTag`, `rvkLabel`), the branch (`rvkHead`,
      ## `rvkRef`), or empty (`rvkCommit`)

  RecordSubmodule* = object
    ## One submodule whose tree is part of a version's source object
    ## (NPC-AREQ12, "Submodule sources"): where its tree is placed, the URL
    ## it was fetched from (after relative resolution) and the commit its
    ## gitlink pins. Provenance: the record's ``tree`` covers the content.
    path*: string   ## relative to the package directory, `/`-separated
    url*: string    ## an `https://` URL
    commit*: string ## lower-case hex, full width

  VersionRecord* = object
    ## NPC-AREQ5: one immutable record per version.
    version*: RecordVersion
    commit*: string            ## peeled commit id, lower-case hex (40 or 64)
    tree*: IndexObjectId       ## the canonical tree digest (BLAKE3)
    archiveSha256*: Sha256Digest
    size*: uint64              ## bytes of the canonical archive
    firstSeen*: uint64         ## generator observation time, Unix seconds
    origin*: uint16            ## index into the package's ``origins``
    nim*: seq[RequirementEntry]
    requires*: seq[RequirementEntry]
    features*: seq[RecordFeature]
    layout*: RecordLayout
    binaries*: RecordBinaries
    foreign*: seq[ForeignDependency]
    flags*: set[RecordFlag]
    readerClass*: RecordReaderClass
    resolutionClass*: RecordReaderClass
    probePlatform*: string
      ## the platform pair a probe read the record on; set exactly when
      ## ``flPlatformLimited`` is
    nimbleFile*: Option[IndexObjectId]
      ## BLAKE3 of the `.nimble` read; none when the version has no
      ## `.nimble` (then the record is unreadable)
    submodules*: seq[RecordSubmodule]
      ## every submodule of the source object at any depth, strictly
      ## ascending by path; empty for a version without gitlinks. A record
      ## flagged `gitlinks` with an empty list is from a generator before
      ## submodule sources: its tree lacks the submodules, and it is never
      ## offered.

  OriginVcs* = enum
    ovGit = "git"
    ovHg = "hg"

  PackageOrigin* = object
    url*: string
    subdir*: string
    vcs*: OriginVcs

  PackageEnvelope* = object
    ## One package: its canonical name, every origin it has had (in the
    ## order first observed; a repointed name keeps the old one), the origin
    ## the registry names now, and its version records sorted by
    ## ``versionSortKey``.
    name*: string
    origins*: seq[PackageOrigin]
    registryOrigin*: uint16
    versions*: seq[VersionRecord]

  PackageAlias* = object
    alias*: string
    target*: string ## the canonical name

  ObservationState* = enum
    ## What the origin of a package answered the generator's `refs` edge.
    osAnswering = "answering" ## it listed its refs
    osGone = "gone"
      ## it did not answer, or the registry no longer lists the package
    osRefused = "refused"
      ## the origin egress policy refused the origin; it was never contacted

  ObservedTag* = object
    name*: string   ## the tag's name, without `refs/tags/`
    commit*: string ## the object it peels to, lower-case hex

  HeldVersion* = object
    ## A version the generator has seen and withholds from the index until
    ## it has been observable for the source set's `cooldown_days`
    ## (NPC-AREQ11). Only its first sighting is kept: the record is built
    ## when it is admitted, with this `firstSeen`.
    version*: RecordVersion
    commit*: string
    firstSeen*: uint64

  PackageObservation* = object
    ## The origin answers the generator recorded for one package at this
    ## generation: what the next generation compares against to compute the
    ## origin events (NPC-AREQ4), and what a second operator's run is
    ## compared with field by field (NPC-AREQ9). A package that has an
    ## observation need not have an envelope (every version may be held).
    name*: string
    origin*: PackageOrigin   ## the origin the `refs` edge read
    state*: ObservationState
    headRef*: string         ## the branch `HEAD` names; may be empty
    head*: string            ## the commit `HEAD` names; may be empty
    tags*: seq[ObservedTag]  ## strictly ascending by name
    held*: seq[HeldVersion]  ## strictly ascending by ``heldSortKey``

  NimbleShard* = object
    shardBits*: uint8
    bucket*: uint32
    packages*: seq[PackageEnvelope] ## sorted by ``nameKey`` of the name
    aliases*: seq[PackageAlias]     ## sorted by ``nameKey`` of the alias
    observations*: seq[PackageObservation]
      ## sorted by ``nameKey`` of the name; each in its own key's bucket

  ShardRef* = object
    bucket*: uint32
    id*: IndexObjectId
    size*: uint64
    packages*: uint32

  ObjectRef* = object
    id*: IndexObjectId
    size*: uint64

  NimbleIndexRoot* = object
    generator*: string
    sourceSet*: IndexObjectId
    generatedAt*: uint64
    previousRoot*: Option[IndexObjectId]
    packageCount*: uint32
    versionCount*: uint32
    eventCount*: uint32
    shardBits*: uint8
    shards*: seq[ShardRef] ## strictly ascending by bucket; empty buckets absent
    nameMap*: ObjectRef
    events*: ObjectRef

  NameEntry* = object
    name*: string
    target*: string ## empty for a canonical name; the canonical name for an alias

  NimbleNameMap* = object
    entries*: seq[NameEntry] ## sorted by ``nameKey`` of the name

  OriginEventKind* = enum
    oeRepointed = "repointed"
    oeTagMoved = "tag-moved"
    oeHistoryRewritten = "history-rewritten"
    oeGone = "gone"
    oeTagRemoved = "tag-removed"

  OriginEvent* = object
    kind*: OriginEventKind
    package*: string
    version*: string  ## the version's tag or label; empty for a package event
    before*: string
    after*: string
    observedAt*: uint64

  NimbleEvents* = object
    events*: seq[OriginEvent]

proc refuse*(reason: NimbleIndexRefusal; detail: string) {.noreturn.} =
  var e = newException(NimbleIndexError, $reason & ": " & detail)
  e.reason = reason
  raise e

proc nameKey*(name: string): string =
  ## The registry's uniqueness key (NPC-AREQ3): ASCII case folded,
  ## underscores removed -- the comparison Nimble's `normalize` uses.
  for c in name:
    if c != '_':
      result.add toLowerAscii(c)

proc parseTagVersion*(tag: string; components: var seq[uint64]): bool =
  ## Read a tag as a version the way Nimble's `getVersionList` does: skip
  ## everything before the first digit, then the rest must be one or more
  ## dot-separated decimal components (at most ``MaxVersionComponents``,
  ## each fitting in 64 bits). `v1.2.3`, `1.2` and `release-0.7.0.8.0` are
  ## versions; `1.2.3-rc1` and `latest` are labels.
  components = @[]
  var i = 0
  while i < tag.len and tag[i] notin {'0'..'9'}:
    inc i
  if i >= tag.len:
    return false
  var current = 0'u64
  var digits = 0
  while i <= tag.len:
    if i == tag.len or tag[i] == '.':
      if digits == 0 or components.len >= MaxVersionComponents:
        components = @[]
        return false
      components.add current
      current = 0
      digits = 0
      if i == tag.len:
        break
    elif tag[i] in {'0'..'9'}:
      let d = uint64(ord(tag[i]) - ord('0'))
      if current > (high(uint64) - d) div 10:
        components = @[]
        return false
      current = current * 10 + d
      inc digits
    else:
      components = @[]
      return false
    inc i
  true

proc toHexLower*(bytes: openArray[byte]): string =
  const digits = "0123456789abcdef"
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add digits[int(b shr 4)]
    result.add digits[int(b and 0x0f)]

proc parseObjectId*(hex: string; id: var IndexObjectId): bool =
  ## A 64-digit lower-case hex string as an object id.
  if hex.len != 64:
    return false
  for i in 0 ..< 32:
    var v = 0
    for j in 0 .. 1:
      let c = hex[2 * i + j]
      v = v * 16 + (case c
        of '0'..'9': ord(c) - ord('0')
        of 'a'..'f': ord(c) - ord('a') + 10
        else: return false)
    id[i] = byte(v)
  true

proc `$`*(id: IndexObjectId): string = toHexLower(id)

proc utcDateOf*(unixSeconds: uint64): uint64 =
  ## The UTC calendar date of a Unix time as the number `YYYYMMDD` (the
  ## proleptic Gregorian calendar; `civil_from_days`).
  let z = int64(unixSeconds div 86400) + 719468
  let era = z div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  var y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  if m <= 2: inc y
  uint64(y * 10000 + m * 100 + d)

proc isCalendarDate*(date: uint64): bool =
  ## Whether `YYYYMMDD` names a day of the proleptic Gregorian calendar
  ## between the years 1970 and 9999.
  let y = date div 10000
  let m = (date div 100) mod 100
  let d = date mod 100
  if y < 1970 or y > 9999 or m < 1 or m > 12 or d < 1:
    return false
  let leap = (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0
  let days = case m
    of 2: (if leap: 29'u64 else: 28'u64)
    of 4, 6, 9, 11: 30'u64
    else: 31'u64
  d <= days

proc snapshotVersion*(firstSeen: uint64): RecordVersion =
  ## The version of a snapshot first seen at ``firstSeen``: dated by the
  ## generator's own observation, never by the commit.
  RecordVersion(kind: rvkSnapshot, components: @[utcDateOf(firstSeen)])

proc snapshotDateText*(v: RecordVersion): string =
  ## A snapshot's date as eight digits; "" for any other kind.
  if v.kind == rvkSnapshot and v.components.len == 1:
    align($v.components[0], 8, '0')
  else: ""

const SnapshotVersionPrefix* = "#snapshot/"
  ## How a snapshot is spelled as a solver version and in a lock row:
  ## `#snapshot/<YYYYMMDD>/<commit>` (spec NPC-AREQ31, "The snapshot's
  ## spelling").

proc snapshotVersionText*(v: RecordVersion; commit: string): string =
  ## `#snapshot/<YYYYMMDD>/<commit>`; "" for any other kind.
  if v.kind != rvkSnapshot: return ""
  SnapshotVersionPrefix & snapshotDateText(v) & "/" & commit

proc parseSnapshotVersionText*(text: string; date: var uint64;
                               commit: var string): bool =
  ## Read `#snapshot/<YYYYMMDD>/<commit>` back: eight digits naming a
  ## calendar date, and a full-width lower-case object id.
  if not text.startsWith(SnapshotVersionPrefix): return false
  let rest = text[SnapshotVersionPrefix.len .. ^1]
  let slash = rest.find('/')
  if slash != 8: return false
  var d = 0'u64
  for c in rest[0 ..< 8]:
    if c notin {'0'..'9'}: return false
    d = d * 10 + uint64(ord(c) - ord('0'))
  let c = rest[9 .. ^1]
  if c.len notin [40, 64]: return false
  for ch in c:
    if ch notin {'0'..'9', 'a'..'f'}: return false
  if not isCalendarDate(d): return false
  date = d
  commit = c
  true

proc versionText*(v: RecordVersion): string =
  ## The version as the inspection view and diagnostics print it.
  case v.kind
  of rvkTag:
    var parts: seq[string]
    for c in v.components: parts.add $c
    parts.join(".")
  of rvkLabel: "label:" & v.tag
  of rvkHead: "#head"
  of rvkRef: "#" & v.tag
  of rvkCommit: "#commit"
  of rvkSnapshot: "#snapshot/" & snapshotDateText(v)
