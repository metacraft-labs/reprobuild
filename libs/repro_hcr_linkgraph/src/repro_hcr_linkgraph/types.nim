type
  ObjectFormat* = enum
    ofMachO64Arm64

  SectionKind* = enum
    skCode
    skData
    skDebug
    skUnwind
    skOther

  SymbolKind* = enum
    sykUndefined
    sykFunction
    sykData
    sykSection
    sykOther

  UnsupportedSeverity* = enum
    usInfo
    usFallbackRequired
    usReject

  RelocationSupport* = enum
    rsSupportedDirect
    rsUnsupported

  FunctionChangeKind* = enum
    fckUnchanged
    fckChangedCode
    fckRelocationSignatureChanged
    fckAdded
    fckRemoved

  SectionFact* = object
    id*: int
    segmentName*: string
    name*: string
    address*: uint64
    size*: uint64
    fileOffset*: uint64
    alignmentPower*: uint32
    flags*: uint32
    kind*: SectionKind
    data*: seq[byte]
    relocationIds*: seq[int]

  SymbolFact* = object
    id*: int
    name*: string
    rawName*: string
    kind*: SymbolKind
    sectionId*: int
    address*: uint64
    size*: uint64
    isExternal*: bool
    isDefined*: bool

  RelocationFact* = object
    id*: int
    sectionId*: int
    offset*: uint32
    typeCode*: uint8
    kindName*: string
    pcrel*: bool
    lengthBytes*: uint8
    isExtern*: bool
    symbolIndex*: int
    targetName*: string
    addend*: int64
    scattered*: bool

  UnsupportedFeatureFact* = object
    feature*: string
    severity*: UnsupportedSeverity
    sectionId*: int
    relocationId*: int
    reason*: string

  LinkGraph* = object
    schemaId*: string
    sourcePath*: string
    format*: ObjectFormat
    arch*: string
    sections*: seq[SectionFact]
    symbols*: seq[SymbolFact]
    relocations*: seq[RelocationFact]
    unsupportedFeatures*: seq[UnsupportedFeatureFact]
    hasDebugFacts*: bool
    hasUnwindFacts*: bool

  RelocationSignature* = object
    offsetWithinFunction*: uint64
    kindName*: string
    typeCode*: uint8
    targetName*: string
    pcrel*: bool
    lengthBytes*: uint8
    isExtern*: bool
    addend*: int64

  FunctionDiff* = object
    name*: string
    kind*: FunctionChangeKind
    oldRawDigest*: string
    newRawDigest*: string
    oldNormalizedDigest*: string
    newNormalizedDigest*: string
    rawBytesEqual*: bool
    normalizedBytesEqual*: bool
    relocationSignaturesEqual*: bool
    oldRelocations*: seq[RelocationSignature]
    newRelocations*: seq[RelocationSignature]

  FunctionDiffSet* = object
    schemaId*: string
    functions*: seq[FunctionDiff]

  TargetSymbolFact* = object
    name*: string
    address*: uint64
    kind*: SymbolKind

  DeterministicTargetSnapshot* = object
    schemaId*: string
    snapshotId*: string
    pointerWidthBytes*: uint8
    symbols*: seq[TargetSymbolFact]

  RelocationDecision* = object
    relocationId*: int
    functionName*: string
    sectionName*: string
    offsetWithinFunction*: uint64
    kindName*: string
    targetName*: string
    support*: RelocationSupport
    reason*: string
    requiresTargetSymbol*: bool
    targetAddress*: uint64

  PlannedSectionBytes* = object
    functionName*: string
    sectionName*: string
    byteCount*: uint64
    rawDigest*: string
    normalizedDigest*: string
    bytes*: seq[byte]

  PatchPlanEvidence* = object
    schemaId*: string
    supportProfile*: string
    targetSnapshotId*: string
    changedFunctions*: seq[string]
    plannedSectionBytes*: seq[PlannedSectionBytes]
    relocationDecisions*: seq[RelocationDecision]
    requiredTargetSymbols*: seq[string]
    unsupportedFallbackReasons*: seq[string]
    mutatesTarget*: bool
    targetMutationOperations*: int
    sharedLibraryPositivePath*: bool
