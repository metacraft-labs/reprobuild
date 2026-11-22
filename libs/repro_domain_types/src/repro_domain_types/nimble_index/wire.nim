## SSZ wire mirror of the Nimble index domain types (``types.nim``).
##
## Every variable-length field is a bounded SSZ ``List``, so the decoder
## refuses a count beyond the bound before it allocates the list
## (``setLenUninitialized`` checks ``maxLen`` first). Enumerations travel as
## unsigned integers and are checked against their closed vocabularies in
## ``codec.nim``, where an unknown value is a refusal. Each object kind's
## first field is its ``schema``, which the codec reads before decoding the
## rest.
##
## SSZ: https://github.com/ethereum/consensus-specs/blob/dev/ssz/simple-serialize.md

import ssz_serialization

import ./types

export ssz_serialization

type
  WDigest* = array[32, byte]
  WName* = List[byte, MaxNameBytes]
  WText* = List[byte, MaxTextBytes]
  WPath* = List[byte, MaxPathBytes]
  WConstraint* = List[byte, MaxConstraintBytes]
  WCondName* = List[byte, MaxConditionNameBytes]
  WCondition* = List[ConditionNodeW, MaxConditionNodes]

  ConditionNodeW* = object
    kind*: uint8
    name*: WCondName

  RequirementW* = object
    condition*: WCondition
    targetKind*: uint8
    target*: WText
    subdir*: WPath
    versionKind*: uint8
    constraint*: WConstraint
    features*: List[WName, MaxRequirementFeatures]
    source*: WText

  FeatureW* = object
    name*: WName
    rootOnly*: bool
    requires*: List[RequirementW, MaxRequirements]

  NamedBinW* = object
    key*: WPath
    value*: WPath

  ConditionalFieldW* = object
    field*: uint8
    append*: bool
    values*: List[WPath, MaxLayoutEntries]
    pairs*: List[NamedBinW, MaxLayoutEntries]
    condition*: WCondition

  LayoutW* = object
    srcDir*: WPath
    installDirs*: List[WPath, MaxLayoutEntries]
    installFiles*: List[WPath, MaxLayoutEntries]
    installExt*: List[WPath, MaxLayoutEntries]
    skipDirs*: List[WPath, MaxLayoutEntries]
    skipFiles*: List[WPath, MaxLayoutEntries]
    skipExt*: List[WPath, MaxLayoutEntries]
    paths*: List[WPath, MaxLayoutEntries]
    modules*: List[WName, MaxModules]
    conditional*: List[ConditionalFieldW, MaxConditionalFields]

  BinariesW* = object
    bin*: List[WPath, MaxBinaries]
    namedBin*: List[NamedBinW, MaxBinaries]
    binDir*: WPath
    backend*: WName

  ForeignW* = object
    name*: WText
    condition*: WCondition

  VersionW* = object
    kind*: uint8
    components*: List[uint64, MaxVersionComponents]
    tag*: WName

  VersionRecordW* = object
    version*: VersionW
    commit*: List[byte, MaxCommitBytes]
    tree*: WDigest
    archiveSha256*: WDigest
    size*: uint64
    firstSeen*: uint64
    origin*: uint16
    nim*: List[RequirementW, MaxNimEntries]
    requires*: List[RequirementW, MaxRequirements]
    features*: List[FeatureW, MaxFeatures]
    layout*: LayoutW
    binaries*: BinariesW
    foreign*: List[ForeignW, MaxForeign]
    flags*: uint32
    readerClass*: uint8
    resolutionClass*: uint8
    probePlatform*: WName
    nimbleFile*: List[WDigest, 1]

  SubmoduleW* = object
    path*: WPath
    url*: WText
    commit*: List[byte, MaxCommitBytes]

  VersionRecordW2* = object
    ## ``VersionRecordW`` with the ``submodules`` list: the record of a
    ## shard of schema ``NimbleShardSubmodulesSchema``. The fields before
    ## it are ``VersionRecordW``'s, in the same order.
    version*: VersionW
    commit*: List[byte, MaxCommitBytes]
    tree*: WDigest
    archiveSha256*: WDigest
    size*: uint64
    firstSeen*: uint64
    origin*: uint16
    nim*: List[RequirementW, MaxNimEntries]
    requires*: List[RequirementW, MaxRequirements]
    features*: List[FeatureW, MaxFeatures]
    layout*: LayoutW
    binaries*: BinariesW
    foreign*: List[ForeignW, MaxForeign]
    flags*: uint32
    readerClass*: uint8
    resolutionClass*: uint8
    probePlatform*: WName
    nimbleFile*: List[WDigest, 1]
    submodules*: List[SubmoduleW, MaxSubmodules]

  OriginW* = object
    url*: WText
    subdir*: WPath
    vcs*: uint8

  PackageW* = object
    name*: WName
    origins*: List[OriginW, MaxOrigins]
    registryOrigin*: uint16
    versions*: List[VersionRecordW, MaxVersionsPerPackage]

  PackageW2* = object
    name*: WName
    origins*: List[OriginW, MaxOrigins]
    registryOrigin*: uint16
    versions*: List[VersionRecordW2, MaxVersionsPerPackage]

  AliasW* = object
    alias*: WName
    target*: WName

  ObservedTagW* = object
    name*: WName
    commit*: List[byte, MaxCommitBytes]

  HeldW* = object
    version*: VersionW
    commit*: List[byte, MaxCommitBytes]
    firstSeen*: uint64

  ObservationW* = object
    name*: WName
    origin*: OriginW
    state*: uint8
    headRef*: WName
    head*: List[byte, MaxCommitBytes]
    tags*: List[ObservedTagW, MaxObservedTags]
    held*: List[HeldW, MaxHeldVersions]

  ShardW* = object
    schema*: uint16
    shardBits*: uint8
    bucket*: uint32
    packages*: List[PackageW, MaxPackagesPerShard]
    aliases*: List[AliasW, MaxAliasesPerShard]
    observations*: List[ObservationW, MaxPackagesPerShard]

  ShardW2* = object
    ## A shard of schema ``NimbleShardSubmodulesSchema``: ``ShardW`` whose
    ## records carry their ``submodules`` list.
    schema*: uint16
    shardBits*: uint8
    bucket*: uint32
    packages*: List[PackageW2, MaxPackagesPerShard]
    aliases*: List[AliasW, MaxAliasesPerShard]
    observations*: List[ObservationW, MaxPackagesPerShard]

  ShardRefW* = object
    bucket*: uint32
    id*: WDigest
    size*: uint64
    packages*: uint32

  ObjectRefW* = object
    id*: WDigest
    size*: uint64

  RootW* = object
    schema*: uint16
    generator*: WName
    sourceSet*: WDigest
    generatedAt*: uint64
    previousRoot*: List[WDigest, 1]
    packageCount*: uint32
    versionCount*: uint32
    eventCount*: uint32
    shardBits*: uint8
    shards*: List[ShardRefW, MaxShards]
    nameMap*: ObjectRefW
    events*: ObjectRefW

  NameEntryW* = object
    name*: WName
    target*: WName

  NameMapW* = object
    schema*: uint16
    entries*: List[NameEntryW, MaxNames]

  EventW* = object
    kind*: uint8
    package*: WName
    version*: WName
    before*: WText
    after*: WText
    observedAt*: uint64

  EventsW* = object
    schema*: uint16
    events*: List[EventW, MaxEvents]
