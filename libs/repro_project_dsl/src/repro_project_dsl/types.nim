type
  BuildActionPayloadError* = object of CatchableError

  Tool*[name: static string] = object

  ReproFs* = object
  ReproHcr* = object

  CliParamKind* = enum
    cpkPositional
    cpkFlag

  CliArgRole* = enum
    carOrdinary
    carInput
    carOutput

  CliArgFormat* = enum
    cafSeparate
    cafConcat
    cafEquals

  CliArgPlacement* = enum
    capAfterSubcommand
    capBeforeSubcommand

  CliParamDef* = object
    name*: string
    nimType*: string
    kind*: CliParamKind
    role*: CliArgRole
    format*: CliArgFormat
    placement*: CliArgPlacement
    repeated*: bool
    position*: int
    alias*: string
    required*: bool
    sourceFile*: string
    sourceLine*: int

  CliCommandDef* = object
    name*: string
    path*: seq[string]
      ## Full lexical path from the cli root to this command. For a top-level
      ## ``subcmd "build"``, the path is ``@["build"]``. For a nested
      ## ``subcmd "build": subcmd "target"`` the inner command has path
      ## ``@["build", "target"]``. Anonymous ``call:`` keeps the path empty.
    params*: seq[CliParamDef]
    dependencyPolicy*: BuildActionDependencyPolicy
    providerEntrypointId*: string
    outputFlags*: seq[string]
      ## Named-Targets M0: cumulative union of every ``outputs`` statement on
      ## the lexical path from the cli root to this command, materialised per
      ## subcommand at parse time. The DSL only records names; the M1 engine
      ## evaluates them against actual call values and runs the basename rule.
    sourceFile*: string
    sourceLine*: int

  ExecutableDef* = object
    exportName*: string
    binaryName*: string
    commands*: seq[CliCommandDef]
    hasImplicitTargetNameHook*: bool
      ## Named-Targets M0: true when the ``executable`` body contains an
      ## ``implicitTargetName(call: <TypedCallRecord>): string`` block. The
      ## hook itself is emitted as a plain Nim proc by the macro; this flag
      ## is the inspection point the M1 engine reads to decide whether to
      ## invoke it.
    sourceFile*: string
    sourceLine*: int

  LibraryKind* = enum
    lkStatic        ## Default — produces a .a / .lib archive
    lkShared        ## Produces a .so / .dylib / .dll
    lkBoth          ## Both static and shared (rare)
    lkHeaderOnly    ## No compile/link — just header export

  LibraryDef* = object
    name*: string
    kind*: LibraryKind
    sourceFile*: string
    sourceLine*: int

  PackageUseDef* = object
    rawConstraint*: string
    packageSelector*: string
    executableName*: string
    policyPath*: seq[string]
    sourceFile*: string
    sourceLine*: int

  NixPackageProvisioningDef* = object
    selector*: string
    executablePath*: string
    expressionFile*: string
    nixpkgsRef*: string
    nixpkgsRev*: string
    nixpkgsNarHash*: string
    packageId*: string
    lockIdentity*: string
    sourceFile*: string
    sourceLine*: int

  TarballProvisioningDef* = object
    url*: string
    mirrors*: seq[string]
    sha256*: string
    archiveType*: string
    executablePath*: string
    stripComponents*: int
    packageId*: string
    lockIdentity*: string
    sourceFile*: string
    sourceLine*: int

  ScoopProvisioningDef* = object
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
    sourceFile*: string
    sourceLine*: int

  PackageDef* = object
    packageName*: string
    defaultToolProvisioning*: string
    executables*: seq[ExecutableDef]
    libraries*: seq[LibraryDef]
    toolUses*: seq[PackageUseDef]
    nixProvisioning*: seq[NixPackageProvisioningDef]
    tarballProvisioning*: seq[TarballProvisioningDef]
    scoopProvisioning*: seq[ScoopProvisioningDef]
    usesImportPaths*: seq[string]
    publicSignatureDependencies*: seq[string]
    hasDevEnv*: bool
    devEnvBodyHash*: string
    sourceFile*: string
    sourceLine*: int

  ProviderForeachDef* = object
    id*: string
    bodyHash*: string
    stableName*: string

  PublicCliArg* = object
    name*: string
    nimType*: string
    kind*: CliParamKind
    role*: CliArgRole
    format*: CliArgFormat
    placement*: CliArgPlacement
    repeated*: bool
    position*: int
    alias*: string
    encodedValue*: string

  PublicCliCall* = object
    packageName*: string
    executableName*: string
    subcommand*: string
    providerEntrypointId*: string
    arguments*: seq[PublicCliArg]

  BuildActionDependencyPolicyKind* = enum
    bdpDefault
    bdpDeclaredOnly
    bdpAutomaticMonitor
    bdpMakeDepfile

  BuildActionDependencyPolicy* = object
    kind*: BuildActionDependencyPolicyKind
    depfile*: string
    ignoredInputPrefixes*: seq[string]

  ActionCacheFingerprintPolicy* = enum
    acfpTimestamp
    acfpChecksum
    acfpHybrid

  SelectedExecutable* = object
    packageName*: string
    executableName*: string

  BuildActionDef* = object
    id*: string
    call*: PublicCliCall
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    pool*: string
    poolUnits*: uint32
    depfile*: string
    dynamicDepsFile*: string
    cacheable*: bool
    commandStatsId*: string
    dependencyPolicy*: BuildActionDependencyPolicy
    actionCachePolicy*: ActionCacheFingerprintPolicy

  BuildTargetDef* = object
    name*: string
    actions*: seq[string]
    targets*: seq[string]

  BuildPoolDef* = object
    name*: string
    capacity*: uint32
