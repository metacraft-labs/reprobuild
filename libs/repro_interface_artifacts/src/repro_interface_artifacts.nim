import std/[algorithm, options, os, osproc, sequtils, sets, streams, strutils,
            tables, tempfiles, times]

when defined(windows):
  type
    ProviderLockHandle = pointer
    ProviderLockDword = uint32
    ProviderLockWideString = WideCString

  const
    ProviderLockInvalidHandle = cast[ProviderLockHandle](-1'i64)
    ProviderLockGenericRead = 0x80000000'u32
    ProviderLockGenericWrite = 0x40000000'u32
    ProviderLockOpenAlways = 4'u32
    ProviderLockFileAttributeNormal = 0x80'u32
    ProviderLockSharingViolation = 32'u32

  proc providerLockCreateFileW(
      path: ProviderLockWideString;
      desiredAccess, shareMode: ProviderLockDword;
      securityAttributes: pointer;
      creationDisposition, flagsAndAttributes: ProviderLockDword;
      templateFile: ProviderLockHandle): ProviderLockHandle
    {.stdcall, dynlib: "kernel32", importc: "CreateFileW".}

  proc providerLockCloseHandle(handle: ProviderLockHandle): int32
    {.stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  proc providerLockGetLastError(): ProviderLockDword
    {.stdcall, dynlib: "kernel32", importc: "GetLastError".}
else:
  import std/posix

  const ProviderLockExclusive = 2.cint

  proc providerLockFlock(fd: cint; operation: cint): cint
    {.importc: "flock", header: "<sys/file.h>".}

import cbor
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import repro_project_dsl

proc sanitizeStaticExec(val: string): string =
  var cleanLines: seq[string] = @[]
  for line in val.splitLines:
    let s = line.strip()
    if s.len > 0 and not s.startsWith("io-mon:"):
      cleanLines.add(s)
  if cleanLines.len > 0: cleanLines[^1] else: ""

const BuiltNimCompilerPath = sanitizeStaticExec(staticExec("command -v nim"))
const BuiltCCompilerPath =
  sanitizeStaticExec(staticExec("command -v cc || command -v gcc || true"))

proc compileTimeSourceRoot(name: string): string {.compileTime.} =
  ## Preserve source-only dependency roots from the environment that built
  ## ``repro``. A Nix-built CLI can then compile out-of-tree providers after
  ## leaving its dev shell; embedding the store paths also keeps those inputs
  ## in the installed closure. Runtime overrides and live sibling checkouts
  ## still take precedence at resolution time.
  let root = getEnv(name)
  if root.len == 0 or root.isAbsolute:
    root
  else:
    # Nim VM cannot call the Windows current-directory API used by
    # `absolutePath`. This module's source location is already known during
    # compilation, so resolve build-environment paths against the reprobuild
    # checkout without consulting ambient process state.
    let reprobuildRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
    os.normalizedPath(reprobuildRoot / root)

const BuiltSourcePackageRoots = [
  ("REPRO_TEST_ADAPTERS_SRC", compileTimeSourceRoot("REPRO_TEST_ADAPTERS_SRC")),
  ("FASTSTREAMS_SRC", compileTimeSourceRoot("FASTSTREAMS_SRC")),
  ("NIM_STEW_SRC", compileTimeSourceRoot("NIM_STEW_SRC")),
  ("NIM_SERIALIZATION_SRC", compileTimeSourceRoot("NIM_SERIALIZATION_SRC")),
  ("NIM_JSON_SERIALIZATION_SRC", compileTimeSourceRoot("NIM_JSON_SERIALIZATION_SRC")),
  ("NIM_TOML_SERIALIZATION_SRC", compileTimeSourceRoot("NIM_TOML_SERIALIZATION_SRC")),
  ("SSZ_SERIALIZATION_SRC", compileTimeSourceRoot("SSZ_SERIALIZATION_SRC")),
  ("NIMCRYPTO_SRC", compileTimeSourceRoot("NIMCRYPTO_SRC")),
  ("BEARSSL_SRC", compileTimeSourceRoot("BEARSSL_SRC")),
  ("RESULTS_SRC", compileTimeSourceRoot("RESULTS_SRC")),
  ("STINT_SRC", compileTimeSourceRoot("STINT_SRC")),
  ("IO_MON_SRC", compileTimeSourceRoot("IO_MON_SRC")),
  ("STACKABLE_HOOKS_SRC", compileTimeSourceRoot("STACKABLE_HOOKS_SRC")),
  ("VM_HARNESS_SRC", compileTimeSourceRoot("VM_HARNESS_SRC")),
  ("SHM_QUEUE_SRC", compileTimeSourceRoot("SHM_QUEUE_SRC")),
  ("SHM_GSET_SRC", compileTimeSourceRoot("SHM_GSET_SRC")),
  ("REPRO_CT_TEST_RUNNER_SRC",
    compileTimeSourceRoot("REPRO_CT_TEST_RUNNER_SRC")),
  ("CODETRACER_SRC", compileTimeSourceRoot("CODETRACER_SRC")),
  ("RUNQUOTA_SRC", compileTimeSourceRoot("RUNQUOTA_SRC")),
]

proc builtSourcePackageRoot(envName: string): string =
  for entry in BuiltSourcePackageRoots:
    if entry[0] == envName:
      return entry[1]

proc seedSourcePackageEnvironment*(roots: openArray[(string, string)]) =
  ## Child compilers rebuild the interface-artifact module and therefore
  ## cannot see its parent's compile-time constants. Export valid embedded
  ## roots through the process environment so every nested extractor and
  ## resource-accessor compile inherits the same source closure.
  for (envName, root) in roots:
    # A build-time relative path is anchored at the directory where the CLI
    # happened to be compiled. Re-exporting it from a consumer or temp runner
    # silently changes its meaning. New binaries normalize such roots while
    # compiling; rejecting them here also keeps older binaries from poisoning
    # cold out-of-tree interface extraction.
    if not existsEnv(envName) and root.isAbsolute and
        dirExists(extendedPath(root)):
      putEnv(envName, root)

proc ensureBuiltSourcePackageEnvironment*() =
  seedSourcePackageEnvironment(BuiltSourcePackageRoots)

type
  InterfaceEnvelopeKind* = enum
    iekProjectInterface
    iekProviderCompile

  InterfaceParamKind* = enum
    ipkPositional
    ipkFlag

  SourceLocation* = object
    file*: string
    line*: int

  InterfaceParam* = object
    name*: string
    nimType*: string
    kind*: InterfaceParamKind
    position*: int
    alias*: string
    required*: bool
    location*: SourceLocation

  InterfaceCommand* = object
    name*: string
    params*: seq[InterfaceParam]
    providerEntrypointId*: string
    location*: SourceLocation

  InterfaceExecutable* = object
    exportName*: string
    binaryName*: string
    commands*: seq[InterfaceCommand]
    location*: SourceLocation

  InterfaceLibrary* = object
    name*: string
    kind*: LibraryKind
    exportedPath*: string
      ## Cross-Repo-Source-Consumption SC-11 (§4.2a.4): the producer-relative
      ## Nim library source root a consumer threads onto its ``nim c --path:``.
      ## Empty ( = convention default ``"src"``) so existing producers work
      ## unchanged; carried across lock-pinned fetches on the interface so a
      ## non-standard layout is known from the fetched interface alone.
    location*: SourceLocation

  InterfaceResourceDeterminism* = enum
    ## RP4: the determinism class carried on an ``InterfaceResource``,
    ## a self-contained mirror (by ordinal) of
    ## ``repro_home_resources``'s ``ResourceDeterminism`` so the codec
    ## does not pull the home-resources / blake3 closure into the
    ## interface-artifacts library. The ``resourceType`` DSL macro maps
    ## the generic-lane ``ResourceDeterminism`` onto this enum at
    ## interface-lifting time. Ordinals MUST stay aligned with
    ## ``ResourceDeterminism`` (rdStrong=0 … rdVolatile=3).
    irdStrong        ## bytewise reproducible; cross-machine substitutable
    irdWeak          ## reproducible up to declared noise
    irdHostBound     ## realization is machine-specific
    irdVolatile      ## inherently non-reproducible

  InterfaceResourceAttr* = object
    ## RP4: one typed attribute of a resource contract — the field name
    ## and its Nim type, as declared by an ``attr <name>: <type>`` line
    ## in the ``resourceType`` block. Mirrors ``InterfaceParam`` in
    ## spirit: it is the typed-wrapper parameter surface a consumer
    ## binds against, so renaming a field (or changing its type) SHIFTS
    ## the exported schema and the interface fingerprint.
    name*: string
    nimType*: string
    location*: SourceLocation

  InterfaceResourceEntrypoints* = object
    ## RP4: the driver ops a resource provider exposes as protocol entry
    ## points (v1 §5). Each is the ``providerEntrypointId`` a consumer's
    ## resource op lowers to an ``InvokeEntryPoint`` against. ``plan`` is
    ## carried as a first-class protocol op even though the generic
    ## native driver folds planning into ``reconcileResources`` — the
    ## contract shape is the protocol surface, not the native vtable.
    identity*: string
    digest*: string
    observe*: string
    plan*: string
    apply*: string

  InterfaceResource* = object
    ## RP4 (Provider-Runtime-Protocol-v1 §5): a resource type crossing
    ## the interface boundary as a typed contract, alongside
    ## ``InterfaceExecutable`` / ``InterfaceLibrary``. Carries the stable
    ## ``typeId``, the determinism class (part of the contract so a
    ## consumer can reason about a resource edge WITHOUT invoking the
    ## driver), the typed attribute schema, and the entry-point
    ## descriptors for the driver ops.
    typeId*: string
    determinism*: InterfaceResourceDeterminism
    attributes*: seq[InterfaceResourceAttr]
    entrypoints*: InterfaceResourceEntrypoints
    location*: SourceLocation

  InterfaceNixProvisioning* = object
    packageName*: string
    contributor*: string
    selector*: string
    executablePath*: string
    expressionFile*: string
    nixpkgsRef*: string
    nixpkgsRev*: string
    nixpkgsNarHash*: string
    packageId*: string
    lockIdentity*: string
    location*: SourceLocation

  InterfaceTarballProvisioning* = object
    packageName*: string
    contributor*: string
    url*: string
    mirrors*: seq[string]
    sha256*: string
    archiveType*: string
    executablePath*: string
    stripComponents*: int
    packageId*: string
    lockIdentity*: string
    cpu*: string
    os*: string
    location*: SourceLocation

  InterfaceScoopProvisioning* = object
    packageName*: string
    contributor*: string
    bucket*: string
    app*: string
    version*: string
    preferredVersion*: string
    manifestChecksum*: string
    manifestUrl*: string
    executablePath*: string
    requiresExecutionProfileChecksum*: bool
    packageId*: string
    lockIdentity*: string
    location*: SourceLocation

  InterfaceToolUse* = object
    rawConstraint*: string
    packageSelector*: string
    executableName*: string
    policyPath*: seq[string]
    nixProvisioning*: seq[InterfaceNixProvisioning]
    tarballProvisioning*: seq[InterfaceTarballProvisioning]
    scoopProvisioning*: seq[InterfaceScoopProvisioning]
    location*: SourceLocation

  InterfaceProvisioningContribution* = object
    targetPackage*: string
    targetInterfaceFingerprint*: string
    contributor*: string
    developInterface*: bool
    nixProvisioning*: seq[InterfaceNixProvisioning]
    tarballProvisioning*: seq[InterfaceTarballProvisioning]
    scoopProvisioning*: seq[InterfaceScoopProvisioning]
    location*: SourceLocation

  ProjectInterface* = object
    projectName*: string
    packageName*: string
    defaultToolProvisioning*: string
    publicExecutables*: seq[InterfaceExecutable]
    publicLibraries*: seq[InterfaceLibrary]
    publicResources*: seq[InterfaceResource]
      ## RP4 (Provider-Runtime-Protocol-v1 §5): resource types this
      ## package exposes as typed contracts, lifted from ``resourceType``
      ## declarations. Encoded in the v12 codec AFTER ``publicLibraries``
      ## and BEFORE ``toolUses``; v<12 readers treat it as empty.
    toolUses*: seq[InterfaceToolUse]
    runtimeToolUses*: seq[InterfaceToolUse]
      ## Package-level runtime dependencies retained separately from the
      ## flattened tool-use surface. Cross-repository executable consumers use
      ## this closure to launch the produced binary with its declared tools.
    provisioningContributions*: seq[InterfaceProvisioningContribution]
    publicSignatureDependencies*: seq[string]
    location*: SourceLocation
    standardBuildEligible*: bool
      ## True iff the package's DSL body declared no ``build:`` block —
      ## the engine's Tier 2b fast path dispatches such projects to the
      ## pre-built ``repro-standard-provider`` binary, which derives the
      ## graph from language conventions instead of compiling a project-
      ## specific provider. See
      ## ``reprobuild-specs/Standard-Provider-Implementation.milestones.org``
      ## §M2 and ``Provider-Compile-Tiering.md`` §"2b".

  ProjectInterfaceArtifact* = object
    projectInterface*: ProjectInterface
    interfaceFingerprint*: ContentDigest

  ProviderCompileExecutionResult* = object
    exitCode*: int
    output*: string

  ProviderCompileEdge* = object
    actionSpec*: ActionSpec
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    actionFingerprint*: ContentDigest

  ProviderCompilePlan* = object
    inputSources*: seq[string]
    outputBinaryPath*: string
    compilerCommand*: seq[string]
    compileEdge*: ProviderCompileEdge
    interfaceFingerprint*: ContentDigest
    providerFingerprint*: ContentDigest
    providerArtifactId*: ContentDigest
      ## RP1: the Provider-Runtime-Protocol v1 ``ProviderArtifactId`` — the
      ## content-addressed identity two consumers of the same dependency
      ## version converge on (the sharing key). See
      ## ``computeProviderArtifactId``.
    providerCompileActionKey*: ContentDigest
      ## RP1: the v1 ``ProviderCompileActionKey`` used as the engine edge's
      ## action key. See ``computeProviderCompileActionKey``.
    workDir*: string

  ProviderCompileArtifact* = object
    inputSources*: seq[string]
    outputBinaryPath*: string
    compilerCommand*: seq[string]
    compileEdge*: ProviderCompileEdge
    interfaceFingerprint*: ContentDigest
    providerFingerprint*: ContentDigest
    outputBinaryFingerprint*: ContentDigest
    executionResult*: ProviderCompileExecutionResult

  InterfaceLiftEdge* = object
    ## TI1: the engine build-edge that LIFTS a producer's interface once into
    ## a cached, content-addressed ``ProjectInterfaceArtifact``. Mirrors
    ## ``ProviderCompileEdge`` — a declared-input/-output edge whose action key
    ## is the ``InterfaceLiftActionKey`` (canonical source inputs + compiler
    ## identity + interface format version), so a rebuild with an unchanged
    ## lift input set is a cache HIT (the lift is not re-run per consumer).
    actionSpec*: ActionSpec
    declaredInputs*: seq[string]
    declaredOutputs*: seq[string]
    actionFingerprint*: ContentDigest

  InterfaceLiftPlan* = object
    ## TI1: the plan for a producer's interface-lift edge. Analogous to
    ## ``ProviderCompilePlan``. ``interfaceLiftActionKey`` decides the engine
    ## action-cache HIT/re-run (input-keyed like the RP1
    ## ``ProviderCompileActionKey``); ``interfaceFingerprint`` is the OUTPUT
    ## identity — the hash of the resulting ``ProjectInterface``'s PUBLIC
    ## surface only, which is what re-keys downstream consumers (TI2/TI3).
    modulePath*: string
    resourceModule*: string
    extraPaths*: seq[string]
    artifactPath*: string
    stubPath*: string
    inputSources*: seq[string]
    liftEdge*: InterfaceLiftEdge
    interfaceLiftActionKey*: ContentDigest
    workDir*: string

  FileStampKind = enum
    fskMissing
    fskRegular
    fskDirectory
    fskOther

  FileStamp = object
    path: string
    kind: FileStampKind
    sizeBytes: uint64
    mtimeNs: uint64

  InterfaceExtractionContext = object
    modulePath: string
    workDir: string
    nimCompiler: string
    libPathFlags: seq[string]
    reproLibFingerprint: string
    sources: seq[string]

  InterfaceExtractionCacheRecord = object
    context: InterfaceExtractionContext
    sourceStamps: seq[FileStamp]
    reproLibStamps: seq[FileStamp]
    inputFingerprint: ContentDigest

  ProviderFreshnessCacheRecord = object
    modulePath: string
    workDir: string
    outputBinaryPath: string
    sourceStamps: seq[FileStamp]
    reproLibStamps: seq[FileStamp]
    outputBinaryStamp: FileStamp
    interfaceFingerprint: ContentDigest
    providerFingerprint: ContentDigest
    reproLibFingerprint: string
    outputBinaryFingerprint: ContentDigest

  InterfaceArtifactWarmStats* = object
    metadataColdReads*: int
    metadataWarmHits*: int
    metadataWarmMisses*: int
    metadataRevalidatedSources*: int
    metadataRevalidatedReproLibs*: int
    artifactColdReads*: int
    artifactWarmHits*: int
    artifactWarmMisses*: int

  WarmInterfaceExtractionCacheRecord = object
    evidence: FileStamp
    record: InterfaceExtractionCacheRecord

  WarmProjectInterfaceArtifact = object
    evidence: FileStamp
    artifact: ProjectInterfaceArtifact

const
  EnvelopeMagic = [byte(ord('R')), byte(ord('B')), byte(ord('S')), byte(ord('Z'))]
  EnvelopeVersion = 14'u16
    ## v14 (current): retains package runtime dependencies in
    ##                ``ProjectInterface.runtimeToolUses``. The block follows
    ##                ``toolUses`` and precedes provisioning contributions.
    ## v13: adds fingerprint-bound provisioning contributions and
    ##                contributor identity on Nix/tarball/Scoop records. The
    ##                contribution block follows ``toolUses``. Provisioning
    ##                payloads remain serialized but are omitted from the
    ##                target project's semantic fingerprint, so realization
    ##                amendments do not masquerade as public API changes.
    ## v12: RP4 (Provider-Runtime-Protocol-v1 §5) adds
    ##                ``ProjectInterface.publicResources`` — resource
    ##                types lifted from ``resourceType`` declarations.
    ##                Encoded as a ``u32`` count + per-entry
    ##                ``InterfaceResource`` rows appended to the interface
    ##                payload AFTER the ``publicLibraries`` block and
    ##                BEFORE the ``toolUses`` block, matching the source
    ##                field order. v11 readers reject v12 envelopes (the
    ##                ``version > EnvelopeVersion`` check); v12 readers
    ##                accept v<12 by treating ``publicResources`` as an
    ##                empty seq (``decodeInterfacePayload`` gates the read
    ##                on ``version >= 12``), mirroring the v8→v9
    ##                ``publicLibraries`` precedent.
    ## v11: Cross-Repo-Source-Consumption SC-11 (§4.2a.4) adds
    ##                ``InterfaceLibrary.exportedPath`` — the producer-relative
    ##                Nim library source root threaded onto a consumer's
    ##                ``nim c --path:``. Encoded as one string appended AFTER
    ##                ``kind`` and BEFORE ``location`` in ``writeLibrary``. v10
    ##                (and earlier) payloads decode with an empty
    ##                ``exportedPath`` ( = convention default ``"src"``), so
    ##                existing producers round-trip unchanged; ``readLibrary``
    ##                gates the read on ``version >= 11``.
    ## v10: adds ``InterfaceTarballProvisioning.cpu`` /
    ##                ``InterfaceTarballProvisioning.os`` per-platform
    ##                target fields. Encoded as two strings appended
    ##                AFTER ``lockIdentity`` and BEFORE ``location`` in
    ##                ``writeTarballProvisioning``. v9 payloads decode
    ##                with empty cpu/os strings ( = "any" semantics).
    ## v9: adds ``ProjectInterface.publicLibraries`` — the M12
    ##               DSL ``library`` member enumerates here. Encoded as a
    ##               ``u32`` count + per-entry ``InterfaceLibrary`` rows
    ##               appended to the interface payload BEFORE the
    ##               ``toolUses`` block. v8 readers reject v9 envelopes
    ##               (the version > EnvelopeVersion check below). v9
    ##               readers accept v8 by treating ``publicLibraries`` as
    ##               an empty seq — see ``decodeInterfacePayload``.
    ## v8: adds ``ProjectInterface.standardBuildEligible``, a single byte
    ##     at the tail of the interface payload (outside the fingerprint).
    ##     v7 readers reject v8; v8 readers accept v7 by defaulting the
    ##     flag to false.
  InterfaceExtractionCacheRecordMagic =
    "reprobuild.interfaceExtractionCache.v2"
  ProviderFreshnessCacheRecordMagic =
    "reprobuild.providerFreshnessCache.v2"

var cachedNimCompilerPath = ""
var processWarmInterfaceMetadata =
  initTable[string, WarmInterfaceExtractionCacheRecord]()
var processWarmInterfaceArtifacts =
  initTable[string, WarmProjectInterfaceArtifact]()
var processWarmInterfaceStats: InterfaceArtifactWarmStats

proc consumeInterfaceArtifactWarmStats*(): InterfaceArtifactWarmStats =
  result = processWarmInterfaceStats
  processWarmInterfaceStats = InterfaceArtifactWarmStats()

proc writeByte(outp: var seq[byte]; value: byte) =
  outp.add(value)

proc readByte(bytes: openArray[byte]; pos: var int): byte =
  if pos >= bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated byte")
  result = bytes[pos]
  inc pos

proc writeStringSeq(outp: var seq[byte]; values: openArray[string]) =
  outp.writeU32Le(uint32(values.len))
  for value in values:
    outp.writeString(value)

proc readStringSeq(bytes: openArray[byte]; pos: var int): seq[string] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[string](count)
  for i in 0 ..< count:
    result[i] = readString(bytes, pos)

proc writeExecutionResult(outp: var seq[byte];
                          execution: ProviderCompileExecutionResult) =
  outp.writeU32Le(uint32(max(execution.exitCode, 0)))
  outp.writeString(execution.output)

proc readExecutionResult(bytes: openArray[byte]; pos: var int):
    ProviderCompileExecutionResult =
  ProviderCompileExecutionResult(
    exitCode: int(readU32Le(bytes, pos)),
    output: readString(bytes, pos))

proc writeDigest(outp: var seq[byte]; digest: ContentDigest) =
  outp.writeByte(byte(ord(digest.algorithm)))
  outp.writeByte(byte(ord(digest.domain)))
  outp.add(digest.bytes)

proc readDigest(bytes: openArray[byte]; pos: var int): ContentDigest =
  let algorithm = readByte(bytes, pos)
  let domain = readByte(bytes, pos)
  if algorithm > byte(ord(haXxh3_64)):
    raiseEnvelopeError(eeMalformed, "invalid hash algorithm")
  if domain > byte(ord(hdMetadataEnvelope)):
    raiseEnvelopeError(eeMalformed, "invalid hash domain")
  if pos + 32 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated content digest")
  result.algorithm = HashAlgorithm(algorithm)
  result.domain = HashDomain(domain)
  for i in 0 ..< 32:
    result.bytes[i] = bytes[pos + i]
  pos += 32

proc digestHexValue(digest: ContentDigest): DynamicValue =
  cborText(toHex(digest.bytes))

proc stableIdFromDigest(digest: ContentDigest): StableId =
  var raw: array[16, byte]
  for i in 0 ..< raw.len:
    raw[i] = digest.bytes[i]
  stableId(raw)

proc actionFingerprintFor*(declaredInputs, declaredOutputs,
                           compilerCommand: openArray[string];
                           interfaceFingerprint,
                           providerFingerprint: ContentDigest): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.providerCompile.v1")
  payload.writeStringSeq(declaredInputs)
  payload.writeStringSeq(declaredOutputs)
  payload.writeStringSeq(compilerCommand)
  payload.writeDigest(interfaceFingerprint)
  payload.writeDigest(providerFingerprint)
  blake3DomainDigest(payload, hdActionFingerprint)

proc providerCompileMetadata(
    declaredInputs, declaredOutputs, compilerCommand: openArray[string];
    interfaceFingerprint, providerFingerprint,
    actionFingerprint: ContentDigest): DynamicValue =
  var inputValues: seq[DynamicValue] = @[]
  for value in declaredInputs:
    inputValues.add(cborText(value))
  var outputValues: seq[DynamicValue] = @[]
  for value in declaredOutputs:
    outputValues.add(cborText(value))
  var commandValues: seq[DynamicValue] = @[]
  for value in compilerCommand:
    commandValues.add(cborText(value))
  cborMap([
    entry("kind", cborText("providerCompile")),
    entry("schema", cborUInt(1)),
    entry("declaredInputs", cborArray(inputValues)),
    entry("declaredOutputs", cborArray(outputValues)),
    entry("command", cborArray(commandValues)),
    entry("interfaceFingerprint", digestHexValue(interfaceFingerprint)),
    entry("providerFingerprint", digestHexValue(providerFingerprint)),
    entry("actionFingerprint", digestHexValue(actionFingerprint))
  ])

proc providerCompileEdge*(inputSources: openArray[string];
                          outputBinaryPath: string;
                          compilerCommand: openArray[string];
                          interfaceFingerprint,
                          providerFingerprint: ContentDigest;
                          workDir = getCurrentDir();
                          knownActionFingerprint = none(ContentDigest)):
    ProviderCompileEdge =
  let declaredInputs = @inputSources
  let declaredOutputs = @[outputBinaryPath]
  let fingerprint =
    if knownActionFingerprint.isSome:
      knownActionFingerprint.get()
    else:
      actionFingerprintFor(declaredInputs, declaredOutputs, compilerCommand,
        interfaceFingerprint, providerFingerprint)
  var processArgs: seq[string] = @[]
  for i in 1 ..< compilerCommand.len:
    processArgs.add(compilerCommand[i])
  let process =
    if compilerCommand.len == 0:
      directProcess(corepaths.normalizedPath("nim"), [],
          corepaths.normalizedPath(workDir))
    else:
      directProcess(
        corepaths.normalizedPath(compilerCommand[0]),
        processArgs,
        corepaths.normalizedPath(workDir))
  ProviderCompileEdge(
    actionSpec: ActionSpec(
      actionId: stableIdFromDigest(fingerprint),
      process: process,
      dependencyPolicy: automaticMonitorGatheringPolicy(),
      metadata: providerCompileMetadata(declaredInputs, declaredOutputs,
        compilerCommand, interfaceFingerprint, providerFingerprint,
        fingerprint)),
    declaredInputs: declaredInputs,
    declaredOutputs: declaredOutputs,
    actionFingerprint: fingerprint)

proc writeLocation(outp: var seq[byte]; loc: SourceLocation;
                   forFingerprint = false) =
  ## Serialises a ``SourceLocation``. When ``forFingerprint`` is true the
  ## location is normalised to a fixed sentinel (empty file, line 0) so the
  ## InterfaceFingerprint depends only on the SEMANTIC public contract and is
  ## invariant to WHERE a public decl is written. A private-impl edit that
  ## shifts line numbers (a longer driver body, a comment before a
  ## ``resourceType`` block) must not change the fingerprint. The artifact
  ## round-trip path (``encodeProjectInterfaceArtifact``) keeps
  ## ``forFingerprint = false`` so real locations are preserved for
  ## diagnostics.
  if forFingerprint:
    outp.writeString("")
    outp.writeU32Le(0'u32)
  else:
    outp.writeString(loc.file)
    outp.writeU32Le(uint32(max(loc.line, 0)))

proc readLocation(bytes: openArray[byte]; pos: var int): SourceLocation =
  SourceLocation(file: readString(bytes, pos), line: int(readU32Le(bytes, pos)))

proc writeParam(outp: var seq[byte]; param: InterfaceParam;
                forFingerprint = false) =
  outp.writeString(param.name)
  outp.writeString(param.nimType)
  outp.writeByte(byte(ord(param.kind)))
  outp.writeU32Le(uint32(param.position))
  outp.writeString(param.alias)
  outp.writeByte(if param.required: 1'u8 else: 0'u8)
  outp.writeLocation(param.location, forFingerprint)

proc readParam(bytes: openArray[byte]; pos: var int): InterfaceParam =
  result.name = readString(bytes, pos)
  result.nimType = readString(bytes, pos)
  let kind = readByte(bytes, pos)
  if kind > byte(ord(ipkFlag)):
    raiseEnvelopeError(eeMalformed, "invalid interface parameter kind")
  result.kind = InterfaceParamKind(kind)
  result.position = int(readU32Le(bytes, pos))
  result.alias = readString(bytes, pos)
  result.required = readByte(bytes, pos) == 1'u8
  result.location = readLocation(bytes, pos)

proc writeCommand(outp: var seq[byte]; cmd: InterfaceCommand;
                  forFingerprint = false) =
  outp.writeString(cmd.name)
  outp.writeString(cmd.providerEntrypointId)
  outp.writeLocation(cmd.location, forFingerprint)
  outp.writeU32Le(uint32(cmd.params.len))
  for param in cmd.params:
    outp.writeParam(param, forFingerprint)

proc readCommand(bytes: openArray[byte]; pos: var int): InterfaceCommand =
  result.name = readString(bytes, pos)
  result.providerEntrypointId = readString(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.params = newSeq[InterfaceParam](count)
  for i in 0 ..< count:
    result.params[i] = readParam(bytes, pos)

proc writeExecutable(outp: var seq[byte]; exe: InterfaceExecutable;
                     forFingerprint = false) =
  outp.writeString(exe.exportName)
  outp.writeString(exe.binaryName)
  outp.writeLocation(exe.location, forFingerprint)
  outp.writeU32Le(uint32(exe.commands.len))
  for cmd in exe.commands:
    outp.writeCommand(cmd, forFingerprint)

proc readExecutable(bytes: openArray[byte]; pos: var int): InterfaceExecutable =
  result.exportName = readString(bytes, pos)
  result.binaryName = readString(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.commands = newSeq[InterfaceCommand](count)
  for i in 0 ..< count:
    result.commands[i] = readCommand(bytes, pos)

proc writeLibrary(outp: var seq[byte]; lib: InterfaceLibrary;
                  version = EnvelopeVersion; forFingerprint = false) =
  outp.writeString(lib.name)
  outp.writeByte(byte(ord(lib.kind)))
  # v11 (SC-11): ``exportedPath`` appended AFTER ``kind`` and BEFORE
  # ``location``; v<11 readers never reach it (gated on ``version >= 11``).
  if version >= 11'u16:
    outp.writeString(lib.exportedPath)
  outp.writeLocation(lib.location, forFingerprint)

proc readLibrary(bytes: openArray[byte]; pos: var int;
                 version = EnvelopeVersion): InterfaceLibrary =
  result.name = readString(bytes, pos)
  let kind = readByte(bytes, pos)
  if kind > byte(ord(lkHeaderOnly)):
    raiseEnvelopeError(eeMalformed, "invalid interface library kind")
  result.kind = LibraryKind(kind)
  # v11 (SC-11): ``exportedPath``. v<11 envelopes have no such field — leave
  # it empty (the splice seam then applies the ``"src"`` convention default).
  if version >= 11'u16:
    result.exportedPath = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeResource(outp: var seq[byte]; res: InterfaceResource;
                   forFingerprint = false) =
  outp.writeString(res.typeId)
  outp.writeByte(byte(ord(res.determinism)))
  outp.writeString(res.entrypoints.identity)
  outp.writeString(res.entrypoints.digest)
  outp.writeString(res.entrypoints.observe)
  outp.writeString(res.entrypoints.plan)
  outp.writeString(res.entrypoints.apply)
  outp.writeLocation(res.location, forFingerprint)
  outp.writeU32Le(uint32(res.attributes.len))
  for attr in res.attributes:
    outp.writeString(attr.name)
    outp.writeString(attr.nimType)
    outp.writeLocation(attr.location, forFingerprint)

proc readResource(bytes: openArray[byte]; pos: var int): InterfaceResource =
  result.typeId = readString(bytes, pos)
  let determinism = readByte(bytes, pos)
  if determinism > byte(ord(irdVolatile)):
    raiseEnvelopeError(eeMalformed, "invalid interface resource determinism")
  result.determinism = InterfaceResourceDeterminism(determinism)
  result.entrypoints.identity = readString(bytes, pos)
  result.entrypoints.digest = readString(bytes, pos)
  result.entrypoints.observe = readString(bytes, pos)
  result.entrypoints.plan = readString(bytes, pos)
  result.entrypoints.apply = readString(bytes, pos)
  result.location = readLocation(bytes, pos)
  let attrCount = int(readU32Le(bytes, pos))
  result.attributes = newSeq[InterfaceResourceAttr](attrCount)
  for i in 0 ..< attrCount:
    result.attributes[i] = InterfaceResourceAttr(
      name: readString(bytes, pos),
      nimType: readString(bytes, pos),
      location: readLocation(bytes, pos))

proc writeNixProvisioning(outp: var seq[byte];
                          provisioning: InterfaceNixProvisioning;
                          version = EnvelopeVersion;
                          forFingerprint = false) =
  outp.writeString(provisioning.packageName)
  if version >= 13'u16:
    outp.writeString(provisioning.contributor)
  outp.writeString(provisioning.selector)
  outp.writeString(provisioning.executablePath)
  outp.writeString(provisioning.expressionFile)
  outp.writeString(provisioning.nixpkgsRef)
  outp.writeString(provisioning.nixpkgsRev)
  outp.writeString(provisioning.nixpkgsNarHash)
  outp.writeString(provisioning.packageId)
  outp.writeString(provisioning.lockIdentity)
  outp.writeLocation(provisioning.location, forFingerprint)

proc readNixProvisioning(bytes: openArray[byte]; pos: var int;
                         version: uint16): InterfaceNixProvisioning =
  result.packageName = readString(bytes, pos)
  if version >= 13'u16:
    result.contributor = readString(bytes, pos)
  result.selector = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  if version >= 3'u16:
    result.expressionFile = readString(bytes, pos)
  if version >= 7'u16:
    result.nixpkgsRef = readString(bytes, pos)
    result.nixpkgsRev = readString(bytes, pos)
    result.nixpkgsNarHash = readString(bytes, pos)
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeTarballProvisioning(outp: var seq[byte];
                              provisioning: InterfaceTarballProvisioning;
                              version = EnvelopeVersion;
                              forFingerprint = false) =
  outp.writeString(provisioning.packageName)
  if version >= 13'u16:
    outp.writeString(provisioning.contributor)
  outp.writeString(provisioning.url)
  outp.writeStringSeq(provisioning.mirrors)
  outp.writeString(provisioning.sha256)
  outp.writeString(provisioning.archiveType)
  outp.writeString(provisioning.executablePath)
  outp.writeU32Le(uint32(max(provisioning.stripComponents, 0)))
  outp.writeString(provisioning.packageId)
  outp.writeString(provisioning.lockIdentity)
  outp.writeString(provisioning.cpu)
  outp.writeString(provisioning.os)
  outp.writeLocation(provisioning.location, forFingerprint)

proc readTarballProvisioning(bytes: openArray[byte]; pos: var int;
                             version: uint16): InterfaceTarballProvisioning =
  result.packageName = readString(bytes, pos)
  if version >= 13'u16:
    result.contributor = readString(bytes, pos)
  result.url = readString(bytes, pos)
  result.mirrors = readStringSeq(bytes, pos)
  result.sha256 = readString(bytes, pos)
  result.archiveType = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  result.stripComponents = int(readU32Le(bytes, pos))
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  if version >= 10'u16:
    # v10: per-platform target fields. v9 payloads have no cpu/os —
    # the empty defaults are semantically "any", matching the
    # any-host behaviour the single-platform v9 schema implied.
    result.cpu = readString(bytes, pos)
    result.os = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeScoopProvisioning(outp: var seq[byte];
                            provisioning: InterfaceScoopProvisioning;
                            version = EnvelopeVersion;
                            forFingerprint = false) =
  outp.writeString(provisioning.packageName)
  if version >= 13'u16:
    outp.writeString(provisioning.contributor)
  outp.writeString(provisioning.bucket)
  outp.writeString(provisioning.app)
  outp.writeString(provisioning.version)
  outp.writeString(provisioning.preferredVersion)
  outp.writeString(provisioning.manifestChecksum)
  outp.writeString(provisioning.manifestUrl)
  outp.writeString(provisioning.executablePath)
  outp.writeByte(byte(ord(provisioning.requiresExecutionProfileChecksum)))
  outp.writeString(provisioning.packageId)
  outp.writeString(provisioning.lockIdentity)
  outp.writeLocation(provisioning.location, forFingerprint)

proc readScoopProvisioning(bytes: openArray[byte]; pos: var int;
                           version: uint16):
    InterfaceScoopProvisioning =
  result.packageName = readString(bytes, pos)
  if version >= 13'u16:
    result.contributor = readString(bytes, pos)
  result.bucket = readString(bytes, pos)
  result.app = readString(bytes, pos)
  result.version = readString(bytes, pos)
  result.preferredVersion = readString(bytes, pos)
  result.manifestChecksum = readString(bytes, pos)
  result.manifestUrl = readString(bytes, pos)
  result.executablePath = readString(bytes, pos)
  result.requiresExecutionProfileChecksum = readByte(bytes, pos) != 0
  result.packageId = readString(bytes, pos)
  result.lockIdentity = readString(bytes, pos)
  result.location = readLocation(bytes, pos)

proc writeToolUse(outp: var seq[byte]; useDef: InterfaceToolUse;
                  version = EnvelopeVersion;
                  forFingerprint = false) =
  outp.writeString(useDef.rawConstraint)
  outp.writeString(useDef.packageSelector)
  outp.writeString(useDef.executableName)
  outp.writeStringSeq(useDef.policyPath)
  let omitRealizations = forFingerprint and version >= 13'u16
  outp.writeU32Le(uint32(if omitRealizations: 0 else:
    useDef.nixProvisioning.len))
  if not omitRealizations:
    for provisioning in useDef.nixProvisioning:
      outp.writeNixProvisioning(provisioning, version, forFingerprint)
  outp.writeU32Le(uint32(if omitRealizations: 0 else:
    useDef.tarballProvisioning.len))
  if not omitRealizations:
    for provisioning in useDef.tarballProvisioning:
      outp.writeTarballProvisioning(provisioning, version, forFingerprint)
  outp.writeU32Le(uint32(if omitRealizations: 0 else:
    useDef.scoopProvisioning.len))
  if not omitRealizations:
    for provisioning in useDef.scoopProvisioning:
      outp.writeScoopProvisioning(provisioning, version, forFingerprint)
  outp.writeLocation(useDef.location, forFingerprint)

proc readToolUse(bytes: openArray[byte]; pos: var int;
                 version: uint16): InterfaceToolUse =
  result.rawConstraint = readString(bytes, pos)
  result.packageSelector = readString(bytes, pos)
  result.executableName = readString(bytes, pos)
  result.policyPath = readStringSeq(bytes, pos)
  if version >= 2'u16:
    let provisioningCount = int(readU32Le(bytes, pos))
    result.nixProvisioning = newSeq[InterfaceNixProvisioning](
      provisioningCount)
    for i in 0 ..< provisioningCount:
      result.nixProvisioning[i] = readNixProvisioning(bytes, pos, version)
  if version >= 4'u16:
    let tarballCount = int(readU32Le(bytes, pos))
    result.tarballProvisioning = newSeq[InterfaceTarballProvisioning](
      tarballCount)
    for i in 0 ..< tarballCount:
      result.tarballProvisioning[i] = readTarballProvisioning(bytes, pos,
        version)
  if version >= 5'u16:
    let scoopCount = int(readU32Le(bytes, pos))
    result.scoopProvisioning = newSeq[InterfaceScoopProvisioning](scoopCount)
    for i in 0 ..< scoopCount:
      result.scoopProvisioning[i] = readScoopProvisioning(bytes, pos, version)
  result.location = readLocation(bytes, pos)

proc writeProvisioningContribution(outp: var seq[byte];
    contribution: InterfaceProvisioningContribution;
    version = EnvelopeVersion; forFingerprint = false) =
  outp.writeString(contribution.targetPackage)
  outp.writeString(contribution.targetInterfaceFingerprint)
  outp.writeString(contribution.contributor)
  outp.writeByte(byte(ord(contribution.developInterface)))
  outp.writeLocation(contribution.location, forFingerprint)
  outp.writeU32Le(uint32(contribution.nixProvisioning.len))
  for provisioning in contribution.nixProvisioning:
    outp.writeNixProvisioning(provisioning, version, forFingerprint)
  outp.writeU32Le(uint32(contribution.tarballProvisioning.len))
  for provisioning in contribution.tarballProvisioning:
    outp.writeTarballProvisioning(provisioning, version, forFingerprint)
  outp.writeU32Le(uint32(contribution.scoopProvisioning.len))
  for provisioning in contribution.scoopProvisioning:
    outp.writeScoopProvisioning(provisioning, version, forFingerprint)

proc readProvisioningContribution(bytes: openArray[byte]; pos: var int;
    version: uint16): InterfaceProvisioningContribution =
  result.targetPackage = readString(bytes, pos)
  result.targetInterfaceFingerprint = readString(bytes, pos)
  result.contributor = readString(bytes, pos)
  result.developInterface = readByte(bytes, pos) != 0
  result.location = readLocation(bytes, pos)
  let nixCount = int(readU32Le(bytes, pos))
  result.nixProvisioning = newSeq[InterfaceNixProvisioning](nixCount)
  for i in 0 ..< nixCount:
    result.nixProvisioning[i] = readNixProvisioning(bytes, pos, version)
  let tarballCount = int(readU32Le(bytes, pos))
  result.tarballProvisioning =
    newSeq[InterfaceTarballProvisioning](tarballCount)
  for i in 0 ..< tarballCount:
    result.tarballProvisioning[i] =
      readTarballProvisioning(bytes, pos, version)
  let scoopCount = int(readU32Le(bytes, pos))
  result.scoopProvisioning = newSeq[InterfaceScoopProvisioning](scoopCount)
  for i in 0 ..< scoopCount:
    result.scoopProvisioning[i] =
      readScoopProvisioning(bytes, pos, version)

proc encodeInterfacePayload*(value: ProjectInterface;
                             version = EnvelopeVersion;
                             forFingerprint = false): seq[byte] =
  ## Encodes the fingerprinted portion of the project-interface payload.
  ##
  ## When ``forFingerprint`` is true every ``SourceLocation`` is normalised to
  ## a fixed sentinel (see ``writeLocation``) so the InterfaceFingerprint is
  ## invariant to WHERE the public surface is written — a private-impl edit
  ## that only shifts line numbers must not change the fingerprint. The
  ## on-disk artifact round-trip path leaves ``forFingerprint = false`` so real
  ## locations are preserved for diagnostics and decode.
  ## ``standardBuildEligible`` is deliberately NOT serialised here so it
  ## does NOT contribute to ``interfaceFingerprint``: the flag is a
  ## function of the DSL source's structural shape (presence of a
  ## ``build:`` block), and the source-file digest is already part of
  ## the interface-extraction cache key. Keeping the flag out of the
  ## interface fingerprint also means existing v<8 artifacts on disk
  ## continue to round-trip cleanly under the v8 codec — their stored
  ## fingerprints match what ``interfaceFingerprint`` recomputes.
  result.writeString(value.projectName)
  result.writeString(value.packageName)
  result.writeString(if forFingerprint and version >= 13'u16: "" else:
    value.defaultToolProvisioning)
  result.writeStringSeq(value.publicSignatureDependencies)
  result.writeLocation(value.location, forFingerprint)
  result.writeU32Le(uint32(value.publicExecutables.len))
  for exe in value.publicExecutables:
    result.writeExecutable(exe, forFingerprint)
  # v9: publicLibraries are encoded AFTER publicExecutables and BEFORE
  # toolUses so the field order matches the source-of-truth in the
  # ``ProjectInterface`` object literal above. v8 envelopes encode no
  # libraries block at all; ``decodeInterfacePayload`` gates this read
  # on ``version >= 9'u16`` so v8 on-disk artifacts load cleanly under
  # the v9 reader.
  if version >= 9'u16:
    result.writeU32Le(uint32(value.publicLibraries.len))
    for lib in value.publicLibraries:
      result.writeLibrary(lib, version, forFingerprint)
  # v12 (RP4): publicResources are encoded AFTER publicLibraries and
  # BEFORE toolUses so the field order matches the ``ProjectInterface``
  # object literal. v<12 envelopes encode no resources block at all;
  # ``decodeInterfacePayload`` gates this read on ``version >= 12'u16``
  # so v11 on-disk artifacts load cleanly under the v12 reader.
  if version >= 12'u16:
    result.writeU32Le(uint32(value.publicResources.len))
    for res in value.publicResources:
      result.writeResource(res, forFingerprint)
  result.writeU32Le(uint32(value.toolUses.len))
  for useDef in value.toolUses:
    result.writeToolUse(useDef, version, forFingerprint)
  if version >= 14'u16:
    result.writeU32Le(uint32(value.runtimeToolUses.len))
    for useDef in value.runtimeToolUses:
      result.writeToolUse(useDef, version, forFingerprint)
  if version >= 13'u16:
    result.writeU32Le(uint32(value.provisioningContributions.len))
    for contribution in value.provisioningContributions:
      result.writeProvisioningContribution(contribution, version,
        forFingerprint)

proc decodeInterfacePayload*(bytes: openArray[byte];
                             version = EnvelopeVersion): ProjectInterface =
  var pos = 0
  result.projectName = readString(bytes, pos)
  result.packageName = readString(bytes, pos)
  if version >= 6'u16:
    result.defaultToolProvisioning = readString(bytes, pos)
  result.publicSignatureDependencies = readStringSeq(bytes, pos)
  result.location = readLocation(bytes, pos)
  let count = int(readU32Le(bytes, pos))
  result.publicExecutables = newSeq[InterfaceExecutable](count)
  for i in 0 ..< count:
    result.publicExecutables[i] = readExecutable(bytes, pos)
  # v9 added publicLibraries between executables and toolUses. v<9
  # envelopes have no library block — leave the seq empty.
  if version >= 9'u16:
    let libCount = int(readU32Le(bytes, pos))
    result.publicLibraries = newSeq[InterfaceLibrary](libCount)
    for i in 0 ..< libCount:
      result.publicLibraries[i] = readLibrary(bytes, pos, version)
  # v12 added publicResources between libraries and toolUses. v<12
  # envelopes have no resource block — leave the seq empty.
  if version >= 12'u16:
    let resCount = int(readU32Le(bytes, pos))
    result.publicResources = newSeq[InterfaceResource](resCount)
    for i in 0 ..< resCount:
      result.publicResources[i] = readResource(bytes, pos)
  let useCount = int(readU32Le(bytes, pos))
  result.toolUses = newSeq[InterfaceToolUse](useCount)
  for i in 0 ..< useCount:
    result.toolUses[i] = readToolUse(bytes, pos, version)
  if version >= 14'u16:
    let runtimeUseCount = int(readU32Le(bytes, pos))
    result.runtimeToolUses = newSeq[InterfaceToolUse](runtimeUseCount)
    for i in 0 ..< runtimeUseCount:
      result.runtimeToolUses[i] = readToolUse(bytes, pos, version)
  if version >= 13'u16:
    let contributionCount = int(readU32Le(bytes, pos))
    result.provisioningContributions =
      newSeq[InterfaceProvisioningContribution](contributionCount)
    for i in 0 ..< contributionCount:
      result.provisioningContributions[i] =
        readProvisioningContribution(bytes, pos, version)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing interface payload bytes")

proc interfaceFingerprint(value: ProjectInterface;
                          version: uint16): ContentDigest =
  # TI3: the InterfaceFingerprint is a projection over the SEMANTIC public
  # contract only. ``forFingerprint = true`` normalises every SourceLocation
  # to a fixed sentinel so a private-impl edit that merely shifts line numbers
  # (a longer driver body, a comment before a ``resourceType`` block) leaves
  # the fingerprint UNCHANGED. The on-disk artifact serialisation
  # (``encodeProjectInterfaceArtifact``) keeps real locations for diagnostics.
  blake3DomainDigest(
    encodeInterfacePayload(value, version, forFingerprint = true),
    hdMetadataEnvelope)

proc interfaceFingerprint*(value: ProjectInterface): ContentDigest =
  interfaceFingerprint(value, EnvelopeVersion)

proc artifactFor*(value: ProjectInterface): ProjectInterfaceArtifact =
  ProjectInterfaceArtifact(
    projectInterface: value,
    interfaceFingerprint: interfaceFingerprint(value))

proc writeEnvelopeHeader(outp: var seq[byte]; kind: InterfaceEnvelopeKind;
                         payloadLength: int) =
  outp.add(EnvelopeMagic)
  outp.writeU16Le(EnvelopeVersion)
  outp.writeU16Le(uint16(ord(kind) + 101))
  outp.writeU32Le(uint32(payloadLength))

proc encodeProjectInterfaceArtifact*(artifact: ProjectInterfaceArtifact): seq[byte] =
  var payload = encodeInterfacePayload(artifact.projectInterface)
  payload.writeDigest(artifact.interfaceFingerprint)
  # v8: ``standardBuildEligible`` lives in the envelope tail, NOT in the
  # fingerprinted payload — see ``encodeInterfacePayload`` for why. v8
  # readers decoding a v7 envelope skip this byte and leave the field
  # as ``false`` (the conservative slow-path default), keeping existing
  # on-disk artifacts loadable without re-extraction.
  payload.writeByte(
    if artifact.projectInterface.standardBuildEligible: 1'u8 else: 0'u8)
  result.writeEnvelopeHeader(iekProjectInterface, payload.len)
  result.add(payload)

proc decodeProjectInterfaceArtifact*(bytes: openArray[
    byte]): ProjectInterfaceArtifact =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated interface artifact envelope")
  for i in 0 ..< 4:
    if bytes[i] != EnvelopeMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown interface artifact envelope magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version < 1'u16 or version > EnvelopeVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported interface envelope version")
  let typeId = readU16Le(bytes, pos)
  if typeId != uint16(ord(iekProjectInterface) + 101):
    raiseEnvelopeError(eeUnknownType, "not a project interface artifact")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "interface envelope payload length mismatch")
  # v8 envelopes carry an extra trailing byte for standardBuildEligible
  # past the 34-byte interface fingerprint; older envelopes do not.
  let standardBuildEligibleBytes = if version >= 8'u16: 1 else: 0
  let interfacePayloadLen = payloadLength - 34 - standardBuildEligibleBytes
  if interfacePayloadLen < 0:
    raiseEnvelopeError(eeMalformed, "truncated interface fingerprint")
  let interfacePayloadStart = pos
  result.projectInterface =
    decodeInterfacePayload(bytes.toOpenArray(pos, pos + interfacePayloadLen - 1),
      version)
  pos += interfacePayloadLen
  result.interfaceFingerprint = readDigest(bytes, pos)
  let semanticFingerprint = interfaceFingerprint(result.projectInterface, version)
  # TI3 made interface fingerprints location-independent without changing the
  # v12 wire version. Artifacts written before TI3 therefore carry the digest
  # of the exact (location-bearing) interface payload, while current artifacts
  # carry the normalized semantic digest. Accept either authentic shape so
  # existing caches remain readable; a digest matching neither still fails
  # closed. Hashing the original payload bytes (rather than a re-encoding) also
  # preserves compatibility with every older supported envelope version.
  let legacyWireFingerprint = blake3DomainDigest(
    bytes.toOpenArray(interfacePayloadStart,
      interfacePayloadStart + interfacePayloadLen - 1),
    hdMetadataEnvelope)
  if result.interfaceFingerprint != semanticFingerprint and
      result.interfaceFingerprint != legacyWireFingerprint:
    raiseEnvelopeError(eeMalformed, "interface fingerprint mismatch")
  if version >= 8'u16:
    result.projectInterface.standardBuildEligible =
      readByte(bytes, pos) != 0'u8

proc encodeProviderCompileArtifact*(artifact: ProviderCompileArtifact): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeStringSeq(artifact.inputSources)
  payload.writeString(artifact.outputBinaryPath)
  payload.writeStringSeq(artifact.compilerCommand)
  payload.writeString($artifact.compileEdge.actionSpec.process.cwd)
  payload.writeStringSeq(artifact.compileEdge.declaredInputs)
  payload.writeStringSeq(artifact.compileEdge.declaredOutputs)
  payload.writeDigest(artifact.compileEdge.actionFingerprint)
  payload.writeExecutionResult(artifact.executionResult)
  payload.writeDigest(artifact.interfaceFingerprint)
  payload.writeDigest(artifact.providerFingerprint)
  payload.writeDigest(artifact.outputBinaryFingerprint)
  result.writeEnvelopeHeader(iekProviderCompile, payload.len)
  result.add(payload)

proc decodeProviderCompileArtifact*(bytes: openArray[
    byte]): ProviderCompileArtifact =
  if bytes.len < 12:
    raiseEnvelopeError(eeMalformed, "truncated provider compile envelope")
  for i in 0 ..< 4:
    if bytes[i] != EnvelopeMagic[i]:
      raiseEnvelopeError(eeUnknownMagic, "unknown provider compile envelope magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != EnvelopeVersion:
    raiseEnvelopeError(eeUnsupportedVersion, "unsupported provider compile envelope version")
  let typeId = readU16Le(bytes, pos)
  if typeId != uint16(ord(iekProviderCompile) + 101):
    raiseEnvelopeError(eeUnknownType, "not a provider compile artifact")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raiseEnvelopeError(eeMalformed, "provider compile payload length mismatch")
  result.inputSources = readStringSeq(bytes, pos)
  result.outputBinaryPath = readString(bytes, pos)
  result.compilerCommand = readStringSeq(bytes, pos)
  let processCwd = readString(bytes, pos)
  let declaredInputs = readStringSeq(bytes, pos)
  let declaredOutputs = readStringSeq(bytes, pos)
  let actionFingerprint = readDigest(bytes, pos)
  result.executionResult = readExecutionResult(bytes, pos)
  result.interfaceFingerprint = readDigest(bytes, pos)
  result.providerFingerprint = readDigest(bytes, pos)
  result.outputBinaryFingerprint = readDigest(bytes, pos)
  result.compileEdge = providerCompileEdge(
    result.inputSources,
    result.outputBinaryPath,
    result.compilerCommand,
    result.interfaceFingerprint,
    result.providerFingerprint,
    workDir = processCwd,
    knownActionFingerprint = some(actionFingerprint))
  result.compileEdge.declaredInputs = declaredInputs
  result.compileEdge.declaredOutputs = declaredOutputs
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing provider compile payload bytes")

proc toByteString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc fromByteString(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc writeInterfaceArtifact*(path: string; artifact: ProjectInterfaceArtifact) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProjectInterfaceArtifact(artifact)))

proc readInterfaceArtifact*(path: string): ProjectInterfaceArtifact =
  decodeProjectInterfaceArtifact(fromByteString(readFile(extendedPath(path))))

proc writeProviderCompileArtifact*(path: string;
    artifact: ProviderCompileArtifact) =
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), toByteString(encodeProviderCompileArtifact(artifact)))

proc readProviderCompileArtifact*(path: string): ProviderCompileArtifact =
  decodeProviderCompileArtifact(fromByteString(readFile(extendedPath(path))))

proc writeFileStamp(outp: var seq[byte]; stamp: FileStamp) =
  outp.writeString(stamp.path)
  outp.writeByte(byte(ord(stamp.kind)))
  outp.writeU64Le(stamp.sizeBytes)
  outp.writeU64Le(stamp.mtimeNs)

proc readFileStamp(bytes: openArray[byte]; pos: var int): FileStamp =
  result.path = readString(bytes, pos)
  let kind = readByte(bytes, pos)
  if kind > byte(ord(fskOther)):
    raiseEnvelopeError(eeMalformed, "invalid file stamp kind")
  result.kind = FileStampKind(kind)
  result.sizeBytes = readU64Le(bytes, pos)
  result.mtimeNs = readU64Le(bytes, pos)

proc writeFileStamps(outp: var seq[byte]; stamps: openArray[FileStamp]) =
  outp.writeU32Le(uint32(stamps.len))
  for stamp in stamps:
    outp.writeFileStamp(stamp)

proc readFileStamps(bytes: openArray[byte]; pos: var int): seq[FileStamp] =
  let count = int(readU32Le(bytes, pos))
  result = newSeq[FileStamp](count)
  for i in 0 ..< count:
    result[i] = readFileStamp(bytes, pos)

proc writeInterfaceContext(outp: var seq[byte];
                           context: InterfaceExtractionContext) =
  outp.writeString(context.modulePath)
  outp.writeString(context.workDir)
  outp.writeString(context.nimCompiler)
  outp.writeStringSeq(context.libPathFlags)
  outp.writeString(context.reproLibFingerprint)
  outp.writeStringSeq(context.sources)

proc readInterfaceContext(bytes: openArray[byte]; pos: var int):
    InterfaceExtractionContext =
  result.modulePath = readString(bytes, pos)
  result.workDir = readString(bytes, pos)
  result.nimCompiler = readString(bytes, pos)
  result.libPathFlags = readStringSeq(bytes, pos)
  result.reproLibFingerprint = readString(bytes, pos)
  result.sources = readStringSeq(bytes, pos)

proc encodeInterfaceExtractionCacheRecord(
    record: InterfaceExtractionCacheRecord): seq[byte] =
  result.writeString(InterfaceExtractionCacheRecordMagic)
  result.writeInterfaceContext(record.context)
  result.writeFileStamps(record.sourceStamps)
  result.writeFileStamps(record.reproLibStamps)
  result.writeDigest(record.inputFingerprint)

proc decodeInterfaceExtractionCacheRecord(bytes: openArray[byte]):
    InterfaceExtractionCacheRecord =
  var pos = 0
  let magic = readString(bytes, pos)
  if magic != InterfaceExtractionCacheRecordMagic:
    raiseEnvelopeError(eeUnknownType, "not an interface extraction cache record")
  result.context = readInterfaceContext(bytes, pos)
  result.sourceStamps = readFileStamps(bytes, pos)
  result.reproLibStamps = readFileStamps(bytes, pos)
  result.inputFingerprint = readDigest(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed,
      "trailing interface extraction cache bytes")

proc encodeProviderFreshnessCacheRecord(
    record: ProviderFreshnessCacheRecord): seq[byte] =
  result.writeString(ProviderFreshnessCacheRecordMagic)
  result.writeString(record.modulePath)
  result.writeString(record.workDir)
  result.writeString(record.outputBinaryPath)
  result.writeFileStamps(record.sourceStamps)
  result.writeFileStamps(record.reproLibStamps)
  result.writeFileStamp(record.outputBinaryStamp)
  result.writeDigest(record.interfaceFingerprint)
  result.writeDigest(record.providerFingerprint)
  result.writeString(record.reproLibFingerprint)
  result.writeDigest(record.outputBinaryFingerprint)

proc decodeProviderFreshnessCacheRecord(bytes: openArray[byte]):
    ProviderFreshnessCacheRecord =
  var pos = 0
  let magic = readString(bytes, pos)
  if magic != ProviderFreshnessCacheRecordMagic:
    raiseEnvelopeError(eeUnknownType, "not a provider freshness cache record")
  result.modulePath = readString(bytes, pos)
  result.workDir = readString(bytes, pos)
  result.outputBinaryPath = readString(bytes, pos)
  result.sourceStamps = readFileStamps(bytes, pos)
  result.reproLibStamps = readFileStamps(bytes, pos)
  result.outputBinaryStamp = readFileStamp(bytes, pos)
  result.interfaceFingerprint = readDigest(bytes, pos)
  result.providerFingerprint = readDigest(bytes, pos)
  result.reproLibFingerprint = readString(bytes, pos)
  result.outputBinaryFingerprint = readDigest(bytes, pos)
  if pos != bytes.len:
    raiseEnvelopeError(eeMalformed, "trailing provider freshness cache bytes")

proc toInterfaceParam(param: CliParamDef): InterfaceParam =
  InterfaceParam(
    name: param.name,
    nimType: param.nimType,
    kind: if param.kind == cpkPositional: ipkPositional else: ipkFlag,
    position: param.position,
    alias: param.alias,
    required: param.required,
    location: SourceLocation(file: param.sourceFile, line: param.sourceLine))

proc toInterfaceNixProvisioning(packageName: string;
                                provisioning: NixPackageProvisioningDef;
                                contributor = ""):
    InterfaceNixProvisioning =
  InterfaceNixProvisioning(
    packageName: packageName,
    contributor: contributor,
    selector: provisioning.selector,
    executablePath: provisioning.executablePath,
    expressionFile: provisioning.expressionFile,
    nixpkgsRef: provisioning.nixpkgsRef,
    nixpkgsRev: provisioning.nixpkgsRev,
    nixpkgsNarHash: provisioning.nixpkgsNarHash,
    packageId: provisioning.packageId,
    lockIdentity: provisioning.lockIdentity,
    location: SourceLocation(file: provisioning.sourceFile,
      line: provisioning.sourceLine))

proc toInterfaceTarballProvisioning(packageName: string;
                                    provisioning: TarballProvisioningDef;
                                    contributor = ""):
    InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(
    packageName: packageName,
    contributor: contributor,
    url: provisioning.url,
    mirrors: provisioning.mirrors,
    sha256: provisioning.sha256,
    archiveType: provisioning.archiveType,
    executablePath: provisioning.executablePath,
    stripComponents: provisioning.stripComponents,
    packageId: provisioning.packageId,
    lockIdentity: provisioning.lockIdentity,
    cpu: provisioning.cpu,
    os: provisioning.os,
    location: SourceLocation(file: provisioning.sourceFile,
      line: provisioning.sourceLine))

proc toInterfaceScoopProvisioning(packageName: string;
                                  provisioning: ScoopProvisioningDef;
                                  contributor = ""):
    InterfaceScoopProvisioning =
  InterfaceScoopProvisioning(
    packageName: packageName,
    contributor: contributor,
    bucket: provisioning.bucket,
    app: provisioning.app,
    version: provisioning.version,
    preferredVersion: provisioning.preferredVersion,
    manifestChecksum: provisioning.manifestChecksum,
    manifestUrl: provisioning.manifestUrl,
    executablePath: provisioning.executablePath,
    requiresExecutionProfileChecksum:
      provisioning.requiresExecutionProfileChecksum,
    packageId: provisioning.packageId,
    lockIdentity: provisioning.lockIdentity,
    location: SourceLocation(file: provisioning.sourceFile,
      line: provisioning.sourceLine))

proc toInterfaceToolUse(useDef: PackageUseDef;
                        packages: openArray[PackageDef]): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: useDef.rawConstraint,
    packageSelector: useDef.packageSelector,
    executableName: useDef.executableName,
    policyPath: useDef.policyPath,
    location: SourceLocation(file: useDef.sourceFile, line: useDef.sourceLine))
  for pkg in packages:
    if pkg.packageName == useDef.packageSelector:
      for provisioning in pkg.nixProvisioning:
        result.nixProvisioning.add(toInterfaceNixProvisioning(pkg.packageName,
          provisioning))
      for provisioning in pkg.tarballProvisioning:
        result.tarballProvisioning.add(toInterfaceTarballProvisioning(
          pkg.packageName, provisioning))
      for provisioning in pkg.scoopProvisioning:
        result.scoopProvisioning.add(toInterfaceScoopProvisioning(
          pkg.packageName, provisioning))
      # When the package declares an ``executable`` whose exportName
      # matches the use selector and renames the binary via ``name:``
      # (e.g. ``package foundry: executable foundry: name: "forge"``),
      # propagate that binary basename as the use's executableName so
      # path-mode tool resolution probes for ``forge[.exe]`` instead of
      # the non-existent ``foundry[.exe]`` derived from the selector.
      # The default executableName (= selector) is preserved when no
      # such executable is declared, keeping existing single-binary
      # packages (cargo, gcc, nim, ...) unchanged.
      for exe in pkg.executables:
        if exe.exportName == useDef.executableName and
            exe.binaryName.len > 0 and
            exe.binaryName != useDef.executableName:
          result.executableName = exe.binaryName
          break

proc normalizedInterfaceFingerprint(value: string): string =
  result = value.strip().toLowerAscii()
  for prefix in ["blake3-256:", "blake3:", "b3:"]:
    if result.startsWith(prefix):
      return result[prefix.len .. ^1]

proc toInterfaceProvisioningContribution(contribution:
    ProvisioningContributionDef; targetFingerprint: string):
    InterfaceProvisioningContribution =
  result = InterfaceProvisioningContribution(
    targetPackage: contribution.targetPackage,
    targetInterfaceFingerprint: targetFingerprint,
    contributor: contribution.contributor,
    developInterface: contribution.developInterface,
    location: SourceLocation(file: contribution.sourceFile,
      line: contribution.sourceLine))
  for provisioning in contribution.nixProvisioning:
    result.nixProvisioning.add(toInterfaceNixProvisioning(
      contribution.targetPackage, provisioning, contribution.contributor))
  for provisioning in contribution.tarballProvisioning:
    result.tarballProvisioning.add(toInterfaceTarballProvisioning(
      contribution.targetPackage, provisioning, contribution.contributor))
  for provisioning in contribution.scoopProvisioning:
    result.scoopProvisioning.add(toInterfaceScoopProvisioning(
      contribution.targetPackage, provisioning, contribution.contributor))

proc toProjectInterface*(pkg: PackageDef;
                         packages: openArray[PackageDef] = [];
                         contributions:
                           openArray[ProvisioningContributionDef] = []):
    ProjectInterface =
  result.projectName = pkg.packageName
  result.packageName = pkg.packageName
  result.defaultToolProvisioning = pkg.defaultToolProvisioning
  result.publicSignatureDependencies = pkg.publicSignatureDependencies
  result.location = SourceLocation(file: pkg.sourceFile, line: pkg.sourceLine)
  # NLF-M8 — `PackageDef.toolUses` is no longer the concatenation of the
  # three dependency lists (`allToolUses` is), so the union is taken HERE.
  # `ProjectInterface.toolUses` keeps exactly the content it had, byte for
  # byte and in the same order, because the ~14 tool-PATH sites downstream
  # read it and this change is not theirs.
  for useDef in pkg.allToolUses():
    result.toolUses.add(toInterfaceToolUse(useDef, packages))
  for useDef in pkg.runtimeDeps:
    result.runtimeToolUses.add(toInterfaceToolUse(useDef, packages))
  for exe in pkg.executables:
    var normalizedExe = InterfaceExecutable(
      exportName: exe.exportName,
      binaryName: exe.binaryName,
      location: SourceLocation(file: exe.sourceFile, line: exe.sourceLine))
    for cmd in exe.commands:
      var normalizedCmd = InterfaceCommand(
        name: cmd.name,
        providerEntrypointId: cmd.providerEntrypointId,
        location: SourceLocation(file: cmd.sourceFile, line: cmd.sourceLine))
      for param in cmd.params:
        normalizedCmd.params.add(toInterfaceParam(param))
      normalizedExe.commands.add(normalizedCmd)
    result.publicExecutables.add(normalizedExe)
  for lib in pkg.libraries:
    result.publicLibraries.add(InterfaceLibrary(
      name: lib.name,
      kind: lib.kind,
      exportedPath: lib.exportedPath,
      location: SourceLocation(file: lib.sourceFile, line: lib.sourceLine)))
  # RP4 (Provider-Runtime-Protocol-v1 §5): fold every ``resourceType``
  # declaration into the interface. Resource types are declared at
  # module scope (like ``registerResourceProvider``), not lexically
  # inside a ``package`` block, so they live in a module-global registry
  # rather than on ``PackageDef``; the extractor attributes the whole
  # set to the (single) project being lifted. ``determinismOrd`` maps
  # ordinal-for-ordinal onto ``InterfaceResourceDeterminism`` (both
  # enums share the rdStrong=0 … rdVolatile=3 ordering).
  for rt in registeredResourceTypeInterfaces():
    var res = InterfaceResource(
      typeId: rt.typeId,
      determinism: InterfaceResourceDeterminism(rt.determinismOrd),
      entrypoints: InterfaceResourceEntrypoints(
        identity: rt.identityEntrypoint,
        digest: rt.digestEntrypoint,
        observe: rt.observeEntrypoint,
        plan: rt.planEntrypoint,
        apply: rt.applyEntrypoint),
      location: SourceLocation(file: rt.sourceFile, line: rt.sourceLine))
    for attr in rt.attributes:
      res.attributes.add(InterfaceResourceAttr(
        name: attr.name,
        nimType: attr.nimType,
        location: SourceLocation(file: attr.sourceFile,
          line: attr.sourceLine)))
    result.publicResources.add(res)

  if contributions.len > 0:
    for contribution in contributions:
      var targetFound = false
      var targetFingerprint = ""
      var activeFingerprints: seq[string] = @[]
      let pinnedFingerprint = normalizedInterfaceFingerprint(
        contribution.targetInterfaceFingerprint)
      for targetPkg in packages:
        if targetPkg.packageName == contribution.targetPackage:
          targetFound = true
          let targetInterface = toProjectInterface(targetPkg, packages, [])
          let candidateFingerprint = toHex(
            interfaceFingerprint(targetInterface).bytes).toLowerAscii()
          if activeFingerprints.find(candidateFingerprint) < 0:
            activeFingerprints.add(candidateFingerprint)
          if contribution.developInterface:
            if targetFingerprint.len == 0:
              targetFingerprint = candidateFingerprint
          elif candidateFingerprint == pinnedFingerprint:
            targetFingerprint = candidateFingerprint
      if not targetFound:
        # A thin catalog may be inspected before its target repository is
        # materialized. Preserve the pinned identity; the consuming resolver
        # validates it once the canonical package interface is present.
        targetFingerprint = pinnedFingerprint
      elif contribution.developInterface and activeFingerprints.len > 1:
        raise newException(ValueError,
          "ambiguous package interface for development contribution \"" &
          contribution.targetPackage & "\" from \"" &
          contribution.contributor & "\": active fingerprints " &
          activeFingerprints.join(", ") &
          "; publish an explicit interfaceFingerprint")
      elif not contribution.developInterface and targetFingerprint.len == 0:
        raise newException(ValueError,
          "provisioning contribution interface mismatch for package \"" &
          contribution.targetPackage & "\" from \"" &
          contribution.contributor & "\": expected " &
          contribution.targetInterfaceFingerprint & ", active " &
          activeFingerprints.join(", "))
      let projected = toInterfaceProvisioningContribution(contribution,
        targetFingerprint)
      result.provisioningContributions.add(projected)
      for useDef in result.toolUses.mitems:
        if useDef.packageSelector != contribution.targetPackage:
          continue
        useDef.nixProvisioning.add(projected.nixProvisioning)
        useDef.tarballProvisioning.add(projected.tarballProvisioning)
        useDef.scoopProvisioning.add(projected.scoopProvisioning)

proc canonicalPackageInterfaceFingerprint*(pkg: PackageDef;
    packages: openArray[PackageDef] = []): string =
  toHex(interfaceFingerprint(toProjectInterface(pkg, packages, [])).bytes).
    toLowerAscii()

proc sameSourceFile(a, b: string): bool =
  if a.len == 0 or b.len == 0:
    return false
  try:
    if sameFile(a, b):
      return true
  except CatchableError:
    discard
  let rawA = a.replace('\\', '/')
  let rawB = b.replace('\\', '/')
  if rawA == rawB or rawA.endsWith("/" & rawB) or rawB.endsWith("/" & rawA):
    return true
  try:
    os.normalizedPath(expandFilename(a)) ==
      os.normalizedPath(expandFilename(b))
  except CatchableError:
    a == b

proc sourceFileWithinProject(sourceFile, rootSourceFile: string): bool =
  ## Package modules imported from below the root recipe are part of the same
  ## project interface. Imported stdlib and sibling-repository packages are
  ## deliberately excluded.
  if sourceFile.len == 0 or rootSourceFile.len == 0:
    return false
  try:
    let projectRoot = os.normalizedPath(absolutePath(
      parentDir(rootSourceFile))).replace('\\', '/')
    let candidate = os.normalizedPath(
      absolutePath(sourceFile)).replace('\\', '/')
    let rootPrefix = projectRoot.strip(
      leading = false, trailing = true, chars = {'/'}) & "/"
    when defined(windows):
      candidate.toLowerAscii().startsWith(rootPrefix.toLowerAscii())
    else:
      candidate.startsWith(rootPrefix)
  except CatchableError:
    false

const
  RegisteredStandardConventionToolchains* = ["nim", "rust", "rustc", "cargo",
    "go",
    "python3", "python", "uv",
    "node", "typescript", "tsx", "swc", "esbuild",
    "gcc", "clang", "make", "ar", "autoconf", "automake",
    "cmake", "ninja", "meson",
    "java", "jdk", "javac", "mvn", "maven",
    "gradle", "kotlin",
    "dotnet", "dotnet-sdk", "csharp",
    "swift", "swiftc", "swiftpm",
    "gfortran", "fortran",
    "zig",
    "d", "dmd", "ldc2", "gdc",
    "ada", "gnat", "gnatmake",
    "pascal", "fpc", "freepascal",
    "crystal", "shards",
    "erlang", "erl", "rebar3",
    "elixir", "mix",
    "ocaml", "ocamlc", "ocamlopt", "ocamlfind", "dune",
    "haskell", "ghc", "cabal", "cabal-install",
    "ruby", "bundler",
    "php", "composer"]
    ## Toolchain names whose presence in ``uses:`` makes a package
    ## ``executable``/``library`` declaration safe to route through the
    ## Tier 2b standard provider. This list MUST stay in sync with the
    ## conventions registered in
    ## ``apps/repro-standard-provider/repro_standard_provider.nim``.
    ## ``"rust"`` and ``"cargo"`` both route to the same Rust convention
    ## plugin (M4) — the Rust convention's ``recognize`` matches either
    ## token in ``uses:``. ``"go"`` (M5) routes to the Go convention plugin
    ## which keys on the ``go.mod`` + ``main.go`` layout. ``"python3"`` /
    ## ``"python"`` / ``"uv"`` (M15) route to the Python convention plugin
    ## which keys on ``pyproject.toml`` + a recognised PEP 517 build
    ## backend (hatchling / flit_core / setuptools). ``"gcc"`` / ``"clang"``
    ## / ``"make"`` / ``"ar"`` (M17) route to the C/C++ Make convention;
    ## ``"autoconf"`` / ``"automake"`` (M17) route to the C/C++ Autotools
    ## convention which keys on ``configure.ac`` + ``Makefile.am`` at the
    ## project root. ``"cmake"`` (M38) routes to the C/C++ CMake (Tier 2b)
    ## convention which keys on ``CMakeLists.txt`` at the project root.
    ## ``"meson"`` (M39) routes to the C/C++ Meson (Tier 2b) convention
    ## which keys on ``meson.build`` at the project root.
    ## ``"java"`` / ``"jdk"`` / ``"javac"`` / ``"mvn"`` / ``"maven"`` (M40)
    ## route to the Java + Maven (Tier 2b) convention which keys on
    ## ``pom.xml`` at the project root; recognition additionally requires
    ## both halves (a JDK token AND a Maven token) in ``uses:``.
    ## ``"gradle"`` / ``"kotlin"`` (M41) route to the Kotlin + Gradle
    ## (Tier 2b) convention which keys on ``build.gradle.kts`` (or
    ## ``build.gradle``) at the project root; recognition additionally
    ## requires both halves (a JDK token AND a Gradle/Kotlin token) in
    ## ``uses:`` AND the absence of ``pom.xml`` at the root (defers to
    ## the M40 Maven convention when both manifests coexist).
    ## ``"dotnet"`` / ``"dotnet-sdk"`` / ``"csharp"`` (M42) route to the
    ## C# + .NET (Tier 2b) convention which keys on a single ``*.csproj``
    ## at the project root + a ``packages.lock.json`` (HARD precondition).
    ## ``"swift"`` / ``"swiftc"`` / ``"swiftpm"`` (M43) route to the
    ## Swift + SwiftPM (Tier 2b) convention which keys on ``Package.swift``
    ## at the project root.
    ## ``"ocaml"`` / ``"ocamlc"`` / ``"ocamlopt"`` / ``"ocamlfind"`` /
    ## ``"dune"`` (M46) route to the OCaml + Dune (Tier 2b) convention
    ## which keys on ``dune-project`` at the project root; recognition
    ## additionally requires BOTH halves (an OCaml token AND ``dune``)
    ## in ``uses:`` — mirrors M40 java-maven's strict "both required"
    ## pattern because Dune isn't a built-in part of the OCaml
    ## distribution (it's a separate ``opam install dune``).
    ## Mismatches break in the engine-side fall-back path:
    ## the engine will dispatch to the provider, the provider will reply
    ## "no convention matched", and the build fails loudly — preferable to
    ## silently routing through the slow path when the user expects the
    ## fast path.

proc usesIncludesRegisteredConvention(sourceFile: string): bool =
  ## Heuristic line scan of ``reprobuild.nim`` for any toolchain in
  ## ``RegisteredStandardConventionToolchains`` appearing inside a
  ## ``uses:`` block. Mirrors the line-scan in
  ## ``libs/repro_standard_provider/src/repro_standard_provider/project_intro.nim``
  ## (no DSL evaluator), kept here rather than imported because
  ## ``repro_interface_artifacts`` is upstream of ``repro_standard_provider``
  ## in the library dep graph. Conservative: returns ``false`` on any
  ## read error or malformed block.
  if sourceFile.len == 0:
    return false
  var content: string
  try:
    content = readFile(extendedPath(sourceFile))
  except CatchableError:
    return false
  var inBlock = false
  for rawLine in content.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    var payload = ""
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        payload = stripped
    if payload.len == 0 and stripped.startsWith("uses:"):
      let p = stripped[5 .. ^1].strip()
      if p.len == 0:
        inBlock = true
      else:
        payload = p
    if payload.len == 0:
      continue
    var clean = payload
    if clean.startsWith("["):
      clean = clean[1 .. ^1]
    if clean.endsWith("]"):
      clean = clean[0 ..< ^1]
    for raw in clean.split({',', ' ', '\t'}):
      let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
      if entry.len == 0:
        continue
      let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
      for toolchain in RegisteredStandardConventionToolchains:
        if firstToken == toolchain:
          return true
  false

proc detectStandardBuildEligible(sourceFile: string;
                                  pkg: PackageDef): bool =
  ## A package is eligible for the Tier 2b ``repro-standard-provider``
  ## fast path when the DSL body declares NO ``build:`` block AND one
  ## of two things is true:
  ##   1. zero ``executable`` / ``library`` members (pure metadata or
  ##      "no-build" package — let the standard provider decide what to
  ##      do; missing match still fails loudly), OR
  ##   2. ``uses:`` includes a toolchain name listed in
  ##      ``RegisteredStandardConventionToolchains`` (i.e. the standard
  ##      provider ships a convention plugin for it).
  ##
  ## Conservatively excluding executable-bearing packages whose ``uses:``
  ## doesn't reference any registered convention keeps tool-wrapper
  ## packages (``executable foo`` with no ``build:``, expecting the slow
  ## path's typed-tool resolution to materialise a launcher) on the
  ## traditional path — bypassing them through the standard provider
  ## would mean every such package hits a "no convention matched" error.
  ##
  ## The ``build:`` check is a heuristic line-scan of the source file,
  ## mirroring ``moduleHasBuildBlock`` in ``repro_cli_support``: a
  ## stripped-equal-to-``build:`` line under either the top-level
  ## package body or a nested ``executable`` block disqualifies. Empty
  ## or unreadable source file → not eligible (conservative default).
  if sourceFile.len == 0:
    return false
  var content: string
  try:
    content = readFile(extendedPath(sourceFile))
  except CatchableError:
    return false
  for line in content.splitLines:
    if line.strip() == "build:":
      return false
  if pkg.executables.len == 0 and pkg.libraries.len == 0:
    return true
  # Library-only packages (no executable members) need the same
  # registered-convention gate as executable-bearing packages: routing a
  # ``library foo`` declaration through the standard provider only makes
  # sense when the convention plugin in question knows how to emit a
  # library link action. The Nim convention's M12 ``emitFragment`` covers
  # ``lkStatic``/``lkShared``/``lkBoth``/``lkHeaderOnly`` — see
  # ``conventions/nim.nim``.
  usesIncludesRegisteredConvention(sourceFile)

proc mergeProjectInterfaces(matches: openArray[PackageDef];
                            packages: openArray[PackageDef];
                            contributions:
                              openArray[ProvisioningContributionDef] = []):
    ProjectInterface =
  ## Combine the ``ProjectInterface`` projections of every package
  ## declared in the same Nim project file into a single envelope.
  ##
  ## Background: the on-disk interface artifact carries ONE
  ## ``ProjectInterface`` per project file (one ``ProjectInterfaceArtifact``
  ## per ``repro.nim``). When multiple ``package`` blocks share a file —
  ## the "one workspace, many packages, single file" Mode 3 shape —
  ## downstream consumers (the engine, ``repro-standard-provider``, the
  ## CMake generator) still expect a single envelope. We project the
  ## multi-package shape into the single-envelope shape by:
  ##
  ##   * keeping the FIRST package's ``projectName`` /
  ##     ``packageName`` / ``defaultToolProvisioning`` /
  ##     ``location`` as the "root" — preserving the
  ##     single-package shape byte-for-byte when ``matches.len == 1``;
  ##   * concatenating ``publicExecutables`` and ``publicLibraries``
  ##     across every package in source order (the DSL itself
  ##     guarantees member-name uniqueness within a package, and
  ##     multi-package files almost always partition members one per
  ##     package, so duplicates are not expected here);
  ##   * retaining each module-global ``publicResources`` contract once,
  ##     deduplicated by ``typeId`` (each package projection sees the same
  ##     resource registry);
  ##   * deduplicating ``toolUses`` by
  ##     ``(packageSelector, executableName)`` so a constraint listed in
  ##     two ``uses:`` blocks (typical for shared toolchains like
  ##     ``"nim >=2.2 <3.0"``) doesn't surface twice;
  ##   * unioning ``publicSignatureDependencies``.
  ##
  ## The per-target ``packageName`` distinction is preserved at the
  ## DSL level (each ``InterfaceExecutable.binaryName`` /
  ## ``InterfaceLibrary.name`` plus its source location still maps
  ## back to its owning package); the merged envelope just doesn't
  ## carry the per-target package label in the v9 wire format. The
  ## scanner, ``repro show-conventions``, ``repro deps refresh``, and
  ## the multi-package unit tests all consult ``registeredPackages()``
  ## directly so they retain full per-package attribution.
  result.projectName = matches[0].packageName
  result.packageName = matches[0].packageName
  result.defaultToolProvisioning = matches[0].defaultToolProvisioning
  result.location = SourceLocation(
    file: matches[0].sourceFile,
    line: matches[0].sourceLine)
  var seenToolUses: seq[string] = @[]
  var seenRuntimeToolUses: seq[string] = @[]
  var seenSigDeps: seq[string] = @[]
  var seenResourceTypeIds: seq[string] = @[]
  for pkg in matches:
    let projection = toProjectInterface(pkg, packages, contributions)
    if result.provisioningContributions.len == 0:
      result.provisioningContributions = projection.provisioningContributions
    for exe in projection.publicExecutables:
      result.publicExecutables.add(exe)
    for lib in projection.publicLibraries:
      result.publicLibraries.add(lib)
    for resource in projection.publicResources:
      if seenResourceTypeIds.find(resource.typeId) >= 0:
        continue
      seenResourceTypeIds.add(resource.typeId)
      result.publicResources.add(resource)
    for use in projection.toolUses:
      let key = use.packageSelector & "\x1f" & use.executableName
      if seenToolUses.find(key) >= 0:
        continue
      seenToolUses.add(key)
      result.toolUses.add(use)
    for use in projection.runtimeToolUses:
      let key = use.packageSelector & "\x1f" & use.executableName
      if seenRuntimeToolUses.find(key) >= 0:
        continue
      seenRuntimeToolUses.add(key)
      result.runtimeToolUses.add(use)
    for dep in projection.publicSignatureDependencies:
      if seenSigDeps.find(dep) >= 0:
        continue
      seenSigDeps.add(dep)
      result.publicSignatureDependencies.add(dep)
    # ``defaultToolProvisioning`` resolution: the first non-empty wins.
    # An explicit value on a later package overrides a default-empty
    # earlier one, matching the "first explicit declaration in source
    # order" rule the spec hints at.
    if result.defaultToolProvisioning.len == 0 and
        pkg.defaultToolProvisioning.len > 0:
      result.defaultToolProvisioning = pkg.defaultToolProvisioning

proc artifactFromRegisteredDsl*(rootSourceFile = ""): ProjectInterfaceArtifact =
  let packages = registeredPackages()
  let contributions = registeredProvisioningContributions()
  if rootSourceFile.len > 0:
    var rootPackages: seq[PackageDef] = @[]
    var localPackageModules: seq[PackageDef] = @[]
    for pkg in packages:
      if sameSourceFile(pkg.sourceFile, rootSourceFile):
        rootPackages.add(pkg)
      elif sourceFileWithinProject(pkg.sourceFile, rootSourceFile):
        localPackageModules.add(pkg)
    let matches =
      if rootPackages.len > 0: rootPackages & localPackageModules
      else: newSeq[PackageDef]()
    if matches.len == 1:
      var pi = toProjectInterface(matches[0], packages, contributions)
      pi.standardBuildEligible =
        detectStandardBuildEligible(rootSourceFile, matches[0])
      return artifactFor(pi)
    if matches.len > 1:
      # Root packages own the project identity and default provisioning;
      # imported local modules contribute public members and tool requirements.
      var pi = mergeProjectInterfaces(matches, packages, contributions)
      var allEligible = true
      for pkg in rootPackages:
        if not detectStandardBuildEligible(rootSourceFile, pkg):
          allEligible = false
          break
      pi.standardBuildEligible = allEligible
      return artifactFor(pi)
  if packages.len != 1:
    # Same multi-package fallback as the rootSourceFile branch above,
    # for callers that don't pass a root hint. The merge preserves the
    # ``packages.len == 1`` shape exactly (single-element ``matches`` →
    # ``mergeProjectInterfaces`` reproduces the legacy
    # ``toProjectInterface`` output), so this branch only kicks in when
    # two or more packages were registered without an explicit root.
    var pi = mergeProjectInterfaces(packages, packages, contributions)
    var allEligible = true
    for pkg in packages:
      if not detectStandardBuildEligible(pkg.sourceFile, pkg):
        allEligible = false
        break
    pi.standardBuildEligible = allEligible
    return artifactFor(pi)
  var pi = toProjectInterface(packages[0], packages, contributions)
  pi.standardBuildEligible =
    detectStandardBuildEligible(packages[0].sourceFile, packages[0])
  artifactFor(pi)

proc nimDefault(nimType: string): string =
  case nimType.normalize
  of "string":
    "\"\""
  of "int":
    "0"
  of "bool":
    "false"
  of "seq[string]":
    "@[]"
  else:
    "default(" & nimType & ")"

proc escForCode(text: string): string =
  text.escape()

proc argBuilder(param: InterfaceParam): string =
  let kindCode =
    if param.kind == ipkPositional:
      "cpkPositional"
    else:
      "cpkFlag"
  let metaArgs = ", " & kindCode & ", " & $param.position & ", " &
    escForCode(param.alias)
  if param.nimType.normalize == "seq[string]":
    "cliArgSeq(\"" & param.name & "\", " & param.name & metaArgs & ")"
  else:
    "cliArg(\"" & param.name & "\", " & param.name & metaArgs & ")"

proc titleIdent(text: string): string =
  if text.len == 0:
    "Package"
  else:
    text[0].toUpperAscii() & text.substr(1) & "Package"

proc validGeneratedIdent(text: string): bool =
  const keywords = [
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
    "concept", "const", "continue", "converter", "defer", "discard", "distinct",
    "div", "do", "elif", "else", "end", "enum", "except", "export", "finally",
    "for", "from", "func", "if", "import", "in", "include", "interface", "is",
    "isnot", "iterator", "let", "macro", "method", "mixin", "mod", "nil", "not",
    "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref",
    "return", "shl", "shr", "static", "template", "try", "tuple", "type",
    "using", "var", "when", "while", "xor", "yield"
  ]
  if text.len == 0 or text.normalize in keywords:
    return false
  if not (text[0].isAlphaAscii() or text[0] == '_'):
    return false
  for ch in text:
    if not (ch.isAlphaNumeric() or ch == '_'):
      return false
  true

proc commandProcName(cmdName: string): string =
  if validGeneratedIdent(cmdName):
    return cmdName
  result = "subcmd"
  for ch in cmdName:
    if ch.isAlphaNumeric():
      result.add("_" & $ch)
    else:
      result.add("_" & toHex(ord(ch), 2).toLowerAscii())

proc liftedAttrsTypeName(typeId: string): string =
  ## M1b: the generated name of the consumer-importable attribute record type
  ## for a lifted ``resourceType``. The producer's OWN attrs type name never
  ## crosses the boundary (it is private to the producer module); the consumer
  ## imports THIS regenerated type, whose field set (name + type, in
  ## declaration order) is a structural mirror of the producer's — enough for
  ## the ``attr_ssz`` codec, which is purely field-shaped. Derived from the
  ## stable ``typeId`` so two producers of the same resource type converge on
  ## the same generated name and a consumer can name it deterministically.
  result = ""
  for ch in typeId:
    if ch.isAlphaNumeric():
      result.add(if result.len == 0: ch.toUpperAscii() else: ch)
    elif result.len > 0 and result[^1] != '_':
      result.add('_')
  if result.len == 0 or not (result[0].isAlphaAscii() or result[0] == '_'):
    result = "R" & result
  result.add("Attrs")

proc regenerableAttrType(nimType: string): string =
  ## M1b: the consumer-side field type to regenerate for a lifted attribute,
  ## or ``""`` when the declared type cannot be reconstructed structurally from
  ## the interface schema alone. Only the flat SSZ-clean field kinds the
  ## ``attr_ssz`` envelope supports AND whose spelling is self-contained
  ## (needs no producer-private type definition) round-trip here: ``string``,
  ## ``seq[string]``, and the integer / ``bool`` scalars. An ``enum`` attribute
  ## names a producer-private enum type, so it is NOT regenerable in the
  ## consumer (its type name is undefined there) — such a resource is lifted as
  ## a typed CONTRACT (schema in ``publicResources``) but no consumer-side codec
  ## is emitted for it.
  case nimType.normalize
  of "string": "string"
  of "seq[string]": "seq[string]"
  of "bool": "bool"
  of "int", "int8", "int16", "int32", "int64",
     "uint", "uint8", "uint16", "uint32", "uint64": nimType.strip()
  else: ""

proc emitLiftedExtensionTypes(code: var string;
                              resources: seq[InterfaceResource]) =
  ## M1b (Typed-Extension-Interfaces §2 capstone unblock): for each lifted
  ## ``resourceType``, emit into the consumer stub (a) a regenerated attribute
  ## record type whose fields mirror the producer's, and (b) a module-init
  ## ``registerExtension[<T>](typeId)`` so the CONSUMING compilation installs
  ## the SSZ codec (M1a) in its OWN process WITHOUT linking the producer's
  ## provider/driver module. This is what lets ``unmarshalAttrs`` re-hydrate an
  ## out-of-tree provider's attrs box: the marshaller now exists because the
  ## attrs TYPE crossed the interface boundary (like a typed tool), not the
  ## implementation. A resource with a non-regenerable attribute (e.g. an
  ## ``enum`` naming a producer-private type) is skipped — it still ships as a
  ## typed contract in the artifact, just without a consumer-side codec.
  var typeBlock = ""
  var regBody = ""
  for res in resources:
    var fields = ""
    var regenerable = true
    for attr in res.attributes:
      let fieldType = regenerableAttrType(attr.nimType)
      if fieldType.len == 0 or not validGeneratedIdent(attr.name):
        regenerable = false
        break
      fields.add("    " & attr.name & "*: " & fieldType & "\n")
    if not regenerable:
      continue
    let attrsName = liftedAttrsTypeName(res.typeId)
    typeBlock.add("  " & attrsName & "* = object\n")
    if fields.len == 0:
      typeBlock.add("    discard\n")
    else:
      typeBlock.add(fields)
    regBody.add("  registerExtension[" & attrsName & "](" &
      escForCode(res.typeId) & ")\n")
  if typeBlock.len == 0:
    return
  code.add("type\n" & typeBlock & "\n")
  code.add("proc registerLiftedExtensions*() =\n")
  code.add("  ## M1b: install the SSZ codecs for this dependency's lifted\n")
  code.add("  ## resource attribute types in the CONSUMING compilation, so\n")
  code.add("  ## ``unmarshalAttrs`` can round-trip their attrs boxes without\n")
  code.add("  ## linking the producer's provider module.\n")
  code.add(regBody)
  # Run once at module init so a mere ``import`` of the lifted interface is
  # enough to make the dependency's resource attrs marshallable — matching how
  # importing the producer module used to run its ``registerExtension`` side
  # effect. The explicit proc above is also exported for callers that register
  # into a freshly-cleared registry (e.g. per-test isolation).
  code.add("\nregisterLiftedExtensions()\n\n")

proc emitProvisioningContributionRegistrations(code: var string;
    contributions: seq[InterfaceProvisioningContribution]) =
  for contribution in contributions:
    code.add("registerProvisioningContributionDef(" &
      "ProvisioningContributionDef(targetPackage: " &
      escForCode(contribution.targetPackage) &
      ", targetInterfaceFingerprint: " &
      escForCode(contribution.targetInterfaceFingerprint) &
      ", contributor: " & escForCode(contribution.contributor) &
      ", developInterface: " & $contribution.developInterface &
      ", nixProvisioning: @[")
    for i, provisioning in contribution.nixProvisioning:
      if i > 0: code.add(", ")
      code.add("NixPackageProvisioningDef(selector: " &
        escForCode(provisioning.selector) &
        ", executablePath: " & escForCode(provisioning.executablePath) &
        ", expressionFile: " & escForCode(provisioning.expressionFile) &
        ", nixpkgsRef: " & escForCode(provisioning.nixpkgsRef) &
        ", nixpkgsRev: " & escForCode(provisioning.nixpkgsRev) &
        ", nixpkgsNarHash: " & escForCode(provisioning.nixpkgsNarHash) &
        ", packageId: " & escForCode(provisioning.packageId) &
        ", lockIdentity: " & escForCode(provisioning.lockIdentity) &
        ", sourceFile: " & escForCode(provisioning.location.file) &
        ", sourceLine: " & $provisioning.location.line & ")")
    code.add("], tarballProvisioning: @[")
    for i, provisioning in contribution.tarballProvisioning:
      if i > 0: code.add(", ")
      code.add("TarballProvisioningDef(url: " & escForCode(provisioning.url) &
        ", mirrors: @[")
      for j, mirror in provisioning.mirrors:
        if j > 0: code.add(", ")
        code.add(escForCode(mirror))
      code.add("], sha256: " & escForCode(provisioning.sha256) &
        ", archiveType: " & escForCode(provisioning.archiveType) &
        ", executablePath: " & escForCode(provisioning.executablePath) &
        ", stripComponents: " & $provisioning.stripComponents &
        ", packageId: " & escForCode(provisioning.packageId) &
        ", lockIdentity: " & escForCode(provisioning.lockIdentity) &
        ", cpu: " & escForCode(provisioning.cpu) &
        ", os: " & escForCode(provisioning.os) &
        ", sourceFile: " & escForCode(provisioning.location.file) &
        ", sourceLine: " & $provisioning.location.line & ")")
    code.add("], scoopProvisioning: @[")
    for i, provisioning in contribution.scoopProvisioning:
      if i > 0: code.add(", ")
      code.add("ScoopProvisioningDef(bucket: " &
        escForCode(provisioning.bucket) &
        ", app: " & escForCode(provisioning.app) &
        ", version: " & escForCode(provisioning.version) &
        ", preferredVersion: " & escForCode(provisioning.preferredVersion) &
        ", manifestChecksum: " & escForCode(provisioning.manifestChecksum) &
        ", manifestUrl: " & escForCode(provisioning.manifestUrl) &
        ", executablePath: " & escForCode(provisioning.executablePath) &
        ", requiresExecutionProfileChecksum: " &
        $provisioning.requiresExecutionProfileChecksum &
        ", packageId: " & escForCode(provisioning.packageId) &
        ", lockIdentity: " & escForCode(provisioning.lockIdentity) &
        ", sourceFile: " & escForCode(provisioning.location.file) &
        ", sourceLine: " & $provisioning.location.line & ")")
    code.add("], sourceFile: " & escForCode(contribution.location.file) &
      ", sourceLine: " & $contribution.location.line & "))\n")
  if contributions.len > 0:
    code.add("\n")

proc writeNimInterfaceStub*(path: string; artifact: ProjectInterfaceArtifact) =
  let pkg = artifact.projectInterface
  var code = "import repro_project_dsl\n\n"
  emitLiftedExtensionTypes(code, pkg.publicResources)
  emitProvisioningContributionRegistrations(code,
    pkg.provisioningContributions)
  let typeName = titleIdent(pkg.packageName)
  let exeTypeName = typeName & "Executable"
  code.add("type\n  " & typeName & "* = object\n")
  code.add("  " & exeTypeName & "* = object\n")
  code.add("    value*: SelectedExecutable\n\n")
  code.add("const " & pkg.packageName & "* = " & typeName & "()\n\n")
  code.add("proc executable*(pkg: " & typeName & "; name: string): " &
    exeTypeName & " =\n")
  code.add("  discard pkg\n")
  code.add("  " & exeTypeName & "(value: selectedExecutable(\"" &
    pkg.packageName & "\", name))\n\n")
  var selectedCommands: seq[string] = @[]
  for exe in pkg.publicExecutables:
    for cmd in exe.commands:
      var params: seq[string] = @["exe: " & exeTypeName]
      var argCalls: seq[string] = @[]
      let procName = commandProcName(cmd.name)
      var signature = procName & "|" & cmd.name
      for param in cmd.params:
        var spec = param.name & ": " & param.nimType
        if not param.required:
          spec.add(" = " & nimDefault(param.nimType))
        params.add(spec)
        signature.add("|" & spec)
        argCalls.add(argBuilder(param))
      if selectedCommands.find(signature) >= 0:
        continue
      selectedCommands.add(signature)
      code.add("proc " & procName & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      code.add("  publicCliCall(exe.value.packageName, " &
        "exe.value.executableName, \"" & cmd.name &
        "\", exe.value.packageName & \".\" & exe.value.executableName & " &
        "\"." & cmd.name & "\", @[" & argCalls.join(", ") & "])\n\n")
  if pkg.publicExecutables.len == 1:
    let exe = pkg.publicExecutables[0]
    for cmd in exe.commands:
      var params: seq[string] = @["pkg: " & typeName]
      var argCalls: seq[string] = @[]
      for param in cmd.params:
        var spec = param.name & ": " & param.nimType
        if not param.required:
          spec.add(" = " & nimDefault(param.nimType))
        params.add(spec)
        argCalls.add(argBuilder(param))
      let procName = commandProcName(cmd.name)
      code.add("proc " & procName & "*( " & params.join("; ") &
        "): PublicCliCall =\n")
      code.add("  discard pkg\n")
      code.add("  publicCliCall(\"" & pkg.packageName & "\", \"" &
        exe.binaryName &
        "\", \"" & cmd.name & "\", \"" & cmd.providerEntrypointId &
        "\", @[" & argCalls.join(", ") & "])\n\n")
  createDir(extendedPath(parentDir(path)))
  writeFile(extendedPath(path), code)

when compileOption("threads"):
  import std/locks

  var spawnWorkingDirLock: Lock
  spawnWorkingDirLock.initLock()

template withSpawnWorkingDir(body: untyped) =
  ## Serialise `startProcess(workingDir = ...)` against itself.
  ##
  ## On POSIX, `osproc.startProcess` applies `workingDir` by calling
  ## `setCurrentDir` in the PARENT, spawning, and then restoring the old
  ## directory (`startProcessAuxSpawn`; the posix_spawn path has no
  ## per-spawn chdir file action). The current directory is a
  ## process-global, so two threads spawning concurrently with different
  ## `workingDir` values race: whichever chdir lands last wins for BOTH
  ## children, and the second spawn's child silently inherits the first
  ## one's directory.
  ##
  ## `compileProviderBinary` allocates a private compiler CWD per provider
  ## compile precisely because `nim` writes its linker response files
  ## (`*_linkerArgs.txt`) relative to the current directory — two compiles
  ## landing in one directory clobber each other's response file. Holding
  ## this lock across the whole `startProcess` call keeps the chdir /
  ## spawn / restore triple atomic, so the private CWD is exclusive in
  ## fact and not merely by luck. Only the spawn itself is serialised;
  ## the compiles that follow still run concurrently.
  when compileOption("threads"):
    withLock spawnWorkingDirLock:
      body
  else:
    body

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc cmdExeShellEscape(value: string): string =
  ## cmd.exe quoting: wrap in double quotes; escape embedded double quotes.
  "\"" & value.replace("\"", "\\\"") & "\""

proc powerShellSingleQuote(value: string): string =
  "'" & value.replace("'", "''") & "'"

proc powerShellRunCommandScript*(command: openArray[string];
    sinkPath: string): string =
  ## Materialise a long argv as a PowerShell array so Windows does not route
  ## the child command through cmd.exe's ~8191-character command-line limit.
  if command.len == 0:
    raise newException(ValueError, "PowerShell command script requires argv")
  result = "$ErrorActionPreference = 'Stop'\r\n"
  result.add("$exe = " & powerShellSingleQuote(command[0]) & "\r\n")
  result.add("$argv = @(\r\n")
  for i in 1 ..< command.len:
    result.add("  " & powerShellSingleQuote(command[i]))
    if i + 1 < command.len:
      result.add(",")
    result.add("\r\n")
  result.add(")\r\n")
  result.add("& $exe @argv > " & powerShellSingleQuote(sinkPath) &
    " 2>&1\r\n")
  result.add("exit $LASTEXITCODE\r\n")

proc runCommand(command: openArray[string];
    cwd = ""): ProviderCompileExecutionResult =
  if command.len == 0:
    raise newException(OSError, "runCommand requires a non-empty argv")
  when defined(windows):
    # Capture the child's merged stdout+stderr through a temp-file sink
    # rather than draining an inherited OS pipe. The pipe variant deadlocks
    # on Windows whenever the child (typically `nim c`) spawns a sub-process
    # (gcc) that inherits the pipe write handle: when `nim` exits but gcc
    # is still running, the pipe never EOFs and the parent's `readAll()`
    # blocks forever. Materialising the redirection as a tiny .cmd script
    # (rather than passing it inline through `cmd.exe /c`) sidesteps the
    # cmd.exe outer-quote-stripping rule that otherwise mangles the `>`
    # redirection when the assembled command line starts with a quoted
    # absolute path.
    let sinkDir = getTempDir()
    createDir(extendedPath(sinkDir))
    let nonce = $getCurrentProcessId() & "-" &
      $int64(epochTime() * 1_000_000.0)
    let sinkPath = sinkDir / ("repro-runcommand-" & nonce & ".log")
    let scriptPath = sinkDir / ("repro-runcommand-" & nonce & ".cmd")
    let psScriptPath = sinkDir / ("repro-runcommand-" & nonce & ".ps1")
    # cmd.exe truncates any single command line past ~8191 chars, so a
    # large `nim c` invocation (60+ --path: entries) silently produces an
    # empty sink and we report `command failed` with no stderr. Fall back
    # to a PowerShell script when the assembled arg list would overflow:
    # the pwsh.exe command line remains short, while the script invokes the
    # real child with an argv array and file redirection. This keeps us out
    # of unsupported Nim @-file semantics and preserves exact arguments.
    let assembledLen = command.mapIt(cmdExeShellEscape(it)).join(" ").len +
      cmdExeShellEscape(sinkPath).len + " > 2>&1\r\n@echo off\r\n".len
    let usePowerShellScript = assembledLen > 6000
    var process: Process
    if usePowerShellScript:
      writeFile(extendedPath(psScriptPath),
        powerShellRunCommandScript(command, sinkPath))
      let powerShellExe = block:
        let pwsh = findExe("pwsh")
        if pwsh.len > 0:
          pwsh
        else:
          let windowsPowerShell = findExe("powershell")
          if windowsPowerShell.len > 0:
            windowsPowerShell
          else:
            raise newException(OSError,
              "pwsh/powershell required for long Windows command")
      withSpawnWorkingDir:
        process = startProcess(powerShellExe,
          args = @[
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            psScriptPath],
          workingDir = cwd, options = {poUsePath})
    else:
      let scriptBody = "@echo off\r\n" &
        command.mapIt(cmdExeShellEscape(it)).join(" ") &
        " > " & cmdExeShellEscape(sinkPath) & " 2>&1\r\n"
      writeFile(extendedPath(scriptPath), scriptBody)
      withSpawnWorkingDir:
        process = startProcess("cmd.exe",
          args = @["/c", scriptPath],
          workingDir = cwd, options = {poUsePath})
    # Bounded wait. A wedged `nim c` -- whose gcc children can deadlock on
    # Windows and hold the runner for HOURS (observed: a 4h+ hang on the
    # full-closure interface extract) -- must fail fast with whatever it wrote
    # to the sink, never hang. REPRO_INTERFACE_COMPILE_TIMEOUT_SECONDS overrides
    # the default cap; a value <= 0 restores the original unbounded wait. On
    # timeout we kill the WHOLE process tree (wrapper -> nim.exe -> gcc.exe) via
    # `taskkill /T` so no orphaned compiler keeps the slot busy, then still read
    # the partial sink -- so with `--listCmd` the LAST command in the dump is the
    # sub-command that wedged, converting a silent hang into an actionable error.
    var timeoutSecs = 1800
    block:
      let raw = getEnv("REPRO_INTERFACE_COMPILE_TIMEOUT_SECONDS").strip()
      if raw.len > 0:
        try:
          timeoutSecs = parseInt(raw)
        except ValueError:
          timeoutSecs = 1800
    var exitCode = 0
    var timedOut = false
    if timeoutSecs <= 0:
      exitCode = process.waitForExit()
    else:
      let deadline = epochTime() + timeoutSecs.float
      while true:
        if not running(process):
          exitCode = process.waitForExit()
          break
        if epochTime() >= deadline:
          timedOut = true
          discard execCmd("taskkill /F /T /PID " & $process.processID &
            " > nul 2>&1")
          try:
            exitCode = process.waitForExit()
          except CatchableError:
            exitCode = 124
          break
        sleep(500)
    process.close()
    try:
      removeFile(extendedPath(scriptPath))
    except CatchableError:
      discard
    try:
      removeFile(extendedPath(psScriptPath))
    except CatchableError:
      discard
    var output = ""
    if fileExists(extendedPath(sinkPath)):
      try:
        output = readFile(extendedPath(sinkPath))
      except CatchableError:
        output = ""
      try:
        removeFile(extendedPath(sinkPath))
      except CatchableError:
        discard
    if timedOut:
      exitCode = 124
      output = "runCommand: TIMED OUT after " & $timeoutSecs &
        "s and killed the nim/gcc process tree. Partial sink output follows; " &
        "with --listCmd the LAST command shown is the one that wedged.\n" &
        output
    result = ProviderCompileExecutionResult(
      exitCode: exitCode,
      output: output)
  else:
    var process: Process
    withSpawnWorkingDir:
      process = startProcess(command[0],
        args = command[1 .. ^1],
        workingDir = cwd,
        options = {poUsePath, poStdErrToStdOut})
    var output = ""
    if process.outputStream != nil:
      output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    result = ProviderCompileExecutionResult(
      exitCode: exitCode,
      output: output)
  if result.exitCode != 0:
    let quoted = command.mapIt(shellQuote(it)).join(" ")
    raise newException(OSError, "command failed (" & $result.exitCode &
      "): " & quoted & "\n" & result.output)

proc nimCompilerPath(): string =
  if cachedNimCompilerPath.len > 0:
    return cachedNimCompilerPath
  let overridePath = getEnv("REPRO_NIM_COMPILER")
  if overridePath.len > 0:
    cachedNimCompilerPath = overridePath
    return overridePath
  proc addUnique(paths: var seq[string]; path: string) =
    if path.len == 0:
      return
    for existing in paths:
      if existing == path:
        return
    paths.add(path)
  proc looksLikeNimCompiler(path: string): bool =
    try:
      let probe = runCommand(@[path, "--version"])
      probe.output.contains("Nim Compiler")
    except CatchableError:
      false
  let exeName = addFileExt("nim", ExeExt)
  var candidates: seq[string] = @[]
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0:
      continue
    let candidate = dir / exeName
    if fileExists(extendedPath(candidate)):
      candidates.addUnique(candidate)
  if BuiltNimCompilerPath.len > 0 and fileExists(extendedPath(BuiltNimCompilerPath)):
    candidates.addUnique(BuiltNimCompilerPath)
  candidates.addUnique("nim")
  for candidate in candidates:
    if candidate.startsWith("/nix/store/"):
      cachedNimCompilerPath = candidate
      return candidate
    if looksLikeNimCompiler(candidate):
      cachedNimCompilerPath = candidate
      return candidate
  cachedNimCompilerPath =
    if BuiltNimCompilerPath.len > 0 and fileExists(extendedPath(BuiltNimCompilerPath)):
      BuiltNimCompilerPath
    else:
      "nim"
  cachedNimCompilerPath

proc compiledExecutablePath(outputPath: string): string =
  when defined(windows):
    if ExeExt.len == 0 or outputPath.endsWith("." & ExeExt):
      outputPath
    else:
      outputPath & "." & ExeExt
  else:
    outputPath

proc ensureExecutable(path: string) =
  when defined(windows):
    discard path
  else:
    setFilePermissions(extendedPath(path), {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc hostCCompilerPath(): string =
  # MR9 — `$REPRO_BOOTSTRAP_CC` is the bootstrap-resolved gcc absolute
  # path published by `ensureBootstrapToolchainEnv` (tool_profiles.nim)
  # before the interface-extract step runs. It outranks `$CC` because
  # env.ps1 / inherited shells legitimately set `$CC` to a bare
  # basename like ``gcc`` for use by Makefiles / autotools, and the
  # `isAbsolute(ccEnv)` check below would discard that value and fall
  # through to `BuiltCCompilerPath` (which, on a clean Windows host,
  # rarely matches a usable 64-bit toolchain). Consulting the
  # bootstrap pin first guarantees nim's `--gcc.exe:` flag points at
  # the reprobuild-provisioned winlibs gcc instead of whatever
  # PATH-resolution would pick (e.g. FPC's 32-bit-target gcc 2.95).
  let bootstrapCC = getEnv("REPRO_BOOTSTRAP_CC")
  if bootstrapCC.len > 0 and isAbsolute(bootstrapCC) and
      fileExists(extendedPath(bootstrapCC)):
    return bootstrapCC
  let ccEnv = getEnv("CC")
  if ccEnv.len > 0 and isAbsolute(ccEnv):
    return ccEnv
  when not defined(windows):
    let runtimeCC = findExe("cc")
    if runtimeCC.len > 0 and isAbsolute(runtimeCC) and
        fileExists(extendedPath(runtimeCC)):
      return runtimeCC
  if BuiltCCompilerPath.len > 0 and fileExists(extendedPath(BuiltCCompilerPath)):
    return BuiltCCompilerPath
  ""

var cachedHostCCompilerFamily = ""

proc hostCCompilerFamily(cc: string): string =
  ## Detect whether the provisioned C compiler is clang- or gcc-flavoured
  ## so Nim's selected compiler *family* matches the actual binary.
  ##
  ## ``hostCCompilerFlags`` aliases BOTH ``--gcc.exe`` and ``--clang.exe``
  ## to this single compiler but, historically, left the compiler family
  ## at Nim's platform default (clang on macOS, gcc on Linux). When the
  ## provisioned ``cc`` is gcc (e.g. the Nix gcc-wrapper used by path-mode
  ## provisioning) but Nim still thinks it is clang, Nim emits clang-only
  ## flags such as ``-ferror-limit=3`` (from ``clang.options.always``)
  ## and the gcc binary rejects them, breaking interface extraction.
  ## Pinning ``--cc`` to the detected family keeps the always-on flag set
  ## consistent with the binary on every platform.
  if cachedHostCCompilerFamily.len > 0:
    return cachedHostCCompilerFamily
  cachedHostCCompilerFamily = "gcc"
  try:
    let (output, exitCode) = execCmdEx(quoteShell(cc) & " --version")
    if exitCode == 0 and "clang" in output.toLowerAscii:
      cachedHostCCompilerFamily = "clang"
  except CatchableError, OSError:
    discard
  cachedHostCCompilerFamily

proc hostCCompilerFlags(): seq[string] =
  # Windows: bump the linked stack size for any binary the engine
  # compiles on its own behalf (interface-extract runner, per-project
  # provider). Default Windows stack is 1 MB; the recipe-evaluation
  # path executes deeply-recursive macro-expansion code under a
  # singleton thread (no async, no fan-out), and the resulting binary
  # routinely overflows that limit with STATUS_STACK_OVERFLOW
  # (-1073741571 / 0xC00000FD) on recipes that import the whole
  # ``repro_dsl_stdlib`` umbrella. POSIX gets a much larger default
  # stack from the kernel (8 MB on Linux, 8 MB on macOS) so this is a
  # Windows-only adjustment. Emitted regardless of whether
  # ``hostCCompilerPath`` resolved — the flag is honoured by every
  # supported toolchain (winlibs gcc, MSYS2 mingw64, MSVC link.exe via
  # ``--passL:/STACK:`` equivalent).
  when defined(windows):
    result.add("--passL:-Wl,--stack,16777216")

  let cc = hostCCompilerPath()
  if cc.len == 0:
    return
  # Match Nim's compiler family to the provisioned binary so the family's
  # always-on flags (e.g. clang's -ferror-limit) are not handed to the
  # wrong compiler. See hostCCompilerFamily for the failure this avoids.
  result.add("--cc:" & hostCCompilerFamily(cc))
  result.add("--gcc.exe:" & cc)
  result.add("--gcc.linkerexe:" & cc)
  result.add("--clang.exe:" & cc)
  result.add("--clang.linkerexe:" & cc)

proc walkLibSrcPathsInto(libsRoot: string; sink: var seq[string]) =
  ## Walks ``<libsRoot>/<name>/src`` and appends every existing entry to
  ## ``sink``. Follows symlinked dirs so cross-repo libraries vendored
  ## via symlink (codetracer's ``ct_test_nim_unittest`` adapter etc.)
  ## participate. Idempotent — the caller deduplicates the final list.
  if not dirExists(extendedPath(libsRoot)):
    return
  # TODO(win-longpath): walk results escape; needs review
  for path in walkDir(libsRoot):
    if path.kind in {pcDir, pcLinkToDir}:
      let src = path.path / "src"
      if dirExists(extendedPath(src)):
        sink.add(src)

proc reprobuildLibsRootFromEnv(): string =
  ## ``$REPROBUILD_LIBS_DIR`` is the explicit operator override for
  ## "where reprobuild's libs/ live". Set by the engine when invoking
  ## an out-of-tree provider compile; mirrors ``$REPROBUILD_REPO_ROOT``
  ## except it points at the libs dir directly. Empty when not set.
  let direct = getEnv("REPROBUILD_LIBS_DIR")
  if direct.len > 0:
    return direct
  let repoRoot = getEnv("REPROBUILD_REPO_ROOT")
  if repoRoot.len > 0:
    return repoRoot / "libs"
  ""

proc reprobuildSourceRootFromBinaryLocation*(exePath = ""): string =
  ## Derive the source checkout containing a local
  ## ``<reprobuild-root>/build/bin/repro`` binary. Installed binaries do not
  ## have this layout and deliberately return an empty string; their wrapper
  ## supplies ``REPROBUILD_SOURCE_ROOT`` instead.
  let resolvedExe = if exePath.len > 0: exePath else: getAppFilename()
  if resolvedExe.len == 0:
    return ""
  let candidateRoot = resolvedExe.parentDir.parentDir.parentDir
  let marker = candidateRoot / "libs" / "repro_project_dsl" / "src" /
    "repro_project_dsl.nim"
  if fileExists(extendedPath(marker)):
    return candidateRoot
  ""

proc reprobuildLibsRootFromBinaryLocation(): string =
  ## When the running ``repro`` binary lives inside a reprobuild source
  ## checkout, derive the libs root from the validated checkout root.
  let sourceRoot = reprobuildSourceRootFromBinaryLocation()
  if sourceRoot.len == 0:
    return ""
  sourceRoot / "libs"

proc siblingReprobuildLibsRoot(workDir: string): string =
  ## When a recorder repo is checked out as a sibling of reprobuild
  ## (``D:/m/dev/codetracer-foo-recorder/`` next to
  ## ``D:/m/dev/reprobuild/``) the develop-mode convention is for the
  ## consumer to find reprobuild's libs at ``../reprobuild/libs/``.
  ## This is the equivalent of the recorder dev-shell scripts' sibling
  ## detection (``scripts/detect-siblings.sh`` etc.) lifted into the
  ## reprobuild engine itself so consumers don't have to redo it.
  let candidate = workDir.parentDir / "reprobuild" / "libs"
  let marker = candidate / "repro_project_dsl" / "src" / "repro_project_dsl.nim"
  if fileExists(extendedPath(marker)):
    return candidate
  ""

proc workDirIsReprobuildTree(workDir: string): bool =
  ## True when ``workDir`` IS itself a reprobuild source checkout — its own
  ## ``libs/`` is the authoritative copy of the reprobuild libs the harness
  ## compiles against, so no EXTERNAL root is consulted.
  fileExists(extendedPath(
    workDir / "libs" / "repro_project_dsl" / "src" / "repro_project_dsl.nim"))

proc reprobuildExternalLibsRoot(workDir: string): string =
  ## The reprobuild ``libs/`` root a NON-reprobuild consumer compiles its
  ## provider/interface recipes against, resolved EXACTLY as
  ## ``reproLibPathFlags`` does: ``$REPROBUILD_LIBS_DIR`` /
  ## ``$REPROBUILD_REPO_ROOT`` → the running ``repro`` binary's own checkout →
  ## a sibling ``../reprobuild/`` checkout. Empty when ``workDir`` IS itself a
  ## reprobuild tree (its ``libs/`` is already the authoritative copy) or when
  ## no external root is found.
  ##
  ## This is the single source of truth for "which reprobuild libs does the
  ## harness use", consumed BOTH by ``reproLibPathFlags`` (to build the
  ## ``--path:`` flags) AND by ``reproLibSources`` (to fold those libs into the
  ## provider-nimcache freshness key). Without the latter, an out-of-tree
  ## reprobuild lib edit would NOT change the nimcache key — the shared
  ## nimcache would then reuse a STALE compiled ``repro_interface_artifacts``,
  ## and the harness would emit interface artifacts the freshly-built ``repro``
  ## binary cannot validate (an interface/provider fingerprint skew across the
  ## harness↔binary boundary).
  if workDirIsReprobuildTree(workDir):
    return ""
  result = reprobuildLibsRootFromEnv()
  if result.len == 0:
    result = reprobuildLibsRootFromBinaryLocation()
  if result.len == 0:
    result = siblingReprobuildLibsRoot(workDir)

proc markedPackageRoot(candidate, marker: string): string =
  if candidate.len == 0:
    return ""
  if fileExists(extendedPath(candidate / marker)):
    return candidate
  let srcCandidate = candidate / "src"
  if fileExists(extendedPath(srcCandidate / marker)):
    return srcCandidate

proc resolveBootstrapPackagePath*(envName: string;
                                  candidates: openArray[string];
                                  marker: string;
                                  builtCandidate = ""): string =
  ## MR14 — mirror ``config.nims``'s ``addPackagePath`` resolution shape
  ## so the recipe-compile (extract_runner) ``nim c`` invocation sees the
  ## same sibling source-only dependencies that reprobuild itself sees
  ## when it is compiled. ``config.nims`` is loaded by ``nim`` when the
  ## current directory is the reprobuild repo root; the recipe-compile
  ## step runs from the *consumer* repo's workdir so it never loads
  ## reprobuild's ``config.nims``. Without this helper, an ``import``
  ## that the dev-shell could resolve (e.g. ``import nimcrypto/sha2``
  ## inside ``repro_project_dsl``) fails at extract_runner compile time
  ## with ``Error: cannot open file: nimcrypto/sha2``.
  ##
  ## Resolution order (mirrors ``config.nims:112-121``):
  ## 1. ``$<envName>`` environment variable (if set and contains marker)
  ## 2. each candidate path in declaration order (if it contains marker)
  ## 3. the source root captured when ``repro`` was built
  ## 4. "" (caller skips the ``--path:`` flag entirely)
  let envPath = markedPackageRoot(getEnv(envName), marker)
  if envPath.len > 0:
    return envPath
  for candidate in candidates:
    let resolved = markedPackageRoot(candidate, marker)
    if resolved.len > 0:
      return resolved
  markedPackageRoot(builtCandidate, marker)

proc resolveCtTestRunnerAdapterPath(anchorRoot: string): string =
  let envRoot = getEnv("REPRO_CT_TEST_RUNNER_SRC")
  if envRoot.len > 0:
    let candidate = envRoot / "libs" / "ct_test_runner_adapter" / "src"
    if fileExists(extendedPath(candidate / "ct_test_runner_adapter.nim")):
      return candidate
  if anchorRoot.len > 0:
    let candidate = anchorRoot.parentDir / "reprobuild-ct-test-runner" /
      "libs" / "ct_test_runner_adapter" / "src"
    if fileExists(extendedPath(candidate / "ct_test_runner_adapter.nim")):
      return candidate
  ""

proc resolveCtIncrementalAdapterPath(anchorRoot: string): string =
  for codeTracerRoot in [getEnv("CODETRACER_SRC"),
                         anchorRoot.parentDir / "codetracer" / "src"]:
    let candidate = markedPackageRoot(
      codeTracerRoot, "ct_incremental_adapter.nim")
    if candidate.len > 0:
      return candidate
  for runnerRoot in [getEnv("REPRO_CT_TEST_RUNNER_SRC"),
                     anchorRoot.parentDir / "reprobuild-ct-test-runner"]:
    let candidate = runnerRoot / "libs" / "ct_incremental_adapter" / "src"
    if fileExists(extendedPath(candidate / "ct_incremental_adapter.nim")):
      return candidate
  ""

proc resolveRunquotaRoot(anchorRoot, consumerParent: string): string =
  let marker = "libs" / "runquota_core" / "src" / "runquota_core.nim"
  for candidate in [getEnv("RUNQUOTA_SRC"),
                    anchorRoot.parentDir / "runquota",
                    consumerParent / "runquota"]:
    if candidate.len > 0 and fileExists(extendedPath(candidate / marker)):
      return candidate
  ""

proc bootstrapSiblingPackagePathFlags*(reprobuildRoot: string;
                                       consumerParent = ""): seq[string] =
  ## MR14 — produce the ``--path:`` flags for the source-only sibling
  ## dependencies that ``reprobuild/config.nims`` lines 126-192 register
  ## via ``addPackagePath``. The list MUST stay in sync with config.nims
  ## so the recipe-compile reaches the same path set as reprobuild itself.
  ##
  ## The candidate lists below are written relative to
  ## ``reprobuildRoot`` (the absolute path to reprobuild's repo root)
  ## rather than to ``getCurrentDir()`` because the recipe-compile runs
  ## from the consumer's workdir, where ``".." / "nimcrypto"`` would
  ## point at a sibling of the *consumer* repo and not at a sibling of
  ## reprobuild. We resolve every candidate against ``reprobuildRoot``
  ## so the same workspace layout that satisfies ``nim c`` for
  ## reprobuild itself also satisfies the recipe-compile.
  if reprobuildRoot.len == 0:
    return
  let reprobuildParent = reprobuildRoot.parentDir
  # The workspace the CLI was invoked in. ``workDir`` is NOT a reliable
  # consumer anchor here: the cross-repo producer path extracts with
  # ``reprobuildLibraryWorkDir()``, which resolves through
  # ``currentSourcePath()`` and so points at reprobuild's OWN root -- in a
  # dev shell that is the flake-pinned /nix/store snapshot, whose parent is
  # /nix/store. The process's working directory is the consumer repo for
  # every ``repro build`` invocation, so it anchors the sibling lookup even
  # when the caller had no consumer path to pass.
  let cwdParent = getCurrentDir().parentDir
  proc anchored(candidates: openArray[string]): seq[string] =
    for c in candidates:
      if isAbsolute(c):
        result.add(c)
      elif c.startsWith(".." & DirSep) or c.startsWith("../") or c == ".." or
           c.startsWith(".." & "\\"):
        # Strip a single leading "../" and anchor at reprobuild's parent.
        var rest = c
        if rest == "..":
          rest = ""
        elif rest.startsWith("../"):
          rest = rest[3 .. ^1]
        elif rest.startsWith(".." & DirSep):
          rest = rest[3 .. ^1]
        elif rest.startsWith("..\\"):
          rest = rest[3 .. ^1]
        result.add(if rest.len > 0: reprobuildParent / rest else: reprobuildParent)
        # ...and again anchored at the CONSUMER's workspace, when that is a
        # different tree. In a dev shell reprobuild's libs are a flake-pinned
        # /nix/store snapshot, so ``reprobuildParent`` is /nix/store and a
        # sibling candidate can never resolve there. config.nims papers over
        # this with per-package env vars ($REPRO_TEST_ADAPTERS_SRC, ...)
        # "seeded by the flake input", but a consumer's dev shell does not
        # seed them -- which is why every codetracer graph evaluation failed
        # with ``cannot open file: repro_test_adapters/test_runner`` while the
        # package sat checked out in the workspace all along.
        for extraAnchor in [consumerParent, cwdParent]:
          if extraAnchor.len > 0 and extraAnchor != reprobuildParent:
            result.add(
              if rest.len > 0: extraAnchor / rest else: extraAnchor)
      else:
        result.add(reprobuildRoot / c)

  type SiblingSpec = tuple
    envName: string
    candidates: seq[string]
    marker: string
  let specs: seq[SiblingSpec] = @[
    ("REPRO_TEST_ADAPTERS_SRC", anchored([
      ".." / "reprobuild-test-adapters" / "src",
    ]), "repro_test_adapters" / "test_runner.nim"),
    ("FASTSTREAMS_SRC", anchored([
      "libs" / "nim-faststreams" / "src",
      ".." / "codetracer" / "libs" / "nim-faststreams",
      ".." / "nim-faststreams",
    ]), "faststreams" / "inputs.nim"),
    ("NIM_STEW_SRC", anchored([
      "libs" / "nim-stew" / "src",
      ".." / "codetracer" / "libs" / "nim-stew",
      ".." / "nim-stew",
    ]), "stew" / "objects.nim"),
    ("NIM_SERIALIZATION_SRC", anchored([
      "libs" / "nim-serialization" / "src",
      ".." / "codetracer" / "libs" / "nim-serialization",
      ".." / "nim-serialization",
    ]), "serialization" / "case_objects.nim"),
    ("NIM_JSON_SERIALIZATION_SRC", anchored([
      "libs" / "nim-json-serialization" / "src",
      ".." / "codetracer" / "libs" / "nim-json-serialization",
      ".." / "nim-json-serialization",
    ]), "json_serialization.nim"),
    ("NIM_TOML_SERIALIZATION_SRC", anchored([
      "libs" / "nim-toml-serialization" / "src",
      ".." / "codetracer" / "libs" / "nim-toml-serialization",
      ".." / "nim-toml-serialization",
    ]), "toml_serialization.nim"),
    ("SSZ_SERIALIZATION_SRC", anchored([
      "libs" / "nim-ssz-serialization" / "src",
      ".." / "nim-ssz-serialization",
    ]), "ssz_serialization.nim"),
    ("NIMCRYPTO_SRC", anchored([
      # Vendored source-only slice under reprobuild's own libs/, listed
      # first so the recipe-compile is self-contained and does not depend
      # on a consumer's sibling nimcrypto checkout. Mirrors config.nims.
      # Marker is nimcrypto/hash.nim.
      "libs" / "nimcrypto",
      ".." / "codetracer" / "libs" / "nimcrypto",
      ".." / "nimcrypto",
    ]), "nimcrypto" / "hash.nim"),
    ("IO_MON_SRC", anchored([
      ".." / "io-mon" / "src",
    ]), "io_mon.nim"),
    ("BEARSSL_SRC", anchored([
      ".." / "nim-bearssl",
      "libs" / "nim-bearssl",
    ]), "bearssl.nim"),
    ("RESULTS_SRC", anchored([
      "libs" / "results" / "src",
    ]), "results.nim"),
    ("STINT_SRC", anchored([
      "libs" / "stint" / "src",
    ]), "stint.nim"),
    # Incremental-Test-Runner M7: the monitor shim moved to the io-mon
    # sibling; ``nim-stackable-hooks`` is resolved only from the sibling
    # checkout now (the deleted ``repro_monitor_shim/vendor`` fallback is gone).
    ("STACKABLE_HOOKS_SRC", anchored([
      ".." / "nim-stackable-hooks" / "src",
    ]), "stackable_hooks.nim"),
    ("VM_HARNESS_SRC", anchored([
      ".." / "vm-harness" / "src",
    ]), "vm_harness.nim"),
    # SHM-QUEUE-MIGRATE: ``libs/repro_shm_index`` (``repro_shm_index/layout``)
    # imports ``shm_queue/segment`` from the ``nim-shm-queue`` sibling — the
    # extracted single MPSC ring. ``config.nims:373`` registers it via
    # ``addPackagePath("SHM_QUEUE_SRC", …, useDevShellFallback = true)``, so it
    # is on the NORMAL build ``--path`` but was absent here — any producer whose
    # ``repro.nim`` transitively pulls ``repro_shm_index`` (e.g. via
    # ``import repro_resources``) failed to interface-extract with
    # ``cannot open file: shm_queue/segment``. Mirror config.nims so the
    # extractor's path set matches the build's: prefer ``$SHM_QUEUE_SRC``, then
    # the sibling checkout.
    ("SHM_QUEUE_SRC", anchored([
      ".." / "nim-shm-queue" / "src",
    ]), "shm_queue.nim"),
    # io-mon's writer now imports ``shm_gset/transport`` from the
    # ``nim-shm-gset`` sibling (the grow-only shared-memory set, io-mon's Linux
    # dependency-capture channel). Any producer whose ``repro.nim`` transitively
    # pulls ``io_mon`` fails to interface-extract with ``cannot open file:
    # shm_gset/transport`` unless nim-shm-gset is on the extractor's ``--path``.
    # Mirror config.nims (SHM_GSET_SRC), exactly as SHM_QUEUE_SRC above.
    ("SHM_GSET_SRC", anchored([
      ".." / "nim-shm-gset" / "src",
    ]), "shm_gset.nim"),
    ("REPRO_TEST_ADAPTERS_SRC", anchored([
      ".." / "reprobuild-test-adapters" / "src",
    ]), "repro_test_adapters" / "test_runner.nim"),
  ]
  for spec in specs:
    let resolved = resolveBootstrapPackagePath(spec.envName, spec.candidates,
                                               spec.marker,
                                               builtSourcePackageRoot(spec.envName))
    if resolved.len > 0:
      result.add("--path:" & resolved)
  for adapterPath in [resolveCtTestRunnerAdapterPath(reprobuildRoot),
                      resolveCtIncrementalAdapterPath(reprobuildRoot)]:
    if adapterPath.len > 0:
      result.add("--path:" & adapterPath)

  let runquotaRoot = resolveRunquotaRoot(reprobuildRoot, consumerParent)
  if runquotaRoot.len > 0:
    var runquotaPaths: seq[string] = @[]
    walkLibSrcPathsInto(runquotaRoot / "libs", runquotaPaths)
    runquotaPaths.sort(system.cmp[string])
    for path in runquotaPaths:
      result.add("--path:" & path)

proc declaredPackageDeps*(workDir: string): seq[string] =
  ## The package dependencies a project's ``repro.nim`` declares with a
  ## nested ``uses "<name>"`` entry, in declaration order, deduplicated.
  ##
  ## Read TEXTUALLY, on purpose. The declarations live INSIDE the recipe,
  ## but the ``--path:`` flags they imply are needed to COMPILE that recipe
  ## — so nothing may depend on having evaluated it first. This is the same
  ## bootstrap technique ``discoverNimSources`` already uses to build the
  ## provider-compile source closure without a semantic pass.
  ##
  ## Only the nested ``uses "<x>"`` form is a package dependency. Bare
  ## strings inside a ``uses:`` block (``"nim >=2.0"``, ``"ffmpeg >=7.0"``)
  ## are tool/version requirements and name no Nim package; treating them
  ## as one would try to put ``ffmpeg`` on the Nim path.
  let recipe = workDir / "repro.nim"
  if not fileExists(extendedPath(recipe)):
    return
  var seen = initHashSet[string]()
  for rawLine in lines(extendedPath(recipe)):
    # Comment-strip inline rather than via ``stripNimLineComment``: that
    # helper is defined further down this module, and these two procs must
    # sit above ``reproLibPathFlags``, which calls them.
    let hashPos = rawLine.find('#')
    let uncommented = if hashPos >= 0: rawLine[0 ..< hashPos] else: rawLine
    let line = uncommented.strip()
    if not line.startsWith("uses"):
      continue
    # ``uses "x"`` / ``uses: "x"`` -- and NOT a bare ``uses:`` block head,
    # whose own body lines are handled by their own iterations.
    var rest = line["uses".len .. ^1].strip()
    if rest.startsWith(":"):
      rest = rest[1 .. ^1].strip()
    if rest.len < 2 or rest[0] != '"':
      continue
    let closing = rest.find('"', 1)
    if closing <= 1:
      continue
    let name = rest[1 ..< closing]
    # A version constraint is a requirement, not a package name.
    if name.contains('>') or name.contains('<') or name.contains('='):
      continue
    if ' ' in name:
      continue
    if not seen.containsOrIncl(name):
      result.add(name)

proc resolvePackageRoot*(consumerDir, name: string): string =
  ## Resolve ONE declared package name to a checkout next to the consumer.
  ##
  ## PURE: a directory-existence check and nothing else. No daemon, no lock,
  ## no sub-build. That matters because this is reachable from a recipe's
  ## own macro expansion via ``staticExec`` DURING a build -- anything that
  ## took a build lock here could deadlock against the build that spawned
  ## it, and anything slow would be paid by every recipe compile.
  ##
  ## The single source of truth for the resolution: ``declaredPackageRoots``
  ## and the ``internal resolve-package`` subcommand both route through it,
  ## so the path a macro imports and the path the engine puts on ``--path:``
  ## cannot drift apart.
  if consumerDir.len == 0 or name.len == 0:
    return ""
  let candidate = consumerDir.parentDir / name
  if dirExists(extendedPath(candidate)):
    return os.normalizedPath(candidate).replace('\\', '/')

proc declaredPackageRoots*(workDir: string): seq[string] =
  ## Resolve ``declaredPackageDeps`` to sibling checkouts next to the
  ## consumer. A declared dependency that is not checked out is SKIPPED
  ## rather than failing here: the recipe compile that follows reports the
  ## unresolved import with a real file and line, which is a far better
  ## diagnostic than a path-assembly error naming a directory.
  for name in declaredPackageDeps(workDir):
    let resolved = resolvePackageRoot(workDir, name)
    if resolved.len > 0:
      result.add(resolved)

proc reproLibPathFlags(workDir: string): seq[string] =
  ## Build the ``--path:`` flags the engine passes to ``nim c`` when
  ## compiling a project's provider library. Includes:
  ##
  ## 1. ``<workDir>/libs/*/src`` — the consumer repo's own libs.
  ## 2. The reprobuild repo's ``libs/*/src``, located via:
  ##    a. ``$REPROBUILD_LIBS_DIR`` / ``$REPROBUILD_REPO_ROOT`` overrides,
  ##    b. the running ``repro`` binary's location (when it lives inside
  ##       a reprobuild source checkout — the develop-mode default), or
  ##    c. a sibling ``../reprobuild/`` checkout next to the consumer.
  ## 3. (MR14) The source-only sibling dependencies that
  ##    ``reprobuild/config.nims`` registers via ``addPackagePath`` —
  ##    nimcrypto, nim-stew, nim-faststreams, nim-bearssl, etc. The
  ##    recipe-compile (extract_runner) never loads ``config.nims`` so
  ##    those flags have to be reconstructed here, anchored at the
  ##    reprobuild repo root located in step (2).
  ##
  ## Step (2) is the develop-mode sibling-repo detection per
  ## codetracer-specs/Repo-Requirements.md §2.8: the engine ensures
  ## that every recipe that imports ``repro_project_dsl`` / the
  ## reprobuild stdlib packages compiles without the consumer recipe
  ## having to embed the reprobuild repo path. It is also what makes
  ## a one-shot ``repro build`` work in a recorder repo on Windows
  ## without an env.ps1 pre-setup of NIM ``--path``.
  var paths: seq[string] = @[]
  walkLibSrcPathsInto(workDir / "libs", paths)

  # When the consumer's own ``libs/`` IS a reprobuild source tree — the
  # in-tree case where the provider compiles reprobuild's own ``repo.nim``
  # — those working-tree libs are the authoritative copy. Adding a SECOND
  # reprobuild lib root located via ``$REPROBUILD_REPO_ROOT`` /
  # ``$REPROBUILD_LIBS_DIR`` (or the binary location / a sibling checkout)
  # would put a duplicate of every ``repro_*`` module on ``--path``. Nim's
  # module resolution does NOT reliably prefer the first ``--path`` entry
  # when the same logical module exists under two roots, so the external
  # root can SHADOW the working tree — and in a dev shell that external
  # root is a flake-pinned snapshot that can lag the working tree (e.g.
  # pinned to a different branch), silently compiling the recipe against
  # stale stdlib sources. So only consult the external reprobuild root
  # when the consumer does not already provide the reprobuild libs itself.
  var reprobuildLibsRoot = ""
  if workDirIsReprobuildTree(workDir):
    # In-tree: anchor the MR14 sibling source-only flags at the working
    # tree; the working-tree libs are already on ``paths`` above.
    reprobuildLibsRoot = workDir / "libs"
  else:
    # Out-of-tree: the SAME external root ``reproLibSources`` folds into the
    # provider-nimcache key, so ``--path:`` and the freshness key never
    # diverge (that divergence is the harness↔binary fingerprint skew).
    reprobuildLibsRoot = reprobuildExternalLibsRoot(workDir)
    if reprobuildLibsRoot.len > 0:
      walkLibSrcPathsInto(reprobuildLibsRoot, paths)

  # Deduplicate (a consumer repo that happens to symlink reprobuild
  # libs into its own libs/ would otherwise list each path twice).
  var seen = initHashSet[string]()
  for p in paths:
    if not seen.containsOrIncl(p):
      result.add("--path:" & p)
  result.sort(system.cmp[string])

  # MR14 — append the sibling source-only ``--path:`` flags after the
  # reprobuild-libs flags so the standard libs win on ambiguity but
  # imports like ``nimcrypto/sha2`` (added during the Phase-2 migration
  # to ``repro_project_dsl``) still resolve. ``reprobuildLibsRoot`` is
  # ``<reprobuild-root>/libs`` so ``parentDir`` gives the reprobuild
  # repo root the candidate lists are anchored at.
  if reprobuildLibsRoot.len > 0:
    let siblingFlags = bootstrapSiblingPackagePathFlags(
      reprobuildLibsRoot.parentDir, workDir.parentDir)
    for flag in siblingFlags:
      result.add(flag)

  # Declared package dependencies (``uses "<name>"``). Appended LAST so the
  # reprobuild stdlib still wins on ambiguity -- a third-party package must
  # not be able to shadow ``repro_project_dsl`` by shipping a module of the
  # same name.
  #
  # Both the package root and its ``src`` go on the path: the root so the
  # dependency's own ``repro.nim`` -- which is its DSL export surface, the
  # standard Nim way -- can be imported, and ``src`` so the modules that
  # recipe imports resolve too.
  #
  # This is what makes a DSL package usable WITHOUT being vendored into
  # reprobuild's ``libs/``. Before it, the only ways in were to be copied
  # into reprobuild's tree or symlinked there, which privileges the stdlib
  # over third-party packages.
  for depRoot in declaredPackageRoots(workDir):
    result.add("--path:" & depRoot)
    let depSrc = depRoot / "src"
    if dirExists(extendedPath(depSrc)):
      result.add("--path:" & depSrc)

proc normalizedStampPath(path: string): string =
  os.normalizedPath(path).replace('\\', '/')

proc stripNimLineComment(line: string): string =
  let pos = line.find('#')
  if pos >= 0:
    line[0 ..< pos]
  else:
    line

proc splitImportSpecs(text: string): seq[string] =
  var current = ""
  var bracketDepth = 0
  for ch in text:
    case ch
    of '[':
      bracketDepth.inc
      current.add(ch)
    of ']':
      bracketDepth.dec
      current.add(ch)
    of ',':
      if bracketDepth == 0:
        let item = current.strip()
        if item.len > 0:
          result.add(item)
        current.setLen(0)
      else:
        current.add(ch)
    else:
      current.add(ch)
  let item = current.strip()
  if item.len > 0:
    result.add(item)

proc expandImportSpec(spec: string): seq[string] =
  var value = spec.strip()
  if value.len == 0:
    return
  let aliasPos = value.find(" as ")
  if aliasPos >= 0:
    value = value[0 ..< aliasPos].strip()
  if value.startsWith("\"") and value.endsWith("\"") and value.len >= 2:
    value = value[1 .. ^2]
  let openPos = value.find('[')
  let closePos = value.rfind(']')
  if openPos >= 0 and closePos > openPos:
    let prefix = value[0 ..< openPos].strip().strip(chars = {'/'})
    for item in splitImportSpecs(value[openPos + 1 ..< closePos]):
      let suffix = item.strip()
      if suffix.len > 0:
        if prefix.len > 0:
          result.add(prefix & "/" & suffix)
        else:
          result.add(suffix)
  else:
    result.add(value)

proc localNimModulePath(currentFile, projectRoot, spec: string): string =
  if spec.len == 0 or spec.startsWith("std/") or spec == "std" or
      spec.startsWith("pkg/") or spec == "pkg":
    return ""
  var module = spec
  if module.startsWith("./") or module.startsWith("../"):
    module = parentDir(currentFile) / module
  elif module.isAbsolute:
    discard
  else:
    module = projectRoot / module
  if not module.endsWith(".nim") and not module.endsWith(".nims"):
    module.add(".nim")
  module = normalizedStampPath(module)
  let normalizedRoot = normalizedStampPath(projectRoot)
  if module == normalizedRoot or module.startsWith(normalizedRoot & "/"):
    if fileExists(extendedPath(module)):
      return module
  ""

proc nimModulePathInRoot(currentFile, searchRoot, spec: string): string =
  ## TI2 residual fix (b) — resolve a bare/relative import ``spec`` against an
  ## EXTRA search root (an ``extraPaths`` ``--path`` dir), mirroring
  ## ``localNimModulePath`` but anchored at ``searchRoot`` instead of the
  ## module's own project root. Used so a resource module's cross-directory
  ## dependency reachable ONLY via ``extraPaths`` enters the lift source
  ## closure (and thus the ``InterfaceLiftActionKey``), so a content change in
  ## that file re-keys the lift instead of serving a stale artifact.
  if spec.len == 0 or spec.startsWith("std/") or spec == "std" or
      spec.startsWith("pkg/") or spec == "pkg":
    return ""
  # Relative/absolute specs are already resolved by ``localNimModulePath``;
  # here we only resolve the bare ``import somemod`` / ``import a/b`` form that
  # ``--path`` search satisfies.
  if spec.startsWith("./") or spec.startsWith("../") or spec.isAbsolute:
    return ""
  var module = normalizedStampPath(searchRoot) / spec
  if not module.endsWith(".nim") and not module.endsWith(".nims"):
    module.add(".nim")
  module = normalizedStampPath(module)
  let normalizedRoot = normalizedStampPath(searchRoot)
  if (module == normalizedRoot or module.startsWith(normalizedRoot & "/")) and
      fileExists(extendedPath(module)):
    return module
  ""

proc nimImportSpecs(line: string): seq[string] =
  let stripped = stripNimLineComment(line).strip()
  if stripped.startsWith("import "):
    return splitImportSpecs(stripped["import ".len .. ^1])
  if stripped.startsWith("include "):
    return splitImportSpecs(stripped["include ".len .. ^1])
  if stripped.startsWith("from "):
    let rest = stripped["from ".len .. ^1]
    let pos = rest.find(" import ")
    if pos > 0:
      return @[rest[0 ..< pos].strip()]

proc discoverNimSources*(rootModulePath: string;
                         extraRoots: openArray[string] = []): seq[string] =
  ## Enumerate the provider compile's input source set.
  ##
  ## Imports reachable from ``rootModulePath`` are included transitively
  ## (only within the project root, never outside; std/ and pkg/ specs are
  ## ignored). In addition every ``.nim`` file directly in the project
  ## root is included even when it is not currently imported, so that
  ## adding a sibling module to the project invalidates the provider
  ## compile cache: a later edit to ``reprobuild.nim`` might import it,
  ## and Nim's own compilation already treats project-root siblings as
  ## eligible imports. Sibling enumeration is intentionally
  ## non-recursive — subdirectory sources only enter the set through an
  ## explicit import edge.
  ##
  ## TI2 residual fix (b): ``extraRoots`` are additional ``--path`` search
  ## roots (the lift's ``extraPaths``). A bare ``import somemod`` that resolves
  ## into one of these roots is followed transitively (bounded to that root),
  ## so a resource module's cross-directory dependency reachable ONLY via
  ## ``extraPaths`` enters the source closure — and thus the content-addressed
  ## ``InterfaceLiftActionKey``. A change to such a file then re-keys the lift
  ## instead of serving a stale artifact.
  let projectRoot = normalizedStampPath(parentDir(rootModulePath))
  var normalizedExtraRoots: seq[string] = @[]
  for root in extraRoots:
    if root.len > 0:
      let normalized = normalizedStampPath(root)
      if normalized notin normalizedExtraRoots:
        normalizedExtraRoots.add(normalized)
  var pending = @[normalizedStampPath(rootModulePath)]
  var seen = initHashSet[string]()
  while pending.len > 0:
    let path = pending.pop()
    if path in seen:
      continue
    seen.incl(path)
    result.add(path)
    if not fileExists(extendedPath(path)):
      continue
    # The dir the CURRENT file lives in is itself a resolution root for its
    # bare/relative imports (mirrors Nim's own file-relative search), so a
    # module pulled in via ``extraRoots`` can pull its own siblings.
    let currentDir = normalizedStampPath(parentDir(path))
    for line in readFile(extendedPath(path)).splitLines:
      for spec in nimImportSpecs(line):
        for expanded in expandImportSpec(spec):
          let localPath = localNimModulePath(path, projectRoot, expanded)
          if localPath.len > 0 and localPath notin seen:
            pending.add(localPath)
            continue
          # Resolve against the current file's own directory and every extra
          # ``--path`` root, following the bare/relative import out of the
          # project root when (and only when) it lands under one of them.
          for searchRoot in currentDir & normalizedExtraRoots:
            let extraPath = nimModulePathInRoot(path, searchRoot, expanded)
            if extraPath.len > 0 and extraPath notin seen:
              pending.add(extraPath)
              break
  if dirExists(extendedPath(projectRoot)):
    for kind, child in walkDir(projectRoot):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      if not (child.endsWith(".nim") or child.endsWith(".nims")):
        continue
      let normalized = normalizedStampPath(child)
      if normalized notin seen:
        seen.incl(normalized)
        result.add(normalized)
  result.sort(system.cmp[string])

proc walkLibSourcesInto(libsRoot: string; sink: var seq[string];
                        seen: var HashSet[string]) =
  if not dirExists(extendedPath(libsRoot)):
    return
  # NOTE: pass the *non*-extended ``libsRoot`` to ``walkDirRec`` here.
  # On Windows ``walkDirRec`` propagates whatever path it was handed,
  # so feeding it ``\\?\D:\...`` produces ``\\?\D:\...`` children. Those
  # children then survive ``normalizedStampPath`` as ``//?/D:/...`` and
  # the subsequent ``extendedPath`` call re-prefixes them, yielding the
  # invalid ``\\?\\\?\D:\...`` Nim then fails to open. The libs tree is
  # well under MAX_PATH so the raw form is safe.
  for path in walkDirRec(libsRoot):
    if path.endsWith(".nim") or path.endsWith(".nims"):
      let normalized = normalizedStampPath(path)
      if not seen.containsOrIncl(normalized):
        sink.add(normalized)

proc reproLibSources(workDir: string): seq[string] =
  var seen = initHashSet[string]()
  walkLibSourcesInto(workDir / "libs", result, seen)
  # Out-of-tree consumers compile their provider/interface recipes against an
  # EXTERNAL reprobuild libs root (``reproLibPathFlags`` resolves the same
  # root). Fold those sources into the fingerprint so an edit to reprobuild's
  # own libs (e.g. the interface-artifact codec) invalidates the shared
  # provider-nimcache — otherwise the harness reuses a stale compiled
  # ``repro_interface_artifacts`` and emits artifacts the freshly-built
  # ``repro`` binary cannot validate (the harness↔binary fingerprint skew).
  # In-tree (workDir IS reprobuild) this root is empty: the working-tree libs
  # are already covered by the ``workDir / "libs"`` walk above, so reprobuild's
  # own provider compiles are unchanged.
  let externalRoot = reprobuildExternalLibsRoot(workDir)
  if externalRoot.len > 0:
    walkLibSourcesInto(externalRoot, result, seen)

  # Declared package dependencies contribute ``--path:`` entries (see
  # ``reproLibPathFlags``), so their sources MUST fold into this key too.
  # The two are required to stay in lockstep: if a dependency's DSL exports
  # can be imported but editing them does not re-key the provider nimcache,
  # the harness serves a stale compiled recipe -- and that surfaces as the
  # harness<->binary fingerprint skew described above rather than as
  # "my constructor change had no effect".
  #
  # Only the dependency's own ``repro.nim`` and its ``src`` tree are
  # folded in -- not its tests or build outputs, which cannot change what
  # the recipe compiles to.
  for depRoot in declaredPackageRoots(workDir):
    let depRecipe = depRoot / "repro.nim"
    if fileExists(extendedPath(depRecipe)):
      let normalized = normalizedStampPath(depRecipe)
      if not seen.containsOrIncl(normalized):
        result.add(normalized)
    let depSrc = depRoot / "src"
    if dirExists(extendedPath(depSrc)):
      walkLibSourcesInto(depSrc, result, seen)

  result.sort(system.cmp[string])

proc reproLibSourceFingerprint(workDir: string): string =
  let paths = reproLibSources(workDir)
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.lib-sources.v1")
  for path in paths:
    payload.writeString(path)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  toHex(blake3DomainDigest(payload, hdActionFingerprint).bytes)

proc fileStamp(path: string): FileStamp =
  result.path = normalizedStampPath(path)
  if not fileExists(extendedPath(path)) and not dirExists(extendedPath(path)):
    result.kind = fskMissing
    return
  let info = getFileInfo(extendedPath(path), followSymlink = false)
  result.kind =
    case info.kind
    of pcFile, pcLinkToFile:
      fskRegular
    of pcDir, pcLinkToDir:
      fskDirectory
  result.sizeBytes = uint64(max(info.size, 0))
  let mtime = info.lastWriteTime
  result.mtimeNs = uint64(mtime.toUnix) * 1_000_000_000'u64 +
    uint64(mtime.nanosecond)

proc cacheableWarmEvidence(stamp: FileStamp): bool =
  stamp.kind == fskRegular

proc readInterfaceArtifactWithWarm(path: string): ProjectInterfaceArtifact =
  let evidence = fileStamp(path)
  if processWarmInterfaceArtifacts.hasKey(path):
    let warm = processWarmInterfaceArtifacts[path]
    if cacheableWarmEvidence(evidence) and warm.evidence == evidence:
      inc processWarmInterfaceStats.artifactWarmHits
      return warm.artifact
    inc processWarmInterfaceStats.artifactWarmMisses
  else:
    inc processWarmInterfaceStats.artifactColdReads
  result = readInterfaceArtifact(path)
  if cacheableWarmEvidence(evidence):
    processWarmInterfaceArtifacts[path] = WarmProjectInterfaceArtifact(
      evidence: evidence,
      artifact: result)

proc fileStamps(paths: openArray[string]): seq[FileStamp] =
  for path in paths:
    result.add(fileStamp(path))
  result.sort do (a, b: FileStamp) -> int:
    cmp(a.path, b.path)

proc restampRecordedInputs(stamps: openArray[FileStamp]): seq[FileStamp] =
  for stamp in stamps:
    result.add(fileStamp(stamp.path))
  result.sort do (a, b: FileStamp) -> int:
    cmp(a.path, b.path)

proc immutableStorePath(path: string): bool =
  normalizedStampPath(path).startsWith("/nix/store/")

proc reproLibStampsForCache(workDir: string): seq[FileStamp] =
  if immutableStorePath(workDir):
    return @[]
  fileStamps(reproLibSources(workDir))

proc interfaceLiftSources(modulePath, resourceModule: string;
                          extraPaths: openArray[string] = []): seq[string] =
  ## The full source closure a lift compiles: the producer's own module
  ## closure plus, when a producer declares a separate resource module (TI1),
  ## that module's closure. Both feed the extraction fingerprint so a
  ## resource-module edit re-keys the lift.
  ##
  ## TI2 residual fix (b): ``extraPaths`` are threaded into the source-closure
  ## walk so a resource module's cross-directory dependency reachable ONLY via
  ## an extra ``--path`` is discovered (with its CONTENT), not just named by
  ## basename. A change to such a file re-keys the lift.
  result = discoverNimSources(modulePath, extraPaths).mapIt(
    normalizedStampPath(it))
  if resourceModule.len > 0:
    for src in discoverNimSources(resourceModule, extraPaths):
      let normalized = normalizedStampPath(src)
      if normalized notin result:
        result.add(normalized)

proc interfaceExtractionContext(modulePath: string;
                                workDir = getCurrentDir();
                                includeReproLibFingerprint = true;
                                resourceModule = "";
                                extraPaths: openArray[string] = []):
    InterfaceExtractionContext =
  let sources = interfaceLiftSources(modulePath, resourceModule, extraPaths)
  var libPathFlags = reproLibPathFlags(workDir)
  # TI1: the producer's declared resource module + extra ``--path``s are part
  # of the lift's input identity — a change to the extra path set re-keys the
  # extraction (a different resource module resolves a different closure).
  if resourceModule.len > 0:
    libPathFlags.add("--resource-module:" & normalizedStampPath(resourceModule))
  for extra in extraPaths:
    if extra.len > 0:
      libPathFlags.add("--path:" & normalizedStampPath(extra))
  InterfaceExtractionContext(
    modulePath: normalizedStampPath(modulePath),
    workDir: normalizedStampPath(workDir),
    nimCompiler: nimCompilerPath(),
    libPathFlags: libPathFlags,
    reproLibFingerprint:
      if includeReproLibFingerprint: reproLibSourceFingerprint(workDir)
      else: "",
    sources: sources)

proc interfaceExtractionCacheContext(modulePath: string;
                                     workDir = getCurrentDir();
                                     resourceModule = "";
                                     extraPaths: openArray[string] = []):
    InterfaceExtractionContext =
  var libPathFlags =
    if immutableStorePath(workDir): @[]
    else: reproLibPathFlags(workDir)
  if resourceModule.len > 0:
    libPathFlags.add("--resource-module:" & normalizedStampPath(resourceModule))
  for extra in extraPaths:
    if extra.len > 0:
      libPathFlags.add("--path:" & normalizedStampPath(extra))
  InterfaceExtractionContext(
    modulePath: normalizedStampPath(modulePath),
    workDir: normalizedStampPath(workDir),
    nimCompiler: nimCompilerPath(),
    libPathFlags: libPathFlags,
    reproLibFingerprint: "",
    sources: @[])

proc interfaceContextsMatchForCache(a, b: InterfaceExtractionContext): bool =
  a.modulePath == b.modulePath and
    a.workDir == b.workDir and
    a.nimCompiler == b.nimCompiler and
    (a.libPathFlags == b.libPathFlags or immutableStorePath(a.workDir))

proc interfaceExtractionFingerprint(context: InterfaceExtractionContext):
    ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.interfaceExtract.v1")
  payload.writeString(context.modulePath)
  payload.writeString(context.workDir)
  payload.writeString(context.nimCompiler)
  payload.writeStringSeq(context.libPathFlags)
  payload.writeString(context.reproLibFingerprint)
  for path in context.sources:
    payload.writeString(path)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  blake3DomainDigest(payload, hdActionFingerprint)

proc interfaceExtractionFingerprint*(modulePath: string;
                                     workDir = getCurrentDir()): ContentDigest =
  interfaceExtractionFingerprint(interfaceExtractionContext(modulePath, workDir))

proc interfaceExtractionCachePath(artifactPath: string): string =
  artifactPath & ".inputs"

proc interfaceExtractionMetadataPath(artifactPath: string): string =
  artifactPath & ".inputs.meta"

proc interfaceLiftActionKeyPath*(artifactPath: string): string =
  ## TI1: the sidecar recording the ``InterfaceLiftActionKey`` an artifact was
  ## materialized under, so a second lift with an unchanged input closure is a
  ## cache HIT without re-running the lift edge.
  artifactPath & ".liftkey"

proc writeInterfaceExtractionCacheRecord(artifactPath: string;
    context: InterfaceExtractionContext; fingerprint: ContentDigest) =
  let record = InterfaceExtractionCacheRecord(
    context: context,
    sourceStamps: fileStamps(context.sources),
    reproLibStamps: reproLibStampsForCache(context.workDir),
    inputFingerprint: fingerprint)
  try:
    let metadataPath = interfaceExtractionMetadataPath(artifactPath)
    writeFile(extendedPath(metadataPath),
      toByteString(encodeInterfaceExtractionCacheRecord(record)))
    let evidence = fileStamp(metadataPath)
    if cacheableWarmEvidence(evidence):
      processWarmInterfaceMetadata[metadataPath] =
        WarmInterfaceExtractionCacheRecord(
          evidence: evidence,
          record: record)
  except CatchableError:
    discard

proc readInterfaceExtractionCacheRecord(path: string):
    tuple[record: Option[InterfaceExtractionCacheRecord];
          warmHitAccounted: bool] =
  let evidence = fileStamp(path)
  if evidence.kind == fskMissing:
    return (none(InterfaceExtractionCacheRecord), false)
  if processWarmInterfaceMetadata.hasKey(path):
    let warm = processWarmInterfaceMetadata[path]
    if cacheableWarmEvidence(evidence) and warm.evidence == evidence:
      inc processWarmInterfaceStats.metadataWarmHits
      return (some(warm.record), true)
    inc processWarmInterfaceStats.metadataWarmMisses
  else:
    inc processWarmInterfaceStats.metadataColdReads
  try:
    let record =
      decodeInterfaceExtractionCacheRecord(fromByteString(readFile(extendedPath(path))))
    if cacheableWarmEvidence(evidence):
      processWarmInterfaceMetadata[path] =
        WarmInterfaceExtractionCacheRecord(
          evidence: evidence,
          record: record)
    return (some(record), false)
  except CatchableError:
    return (none(InterfaceExtractionCacheRecord), false)

proc cachedInterfaceArtifactByMetadata(artifactPath, stubPath: string;
                                       context: InterfaceExtractionContext;
                                       requireStub = true):
    Option[ProjectInterfaceArtifact] =
  if not fileExists(extendedPath(artifactPath)):
    return none(ProjectInterfaceArtifact)
  if requireStub and not fileExists(extendedPath(stubPath)):
    return none(ProjectInterfaceArtifact)
  let lookup = readInterfaceExtractionCacheRecord(
    interfaceExtractionMetadataPath(artifactPath))
  if lookup.record.isNone:
    return none(ProjectInterfaceArtifact)
  let cached = lookup.record.get()
  if not interfaceContextsMatchForCache(cached.context, context):
    return none(ProjectInterfaceArtifact)
  processWarmInterfaceStats.metadataRevalidatedSources +=
    cached.sourceStamps.len
  if cached.sourceStamps != restampRecordedInputs(cached.sourceStamps):
    return none(ProjectInterfaceArtifact)
  processWarmInterfaceStats.metadataRevalidatedReproLibs +=
    cached.reproLibStamps.len
  if cached.reproLibStamps != restampRecordedInputs(cached.reproLibStamps):
    return none(ProjectInterfaceArtifact)
  try:
    let artifact = readInterfaceArtifactWithWarm(artifactPath)
    if artifact.interfaceFingerprint != cached.inputFingerprint:
      return none(ProjectInterfaceArtifact)
    if not lookup.warmHitAccounted:
      inc processWarmInterfaceStats.metadataWarmHits
    return some(artifact)
  except CatchableError:
    return none(ProjectInterfaceArtifact)

proc cachedInterfaceArtifactByFingerprint(artifactPath, stubPath: string;
                                          fingerprint: ContentDigest;
                                          requireStub = true):
    Option[ProjectInterfaceArtifact] =
  let cachePath = interfaceExtractionCachePath(artifactPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(cachePath))):
    return none(ProjectInterfaceArtifact)
  if requireStub and not fileExists(extendedPath(stubPath)):
    return none(ProjectInterfaceArtifact)
  if readFile(extendedPath(cachePath)).strip() != toHex(fingerprint.bytes):
    return none(ProjectInterfaceArtifact)
  try:
    let artifact = readInterfaceArtifactWithWarm(artifactPath)
    inc processWarmInterfaceStats.metadataWarmHits
    return some(artifact)
  except CatchableError:
    return none(ProjectInterfaceArtifact)

proc interfaceExtractionCacheProbe(modulePath, artifactPath, stubPath: string;
                                   workDir: string;
                                   requireStub: bool;
                                   resourceModule: string;
                                   extraPaths: openArray[string]):
    tuple[artifact: Option[ProjectInterfaceArtifact];
          fingerprintContext: InterfaceExtractionContext;
          inputFingerprint: ContentDigest] =
  ## The two-stage warm check every interface extraction performs before it
  ## considers compiling anything: a cheap metadata/stamp revalidation, then
  ## a content fingerprint.
  ##
  ## Factored out of ``extractInterfaceFromModule`` so the engine-side caller
  ## can ask the SAME question without spawning the extraction edge — the
  ## edge costs a process launch plus io-monitor wiring, which is pure
  ## overhead on the overwhelmingly common warm path. The returned
  ## fingerprint context is handed back so a MISS does not pay for hashing
  ## every source a second time inside the extractor.
  let extractionContext = interfaceExtractionCacheContext(modulePath, workDir,
    resourceModule, extraPaths)
  let metadataCached = cachedInterfaceArtifactByMetadata(artifactPath,
    stubPath, extractionContext, requireStub)
  if metadataCached.isSome:
    result.artifact = metadataCached
    return

  result.fingerprintContext = interfaceExtractionContext(modulePath, workDir,
    includeReproLibFingerprint = true, resourceModule = resourceModule,
    extraPaths = extraPaths)
  result.inputFingerprint =
    interfaceExtractionFingerprint(result.fingerprintContext)
  let cached = cachedInterfaceArtifactByFingerprint(artifactPath, stubPath,
    result.inputFingerprint, requireStub)
  if cached.isSome:
    writeInterfaceExtractionCacheRecord(artifactPath,
      result.fingerprintContext, result.inputFingerprint)
    result.artifact = cached

## There is deliberately no exported "is the interface already fresh?" probe
## here. One existed (``cachedInterfaceArtifact``) so ``repro_cli_support``
## could short-circuit the extraction EDGE, and it was UNSOUND: its key is an
## import walk of the recipe's TEXT, which cannot see a dependency the recipe
## acquires during macro expansion, so editing such a file left it warm and
## served a stale interface behind a green build. The engine decides whether
## the edge re-runs, from the monitored read set. See ``extractInterfaceEdge``
## in ``repro_cli_support`` and Compiles-Are-Normal-Edges.md.
##
## ``interfaceExtractionCacheProbe`` above is retained for the in-process
## ``extractInterfaceFromModule`` path (tests, bootstrap, and the temp-root
## solver probe), which has no engine to defer to.

proc interfaceExtractionOutputs*(artifactPath, stubPath: string): seq[string] =
  ## Every file one interface extraction writes and that a later run reads
  ## back — the artifact, the Nim stub, and the two freshness sidecars.
  ##
  ## All four must be DECLARED outputs of the extraction edge. Declaring only
  ## the artifact would make a cache hit restore a file whose sidecars are
  ## absent, so the in-process freshness probe would miss and every direct
  ## (non-edge) caller would re-extract — a silent loss of the cache rather
  ## than an error.
  result = @[artifactPath]
  if stubPath.len > 0:
    result.add(stubPath)
  result.add(interfaceExtractionCachePath(artifactPath))
  result.add(interfaceExtractionMetadataPath(artifactPath))

proc firstExistingPrefix(candidates: openArray[string]; header: string;
                         libraryNames: openArray[string]): string =
  proc hasLibrary(prefix, libraryName: string): bool =
    let exact = prefix / "lib" / libraryName
    if fileExists(extendedPath(exact)):
      return true
    let dot = libraryName.find('.')
    let stem =
      if dot > 0:
        libraryName[0 ..< dot]
      else:
        libraryName
    if not dirExists(extendedPath(prefix / "lib")):
      return false
    for kind, path in walkDir(extendedPath(prefix / "lib")):
      if kind == pcFile:
        let tail = splitPath(path).tail
        if tail == libraryName or tail.startsWith(stem & "."):
          return true

  for prefix in candidates:
    if prefix.len == 0:
      continue
    if not fileExists(extendedPath(prefix / header)):
      continue
    for libraryName in libraryNames:
      if hasLibrary(prefix, libraryName):
        return prefix
  ""

proc nixLibFile(prefix, libraryName: string): string =
  ## The actual library file under ``prefix/lib`` matching ``libraryName``
  ## (exact, or ``<stem>.*`` for a versioned soname), or "" — mirrors the
  ## resolution in ``firstExistingPrefix.hasLibrary`` but returns the file.
  let libDir = prefix / "lib"
  let exact = libDir / libraryName
  if fileExists(extendedPath(exact)):
    return exact
  let dot = libraryName.find('.')
  let stem =
    if dot > 0: libraryName[0 ..< dot]
    else: libraryName
  if not dirExists(extendedPath(libDir)):
    return ""
  for kind, path in walkDir(extendedPath(libDir)):
    if kind == pcFile:
      let tail = splitPath(path).tail
      if tail == libraryName or tail.startsWith(stem & "."):
        return path
  ""

proc soMatchesHostArch(libFile: string): bool =
  ## Guard ``nixPrefix``'s ``/nix/store`` glob against picking a
  ## wrong-architecture build. The fleet's shared store holds BOTH x86-64 and
  ## aarch64 copies of libraries like xxHash under indistinguishable
  ## ``*-xxHash-*`` store-path names, so a bare glob can return the aarch64
  ## ``libxxhash.so`` on an x86-64 runner — the extract-runner link then fails
  ## with ``ld: … libxxhash.so is incompatible with elf64-x86-64``. Reject an
  ## ELF whose machine differs from the build host. A non-ELF file (macOS
  ## Mach-O ``.dylib``), a static archive (``.a``), or an unreadable/short file
  ## is treated as a match — let the platform/linker decide.
  var f: File
  if not open(f, extendedPath(libFile)):
    return true
  defer: close(f)
  var hdr: array[20, byte]
  if readBytes(f, hdr, 0, 20) < 20:
    return true
  if not (hdr[0] == 0x7F'u8 and hdr[1] == byte('E') and
          hdr[2] == byte('L') and hdr[3] == byte('F')):
    return true                       # not ELF -> not our concern
  if hdr[5] != 1'u8:                   # EI_DATA: only handle little-endian
    return true
  let eMachine = uint16(hdr[18]) or (uint16(hdr[19]) shl 8)
  const
    EM_X86_64 = 0x3E'u16
    EM_AARCH64 = 0xB7'u16
  let hostMachine =
    when hostCPU == "amd64": EM_X86_64
    elif hostCPU == "arm64": EM_AARCH64
    else: 0'u16
  if hostMachine == 0'u16:
    return true                       # unknown host arch -> don't reject
  eMachine == hostMachine

proc nixPrefix(namePattern, header: string;
               libraryNames: openArray[string]): string =
  if not dirExists(extendedPath("/nix/store")):
    return ""
  let needle = namePattern.replace("*", "")
  # TODO(win-longpath): walk results escape; needs review
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    let tail = splitPath(path).tail
    if needle.len > 0 and tail.find(needle) < 0:
      continue
    if not fileExists(extendedPath(path / header)):
      continue
    for libraryName in libraryNames:
      let lib = nixLibFile(path, libraryName)
      # Skip a store build whose library is for the wrong architecture — the
      # shared store holds both x86-64 and aarch64 copies under the same
      # ``*-xxHash-*`` name and this glob would otherwise pick either one.
      if lib.len > 0 and soMatchesHostArch(lib):
        return path
  ""

const InterfaceLibSubdirs = [
  "lib",
  "lib64",
  "lib/x86_64-linux-gnu",
  "lib/aarch64-linux-gnu",
]
  ## Mirror of `config.nims`'s `LibSubdirs`: the standard lib subdirectories
  ## a `-L` search must probe (plain `lib`, `lib64`, Debian-multiarch triples)
  ## so a bare prefix like `/usr` resolves regardless of host layout.

proc firstExistingPrefixLibDir(prefix: string;
                               dylibNames: openArray[string]): string =
  ## Mirror of `config.nims`'s `firstExistingPrefixLibDir`: return the
  ## absolute libdir under `prefix` that holds one of `dylibNames`, or "".
  for libSub in InterfaceLibSubdirs:
    let candidate = prefix / libSub
    for dylibName in dylibNames:
      if fileExists(extendedPath(candidate / dylibName)):
        return candidate
  ""

proc firstExistingLibDir(candidates: openArray[string];
                         dylibNames: openArray[string]): string =
  ## Mirror of `config.nims`'s `firstExistingLibDir`: probe each candidate
  ## directly (it may already be a libdir like `/usr/lib64`) and then walk
  ## the standard lib subdirectories so a candidate like `/usr` resolves on
  ## `/usr/lib`, `/usr/lib64`, or a Debian-multiarch host.
  for candidate in candidates:
    let path = candidate.strip()
    if path.len == 0:
      continue
    for dylibName in dylibNames:
      if fileExists(extendedPath(path / dylibName)):
        return path
    let resolved = firstExistingPrefixLibDir(path, dylibNames)
    if resolved.len > 0:
      return resolved
  ""

proc nixLibDir(namePattern: string; dylibNames: openArray[string]): string =
  ## Mirror of `config.nims`'s `nixLibDir`: scan `/nix/store` for a store
  ## path matching `namePattern` whose libdir holds one of `dylibNames`.
  if not dirExists(extendedPath("/nix/store")):
    return ""
  let needle = namePattern.replace("*", "")
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    let tail = splitPath(path).tail
    if needle.len > 0 and tail.find(needle) < 0:
      continue
    let libDir = firstExistingLibDir([path], dylibNames)
    if libDir.len > 0:
      return libDir
  ""

proc addExternalPackagePath(flags: var seq[string]; workDir, envName: string;
                            candidates: openArray[string]; marker: string) =
  ## Replay one of ``config.nims``'s ``addPackagePath`` resolutions as an
  ## explicit ``--path`` flag. ``config.nims`` resolves each third-party /
  ## sibling-repo package by checking ``getEnv(envName)`` first and then a
  ## list of candidate directories, gating each on a marker file so a stale or
  ## wrong directory is never added. We mirror that exact logic here.
  ##
  ## This is required because the interface-extraction runner and the per-
  ## project provider binary are compiled from a scratch tree that lives
  ## OUTSIDE reprobuild (under ``<project>/.repro/...`` for dev-env, under the
  ## build out-dir otherwise). Nim only evaluates reprobuild's ``config.nims``
  ## when the compiled main module sits inside reprobuild's directory tree (the
  ## project-config parent walk); for an arbitrary project it does not, so the
  ## ``--path`` switches ``config.nims`` would have added (e.g. ``NIMCRYPTO_SRC``
  ## for ``nimcrypto/sha2``, pulled in transitively by ``repro_project_dsl``)
  ## are missing and the compile fails with ``cannot open file: nimcrypto/sha2``.
  ## ``externalHashFlags`` replays ``config.nims``'s C-library flags for the same
  ## reason; this helper extends that to the Nim package source paths.
  ##
  ## Candidate paths are resolved relative to ``workDir`` (the
  ## ``reprobuildLibraryWorkDir``) so they match ``config.nims``'s
  ## reprobuild-root-relative candidates regardless of the compile's cwd.
  let resolve = proc(path: string): string =
    if path.len == 0 or path.isAbsolute: path else: workDir / path
  let envPath = getEnv(envName)
  if envPath.len > 0 and fileExists(extendedPath(envPath / marker)):
    flags.add("--path:" & envPath)
    return
  for candidate in candidates:
    let resolved = resolve(candidate)
    if fileExists(extendedPath(resolved / marker)):
      flags.add("--path:" & resolved)
      return

proc reproPackagePathFlags(workDir: string): seq[string] =
  ## Replay the third-party / sibling-repo package ``--path`` switches that
  ## reprobuild's ``config.nims`` adds via ``addPackagePath``. Kept byte-for-byte
  ## in sync with the ``addPackagePath(...)`` block in ``config.nims``; when a
  ## package is added or its candidate list changes there, update it here too.
  ## (reprobuild's OWN ``libs/*/src`` tree is replayed separately by
  ## ``reproLibPathFlags``; this helper covers only the out-of-tree packages.)
  if workDir.len == 0:
    return
  let ctRunnerAdapter = resolveCtTestRunnerAdapterPath(workDir)
  if ctRunnerAdapter.len > 0:
    result.add("--path:" & ctRunnerAdapter)
  result.addExternalPackagePath(workDir, "REPRO_TEST_ADAPTERS_SRC", [
    ".." / "reprobuild-test-adapters" / "src",
  ], "repro_test_adapters" / "test_runner.nim")
  result.addExternalPackagePath(workDir, "FASTSTREAMS_SRC", [
    "libs" / "nim-faststreams" / "src",
    ".." / "codetracer" / "libs" / "nim-faststreams",
    ".." / "nim-faststreams",
  ], "faststreams" / "inputs.nim")
  result.addExternalPackagePath(workDir, "NIM_STEW_SRC", [
    "libs" / "nim-stew" / "src",
    ".." / "codetracer" / "libs" / "nim-stew",
    ".." / "nim-stew",
  ], "stew" / "objects.nim")
  result.addExternalPackagePath(workDir, "NIM_SERIALIZATION_SRC", [
    "libs" / "nim-serialization" / "src",
    ".." / "codetracer" / "libs" / "nim-serialization",
    ".." / "nim-serialization",
  ], "serialization" / "case_objects.nim")
  result.addExternalPackagePath(workDir, "NIM_JSON_SERIALIZATION_SRC", [
    "libs" / "nim-json-serialization" / "src",
    ".." / "codetracer" / "libs" / "nim-json-serialization",
    ".." / "nim-json-serialization",
  ], "json_serialization.nim")
  result.addExternalPackagePath(workDir, "NIM_TOML_SERIALIZATION_SRC", [
    "libs" / "nim-toml-serialization" / "src",
    ".." / "codetracer" / "libs" / "nim-toml-serialization",
    ".." / "nim-toml-serialization",
  ], "toml_serialization.nim")
  result.addExternalPackagePath(workDir, "SSZ_SERIALIZATION_SRC", [
    "libs" / "nim-ssz-serialization" / "src",
    ".." / "nim-ssz-serialization",
  ], "ssz_serialization.nim")
  result.addExternalPackagePath(workDir, "NIMCRYPTO_SRC", [
    # Vendored source-only slice under reprobuild's own libs/, listed
    # first so the recipe-compile is self-contained and does not depend on
    # a consumer's sibling nimcrypto checkout. Mirrors config.nims. Marker
    # is nimcrypto/hash.nim.
    "libs" / "nimcrypto",
    ".." / "codetracer" / "libs" / "nimcrypto",
    ".." / "nimcrypto",
  ], "nimcrypto" / "hash.nim")
  result.addExternalPackagePath(workDir, "BEARSSL_SRC", [
    ".." / "nim-bearssl",
    "libs" / "nim-bearssl",
  ], "bearssl.nim")
  result.addExternalPackagePath(workDir, "RESULTS_SRC", [
    "libs" / "results" / "src",
  ], "results.nim")
  result.addExternalPackagePath(workDir, "STINT_SRC", [
    "libs" / "stint" / "src",
  ], "stint.nim")
  result.addExternalPackagePath(workDir, "REPRO_TEST_ADAPTERS_SRC", [
    ".." / "reprobuild-test-adapters" / "src",
  ], "repro_test_adapters" / "test_runner.nim")

type RuntimeLinkTarget* = enum
  rltWindows
  rltLinux
  rltDarwin
  rltOtherPosix

proc runtimeRpathCompilerFlags*(runtimeDirs: openArray[string];
                                target: RuntimeLinkTarget): seq[string] =
  ## Build linker flags for binaries compiled by reprobuild itself after
  ## installation. Keep this target-parameterized so a Linux test can verify
  ## Darwin argv shape: ld64 requires one LC_RPATH option per directory,
  ## whereas GNU ld accepts a colon-delimited DT_RPATH value.
  var uniqueDirs: seq[string] = @[]
  for libDir in runtimeDirs:
    if libDir.len > 0 and libDir notin uniqueDirs:
      uniqueDirs.add(libDir)
  case target
  of rltWindows:
    discard
  of rltLinux:
    if uniqueDirs.len > 0:
      result.add("--passL:-Wl,--disable-new-dtags")
      result.add("--passL:-Wl,-rpath," & uniqueDirs.join(":"))
  of rltDarwin, rltOtherPosix:
    for libDir in uniqueDirs:
      result.add("--passL:-Wl,-rpath," & libDir)

proc hostRuntimeLinkTarget(): RuntimeLinkTarget =
  when defined(windows):
    rltWindows
  elif defined(linux):
    rltLinux
  elif defined(macosx):
    rltDarwin
  else:
    rltOtherPosix

proc stageHostDynlibsBesideBinary*(destDir: string): seq[string]
    {.discardable.} =
  ## Windows: copy the dynlibs sitting next to the RUNNING reprobuild
  ## executable into ``destDir``, so a binary reprobuild compiled for itself
  ## into a scratch directory can load them.
  ##
  ## Every non-system library reprobuild uses on Windows is dlopen'd by leaf
  ## name (``clingo.dll``, ``libzstd.dll``, ``sqlite3_64.dll``, the OpenSSL
  ## pair) rather than linked through the import table. Win32's LoadLibrary
  ## searches the .exe's OWN directory first and PATH last — and the .exe here
  ## is not ``repro.exe`` but the helper reprobuild just compiled into a temp
  ## or scratch tree, whose directory contains no DLLs at all. So the loader
  ## falls through to PATH, and the helper starts only on hosts that happen to
  ## carry clingo there.
  ##
  ## That "happens to" is the bug this closes: ``repro_solver``'s clingo
  ## binding is resolved at MODULE INIT, before ``main``, so on a host without
  ## clingo on PATH the helper aborts with ``could not load: clingo.dll``
  ## before running a single line of its own code — which is what an installed
  ## repro looks like to a user who never provisioned a dev environment.
  ##
  ## Copying rather than prepending the app dir to the child's ``PATH`` is
  ## deliberate. Reprobuild goes out of its way NOT to leak its own library
  ## directories into the environment of the actions it runs (see the
  ## ``LD_LIBRARY_PATH`` / ``DYLD_*`` reasoning in ``externalHashFlags`` and
  ## ``repro_provider_runtime/runtime.nim``); a PATH edit would put reprobuild's
  ## OpenSSL and sqlite ahead of whatever the user's own build actions resolve,
  ## which is exactly the kind of ambient influence hermeticity forbids. A copy
  ## is scoped to the one directory that needs it.
  ##
  ## Returns the leaf names staged, so callers and tests can assert coverage.
  ## Failures to copy an individual DLL are non-fatal: the loader error the
  ## helper raises later is more specific than anything we could report here.
  when defined(windows):
    let appDir = parentDir(getAppFilename())
    if appDir.len == 0 or destDir.len == 0:
      return @[]
    # Nothing to do when the helper already lives beside the app's DLLs;
    # copyFile onto itself would truncate the source.
    if cmpPaths(absolutePath(appDir), absolutePath(destDir)) == 0:
      return @[]
    for kind, path in walkDir(appDir):
      if kind != pcFile or not path.toLowerAscii.endsWith(".dll"):
        continue
      let leaf = extractFilename(path)
      let dest = destDir / leaf
      try:
        # Skip an already-staged copy of the same size. The provider scratch
        # dir persists across builds, so re-copying ~12 MB of DLLs on every
        # provider compile would be pure overhead.
        if fileExists(extendedPath(dest)) and
           getFileSize(extendedPath(dest)) == getFileSize(extendedPath(path)):
          result.add(leaf)
          continue
        copyFile(path, dest)
        result.add(leaf)
      except CatchableError:
        discard
  else:
    # POSIX resolves these through DT_RUNPATH / LC_RPATH baked in at link time
    # by `runtimeRpathCompilerFlags`, so there is nothing to stage.
    discard

proc externalHashFlags(workDir = ""): seq[string] =
  # Windows: there is no homebrew/nix prefix that ships libblake3 or libxxhash.
  # The reprobuild repo vendors portable C sources for both inside the
  # package-local source trees, and config.nims wires the include paths +
  # `{.compile:.}` pragmas accordingly. When repro is run as a CLI against an
  # arbitrary project, the project's nim invocation does NOT pick up
  # reprobuild's config.nims (different working directory), so we have to
  # propagate the same define/include flags here. The vendored sources live
  # alongside the reprobuild library tree, so resolve the include dirs relative
  # to workDir (which is the reprobuildLibraryWorkDir).
  # Installed wrappers publish this build-time-only search path. It is never
  # assigned to LD_LIBRARY_PATH/DYLD_*: those variables would leak package
  # libraries into arbitrary user actions. Instead, bake the package's
  # complete runtime closure into the two binaries reprobuild compiles for
  # itself after installation (the interface runner and project provider).
  result.add(runtimeRpathCompilerFlags(
    getEnv("REPROBUILD_RUNTIME_LIBRARY_PATH").split(PathSep),
    hostRuntimeLinkTarget()))

  when defined(windows):
    # M9.R.13b.1 — propagate `--define:reproVendoredHash` so the vendored
    # path in `blake3.nim` / `xxh3.nim` (a `when defined(reproVendoredHash):
    # {.compile: ...c.}` block guarding the inclusion of the portable C
    # implementations) actually fires when the interface-extract runner
    # and the provider compile run outside the reprobuild project's
    # `config.nims` scope. Without this define the runner picks up only
    # the `-I` include flags below — `xxh3/capi.c` resolves `XXH3_64bits`
    # through `xxhash.h` but no implementation translation unit is
    # compiled, so the link step fails with `undefined reference to
    # XXH3_64bits` / `XXH3_64bits_withSeed` (the symptom that blocked the
    # wayland from-source smoke at the interface-extract LINK stage,
    # M9.R.13a → M9.R.13b handover). The non-Windows branch below
    # delegates to system-installed libblake3 / libxxhash via `-L` + `-l`
    # so it doesn't need the define; Windows has no such system install
    # so the vendored path is the only one available.
    let envSystem = getEnv("REPROBUILD_USE_SYSTEM_HASH_LIBS").toLowerAscii()
    let useSystem = envSystem in ["1", "true", "yes", "on"]
    if workDir.len > 0:
      let blake3Inc = workDir / "libs" / "blake3" / "src" / "blake3" /
        "vendor"
      let xxhashInc = workDir / "libs" / "xxh3" / "src" / "xxh3" /
        "vendor"
      if fileExists(extendedPath(blake3Inc / "blake3.h")):
        result.add("--passC:-I" & blake3Inc)
      if fileExists(extendedPath(xxhashInc / "xxhash.h")):
        result.add("--passC:-I" & xxhashInc)
      if not useSystem and
         fileExists(extendedPath(blake3Inc / "blake3.c")) and
         fileExists(extendedPath(xxhashInc / "xxhash.c")):
        # Mirror `config.nims`'s `switch("define", "reproVendoredHash")`
        # for the runner / provider compile so the `{.compile:.}` pragmas
        # in `blake3.nim` / `xxh3.nim` fire and the vendored C sources
        # land in the link.
        result.add("--define:reproVendoredHash")
        result.add("--passC:-DREPRO_VENDORED_HASH")
    return

  let blake3Prefix = block:
    let direct = firstExistingPrefix(
      [getEnv("BLAKE3_PREFIX"), "/opt/homebrew/opt/blake3",
        "/usr/local/opt/blake3"],
      "include/blake3.h",
      ["libblake3.dylib", "libblake3.so", "libblake3.a"])
    if direct.len > 0:
      direct
    else:
      nixPrefix("*-libblake3-*", "include/blake3.h",
        ["libblake3.dylib", "libblake3.so", "libblake3.a"])
  if blake3Prefix.len > 0:
    result.add("--passC:-I" & (blake3Prefix / "include"))
    result.add("--passL:-L" & (blake3Prefix / "lib"))
    result.add("--passL:-lblake3")

  let xxhashPrefix = block:
    let direct = firstExistingPrefix(
      [getEnv("XXHASH_PREFIX"), "/opt/homebrew/opt/xxhash",
        "/usr/local/opt/xxhash"],
      "include/xxhash.h",
      ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
    if direct.len > 0:
      direct
    else:
      nixPrefix("*-xxHash-*", "include/xxhash.h",
        ["libxxhash.dylib", "libxxhash.so", "libxxhash.a"])
  if xxhashPrefix.len > 0:
    result.add("--passC:-I" & (xxhashPrefix / "include"))
    result.add("--passL:-L" & (xxhashPrefix / "lib"))
    result.add("--passL:-lxxhash")

  # repro's own ASP solver (repro_solver) dlopens libclingo at module-init
  # time through a ``{.dynlib.}`` const. When repro runs as a CLI against an
  # arbitrary project, the extract_runner links repro's DSL (which pulls in
  # the solver), so the runner must resolve libclingo at runtime regardless
  # of whether the *host project's* environment provisions it. Replay
  # clingo's lib dir the same way blake3/xxhash are replayed so the runner
  # is self-contained instead of depending on the caller's NIX_LDFLAGS /
  # dyld search path. clingo is dlopened, not linked, so no ``-lclingo`` and
  # no ``-I`` (the bindings are header-free); the ``-L`` search dir plus an
  # ``-rpath`` are both required — on macOS ``-L`` alone does not let the
  # baked dlopen find the library (verified), the rpath is what resolves it.
  let clingoPrefix = block:
    let direct = firstExistingPrefix(
      [getEnv("CLINGO_PREFIX"), "/opt/homebrew/opt/clingo",
        "/usr/local/opt/clingo"],
      "include/clingo.h",
      ["libclingo.dylib", "libclingo.so"])
    if direct.len > 0:
      direct
    else:
      nixPrefix("*-clingo-*", "include/clingo.h",
        ["libclingo.dylib", "libclingo.so"])
  if clingoPrefix.len > 0:
    result.add("--passL:-L" & (clingoPrefix / "lib"))
    result.add("--passL:-Wl,-rpath," & (clingoPrefix / "lib"))

  # sqlite: `config.nims`'s non-Windows/non-macOS block links `-lsqlite3`
  # (pulled in transitively by the cas / lock store deps that
  # `repro_project_dsl` drags in) and adds the resolving `-L` + `-rpath`.
  # The provider-compile / interface-extract edge emits the `-lsqlite3`
  # via those transitive deps but, before this block, added no `-L`, so the
  # link failed with `ld: cannot find -lsqlite3` (RP5c1). Mirror config.nims's
  # exact resolution (SQLITE_LIBDIR / SQLITE_PREFIX / standard system libdirs /
  # nix store) so any provider the normal build links, this edge links too.
  # The Windows branch above has already returned; guard only macOS, which
  # ships libsqlite3 in the SDK and needs no explicit `-L` (matching
  # config.nims's `when not defined(windows) and not defined(macosx)`).
  when not defined(macosx):
    let sqliteLibDir = block:
      let direct = firstExistingLibDir(
        [
          getEnv("SQLITE_LIBDIR"),
          getEnv("SQLITE_PREFIX"),
          "/usr",
          "/usr/local",
          "/usr/lib",
          "/usr/lib64",
          "/usr/lib/x86_64-linux-gnu",
        ],
        ["libsqlite3.so", "libsqlite3.a"])
      if direct.len > 0:
        direct
      else:
        nixLibDir("*-sqlite-*", ["libsqlite3.so", "libsqlite3.a"])
    if sqliteLibDir.len > 0:
      result.add("--passL:-L" & sqliteLibDir)
      result.add("--passL:-Wl,-rpath," & sqliteLibDir)

proc consumerCompilePathFlags*(workDir = getCurrentDir()): seq[string] =
  ## ``--path:`` / ``--passC:`` / ``--passL:`` flags a downstream module
  ## must be compiled with when it ``import``s ``repro_project_dsl`` (or a
  ## generated interface stub, which itself ``import``s the DSL umbrella)
  ## from OUTSIDE the reprobuild source tree.
  ##
  ## The DSL umbrella takes hard dependencies on reprobuild's own
  ## libraries (``repro_binary_cache_client``, ``repro_binary_cache_server``,
  ## ``repro_core`` …) plus out-of-tree packages (``nimcrypto`` …). In a
  ## normal in-tree compile reprobuild's ``config.nims`` registers all of
  ## those on ``--path``; a consumer compiled in a scratch directory never
  ## loads that ``config.nims``, so the flags have to be replayed
  ## explicitly. This is the same flag set the interface-extraction and
  ## provider-compile commands assemble (see ``interfaceExtractionCommand``
  ## / ``providerCompileCommand``), exposed publicly so the engine-side
  ## consumer compile and the integration tests share one authoritative
  ## source of truth instead of hand-maintaining a parallel ``--path``
  ## list.
  result.add(reproLibPathFlags(workDir))
  result.add(reproPackagePathFlags(workDir))
  result.add(externalHashFlags(workDir))

proc fnvHex64(parts: openArray[string]): string =
  ## FNV-1a 64-bit hex digest of the concatenation of `parts` (with a NUL
  ## separator between parts so prefix collisions are impossible). Rendered
  ## inline to avoid pulling in a specific `toHex`.
  var h = 0xcbf29ce484222325'u64
  for i, part in parts:
    if i > 0:
      h = (h xor 0'u64) * 0x100000001b3'u64
    for ch in part:
      h = (h xor uint64(ord(ch))) * 0x100000001b3'u64
  const hexDigits = "0123456789abcdef"
  result = newString(16)
  for i in 0 ..< 16:
    result[15 - i] = hexDigits[int((h shr (uint64(i) * 4)) and 0xF'u64)]

proc providerNimcacheKey(outputBinaryPath: string): string =
  ## Per-output-binary nimcache key (FNV-1a of absolute output path).
  ## Retained for opt-in isolation via `REPRO_PROVIDER_NIMCACHE_MODE=per-binary`.
  fnvHex64([absolutePath(outputBinaryPath)])

const
  ProviderNimcacheSessionEnv* = "REPRO_PROVIDER_NIMCACHE_SESSION"
  ProviderParallelBuildEnv* = "REPRO_PROVIDER_PARALLEL_BUILD"
  ProviderParallelBuildMax* = 64
  ## Environment variable carrying the per-`repro`-invocation nimcache
  ## session token. The root `repro` process seeds this env var to its
  ## own pid (see `ensureProviderNimcacheSession`) and every child
  ## process spawned by the build engine -- in particular the per-recipe
  ## `repro __repro-compile-provider` invocations that auto-recurse fires
  ## for each from-source recipe -- inherits it through the engine's
  ## `envTableFromArgvStyle` env copy. All children of one root `repro`
  ## therefore land in the same shared provider nimcache and reuse Nim's
  ## `.sha1` incremental compilation across recipes. Independent
  ## concurrent `repro` sessions get distinct tokens (the env var is not
  ## inherited from outside `repro` because no outside caller sets it),
  ## so the M9.R.12 ENOTEMPTY concurrency-safety property is preserved.

proc ensureProviderNimcacheSession*() =
  ## Seed `REPRO_PROVIDER_NIMCACHE_SESSION` to the current process's pid
  ## if (and only if) the env var is not already set. Called at the top
  ## of `runThinApp` so every `repro` entry point participates; nested
  ## `repro` subprocesses (the build engine's `__repro-compile-provider`
  ## helpers, the recursive `executeBuildTarget` calls auto-recurse
  ## triggers) inherit the parent's value and therefore share the
  ## per-process provider nimcache key with their root invocation.
  if getEnv(ProviderNimcacheSessionEnv).len == 0:
    putEnv(ProviderNimcacheSessionEnv, "pid-" & $getCurrentProcessId())

proc providerNimcacheSessionToken(): string =
  ## Returns the session token to fold into the shared nimcache key.
  ## Prefers the inherited `REPRO_PROVIDER_NIMCACHE_SESSION` so every
  ## subprocess spawned by one root `repro` lands in the same shared
  ## cache; falls back to the current pid for callers that did not go
  ## through `ensureProviderNimcacheSession` (test fixtures, embedding
  ## libraries that call into `providerCompileCommand` directly).
  let inherited = getEnv(ProviderNimcacheSessionEnv)
  if inherited.len > 0:
    inherited
  else:
    "pid-" & $getCurrentProcessId()

proc sharedProviderNimcacheKey*(workDir: string;
                                hostFlags, libFlags: openArray[string]): string =
  ## Toolchain-stable nimcache key shared across every provider compile that
  ## targets the same Nim compiler + host C compiler + library set, anchored
  ## at the same `workDir`. Provider compiles invoked from a single CMake
  ## configure (the parent project plus every `try_compile`), and provider
  ## compiles fired by auto-recurse for from-source recipes, all land in the
  ## same nimcache so unchanged library modules are reused across them --
  ## the dominant slice of each provider compile.
  ##
  ## Concurrent-process hazard: the key is session-scoped via
  ## `REPRO_PROVIDER_NIMCACHE_SESSION` (see `providerNimcacheSessionToken`).
  ## Multiple `repro` sessions (separate processes) can run provider/
  ## interface compiles at the same time -- e.g. several concurrent
  ## dev-env sessions sharing one project tree. Nim's incremental compiler
  ## renames/removes temporary entries inside the nimcache while it
  ## builds; if a sibling process is concurrently populating the *same*
  ## directory, that cleanup hits `ENOTEMPTY` ("Directory not empty") and
  ## the compile aborts. The session token gives each root `repro`
  ## invocation its own nimcache directory, so concurrent sessions never
  ## collide. Crucially -- and unlike the prior pid-scoped key -- every
  ## subprocess spawned by ONE root `repro` (build-engine action helpers,
  ## including the `__repro-compile-provider` invocations the build engine
  ## emits for each per-recipe provider compile, plus recursive
  ## `executeBuildTarget` calls auto-recurse fires for from-source recipes)
  ## inherits the root's session token via the standard env-var inheritance
  ## the engine's `envTableFromArgvStyle` performs, so all 84 from-source
  ## recipes in one `repro build` cooperate on a single shared cache and
  ## keep Nim's `.sha1` incremental benefit. M9.R.13a closed the per-pid
  ## divergence that made each subprocess pay the full ~5 min provider
  ## compile from scratch.
  ##
  ## SCOPE (Compiles-Are-Normal-Edges.md): this selects a SCRATCH DIRECTORY
  ## for Nim's own incremental cache. It is NOT the cache key of any artifact.
  ## Both compiles that use it -- the provider compile and the interface
  ## extraction -- now run as monitored build edges, so what those compiles
  ## produce is addressed by the engine's action key over the observed argv,
  ## inputs and reads. Nothing this function forgets to mention can cause a
  ## stale artifact to be served; the worst case is a nimcache directory
  ## shared more or less widely than optimal, which Nim's own content-hashed
  ## reuse handles. Do not grow it back into an input enumeration.
  var parts = @[nimCompilerPath(), absolutePath(workDir),
                "session=" & providerNimcacheSessionToken()]
  for f in hostFlags:
    parts.add(f)
  for f in libFlags:
    parts.add(f)
  parts.add(reproLibSourceFingerprint(workDir))
  fnvHex64(parts)

proc providerNimcacheMode(): string =
  let mode = getEnv("REPRO_PROVIDER_NIMCACHE_MODE")
  if mode.len == 0: "shared" else: mode.toLowerAscii()

proc providerParallelBuildCount(): int =
  let raw = getEnv(ProviderParallelBuildEnv).strip()
  if raw.len == 0:
    return 1
  try:
    result = parseInt(raw)
  except ValueError:
    raise newException(ValueError,
      ProviderParallelBuildEnv & " must be an integer between 1 and " &
      $ProviderParallelBuildMax & "; got: " & raw)
  if result < 1 or result > ProviderParallelBuildMax:
    raise newException(ValueError,
      ProviderParallelBuildEnv & " must be between 1 and " &
      $ProviderParallelBuildMax & "; got: " & raw)

proc boundedNimCompileCommand*(): seq[string] =
  ## Provider and interface-runner compiles are nested build-engine work. Keep
  ## their host-C waves under the same validated bound so either path cannot
  ## independently exhaust a constrained builder.
  @[
    nimCompilerPath(),
    "c",
    "--parallelBuild:" & $providerParallelBuildCount()
  ]

type ReproFileLock* = object
  held: bool
  when defined(windows):
    handle: ProviderLockHandle
  else:
    fd: cint

proc providerNimcachePath(command: openArray[string]): string =
  for arg in command:
    if arg.startsWith("--nimcache:"):
      return arg["--nimcache:".len .. ^1]
  raise newException(ValueError,
    "provider compiler command has no --nimcache path")

proc acquireProviderFileLock(lockPath: string): ReproFileLock =
  createDir(extendedPath(parentDir(lockPath)))
  when defined(windows):
    let wide = newWideCString(lockPath)
    while true:
      let handle = providerLockCreateFileW(
        wide,
        ProviderLockGenericRead or ProviderLockGenericWrite,
        0,
        nil,
        ProviderLockOpenAlways,
        ProviderLockFileAttributeNormal,
        nil)
      if cast[int](handle) != cast[int](ProviderLockInvalidHandle):
        return ReproFileLock(held: true, handle: handle)
      let error = providerLockGetLastError()
      if error != ProviderLockSharingViolation:
        raise newException(IOError,
          "CreateFileW(" & lockPath & ") failed, GetLastError=" & $error)
      sleep(50)
  else:
    let fd = posix.open(lockPath.cstring, O_RDWR or O_CREAT, Mode(0o600))
    if fd < 0:
      raise newException(IOError,
        "open(" & lockPath & ") failed, errno=" & $errno)
    while providerLockFlock(fd, ProviderLockExclusive) != 0:
      if errno == EINTR:
        continue
      let lockError = errno
      discard posix.close(fd)
      raise newException(IOError,
        "flock(" & lockPath & ") failed, errno=" & $lockError)
    return ReproFileLock(held: true, fd: fd)

proc acquireProviderNimcacheLock(command: openArray[string]):
    ReproFileLock =
  ## Nim's incremental cache is reusable across provider recipes but is not
  ## safe for concurrent writers. Serialize commands that carry the same
  ## ``--nimcache`` path while leaving independent sessions fully parallel.
  acquireProviderFileLock(providerNimcachePath(command) & ".compile.lock")

proc releaseProviderNimcacheLock(lock: var ReproFileLock) =
  if not lock.held:
    return
  when defined(windows):
    if cast[int](lock.handle) != cast[int](ProviderLockInvalidHandle):
      discard providerLockCloseHandle(lock.handle)
      lock.handle = ProviderLockInvalidHandle
  else:
    if lock.fd >= 0:
      discard posix.close(lock.fd)
      lock.fd = -1
  lock.held = false

proc acquireInterfaceArtifactLock*(artifactPath: string):
    ReproFileLock =
  ## Serialize independent Reprobuild sessions that evaluate the same
  ## interface-extraction edge. The edge's monitor depfile and cache staging
  ## paths are project-local shared outputs, so RunQuota resource admission
  ## alone does not make concurrent writers safe.
  acquireProviderFileLock(artifactPath & ".extract.lock")

proc releaseInterfaceArtifactLock*(lock: var ReproFileLock) =
  releaseProviderNimcacheLock(lock)

proc runSharedNimcacheCompilerCommand(command: openArray[string]; cwd = ""):
    ProviderCompileExecutionResult =
  ## Execute a compiler command under the lock for its shared Nim cache. The
  ## lock is kernel-owned, so process termination releases it even though the
  ## small lock file remains available for later sessions.
  var lock = acquireProviderNimcacheLock(command)
  try:
    result = runCommand(command, cwd = cwd)
  finally:
    releaseProviderNimcacheLock(lock)

proc runProviderCompilerCommand*(command: openArray[string]; cwd = ""):
    ProviderCompileExecutionResult =
  runSharedNimcacheCompilerCommand(command, cwd)

proc runInterfaceCompilerCommand*(command: openArray[string]; cwd = ""):
    ProviderCompileExecutionResult =
  ## Interface runners reuse one cache for the same toolchain and library set.
  ## Distinct extraction edges may run in separate Reprobuild processes, so
  ## their compiler writes require the same cross-process serialization as
  ## provider compiles.
  runSharedNimcacheCompilerCommand(command, cwd)

proc providerDynamicEnabled(): bool =
  ## Returns true when ``REPRO_PROVIDER_DYNAMIC`` selects the Tier 1
  ## shared DSL runtime DLL link mode (see
  ## ``reprobuild-specs/Provider-Compile-Tiering.md``). Off by default
  ## until the DLL's dynamic-mode forward declarations land and the
  ## bench has measured the configure-time drop; switching it on today
  ## adds the link arguments to the provider compile but does not yet
  ## shrink the compile, because the umbrella DSL still pulls every
  ## runtime proc body into the per-project binary.
  let raw = getEnv("REPRO_PROVIDER_DYNAMIC").toLowerAscii()
  raw in ["1", "true", "yes", "on"]

proc providerDynamicLibDir(workDir: string): string =
  ## Filesystem directory that the per-project provider link step
  ## searches for the shared DSL runtime DLL. This matches the build
  ## script's output location
  ## (``build/lib/librepro_project_dsl_runtime.{dll,so,dylib}``).
  workDir / "build" / "lib"

proc buildScratchRoot(workDir, scratchDir: string): string =
  if scratchDir.len > 0:
    scratchDir
  else:
    workDir / "build"

proc extractInterfaceFromModule*(modulePath, artifactPath, stubPath: string;
                                 workDir = getCurrentDir();
                                 scratchDir = "";
                                 requireStub = true;
                                 resourceModule = "";
                                 extraPaths: openArray[string] = [];
                                 consumerRoot = "";
                                 useExtractionCache = true):
    ProjectInterfaceArtifact =
  ## ``useExtractionCache`` controls the built-in warm short-circuit. It is
  ## ``false`` for exactly one caller: the child of the extraction EDGE.
  ##
  ## That short-circuit is keyed by ``interfaceExtractionFingerprint``, whose
  ## source closure is an import walk of the recipe's TEXT. It therefore
  ## cannot see a dependency the recipe acquires during macro expansion — a
  ## ``dslDeps`` package's own ``repro.nim``, or anything a ``staticExec`` in
  ## a macro reads. When the engine has decided the edge must re-run, it did
  ## so from monitored evidence that DOES see those files; consulting the
  ## narrower key inside the child would then veto the engine's decision and
  ## serve the stale artifact the edge was re-run to replace.
  ## ``consumerRoot`` is the project root the extracted recipe belongs to. It
  ## is handed to the recipe's macro expansion as ``-d:reproConsumerRoot`` so
  ## a macro can resolve a declared dependency against the RIGHT workspace.
  ## Defaults to the process working directory, which is what every direct
  ## (test / bootstrap) caller means. The engine-side caller passes it
  ## EXPLICITLY: once the extraction runs as a build edge it runs in a child
  ## process whose cwd is chosen by the engine, so an ambient
  ## ``getCurrentDir()`` there would name the wrong project — and, because the
  ## value is baked into the compiled recipe, would do so silently.
  ##
  ## TI1 (Project-Provider-Runtime-Protocol.milestones.org) — a producer may
  ## declare a RESOURCE MODULE (e.g. vm-harness's ``src/vm_harness/repro/
  ## resources.nim``) that carries its ``resourceType`` blocks, plus the extra
  ## ``--path``s that module's imports need. When ``resourceModule`` is given
  ## the extraction runner ALSO imports that module so its module-init
  ## ``registerResourceTypeInterface`` side effects run before the interface is
  ## projected — so ``publicResources`` reflects the producer's REAL resource
  ## types, not a stub. The resource-module driver closure is producer-side
  ## only (compiled once, here, at lift time). ``extraPaths`` are appended as
  ## ``--path:`` flags for the runner compile.
  var fingerprintContext: InterfaceExtractionContext
  var inputFingerprint: ContentDigest
  if useExtractionCache:
    let probe = interfaceExtractionCacheProbe(modulePath, artifactPath,
      stubPath, workDir, requireStub, resourceModule, extraPaths)
    if probe.artifact.isSome:
      return probe.artifact.get()
    fingerprintContext = probe.fingerprintContext
    inputFingerprint = probe.inputFingerprint
  else:
    fingerprintContext = interfaceExtractionContext(modulePath, workDir,
      includeReproLibFingerprint = true, resourceModule = resourceModule,
      extraPaths = extraPaths)
    inputFingerprint = interfaceExtractionFingerprint(fingerprintContext)

  let moduleDir = parentDir(modulePath)
  # Windows: the extract_runner.nim path is passed verbatim to a child
  # `nim c` invocation, and nim opens it via the non-extended Win32 API,
  # so paths longer than MAX_PATH (260 chars) cause `Error: cannot open
  # …extract_runner.nim`. CMake TryCompile workdirs nested inside the
  # generator's per-build worktree blow past that limit, so prefer the
  # system temp dir for the runner scratch tree on Windows.
  let tempParent = absolutePath(
    when defined(windows):
      getTempDir() / "repro-interface-extract"
    else:
      buildScratchRoot(workDir, scratchDir) / "m7-temp")
  createDir(extendedPath(tempParent))
  # createTempDir uses an atomic create-and-retry loop. PID/timestamp names can
  # collide between threads in one process and make compilers share response
  # files; each extraction instead owns an exclusive writable directory.
  let tempRoot = createTempDir("repro-interface-extract-", "", tempParent)
  defer:
    try:
      removeDir(extendedPath(tempRoot))
    except OSError:
      discard
  let runnerPath = tempRoot / "extract_runner.nim"
  # M9.R.14b.2: Pin the recipe import to its absolute path so that
  # ``import repro`` does not resolve through Nim's search path. The
  # generic ``import <moduleName>`` form used to ride on
  # ``--path:moduleDir``, but config.nims at the reprobuild root adds
  # ``switch("path", ".")`` which gives Nim the ROOT ``repro.nim``
  # as a SECOND candidate for the bare ``repro`` module identifier.
  # On any from-source recipe (e.g. ``recipes/packages/source/gcc/``
  # whose own ``repro.nim`` collides on the leaf module name with the
  # workspace root's ``repro.nim``), Nim picked the ROOT — silently
  # extracting the wrong project's interface (projectName = "sh"
  # because the merged registry's first package was the stdlib's
  # ``sh`` package via the system_tools chain, NOT the recipe's
  # ``gccSource``). Downstream this surfaced as "root entry point
  # is missing from provider manifest" because the standard provider
  # could not match the gcc recipe's expected entry point against the
  # extracted root project's interface.
  #
  # An absolute-path quoted import sidesteps the path-search ambiguity
  # entirely. Nim treats ``import "<abs path>"`` as a literal file
  # reference; the per-module symbol scope still gives us the
  # ``registeredPackages()`` set as expected by ``artifactFromRegisteredDsl``.
  let absoluteModulePath = absolutePath(modulePath).replace('\\', '/')
  # TI1: when a producer declares a separate RESOURCE MODULE, import it BEFORE
  # the producer's own module so its ``resourceType`` module-init registrations
  # run and ``artifactFromRegisteredDsl`` sees the real resource types. The
  # ``resourceType`` macro emits a module-init proc calling
  # ``registerResourceTypeInterface``; that side effect only executes if the
  # module is actually imported into the extraction runner's compilation unit.
  var resourceImport = ""
  if resourceModule.len > 0:
    let absoluteResourceModule =
      absolutePath(resourceModule).replace('\\', '/')
    resourceImport = "import \"" & absoluteResourceModule & "\"\n"
  writeFile(extendedPath(runnerPath),
    "import std/os\n" &
    "import repro_interface_artifacts\n" &
    "import repro_project_dsl\n" &
    "import repro_dsl_stdlib/constructors\n" &
    resourceImport &
    "import \"" & absoluteModulePath & "\"\n\n" &
    "let artifact = artifactFromRegisteredDsl(paramStr(3))\n" &
    "writeInterfaceArtifact(paramStr(1), artifact)\n" &
    "writeNimInterfaceStub(paramStr(2), artifact)\n")
  let runnerBin = tempRoot / "extract_runner"
  let hostFlags = hostCCompilerFlags()
  let libFlags = reproLibPathFlags(workDir)
  # Share the extractor nimcache across every interface extraction with the
  # same toolchain + library set. The runner module itself (`extract_runner`)
  # recompiles each time because it imports a project-specific module, but
  # every standard library / repro library module is reused via Nim's
  # `.sha1`-based incremental compilation -- the dominant slice of the
  # compile cost. `REPRO_PROVIDER_NIMCACHE_MODE=per-binary` falls back to
  # the per-tempRoot nimcache that isolates each invocation.
  # Nim's `--nimcache:` directive is also subject to the MAX_PATH ceiling
  # because Nim's own mkdir does not use the \\?\ extended-length prefix.
  # On Windows root the shared nimcache under the same short temp parent
  # we use for the runner, keyed by toolchain+library set so independent
  # extractions still share the bulk of the standard-library compile
  # cost. `REPRO_PROVIDER_NIMCACHE_MODE=per-binary` keeps each
  # extraction's nimcache fully isolated.
  # The engine's own binary and the consumer's root are handed to the recipe's
  # macro expansion. A macro that needs to resolve a declared dependency calls
  # back through `staticExec` (see `internal resolve-package`) rather than
  # reimplementing workspace lookup: it runs at compile time in a scratch
  # directory and can derive neither on its own -- `getProjectPath` points at
  # that scratch dir, not at the consumer.
  #
  # These are ordinary elements of the compile's ARGV, which is the point:
  # when this compile runs as a monitored build edge the argv IS part of the
  # action key, so a define cannot be added without re-keying the edge. The
  # hand-written `sharedProviderNimcacheKey` had no such property -- it never
  # mentioned defines, which is how `-d:reproBin` was once introduced,
  # reached the command line, and still had no effect.
  let effectiveConsumerRoot =
    if consumerRoot.len > 0: absolutePath(consumerRoot) else: getCurrentDir()
  let interfaceDefines = @[
    "--define:reproInterfaceMode",
    "--define:reproBin=" & getAppFilename(),
    # NOT workDir. On the cross-repo producer path workDir comes from
    # `reprobuildLibraryWorkDir()`, which resolves through
    # `currentSourcePath()` and therefore names REPROBUILD's own root -- so
    # `-d:reproConsumerRoot=workDir` handed the macro reprobuild instead of
    # the consumer, and every dependency resolved against the wrong
    # workspace.
    "--define:reproConsumerRoot=" & effectiveConsumerRoot,
  ] & (if getEnv("REPRO_DSLDEPS_DEBUG").len > 0:
         @["--define:reproDslDepsDebug"] else: @[])
  let nimcache =
    if providerNimcacheMode() == "per-binary":
      tempRoot / "nimcache"
    else:
      when defined(windows):
        tempParent / "nimcache-interface" /
          sharedProviderNimcacheKey(workDir, hostFlags, libFlags)
      else:
        buildScratchRoot(workDir, scratchDir) / "nimcache-interface" /
          sharedProviderNimcacheKey(workDir, hostFlags, libFlags)
  var command = boundedNimCompileCommand()
  command.add(interfaceDefines)
  command.add(@[
    "--path:" & moduleDir,
    "--nimcache:" & nimcache,
    "--out:" & runnerBin,
    runnerPath
  ])
  command.insert(hostFlags, 2)
  command.insert(externalHashFlags(workDir), 2)
  command.insert(reproPackagePathFlags(workDir), 2)
  command.insert(libFlags, 4)
  # TI2 residual fix (a) — ``--path`` ORDER: the producer-declared resource
  # module dir + its extra ``--path``s MUST come AFTER the reprobuild lib flags
  # (``libFlags``, inserted at index 4 above), never before. Nim's module
  # resolution does NOT reliably prefer the first ``--path`` entry when the same
  # logical module name exists under two roots, so a producer whose src tree
  # (or an ``extraPaths`` dir) happens to contain a module colliding with a
  # reprobuild lib module (e.g. a stray ``repro_*`` leaf) could SHADOW the
  # reprobuild copy and silently lift against the wrong sources. Appending the
  # producer paths AFTER ``libFlags`` guarantees the reprobuild libs win on any
  # ambiguity. (Before TI2 these were inserted at the SAME index 4, which put
  # them BEFORE ``libFlags`` — the shadowing hazard TI1 flagged as residual.)
  var producerPathFlags: seq[string] = @[]
  if resourceModule.len > 0:
    producerPathFlags.add("--path:" & parentDir(absolutePath(resourceModule)))
  for extra in extraPaths:
    if extra.len > 0:
      producerPathFlags.add("--path:" & absolutePath(extra))
  if producerPathFlags.len > 0:
    command.insert(producerPathFlags, 4 + libFlags.len)
  # Diagnostic (opt-in via REPRO_INTERFACE_LIST_CMD): make the otherwise-silent
  # interface `nim c` echo every sub-command (the gcc.exe compile/link lines) it
  # issues. Paired with runCommand's Windows timeout-and-dump-sink, the LAST
  # echoed command in the dump names the exact sub-process that wedged, turning a
  # silent multi-hour hang into an actionable error. Inserted among the flags
  # (index 2), never after `runnerPath`, or nim treats it as a second input file.
  if getEnv("REPRO_INTERFACE_LIST_CMD").len > 0:
    command.insert(@["--listCmd"], 2)
  # `workDir` is the reprobuild library lookup/fingerprint root. Installed Nix
  # packages deliberately point it at their immutable source closure, so it is
  # not a valid compiler working directory: Nim writes relative linker response
  # files (for example `extract_runner_linkerArgs.txt`) into its process CWD.
  # The runner scratch directory already owns every generated extractor file.
  let compileExecution = runInterfaceCompilerCommand(command, cwd = tempRoot)
  let runnerExe = compiledExecutablePath(runnerBin)
  if not fileExists(extendedPath(runnerExe)):
    # `runCommand` already raises on non-zero exit, so reaching this branch
    # means the compiler reported success (typically `[SuccessX]`) but did
    # not actually write the binary. This has been observed under
    # fork/resource pressure with certain Nim/clang-wrapper combinations.
    # Capture a directory listing to make the missing-output state visible
    # for future triage instead of just claiming the file is absent.
    let runnerExeDir = runnerExe.splitPath.head
    var listing = ""
    try:
      let lsExec = runCommand(@["ls", "-la", runnerExeDir])
      listing = lsExec.output
    except CatchableError as ex:
      listing = "(failed to list " & runnerExeDir & ": " & ex.msg & ")"
    raise newException(IOError,
      "interface extraction runner was not compiled (exit=" &
        $compileExecution.exitCode &
        ", compiler reported success but produced no binary): " &
        runnerExe & "\ncompiler output:\n" & compileExecution.output &
        "\ndirectory listing of " & runnerExeDir & ":\n" & listing)
  # Windows: the runner dlopens clingo/sqlite/zstd/OpenSSL by leaf name and
  # lives in a temp tree with no DLLs of its own. See the proc's docstring.
  stageHostDynlibsBesideBinary(parentDir(runnerExe))
  ensureExecutable(runnerExe)
  let execution = runCommand(@[
    runnerExe,
    absolutePath(artifactPath),
    absolutePath(stubPath),
    absoluteModulePath
  ], cwd = tempRoot)
  if not fileExists(extendedPath(artifactPath)):
    raise newException(IOError,
      "interface extraction did not write artifact: " & artifactPath &
        "\n" & execution.output)
  result = readInterfaceArtifactWithWarm(artifactPath)
  writeFile(extendedPath(interfaceExtractionCachePath(artifactPath)), toHex(
      inputFingerprint.bytes))
  writeInterfaceExtractionCacheRecord(artifactPath, fingerprintContext,
    inputFingerprint)

proc providerFingerprintFor*(inputSources: openArray[string];
                             interfaceFingerprint: ContentDigest;
                             workDir = getCurrentDir()): ContentDigest =
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.providerSources.v2")
  payload.writeDigest(interfaceFingerprint)
  payload.writeString(reproLibSourceFingerprint(workDir))
  for path in inputSources:
    payload.writeString(path)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  blake3DomainDigest(payload, hdActionFingerprint)

# ---------------------------------------------------------------------
# RP1 — Provider-Runtime-Protocol v1 first-class identities.
#
# ``Provider-Runtime-Protocol-v1.md`` §1 pins the exact structure of the
# two provider-edge identities. The pre-RP1 code already hashed a
# ``providerFingerprint`` (source-based) and an ``actionFingerprint``
# (compile-command-based) — those remain the on-disk artifact/freshness
# key and are UNCHANGED here so existing artifacts keep round-tripping.
#
# RP1 layers the *named* v1 identities ON TOP:
#
#   ProviderArtifactId = hash(
#     providerProtocolVersion, frontendRuntimeIdentity,
#     projectSourceSemanticIdentity, generatedEntryPointIds+bodyHashes,
#     providerImplementationImports, publicDependencyInterfaceFingerprints,
#     providerCompileOptions)
#
#   ProviderCompileActionKey = hash(
#     "compile-provider", ProviderArtifactId, nimCompilerIdentity,
#     canonicalSourceInputPaths, declaredProviderCompileInputs)
#
# The ProviderCompileActionKey becomes the engine edge's action key so a
# rebuild with an unchanged key is a cache HIT and — crucially — two
# consumers whose lock resolves the SAME dependency version compute the
# SAME ProviderArtifactId (because ``publicDependencyInterfaceFingerprints``
# and the source semantic identity coincide) and therefore bind the SAME
# cached binary. The interface-vs-provider fingerprint SPLIT (a private
# impl edit NOT re-keying downstream) is deferred to RP6; v1 includes
# ``publicDependencyInterfaceFingerprints`` in the key but does not yet
# split private-impl edits out of ``projectSourceSemanticIdentity``.

const
  ProviderProtocolVersionV1* = 1'u32
    ## Mirrors ``repro_provider_runtime/types.nim``'s
    ## ``ProviderProtocolVersion``. Held as a local const so the identity
    ## layer does not take a build-graph dependency on the runtime library
    ## (which would form a cycle once RP2 wires the session launcher). Kept
    ## in sync manually; a divergence would only change every
    ## ProviderArtifactId uniformly (a full cache miss, never a correctness
    ## bug).

var cachedNimCompilerIdentity = ""

proc nimCompilerIdentity*(): string =
  ## Canonical identity of the Nim frontend used to compile providers:
  ## the resolved compiler path plus its ``--version`` banner. Feeds
  ## ``ProviderCompileActionKey`` so a compiler swap re-keys the compile
  ## edge. Cached per process — the compiler does not change mid-run.
  if cachedNimCompilerIdentity.len > 0:
    return cachedNimCompilerIdentity
  let path = nimCompilerPath()
  var banner = ""
  try:
    banner = runCommand(@[path, "--version"]).output.splitLines()[0].strip()
  except CatchableError:
    banner = ""
  cachedNimCompilerIdentity = path & "\n" & banner
  cachedNimCompilerIdentity

proc frontendRuntimeIdentity*(workDir = getCurrentDir()): string =
  ## Identity of the frontend/runtime the provider binary links against —
  ## the reprobuild DSL runtime source set. A change to the runtime
  ## re-materializes every provider. Reuses the existing lib-source
  ## fingerprint so it stays consistent with ``providerFingerprintFor``.
  reproLibSourceFingerprint(workDir)

proc commonSourceRoot(paths: openArray[string]): string =
  ## The longest shared directory prefix of the given normalized source
  ## paths. Used to make ``projectSourceSemanticIdentity`` content- and
  ## LAYOUT-addressed rather than absolute-path-addressed, so two consumers
  ## in different directories whose source closures are byte-identical and
  ## laid out identically converge on the same semantic identity (the RP1
  ## sharing property).
  if paths.len == 0:
    return ""
  var prefix = parentDir(normalizedStampPath(paths[0]))
  for i in 1 ..< paths.len:
    let dir = parentDir(normalizedStampPath(paths[i]))
    while prefix.len > 0 and not (dir == prefix or
        dir.startsWith(prefix & "/")):
      let up = parentDir(prefix)
      if up == prefix:
        prefix = ""
        break
      prefix = up
  prefix

proc projectSourceSemanticIdentity*(inputSources: openArray[string]):
    ContentDigest =
  ## The semantic identity of the project's own provider source closure:
  ## the ordered (root-relative path, content) set of the ``.nim`` sources
  ## compiled into the provider. Paths are made relative to the closure's
  ## common root so the identity is content-addressed, not tied to a
  ## consumer's absolute working directory — this is what lets two
  ## consumers of the same dependency version converge on the same
  ## ``ProviderArtifactId`` (the RP1 sharing property). In v1 this is the
  ## whole source closure; RP6 will split the private-impl portion out so
  ## it does not re-key downstream.
  var normalized: seq[string] = @[]
  for path in inputSources:
    normalized.add(normalizedStampPath(path))
  let root = commonSourceRoot(normalized)
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.projectSourceSemanticIdentity.v1")
  for path in normalized:
    let relPath =
      if root.len > 0 and path == root: extractFilename(path)
      elif root.len > 0 and path.startsWith(root & "/"):
        path[root.len + 1 .. ^1]
      else: extractFilename(path)
    payload.writeString(relPath)
    let content = toBytes(readFile(extendedPath(path)))
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  blake3DomainDigest(payload, hdActionFingerprint)

proc computeProviderArtifactId*(
    inputSources: openArray[string];
    interfaceFingerprint: ContentDigest;
    generatedEntryPointIds: openArray[string] = [];
    entryPointBodyHashes: openArray[string] = [];
    providerImplementationImports: openArray[string] = [];
    publicDependencyInterfaceFingerprints: openArray[string] = [];
    providerCompileOptions: openArray[string] = [];
    workDir = getCurrentDir()): ContentDigest =
  ## The v1 ``ProviderArtifactId`` (Provider-Runtime-Protocol-v1.md §1).
  ##
  ## ``publicDependencyInterfaceFingerprints`` is the SHARING key: two
  ## consumers whose lock resolves the same dependency version pass the
  ## same fingerprints here and — with identical source semantic identity —
  ## compute the same id, hence bind the same cached artifact.
  var payload: seq[byte] = @[]
  payload.writeString("reprobuild.providerArtifactId.v1")
  payload.writeU32Le(ProviderProtocolVersionV1)
  payload.writeString(frontendRuntimeIdentity(workDir))
  payload.writeDigest(projectSourceSemanticIdentity(inputSources))
  # The interface fingerprint is the project's own public-signature
  # identity; carried so an interface-only change re-keys the artifact.
  payload.writeDigest(interfaceFingerprint)
  var entryIds = @generatedEntryPointIds
  entryIds.sort(system.cmp[string])
  payload.writeStringSeq(entryIds)
  var bodyHashes = @entryPointBodyHashes
  bodyHashes.sort(system.cmp[string])
  payload.writeStringSeq(bodyHashes)
  var imports = @providerImplementationImports
  imports.sort(system.cmp[string])
  payload.writeStringSeq(imports)
  # Public dependency interface fingerprints are order-normalized so two
  # consumers that list the same deps in different orders still converge.
  var depFingerprints = @publicDependencyInterfaceFingerprints
  depFingerprints.sort(system.cmp[string])
  payload.writeStringSeq(depFingerprints)
  var compileOptions = @providerCompileOptions
  compileOptions.sort(system.cmp[string])
  payload.writeStringSeq(compileOptions)
  blake3DomainDigest(payload, hdActionFingerprint)

proc computeProviderCompileActionKey*(
    providerArtifactId: ContentDigest;
    canonicalSourceInputPaths: openArray[string];
    declaredProviderCompileInputs: openArray[string] = []): ContentDigest =
  ## The v1 ``ProviderCompileActionKey`` (Provider-Runtime-Protocol-v1.md
  ## §1) — the engine edge's action key. Keyed by ``nimCompilerIdentity``
  ## so a compiler swap forces a recompile even when the artifact id is
  ## unchanged.
  var payload: seq[byte] = @[]
  payload.writeString("compile-provider")
  payload.writeDigest(providerArtifactId)
  payload.writeString(nimCompilerIdentity())
  var sourcePaths: seq[string] = @[]
  for path in canonicalSourceInputPaths:
    sourcePaths.add(normalizedStampPath(path))
  sourcePaths.sort(system.cmp[string])
  payload.writeStringSeq(sourcePaths)
  var declared: seq[string] = @[]
  for path in declaredProviderCompileInputs:
    declared.add(normalizedStampPath(path))
  declared.sort(system.cmp[string])
  payload.writeStringSeq(declared)
  blake3DomainDigest(payload, hdActionFingerprint)

proc providerFreshnessCachePath(artifactPath: string): string =
  artifactPath & ".inputs"

proc writeProviderFreshnessCacheRecord(artifactPath, modulePath: string;
                                       workDir: string;
                                       artifact: ProviderCompileArtifact) =
  let record = ProviderFreshnessCacheRecord(
    modulePath: normalizedStampPath(modulePath),
    workDir: normalizedStampPath(workDir),
    outputBinaryPath: normalizedStampPath(artifact.outputBinaryPath),
    sourceStamps: fileStamps(artifact.inputSources),
    reproLibStamps: reproLibStampsForCache(workDir),
    outputBinaryStamp: fileStamp(artifact.outputBinaryPath),
    interfaceFingerprint: artifact.interfaceFingerprint,
    providerFingerprint: artifact.providerFingerprint,
    reproLibFingerprint: reproLibSourceFingerprint(workDir),
    outputBinaryFingerprint: artifact.outputBinaryFingerprint)
  try:
    writeFile(extendedPath(providerFreshnessCachePath(artifactPath)),
      toByteString(encodeProviderFreshnessCacheRecord(record)))
  except CatchableError:
    discard

proc readProviderFreshnessCacheRecord(path: string):
    Option[ProviderFreshnessCacheRecord] =
  if not fileExists(extendedPath(path)):
    return none(ProviderFreshnessCacheRecord)
  try:
    return some(decodeProviderFreshnessCacheRecord(fromByteString(readFile(extendedPath(path)))))
  except CatchableError:
    return none(ProviderFreshnessCacheRecord)

proc providerFreshnessRecordMatches(record: ProviderFreshnessCacheRecord;
                                    modulePath, outputBinaryPath: string;
                                    workDir: string;
                                    inputSources: openArray[string];
                                    interfaceFingerprint,
                                    providerFingerprint,
                                    outputBinaryFingerprint: ContentDigest): bool =
  (modulePath.len == 0 or record.modulePath == normalizedStampPath(modulePath)) and
    record.workDir == normalizedStampPath(workDir) and
    record.outputBinaryPath == normalizedStampPath(outputBinaryPath) and
    record.interfaceFingerprint == interfaceFingerprint and
    record.providerFingerprint == providerFingerprint and
    record.reproLibFingerprint.len > 0 and
    record.outputBinaryFingerprint == outputBinaryFingerprint and
    record.sourceStamps == fileStamps(inputSources) and
    record.reproLibStamps == reproLibStampsForCache(workDir) and
    record.outputBinaryStamp == fileStamp(outputBinaryPath)

proc cachedProviderFreshnessByMetadata(artifactPath, modulePath,
                                       outputBinaryPath: string;
                                       workDir: string;
                                       inputSources: openArray[string];
                                       cached: ProviderCompileArtifact):
    bool =
  let record = readProviderFreshnessCacheRecord(
    providerFreshnessCachePath(artifactPath))
  if record.isNone:
    return false
  providerFreshnessRecordMatches(record.get(), modulePath, outputBinaryPath,
    workDir, inputSources, cached.interfaceFingerprint, cached.providerFingerprint,
    cached.outputBinaryFingerprint)

proc normalizedProviderOutputPath*(outputBinaryPath: string): string =
  # On Windows, the Nim compiler emits executables with a .exe suffix even
  # when `--out:` is given without one. Normalize the requested path so the
  # rest of the pipeline (cache lookup, startProcess) sees the real artifact
  # location. ExeExt is "" on POSIX so this is a no-op there.
  when defined(windows):
    if outputBinaryPath.endsWith("." & ExeExt) or ExeExt.len == 0:
      outputBinaryPath
    else:
      outputBinaryPath & "." & ExeExt
  else:
    outputBinaryPath

proc providerCompileNimcacheRoot*(): string =
  ## Root of the SHARED provider nimcache (`providerCompileCommand` anchors
  ## `--nimcache:` under it). Exported so the provider-compile edge can declare
  ## it as an ignored input prefix — see `providerCompileIgnoredInputPrefixes`.
  getTempDir() / "repro-nimcache-provider"

proc providerCompileIgnoredInputPrefixes*(scratchDir = ""): seq[string] =
  ## Prefixes the provider-compile edge's monitor must NOT record as inputs.
  ##
  ## The compile reads back what it just wrote into its own derived state: the
  ## Nim incremental cache (`<temp>/repro-nimcache-provider/<key>`) and the
  ## per-recipe scratch tree. Recording those as inputs is wrong twice over:
  ##
  ##   * the nimcache is SHARED by key across recipes and across `repro`
  ##     sessions on purpose (cross-recipe `.o` reuse), so any OTHER provider
  ##     compile that lands in the same directory rewrites files this edge
  ##     recorded — and a warm build that changed nothing then misses its cache
  ##     nondeterministically, depending only on what else ran;
  ##   * the scratch tree contains freshly created directories that do not even
  ##     exist on the next run.
  ##
  ## Everything here is machine-local derived state. The real inputs — the
  ## recipe, the reprobuild libs, the toolchain, the config files — live
  ## elsewhere and stay recorded. This mirrors the identical treatment the
  ## interface-extraction edge gives its own scratch (`extractInterfaceEdge`).
  result = @[absolutePath(providerCompileNimcacheRoot())]
  if scratchDir.len > 0:
    result.add(absolutePath(scratchDir))

proc providerCompileOutputs*(artifactPath, outputBinaryPath: string):
    seq[string] =
  ## Every file one provider compile writes and that a later run reads back —
  ## the provider binary, the compile artifact, and the freshness sidecar
  ## (``<artifact>.inputs``, written by ``writeProviderFreshnessCacheRecord``).
  ##
  ## All three must be DECLARED outputs of the provider-compile edge, for the
  ## same reason ``interfaceExtractionOutputs`` lists all four of the
  ## extraction's: an action-cache hit restores exactly the declared set, so
  ## declaring only the binary and the artifact would leave the sidecar
  ## absent. The in-process freshness probe would then miss and every direct
  ## (non-edge) caller would re-compile — a silent loss of the cache rather
  ## than an error.
  result = @[normalizedProviderOutputPath(outputBinaryPath), artifactPath]
  result.add(providerFreshnessCachePath(artifactPath))

when defined(linux):
  # Linux io-mon injects its shim with ``LD_PRELOAD``. A statically linked ELF
  # never consults the dynamic loader, so the shim cannot be loaded into it and
  # its reads are unobservable. An edge whose compiler is such a binary must
  # not make a monitor-completeness claim, hence must not be cacheable.
  #
  # This lives here rather than in ``repro_cli_support`` because BOTH edge
  # constructors (``repro_cli_support`` and ``repro_dev_env_engine``) need the
  # same answer; the dev-env one previously hard-coded ``cacheable = true``
  # and would have published an incomplete-evidence entry in exactly this
  # configuration.
  proc elfU16At(bytes: string; offset: int): uint16 =
    if offset < 0 or offset + 2 > bytes.len:
      return 0'u16
    uint16(ord(bytes[offset])) or
      (uint16(ord(bytes[offset + 1])) shl 8)

  proc elfU32At(bytes: string; offset: int): uint32 =
    if offset < 0 or offset + 4 > bytes.len:
      return 0'u32
    uint32(ord(bytes[offset])) or
      (uint32(ord(bytes[offset + 1])) shl 8) or
      (uint32(ord(bytes[offset + 2])) shl 16) or
      (uint32(ord(bytes[offset + 3])) shl 24)

  proc elfU64At(bytes: string; offset: int): uint64 =
    if offset < 0 or offset + 8 > bytes.len:
      return 0'u64
    result = 0'u64
    for i in 0 ..< 8:
      result = result or (uint64(ord(bytes[offset + i])) shl (8 * i))

  proc elfHasProgramInterpreter(path: string): bool =
    ## True for ELF files that go through the dynamic loader. Linux io-mon uses
    ## LD_PRELOAD, so a static ELF provider compiler cannot load the shim after
    ## exec and must not make a cacheable monitor-completeness claim.
    let raw = readFile(extendedPath(path))
    if raw.len < 52:
      return false
    if raw[0] != char(0x7f) or raw[1] != 'E' or raw[2] != 'L' or raw[3] != 'F':
      return false
    if ord(raw[5]) != 1: # little-endian ELF
      return false
    const PtInterp = 3'u32
    let elfClass = ord(raw[4])
    var phoff: int
    var phentsize: int
    var phnum: int
    case elfClass
    of 1: # ELF32
      phoff = int(elfU32At(raw, 28))
      phentsize = int(elfU16At(raw, 42))
      phnum = int(elfU16At(raw, 44))
    of 2: # ELF64
      if raw.len < 64:
        return false
      let phoff64 = elfU64At(raw, 32)
      if phoff64 > uint64(int.high):
        return false
      phoff = int(phoff64)
      phentsize = int(elfU16At(raw, 54))
      phnum = int(elfU16At(raw, 56))
    else:
      return false
    if phoff <= 0 or phentsize < 4 or phnum <= 0:
      return false
    for i in 0 ..< phnum:
      let entry = phoff + i * phentsize
      if entry < 0 or entry + 4 > raw.len:
        return false
      if elfU32At(raw, entry) == PtInterp:
        return true
    false

  proc linuxElfWithoutProgramInterpreter(path: string): bool =
    try:
      let raw = readFile(extendedPath(path))
      if raw.len < 4 or raw[0] != char(0x7f) or raw[1] != 'E' or
          raw[2] != 'L' or raw[3] != 'F':
        return false
      not elfHasProgramInterpreter(path)
    except CatchableError:
      false

proc providerCompileMonitorInjectable*(compilerCommand: openArray[string]):
    bool =
  ## Whether io-mon can observe the compiler this plan will spawn. False only
  ## on Linux with a static-ELF compiler (see above). When false the
  ## provider-compile edge must be declared ``cacheable = false``: its monitor
  ## evidence would be incomplete, and an edge that publishes on incomplete
  ## evidence fails by serving a stale binary rather than by erroring.
  when defined(linux):
    if compilerCommand.len > 0 and
        linuxElfWithoutProgramInterpreter(compilerCommand[0]):
      return false
  true

proc providerCompileCacheable*(plan: ProviderCompilePlan): bool =
  providerCompileMonitorInjectable(plan.compilerCommand)

type
  ReproRtlMode* = enum
    ## Typed-Extension-Interfaces M4c — the RTL mode of a provider-LIBRARY
    ## build (§4.4). It is part of the library edge's action key: a
    ## nimRtl-shared artifact and a standalone C-ABI artifact are DISTINCT
    ## cache entries and never confused. Rendered as SEMANTIC compiler
    ## ``--define``s, so it flows into ``providerCompileOptions`` →
    ## ``ProviderArtifactId`` → ``ProviderCompileActionKey`` automatically.
    rtlStandaloneCAbi   ## ``--app:lib`` only — the portable C-ABI boundary,
                        ## no nimRtl coupling; interoperates with ANY host.
    rtlNimRtlShared     ## ``--app:lib -d:useNimRtl -d:reproNimRtlShared`` —
                        ## the Nim-native fast path; sound ONLY when host +
                        ## library share one pinned ``nimrtl`` (matched Nim
                        ## version + ORC). Emits the ``*_direct`` no-marshal
                        ## entry points + the ``SymRtlProbe`` presence symbol.

proc rtlModeDefines*(mode: ReproRtlMode): seq[string] =
  ## The extra compiler flags that render an ``ReproRtlMode`` as a LIBRARY
  ## build. Both modes are ``--app:lib``; nimRtl-shared additionally shares the
  ## runtime and emits the fast-path surface. These are semantic compile
  ## options (they change the emitted symbols), so appending them re-keys the
  ## provider-compile action deterministically.
  case mode
  of rtlStandaloneCAbi: @["--app:lib"]
  of rtlNimRtlShared:   @["--app:lib", "--define:useNimRtl",
                          # mirrors ``library_abi.ReproRtlSharedDefine``; held
                          # as a local literal so this identity layer takes no
                          # build-graph dependency on ``repro_resources``.
                          "--define:reproNimRtlShared"]

proc providerCompileCommand*(modulePath, outputBinaryPath: string;
                             workDir = getCurrentDir();
                             scratchDir = ""): seq[string] =
  # The Nim provider nimcache holds generated C/object files with long
  # `@m..@s..nim.c` names. When `outputBinaryPath` lands deep inside a
  # CMake TryCompile scratch tree, a nimcache placed next to it overflows
  # Windows' 260-char MAX_PATH. The nimcache is a pure build intermediate,
  # so anchor it under the short scratch root that the interface extractor also
  # uses.
  #
  # The key is shared across every provider compile that targets the same
  # toolchain + library set *within one `repro` session*
  # (default `REPRO_PROVIDER_NIMCACHE_MODE=shared`).
  # Each CMake configure pays for one cold provider compile; subsequent
  # try_compile providers reuse all unchanged library object files via
  # Nim's `.sha1`-based incremental compilation. The same caching extends
  # across all 84 from-source recipes auto-recurse fires for a
  # `--tool-provisioning=from-source` build: cold compile of the first
  # recipe's provider populates the shared cache, every later recipe's
  # provider compile reuses ~99 % of those `.o` files. Across `repro`
  # sessions the key is additionally scoped by a per-session token
  # (`REPRO_PROVIDER_NIMCACHE_SESSION`, see `sharedProviderNimcacheKey`)
  # so concurrent independent `repro` sessions building from the same
  # project tree never share a nimcache directory and never race Nim's
  # incremental rename/rmdir cleanup into an `ENOTEMPTY` abort.
  # `REPRO_PROVIDER_NIMCACHE_MODE=per-binary` restores the legacy
  # per-output isolation.
  let hostFlags = hostCCompilerFlags()
  let libFlags = reproLibPathFlags(workDir)
  # The nimcache root MUST be independent of the per-recipe scratch/out
  # tree, otherwise every recipe's provider compile lands in its own
  # directory and the cross-recipe `.o` sharing M9.R.13a delivers never
  # materialises (auto-recurse fires one scratchDir per recipe). Anchor
  # it under a stable system-temp root on every platform; the full path
  # is then `<temp>/repro-nimcache-provider/<sharedKey>` where the
  # `sharedKey` already scopes by workDir + toolchain + library set +
  # session token, so:
  #   * recipes A and B of the same `repro` session/project share a
  #     nimcache (different scratchDir, identical key) — the speedup;
  #   * different projects / toolchains get different keys (no collision);
  #   * concurrent independent sessions get different session tokens
  #     (the M9.R.12 ENOTEMPTY-collision safety property).
  # Using system-temp rather than the workDir also keeps this working
  # when workDir is a read-only immutable store path, and on Windows the
  # short temp root avoids the MAX_PATH overflow that nested CMake
  # TryCompile scratch trees hit (Nim's mkdir does not use the \\?\
  # extended-length prefix).
  let nimcacheRoot = getTempDir() / "repro-nimcache-provider"
  let nimcache =
    if providerNimcacheMode() == "per-binary":
      nimcacheRoot / providerNimcacheKey(outputBinaryPath)
    else:
      nimcacheRoot / sharedProviderNimcacheKey(workDir, hostFlags, libFlags)
  result = boundedNimCompileCommand()
  result.add(@[
    # Provider compiles are often nested inside latency-sensitive graph
    # construction paths. The default stays serial to avoid observed GCC 15
    # vregs ICEs and unbounded nested compiler bursts. Hosts with a validated
    # toolchain can opt into bounded concurrency through the environment.
    "--define:reproProviderMode",
    "--path:" & parentDir(modulePath),
    "--nimcache:" & nimcache,
    "--out:" & outputBinaryPath,
    modulePath
  ])
  result.insert(hostFlags, 2)
  result.insert(externalHashFlags(workDir), 2)
  result.insert(reproPackagePathFlags(workDir), 2)
  result.insert(libFlags, 2)
  if providerDynamicEnabled():
    # Tier 1 shared DSL runtime DLL: opt-in via ``REPRO_PROVIDER_DYNAMIC=1``.
    # The define switches the DSL umbrella module into dynamic mode and
    # the link flags point at the DLL location produced by
    # ``scripts/build_apps.sh``.
    #
    # The absolute DLL path is also baked into the per-project provider
    # via ``--define:reproProviderDynamicLibPath=<abs>`` so the
    # ``{.dynlib.}`` consumer can ``dlopen``/``LoadLibrary`` the DLL
    # directly when the per-project binary is launched from a directory
    # where the default DLL search order would not find it — notably
    # the deep CMake ``TryCompile`` scratch dirs that the
    # cmake-reprobuild generator hands the engine. On POSIX the link
    # step still emits an rpath so the binary is also self-locating
    # when copied around.
    let libDir = providerDynamicLibDir(workDir)
    let dllExt =
      when defined(windows): "dll"
      elif defined(macosx):  "dylib"
      else:                  "so"
    let dllAbsPath = absolutePath(libDir / ("librepro_project_dsl_runtime." & dllExt))
    var dynamicFlags = @[
      "--define:reproProviderDynamic",
      "--define:reproProviderDynamicLibPath=" & dllAbsPath,
      "--passL:-L" & libDir,
      "--passL:-lrepro_project_dsl_runtime"
    ]
    when not defined(windows):
      dynamicFlags.add("--passL:-Wl,-rpath," & libDir)
    for flag in dynamicFlags:
      result.insert(flag, 2)

proc providerLibraryCompileCommand*(modulePath, outputBinaryPath: string;
                                    mode: ReproRtlMode;
                                    workDir = getCurrentDir();
                                    scratchDir = ""): seq[string] =
  ## The provider-LIBRARY compile command (M4c). Same base as
  ## ``providerCompileCommand`` (full repro ``--path`` set + host flags +
  ## ``-d:reproProviderMode``), rendered as a shared library in the requested
  ## ``ReproRtlMode``. The RTL-mode ``--define``s are inserted BEFORE the
  ## trailing module-path argument (flags after it are treated as run args),
  ## so they land in ``providerCompileOptions`` and re-key the compile action
  ## per mode — a nimRtl-shared artifact and a standalone C-ABI artifact are
  ## DISTINCT cache entries (§4.4).
  result = providerCompileCommand(modulePath, outputBinaryPath, workDir,
    scratchDir)
  for flag in rtlModeDefines(mode):
    result.insert(flag, result.len - 1)

proc providerLibraryCompileActionKey*(modulePath, outputBinaryPath: string;
                                      interfaceFingerprint: ContentDigest;
                                      mode: ReproRtlMode;
                                      workDir = getCurrentDir();
                                      scratchDir = ""): ContentDigest =
  ## The action key for a provider-LIBRARY build in a given ``ReproRtlMode``
  ## (M4c). Reuses the RP1 ``ProviderArtifactId`` machinery — the RTL-mode
  ## ``--define``s enter ``providerCompileOptions``, so the two modes yield
  ## DISTINCT keys by construction. This lets an engine cache/reuse the
  ## nimRtl-shared and standalone C-ABI builds independently before the full
  ## §4.3 library build-edge lands.
  let absoluteModulePath = absolutePath(modulePath)
  let normalizedOutputPath = absolutePath(
    normalizedProviderOutputPath(outputBinaryPath))
  let sources = discoverNimSources(absoluteModulePath)
  let command = providerLibraryCompileCommand(absoluteModulePath,
    normalizedOutputPath, mode, workDir, scratchDir)
  var compileOptions: seq[string] = @[]
  for i in 1 ..< command.len:
    let arg = command[i]
    if arg.startsWith("--out:") or arg.startsWith("--nimcache:") or
        arg == normalizedOutputPath or arg == absoluteModulePath:
      continue
    compileOptions.add(arg)
  let providerArtifactId = computeProviderArtifactId(
    sources, interfaceFingerprint,
    providerCompileOptions = compileOptions, workDir = workDir)
  computeProviderCompileActionKey(providerArtifactId, sources, sources)

proc providerCompilePlan*(modulePath, outputBinaryPath: string;
                          interfaceFingerprint: ContentDigest;
                          workDir = getCurrentDir();
                          scratchDir = ""): ProviderCompilePlan =
  # The compiler runs in an exclusive scratch CWD, so every path that belongs
  # to the provider itself must be independent of that CWD.
  let absoluteModulePath = absolutePath(modulePath)
  let normalizedOutputPath = absolutePath(
    normalizedProviderOutputPath(outputBinaryPath))
  let sources = discoverNimSources(absoluteModulePath)
  let providerFingerprint = providerFingerprintFor(sources, interfaceFingerprint,
    workDir)
  let command = providerCompileCommand(absoluteModulePath,
    normalizedOutputPath, workDir, scratchDir)
  # RP1: derive the v1-named identities. The ``providerCompileOptions`` set is
  # the compiler command minus the compiler path and the ``--out:``/nimcache
  # intermediate flags (which are output-location noise, not semantic inputs).
  var compileOptions: seq[string] = @[]
  for i in 1 ..< command.len:
    let arg = command[i]
    if arg.startsWith("--out:") or arg.startsWith("--nimcache:") or
        arg == normalizedOutputPath or arg == absoluteModulePath:
      continue
    compileOptions.add(arg)
  let providerArtifactId = computeProviderArtifactId(
    sources, interfaceFingerprint,
    providerCompileOptions = compileOptions, workDir = workDir)
  let providerCompileActionKey = computeProviderCompileActionKey(
    providerArtifactId, sources, sources)
  # The engine edge is keyed by the v1 ProviderCompileActionKey so the
  # action-cache HIT/rebuild decision follows the v1 identity exactly.
  let edge = providerCompileEdge(sources, normalizedOutputPath, command,
    interfaceFingerprint, providerFingerprint, workDir = workDir,
    knownActionFingerprint = some(providerCompileActionKey))
  ProviderCompilePlan(
    inputSources: sources,
    outputBinaryPath: normalizedOutputPath,
    compilerCommand: command,
    compileEdge: edge,
    interfaceFingerprint: interfaceFingerprint,
    providerFingerprint: providerFingerprint,
    providerArtifactId: providerArtifactId,
    providerCompileActionKey: providerCompileActionKey,
    workDir: workDir)

proc providerCompileArtifactFresh*(artifactPath, outputBinaryPath: string;
                                   interfaceFingerprint,
                                   providerFingerprint: ContentDigest;
                                   workDir = getCurrentDir()): bool =
  let normalizedOutputPath = normalizedProviderOutputPath(outputBinaryPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(normalizedOutputPath))):
    return false
  try:
    let cached = readProviderCompileArtifact(artifactPath)
    if cached.providerFingerprint != providerFingerprint:
      return false
    if cached.interfaceFingerprint != interfaceFingerprint:
      return false
    if cached.outputBinaryPath != normalizedOutputPath:
      return false
    if cachedProviderFreshnessByMetadata(artifactPath, "", normalizedOutputPath,
        workDir, cached.inputSources, cached):
      return true
    if cached.outputBinaryFingerprint != casDigest(toBytes(readFile(
        extendedPath(normalizedOutputPath)))):
      return false
    return true
  except CatchableError:
    false

proc readFreshProviderCompileArtifact*(artifactPath, modulePath,
                                       outputBinaryPath: string;
                                       interfaceFingerprint: ContentDigest;
                                       workDir = getCurrentDir()):
    Option[ProviderCompileArtifact] =
  ## UNSOUND AS A GATE IN FRONT OF THE PROVIDER-COMPILE EDGE. Its key is a
  ## TEXT import walk of the recipe (``discoverNimSources``), so anything the
  ## compile acquires without an ``import``/``include`` statement — a
  ## ``staticRead`` payload, a ``staticExec`` result, a dependency a macro
  ## resolves during expansion — is invisible to it, and it fails by serving a
  ## stale provider binary behind a green build rather than by erroring. The
  ## equivalent gate on the interface-extraction edge was removed for exactly
  ## this reason (Compiles-Are-Normal-Edges.md; reprobuild 66bdb188).
  ##
  ## It survives for two callers only:
  ##
  ##   * the in-process ``compileProviderBinary`` path (tests, bootstrap),
  ##     which has no engine to defer to; and
  ##   * ``staticFreshnessFallbackProvider`` below, i.e. the one configuration
  ##     where the engine edge provably cannot publish.
  ##
  ## Do NOT reintroduce it in front of a cacheable provider-compile edge. The
  ## engine decides whether that edge re-runs, from the monitored read set.
  let normalizedOutputPath = normalizedProviderOutputPath(outputBinaryPath)
  if not (fileExists(extendedPath(artifactPath)) and fileExists(extendedPath(normalizedOutputPath))):
    return none(ProviderCompileArtifact)
  try:
    let cached = readProviderCompileArtifact(artifactPath)
    if cached.interfaceFingerprint != interfaceFingerprint:
      return none(ProviderCompileArtifact)
    if cached.outputBinaryPath != normalizedOutputPath:
      return none(ProviderCompileArtifact)
    let sources = discoverNimSources(modulePath)
    if cachedProviderFreshnessByMetadata(artifactPath, modulePath,
        normalizedOutputPath, workDir, sources, cached):
      return some(cached)
    let providerFingerprint = providerFingerprintFor(sources,
      interfaceFingerprint, workDir)
    if cached.providerFingerprint != providerFingerprint:
      return none(ProviderCompileArtifact)
    if cached.outputBinaryFingerprint != casDigest(toBytes(readFile(
        extendedPath(normalizedOutputPath)))):
      return none(ProviderCompileArtifact)
    writeProviderFreshnessCacheRecord(artifactPath, modulePath, workDir, cached)
    return some(cached)
  except CatchableError:
    return none(ProviderCompileArtifact)

proc staticFreshnessFallbackProvider*(plan: ProviderCompilePlan;
                                      artifactPath, modulePath,
                                      outputBinaryPath: string;
                                      interfaceFingerprint: ContentDigest;
                                      workDir = getCurrentDir()):
    Option[ProviderCompileArtifact] =
  ## The ONLY surviving short-circuit in front of the provider-compile edge.
  ##
  ## In the normal configuration this returns ``none`` unconditionally: the
  ## compile is an ordinary monitored edge and the engine's action cache — keyed
  ## on the argv plus everything the compile was OBSERVED to read — is what
  ## decides whether it re-runs. That is strictly stronger than the text
  ## closure, and it is what makes a ``staticRead``/``staticExec`` dependency an
  ## input by construction rather than by somebody's list.
  ##
  ## It returns the hand-keyed freshness answer in exactly one state: when
  ## ``providerCompileCacheable(plan)`` is false, i.e. Linux with a static-ELF
  ## compiler that ``LD_PRELOAD`` cannot inject the io-mon shim into. There the
  ## edge can neither publish nor hit, and — because the compiler's own reads
  ## are unobservable in that state — the engine's evidence is no more complete
  ## than the text closure is. Without this fallback such a host would pay a
  ## full provider compile (measured ~5 min) on EVERY build, for no gain in
  ## soundness: a monitored edge is never eligible for the engine's
  ## outputs-present short-circuit (``needsExecutionForPolicy``), so it always
  ## launches when the action cache is unavailable.
  ##
  ## Narrowing it to that state is the point: on every host where the shim can
  ## be injected, the unsound key is not consulted at all.
  if providerCompileCacheable(plan):
    return none(ProviderCompileArtifact)
  readFreshProviderCompileArtifact(artifactPath, modulePath, outputBinaryPath,
    interfaceFingerprint, workDir)

proc compileProviderBinary*(modulePath, outputBinaryPath: string;
                            interfaceFingerprint: ContentDigest;
                            artifactPath = "";
                            workDir = getCurrentDir();
                            scratchDir = "";
                            useFreshnessCache = true): ProviderCompileArtifact =
  ## ``useFreshnessCache`` controls the built-in warm short-circuit. It is
  ## ``false`` for exactly one caller: the child of the provider-compile EDGE
  ## (``repro __repro-compile-provider``). This mirrors
  ## ``extractInterfaceFromModule``'s ``useExtractionCache``.
  ##
  ## The short-circuit is keyed by ``providerFingerprintFor``, whose source
  ## closure is an import walk of the recipe's TEXT. It cannot see a dependency
  ## the compile acquires without an import statement — a ``staticRead``
  ## payload, a ``staticExec`` result, a module a macro resolves during
  ## expansion. When the engine has decided the edge must re-run, it did so
  ## from monitored evidence that DOES see those files; consulting the narrower
  ## key inside the child would veto the engine's decision and re-publish the
  ## very stale binary the edge was re-run to replace.
  let plan = providerCompilePlan(modulePath, outputBinaryPath,
    interfaceFingerprint, workDir, scratchDir)
  if useFreshnessCache and artifactPath.len > 0 and
      providerCompileArtifactFresh(artifactPath,
        plan.outputBinaryPath, interfaceFingerprint, plan.providerFingerprint,
        plan.workDir):
    return readProviderCompileArtifact(artifactPath)
  createDir(extendedPath(parentDir(plan.outputBinaryPath)))
  let compilerCwdRoot =
    if scratchDir.len > 0:
      absolutePath(scratchDir)
    else:
      absolutePath(parentDir(plan.outputBinaryPath))
  createDir(extendedPath(compilerCwdRoot))
  # Nim writes linker response files relative to CWD. Allocate that CWD with
  # an atomic create-and-retry operation so concurrent compiles in the same
  # process cannot collide even when their clocks and PID are identical.
  let compilerCwd = createTempDir("provider-compiler-cwd-", "",
    compilerCwdRoot)
  defer:
    try:
      removeDir(extendedPath(compilerCwd))
    except OSError:
      discard
  # Keep the immutable library lookup root (`workDir`) out of the write path.
  # Nim emits relative linker response files in CWD even though `--nimcache`
  # and `--out` are absolute.
  let execution = runProviderCompilerCommand(plan.compilerCommand, compilerCwd)
  if not fileExists(extendedPath(plan.outputBinaryPath)):
    raise newException(IOError,
      "provider compilation did not write binary: " & plan.outputBinaryPath &
        "\n" & execution.output)
  # Windows: the provider binary links repro's DSL, which pulls in
  # `repro_solver` and its module-init clingo dlopen — the same requirement the
  # interface-extract runner has. The provider is spawned directly from its own
  # scratch directory (`repro_provider_runtime/runtime.nim`), so LoadLibrary
  # searches THAT directory, not repro's bin. Without this the provider aborts
  # at startup with `could not load: clingo.dll` on any host that does not
  # carry clingo on PATH.
  stageHostDynlibsBesideBinary(parentDir(plan.outputBinaryPath))
  result = ProviderCompileArtifact(
    inputSources: plan.inputSources,
    outputBinaryPath: plan.outputBinaryPath,
    compilerCommand: plan.compilerCommand,
    compileEdge: plan.compileEdge,
    interfaceFingerprint: interfaceFingerprint,
    providerFingerprint: plan.providerFingerprint,
    outputBinaryFingerprint: casDigest(toBytes(readFile(
        extendedPath(plan.outputBinaryPath)))),
    executionResult: execution)
  if artifactPath.len > 0:
    writeProviderCompileArtifact(artifactPath, result)
    writeProviderFreshnessCacheRecord(artifactPath, modulePath, workDir, result)

# ---------------------------------------------------------------------
# TI1 — the interface-lift EDGE.
#
# Project-Interface-Artifacts-And-Import-Modes.md §"Automatic Interface
# Lifting" makes the interface artifact a first-class build product. TI1
# turns the LIFT into a cached, content-addressed engine build edge —
# mirroring RP1's provider-compile edge — so a producer's interface is
# lifted ONCE and read from cache, not re-extracted per consumer (the
# RP5a ``staticExec``-per-consumer workaround this replaces).
#
# Two identities, exactly parallel to RP1's (artifact-id vs action-key):
#
#   InterfaceLiftActionKey = hash(
#     "lift-interface", interfaceFormatVersion, nimCompilerIdentity,
#     canonicalSourceInputPaths+content (producer closure + resource
#     module closure), resource-module identity, extra-path set)
#     — the engine edge's action key. Input-keyed: any source edit (public
#       OR private) re-keys the LIFT so the edge re-runs. This is correct:
#       a private edit must still re-run the lift to CONFIRM the public
#       surface is unchanged; the confirmation is cheap and the RESULT is
#       the InterfaceFingerprint, which is what actually gates downstream.
#
#   InterfaceFingerprint = hash(ProjectInterface public surface only)
#     — the OUTPUT identity (``interfaceFingerprint`` above). Excludes
#       ``build:``/driver bodies + private helpers by CONSTRUCTION: it
#       hashes the projected ``ProjectInterface`` (public exec/lib/resource
#       decls + signatures), never the source closure. So a private/driver
#       edit re-runs the lift but yields the SAME InterfaceFingerprint —
#       the load-bearing TI3-readiness property established here.

const
  InterfaceFormatVersion* = EnvelopeVersion
    ## The "relevant frontend/interface format version" the spec's
    ## ``InterfaceFingerprint`` names — reuses the codec envelope version so a
    ## format bump re-keys every lift.

proc interfaceLiftActionKey*(
    canonicalSourceInputPaths: openArray[string];
    resourceModule = "";
    extraPaths: openArray[string] = [];
    workDir = getCurrentDir()): ContentDigest =
  ## The TI1 ``InterfaceLiftActionKey`` — the engine edge's action key,
  ## analogous to RP1's ``ProviderCompileActionKey``. Keyed by the canonical
  ## (root-relative path, content) source set, the resource-module identity,
  ## the extra ``--path`` set, the Nim frontend identity, and the interface
  ## format version. Content-addressed (paths made relative to the source
  ## closure root, like ``projectSourceSemanticIdentity``) so two consumers
  ## whose lift inputs are byte-identical converge on the same key.
  var normalized: seq[string] = @[]
  for path in canonicalSourceInputPaths:
    normalized.add(normalizedStampPath(path))
  let root = commonSourceRoot(normalized)
  var payload: seq[byte] = @[]
  payload.writeString("lift-interface")
  payload.writeU32Le(uint32(InterfaceFormatVersion))
  payload.writeString(nimCompilerIdentity())
  payload.writeString(frontendRuntimeIdentity(workDir))
  for path in normalized:
    let relPath =
      if root.len > 0 and path == root: extractFilename(path)
      elif root.len > 0 and path.startsWith(root & "/"):
        path[root.len + 1 .. ^1]
      else: extractFilename(path)
    payload.writeString(relPath)
    let content =
      if fileExists(extendedPath(path)): toBytes(readFile(extendedPath(path)))
      else: @[]
    payload.writeU64Le(uint64(content.len))
    payload.add(content)
  payload.writeString(
    if resourceModule.len > 0: extractFilename(normalizedStampPath(resourceModule))
    else: "")
  var extras: seq[string] = @[]
  for extra in extraPaths:
    if extra.len > 0:
      extras.add(extractFilename(normalizedStampPath(extra)))
  extras.sort(system.cmp[string])
  payload.writeStringSeq(extras)
  blake3DomainDigest(payload, hdActionFingerprint)

proc interfaceLiftMetadata(declaredInputs, declaredOutputs: openArray[string];
                           interfaceLiftActionKey: ContentDigest): DynamicValue =
  var inputValues: seq[DynamicValue] = @[]
  for value in declaredInputs:
    inputValues.add(cborText(value))
  var outputValues: seq[DynamicValue] = @[]
  for value in declaredOutputs:
    outputValues.add(cborText(value))
  cborMap([
    entry("kind", cborText("interfaceLift")),
    entry("schema", cborUInt(1)),
    entry("declaredInputs", cborArray(inputValues)),
    entry("declaredOutputs", cborArray(outputValues)),
    entry("interfaceLiftActionKey", digestHexValue(interfaceLiftActionKey))
  ])

proc interfaceLiftPlan*(modulePath, artifactPath, stubPath: string;
                        resourceModule = "";
                        extraPaths: openArray[string] = [];
                        workDir = getCurrentDir()): InterfaceLiftPlan =
  ## TI1: build the interface-lift edge plan for a producer. The declared
  ## inputs are the producer's source closure (plus the resource-module
  ## closure when declared); the declared outputs are the interface artifact +
  ## stub. The engine edge is keyed by the ``InterfaceLiftActionKey``.
  let sources = interfaceLiftSources(modulePath, resourceModule, extraPaths)
  let actionKey = interfaceLiftActionKey(sources, resourceModule, extraPaths,
    workDir)
  let declaredInputs = sources
  var declaredOutputs = @[artifactPath]
  if stubPath.len > 0:
    declaredOutputs.add(stubPath)
  let process = directProcess(corepaths.normalizedPath(nimCompilerPath()), [],
    corepaths.normalizedPath(workDir))
  let edge = InterfaceLiftEdge(
    actionSpec: ActionSpec(
      actionId: stableIdFromDigest(actionKey),
      process: process,
      dependencyPolicy: automaticMonitorGatheringPolicy(),
      metadata: interfaceLiftMetadata(declaredInputs, declaredOutputs,
        actionKey)),
    declaredInputs: declaredInputs,
    declaredOutputs: declaredOutputs,
    actionFingerprint: actionKey)
  InterfaceLiftPlan(
    modulePath: modulePath,
    resourceModule: resourceModule,
    extraPaths: @extraPaths,
    artifactPath: artifactPath,
    stubPath: stubPath,
    inputSources: sources,
    liftEdge: edge,
    interfaceLiftActionKey: actionKey,
    workDir: workDir)

proc interfaceArtifactFresh*(plan: InterfaceLiftPlan): bool =
  ## TI1: is the on-disk interface artifact a cache HIT for this plan? Fresh
  ## iff the artifact exists AND the recomputed ``InterfaceLiftActionKey`` is
  ## unchanged (the extraction cache record already gates the underlying
  ## extractor on the same input closure). A stale artifact returns false and
  ## the lift edge re-runs.
  if plan.artifactPath.len == 0 or
      not fileExists(extendedPath(plan.artifactPath)):
    return false
  try:
    let sidecar = interfaceLiftActionKeyPath(plan.artifactPath)
    if not fileExists(extendedPath(sidecar)):
      return false
    let stored = readFile(extendedPath(sidecar)).strip()
    stored == toHex(plan.interfaceLiftActionKey.bytes)
  except CatchableError:
    false

proc liftInterfaceArtifact*(plan: InterfaceLiftPlan): ProjectInterfaceArtifact =
  ## TI1: MATERIALIZE the interface-lift edge — run the lift once and cache
  ## the ``ProjectInterfaceArtifact`` keyed by the ``InterfaceLiftActionKey``.
  ## A second call with an unchanged input closure is a cache HIT (the
  ## underlying ``extractInterfaceFromModule`` short-circuits on its own
  ## extraction cache; here we additionally short-circuit on the action-key
  ## sidecar so the lift edge is not re-run). The persisted artifact round-
  ## trips through the existing ``ProjectInterfaceArtifact`` codec.
  if interfaceArtifactFresh(plan):
    return readInterfaceArtifactWithWarm(plan.artifactPath)
  # The consumer root for a LIFT is the lifted recipe's OWN project root, not
  # the process cwd. This path lifts a PRODUCER's interface while the process
  # is sitting in a CONSUMER's directory, so an ambient ``getCurrentDir()``
  # would compile the producer's recipe with the consumer's root baked in —
  # and would give a different answer for every consumer that lifted it.
  result = extractInterfaceFromModule(plan.modulePath, plan.artifactPath,
    plan.stubPath, plan.workDir, requireStub = plan.stubPath.len > 0,
    resourceModule = plan.resourceModule, extraPaths = plan.extraPaths,
    consumerRoot = parentDir(absolutePath(plan.modulePath)))
  try:
    writeFile(extendedPath(interfaceLiftActionKeyPath(plan.artifactPath)),
      toHex(plan.interfaceLiftActionKey.bytes))
  except CatchableError:
    discard
