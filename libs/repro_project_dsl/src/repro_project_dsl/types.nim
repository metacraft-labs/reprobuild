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
    gateVariant*: string
      ## Spec-Implementation M2d: when non-empty, this ``uses:`` entry
      ## was collected from a variant-conditioned arm (``if
      ## <variant>.value: ...`` or ``case <variant>.value: of "value":
      ## ...``). The arm only contributes the dependency when the named
      ## variant resolves to ``gateValue``. M2d's solver-driven
      ## ``finalizeVariants()`` propagates the gate through
      ## ``ConditionalGate`` in the solver's ``DependencyDecl``.
    gateValue*: string
      ## The variant value that activates the gate. For ``case
      ## compiler.value: of "gcc": "gcc >=12 <15"`` this is ``"gcc"``;
      ## for ``if enableTLS.value: "openssl >=3.3 <4.0"`` this is
      ## ``"true"`` (bool variants encode triggers as the string form).

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
    # Per-platform targeting. Empty (= "any") means the entry matches
    # any host. Multiple ``tarball(...)`` entries inside one
    # ``provisioning:`` block let a single package definition serve
    # several (cpu, os) combinations; the resolver picks the first
    # entry whose (cpu, os) constraints match the host. Allowed
    # values mirror the M63 ``PlatformCpu`` / ``PlatformOs``
    # taxonomy: cpu ∈ {"", "any", "x86_64", "aarch64"}; os ∈ {"",
    # "any", "windows", "linux", "macos", "darwin"} (``darwin`` is
    # an alias for ``macos``).
    cpu*: string
    os*: string
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

  VariantDecl* = object
    ## Spec-Implementation M1: one entry per variant declared in a
    ## package ``config:`` block. Both spellings — ``variant: T =
    ## default`` and ``name: T = default`` paired with a ``@variant``
    ## doc directive — produce the same record. The ``package`` macro
    ## consumes the list to emit one ``declareVariant[T](...)`` per
    ## entry plus a single ``finalizeVariants()`` call afterwards.
    name*: string
    nimType*: string
      ## The Nim type the variant resolves to. Typically ``bool``,
      ## ``string``, or ``int``; the M1 CLI override parser handles
      ## those three. Enum and compound types are accepted at the
      ## declaration level but the CLI parser raises at override time
      ## (until M2 broadens parsing).
    defaultExpr*: string
      ## Source-form Nim expression for the default value. Re-parsed
      ## by the ``package`` macro into the lowered
      ## ``declareVariant[T](...)`` call.
    description*: string
    explicitId*: string
    sourceFile*: string
    sourceLine*: int

  OutputDef* = object
    ## Recipe-Val M8: one entry per logical Nix-style package output
    ## (``$out`` / ``$out-man`` / ``$out-doc`` / ``$out-dev``). A
    ## recipe declares its outputs in an ``outputs:`` section inside
    ## the ``package`` block; each output is materialised at its own
    ## content-addressed store prefix with its own realization hash.
    ##
    ## Empty ``PackageDef.outputs`` keeps legacy single-output
    ## behavior: every build artifact lands in one prefix named
    ## after the package, matching the pre-M8 store layout.
    name*: string
      ## Logical output name. Conventional names are ``bin`` /
      ## ``man`` / ``doc`` / ``dev``; ``out`` is the default
      ## (synthesised when ``outputs:`` is absent).
    actionIds*: seq[string]
      ## Build actions whose materialised outputs flow into this
      ## per-output prefix. Populated by the build-graph normalizer
      ## at apply time from the ``outputTag`` field on each
      ## ``BuildActionDef``; surface DSL recipes leave it empty.
    paths*: seq[string]
      ## Per-output file globs taken from the recipe's ``outputs:``
      ## block (e.g. ``"share/man/**"`` for the ``man`` output).
      ## Used by the store split path to partition the realized
      ## payload across per-output prefixes.
    inheritsDefault*: bool
      ## When true, this output also receives whatever paths are
      ## NOT claimed by any other output. The synthesised default
      ## ``out`` output sets this flag so legacy single-output
      ## recipes (with no ``outputs:`` section) preserve their
      ## "everything in one prefix" layout.
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
    variants*: seq[VariantDecl]
    outputs*: seq[OutputDef]
      ## Recipe-Val M8: declared Nix-style package outputs. Empty
      ## means "legacy single-output recipe — everything goes into
      ## one ``out`` prefix"; the store layer synthesises a default
      ## ``out`` ``OutputDef`` at realize time when this is empty so
      ## the on-the-wire representation of single-output recipes is
      ## indistinguishable from pre-M8 recipes (no payload bytes
      ## emitted by the ``outputs:`` section).
      ## Spec-Implementation M1: variants declared in the package's
      ## ``config:`` block. The ``package`` macro emits one
      ## ``declareVariant[T](...)`` call per entry followed by
      ## ``finalizeVariants()`` so subsequent ``build:`` code can read
      ## each variant's ``.value`` as a concrete Nim value.

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
    bdpAutomaticMonitor
    bdpMakeDepfile

  BuildActionDependencyPolicy* = object
    kind*: BuildActionDependencyPolicyKind
    depfiles*: seq[string]
      ## MR16: zero or more depfile path patterns the engine reads as
      ## recognized ``make-depfile`` reports. Each entry may be a
      ## literal path OR a glob (``*``, ``?``, ``**``) expanded at
      ## evidence-collection time against the action's cwd. Multiple
      ## entries are aggregated into a single
      ## ``RecognizedDependencyReportSpec`` with one
      ## ``ExpectedDependencyFile`` per path. The legacy single
      ## ``depfile: string`` field has been removed; recipes that need
      ## one depfile pass a one-element ``depfiles`` seq.
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
    outputTag*: string
      ## Recipe-Val M8: which package-output (``$out`` / ``$out-man``
      ## / ``$out-doc`` / ``$out-dev``, declared via ``OutputDef`` on
      ## ``PackageDef.outputs``) this edge contributes to. Default
      ## (empty string OR ``"out"``) means "contributes to the
      ## default ``out`` output," preserving legacy single-output
      ## semantics. The runtime closure walker filters edges by this
      ## tag when computing per-output transitive dependencies so a
      ## consumer that ``uses:`` only the ``bin`` output of package
      ## P never pulls man-page or doc edges into its closure.
      ##
      ## Carried through the payload codec (v13+) so multi-output
      ## graphs survive serialization. v12 and earlier payloads
      ## decode with an empty ``outputTag``, which the closure walker
      ## treats identically to ``"out"``.
    env*: seq[(string, string)]
      ## MR10 (Reprobuild typed-tool env injection): per-edge env-var
      ## additions threaded down from the typed-tool wrapper-proc's
      ## ``extraEnv`` parameter. Each ``(NAME, VALUE)`` entry is
      ## appended to the action's spawned-process env table by the
      ## CLI's action-realisation path (``repro_cli_support``). The
      ## engine inherits the parent process env unconditionally;
      ## ``env`` extends rather than replaces. Empty for legacy
      ## recipes (and the v13-and-earlier payload codec round-trips
      ## the field as empty so older artifacts decode cleanly).
    publishToBinaryCache*: bool
      ## M9.L.4-refactor Step B: passive flag the from-source
      ## conventions stamp on each install + stage-copy action so the
      ## engine's binary-cache publisher hook fires after a successful
      ## run. Default ``false`` keeps legacy actions inert — the
      ## engine's hook only consults the publisher closure when both
      ## this flag and ``cacheEntryIdentity.isSome`` AND the engine
      ## config carries a non-nil ``binaryCachePublisher`` hold.
      ## Payload codec v15+.
    cacheEntryIdentity*: Option[CacheEntryIdentity]
      ## M9.L.4-refactor Step B: convention-supplied identity tuple
      ## from which the engine's publisher re-derives the canonical
      ## 64-char hex entry key (drift-guard) and which signs the
      ## manifest. ``none`` (the default) means "no identity wired" —
      ## conventions that don't opt into binary-cache publishing leave
      ## the slot empty so the engine's hook skips the action even when
      ## the flag above is true. Payload codec v15+.
    sourceFile*: string
    sourceLine*: int

  BuildTargetKind* = enum
    ## Spec-Implementation M5: discriminator on ``BuildTargetDef`` so the
    ## persistence path can distinguish ad-hoc aggregates (the
    ## Named-Targets M1 ``aggregate("...", ...)`` shape) from build
    ## graph collections (Build-Graph-Collections.md §"Persistence and
    ## the Target-Export Table"). M0 shipped the ``collect()`` primitive
    ## as a thin alias over ``aggregate()`` so a single registry was
    ## fine; M5 splits the registries so the target-export-table v2
    ## rows carry the right ``kind`` discriminator end-to-end.
    btkAggregate     ## ad-hoc ``aggregate("...", ...)`` grouping
    btkCollection    ## ``collect("...", ...)`` graph collection

  BuildTargetDef* = object
    name*: string
    actions*: seq[string]
    targets*: seq[string]
    sourceFile*: string
    sourceLine*: int
    kind*: BuildTargetKind
      ## Spec-Implementation M5: ``btkAggregate`` for legacy ``aggregate``
      ## registrations; ``btkCollection`` for ``collect`` registrations.
      ## Default ``btkAggregate`` is intentional: target-export-table v1
      ## payloads decode with no ``kind`` field; promoting the zero value
      ## to ``btkAggregate`` keeps backward-compat with the v1 record
      ## shape.

  BuildPoolDef* = object
    name*: string
    capacity*: uint32

  TargetExportKind* = enum
    ## Named-Targets M1 / Spec-Implementation M5: per-edge target-name
    ## origin marker. M0/M1 shipped ``tekImplicit`` + ``tekExplicit``;
    ## M5 adds ``tekAggregate`` + ``tekCollection`` so target-export
    ## table v2 rows can distinguish aggregate-target registrations
    ## (``aggregate("...", ...)``) from collection registrations
    ## (``collect("...", ...)``) per Build-Graph-Collections.md
    ## §"Persistence and the Target-Export Table". v1 payloads decode
    ## with ``tekImplicit`` / ``tekExplicit`` only — the v2 wire format
    ## marks the M5 additions with discriminator bytes 2 / 3.
    tekImplicit   ## Computed from ``outputs`` statements and optional hook.
    tekExplicit   ## Declared via ``target "name", handle`` in the DSL.
    tekAggregate  ## Declared via ``aggregate("name", ...)`` (M0 surface).
    tekCollection ## Declared via ``collect("name", ...)`` (M0 + M5 split).

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
