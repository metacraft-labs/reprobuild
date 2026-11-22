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

  ConditionNodeW3* = object
    ## A condition node of shard schema ``NimbleShardConditionsSchema``:
    ## ``ConditionNodeW`` followed by a Nim-version comparison's term,
    ## operator and literal (zero and empty on every other node).
    kind*: uint8
    name*: WCondName
    term*: uint8
    op*: uint8
    ints*: List[uint64, MaxNimVersionInts]
    text*: List[byte, MaxNimVersionTextBytes]

  WCondition3* = List[ConditionNodeW3, MaxConditionNodes]

  RequirementWT*[C] = object
    ## A requirement entry whose condition nodes are ``C``.
    condition*: List[C, MaxConditionNodes]
    targetKind*: uint8
    target*: WText
    subdir*: WPath
    versionKind*: uint8
    constraint*: WConstraint
    features*: List[WName, MaxRequirementFeatures]
    source*: WText

  RequirementW* = RequirementWT[ConditionNodeW]
  RequirementW3* = RequirementWT[ConditionNodeW3]

  FeatureWT*[C] = object
    name*: WName
    rootOnly*: bool
    requires*: List[RequirementWT[C], MaxRequirements]

  FeatureW* = FeatureWT[ConditionNodeW]

  NamedBinW* = object
    key*: WPath
    value*: WPath

  ConditionalFieldWT*[C] = object
    field*: uint8
    append*: bool
    values*: List[WPath, MaxLayoutEntries]
    pairs*: List[NamedBinW, MaxLayoutEntries]
    condition*: List[C, MaxConditionNodes]

  ConditionalFieldW* = ConditionalFieldWT[ConditionNodeW]

  LayoutWT*[C] = object
    srcDir*: WPath
    installDirs*: List[WPath, MaxLayoutEntries]
    installFiles*: List[WPath, MaxLayoutEntries]
    installExt*: List[WPath, MaxLayoutEntries]
    skipDirs*: List[WPath, MaxLayoutEntries]
    skipFiles*: List[WPath, MaxLayoutEntries]
    skipExt*: List[WPath, MaxLayoutEntries]
    paths*: List[WPath, MaxLayoutEntries]
    modules*: List[WName, MaxModules]
    conditional*: List[ConditionalFieldWT[C], MaxConditionalFields]

  LayoutW* = LayoutWT[ConditionNodeW]

  BinariesW* = object
    bin*: List[WPath, MaxBinaries]
    namedBin*: List[NamedBinW, MaxBinaries]
    binDir*: WPath
    backend*: WName

  ForeignWT*[C] = object
    name*: WText
    condition*: List[C, MaxConditionNodes]

  ForeignW* = ForeignWT[ConditionNodeW]

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

  VersionRecordW2T*[C] = object
    ## ``VersionRecordW`` with the ``submodules`` list: the record of a
    ## shard of schema ``NimbleShardSubmodulesSchema`` (``C`` is
    ## ``ConditionNodeW``) or ``NimbleShardConditionsSchema`` (``C`` is
    ## ``ConditionNodeW3``). The fields before it are ``VersionRecordW``'s,
    ## in the same order.
    version*: VersionW
    commit*: List[byte, MaxCommitBytes]
    tree*: WDigest
    archiveSha256*: WDigest
    size*: uint64
    firstSeen*: uint64
    origin*: uint16
    nim*: List[RequirementWT[C], MaxNimEntries]
    requires*: List[RequirementWT[C], MaxRequirements]
    features*: List[FeatureWT[C], MaxFeatures]
    layout*: LayoutWT[C]
    binaries*: BinariesW
    foreign*: List[ForeignWT[C], MaxForeign]
    flags*: uint32
    readerClass*: uint8
    resolutionClass*: uint8
    probePlatform*: WName
    nimbleFile*: List[WDigest, 1]
    submodules*: List[SubmoduleW, MaxSubmodules]

  VersionRecordW2* = VersionRecordW2T[ConditionNodeW]
  VersionRecordW3* = VersionRecordW2T[ConditionNodeW3]

  OriginW* = object
    url*: WText
    subdir*: WPath
    vcs*: uint8

  PackageW* = object
    name*: WName
    origins*: List[OriginW, MaxOrigins]
    registryOrigin*: uint16
    versions*: List[VersionRecordW, MaxVersionsPerPackage]

  PackageW2T*[C] = object
    name*: WName
    origins*: List[OriginW, MaxOrigins]
    registryOrigin*: uint16
    versions*: List[VersionRecordW2T[C], MaxVersionsPerPackage]

  PackageW2* = PackageW2T[ConditionNodeW]
  PackageW3* = PackageW2T[ConditionNodeW3]

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

  ShardW2T*[C] = object
    ## A shard of schema ``NimbleShardSubmodulesSchema`` (``ShardW2``) or
    ## ``NimbleShardConditionsSchema`` (``ShardW3``): ``ShardW`` whose
    ## records carry their ``submodules`` list, and for schema 3 whose
    ## condition nodes carry a Nim-version comparison.
    schema*: uint16
    shardBits*: uint8
    bucket*: uint32
    packages*: List[PackageW2T[C], MaxPackagesPerShard]
    aliases*: List[AliasW, MaxAliasesPerShard]
    observations*: List[ObservationW, MaxPackagesPerShard]

  ShardW2* = ShardW2T[ConditionNodeW]
  ShardW3* = ShardW2T[ConditionNodeW3]

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
