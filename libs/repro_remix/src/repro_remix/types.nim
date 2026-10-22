## Domain types for the Remix protocol.
##
## Normative source: `reprobuild-pm/spec/Remix-Protocol.md`. The section
## each type implements is named on the type. These are the in-memory
## domain values callers build and inspect; `wire.nim` holds the SSZ
## mirror types and `codec.nim` converts between the two, enforcing the
## canonical form and the parser bounds on the way in.

const
  RemixSchemaVersion* = 1'u16
    ## The only schema version this build reads and writes
    ## (§"Schema evolution"). Readers of a later build decode every
    ## version up to their own; this one knows only v1.
  RemixKnownFeatures* = 0'u32
    ## `requiredFeatures` bits this build understands. Zero in v1: any
    ## set bit refuses (Invariant I-9).
  RemixEnvelopeTypeId* = 0x1101'u16
    ## RBSZ type ID for the Remix family. PROVISIONAL (spec OD-3): it
    ## must be confirmed by the central type-ID registry before any
    ## record is published outside a test fixture.

  # §"Parser bounds". Raising any of these is a schema change.
  MaxBodyBytes* = 4 * 1024 * 1024
  MaxSignatures* = 16
  MaxParents* = 64
  MaxEntries* = 1024
    ## Targets, sources, patches, configuration entries, graph
    ## fragments, tests and added dependencies, each.
  MaxSmallLists* = 256
    ## Exposed configurables, health checks, assets, permissions.
  MaxPlatforms* = 64
  MaxDataMigrations* = 64
  MaxExtensions* = 32
  MaxExtensionBytes* = 64 * 1024
  MaxTextBytes* = 64 * 1024
  MaxIntentBytes* = 16 * 1024
  MaxNameBytes* = 256
  MaxRevisionBytes* = 64
    ## Full-width hex object id: 40 (SHA-1) or 64 (SHA-256) characters.
  MaxDigestTextBytes* = 80
    ## Self-describing `<alg>:<hex>` digest text.
  MaxBlobBytes* = 512'u64 * 1024 * 1024
  MaxAssetBytes* = 16'u64 * 1024 * 1024
  MaxLineageDepth* = 256
    ## Spec OD-7; provisional.
  MaxSignatureValueBytes* = 132
  MaxPublicKeyBytes* = 133

type
  Digest32* = array[32, byte]

  RemixError* = object of CatchableError
    ## Every refusal the codec, the signature check or the lineage walk
    ## makes. `reason` is a stable, machine-readable code so a caller (and
    ## the parser-bounds corpus) can tell refusals apart without matching
    ## message text.
    reason*: RemixRefusal

  RemixRefusal* = enum
    rrTruncated = "truncated"
    rrBadMagic = "bad-magic"
    rrUnknownEnvelopeVersion = "unknown-envelope-version"
    rrUnknownTypeId = "unknown-type-id"
    rrLengthMismatch = "length-mismatch"
    rrOversize = "oversize"
    rrMalformed = "malformed"
    rrUnknownSchemaVersion = "unknown-schema-version"
    rrUnknownRequiredFeature = "unknown-required-feature"
    rrUnknownRecordKind = "unknown-record-kind"
    rrNonCanonical = "non-canonical"
    rrDuplicate = "duplicate"
    rrUnsorted = "unsorted"
    rrBound = "bound-exceeded"
    rrInvalidText = "invalid-text"
    rrUnknownVocabulary = "unknown-vocabulary"
    rrUnknownCriticalExtension = "unknown-critical-extension"
    rrForbiddenContent = "forbidden-content"
    rrDanglingReference = "dangling-reference"
    rrUnknownAlgorithm = "unknown-algorithm"
    rrBadSignature = "bad-signature"
    rrMissingAuthorSignature = "missing-author-signature"
    rrKeyMismatch = "key-mismatch"
    rrLineageCycle = "lineage-cycle"
    rrLineageTooDeep = "lineage-too-deep"
    rrIncompleteLineage = "incomplete-lineage"
    rrDigestMismatch = "digest-mismatch"
    rrMissingBlob = "missing-blob"
    rrSizeMismatch = "size-mismatch"
    rrNotLogged = "not-logged"
    rrRevokedKey = "revoked-key"
    rrInactiveKey = "inactive-key"
    rrBlockedByPolicy = "blocked-by-policy"

  RecordKind* = enum
    ## §"Envelope". Only `rkManifest` has a body codec in this build; the
    ## others are reserved so their tags never get reused.
    rkManifest = 1
    rkComposition = 2
    rkStatement = 3
    rkKeyLogEntry = 4
    rkInstallLock = 5
    rkBundleIndex = 6

  SignatureAlgorithm* = enum
    ## §"Envelope". Tag 1 is the only one defined in v1 (spec OD-2).
    saEcdsaP256 = 1

  ConstraintKind* = enum
    ## §"Compatibility", version axis.
    ckExactFingerprint = 0
    ckVersionRange = 1

  PatchTargetKind* = enum
    ## What a patch's `appliesTo` index points into.
    ptTarget = 0
    ptSource = 1

  ConfigPriority* = enum
    ## The priorities of `Configurable-System.md` §"Priorities And
    ## Contributions" that a Remix may use. `prDefault` (0) belongs to the
    ## configurable's own definition and `prForce` (3) is refused in a
    ## Remix, so neither has a value here: decoding one is a refusal.
    cpSet = 1
    cpOverride = 2

  ConfigOperation* = enum
    ## `Configurable-System.md` §"Operation is a SECOND axis".
    coReplace = 1
    coAppend = 2

  HealthCheckKind* = enum
    ## §"Manifest body", `healthChecks`; closed vocabulary (spec OD-4).
    hcUnitActive = 1
    hcUnitNotFailed = 2
    hcSocketListening = 3
    hcPathExists = 4
    hcCommandExitZero = 5

  PermissionKind* = enum
    ## §"Permissions"; closed v1 vocabulary. Kinds that take a scope are
    ## marked in `permissionTakesScope`.
    pkNetworkClient = 1
    pkNetworkListen = 2
    pkFilesystemRead = 3
    pkFilesystemWrite = 4
    pkDevice = 5
    pkSystemService = 6
    pkUserService = 7
    pkPrivilegedHelper = 8
    pkSetuid = 9
    pkKernelModule = 10
    pkBootChain = 11
    pkCredentialStore = 12
    pkIpc = 13
    pkScheduledTask = 14
    pkDataMigration = 15

  MigrationKind* = enum
    ## Invariant I-6: every data migration names its rollback behaviour.
    mkReversible = 1
    mkBackupRestore = 2
    mkOneWay = 3

  OriginalRef* = object
    ## §"Identities", Original software: a package as a catalog import
    ## published it (Federated-Catalog-Imports.md's four components plus
    ## the package and its interface fingerprint).
    package*: string
    interfaceFingerprint*: Digest32
    catalogWorkspace*: string
    catalogRemote*: string
    catalogRevision*: string
    catalogInterfaceArtifact*: Digest32

  Target* = object
    original*: OriginalRef
    constraintKind*: ConstraintKind
    constraint*: string
      ## Empty for `ckExactFingerprint`; a version range otherwise.

  SourceTree* = object
    repo*: string
    remote*: string
    revision*: string
    digest*: string
      ## Self-describing `<alg>:<hex>` tree digest.

  BlobRef* = object
    id*: Digest32
      ## BLAKE3-256 of the blob bytes (the CAS identity).
    mediaType*: string
    size*: uint64

  Patch* = object
    appliesToKind*: PatchTargetKind
    appliesToIndex*: uint16
    blob*: BlobRef
    strip*: uint8
    order*: uint16

  ConfigContribution* = object
    configurable*: string
    schemaFingerprint*: Digest32
    priority*: ConfigPriority
    operation*: ConfigOperation
    value*: BlobRef

  ExposedConfigurable* = object
    name*: string
    schemaFingerprint*: Digest32

  TestRef* = object
    name*: string
    fragment*: uint16
      ## Index into `graphFragments`.

  HealthCheck* = object
    kind*: HealthCheckKind
    target*: string
    timeoutSeconds*: uint32

  Permission* = object
    kind*: PermissionKind
    scope*: string
      ## Empty unless the kind takes a scope.

  DataMigration* = object
    store*: string
    kind*: MigrationKind
    edge*: string

  Extension* = object
    id*: string
    critical*: bool
    payload*: seq[byte]

  Manifest* = object
    ## §"Manifest body". Field order here is the wire order.
    remixName*: string
    version*: string
    intent*: string
    license*: string
    targets*: seq[Target]
    platforms*: seq[string]
    parents*: seq[Digest32]
    sources*: seq[SourceTree]
    patches*: seq[Patch]
    graphFragments*: seq[BlobRef]
    configuration*: seq[ConfigContribution]
    exposedConfigurables*: seq[ExposedConfigurable]
    tests*: seq[TestRef]
    healthChecks*: seq[HealthCheck]
    assets*: seq[BlobRef]
    permissions*: seq[Permission]
    dataMigrations*: seq[DataMigration]
    dependenciesAdded*: seq[OriginalRef]
    authors*: seq[Digest32]
      ## `KeyId`s whose signatures the manifest requires.
    extensions*: seq[Extension]

  Signature* = object
    keyId*: Digest32
    algorithm*: SignatureAlgorithm
    publicKey*: seq[byte]
      ## Carried so a release verifies offline (Invariant I-10). The key is
      ## only *trusted* through the signer's key log; `keyId` binds it.
    value*: seq[byte]

  Envelope* = object
    ## A decoded record: header fields, the canonical body bytes and the
    ## signatures. `body` is kept as bytes because identities are computed
    ## over it, never over a re-encoding of a domain value.
    schemaVersion*: uint16
    requiredFeatures*: uint32
    recordKind*: RecordKind
    body*: seq[byte]
    signatures*: seq[Signature]

  ReleaseId* = distinct Digest32
  KeyId* = distinct Digest32

proc `==`*(a, b: ReleaseId): bool {.borrow.}
proc `==`*(a, b: KeyId): bool {.borrow.}

proc permissionTakesScope*(kind: PermissionKind): bool =
  ## Kinds whose capability is meaningless without a scope (§"Permissions":
  ## `filesystem-read:<scope>` and the like). The others must carry an
  ## empty scope, so one capability has exactly one encoding.
  kind in {pkFilesystemRead, pkFilesystemWrite, pkDevice, pkIpc,
           pkDataMigration}

proc refuse*(reason: RemixRefusal; detail: string) {.noreturn.} =
  ## Raise a `RemixError` carrying a stable reason code.
  var e = newException(RemixError, $reason & ": " & detail)
  e.reason = reason
  raise e
