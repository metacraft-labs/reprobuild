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

  # Text bounds, in bytes.
  MaxNameBytes* = 256
  MaxTextBytes* = 2048
  MaxPathBytes* = 1024
  MaxConstraintBytes* = 256
  MaxConditionNameBytes* = 32
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

  ConditionNode* = object
    ## One node of a condition in prefix (Polish) order: `and a b` is
    ## `[and, a, b]`. A term carries the lower-case Nim target name; an
    ## operator carries none. An empty node list is "unconditional".
    kind*: ConditionNodeKind
    name*: string

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
    flOverrideApplied = "override_applied"

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

  RecordVersion* = object
    kind*: RecordVersionKind
    components*: seq[uint64]
      ## the numeric components of a `rvkTag`, as many as the tag has (up
      ## to ``MaxVersionComponents``); empty for every other kind
    tag*: string
      ## the source tag (`rvkTag`, `rvkLabel`), the branch (`rvkHead`,
      ## `rvkRef`), or empty (`rvkCommit`)

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

  NimbleShard* = object
    shardBits*: uint8
    bucket*: uint32
    packages*: seq[PackageEnvelope] ## sorted by ``nameKey`` of the name
    aliases*: seq[PackageAlias]     ## sorted by ``nameKey`` of the alias

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
