import repro_hcr_linkgraph

type
  TargetProtection* = enum
    tpNoAccess
    tpReadWrite
    tpReadExec
    tpReadWriteExec

  TargetRegionKind* = enum
    trkOriginalText
    trkPatchCode
    trkRetainedOldCode

  TargetMemoryRegion* = object
    id*: string
    base*: uint64
    size*: uint64
    protection*: TargetProtection
    kind*: TargetRegionKind

  TrampolineKind* = enum
    tkAarch64BranchImm26
    tkX86_64JmpRel32
      ## HLX-M0: the Linux x86_64 published trampoline. Five bytes
      ## (``E9 rel32``) stored inside a single naturally aligned 8-byte
      ## window, per ``HCR/Linux-ELF-Provider.md`` §4.2. The kind exists so a
      ## selection that would need a non-atomically-publishable 13- or 14-byte
      ## encoding has no representation to fall into; far targets route through
      ## an island in HLX-M2 and the published store stays this shape.

  TrampolinePlan* = object
    kind*: TrampolineKind
    sourceAddress*: uint64
    destinationAddress*: uint64
    displacementBytes*: int64
    bytes*: seq[byte]

  PatchOperationKind* = enum
    pokAllocatePatchMemory
    pokWritePatchBytes
    pokSetExecutableProtection
    pokFlushInstructionCache
    pokInstallTrampoline
    pokPublishSymbolGeneration
    pokRetainOldPatchRegion

  PatchTransactionOperation* = object
    kind*: PatchOperationKind
    name*: string
    address*: uint64
    byteCount*: uint64
    protection*: TargetProtection
    commitMutation*: bool

  PatchTransaction* = object
    schemaId*: string
    transactionId*: string
    functionName*: string
    targetEntryAddress*: uint64
    nopSledBytes*: uint32
    patchPlan*: PatchPlanEvidence
    patchBytes*: seq[byte]

  PatchTransactionEvidence* = object
    schemaId*: string
    transactionId*: string
    supportProfile*: string
    functionName*: string
    preparationComplete*: bool
    commitComplete*: bool
    patchAddress*: uint64
    patchSize*: uint64
    trampoline*: TrampolinePlan
    operations*: seq[PatchTransactionOperation]
    oldEntryBytes*: seq[byte]
    retainedRegionAddresses*: seq[uint64]
    symbolGeneration*: uint64
    sharedLibraryPositivePath*: bool
    debuggerUnwindRegistered*: bool

  ReadTargetBytesProc* = proc(ctx: pointer; address: uint64;
                              byteCount: int): seq[byte]
  AllocatePatchMemoryProc* = proc(ctx: pointer; nearAddress: uint64;
                                  byteCount: int): TargetMemoryRegion
  WritePatchBytesProc* = proc(ctx: pointer; region: TargetMemoryRegion;
                              bytes: seq[byte])
  SetExecutableProtectionProc* = proc(ctx: pointer;
                                      region: TargetMemoryRegion):
                                      TargetMemoryRegion
  FlushInstructionCacheProc* = proc(ctx: pointer; address: uint64;
                                    byteCount: int)
  InstallTrampolineProc* = proc(ctx: pointer; functionName: string;
                                entryAddress: uint64;
                                trampoline: TrampolinePlan): seq[byte]
  PublishSymbolGenerationProc* = proc(ctx: pointer; functionName: string;
                                      patchAddress: uint64;
                                      patchSize: uint64): uint64
  RetainOldPatchRegionProc* = proc(ctx: pointer; functionName: string;
                                   entryAddress: uint64;
                                   oldEntryBytes: seq[byte]): TargetMemoryRegion

  TargetEnvironmentOps* = object
    ctx*: pointer
    readTargetBytes*: ReadTargetBytesProc
    allocatePatchMemory*: AllocatePatchMemoryProc
    writePatchBytes*: WritePatchBytesProc
    setExecutableProtection*: SetExecutableProtectionProc
    flushInstructionCache*: FlushInstructionCacheProc
    installTrampoline*: InstallTrampolineProc
    publishSymbolGeneration*: PublishSymbolGenerationProc
    retainOldPatchRegion*: RetainOldPatchRegionProc
