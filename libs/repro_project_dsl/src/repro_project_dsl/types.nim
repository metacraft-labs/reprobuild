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

  TestDef* = object
    ## Test-Edges-And-Parallel-Runner M0: parsed shape of a ``test
    ## <ident>:`` block. The block ident contributes the kebab-cased
    ## implicit name used in the default output path
    ## (``build/test-bin/<ident-kebab>``); the resulting edge's
    ## ``targetNames`` are derived by the M1 wiring from the synthesised
    ## ``output`` argument's basename per Named-Targets M1, NOT from
    ## the ident itself.
    ##
    ## The DSL collects these defs onto ``PackageDef.tests`` purely as
    ## an inspection record; the actual ``BuildActionDef`` is materialised
    ## by code emitted from ``synthesizeTestBuildStatements`` and merged
    ## into the package's ``build:`` body by ``macros_b``'s
    ## ``collectBuildStatements`` walker. The edge is marked
    ## ``kind = bakTest`` at materialisation time via
    ## ``setRegisteredActionKind``.
    ident*: string
      ## Original Nim identifier of the block (e.g. ``localBuildEngineSmoke``).
    kebabName*: string
      ## Lower-cased, dash-separated form of ``ident`` (the default
      ## implicit name; overridden by ``nameOverride`` when set).
    nameOverride*: string
      ## Value of the ``name "..."`` setter when supplied; empty otherwise.
    source*: string
      ## Value of the required ``source "..."`` setter — the test's
      ## single Nim entry-point path.
    hasExplicitBuild*: bool
      ## True when the block carried an explicit ``build:`` body. The
      ## materialisation code emits that body verbatim and tags its
      ## resulting edge ``bakTest``; the default ``nim.c(...)`` synthesis
      ## is skipped in that case so the user keeps full control.
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
    tests*: seq[TestDef]
      ## Test-Edges-And-Parallel-Runner M0: parsed ``test <ident>:`` blocks
      ## declared at the top level of the package body. The collection is
      ## inspection-only — the actual build edges are emitted from code
      ## injected into the package's ``build:`` body by ``macros_b``.
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

  BuildActionEdgeKind* = enum
    ## Test-Edges-And-Parallel-Runner M0: per-edge metadata marker that
    ## classifies a build action. ``bakAction`` is the default for every
    ## ordinary build edge (e.g. a typed-tool wrapper call inside a
    ## ``build:`` body). ``bakTest`` is set on edges synthesised by the
    ## DSL ``test`` block so downstream consumers (``repro test``,
    ## ``repro why``, the protocol-level runner) can enumerate test
    ## edges via the normalized-graph artifact without scanning the
    ## whole graph. Implicit-name resolution remains uniform across
    ## kinds — this field carries metadata, not target-export
    ## semantics.
    bakAction
    bakTest

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
    kind*: BuildActionEdgeKind
      ## Test-Edges-And-Parallel-Runner M0: per-edge kind marker. Defaults
      ## to ``bakAction``; the DSL ``test`` block re-tags its synthesised
      ## edge as ``bakTest`` via ``setRegisteredActionKind`` so consumers
      ## can enumerate test edges from the normalized-graph artifact.
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
