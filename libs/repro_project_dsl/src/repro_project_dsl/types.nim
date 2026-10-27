import std/[tables]

import ./attr_ssz

type
  ExtensionBox* = ref object of RootRef
    typeId*: string

  TypedExtensionBox*[T] = ref object of ExtensionBox
    val*: T

  RawExtensionBox* = ref object of ExtensionBox
    ## Typed-Extension-Interfaces M2 (opaque attr pass-through): carries a
    ## resource's attribute record OPAQUELY — the base ``typeId`` plus the
    ## already-marshalled envelope bytes (``raw``, a byte-per-char string,
    ## the exact output of ``marshalAttrs``) — WITHOUT a registered codec.
    ##
    ## The ``repro`` CLI is only a ROUTER for an out-of-tree provider's
    ## resources: it decodes the resource graph, hands the members to the
    ## provider SESSION (which HAS the codec), and stores the opaque
    ## ``attrsJson`` in the state store. It must NOT need the attrs codec
    ## in-process. ``unmarshalAttrsOrRaw`` produces this box for an
    ## unregistered ``typeId``; ``marshalAttrs`` re-serializes it VERBATIM
    ## (identity round-trip), so the bytes reaching the session / store are
    ## byte-for-byte what was decoded. A process that DOES have the codec
    ## (the provider) still gets the typed ``TypedExtensionBox[T]``.
    raw*: string

  ExtensionMarshaler* = object
    ## Typed-Extension-Interfaces M1: the marshaller round-trips the
    ## attribute record through a versioned SSZ envelope
    ## (``attr_ssz.encodeAttrEnvelope`` / ``decodeAttrEnvelope``) — NOT
    ## ``std/json``. ``marshal`` returns the envelope bytes carried as a
    ## byte-per-char string; ``unmarshal`` takes that same byte string.
    ## The parameter is named ``payload`` (was ``jsonStr``) to reflect
    ## the binary payload.
    marshal*: proc(box: ExtensionBox): string {.nimcall.}
    unmarshal*: proc(payload: string): ExtensionBox {.nimcall.}

  NimPackageExtension* = object
    name*: string
    srcDir*: string

  GeneratedFileExtension* = object
    destPath*: string
    content*: string

var extensionRegistry* {.threadvar.}: Table[string, ExtensionMarshaler]

template registerExtension*[T](id: string) =
  ## Register the versioned-SSZ-envelope marshaller for attribute record
  ## ``T`` under ``id``. ``marshal`` emits ``[u16le version][ssz(val)]``
  ## carried as a byte-per-char string; ``unmarshal`` reads the version
  ## then SSZ-decodes ``T``. No ``std/json`` on this path.
  block:
    let m = ExtensionMarshaler(
      marshal: proc(box: ExtensionBox): string =
        bytesToByteString(encodeAttrEnvelope(TypedExtensionBox[T](box).val)),
      unmarshal: proc(payload: string): ExtensionBox =
        let val = decodeAttrEnvelope[T](byteStringToBytes(payload))
        return TypedExtensionBox[T](typeId: id, val: val)
    )
    extensionRegistry[id] = m

type
  BuildActionPayloadError* = object of CatchableError

  BuildActionPayloadTooNewError* = object of BuildActionPayloadError
    ## A well-formed payload envelope whose version is NEWER than the
    ## ``BuildActionPayloadVersion`` this build reads: it was written by a
    ## newer reprobuild, not corrupted. Kept distinct from its parent so a
    ## reader of a shared cache can treat exactly this refusal as a miss
    ## (Incremental-Invalidation.md §"Record payload schemas": an older
    ## reader treats a newer record as absent) without also hiding real
    ## corruption, which stays a plain ``BuildActionPayloadError``.
    foundVersion*: uint16
    supportedVersion*: uint16


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
    nonDeterminism*: NonDeterminismPolicy
      ## Windows-Build-Correctness M6 — the tool's entropy blessing, declared
      ## once with ``nonDeterminism entropyBlessed, justification = "..."``
      ## inside the ``cli:`` block and inherited by every nested ``subcmd``
      ## exactly the way ``dependencyPolicy`` is. Defaults to
      ## ``ndpUnblessed``.
    subTools*: seq[string]
      ## Tools this tool itself shells out to by BARE NAME, declared once
      ## with ``subTools "rustc", "gcc"`` directly under ``cli:``. A
      ## ``uses:`` entry of the calling recipe that matches one of these
      ## names has its resolved directory PREPENDED to every edge of this
      ## tool; an unmatched name is inert. Unlike an edge's
      ## ``toolIdentityRefs`` this is not a statement about the edge's
      ## complete tool set, so it does not make the edge's ``PATH``
      ## hermetic.
    nonDeterminismJustification*: string
      ## Why the blessing above is sound. Required when the policy is
      ## ``ndpEntropyBlessed`` (the macro rejects a bare blessing), carried
      ## through to the engine so ``repro why`` can print the reason a
      ## tool's randomness was ignored instead of leaving it to folklore.
    providerEntrypointId*: string
    optionalOutputFlags*: seq[string]
      ## Output parameters that the tool may legitimately leave absent.
    removeBeforeRunFlags*: seq[string]
      ## The output flags (``role = output`` parameters) whose values the
      ## engine removes before every edge of this command runs, declared
      ## with ``removeBeforeRun <flag>...`` for a tool that refuses to write
      ## over an existing output. Inherited by nested ``subcmd`` scopes the
      ## way ``outputFlags`` is. Lowered to ``BuildActionDef.removeBeforeRun``.
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
    lockFile*: string
      ## Named-Lock-Files NLF-M7 (§4.3) — the lock file designated at this
      ## artifact by a ``lockFile <name>`` line in its body. Empty means
      ## INHERIT, which §4.6's table makes the default for an ordinary
      ## artifact: "Built under whatever lock file its consumer is under;
      ## once per distinct consuming lock file."
      ##
      ## §4.3 puts the designation here rather than on the package because
      ## "a package routinely declares both a host build tool and a shipped
      ## binary … so package-level designation would be too coarse to express
      ## the motivating case".
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
    lockFile*: string
      ## Named-Lock-Files NLF-M7 (§4.3). See ``ExecutableDef.lockFile``; a
      ## library designating one is §4.6's PINNED row and is the unusual
      ## case — "a library's architecture is a property of who is using it".
    exportedPath*: string
      ## Cross-Repo-Source-Consumption SC-11 (§4.2a.4): the producer-relative
      ## directory a Nim library-consumer threads onto its ``nim c --path:``.
      ## Empty means the convention default ``"src"`` (resolved at the splice
      ## seam), so an existing bare ``library foo`` exports ``<root>/src``
      ## unchanged; a non-standard layout sets it explicitly.
    sourceFile*: string
    sourceLine*: int

  ResourceAttrDef* = object
    ## RP4: one ``attr <name>: <type>`` declaration inside a
    ## ``resourceType`` block — the typed-wrapper parameter surface the
    ## interface lifting turns into an ``InterfaceResourceAttr``.
    name*: string
    nimType*: string
    sourceFile*: string
    sourceLine*: int

  ResourceTypeInterfaceDef* = object
    ## RP4 (Provider-Runtime-Protocol-v1 §5): the compile-time record a
    ## ``resourceType`` block lowers to for interface lifting. Mirrors
    ## ``ExecutableDef`` / ``LibraryDef``: a self-contained, codec-free
    ## value the interface extractor projects into an
    ## ``InterfaceResource``. ``determinism`` is stored as the ordinal of
    ## the generic-lane ``ResourceDeterminism`` (rdStrong=0 … rdVolatile=3)
    ## so this module stays free of the home-resources import.
    typeId*: string
    determinismOrd*: int
    attributes*: seq[ResourceAttrDef]
    identityEntrypoint*: string
    digestEntrypoint*: string
    observeEntrypoint*: string
    planEntrypoint*: string
    applyEntrypoint*: string
    sourceFile*: string
    sourceLine*: int

  ActivityParamInterfaceDef* = object
    ## Shared-Development-Services L3: one constructor-style typed
    ## parameter of an exported dev-env activity, as DECLARED. ``nimType``
    ## is the parameter's type expression written verbatim — the lift
    ## carries the author's spelling, not a resolved symbol, because the
    ## consuming compilation resolves it in its own scope exactly as the
    ## ``InterfaceResourceAttr.nimType`` of a lifted resource attribute is
    ## resolved there.
    name*: string
    nimType*: string
    sourceFile*: string
    sourceLine*: int

  ActivityConfigInterfaceDef* = object
    ## Shared-Development-Services L3: one ``config:`` key of an exported
    ## dev-env activity — "the ``config:`` surface with defaults so a
    ## consumer's ``enable`` block typechecks" (L3 ``:gate:``).
    ##
    ## ``hasDefault`` is a FIELD rather than ``defaultRepr.len > 0`` for
    ## the reason L2's ``DslActivityConfigDef`` gives: ``issuer: string``
    ## and ``issuer: string = ""`` would otherwise be the same record and
    ## the second would read as required.
    name*: string
    nimType*: string
    defaultRepr*: string
    hasDefault*: bool
    description*: string
    sourceFile*: string
    sourceLine*: int

  ServiceIdentityKind* = enum
    ## Shared-Development-Services L4 (§4.2): the two identity modes, and
    ## the choice between them "is forced by durable state".
    ##
    ## ``sikDerived`` is ordinal 0 on purpose. It is the DEFAULT and it is
    ## also today's behaviour, so a record built by the legacy positional
    ## ``registerService``, and a v1 ``RSVC`` payload that carries no
    ## identity block at all, both decode to it without a special case.
    sikDerived
      ## ``identity derived`` — "a digest of the service's materialised
      ## definition: the executable, the rendered configuration outputs,
      ## the arguments". Two worktrees that build the same closure share
      ## one instance. Unsafe for a service that owns durable state, which
      ## is why the other mode exists.
    sikStable
      ## ``identity stable "<id>"`` — "The author assigns a stable
      ## identifier, independent of the build. There is one instance per
      ## ``(id, scope)``, and it survives redefinition."

  ServiceScope* = enum
    ## Shared-Development-Services L4 (§4.1): how widely one instance is
    ## shared. ORTHOGONAL to ``ServiceIdentityKind`` -- identity answers
    ## "are these the same instance?", scope answers "how widely is one
    ## instance shared?", and §4 is written to prevent the two being
    ## conflated.
    ##
    ## The two WIDER values extend the lease scope
    ## ``Ephemeral-State-Leases.md`` §4.1 already resolved (``user`` vs
    ## ``system``, routing to the user vs system daemon); that resolution
    ## is not re-decided here. ``sscProject`` is ordinal 0 because it is
    ## the default and "today's only behaviour", for the same
    ## ground-state reason ``sikDerived`` is.
    sscProject    ## one instance per project root — the default
    sscWorkspace  ## one instance per workspace (D-SS3)
    sscUser       ## one instance per OS user, via the user daemon
    sscSystem     ## one instance per machine, via the system daemon

  ServiceIdentityDef* = object
    ## One ``service`` block's declared identity.
    ##
    ## ``stableId`` is meaningful only for ``sikStable`` and is the
    ## empty string otherwise; the macro refuses ``identity derived
    ## "<id>"`` rather than recording an id the resolver would ignore.
    kind*: ServiceIdentityKind
    stableId*: string
      ## The author's identifier, verbatim. §4.2: "A stable identifier is
      ## a name, not a secret, and it is chosen to be globally unique by
      ## construction -- a reverse-DNS-style string, or a GUID. It is not
      ## derived from a path, because a path is what distinguishes the
      ## worktrees that are supposed to share the instance." The macro
      ## enforces the last sentence as far as a macro can: the id must be
      ## a STRING LITERAL, so it cannot be computed from the build or
      ## from the invocation directory.

  ServiceInterfaceDef* = object
    ## Shared-Development-Services L3: one ``service <name>:`` crossing
    ## the interface boundary as a typed symbol.
    ##
    ## This record carries the service's SIGNATURE and deliberately not
    ## its implementation. A consumer compiles against the service's name
    ## and the handle type it is reached through; it does not compile
    ## against the service's ``executable``, ``args``, ``runtimeFile`` or
    ## ``on <trigger>:`` setters, which are the producer's private
    ## business. That split is what keeps the interface fingerprint from
    ## being a rebuild-everything hammer: changing a service's argv
    ## re-lifts to the same digest and does not invalidate consumers,
    ## while renaming the service does. Measured both ways in
    ## ``t_l3_lift_carries_service_and_activity_signatures.nim``.
    ##
    ## ``activityName`` is the activity whose body declared it, or "" for
    ## a package-level service.
    packageName*: string
      ## The declaring package. Set by ``registerServiceInterface``, so a
      ## caller constructing the record never has to repeat it.
    name*: string
    activityName*: string
    handleType*: string
      ## The generated Nim type a consumer reaches this service's handle
      ## through — ``<Title><Activity>Handle`` for a service inside an
      ## activity. Empty for a package-level service, which no handle
      ## type carries yet.
    identityKind*: ServiceIdentityKind
      ## Shared-Development-Services L4: the DECLARED identity mode. L3's
      ## gate names "the declared identity and scope" as part of what the
      ## lift carries and deferred it here, because the DSL had no such
      ## surface until L4 added one.
      ##
      ## It belongs to the SIGNATURE and not to the implementation, which
      ## is the test ``ServiceInterfaceDef``'s own doc comment sets: a
      ## consumer resolving a shared service has to know whether it is
      ## being handed an instance keyed by a declared id or one keyed by
      ## a digest of somebody else's build, because that is the
      ## difference between "my state survives" and "my state forks".
      ## Changing it therefore MUST move the interface fingerprint, and a
      ## change to ``args`` still must not.
    identityStableId*: string
      ## The declared id for ``sikStable``; empty for ``sikDerived``.
    scope*: ServiceScope
      ## The DECLARED scope. Also signature, for the same reason: it is
      ## half of the instance key a consumer resolves against.
    compatibilityMajor*: uint32
      ## Shared-Development-Services L6 (§4.3): the DECLARED MAJOR
      ## COMPATIBILITY FIELD, from ``compatibility <n>``.
      ##
      ## It is the input to the ONE outcome of §4.3's three that is not
      ## decided on the fingerprint: "| major compatibility field differs
      ## | **Refuse.** Attaching would hand the consumer a handle whose
      ## members it cannot use; a warning there would be a defect report
      ## written after the damage |". Without a field for it the table's
      ## bottom row has no input and the decision collapses to two
      ## outcomes, which is the design §4.3 exists to reject.
      ##
      ## ``0`` means UNDECLARED, and it is the zero value on purpose:
      ## every artifact written before the envelope carried this field
      ## decodes to 0, so a cached pre-v23 artifact and a freshly lifted
      ## definition that declared nothing AGREE rather than refusing each
      ## other over a format boundary. The DSL consequently refuses
      ## ``compatibility 0`` — declaring it would be unobservable.
      ##
      ## IT IS NOT ON ``DslServiceDef`` AND THAT IS DELIBERATE. §4.4 and
      ## §6.5 key an instance by ``(identity, scope, environment)``; the
      ## major is not in that key, nothing about MATERIALISING a service
      ## reads it, and the lowered ``gnkService`` payload exists to
      ## materialise. Copying it there would be a second place for one
      ## fact to disagree with itself — the same argument L4 made for
      ## keeping identity off ``ActivityInterfaceDef``. The lift reads it
      ## from the body AST through the shared ``identity``/``scope``
      ## walker, so there is exactly one reading.
    contributionPoints*: seq[string]
      ## Shared-Development-Services D-SS11 (§4.6): the CONTRIBUTION
      ## POINTS this service converges, as the bare names the author
      ## wrote in ``converge <point>, <point>``, in declaration order.
      ##
      ## §4.6 requires this of the lift and not of anything else: "The
      ## owner's lifted interface must **carry its contribution points**,
      ## so a consumer's contribution is type-checked against a declared
      ## point and a misspelled one is refused by name at the consumer's
      ## compile time." Before this field the points existed only in the
      ## owner's own lowering (``DslServiceDef.convergePoints``) and in
      ## the owner's own process, so a consumer had nothing to compile
      ## against -- which is exactly L9's F2 measurement.
      ##
      ## THE BARE NAME, NOT THE RESOLVED KEY. The resolved key is
      ## ``<package>.<activity>.<name>`` and is derived by
      ## ``resolveServiceConvergePoint`` from facts the OWNER knows; the
      ## bare name is what a consumer writes at the resolver
      ## (``infra.sso.shared(relyingParties = append("x"))``). Carrying
      ## the bare name keeps the consumer's spelling and the owner's
      ## declaration the same string, so a refusal can name it back
      ## verbatim.
      ##
      ## IT IS SIGNATURE, so it belongs in the fingerprint: a service
      ## that drops a point a consumer contributes to has changed what
      ## that consumer compiled against. ``serviceInterfaceMembers``
      ## emits one ``smkContributionPoint`` member per entry for exactly
      ## that reason.
    sourceFile*: string
    sourceLine*: int

  ActivityInterfaceDef* = object
    ## Shared-Development-Services L3: one exported dev-env activity's
    ## lifted signature — "the handle type and its members … and the
    ## ``config:`` surface with defaults" (L3 ``:gate:``).
    ##
    ## WHAT IS NOT HERE, AND WHICH MILESTONE ADDS IT. L3's gate also names
    ## "the declared identity and scope" (L4) and "the shared collections
    ## it converges" (L8).
    ##
    ## L4 HAS LANDED, AND IT PUT IDENTITY AND SCOPE ON THE SERVICE RECORD
    ## RATHER THAN ON THIS ONE. ``identity`` and ``scope`` are setters of
    ## a ``service`` block, not of an ``activity``: one activity may
    ## declare several services and §4 keys an INSTANCE, which is a
    ## service, by ``(identity, scope)``. Every service this activity
    ## declares already has its own ``ServiceInterfaceDef`` row carrying
    ## them (``identityKind`` / ``identityStableId`` / ``scope``), so a
    ## copy here would be a second place for the same fact to disagree
    ## with itself. ``services`` below names the rows.
    ##
    ## ``the shared collections it converges`` (L8) is still absent and is
    ## still not invented: it is ADDED as a field here, reaching the wire
    ## through one more version-gated block in
    ## ``encodeInterfacePayload`` — the same additive route
    ## ``publicLibraries`` took at envelope v9, ``publicResources`` at
    ## v12 and L4's identity/scope at v22. Nothing in the shape has to be
    ## rewritten for it.
    packageName*: string
      ## The declaring package. Set by ``registerActivityInterface``.
    name*: string
    handleType*: string
      ## The generated handle type's name, ``<Title><Activity>Handle``.
      ## Recorded rather than recomputed so a consumer reading the
      ## artifact does not have to reimplement the producer's naming rule.
    params*: seq[ActivityParamInterfaceDef]
    config*: seq[ActivityConfigInterfaceDef]
    services*: seq[string]
      ## Names of the services this activity's body declares, in
      ## declaration order. Each is also a member of the handle type.
    sourceFile*: string
    sourceLine*: int

  EnvironmentPrecedence* = enum
    ## Shared-Development-Services L5 (§6.1), D-SS6's second half: WHERE
    ## an environment's binding sits in the precedence order each
    ## configurable already declares.
    ##
    ## This is a MIRROR of `Configurable-System.md`'s
    ## ``ContributionPriority`` (``prDefault`` < ``prSet`` <
    ## ``prOverride`` < ``prForce``), declared here for the same reason
    ## ``InterfaceServiceScope`` mirrors ``ServiceScope``: the ladder's
    ## own type lives in ``repro_dsl_stdlib/configurables/types.nim`` and
    ## ``repro_dsl_stdlib`` DEPENDS ON this library, so importing it here
    ## would be a cycle. The ordinals line up, and
    ## ``t_l5_environment_binds_configurables.nim`` carries the drift
    ## assertion -- a test can import both.
    ##
    ## §6.1: an environment "needs no new staging, no new merge rules and
    ## no new precedence model -- only a name, a binding set, and a
    ## DECLARED POSITION in the existing precedence order". This enum is
    ## how that position is recorded rather than re-decided.
    epDefault   ## = ``prDefault``
    epSet       ## = ``prSet``
    epOverride  ## = ``prOverride`` -- where an environment binds (D-SS6)
    epForce     ## = ``prForce``

  ContributionOperation* = enum
    ## Shared-Development-Services L8 (§5), implementing
    ## `Configurable-System.md` §"Operation is a SECOND axis, independent
    ## of priority": "each contribution carries an **operation** as well
    ## as a priority".
    ##
    ## THE TWO AXES ARE INDEPENDENT, and that independence is the whole
    ## reason this enum exists. Priority alone makes every authoritative
    ## contribution DESTRUCTIVE -- there is no way to say "add this, and
    ## I have the standing to insist on it" without also saying "and
    ## discard everything contributed below me". With the operation at
    ## the call site there is: an ``coAppend`` at ``epOverride`` or
    ## ``epForce`` is authoritative and leaves every lower contribution
    ## present, while a ``coReplace`` is destructive downward at any
    ## priority.
    ##
    ## ``coReplace`` IS ORDINAL 0 ON PURPOSE. Every contribution the
    ## port recorded before this axis existed was a replace -- an
    ## ``environment`` binding, a ``setConfigurable``, a construction
    ## default -- so a record that carries no operation decodes to the
    ## behaviour it already had rather than to a new one. That is the
    ## same additive-decode argument ``compatibilityMajor`` makes for
    ## ``0`` meaning UNDECLARED.
    coReplace = 0
      ## *The value is exactly this.* The only operation a scalar has,
      ## which is why a scalar key needs no new spelling: ``:=`` /
      ## ``setConfigurable`` / an ``environment`` binding are all
      ## ``coReplace`` and always were.
    coAppend = 1
      ## *Add these to the collection.* Available only on a
      ## CONTRIBUTION POINT -- a configurable whose type is an ordered
      ## collection. Appending to a scalar is refused by name rather
      ## than silently treated as a replace, because "add 4 to the
      ## worker count" is not a thing the author can have meant.

  EnvironmentBindingDef* = object
    ## Shared-Development-Services L5 (§6): ONE binding of ONE
    ## configurable by ONE environment. "An environment is a named set of
    ## bindings to configurables, and nothing else", and this is one
    ## element of that set.
    ##
    ## The record carries no value. It carries the author's EXPRESSION,
    ## verbatim, because the value is produced by the emitted
    ## ``bindEnvironmentConfigurable`` call in the author's own scope --
    ## the same contract ``ActivityConfigInterfaceDef.defaultRepr`` has,
    ## and for the same reason: a macro that evaluated the expression
    ## would be re-implementing a Nim evaluator.
    key*: string
      ## The configurable's FULL key, ``<package>.<name>`` for a
      ## package-level ``config:`` key and
      ## ``<package>.<activity>.<name>`` for an activity's. The first
      ## form is byte-identical to the key ``recordConfigDefault``
      ## registers, which is what makes an environment a contributor into
      ## the EXISTING table rather than a second one.
    qualifier*: string
      ## The declaring activity, or "" for a package-level configurable.
    name*: string
      ## The configurable's own name, unqualified.
    valueRepr*: string
      ## The bound expression as the author wrote it. Diagnostics and the
      ## environment component of the instance key read this; nothing
      ## evaluates it.
    precedence*: EnvironmentPrecedence
      ## Always ``epOverride`` today (D-SS6). A field rather than a
      ## constant so a configurable that declares a different position
      ## for environment contributions has somewhere to say so without a
      ## shape change.
    sourceFile*: string
    sourceLine*: int

  DslEnvironmentDef* = object
    ## Shared-Development-Services L5 (§6): one ``environment <name>:``
    ## declaration, lowered.
    ##
    ## It has a name and a binding set. It has no executable, no
    ## topology, no host and no activity list, and that absence is the
    ## design: §6.2 says an environment "is not a machine and has no
    ## topology", and a field here that looked like one would be the
    ## second of the two drafts §6.3 records as wrong.
    packageName*: string
    name*: string
    bindings*: seq[EnvironmentBindingDef]
    sourceFile*: string
    sourceLine*: int

  ConsumerLeaseKind* = enum
    ## Shared-Development-Services L5, §6.6's left column: the lease
    ## policy a CONSUMER chooses for its own consuming edge, which
    ## ``Ephemeral-State-Leases.md`` §2.2 already allows per edge.
    ##
    ## A mirror of ``repro_resources/lease.nim``'s ``LeaseKind`` plus an
    ## ``unset`` ground state, for the mirror reason
    ## ``EnvironmentPrecedence`` gives -- ``repro_resources`` depends on
    ## this library. ``clkUnset`` is ordinal 0 so a record that declared
    ## nothing is distinguishable from one that declared ``keep``, which
    ## is ``LeaseKind``'s own default and therefore NOT the same
    ## statement.
    clkUnset
    clkKeep       ## ``lease keep`` -> ``lkKeep``
    clkImmediate  ## ``lease immediate`` -> ``lkImmediate``
    clkDelayed    ## ``lease delayed(<seconds>)`` -> ``lkDelayed``

  ConsumerInstanceOverrideDef* = object
    ## Shared-Development-Services L5 (§6.6): what a CONSUMER is allowed
    ## to say about an instance of somebody else's service.
    ##
    ## §6.6's rule is one line -- "a consumer may decide what affects
    ## only itself; the environment binds everything that defines the
    ## instance" -- and this record is the left column of its table,
    ## entire: the instance SCOPE (§4.1) and the consumer's OWN LEASE
    ## POLICY. There is deliberately no field for a configurable value,
    ## no field for a hostname, and no field for an identity: every one
    ## of those is the right column, and the walker refuses them in the
    ## consumer's own compilation rather than recording them here.
    ##
    ## NOTHING IS RESOLVED BY THIS RECORD. It takes no lease, starts
    ## nothing, and contacts no daemon; it is the consumer's declared
    ## intent, which L6's attach decision and L7's resolver read.
    consumerPackage*: string
    targetPackage*: string
      ## The package that OWNS the service, as written.
    targetService*: string
    scopeDeclared*: bool
      ## Whether ``scope`` was written. Separate from ``scope`` for L4's
      ## reason: "the author said nothing" and "the author wrote the
      ## default" must not be the same record, because the second is an
      ## override of the owner's suggestion and the first is not.
    scope*: ServiceScope
    leaseKind*: ConsumerLeaseKind
    leaseTtlSeconds*: int
      ## Meaningful only for ``clkDelayed``; zero otherwise.
    sourceFile*: string
    sourceLine*: int

  SharedServiceDeclarationDef* = object
    ## Shared-Development-Services D-SS11 (§4.6): the DECLARATION a
    ## resolver is spelled against, as the owner's lift carries it.
    ##
    ## `<package>.<service>.shared()` is "a resolver on the typed
    ## declaration symbol", and this record is what the declaration
    ## symbol knows about itself in a CONSUMER's compilation: who owns
    ## it, what it is called, which activity declares it, where the
    ## owner's recipe lives, and which contribution points it converges.
    ## Every field comes from the owner's `service` block by way of the
    ## interface lift; none of it is supplied by the consumer.
    ##
    ## IT IS NOT A HANDLE, and that is the distinction §4.6's closing
    ## paragraph exists for: "The activity names the service; the
    ## resolver yields a handle to an instance of it; the two are
    ## different types and should not be spellable interchangeably."
    ## `SharedServiceHandle` below is the other type.
    ownerPackage*: string
    serviceName*: string
    activityName*: string
      ## The activity whose body declares the service, or "" for a
      ## package-level `service`.
    ownerRecipeDir*: string
      ## The directory of the recipe file that declared the service.
      ##
      ## This is the one field that is a PATH, and it is here because the
      ## resolver's attach decision needs the owner's own project
      ## interface artifact -- §4.3 compares the running instance's
      ## interface fingerprint against the definition the consumer
      ## resolved, and the consumer has no other way to reach it. It is
      ## derived from the service declaration's `sourceFile`, which the
      ## lift already carries for diagnostics, so no new fact crosses the
      ## boundary.
      ##
      ## A path in a lifted record is normally wrong (§4.4: "State is
      ## keyed by identity, never by path"), and this one is NOT part of
      ## the instance key, is not digested into any identity, and is read
      ## exactly once, to locate an artifact. When it is stale or absent
      ## the resolver REFUSES by name and says which project to run
      ## `repro dev-env` in; it never falls back to a default identity.
    contributionPoints*: seq[string]
      ## The points this service converges, bare names, declaration
      ## order -- `ServiceInterfaceDef.contributionPoints` as it reaches
      ## a consumer. The resolver macro checks the consumer's spelling
      ## against this list AT THE CONSUMER'S COMPILE TIME, which is the
      ## first of §4.6's two "must land together" requirements.

  SharedServiceHandle*[T] = object
    ## Shared-Development-Services D-SS11 (§4.6): what a RESOLVER
    ## returns. "It returns a `SharedServiceHandle[T]`, a type
    ## **distinct from the declaration's**, so the two are not spellable
    ## interchangeably."
    ##
    ## `T` is the declaration's own lifted type (`LiftedServiceHandle`
    ## for every service the lift emits today). It is a PHANTOM
    ## parameter: nothing reads a `T`-typed field, and it is here so that
    ## the handle's type names the declaration it came from. That is what
    ## makes `enable stack(sso = infra.sso)` a type error while
    ## `enable stack(sso = infra.sso.shared())` is not -- the mistake
    ## §4.6 records an earlier revision of §9 making.
    ##
    ## WHAT IT DOES NOT CARRY: a value of the running service. §7's
    ## staged configurables and computed resource attributes are read
    ## from the instance after it converges; a handle minted at
    ## evaluation time is an ADDRESS plus the resolution it belongs to.
    ## Pre-filling it would make it read like an instance, which is
    ## exactly what the lift already refuses to do for `config:`
    ## defaults.
    ownerPackage*: string
    serviceName*: string
    activityName*: string
    consumerPackage*: string
      ## The package whose recipe wrote the resolver. This is the
      ## ATTRIBUTION §5 requires of every contribution, captured at the
      ## one call site that knows it.
    sourceFile*: string
    sourceLine*: int

  SharedContributionDef* = object
    ## ONE contribution made AT a resolver call. §4.6: "the consumer's
    ## contributions are **arguments of the resolver call**".
    point*: string
      ## The bare point name, as the consumer wrote it and as the owner
      ## declared it. Checked against
      ## `SharedServiceDeclarationDef.contributionPoints` at the
      ## consumer's compile time.
    operation*: ContributionOperation
      ## `coAppend` only, today, and the restriction is REFUSED rather
      ## than silently coerced: §5.1 and D-SS9 say a consumer of a shared
      ## service "must be able to `append` a relying party freely, and
      ## must **not** be able to `replace` the relying-party collection",
      ## because "a consumer that could replace them would fork the
      ## instance it is trying to join". The field is still typed as the
      ## operation axis rather than dropped, so the record a store holds
      ## says which operation produced it and D-SS9's resolution has
      ## somewhere to widen into.
    precedence*: EnvironmentPrecedence
    members*: seq[string]
    sourceFile*: string
    sourceLine*: int

  SharedServiceResolution* = object
    ## One resolver call, recorded at the consumer's evaluation.
    ##
    ## This is the record that travels from the consumer's recipe to the
    ## consumer's `repro up`, and it is the whole of what the
    ## CROSS-PROCESS lane carries. Everything in it was decided by the
    ## consumer's own compilation; nothing in it is read from a running
    ## instance.
    declaration*: SharedServiceDeclarationDef
    consumerPackage*: string
    consumerActivities*: seq[string]
      ## Consumer activities receiving this handle. These are alternatives:
      ## selecting ANY one includes this resolution. An empty list denotes
      ## a recipe-global resolver with no activity parameter binding.
      ## Derived during lowering, then filtered before the provider wire.
    requestedThisEvaluation*: bool
      ## The resolver or its retained handle was encountered in the current
      ## dev-env evaluation. A previous request's unbound row is not a
      ## recipe-global resolver in this request. Local lowering state only.
    contributions*: seq[SharedContributionDef]
    sourceFile*: string
    sourceLine*: int

  LiftedServiceHandle* = object
    ## Shared-Development-Services L3: the consumer-side value a lifted
    ## activity handle's service member holds.
    ##
    ## It carries the service's ADDRESS and nothing else. A running
    ## service's own members — its readiness, its url, the resource
    ## attributes it mints — are §7's staged configurables and computed
    ## resource attributes, and L7 is where they become reachable. Until
    ## then a consumer can name a dependency's service as a typed symbol
    ## and get a compile error for a misspelling, which is L3's claim and
    ## the whole of it.
    packageName*: string
    activityName*: string
    serviceName*: string

  PackageSourceDecl* = object
    ## One ``packageSource <package>, <provenance>`` declaration. See
    ## ``PackageDef.packageSources``.
    packageName*: string
    source*: string
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
    depKind*: string
      ## Named-Lock-Files NLF-M7 (§4.6) — WHICH of the three approved
      ## dependency lists this entry was written in: ``"target"``
      ## (``uses:`` / ``buildDeps:``), ``"native"`` (``nativeBuildDeps:``) or
      ## ``"runtime"`` (``runtimeDeps:``).
      ##
      ## §4.6 is where this comes from and why it matters. The approved DSL
      ## already declares the host/target split at list granularity —
      ## "``nativeBuildDeps:`` resolves under the ``hostTools`` lock file;
      ## ``buildDeps:`` and ``runtimeDeps:`` resolve under the consuming
      ## artifact's lock file" — but §4.6 MEASURED that the distinction is
      ## "erased before the solver ever sees it", because the three lists are
      ## concatenated at serialization
      ## (``pkg.toolUses & pkg.nativeBuildDeps & pkg.runtimeDeps``).
      ##
      ## Tagging the entry is what un-erased it for NLF-M7: the platform tag
      ## survived the concatenation and reached the solver through
      ## ``registerSolverDependency``.
      ##
      ## NLF-M8 then removed the concatenation itself (``allToolUses``), so
      ## ``toolUses`` now holds what its name says at run time as well as at
      ## macro-expansion time. The tag stays, and is now the ANSWER rather
      ## than a repair: a consumer that needs to know which list an entry
      ## came from reads it here instead of inferring it from a position in a
      ## merged seq, and `repro_lock_files`'s propagation reads it to decide
      ## which lock file the edge resolves under (§4.6).
      ##
      ## Empty means untagged, which no in-tree collection site produces; it
      ## is the zero value and is treated as ``"target"`` by consumers so a
      ## `PackageUseDef` built by hand keeps its former meaning.

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

  TarballArchiveDetail* = object
    ## GM4b: the archive-realization metadata a ``tarball`` realization
    ## carries beyond "download, verify, extract". These are the fields the
    ## retired ``VersionedProvisioning`` catalog records held
    ## (Provisioning-Contributions.md §"Profile Package References"); every
    ## record moved into a ``tarball`` realization of its canonical
    ## definition, so a realization has exactly one representation.
    ##
    ## Grouped in one object so the four places that serialize a tarball
    ## record (the in-package and contribution literal emitters, the
    ## thin-interface stub emitter and the interface-artifact codec) add one
    ## field, not seventeen, and cannot drift on any of these.
    ##
    ## Every field is a string, a ``seq[string]`` or a ``bool`` on purpose:
    ## at macro time the string fields hold the EXPRESSION SOURCE the
    ## emitters splice (as every other ``TarballProvisioningDef`` field does),
    ## and the structured entries (``preInstall``, ``launcherEmit``) are
    ## encoded strings produced by ``packages_schema.preInstallAction`` /
    ## ``launcherEmitSpec`` and decoded by the realizer.
    ##
    ## An all-empty detail is the plain archive every pre-GM4b ``tarball``
    ## realization is: ``installMethod`` empty means ``extract``.
    version*: string
      ## Upstream version this archive realizes. Version-pinned profile
      ## references (``package(jdk, "21.0.5")``) select on it; an unpinned
      ## reference takes the first eligible realization in declaration
      ## order, so a package lists its default version first.
    sha512*: string
      ## Alternative digests for upstreams that publish no SHA-256. Exactly
      ## the precedence the catalog records had: sha256, then sha512, then
      ## the weak sha1.
    sha1*: string
    installMethod*: string
      ## ``extract`` (or empty), ``installer-msi``, ``installer-nsis``,
      ## ``installer-nsis-bundle``, ``installer-inno-setup``,
      ## ``installer-silent``, ``msys2-pacman`` or ``source-bootstrap``.
      ## Validated against ``TarballInstallMethods`` at authoring time; a
      ## realizer that cannot honour a method refuses the record.
    extractPath*: string
      ## Inner directory flattened to the prefix root after extraction.
    extraExecutables*: seq[string]
      ## Prefix-relative executables exported beside ``executablePath``.
    installerArgs*: seq[string]
    pacmanPackages*: seq[string]
    bootstrapArgv*: seq[string]
    env*: seq[string]
      ## ``NAME=value`` bindings; ``${prefix}`` is substituted with the
      ## realized prefix.
    nested7z*: bool
    msiAdminInstall*: bool
    preInstall*: seq[string]
      ## Encoded by ``packages_schema.preInstallAction``.
    preInstallUnrecognized*: seq[string]
    launcherEmit*: seq[string]
      ## Encoded by ``packages_schema.launcherEmitSpec``.
    cpuLevel*: string
      ## Microarchitecture floor (``x86-64-v3``), empty for none.
    cpuFeatures*: string
      ## Extra CPU features beyond the floor, comma separated.
    appBundle*: string
      ## GM4c: the macOS application bundle the archive delivers -- its path
      ## inside the archive (``Ghostty.app``; a component naming a flat
      ## ``.pkg`` is expanded and the path continues inside it). Set with
      ## ``installMethod = "app-bundle"`` (and on the declared-only
      ## ``pkg-install`` shape). For a macOS ``installer-silent`` record it
      ## is the PRODUCT bundle's path inside the realized prefix instead
      ## (``OpenWebStart/OpenWebStart javaws.app``); its first component is
      ## the placed item. Store-And-Installation-Layout.md § macOS
      ## Application Bundles.
    bundleId*: string
      ## GM4c: the bundle's ``CFBundleIdentifier``; checked before the bundle
      ## is published to the store and again before it is activated.
    teamId*: string
      ## GM4c: the Apple team identifier that signs the bundle. Required with
      ## ``appBundle``: the realization proves the signature chains to an
      ## Apple Developer ID certificate of this team.
    installerApp*: string
      ## The installer application's path inside the archive
      ## (``OpenWebStart Installer.app``) for a macOS ``installer-silent``
      ## record: the realizer copies it out, verifies it is signed by
      ## ``teamId`` and runs it confined, with ``installerArgs``, into the
      ## staging prefix. Store-And-Installation-Layout.md § Installer
      ## applications.

  TarballProvisioningDef* = object
    url*: string
    mirrors*: seq[string]
    sha256*: string
    detail*: TarballArchiveDetail
      ## GM4b archive-realization metadata; see ``TarballArchiveDetail``.
    archiveType*: string
    executablePath*: string
    executableAlias*: string
      ## Optional second name for the realized executable.
      ##
      ## Some upstreams ship a binary named after its target triple —
      ## ``codex-x86_64-pc-windows-msvc.exe`` — while every consumer invokes
      ## it as ``codex``. The realized prefix goes on PATH as a directory, so
      ## the program's name on PATH is the file's own name and the two do not
      ## meet. Before this, the only way to close that gap was a hand-written
      ## shim outside the store, which is precisely the out-of-band
      ## provisioning a package is supposed to remove.
      ##
      ## When set, realize places a copy beside the declared executable under
      ## this name. A copy rather than a symlink because the store must stay
      ## valid for users without the Windows privilege to create one, and
      ## because a relative symlink does not survive the archive-extraction
      ## boundary on every host.
    prunePaths*: seq[string]
      ## Prefix-relative paths deleted after extraction, before sealing.
      ##
      ## Several upstreams ship one archive that serves audiences a *build*
      ## environment does not have. The PostgreSQL Windows distribution
      ## carries a 671 MB pgAdmin GUI beside a 72 MB ``bin``; the LLVM
      ## release carries a debugger, an interpreter and a bugpoint reducer
      ## beside the compiler. Realizing those wholesale costs store space on
      ## every machine and, once a prefix passes the cache's request-body
      ## limit, costs the package its place in the shared cache entirely —
      ## so the one artifact other machines most want to install quickly is
      ## the one they must build for themselves.
      ##
      ## Each entry is a path relative to the prefix root, matched literally
      ## (no globbing) so a declaration says exactly what it drops; a path
      ## that is not present is not an error, because upstream layouts move
      ## between versions and a stale entry should not break a realize.
      ##
      ## Pruning is part of the prefix's identity: two hosts that prune
      ## differently hold different bytes and must not share a cache entry.
      ## ``toolCacheIdentity`` therefore keys on this list.
    nonRedistributable*: bool
      ## When true, a realized prefix of this entry is NEVER published to a
      ## shared binary cache. It is still realized, still content-addressed,
      ## still substitutable from a cache somebody else populated — it is
      ## only this machine that must not upload it.
      ##
      ## The case that forces it: an upstream archive a developer is
      ## licensed to download and run, but not to redistribute. Agent
      ## Harbor's electron-builder MSI target consumes
      ## ``winCodeSign-2.6.0``, which bundles Microsoft's ``signtool``; the
      ## coding-agent catalog has several vendor-binary payloads in the same
      ## position. Fetching one on a developer's behalf is ordinary;
      ## re-serving it from a cache other people pull from is a different
      ## act, and one nobody should perform by accident because they
      ## happened to have publish credentials configured.
      ##
      ## Deliberately NOT part of the prefix identity. The realized bytes
      ## are the same either way, so two hosts that disagree about this flag
      ## still hold the same prefix and may still share an entry one of them
      ## legitimately published. What the flag governs is the direction of
      ## travel, not the content.
    launcher*: string
      ## The interpreter that runs ``executablePath``, when the declared
      ## payload is a SCRIPT rather than a program.
      ##
      ## A realized prefix reaches PATH as a DIRECTORY, so a command's name
      ## there is a file's own name and the file has to be executable by the
      ## OS. That holds for a native binary and fails for everything npm
      ## publishes: ``@google/gemini-cli`` ships ``bundle/gemini.js`` and
      ## ``@qwen-code/qwen-code`` ships ``cli-entry.js``, and neither is a
      ## program. npm's own answer is to generate a launcher pair beside the
      ## bundle (``gemini`` plus ``gemini.cmd``), which is what this field
      ## asks realize to do.
      ##
      ## Set it together with ``executableAlias``, which supplies the NAME
      ## the launcher takes: ``executableAlias = "gemini"`` with
      ## ``launcher = "node"`` writes ``gemini`` and ``gemini.cmd`` beside
      ## ``bundle/gemini.js``, each invoking ``node`` on the bundle by a
      ## path relative to the launcher's own directory. Without a launcher
      ## an alias is a COPY of the declared file under a second name, which
      ## is the existing behaviour and stays unchanged.
      ##
      ## The interpreter is resolved from the consuming action's PATH rather
      ## than hard-coded to a store path, because the interpreter is itself
      ## a declared package — a recipe that uses this must declare ``node``
      ## as well, and the launcher then runs whichever ``node`` that
      ## recipe's activation put in front.
      ##
      ## Written before the prefix is sealed, so the launchers are part of
      ## the content-addressed tree rather than an edit to a published one —
      ## the same rule ``executableAlias`` follows, and for the same reason.
    closureManifest*: string
      ## Recipe-relative path to a committed manifest of ADDITIONAL archives
      ## unpacked into this prefix, for a package whose entry point does not
      ## run without its dependencies.
      ##
      ## The two npm agents a self-contained bundle does not cover:
      ## ``@zed-industries/claude-code-acp`` is 174 KB with five runtime
      ## dependencies, and ``@sourcegraph/amp`` is an 895-byte wrapper whose
      ## ``bin`` points into ``node_modules/@ampcode/cli/bin/`` — a
      ## platform-specific native binary reached through npm's
      ## optional-dependency mechanism. Neither is a single tarball, and
      ## neither should be a fetch-at-build-time step.
      ##
      ## **A file rather than entries in the recipe**, because the closure is
      ## GENERATED from the same ``package-lock.json`` that already pins every
      ## entry by integrity hash. Hand-transcribing it into a
      ## ``provisioning:`` block would turn a machine-checkable artifact into
      ## prose; committed beside the recipe it diffs like a lock file, which
      ## is what makes a dependency change reviewable.
      ##
      ## Format: one entry per non-blank, non-``#`` line, whitespace
      ## separated — ``<prefix-relative-path> <sha256> <url>``. The path is
      ## where that archive's contents land, matching the layout the entry
      ## point resolves against.
      ##
      ## **The limitation it inherits**, stated because it is why this is a
      ## path and not bytes: like ``expressionFile``, the manifest is read
      ## from the recipe's own directory at realize time, so a consumer that
      ## receives this provisioning as a CONTRIBUTION through an interface
      ## artifact does not get the file with it. A federated catalog
      ## publishing a closure package must be checked out, not merely
      ## pinned. Lifting that means moving the entries into the artifact,
      ## which is a larger change to the provisioning schema than this field.
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

  HomebrewProvisioningDef* = object
    ## A Homebrew cask or formula that installs the target package OUTSIDE
    ## Reprobuild (reprobuild-pm spec Provisioning-Contributions.md
    ## §"Homebrew bridge records"). A bridge record: it lets a consumer that
    ## still installs through Homebrew -- the reprobuild flake's
    ## ``reprobuild.lib.brewRealizationOf`` and the equivalence report --
    ## translate between Homebrew tokens and canonical package names.
    ## Reprobuild never realizes it: it is carried in the interface
    ## artifact's ``provisioningContributions`` only and is never merged into
    ## a tool use's realization candidates, so no selection policy can pick
    ## it. Declared only in a ``provisioningFor`` contribution
    ## (``brewCask "<token>"`` / ``brewFormula "<token>"``), never in a
    ## package's own ``provisioning:`` block.
    kind*: string
      ## ``"cask"`` or ``"formula"``.
    token*: string
      ## The Homebrew token (``brew info --cask <token>``), e.g.
      ## ``visual-studio-code`` or ``temurin@21``.
    tap*: string
      ## The tap that publishes the token; empty for the default taps
      ## (``homebrew/cask`` for casks, ``homebrew/core`` for formulae).
    sourceFile*: string
    sourceLine*: int

  ProvisioningContributionDef* = object
    ## A realization supplied independently of the package that owns the
    ## public interface. ``targetInterfaceFingerprint`` pins the contribution
    ## to that interface; ``developInterface`` resolves the active package
    ## fingerprint during local development and is not suitable for locks.
    targetPackage*: string
    targetInterfaceFingerprint*: string
    contributor*: string
    developInterface*: bool
    nixProvisioning*: seq[NixPackageProvisioningDef]
    tarballProvisioning*: seq[TarballProvisioningDef]
    scoopProvisioning*: seq[ScoopProvisioningDef]
    homebrewProvisioning*: seq[HomebrewProvisioningDef]
      ## Bridge records only; see ``HomebrewProvisioningDef``.
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

  RuntimeLibraryDef* = object
    ## A shared library this package PROVIDES, and where the dynamic loader
    ## finds it inside the realized prefix.
    ##
    ## Distinct from ``LibraryDef`` on purpose, and the distinction is the
    ## reason this type exists rather than a field being bolted onto that one.
    ## ``LibraryDef.exportedPath`` is a Nim SOURCE directory — what a
    ## library-consumer threads onto ``nim c --path:`` — and ``LibraryDef.kind``
    ## describes a library the package BUILDS from source. Neither says anything
    ## about a prebuilt ``.dll`` arriving inside a provisioned prefix, which is
    ## the case that matters for loading. Pointing ``exportedPath`` at
    ## ``Library/bin`` would tell Nim consumers to add a DLL directory to their
    ## source path.
    ##
    ## The declaration is per (cpu, os) slice for the same reason ``tarball``
    ## entries are: the directory follows the PROVISIONING SOURCE, so one
    ## package can be ``Library/bin`` when it arrives from conda-forge win-64
    ## and ``lib`` when it arrives from nixpkgs. See
    ## ``repro_dsl_stdlib/prefix_layout`` for the vocabulary that names those.
    name*: string
      ## The library's stem, as a consumer would name it — ``clingo``, not
      ## ``clingo.dll`` or ``libclingo.so``. The decorated file name is a
      ## platform property, and baking it in here would make the declaration
      ## unusable for the other platform.
    dir*: string
      ## Prefix-relative directory holding the LOADABLE artifact. This is the
      ## directory a launcher must make searchable, and on Windows it is the
      ## bin directory, not the lib one — ``clingo.dll`` really is at
      ## ``Library/bin/clingo.dll``.
    cpu*: string
      ## Empty (= "any") matches every host. Same taxonomy as
      ## ``TarballProvisioningDef.cpu``.
    os*: string
      ## Empty (= "any") matches every host. Same taxonomy as
      ## ``TarballProvisioningDef.os``.
    sourceFile*: string
    sourceLine*: int

  PlatformConstraintDef* = object
    ## PMC-1 (Platform-And-Microarchitecture-Constraints) — one entry of a
    ## package-level ``platforms:`` declaration:
    ##
    ##   package chocolatey:
    ##     platforms: [windows]
    ##
    ## Availability, NOT provisioning. ``TarballProvisioningDef.cpu`` / ``.os``
    ## say "here is the artifact for this host"; this says "the package can
    ## exist on this host at all". Conflating the two is the gap PMC-1 closes:
    ## before it, a package's availability was whatever set of arms happened to
    ## be written, so "Windows-only by nature" was unstatable and unlintable.
    ##
    ## Same token vocabulary as the arm setters — ``any`` / ``x86_64`` /
    ## ``aarch64`` / ``x86`` for ``cpu``, ``any`` / ``windows`` / ``linux`` /
    ## ``macos`` (``darwin``) for ``os``. Empty means "any". The COARSE axis
    ## only: microarchitecture levels (``x86-64-v3``) and feature sets are
    ## PMC-2 / PMC-3 and have no representation here.
    cpu*: string
    os*: string
    sourceFile*: string
    sourceLine*: int

  PlatformConstraint* = object
    ## The VALUE a `platforms` entry evaluates to.
    ##
    ## Distinct from `PlatformConstraintDef`, which is the stored model: this
    ## is what the author's expression produces, and it exists so `windows` can
    ## be a real `const` the compiler resolves rather than an identifier a
    ## macro reads as text. See `DSL-Macro-Authoring-Guide.md` in
    ## reprobuild-specs -- the three defects that motivated it (identifiers
    ## that are not symbols; a source with two readings that Nim's scope rules
    ## do not get to arbitrate; computed expressions impossible) all follow
    ## from the text-reading shape.
    cpu*: string
    os*: string

  PackageDef* = object
    packageName*: string
    lockFile*: string
      ## Named-Lock-Files NLF-M7 (§4.3) — the PACKAGE-level default, which
      ## "remains available as a default that artifacts inherit and may
      ## override". One rung below the artifact in the precedence chain.
    defaultToolProvisioning*: string
    platformsDeclared*: bool
      ## PMC-1: true ONLY when the package body wrote an explicit
      ## ``platforms:`` block. The resolver's availability gate keys off this
      ## flag, not off ``declaredPlatforms.len``, because "declared as the
      ## empty set" and "never declared" are different facts and only the
      ## second one must resolve exactly as it did before PMC-1.
    declaredPlatforms*: seq[PlatformConstraintDef]
      ## PMC-1: the declared coordinates, in source order. Empty for the ~262
      ## stdlib entries that have not been converted yet, and nothing derives
      ## a default for those — an undeclared package resolves exactly as it
      ## did before PMC-1. PMC-1 did ship an "infer from whichever arms
      ## exist" helper here, but it had no caller and could not see the
      ## harvested archive realizations (then separate catalog records; since
      ## GM4b ``tarball`` realizations of the package), so it was removed
      ## rather than left as a trap for PMC-5's lint to fall into.
    platformsMessage*: string
      ## PMC-1: optional author-supplied reason, Spack's ``msg=``. Reproduced
      ## verbatim in the unavailable-package diagnostic. The whole point is
      ## that the author knows WHY ("Chocolatey is a Windows package manager
      ## and has no POSIX build") and the resolver does not.
    executables*: seq[ExecutableDef]
    libraries*: seq[LibraryDef]
    runtimeLibraries*: seq[RuntimeLibraryDef]
      ## Shared libraries this package PROVIDES to consumers at run time,
      ## declared by the producing package because it is the only place that
      ## knows its own prefix layout. Populated by the ``runtimeLibrary``
      ## member; accessor ``registeredRuntimeLibraries(packageName)``.
      ##
      ## The consuming half is ``runtimeDeps:``, which already exists.
    toolUses*: seq[PackageUseDef]
      ## DSL-port M9.R.1: legacy ``uses:`` AND the new ``buildDeps:``
      ## block both populate this seq. ``buildDeps:`` is the canonical
      ## name going forward; ``uses:`` is kept as a synonym until the
      ## M9.R.5 recipe sweep renames the existing 84 recipes onto the
      ## new spelling. Accessor: ``registeredBuildDeps(packageName)``.
    packageSources*: seq[PackageSourceDecl]
      ## M5 SELF-HOST — the declared SOURCE PROVENANCE of depended-on
      ## packages, from the package body's ``packageSource <name>,
      ## <provenance>`` statements.
      ##
      ## MACRO-TIME ONLY, and deliberately: this field is read by
      ## ``emitVariantDeclarations`` to emit one ``packageSource(...)`` call
      ## ahead of the ``registerSolverDependency`` calls, so the declaration
      ## reaches ``buildPackageDecls`` before ``finalizeVariants()`` solves.
      ## It is NOT serialized into the emitted ``PackageDef(...)`` literal
      ## because the registry's consumers ask about artifacts and members,
      ## not about how the solved lock addresses a dependency — that question
      ## is answered by the lock itself.
    nativeBuildDeps*: seq[PackageUseDef]
      ## DSL-port M9.R.1: BUILD-platform tools and code generators
      ## needed to drive the build (Nix ``nativeBuildInputs``
      ## equivalent). Parsed with the same constraint-string grammar
      ## as ``uses:``; populated by the ``nativeBuildDeps:`` block.
      ## Accessor: ``registeredNativeBuildDeps(packageName)``.
    runtimeDeps*: seq[PackageUseDef]
      ## DSL-port M9.R.1: HOST-platform tools and libraries consumers
      ## need at runtime or link time (propagated through
      ## ``propagatedBuildInputs`` + ``DT_NEEDED`` in the Nix world).
      ## Parsed with the same constraint-string grammar as ``uses:``;
      ## populated by the ``runtimeDeps:`` block. Accessor:
      ## ``registeredRuntimeDeps(packageName)``.
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
    bdpIomonReport
      ## The edge's command PRODUCES its own io-mon ``.iomon`` dependency
      ## capture (e.g. ``ct test`` writing the record set of the files it
      ## actually read). The engine consumes THAT file as the edge's
      ## evidence, folding it via the monitor-evidence reader, instead of
      ## monitoring the orchestrator process. Declared with
      ## ``iomonReportPolicy`` / the ``iomonReport`` keyword, giving the
      ## produced file's path. Modelled on ``bdpMakeDepfile`` but routed to
      ## a distinct engine ``formatName`` because the file is io-mon's
      ## binary record format, not a make-format text depfile.
    # NOTE: there is intentionally NO ``bdpDeclaredOnly``. A recipe-facing
    # "declared-only" policy (track only statically declared inputs, no
    # runtime monitoring, mark the action complete/cacheable anyway) is an
    # unapproved soundness hole that lets depended-on files change without a
    # rebuild. It was re-introduced more than once by agents and is REMOVED;
    # opaque tools use ``bdpAutomaticMonitor``, and actions with no
    # monitorable evidence are made non-cacheable per Monitor-Hook-Shim.md:501.
    # See Reprobuild-Development.milestones.org M17.
    #
    # ``bdpTrustedDeclaredInputs`` — "declare the edge's inputs inline and
    # have the engine trust them", added for self-interposing test edges — was
    # the same idea in a narrower wrapper and has been REMOVED as well. An
    # action that cannot be monitored declares its inputs through a DEPFILE
    # (``bdpMakeDepfile``) instead: the list then lives in a file some edge
    # produces, can be regenerated, and is read back by the engine as real
    # evidence, so the paths in it actually invalidate the action cache.
    # ``unmonitorableActionDepfile`` in ``runtime_core.nim`` generates one.

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
    suppressMonitorShimSeed*: bool
      ## Withhold the launch-time ``REPRO_MONITOR_SHIM_LIB`` environment seed
      ## from this edge's action. Lowered onto the engine
      ## ``DependencyGatheringPolicy`` field of the same name, where the full
      ## rationale lives.
      ##
      ## Default false, so no existing edge changes. Set it ONLY for an action
      ## that performs library interposition itself: leaving the engine's
      ## monitor un-wrapped is not sufficient to keep such an action shim-free,
      ## because io-mon's preload runtime propagates whatever this variable
      ## names into the processes the action starts, re-injecting our shim
      ## alongside the action's own. Requested with
      ## ``makeDepfilePolicy(..., suppressMonitorShimSeed = true)``.
    captureBreadth*: MonitorCaptureBreadth
      ## DA-6 — the TOOL PACKAGE's declaration of how much of io-mon's event
      ## stream this edge's action asks for. Written beside the tool's CLI
      ## spec, where the tool is known:
      ##
      ##   executable nim:
      ##     cli:
      ##       dependencyPolicy automaticMonitor,
      ##         captureBreadth = omitAmbientReads
      ##
      ## and inherited by every nested ``subcmd`` exactly the way the rest of
      ## ``dependencyPolicy`` is. Lowered onto the engine
      ## ``DependencyGatheringPolicy`` field of the same name, where the full
      ## rationale lives; the vocabulary itself is documented at
      ## ``MonitorCaptureBreadth`` in
      ## ``repro_core/dependency_gathering.nim``.
      ##
      ## Defaults to ``mcbFullCapture``, so a tool package that says nothing
      ## asks for everything. A RECIPE should not set this: it knows neither
      ## io-mon's record kinds nor which of them the tool it is calling emits.
      ##
      ## ``captureNonDeterminism = true`` / ``= false`` is still accepted in a
      ## ``dependencyPolicy`` declaration as a spelling of this field
      ## (``true`` -> ``fullCapture``, ``false`` -> ``omitAmbientReads``), so
      ## no recipe that set it breaks — but it now MEANS something, namely the
      ## ambient reads and nothing else. ``captureIpc`` is RETIRED and the
      ## parser refuses it by name: ``mrIpcConnect`` is not gate-able at any
      ## granularity after DA-5, so no value of that switch could ever be
      ## honoured.

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

  ActionCwdKind* = enum
    ## M9.R.74 — canonical execution root (R2) per-action declaration.
    ## Spec cite: Hermetic-Builds-And-Path-Independence.md
    ## §"Per-action execution-root declaration". Each action declares
    ## which engine-managed root it wants to run under; the engine
    ## resolves the enum to an absolute path at spawn time.
    ##
    ## ``acwdRecipeRoot`` is the enum's zero value so v20-and-earlier
    ## payloads (which predate this field) decode with the legacy
    ## behaviour byte-for-byte — every existing recipe continues to
    ## run under its recipe/project root without any behavioural
    ## change until it explicitly opts into a tighter kind.
    acwdRecipeRoot   ## Legacy default — the recipe's project root
                     ## (``activeProviderProjectRoot()``). Equivalent to
                     ## the pre-M9.R.74 hardcoded ``cwd = projectRoot``
                     ## on every non-``inlineExecCall`` path.
    acwdSource       ## The extracted upstream source tree — typically
                     ## ``<recipeRoot>/src/`` or the fetch action's
                     ## ``extractedRoot`` override.
    acwdBuild        ## The out-of-tree build directory — typically
                     ## ``<recipeRoot>/build/`` or a convention-supplied
                     ## override. Used by ``compile`` actions.
    acwdInstall      ## The DESTDIR staging directory the install action
                     ## writes into (typically
                     ## ``<recipeRoot>/build/out/``). Used by post-install
                     ## fix-up (``.la`` cleanup, stage-copy, mirror).
    acwdCustom       ## A caller-supplied absolute or recipe-relative
                     ## path — matches the pre-existing
                     ## ``inlineExecCall(argv, cwd = X)`` shape. The
                     ## resolved path is taken from
                     ## ``BuildActionDef.cwdCustomPath``.

  ToolIdentityRefKind* = enum
    ## Platform role for an action's tool-identity reference. Values match
    ## ``repro_build_engine/platform.DepKind`` and are mapped explicitly by
    ## the CLI when the provider graph is lowered.
    tirkBuild = 0'u8
    tirkNative = 1'u8
    tirkRuntime = 2'u8

  BuildActionDef* = object
    id*: string
    call*: PublicCliCall
    deps*: seq[string]
    inputs*: seq[string]
    outputs*: seq[string]
    optionalOutputs*: seq[string]
      ## Tool-owned output candidates whose existence depends on the tool's
      ## result (for example an MSVC import library for a DLL with exports).
      ## Absent candidates are successful; present candidates are cached and
      ## restored. Ordinary ``outputs`` remain obligatory. The engine removes
      ## old candidates before execution and restores their recorded absence
      ## on a cache hit, so stale artifacts cannot impersonate fresh output.
    pool*: string
    poolUnits*: uint32
    depfile*: string
    dynamicDepsFile*: string
    cacheable*: bool
    commandStatsId*: string
    dependencyPolicy*: BuildActionDependencyPolicy
    nonDeterminism*: NonDeterminismPolicy
      ## Windows-Build-Correctness M6 — the entropy blessing of the TOOL this
      ## edge invokes, stamped by the generated wrapper from the tool's CLI
      ## spec. It is deliberately NOT a formal parameter of that wrapper: an
      ## edge must not be able to bless a tool, and — just as important — a
      ## hand-written alias like ``nim.c`` cannot silently DROP the blessing
      ## the way it already replaces ``dependencyPolicy`` (see
      ## ``compileDependencyPolicy`` in ``packages/nim.nim``).
    nonDeterminismJustification*: string
      ## The tool's stated reason, carried alongside the blessing so the
      ## engine's evidence diagnostics can quote it.
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
    fixedOutput*: bool
      ## Cache-Scope P3.4 — a FIXED-OUTPUT action (BuildXL's download pip,
      ## Nix's fixed-output derivation): its outputs are determined by
      ## content hashes it DECLARES and VERIFIES — a tarball checked against
      ## a sha256, a vendored closure checked against lockfile integrity —
      ## not by what the network happened to return. It stays locally
      ## non-cacheable (it reaches the network), but its portable record is
      ## keyed by its static description and declared inputs alone, so the
      ## portable lookup can resolve it without running it.
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
    toolIdentityRefs*: seq[string]
      ## M9.N Batch B: names of tools (matching the recipe's
      ## ``uses:`` package selectors, e.g. ``"meson"``, ``"gcc"``,
      ## ``"sh"``) this action invokes at execution time. The engine
      ## resolves each ref via the CLI-supplied
      ## ``BuildEngineConfig.toolIdentityResolver`` closure to a
      ## ``ToolActionIdentity`` and prepends the resolved binary
      ## directory to the action's ``PATH`` env at fork time. Empty
      ## (the default) keeps legacy behaviour — the action's argv
      ## must reference absolute paths or the host's pre-existing
      ## PATH. Payload codec v17+.
      ##
      ## Why this exists: pre-M9.N-Batch-A the from-source +
      ## c_cpp conventions baked absolute ``findExe(...)`` paths into
      ## argv at recognise time. On a host without meson/cmake/gcc
      ## installed this produces an invalid argv and the engine
      ## fork fails before the tool catalog can substitute. Batch B
      ## moves identity resolution into the engine: the convention
      ## emits a bare tool name + the list of ``toolIdentityRefs``,
      ## the engine resolves them at fork time, and PATH is
      ## populated with the resolved store paths so the bare tool
      ## name finds the right binary.
    subToolRefs*: seq[string]
      ## The typed tool's own ``subTools`` (see ``CliCommandDef.subTools``),
      ## copied onto each edge the tool's wrapper records. Each name that
      ## matches a resolved ``uses:`` tool contributes that tool's
      ## directory to the edge's ``PATH`` ahead of everything else, and
      ## keeps the tool resolvable for a fragment build that selects only
      ## this edge. Unlike ``toolIdentityRefs`` these do NOT opt the edge
      ## into a hermetic ``PATH``: the tool vouches for what IT runs, not
      ## for what the edge's build scripts may run. Payload codec v29+.
    toolIdentityRefKinds*: seq[ToolIdentityRefKind]
      ## Platform role parallel to ``toolIdentityRefs``. An empty or
      ## mismatched list preserves the legacy ``tirkBuild`` default.
      ## Constructor-generated actions populate this list so native tools
      ## retain PATH priority while target dependency headers and libraries
      ## can precede a native toolchain's transitive sysroot.
    requiresElevation*: bool
      ## Windows-System-Resources Phase E: marks an action edge as
      ## one whose execution must cross the privileged-operation
      ## broker. The engine's ``reprobuild.builtin.exec`` lowering
      ## consults this flag: ``false`` (the default) routes through
      ## the standard build engine fork path; ``true`` packages the
      ## action's argv + tool refs + env into a ``pokInlineExecCall``
      ## ``PrivilegedOperation`` and dispatches via the broker.
      ##
      ## Payload codec v19+. v18-and-earlier payloads decode with
      ## ``requiresElevation = false`` so legacy artefacts continue
      ## to take the non-elevated fork path. Default ``false`` keeps
      ## every existing build-graph edge byte-identical to today.
    rebootRequired*: bool
      ## Declares that this edge's effect does not take hold until the
      ## machine restarts, so an apply that RAN it owes the operator a
      ## reboot notice.
      ##
      ## Read this next part before using it. Until this field existed,
      ## ``ApplyResult.restartNeeded`` had exactly ONE write site, fed by
      ## exactly four originators, and all four were behind
      ## ``when defined(windows)``. On every other platform the flag was
      ## provably always ``false``, which made the "a reboot is required"
      ## line the apply already prints a rule with no reachable input --
      ## unreachable code wearing the costume of a live one. This field is
      ## the seam that gives it an input from a profile, on any platform.
      ##
      ## Scope, stated so it is not mistaken for something wider: this is a
      ## PROFILE-scope attribute, consumed by ``repro infra apply``'s
      ## action-edge half. It is deliberately NOT carried by the versioned
      ## binary payload codec in ``runtime_core``, which serialises build
      ## edges for project-interface artefacts -- an artefact round trip has
      ## no apply to report a reboot to, and a codec version bump for a
      ## field nothing on that path reads would cost every consumer an
      ## envelope revision for nothing. A ``BuildActionDef`` that has been
      ## through that codec therefore decodes with ``rebootRequired =
      ## false``; the profile path does not go through it.
    recipeRevisionFingerprint*: string
      ## M9.R.34: BLAKE3-style digest of the recipe (``repro.nim`` /
      ## ``reprobuild.nim``) file bytes the action was emitted from.
      ## ``buildAction`` auto-populates this at registration time
      ## from ``activeProviderProjectRoot()`` so per-recipe action
      ## graphs (cmake_package / autotools_package / meson_package /
      ## from-source-custom shell rows) capture recipe edits in their
      ## local action-cache fingerprint. The engine-side lowering in
      ## ``repro_cli_support.lowerGraphAction`` includes the encoded
      ## ``node.payload`` in every ``fingerprintText`` it composes, so
      ## any change here automatically buses the action's local
      ## ``weakFingerprint``. The binary-cache key continues to be
      ## composed via ``cacheEntryIdentity.providerRevision``
      ## (which already hashes the same recipe file via
      ## ``providerRevisionHex``), so this field affects only the
      ## local action cache — binary-cache semantics are unchanged.
      ##
      ## Payload codec v20+. v19-and-earlier payloads decode with an
      ## empty string so legacy artefacts continue to round-trip; the
      ## first time a new provider re-emits actions the field is
      ## populated and every previously-cached action gets a fresh
      ## fingerprint (one-shot invalidation by construction — that
      ## IS the milestone outcome). Outside provider mode (unit
      ## tests, hand-rolled ``buildAction`` callers) the field stays
      ## empty so existing fixtures see no behaviour change.
    cwdKind*: ActionCwdKind
      ## M9.R.74 — canonical execution root (R2) declaration. Default
      ## ``acwdRecipeRoot`` (enum's zero value) preserves the legacy
      ## behaviour byte-for-byte: every action registered before this
      ## milestone runs under the recipe's project root, matching the
      ## pre-M9.R.74 hardcoded ``cwd = projectRoot`` on every
      ## ``lowerGraphAction`` branch.
      ##
      ## Convention emitters (``autotools_package`` / ``meson_package``
      ## / ``cmake_package`` / ``from_source_custom``) declare tighter
      ## kinds (``acwdBuild`` for ``compile`` actions, ``acwdSource``
      ## for ``configure`` scripts, ...) so the engine sees the
      ## intended CWD instead of an inlined ``cd $buildDir`` that
      ## hides it inside the shell command. Recipes that used
      ## ``inlineExecCall(argv, cwd = X)`` before M9.R.74 keep working
      ## unchanged — the CLI-support lowering routes them through
      ## ``acwdCustom`` internally with ``cwdCustomPath = X``.
      ##
      ## Payload codec v21+.
    cwdCustomPath*: string
      ## Companion path for cwd declarations that need a concrete
      ## directory. For ``acwdSource`` / ``acwdBuild`` / ``acwdInstall``
      ## the convention emitter records the resolved recipe-relative
      ## path (for example ``build`` or ``.repro/build/pkg``). For
      ## ``acwdCustom`` this is the caller-supplied absolute or
      ## recipe-relative path. Empty reduces to ``acwdRecipeRoot`` at
      ## resolve time — matching the pre-M9.R.74 behaviour of the
      ## ``inlineExecCall(argv, cwd = "")`` overload whose CLI-support
      ## fallback was ``projectRoot``. Payload codec v21+.
    scratchDirs*: seq[string]
      ## The action's scratch directories (BuildXL's pip temp directories):
      ## emptied by the engine before the action runs, and nothing the action
      ## does under one is an input or an output. A working tree the action
      ## builds in belongs here; what it produces goes to `declaredOutputs`.
      ## See `BuildAction.scratchDirs` in the engine. Payload codec v30+.
    removeBeforeRun*: seq[string]
      ## Declared outputs the engine removes before the action runs, for a
      ## tool that refuses to write over an existing output (create-dmg's
      ## ``hdiutil convert``). Each must be one of the action's own outputs;
      ## removal never follows a link. Declared by a typed tool with
      ## ``cli: removeBeforeRun <flag>`` or passed to ``buildAction``. See
      ## `BuildAction.removeBeforeRun` in the engine. Payload codec v31+.
    declaredOutputs*: seq[string]
      ## M9.R.75 — R7 (double-write reject) per-action write-root
      ## declaration. Spec cite: Filesystem-Policy-And-Observed-
      ## Inputs.md §"Double Writes" (lines 246-262). Each entry is a
      ## directory (or file) path this action commits to writing during
      ## its execution. The engine's ``validateGraph`` pass runs a
      ## pairwise intersection over all actions' ``declaredOutputs``
      ## seqs; overlap (prefix / containment / equality) is a
      ## graph-time error naming both action ids + the conflicting
      ## path.
      ##
      ## Distinct from ``outputs`` — that field is the per-action
      ## stamp / artefact set the engine checks for post-run readiness
      ## and cache-key composition, and it is typically a single
      ## stamp file (``.repro/stamps/<recipe>-<phase>.stamp``) that
      ## differs per action by design so the existing string-equality
      ## check in ``validateGraph`` doesn't fire. ``declaredOutputs``
      ## carries the FULL write ROOT (``$buildDir`` / ``$installDir`` /
      ## ``$fetchExtracted``) so the intersection pass can catch two
      ## configure or install actions racing for the same DESTDIR.
      ##
      ## Empty (the default) preserves the pre-M9.R.75 behaviour
      ## byte-for-byte: the intersection pass no-ops for actions that
      ## didn't opt in. Payload codec v22+.
    readOnlyRoots*: seq[string]
      ## M9.R.75 — R6 (source-write reject) per-action read-only-root
      ## declaration. Spec cite: Filesystem-Policy-And-Observed-
      ## Inputs.md §"Source Rewrites" (lines 264-278). Each entry is a
      ## directory (or file) path this action MUST NOT write to during
      ## its execution — typically the extracted upstream source tree
      ## (the ``acwdSource`` root).
      ##
      ## Enforcement shapes (either or both):
      ##
      ## Shape A (bwrap sandbox, Linux): the engine's spawn wrapper
      ## adds ``bwrap --ro-bind <root> <root> ...`` for each entry,
      ## so an in-action write attempt fails hard with EROFS.
      ##
      ## Shape B (post-hoc monitor check, all platforms): after the
      ## action completes, the engine walks io-mon evidence for
      ## ``mrFileWrite`` records under any entry and hard-fails the
      ## action with a ``source-write attempt: <path>`` error.
      ##
      ## Fetch actions leave this empty — R6 explicitly names the
      ## fetch step as "the action explicitly owns the target
      ## location" and permits it to write into the source tree.
      ##
      ## Empty (the default) preserves the pre-M9.R.75 behaviour
      ## byte-for-byte: the source-write check no-ops. Payload
      ## codec v22+.
    sourceFile*: string
    sourceLine*: int
    extensions*: seq[ExtensionBox]

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
    btkTarget        ## plain ``target("name", handle)`` registration.
      ## Added so the two call shapes that produce the SAME payload
      ## shape — one action, no nested targets — stay distinguishable.
      ## Before this value existed, ``target("ct-binary", ct)`` and a
      ## degenerate ``aggregate("ct", actions = @[ct], targets = @[])``
      ## decoded identically, so the graph linker could not tell a
      ## RENAME from a one-member GROUPING and refused the pair outright
      ## ("action ... has multiple direct target aliases"). Appended
      ## rather than inserted: the payload ``kind`` byte is positional,
      ## and v1/v2 payloads still have to decode as ``btkAggregate`` (0).

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
    extensions*: seq[ExtensionBox]

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
    tekRunEdge    ## Declared via ``run "name", build = <handle>, ...``
                  ## (Named-Runnable-Edges N0). A named run-edge is a
                  ## build target whose action is an *execution* rather
                  ## than an artifact-producing edge; the row additionally
                  ## carries the run-edge ``runArgs`` + ``consumes`` lease
                  ## list so N1 (CLI routing) and N2 (lease bridge) can
                  ## resolve + reconcile it. A dedicated kind (rather than
                  ## a flag on ``tekExplicit``) follows the M5 grain where
                  ## each new authoring surface gets its own discriminator
                  ## byte, so ``classifyBuildSelector`` / the resolver can
                  ## branch on it directly.

  RunEdgeLeaseKind* = enum
    ## Named-Runnable-Edges N0: the DSL-layer mirror of
    ## ``repro_resources/lease.nim``'s ``LeaseKind``. The DSL sits BELOW
    ## ``repro_resources`` in the dependency order (``repro_resources``
    ## imports the DSL, not the reverse), so ``TargetExportEntry`` cannot
    ## name ``LeaseKind``/``LeasedDep`` directly. ``repro_resources``'s
    ## run-edge surface converts each ``LeasedDep`` into a
    ## ``RunEdgeLease`` (primitives only) on the way in and back on the
    ## way out, so the lease policy round-trips through the target-export
    ## table codec without redefining the lease *value* type. The enum
    ## ordinals MUST match ``LeaseKind`` (keep/immediate/delayed) so the
    ## conversion is a plain ``ord`` cast.
    relKeep       ## mirrors ``lkKeep`` — never auto-reap
    relImmediate  ## mirrors ``lkImmediate`` — reapable when the consume finishes
    relDelayed    ## mirrors ``lkDelayed`` — keep ``ttlSeconds`` after last use

  RunEdgeLease* = object
    ## Named-Runnable-Edges N0: the serializable projection of a
    ## ``repro_resources`` ``LeasedDep`` attached to a run-edge's
    ## ``consumes``. Primitives only (no ``Duration``/``Option``) so the
    ## DSL can carry + serialize it without importing ``repro_resources``.
    address*: string        ## the leased state's resource address / ``stateGroup`` name
    consumerId*: string     ## the holder id (defaults to ``address``)
    policyKind*: RunEdgeLeaseKind
    ttlSeconds*: int64      ## meaningful only for ``relDelayed`` (else 0)

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
    runArgs*: seq[string]
      ## Named-Runnable-Edges N0: the ``args = @[...]`` list of a
      ## ``run "name", ...`` run-target — forwarded to the execution by
      ## N1's ``repro run`` executor. Empty for every non-run-edge row
      ## (``tekImplicit``/``tekExplicit``/``tekAggregate``/
      ## ``tekCollection``), so pre-N0 rows and recipes that use none of
      ## the new surfaces round-trip byte-identically (the v3 codec writes
      ## these trailing fields only when they are non-empty on a
      ## ``tekRunEdge`` row; v1/v2 payloads decode them empty).
    consumes*: seq[RunEdgeLease]
      ## Named-Runnable-Edges N0: the run-edge's leased-state consumption
      ## list — the serializable projection of ``repro_resources``'s
      ## ``seq[LeasedDep]`` (see ``RunEdgeLease``). N2's lease bridge reads
      ## this back to reconcile + renew the named ``stateGroup`` around the
      ## exec. Empty for non-run-edge rows.

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

  BuildOutputPath* = object
    ## A path STRING that carries its producing edge.
    ##
    ## ``Package-Model.md``: "a ``BuildOutput.path`` reaches ``args`` as a
    ## context-carrying string and the framework records the edge through
    ## the typed proxy, just as Nix's string-with-context records
    ## derivation references inside ordinary string splices". This is that
    ## proxy: ``&`` with a plain string keeps the context, and the
    ## ``args`` overload set distinguishes it from a bare ``string``
    ## (which records no edge).
    ##
    ## The producer is carried as three FLAT fields rather than an
    ## embedded ``BuildOutput``, because ``BuildOutput.path`` is a FIELD of
    ## this type and a mutual embedding would be infinitely sized. It is a
    ## field and not an accessor proc for a measured reason: a top-level
    ## ``proc path*`` in this module puts ``path`` into the namespace of
    ## every recipe that imports the DSL, and
    ## ``libs/repro_project_dsl/tests/dsl_port/t_dsl_tool_provisioning_staged.nim``
    ## asserts ``not declared(path)`` precisely to stop that — ``path`` is
    ## a tool-provisioning vocabulary word scoped to its own expression.
    ## Field access costs nothing in the namespace and is the spelling
    ## ``Package-Model.md`` already uses (``cfg.path``).
    value*: string
    producerPackage*: string
    producerActionId*: string
    producerPath*: string
      ## The producing edge's DECLARED output path, which is not the same
      ## as ``value`` once ``&`` has been applied: ``"--config=" &
      ## cfg.path`` has an argv token the graph cannot match on and a
      ## producer path it can.

  BuildOutput* = object
    ## A typed handle on a file this project's build graph PRODUCES.
    ##
    ## Returned by the rendering helpers (``renderConfigFile``) and
    ## consumed by a ``service`` block's ``args`` / ``runtimeFile``
    ## setters. ``Package-Model.md`` §Collections: "`service` does not
    ## have a `config:` setter. Configuration is the package's job:
    ## package-level `config:` configurables plus rendering helpers
    ## (`literalConfigFile`, `configFile`, etc.) produce a `BuildOutput`,
    ## and the service consumes that output the same way any other build
    ## output is consumed — either by reference on argv or via
    ## `runtimeFile`."
    ##
    ## The handle carries the PRODUCING EDGE, not just a path: that is
    ## what makes the service's reference an edge in the graph rather
    ## than a string that happens to look like a path.
    packageName*: string
    actionId*: string
      ## The id of the build action that writes ``filePath``. Empty only
      ## for a handle built by hand (no producing edge is then recorded).
    filePath*: string
      ## The output path exactly as the producing action declares it, so
      ## ``inferDeclaredActionDeps`` can match it by string equality.
    path*: BuildOutputPath
      ## The same path as a context-carrying string — what ``args`` and
      ## ``runtimeFile`` take. Kept in sync by ``newBuildOutput``, which
      ## is the only constructor recipes should use.

  ServiceExecutableKind* = enum
    ## How a ``service`` body's ``executable <expr>`` setter named its
    ## binary. ``sxkUnset`` is the ground state for a body that has no
    ## ``executable`` setter at all (an ``execStart``-only systemd unit).
    sxkUnset
    sxkArtifact
      ## ``executable <ident>`` — an ``executable <ident>:`` artifact of
      ## this package. The ident's TEXT is recorded; the macro never
      ## evaluates the node, so this form works before the artifact slot
      ## variable has a value.
    sxkPackageExecutable
      ## ``executable redis.executable("redis-server")`` — a typed
      ## ``SelectedExecutable`` from a package reached through ``uses:``.
    sxkBuildOutput
      ## ``executable <buildOutput>`` — a binary this graph builds.
    sxkPath
      ## ``executable "<path>"`` — a literal path.

  ServiceExecutableRef* = object
    ## The typed executable edge of one ``service`` block.
    kind*: ServiceExecutableKind
    packageName*: string
    executableName*: string
    path*: string
    actionId*: string
      ## The producing action, when the executable is a build output.

  ServiceArgKind* = enum
    svakLiteral
      ## A plain string. Records NO edge.
    svakBuildOutput
      ## A ``BuildOutputPath`` — the argument carries its producing edge.

  ServiceArgDef* = object
    ## One element of a ``service`` body's ``args "...", ...`` setter, in
    ## declaration order.
    kind*: ServiceArgKind
    value*: string
      ## The argv token.
    producerPackage*: string
    producerActionId*: string
    producerPath*: string
      ## The declared output path of the producing edge. Set only for
      ## ``svakBuildOutput``.

  ServiceRuntimeFileDef* = object
    ## One ``runtimeFile <buildOutput>`` setter: a build output the
    ## service must have alongside it at runtime even though the path
    ## does not appear on argv.
    path*: string
    producerPackage*: string
    producerActionId*: string

  ServiceReadinessKind* = enum
    ## Shared-Development-Services L9 — the ``readiness`` setter
    ## §9.1 writes (``readiness httpGet("/debug/ready", port = port)``).
    ##
    ## THE THREE ARMS ARE THE THREE THE SUPERVISOR IMPLEMENTS, and that
    ## is deliberate rather than conservative: ``readinessOk`` in
    ## ``repro_cli_support/dev_session.nim`` switches on exactly
    ## ``none`` / ``fileexists`` / ``httpget`` and treats anything else
    ## as never-ready. A fourth arm here would be a word a recipe could
    ## write, that reached the artifact, and that made the service hang
    ## until its timeout with nothing said -- the silent-drop shape this
    ## campaign exists to find, in its worst form (a hang, not a miss).
    ##
    ## ``srkUnset`` is ordinal 0 so a record that never saw the setter
    ## -- every pre-L9 recipe -- is distinguishable from one that wrote
    ## ``readiness none``. The distinction is load-bearing: UNSET means
    ## "ask the ``servicePlaceholder``", and ``none`` means "this author
    ## says there is nothing to wait for". Collapsing them would make a
    ## typed ``readiness none`` beside a placeholder's ``fileExists``
    ## silently discard the placeholder's probe.
    srkUnset = 0
    srkNone
    srkFileExists
    srkHttpGet

  ServiceReadinessDef* = object
    ## One ``readiness`` declaration on a ``service`` body.
    kind*: ServiceReadinessKind
    path*: string
      ## ``readiness fileExists("<path>")``. Relative paths are resolved
      ## against the project root by the supervisor, exactly as the
      ## placeholder's ``readiness.path`` is -- one resolution, not two.
    url*: string
      ## ``readiness httpGet(url = "<base>")``, or the ``http://
      ## 127.0.0.1:<port>`` base derived from ``port = <n>``.
    timeoutMs*: int
      ## ``timeoutMs = <n>``. Zero means UNDECLARED, so the supervisor's
      ## own default applies; there is no second copy of that default
      ## here to drift from it.

  ServiceInstanceDef* = object
    ## Shared-Development-Services L9 — the typed form of the
    ## ``instance`` block that until now existed only inside a
    ## ``servicePlaceholder``'s JSON metadata.
    ##
    ## WHAT IS NOT HERE: ``environment``. The JSON block accepts one,
    ## and this block REFUSES it by name, because §6.4 makes the
    ## selected environment a per-invocation tracked input
    ## (``REPRO_ENVIRONMENT`` -> ``canonicalEnvironmentSelection``) and
    ## §6.5 makes it part of the instance key. A recipe that also wrote
    ## the name would be a second answer to "which environment is this
    ## instance keyed under", and the two could disagree with nothing
    ## said. The typed lane DERIVES it from the selection instead.
    declared*: bool
      ## Whether the body carried an ``instance:`` block at all. A
      ## service with no block is session-owned, which is every service
      ## that existed before L7.
    leaseTtlSeconds*: int64
      ## ``lease keep`` (-1, the default -- D-SS5) | ``immediate`` (0) |
      ## ``delayed(<n>)`` (n > 0).
    environment*: string
      ## The environment this instance is keyed under, DERIVED from the
      ## selection at evaluation time rather than declared. Empty when
      ## no environment is selected, which is its own key component
      ## (L5, D-SS8: "``repro up`` implies nothing").

  ServiceTriggerKind* = enum
    ## The ``on <trigger>:`` taxonomy of ``Package-Model.md``
    ## §"Service Lifecycle And Reactive Triggers".
    stkRebuild        ## ``on rebuild <ident>``
    stkChangeOutput   ## ``on change <buildOutput>``
    stkChangePath     ## ``on change "<path>"``
    stkStart          ## ``on start``
    stkStop           ## ``on stop``
    stkCrash          ## ``on crash``

  ServiceTriggerActionKind* = enum
    ## The actions legal inside an ``on <trigger>:`` body.
    stakHotReload
    stakRestart
    stakSendSignal
    stakExec
    stakNotify

  ServiceTriggerAction* = object
    kind*: ServiceTriggerActionKind
    argument*: string
      ## The action's trailing source text, verbatim and unparsed. The
      ## signal name for ``sendSignal``, the command for ``exec``, the
      ## endpoint for ``notify`` — and, for the two actions that take
      ## named options rather than an argument, those options' own text:
      ## ``restart backoff = exponential, maxRetries = 3`` records
      ## ``backoff = exponential, maxRetries = 3`` and ``hotReload
      ## otherwise sendSignal "SIGHUP"`` records ``otherwise sendSignal
      ## "SIGHUP"``. Empty only when the action was written with nothing
      ## after it (a bare ``restart`` / ``hotReload``).
      ##
      ## This comment used to say "empty for ``hotReload`` / ``restart``",
      ## which measurement contradicts — see
      ## ``t_dsl_service_typed_edges.nim``'s "supervisor options are
      ## carried whole, not truncated" suite, whose three cases read
      ## exactly those texts out of this field. The correction matters
      ## beyond tidiness: L1's reason for ACCEPTING the unimplemented
      ## ``hotReload otherwise <action>`` while REFUSING the unimplemented
      ## ``debounce`` / ``coalesce`` modifiers is that this field can hold
      ## the former and nothing can hold the latter.

  ServiceTriggerDef* = object
    kind*: ServiceTriggerKind
    subject*: string
      ## The rebuilt ident for ``stkRebuild``, the watched path for
      ## ``stkChangeOutput`` / ``stkChangePath``, empty otherwise.
    producerActionId*: string
      ## The producing edge of a watched build output. ``stkChangeOutput``
      ## only.
    actions*: seq[ServiceTriggerAction]

  CertificateNodeKind* = enum
    ## Test-Certificates TC-9a: what a ``certificate "<name>", <handle>``
    ## marking points at. The byte is positional in the certificate-export
    ## table payload; append new values, never insert.
    cnkAction  ## a single build edge (``BuildActionDef.id``)
    cnkTarget  ## a build target: ``target``, ``aggregate`` or ``collect``
               ## (``BuildTargetDef.name``)

  CertificateExportEntry* = object
    ## Test-Certificates TC-9a: one row of a package's certificate-export
    ## table (Test-Certificates.md §"Marking a node"). The name is also a
    ## row of the target-export table, so ``repro build <name>`` selects
    ## the node; this table records that the node PRODUCES a named
    ## certificate, which the target-export table cannot express.
    name*: string
      ## The certificate name. It maps onto the test-certificate standard
      ## as a ``targets`` entry.
    owningPackage*: string
    nodeKind*: CertificateNodeKind
    node*: string
      ## ``cnkAction``: the action id. ``cnkTarget``: the build-target name.
    implicit*: bool
      ## True for the marking the DSL applies, with no ``certificate
      ## "test", ...`` declaration, to the node a plain ``repro test``
      ## builds: the one the selector ``test`` resolves to (D15).
    sourceFile*: string
    sourceLine*: int
      ## The declaration site. For an implicit row, the site of the
      ## ``test`` target or export row when one was recorded.

  CertificateExportTable* = object
    entries*: seq[CertificateExportEntry]

  StateGroupDef* = object
    ## Named-Runnable-Edges N0 (spec §3.3): a named resource subgraph —
    ## the leasable/reapable unit. ``members`` are the resource addresses
    ## declared inside the ``stateGroup "name":`` block, in declaration
    ## order. The group name resolves to exactly these addresses so N2's
    ## lease bridge can reconcile the subgraph; the L1 state store still
    ## keys per-resource — this record is only the ergonomic grouping
    ## layered over member addresses (it does not change the store).
    name*: string
    members*: seq[string]
    sourceFile*: string
    sourceLine*: int

const
  SharedServiceInstanceKeepTtlSeconds* = -1'i64
    ## Shared-Development-Services D-SS5's decision, as ONE number.
    ##
    ## `repro_cli_support`'s `SharedServiceInstanceDefaultTtlSeconds`
    ## IS this constant rather than a second copy of it: L7 decided
    ## `keep` is the default for a `stable`, state-owning service, and
    ## two spellings of `-1` in two libraries is the drift the campaign
    ## has already paid for once (`EnvironmentPrecedence` needed a
    ## standing assertion to keep it aligned with
    ## `ContributionPriority`). The typed `instance:` block lowers here
    ## and the JSON `instance` block reads the alias, so there is one
    ## wire spelling of `keep`.

proc allToolUses*(pkg: PackageDef): seq[PackageUseDef] =
  ## Every dependency entry a TOOL-PATH consumer needs, in one seq:
  ## ``uses:``/``buildDeps:``, then ``nativeBuildDeps:``, then
  ## ``runtimeDeps:``.
  ##
  ## Named-Lock-Files NLF-M8, the third criterion folded in from NLF-M7 —
  ## **un-merge the three dependency lists at serialization.** Until this,
  ## `packageLiteral` emitted `pkg.toolUses & pkg.nativeBuildDeps &
  ## pkg.runtimeDeps` into the `toolUses:` slot, so a RUNTIME `PackageDef`'s
  ## `toolUses` meant something different from a MACRO-TIME one's: the same
  ## field name, two contents, one of them the union. §4.6 measured the
  ## consequence — "the platform distinction the recipe expressed is **erased
  ## before the solver ever sees it**".
  ##
  ## M9.R.5a and M9.R.53 widened that fold for a real reason: the convention
  ## layer's PATH builder needs the union, and recipes that declare a tool in
  ## `nativeBuildDeps:` or `runtimeDeps:` must still get it on PATH. So the
  ## union does not go away — it becomes EXPLICIT at each site that wants it,
  ## and the field stops lying about what it holds. Every call site that used
  ## to read the merged field now reads this, so the union is byte-identical
  ## wherever it was before and absent wherever it never should have been.
  ##
  ## The order is the concatenation order the merge used, and that is
  ## load-bearing rather than tidy: `buildPackageDevEnv` hashes this sequence
  ## into the implicit dev-env floor, and a reordering would move that hash
  ## for every package — a fingerprint change with no change behind it.
  pkg.toolUses & pkg.nativeBuildDeps & pkg.runtimeDeps

proc exposesDevEnvIntrospection*(pkg: PackageDef): bool =
  ## Windows-dev-env M1: a package exposes a ``gpkDevEnvIntrospection``
  ## entry point — so ``repro exec`` / ``repro shell`` / the direnv hook
  ## can resolve a dev environment — in either of two cases:
  ##
  ## * it declared an explicit ``devEnv:`` block (``hasDevEnv``), which
  ##   contributes shell ops / tasks / services / extra tool requirements
  ##   on top of the floor; OR
  ## * it declares a non-empty ``uses:`` toolchain floor (even with no
  ##   ``devEnv:`` block). The IMPLICIT dev-env is just the floor: the
  ##   PATH/env contributions of the ``uses:`` tools, with no extra tasks
  ##   or env. ``buildPackageDevEnv`` already appends ``pkg.toolUses`` to
  ##   the dev-env result's tool requirements for BOTH cases, so the
  ##   implicit case reuses the exact same derivation with an empty
  ##   "extra" dev-env body.
  pkg.hasDevEnv or pkg.allToolUses().len > 0

proc sharedServiceReplaceRefusal*(): string =
  ## §5.1's `replace` refusal, WRITTEN ONCE.
  ##
  ## Shared-Development-Services forbids a CONSUMER of a shared service
  ## the destructive operation, and that one judgement is enforced at
  ## THREE different stages, each of which has to refuse independently:
  ##
  ##   1. the consumer's COMPILE time, in the resolver macro
  ##      (`macros_b.nim`), where a `replace*(...)` head at a
  ##      `.shared(...)` argument is a compile error;
  ##   2. EVALUATION, in `resolveSharedService`
  ##      (`dsl_port_runtime.nim`), which is what catches a resolution
  ##      built by a path the macro did not write;
  ##   3. the owner's CONVERGE, in `validateServiceContributions`
  ##      (`repro_resources/service_registry.nim`), which is what catches
  ##      a row that reached the cross-process store some other way.
  ##
  ## ALL THREE STILL FIRE, and none of them is unreachable -- that was
  ## measured, and merging the CHECKS would be wrong because they run at
  ## three different times against three different inputs. What was
  ## duplicated was the JUDGEMENT: the citation, the reason and the
  ## remedy were typed out three times, in three different phrasings
  ## ("may not `replace` what the owner declared", "may `append` freely
  ## and may NOT `replace`", "may only `append`"), which is three copies
  ## of one sentence free to drift apart. The sibling undeclared-point
  ## refusal was already factored into a single helper
  ## (`refuseUndeclaredContribution`); this is the same move for its
  ## twin.
  ##
  ## NOT "ALREADY DRIFTED", AND THE DISTINCTION IS WORTH KEEPING
  ## STRAIGHT. `git log -S` on each of the three fragments, scoped to
  ## its own file, returns exactly ONE commit each -- the commit that
  ## introduced all three. They were born different rather than having
  ## diverged from a common sentence. The hazard is the same (three
  ## copies, three futures) but the history is not a drift and should
  ## not be cited as one.
  ##
  ## ONE COPY IS STILL OUTSIDE THIS HELPER, said here because a reader
  ## otherwise concludes the set is closed.
  ## `tests/dsl_port/t_dss11_resolver_surface_refuses_near_misses.nim`
  ## carries the hand-typed fragment "may not `replace` what the owner
  ## declared" as a `ResolverProbe.phrase`, and a one-word edit to the
  ## text below reddens it while the two in-process tests stay green
  ## (measured: 4 OK / 1 FAILED there, 26 OK / 0 and 21 OK / 0 for the
  ## other two). It cannot simply import this proc: it matches a
  ## substring of a COMPILER DIAGNOSTIC captured from a subprocess, not
  ## an exception message in this process. Closing that one needs the
  ## probe table to carry a phrase derived from here, which is a change
  ## to that file and was not made.
  ##
  ## IT IS THE SHARED PART ONLY. Each site prefixes its own SUBJECT (the
  ## key, the point, the contributing package, the call-site spelling)
  ## and appends its own STAGE-SPECIFIC consequence, because those
  ## genuinely differ: the macro can quote the author's own source line,
  ## and only the converge site can say that a stored `replace` would
  ## become the fold's base value.
  ##
  ## A `proc` rather than a `const`, and that is a STYLE choice, not a
  ## necessity -- do not read the earlier claim that a `const` would not
  ## work in the resolver macro's compile-time `error()`, because it was
  ## measured and it is false. A `const` whose value is a `&` chain of
  ## string literals is an ordinary compile-time value and reads
  ## identically from a macro body executed in the VM: converted to one,
  ## all three sites compile and all three covering tests stay green
  ## (26 OK / 0, 21 OK / 0, and 5 OK / 0 for the out-of-process macro
  ## probe that actually exercises `error()`). The `proc` is kept only
  ## because the file's other derived strings are procs. Either form is
  ## correct, and site 1 and sites 2-3 read the same bytes under both.
  "A CONSUMER of a shared service may `append` freely and " &
    "may not `replace` what the owner declared. " &
    "Shared-Development-Services.md §5.1: a consumer \"must be able to " &
    "`append` a relying party freely, and must NOT be able to " &
    "`replace` the relying-party collection or the issuer's hostname " &
    "... a consumer that could replace them would fork the instance it " &
    "is trying to join\". Who may use the destructive operation is " &
    "D-SS9 and it is still open, so this is refused rather than " &
    "decided. Write `append`, `appendOverride` or `appendForce` -- an " &
    "append at a high priority is authoritative and still not " &
    "destructive."
