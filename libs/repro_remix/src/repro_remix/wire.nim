## SSZ wire mirror of the Remix domain types.
##
## Every variable-length field is a bounded SSZ `List`, so the bounds in
## `types.nim` are enforced by the decoder before anything is allocated
## past them (spec §"Parser bounds"). Enumerations travel as `uint8` and
## are checked against their closed vocabularies in `codec.nim`, where an
## unknown value is a refusal rather than a decoder crash.
##
## SSZ: https://github.com/ethereum/consensus-specs/blob/dev/ssz/simple-serialize.md
## Library: status-im/nim-ssz-serialization (pinned in this repository).

import ssz_serialization

import ./types

type
  SszName* = List[byte, MaxNameBytes]
  SszText* = List[byte, MaxTextBytes]
  SszIntent* = List[byte, MaxIntentBytes]
  SszRevision* = List[byte, MaxRevisionBytes]
  SszDigestText* = List[byte, MaxDigestTextBytes]

  OriginalRefW* = object
    package*: SszName
    interfaceFingerprint*: Digest32
    catalogWorkspace*: SszName
    catalogRemote*: SszText
    catalogRevision*: SszRevision
    catalogInterfaceArtifact*: Digest32

  TargetW* = object
    original*: OriginalRefW
    constraintKind*: uint8
    constraint*: SszName

  SourceTreeW* = object
    repo*: SszName
    remote*: SszText
    revision*: SszRevision
    digest*: SszDigestText

  BlobRefW* = object
    id*: Digest32
    mediaType*: SszName
    size*: uint64

  PatchW* = object
    appliesToKind*: uint8
    appliesToIndex*: uint16
    blob*: BlobRefW
    strip*: uint8
    order*: uint16

  ConfigContributionW* = object
    configurable*: SszName
    schemaFingerprint*: Digest32
    priority*: uint8
    operation*: uint8
    value*: BlobRefW

  ExposedConfigurableW* = object
    name*: SszName
    schemaFingerprint*: Digest32

  TestRefW* = object
    name*: SszName
    fragment*: uint16

  HealthCheckW* = object
    kind*: uint8
    target*: SszText
    timeoutSeconds*: uint32

  PermissionW* = object
    kind*: uint8
    scope*: SszName

  DataMigrationW* = object
    store*: SszName
    kind*: uint8
    edge*: SszName

  ExtensionW* = object
    id*: SszName
    critical*: bool
    payload*: List[byte, MaxExtensionBytes]

  ManifestW* = object
    remixName*: SszName
    version*: SszName
    intent*: SszIntent
    license*: SszName
    targets*: List[TargetW, MaxEntries]
    platforms*: List[SszName, MaxPlatforms]
    parents*: List[Digest32, MaxParents]
    sources*: List[SourceTreeW, MaxEntries]
    patches*: List[PatchW, MaxEntries]
    graphFragments*: List[BlobRefW, MaxEntries]
    configuration*: List[ConfigContributionW, MaxEntries]
    exposedConfigurables*: List[ExposedConfigurableW, MaxSmallLists]
    tests*: List[TestRefW, MaxEntries]
    healthChecks*: List[HealthCheckW, MaxSmallLists]
    assets*: List[BlobRefW, MaxSmallLists]
    permissions*: List[PermissionW, MaxSmallLists]
    dataMigrations*: List[DataMigrationW, MaxDataMigrations]
    dependenciesAdded*: List[OriginalRefW, MaxEntries]
    authors*: List[Digest32, MaxSignatures]
    extensions*: List[ExtensionW, MaxExtensions]

  SignatureW* = object
    keyId*: Digest32
    algorithm*: uint8
    publicKey*: List[byte, MaxPublicKeyBytes]
    value*: List[byte, MaxSignatureValueBytes]

  WrapperW* = object
    ## The bounded wrapper inside the RBSZ frame (spec §"Envelope").
    schemaVersion*: uint16
    requiredFeatures*: uint32
    recordKind*: uint8
    body*: List[byte, MaxBodyBytes]
    signatures*: List[SignatureW, MaxSignatures]
