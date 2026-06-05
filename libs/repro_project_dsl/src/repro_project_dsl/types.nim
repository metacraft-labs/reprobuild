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

  TypedOutputDef* = object
    ## Typed-Outputs M0: one record per typed ``outputs`` statement of the
    ## form ``outputs <fieldName> is <Type1>[, <Type2>...], <pathExpression>``.
    ##
    ## The first type names the static type of the field emitted on the
    ## per-tool-call ``BuildEdge`` subtype (see ``macros_a.nim``'s
    ## ``buildEdgeSubtypeName`` / ``toolActionWrapperCode``). Additional
    ## types tag the output as implementing further interfaces so
    ## reprobuild's type-class-style framework recognition can find it
    ## without re-parsing the DSL (consumed by M1 onwards).
    ##
    ## ``pathExpr`` is stored as the verbatim source repr of the
    ## ``NimNode`` written at the declaration site. The expression is NOT
    ## evaluated at parse time — M1 reparses it (via
    ## ``parseExpr(pathExpr)``) at action-emission time to bind the
    ## runtime path against the call-site flag values. Storing the source
    ## form, rather than a live ``NimNode``, lets the parsed
    ## ``PackageDef`` round-trip through ``packageLiteral`` and survive
    ## as a runtime ``const`` like every other field on ``CliCommandDef``.
    fieldName*: string
    types*: seq[string]
    pathExpr*: string
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
    typedOutputs*: seq[TypedOutputDef]
      ## Typed-Outputs M0: one entry per ``outputs <fieldName> is <Type>...,
      ## <pathExpr>`` statement seen on the lexical path from the cli root
      ## to this command (parent entries flow into nested ``subcmd`` scopes
      ## the same way ``outputFlags`` does). Each entry contributes one
      ## typed field on the per-call ``BuildEdge`` subtype.
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
    implicitTargetNameHookCallType*: string
      ## Named-Targets M1: when ``hasImplicitTargetNameHook`` is true, the
      ## user-written parameter type from the hook spec
      ## (``implicitTargetName(call: <T>): string``). The M1 wrapper emits
      ## code at every typed-tool call site that constructs an instance of
      ## ``<T>`` from the call's actual flag values and passes it to
      ## ``implicitTargetNameFor<TitleExportName>``.
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

  BuildActionTypedOutput* = object
    ## Typed-Outputs M1: one entry per typed ``outputs <field> is
    ## <Type>..., <pathExpr>`` declaration that fires at a typed-tool
    ## call site. The wrapper proc evaluates the ``pathExpr`` against
    ## the call-site flag values and records the resulting path here
    ## together with the declared field name and type identifiers.
    ##
    ## Downstream consumers (the CLI resolver, ``repro why``, the
    ## codetracer ``repro test`` integration) read this list directly
    ## off the build edge to identify outputs implementing interfaces
    ## like ``TestBinary`` without re-parsing the DSL.
    fieldName*: string
    types*: seq[string]
    path*: string

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
    targetNames*: seq[string]
      ## Named-Targets M1: implicit names recorded per build edge. One
      ## entry per flag in the call's subcommand's cumulative
      ## ``outputFlags`` set whose value the call supplied, reduced to
      ## a basename with conventional artifact extensions stripped. When
      ## the executable defines an ``implicitTargetName`` hook the
      ## first (canonical) entry is replaced by the hook's return value;
      ## auxiliary entries from additional output flags remain.
    typedOutputs*: seq[BuildActionTypedOutput]
      ## Typed-Outputs M1: per-output (fieldName, types, path) entries
      ## populated at typed-tool wrapper-proc emission time. The
      ## ``path`` value is the runtime evaluation of the declared
      ## ``pathExpr`` against the call's flag values. Carries through
      ## the payload codec (v12+) so the engine and downstream
      ## consumers can identify framework-specific outputs (e.g.
      ## those implementing ``TestBinary``) without re-parsing the
      ## DSL.
    sourceFile*: string
    sourceLine*: int

  BuildTargetDef* = object
    name*: string
    actions*: seq[string]
    targets*: seq[string]
    sourceFile*: string
    sourceLine*: int

  BuildPoolDef* = object
    name*: string
    capacity*: uint32

  TargetExportKind* = enum
    ## Named-Targets M1: per-edge target-name origin marker.
    tekImplicit  ## Computed from ``outputs`` statements and optional hook.
    tekExplicit  ## Declared via ``target "name", handle`` in the DSL.

  TargetExportEntry* = object
    ## Named-Targets M1: one row in the project-scoped target-export
    ## table for every implicit or explicit target name. Edges with
    ## multiple ``targetNames`` contribute one entry per name, all
    ## carrying the same ``actionId`` so a single edge is selectable
    ## by any of its names.
    name*: string
      ## The implicit name (basename after extension stripping, or
      ## the hook's return value) or the explicit ``target "name", ...``
      ## label.
    kind*: TargetExportKind
    owningPackage*: string
    actionId*: string
      ## Engine handle: the ``BuildActionDef.id`` of the edge that
      ## produces this target. M2 will use the qualified
      ## ``<owningPackage>:<name>`` form to disambiguate cross-package
      ## collisions.
    sourceFile*: string
    sourceLine*: int

  TargetExportAmbiguity* = object
    ## Named-Targets M1: cross-package ambiguity record. When two or
    ## more packages register the same unqualified name, one entry is
    ## kept here listing the candidate qualified forms (``<package>:<name>``)
    ## so M2's resolver can surface the diagnostic.
    name*: string
    candidates*: seq[string]
      ## ``<owningPackage>:<name>`` candidate strings, in registration
      ## order.

  TargetExportTable* = object
    entries*: seq[TargetExportEntry]
    ambiguities*: seq[TargetExportAmbiguity]
