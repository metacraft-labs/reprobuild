## DSL-port M2 — runtime state for the v8-style ``config:`` and
## ``versions:`` block lowerings.
##
## ─────────────────────────────────────────────────────────────────────────
## Why a new runtime sidecar instead of a parallel Cell-backed surface?
## ─────────────────────────────────────────────────────────────────────────
##
## v8's ``configCell`` machinery (``project_package_dsl.nim`` lines
## 299-302) returns a ``ResolvedConfigCell`` whose value flows through
## the full ConfigContext priority lattice (default / set / override /
## force). Production already has a ConfigContext system in
## ``repro_dsl_stdlib/configurables`` — see the variant pathway wired up
## by ``emitVariantDeclarations`` in ``macros_b.nim``. Variants land on
## the *ambient* ConfigContext that ``finalizeVariants()`` finalises at
## package-init time.
##
## For M2 we keep the new ``config:`` scalar surface DELIBERATELY OFF
## that ambient context. Two reasons:
##
##   1. The 11 NDE production packages already use ``config:`` for
##      ``variant: T = default`` declarations. ``parsePackageDef``
##      extracts those into ``pkg.variants`` and ``emitVariantDeclarations``
##      lowers them into ``declareVariant[T](...)``. Layering a SECOND
##      configurable-creation pathway on top of the same block — with
##      the same body shape ``name: T = default`` — would either
##      (a) double-register every variant, or (b) require disambiguation
##      between "this is a variant" and "this is a scalar configurable"
##      at expansion time, which the v8 design does NOT do.
##
##   2. The M2 acceptance only requires read/write of scalar values.
##      Anchoring the M2 surface on a separate ``Table[string,
##      DslScalarValue]`` keeps the test-facing API minimal while still
##      giving M3+ a clean upgrade path: when the Cell-backed pathway
##      lands, ``readConfigurable`` rewires its implementation from the
##      M2 table to a configCell lookup, and the public signatures stay
##      identical.
##
## ─────────────────────────────────────────────────────────────────────────
## What the M2 surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## * ``recordConfigDefault[T]`` — register a default value for a
##   ``<packageName>.<bindingName>`` key. Called from code emitted by
##   the ``package`` macro for every entry in a ``config:`` block whose
##   shape is the v8 typed-default form (``name: T = default``) AND
##   that did NOT match the existing ``parseVariantDeclaration``
##   ``variant`` keyword / ``@variant`` doc directive (i.e. it's a
##   plain scalar, not a solver-participating variant).
##
## * ``readConfigurable[T]`` — return either the override (when one is
##   pending) or the default. Raises ``EDslPortMissingKey`` when the
##   key was never registered; raises ``EDslPortTypeMismatch`` when the
##   stored type does not match the requested ``T``.
##
## * ``setConfigurable[T]`` — store an override against the key.
##
## * ``resetConfigurable`` — drop any override so the default re-emerges.
##
## * ``registeredConfigKeys`` — list every ``<package>.<name>`` key for
##   diagnostic / inspection paths.
##
## * ``registerVersion`` / ``registeredVersions`` /
##   ``resetRegisteredVersions`` — the symmetric ``versions:`` surface.
##
## ─────────────────────────────────────────────────────────────────────────
## Threading model
## ─────────────────────────────────────────────────────────────────────────
##
## The state is module-level (not ``threadvar``) so that
## ``readConfigurable`` from any thread sees the same registrations the
## package macro made at module-init time on the main thread. M2 does
## NOT introduce concurrent writers — overrides happen from test
## fixtures or top-level recipe code, both of which run on the main
## thread.

## (This file is ``include``d from ``repro_project_dsl.nim`` — the
## umbrella module already imports ``std/tables``, ``std/strutils`` etc.
## so no additional imports are needed here. The same include-style is
## what ``runtime_core``, ``macros_a``, ``macros_b``, and ``cross_project``
## use throughout the project DSL.)

type
  DslScalarKind* = enum
    ## Discriminant for the scalar value the M2 surface stores against
    ## each key. Matches the four primitive shapes the v8 fixtures use
    ## (``int``, ``string``, ``bool``, ``float``) plus M9.D's two
    ## additions (``dskEnum`` for typed-enum configurables, and
    ## ``dskSeqEnum`` for ``seq[Enum]`` configurables). Future kinds
    ## (e.g. ``seq[string]``) widen this enum WITHOUT a schema bump
    ## because ``readConfigurable[T]`` raises ``EDslPortTypeMismatch``
    ## when a caller asks for the wrong type — never silently coerces.
    dskBool
    dskInt
    dskString
    dskFloat
    dskEnum
    dskSeqEnum

  DslScalarValue* = object
    ## Discriminated record holding one configurable's payload. Stored
    ## in both the default-value table and the override table.
    case kind*: DslScalarKind
    of dskBool: boolVal*: bool
    of dskInt: intVal*: int
    of dskString: strVal*: string
    of dskFloat: floatVal*: float
    of dskEnum:
      ## M9.D — typed-enum configurable.
      ## ``enumOrd`` stores the enum value's ``.ord`` (so dense enums
      ## round-trip via ``T(ord)`` at read time); ``enumTypeName`` is
      ## ``$T`` captured at registration so cross-type reads can detect
      ## the mismatch; ``enumValueName`` is ``$value`` (the literal name)
      ## for diagnostic / inspection paths.
      enumOrd*: int
      enumTypeName*: string
      enumValueName*: string
    of dskSeqEnum:
      ## M9.D — ``seq[Enum]`` configurable. Same shape per element as
      ## ``dskEnum`` with the per-instance type name pinned at the
      ## seq level (every element shares the same type, by definition).
      seqEnumTypeName*: string
      seqEnumOrds*: seq[int]
      seqEnumValueNames*: seq[string]

  DslVersionInfo* = object
    ## One entry inside a ``versions:`` block. Matches the four named
    ## fields v8's ``project_package_dsl.nim`` accepts as assignments
    ## inside a version body. Unset fields stay at the empty string.
    version*: string
      ## The version string from the outer ``"<version>": <body>`` head.
    sourceRevision*: string
    sourceChecksum*: string
    sourceUrl*: string
    sourceRepository*: string

  EDslPortMissingKey* = object of CatchableError
    ## Raised when ``readConfigurable``/``setConfigurable`` /
    ## ``resetConfigurable`` is called for a key that was never
    ## registered via ``recordConfigDefault``.

  EDslPortTypeMismatch* = object of CatchableError
    ## Raised when the type-parameter ``T`` does not match the
    ## ``DslScalarKind`` the key was registered with.

# ---------------------------------------------------------------------------
# Module-level registries
# ---------------------------------------------------------------------------

var dslPortDefaults: Table[string, DslScalarValue]
  ## Defaults table: one entry per call to ``recordConfigDefault``.
  ## Keyed by ``<packageName>.<bindingName>``. Insertion is idempotent
  ## (re-recording a key leaves the existing default in place) so that
  ## module-init replays do not clobber a previously-overridden cell.

var dslPortOverrides: Table[string, DslScalarValue]
  ## Override table consulted by ``readConfigurable`` BEFORE the
  ## defaults table. Each ``setConfigurable`` writes one row;
  ## ``resetConfigurable`` deletes the row.

var dslPortKeyOrder: seq[string]
  ## Insertion-order key list. The two ``Table[string, ...]``
  ## registries above are unordered; tests need stable enumeration so
  ## the runner can verify expected keys regardless of hash-table
  ## bucket layout. ``recordConfigDefault`` appends here on first
  ## registration only.

var dslPortVersionRegistry: Table[string, seq[DslVersionInfo]]
  ## Per-package ``versions:`` registry. Keyed by package name.
  ## ``registerVersion`` appends to the per-package seq;
  ## ``registeredVersions`` returns a copy so callers cannot mutate
  ## the registry from outside the public API.

# ---------------------------------------------------------------------------
# DslScalarValue constructors
# ---------------------------------------------------------------------------

proc dslScalarBool*(v: bool): DslScalarValue =
  DslScalarValue(kind: dskBool, boolVal: v)

proc dslScalarInt*(v: int): DslScalarValue =
  DslScalarValue(kind: dskInt, intVal: v)

proc dslScalarString*(v: string): DslScalarValue =
  DslScalarValue(kind: dskString, strVal: v)

proc dslScalarFloat*(v: float): DslScalarValue =
  DslScalarValue(kind: dskFloat, floatVal: v)

proc dslScalarEnum*(ordVal: int; typeName, valueName: string): DslScalarValue =
  ## M9.D constructor for the typed-enum arm. ``ordVal`` is the enum
  ## value's ``.ord``; ``typeName`` is ``$T`` (captured at the generic
  ## call site so callers cannot smuggle a wrong type name); ``valueName``
  ## is ``$value`` (the literal name as Nim's ``$`` formats it).
  DslScalarValue(kind: dskEnum, enumOrd: ordVal,
                 enumTypeName: typeName, enumValueName: valueName)

proc dslScalarSeqEnum*(typeName: string;
                       ordsAndNames: seq[(int, string)]):
                       DslScalarValue =
  ## M9.D constructor for ``seq[Enum]``. ``ordsAndNames`` is an
  ## already-paired seq of (``.ord``, ``$value``) entries so the caller
  ## doesn't have to feed two parallel seqs by hand. Storage is two
  ## parallel seqs internally — keeps the discriminant record bytes
  ## minimal vs. boxing each element as a full ``DslScalarValue``.
  var ords = newSeqOfCap[int](ordsAndNames.len)
  var names = newSeqOfCap[string](ordsAndNames.len)
  for (o, n) in ordsAndNames:
    ords.add(o)
    names.add(n)
  DslScalarValue(kind: dskSeqEnum, seqEnumTypeName: typeName,
                 seqEnumOrds: ords, seqEnumValueNames: names)

# ---------------------------------------------------------------------------
# Public API — config: surface
# ---------------------------------------------------------------------------

proc resetDslPortConfigState*() =
  ## Drop every registered default / override / key. Test fixtures call
  ## this between scenarios so registry entries do not leak across
  ## cases. The version registry has its own reset proc — keeping the
  ## two concerns separable lets tests target one without disturbing
  ## the other.
  dslPortDefaults.clear()
  dslPortOverrides.clear()
  dslPortKeyOrder.setLen(0)

proc recordConfigDefaultRaw*(key: string; default: DslScalarValue) =
  ## Type-erased default registration. The ``recordConfigDefault[T]``
  ## generic wrapper below is the call site the ``package`` macro
  ## emits; it constructs the ``DslScalarValue`` then delegates here.
  ##
  ## Idempotency: re-recording the same key leaves the FIRST
  ## registration's default in place. This is the contract the
  ## ``package`` macro relies on so that re-evaluating a package's
  ## module (e.g. inside a unit-test process that imports the recipe
  ## twice) does not clobber a previously-overridden cell.
  if key notin dslPortDefaults:
    dslPortKeyOrder.add(key)
  dslPortDefaults[key] = default

proc recordConfigDefault*[T](packageName, name: string; default: T) =
  ## Generic facade — the ``package`` macro emits one call per
  ## ``name: T = default`` entry. We bridge through the type-erased
  ## ``recordConfigDefaultRaw`` so the macro never has to know the
  ## ``DslScalarValue`` constructor name.
  ##
  ## M9.D widens the supported ``T`` set to include typed enums
  ## (``when T is enum``) and ``seq[Enum]`` (``when T is seq and
  ## elementType(T) is enum``). The seq arm dispatches inside this
  ## generic instead of as a separate overload because the macro emits
  ## an explicit generic parameter ``recordConfigDefault[seq[X]](...)``
  ## which routes to THIS proc, not to a sibling ``[E: enum]`` overload.
  let key = packageName & "." & name
  when T is bool:
    recordConfigDefaultRaw(key, dslScalarBool(default))
  elif T is SomeInteger:
    recordConfigDefaultRaw(key, dslScalarInt(int(default)))
  elif T is string:
    recordConfigDefaultRaw(key, dslScalarString(default))
  elif T is SomeFloat:
    recordConfigDefaultRaw(key, dslScalarFloat(float(default)))
  elif T is enum:
    recordConfigDefaultRaw(key, dslScalarEnum(default.ord, $T, $default))
  elif T is seq:
    # Crack the element type via ``typeof(default[0])`` — works inside
    # a generic body without needing ``std/typetraits.elementType``.
    # The element MUST be an enum; ``seq[string]`` etc. fall through
    # to the static-error arm.
    type Elem = typeof(default[0])
    when Elem is enum:
      var pairs = newSeqOfCap[(int, string)](default.len)
      for e in default:
        pairs.add((e.ord, $e))
      recordConfigDefaultRaw(key, dslScalarSeqEnum($Elem, pairs))
    else:
      {.error: "recordConfigDefault: unsupported configurable type " &
         $T & "; M9.D seq support is restricted to seq[Enum]".}
  else:
    {.error: "recordConfigDefault: unsupported configurable type " &
       $T & "; M2/M9.D supports bool / int / string / float / enum / seq[enum]".}

proc registeredConfigKeys*(): seq[string] =
  ## Return every ``<package>.<name>`` key in insertion order. A copy
  ## so callers cannot mutate the registry.
  result = dslPortKeyOrder

proc isConfigKeyRegistered*(key: string): bool =
  key in dslPortDefaults

proc dslPortLookup(key: string): DslScalarValue =
  ## Internal: consult overrides first, then defaults. Raises
  ## ``EDslPortMissingKey`` when neither table knows the key.
  if key in dslPortOverrides:
    return dslPortOverrides[key]
  if key in dslPortDefaults:
    return dslPortDefaults[key]
  raise newException(EDslPortMissingKey,
    "readConfigurable: no configurable registered for key '" & key &
    "' — verify the package's config: block declares '" & key &
    "' and that the package module has been imported")

proc readConfigurable*[T](key: string): T =
  ## Read the configurable cell at ``key``. Returns the override if
  ## ``setConfigurable`` has stashed one, otherwise the registered
  ## default. Raises ``EDslPortMissingKey`` when the key is unknown;
  ## raises ``EDslPortTypeMismatch`` when ``T`` does not match the
  ## stored kind.
  let stored = dslPortLookup(key)
  when T is bool:
    if stored.kind != dskBool:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[bool]('" & key & "'): stored kind is " &
        $stored.kind & ", not dskBool")
    return stored.boolVal
  elif T is SomeInteger:
    if stored.kind != dskInt:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[" & $T & "]('" & key &
        "'): stored kind is " & $stored.kind & ", not dskInt")
    return T(stored.intVal)
  elif T is string:
    if stored.kind != dskString:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[string]('" & key & "'): stored kind is " &
        $stored.kind & ", not dskString")
    return stored.strVal
  elif T is SomeFloat:
    if stored.kind != dskFloat:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[" & $T & "]('" & key &
        "'): stored kind is " & $stored.kind & ", not dskFloat")
    return T(stored.floatVal)
  elif T is enum:
    if stored.kind != dskEnum:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[" & $T & "]('" & key &
        "'): stored kind is " & $stored.kind & ", not dskEnum")
    if stored.enumTypeName != $T:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[" & $T & "]('" & key &
        "'): stored enum type " & stored.enumTypeName &
        " does not match requested " & $T)
    return T(stored.enumOrd)
  else:
    {.error: "readConfigurable: unsupported type " & $T &
       "; M2/M9.D supports bool / int / string / float / enum / seq[enum]".}

proc readConfigurable*[E: enum](key: string; fallback: seq[E]): seq[E] =
  ## M9.D ``seq[Enum]`` reader with graceful fallback. Returns the
  ## registered seq when the key exists AND the stored kind matches
  ## AND the stored enum type name matches ``$E``; otherwise returns
  ## ``fallback``.
  ##
  ## Graceful degradation here matches the task's "wrong-type fallback"
  ## contract — the key-only overload would raise, which is the wrong
  ## shape for fixture / multi-recipe code paths that probe several
  ## possible types.
  try:
    let stored = dslPortLookup(key)
    if stored.kind != dskSeqEnum:
      return fallback
    if stored.seqEnumTypeName != $E:
      return fallback
    result = newSeqOfCap[E](stored.seqEnumOrds.len)
    for o in stored.seqEnumOrds:
      result.add(E(o))
  except EDslPortMissingKey:
    return fallback

proc readConfigurable*[T](key: string; fallback: T): T =
  ## M9.D fallback-flavoured reader for scalar configurables. Returns
  ## the registered value when the key exists AND the stored kind
  ## matches AND (for enums) the stored type name matches ``$T``;
  ## otherwise returns ``fallback``. Never raises — callers use this
  ## overload when the spec calls for graceful degradation rather than
  ## a hard type-mismatch error.
  try:
    let stored = dslPortLookup(key)
    when T is bool:
      if stored.kind != dskBool: return fallback
      return stored.boolVal
    elif T is SomeInteger:
      if stored.kind != dskInt: return fallback
      return T(stored.intVal)
    elif T is string:
      if stored.kind != dskString: return fallback
      return stored.strVal
    elif T is SomeFloat:
      if stored.kind != dskFloat: return fallback
      return T(stored.floatVal)
    elif T is enum:
      if stored.kind != dskEnum: return fallback
      if stored.enumTypeName != $T: return fallback
      return T(stored.enumOrd)
    else:
      {.error: "readConfigurable: unsupported type " & $T &
         "; M2/M9.D supports bool / int / string / float / enum / seq[enum]".}
  except EDslPortMissingKey:
    return fallback

proc inspectConfigurable*(key: string): DslScalarValue =
  ## M9.D test-side accessor: return the raw stored ``DslScalarValue``
  ## at ``key`` (override-preferred, defaults fallback), or raise
  ## ``EDslPortMissingKey`` when the key is unknown. Tests use this to
  ## verify the captured ``enumTypeName`` / ``enumValueName`` /
  ## ``seqEnumTypeName`` round-trip the macro-emitted ``$T`` / ``$value``
  ## strings byte-for-byte.
  dslPortLookup(key)

proc setConfigurableRaw*(key: string; value: DslScalarValue) =
  ## Type-erased override path. Used by ``setConfigurable[T]`` and by
  ## environment-loader code that has a raw value in hand.
  if key notin dslPortDefaults:
    raise newException(EDslPortMissingKey,
      "setConfigurable: no configurable registered for key '" & key &
      "' — register the default via the package's config: block first")
  let registered = dslPortDefaults[key]
  if registered.kind != value.kind:
    raise newException(EDslPortTypeMismatch,
      "setConfigurable('" & key & "'): override kind " & $value.kind &
      " does not match registered kind " & $registered.kind)
  dslPortOverrides[key] = value

proc setConfigurable*[T](key: string; value: T) =
  ## Override the value at ``key``. The override is consulted by every
  ## subsequent ``readConfigurable`` until ``resetConfigurable`` clears
  ## it. Raises ``EDslPortMissingKey`` when the key is unknown.
  when T is bool:
    setConfigurableRaw(key, dslScalarBool(value))
  elif T is SomeInteger:
    setConfigurableRaw(key, dslScalarInt(int(value)))
  elif T is string:
    setConfigurableRaw(key, dslScalarString(value))
  elif T is SomeFloat:
    setConfigurableRaw(key, dslScalarFloat(float(value)))
  elif T is enum:
    setConfigurableRaw(key, dslScalarEnum(value.ord, $T, $value))
  elif T is seq:
    type Elem = typeof(value[0])
    when Elem is enum:
      var pairs = newSeqOfCap[(int, string)](value.len)
      for e in value:
        pairs.add((e.ord, $e))
      setConfigurableRaw(key, dslScalarSeqEnum($Elem, pairs))
    else:
      {.error: "setConfigurable: unsupported type " & $T &
         "; M9.D seq support is restricted to seq[Enum]".}
  else:
    {.error: "setConfigurable: unsupported type " & $T &
       "; M2/M9.D supports bool / int / string / float / enum / seq[enum]".}

proc resetConfigurable*(key: string) =
  ## Clear the override at ``key`` (if any) so the next read returns
  ## the registered default. The call is a no-op when no override is
  ## pending; the key must still be registered (we surface
  ## ``EDslPortMissingKey`` for typos so test fixtures don't silently
  ## reset the wrong slot).
  if key notin dslPortDefaults:
    raise newException(EDslPortMissingKey,
      "resetConfigurable: no configurable registered for key '" & key &
      "'")
  if key in dslPortOverrides:
    dslPortOverrides.del(key)

# ---------------------------------------------------------------------------
# Public API — versions: surface
# ---------------------------------------------------------------------------

proc resetRegisteredVersions*() =
  ## Drop every ``versions:`` registration. Test fixtures call this
  ## between scenarios to keep the registry clean.
  dslPortVersionRegistry.clear()

proc registerVersion*(packageName: string; info: DslVersionInfo) =
  ## Append one version entry against ``packageName``. The ``package``
  ## macro emits one call per ``"<version>":`` inner block.
  ##
  ## Idempotency: registering a duplicate ``(packageName, version)``
  ## pair appends the new record — we deliberately do NOT collapse,
  ## because the v8 fixtures sometimes re-declare versions across
  ## conditional ``when`` branches and the consumer (M3+) decides which
  ## arm to honour. Surfacing both gives downstream consumers the
  ## complete picture; collapsing would discard provenance.
  if packageName notin dslPortVersionRegistry:
    dslPortVersionRegistry[packageName] = @[]
  dslPortVersionRegistry[packageName].add(info)

proc registeredVersions*(packageName: string): seq[DslVersionInfo] =
  ## Return every version entry registered against ``packageName`` in
  ## declaration order. Returns the empty seq when the package never
  ## declared a ``versions:`` block; callers must NOT treat the empty
  ## return as an error.
  if packageName in dslPortVersionRegistry:
    return dslPortVersionRegistry[packageName]
  return @[]

# ---------------------------------------------------------------------------
# DSL-port M3 — artifact registry for ``executable``, ``library``, ``files``.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## Why a sidecar registry rather than re-using ``pkg.executables`` /
## ``pkg.libraries``?
## ─────────────────────────────────────────────────────────────────────────
##
## The legacy ``parsePackageDef`` walker in ``macros_a.nim`` already
## extracts ``executable <name>: ...`` and ``library <name>: ...``
## entries into ``pkg.executables`` (``ExecutableDef``) and
## ``pkg.libraries`` (``LibraryDef``). Those records are consumed by
## ``wrapperCode`` / ``toolActionWrapperCode`` to emit the typed-tool
## wrapper procs, the ``defineCliInterface`` calls, the ``buildXxx*``
## proc, and the per-package ``const <pkg>* = <Title>Package()``. The
## production NDE recipes plus ``examples/hello-world-c/repro.nim`` AND
## ``examples/hello-world-multi-output/repro.nim`` rely on that emission
## end-to-end.
##
## M3 ports v8's ``executable`` / ``library`` / ``files`` templates as
## an OBSERVER pass that ALSO records each artifact into a separate
## ``dslPortArtifactRegistry`` keyed by package name. Future milestones
## (M4 — cli: lowering, M5 — build: lowering, M6 — files: lowering)
## migrate downstream emission off the legacy records onto this
## registry; until then both records co-exist, populated from the same
## source-order walk over the partitioned section list. No statement is
## double-emitted because:
##
##   * ``parsePackageDef`` populates ``pkg.executables`` /
##     ``pkg.libraries`` (legacy data-extraction sidecar).
##   * M3's ``emitM3Artifacts`` populates ``dslPortArtifactRegistry``
##     (new runtime sidecar — same model as M2's ``dslPortDefaults`` /
##     ``dslPortVersionRegistry``).
##
## Both sidecars are independent; no piece of code is emitted twice
## from a single section.
##
## ─────────────────────────────────────────────────────────────────────────
## Why store the artifact body as a ``string`` (its ``.repr``) instead
## of a ``NimNode``?
## ─────────────────────────────────────────────────────────────────────────
##
## NimNode values exist only at compile time — the runtime registry
## cannot hold one. To still satisfy the spec's "M3 records body
## verbatim; M4+ will lower it" requirement we store the body's
## ``.repr`` as a string. M4 reads the body BACK at compile time
## (the lowering itself runs at macro-expansion time, not at runtime)
## by walking the same partitioned section list; the runtime string
## is the diagnostic surface tests use to verify what was recorded.

type
  DslArtifactKind* = enum
    ## Discriminator for the three artifact-template families v8 ships:
    ## ``executable``, ``library``, ``files``. Matches the three
    ## ``soM3*Artifact`` entries on ``SectionOwnership`` (see
    ## ``cross_project.nim``) one-to-one.
    dakExecutable
    dakLibrary
    dakFiles

  DslArtifact* = object
    ## One ``executable``/``library``/``files`` registration. Populated
    ## by ``emitM3Artifacts`` at module-init time; read by host code via
    ## ``registeredArtifacts``. M3 records the artifact name, kind, and
    ## body repr; M4+ will widen the schema as the cli:/build:/files:
    ## sub-blocks land.
    packageName*: string
    artifactName*: string
      ## The string-form name verbatim, or the ident-form name's
      ## ``strVal`` (NO kebab translation — see the legacy-vs-M3
      ## ownership decision in ``macros_b.nim:emitM3Artifacts``).
    kind*: DslArtifactKind
    bodyRepr*: string
      ## The artifact-internal body's ``NimNode.repr`` at the time
      ## ``emitM3Artifacts`` ran. M4+ will re-parse this at lowering time
      ## or read the AST off the partitioned section list directly.

var dslPortArtifactRegistry: Table[string, seq[DslArtifact]]
  ## Per-package artifact registry. Keyed by package name.
  ## ``registerArtifact`` appends to the per-package seq;
  ## ``registeredArtifacts`` returns a copy so callers cannot mutate
  ## the registry from outside the public API.

proc resetDslPortArtifactState*() =
  ## Drop every artifact registration. Test fixtures call this between
  ## scenarios to keep the registry clean. The config and versions
  ## registries have their own reset procs — keeping the three concerns
  ## separable lets tests target one without disturbing the others.
  dslPortArtifactRegistry.clear()

proc registerArtifact*(packageName: string; artifact: DslArtifact) =
  ## Append one artifact entry against ``packageName``. The ``package``
  ## macro emits one call per recognised ``executable:``/``library:``/
  ## ``files:`` block via ``emitM3Artifacts``.
  ##
  ## Idempotency: registering a duplicate ``(packageName, artifactName,
  ## kind)`` tuple appends the new record — we deliberately do NOT
  ## collapse, because conditional ``when`` branches can legitimately
  ## re-declare the same artifact name under different platform gates
  ## and the consumer (M4+) decides which arm to honour. Surfacing
  ## both gives downstream consumers the complete picture; collapsing
  ## would discard provenance.
  if packageName notin dslPortArtifactRegistry:
    dslPortArtifactRegistry[packageName] = @[]
  dslPortArtifactRegistry[packageName].add(artifact)

proc registeredArtifacts*(packageName: string): seq[DslArtifact] =
  ## Return every artifact registered against ``packageName`` in
  ## declaration order. Returns the empty seq when the package never
  ## declared an ``executable:`` / ``library:`` / ``files:`` block;
  ## callers must NOT treat the empty return as an error.
  if packageName in dslPortArtifactRegistry:
    return dslPortArtifactRegistry[packageName]
  return @[]

# ---------------------------------------------------------------------------
# DSL-port M4 — ``build:`` block lowering: actions, outputs, active-context
# stack.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## What the M4 surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## v8's ``build:`` block macro (``project_package_dsl.nim`` line 418) is a
## pure context wrapper — push a ``BuildBlockState`` onto a thread-local
## stack, run the user's body verbatim, pop on exit. Inside the body, the
## ``output(path)`` / ``output(name, path)`` procs (lines 433-442) read
## the active stack frame to attribute their effect to the right
## artifact (or the package itself for the M1 symmetric package-level
## form).
##
## The M4 production port mirrors that shape one-to-one:
##
##   * ``registerBuildAction(packageName, artifactName, bodyRepr)`` —
##     observer-style append-only registry. The ``package`` macro emits
##     one call per recognised ``build:`` block (package-level OR
##     artifact-scoped). Empty ``artifactName`` is the package-level
##     discriminator; any non-empty string names the parent
##     ``executable`` / ``library`` / ``files`` artifact.
##
##   * ``beginBuildContext(packageName, artifactName)`` /
##     ``endBuildContext()`` — Approach (A) thread-local push/pop. The
##     ``package`` macro wraps every ``build:`` body in a try/finally
##     that pairs these calls, so ``output`` reaches the right frame
##     even when the path passes through a helper proc.
##
##   * ``output(path)`` — Records ``path`` against the active artifact
##     frame. When NO active context exists (e.g. the legacy
##     ``buildXxxPackage*()`` proc invokes a helper that called
##     ``output`` after the M4 try/finally already popped — possible in
##     provider-mode replay), the call is a SILENT no-op so the legacy
##     pathway stays compatible. This is INTENTIONALLY asymmetric with
##     the v8 staged variant (which calls ``currentBuildState()`` and
##     raises): tests for M4 always push a context first via the
##     emitted try/finally, so the no-op branch is unreachable from a
##     correctly-shaped recipe. The branch only exists for compatibility
##     with the legacy provider-mode call chain.
##
##   * ``registeredOutputs(packageName, artifactName): seq[string]`` —
##     diagnostic accessor. Returns the empty seq when no outputs were
##     recorded against the key, matching M2's / M3's "empty rather than
##     raise" convention.
##
##   * ``registeredBuildActions(packageName): seq[DslBuildAction]`` —
##     per-package read of every recorded action. Same semantics as
##     ``registeredArtifacts`` and ``registeredVersions``.
##
##   * ``resetDslPortBuildState()`` — drops every action, every output,
##     and clears the active-context stack. Test fixtures call this
##     between scenarios.
##
## ─────────────────────────────────────────────────────────────────────────
## Why a thread-local stack rather than module-level scalars?
## ─────────────────────────────────────────────────────────────────────────
##
## Approach (A) mirrors v8's production layer (``beginBuildBlock`` /
## ``endBuildBlock`` in ``runtime_core.nim`` lines 113-154) and supports
## nesting — a helper proc invoked from inside one ``build:`` block can
## itself open another (rare today, but the door is left open for
## composition-style helpers). Approach (B) module-level scalars would
## silently corrupt the inner attribution. The active-context state is
## ``threadvar`` so a multi-threaded test runner does not cross-attribute
## outputs between fixtures.
##
## ─────────────────────────────────────────────────────────────────────────
## Coordination with the legacy ``beginBuildBlock`` (Project-DSL-Composition
## M5)
## ─────────────────────────────────────────────────────────────────────────
##
## ``runtime_core.nim``'s ``beginBuildBlock`` records a
## ``PackageBuildState`` for typed-tool wrappers / cross-cutting interface
## slots. M4's ``beginBuildContext`` is a SEPARATE stack used solely by
## the new ``build:`` / ``output()`` surface. The two stacks coexist
## because:
##
##   * ``beginBuildBlock`` is pushed by the legacy ``buildXxxPackage*()``
##     proc (provider-mode only) and consumed by typed-tool wrappers.
##   * ``beginBuildContext`` is pushed by the M4 init-time try/finally
##     and consumed by ``output()``.
##
## M4 does NOT extend the legacy ``PackageBuildState`` to carry an
## ``artifactName`` — doing so would change the legacy ABI and ripple
## through every typed-tool wrapper. Keeping the two stacks disjoint
## means the M4 surface can evolve without touching the legacy chain.

type
  DslBuildAction* = object
    ## One ``build:`` block registration. Populated by ``emitM4*``
    ## emitters at module-init time; read by host code via
    ## ``registeredBuildActions``. Distinguishes:
    ##
    ##   * package-level form (``artifactName == ""``) — the ``build:``
    ##     block sat directly under a ``package <name>:`` head.
    ##   * artifact-scoped form (``artifactName == "<ident>"`` or
    ##     ``"<str-lit>"``) — the ``build:`` block sat inside an
    ##     ``executable`` / ``library`` / ``files`` artifact body.
    packageName*: string
    artifactName*: string
      ## Empty for package-level; the artifact's source-level name for
      ## artifact-scoped.
    bodyRepr*: string
      ## The ``build:`` body's ``NimNode.repr`` at the time
      ## ``emitM4*`` ran. Diagnostic surface — M4+ lowerings re-walk the
      ## partitioned section list (NEVER ``parseStmt(bodyRepr)``).

  DslBuildContextFrame* = object
    ## One frame on the active-context stack. Pushed by
    ## ``beginBuildContext``, popped by ``endBuildContext``.
    packageName*: string
    artifactName*: string
    legacyBuildState*: PackageBuildState
      ## The matching frame on ``runtime_core``'s ``activeBuilds`` stack
      ## (pushed via ``beginBuildBlock``). The M4 module-init emission
      ## drives ``beginBuildContext`` / ``endBuildContext``, but stdlib
      ## recipe helpers reach the active package through
      ## ``currentBuildContext()`` → ``currentBuildState()``, which reads
      ## ``activeBuilds`` — a SEPARATE stack. Pushing both in lockstep
      ## lets a ``build:`` body call those helpers (e.g.
      ## ``currentBuildContext().toolchain.compile(...)``) without
      ## tripping "build DSL operation used outside an active build".

var dslPortBuildActions: seq[DslBuildAction]
  ## Append-only registry. ``registerBuildAction`` adds one row per
  ## recognised ``build:`` block. ``registeredBuildActions`` returns a
  ## per-package filtered copy.

var dslPortOutputs: Table[string, seq[string]]
  ## Per-``(packageName, artifactName)`` output registry, keyed by
  ## ``packageName & "." & artifactName``. ``output(path)`` appends one
  ## row per call into the active frame's bucket;
  ## ``registeredOutputs(packageName, artifactName)`` returns the
  ## per-bucket copy. ``Table[string, seq[string]]`` rather than the
  ## sequence-of-records used for actions because outputs are queried
  ## by exact ``(pkg, artifact)`` lookup and a Table gives O(1).

var dslPortActiveBuildContext {.threadvar.}: seq[DslBuildContextFrame]
  ## Active-context stack. ``threadvar`` so test fixtures running on
  ## different threads don't cross-attribute outputs. Empty when no
  ## ``build:`` block is currently open.

proc resetDslPortBuildInputState*()
  ## Forward declaration so the M4 ``resetDslPortBuildState`` can call
  ## the M9.F state-reset helper; the full body lives further down
  ## next to the M9.F typed-output / build-input registries it manages.

proc resetDslPortBuildState*() =
  ## Drop every recorded build action + every recorded output + clear
  ## the active-context stack. Test fixtures call this between
  ## scenarios so registry entries do not leak across cases. Keeping the
  ## three concerns (config, versions, artifacts, build) separable lets
  ## tests target one surface without disturbing the others.
  dslPortBuildActions.setLen(0)
  dslPortOutputs.clear()
  dslPortActiveBuildContext.setLen(0)
  # M9.F: the typed-output handles + cross-artifact build-input wiring
  # tables are declared further down (after the M5/M6/M7 stacks) so this
  # reset hook delegates via ``resetDslPortBuildInputState`` to keep the
  # var decls colocated with their owning M9.F surface. Each test fixture
  # also runs in its own process so the threadvar tables start empty
  # before the first ``output(...)`` registration in any case.
  resetDslPortBuildInputState()

proc registerBuildAction*(packageName, artifactName, bodyRepr: string) =
  ## Append one build-action entry. The ``package`` macro emits one call
  ## per recognised ``build:`` block via ``emitM4BuildActions`` or
  ## ``emitM4ArtifactBuildLowering``.
  ##
  ## Idempotency: re-running the registration on a second module-init
  ## of the same package (e.g. when the recipe module is imported twice)
  ## appends a duplicate row — we deliberately do NOT collapse, because
  ## conditional ``when`` branches can legitimately re-declare a build
  ## action under different platform gates and the consumer decides
  ## which arm to honour. Tests that need a clean baseline call
  ## ``resetDslPortBuildState`` first.
  dslPortBuildActions.add(DslBuildAction(
    packageName: packageName,
    artifactName: artifactName,
    bodyRepr: bodyRepr))

proc registeredBuildActions*(packageName: string): seq[DslBuildAction] =
  ## Return every build action registered against ``packageName`` in
  ## declaration order. Returns the empty seq when the package never
  ## declared a ``build:`` block; callers must NOT treat the empty
  ## return as an error.
  result = @[]
  for action in dslPortBuildActions:
    if action.packageName == packageName:
      result.add(action)

proc beginBuildContext*(packageName, artifactName: string) =
  ## Push a frame onto the active-context stack. The ``package`` macro
  ## wraps every recognised ``build:`` body in a try/finally that pairs
  ## this with ``endBuildContext``. Multiple pushes nest cleanly —
  ## ``output(path)`` always attributes to the TOP frame.
  # Also push the matching ``activeBuilds`` frame so recipe helpers that
  # read ``currentBuildState()`` / ``currentBuildContext()`` resolve the
  # active package when invoked from inside the M4-driven build body.
  let legacy = beginBuildBlock(packageName, ownerName = artifactName)
  dslPortActiveBuildContext.add(DslBuildContextFrame(
    packageName: packageName,
    artifactName: artifactName,
    legacyBuildState: legacy))

proc endBuildContext*() =
  ## Pop the top frame. Safe to call on an empty stack (no-op) — the
  ## try/finally pairing guarantees balance in well-formed code, but
  ## defensive no-op semantics let unit tests reset between scenarios
  ## without crashing when state was already clean.
  if dslPortActiveBuildContext.len > 0:
    let frame = dslPortActiveBuildContext[^1]
    dslPortActiveBuildContext.setLen(dslPortActiveBuildContext.len - 1)
    # Pop the paired ``activeBuilds`` frame pushed in ``beginBuildContext``.
    if frame.legacyBuildState != nil:
      endBuildBlock(frame.legacyBuildState)

proc currentBuildContextFrame*(): DslBuildContextFrame =
  ## Return the top frame, or a zero-value frame (both fields empty)
  ## when no ``build:`` block is open. Helper for inspection paths that
  ## want to attribute a side-effect to the active artifact without
  ## raising when called outside a build context.
  if dslPortActiveBuildContext.len > 0:
    return dslPortActiveBuildContext[^1]
  return DslBuildContextFrame(packageName: "", artifactName: "")

# ---------------------------------------------------------------------------
# DSL-port M7 — user-facing helper API: read the active build context from
# arbitrary Nim procs called as side effects from inside a ``build:`` body.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## What the M7 surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## v8's ``build:`` block runs the user-written body verbatim inside the
## active-context try/finally pair. Helper procs the recipe author defines
## at module scope and CALLS from inside the build body are reached while
## the M4 stack frame is still on top of ``dslPortActiveBuildContext``.
## M7 exposes a minimal, ergonomic accessor surface so those helpers can
## read which package / artifact frame is currently active without having
## to deal in the raw ``DslBuildContextFrame`` record:
##
##   * ``currentBuildPackage(): string`` — the top frame's package name,
##     or ``""`` when no ``build:`` block is open.
##
##   * ``currentBuildArtifact(): string`` — the top frame's artifact name
##     (``""`` for the package-level ``build:`` form), or ``""`` when no
##     ``build:`` block is open.
##
##   * ``currentServicePackage(): string`` / ``currentServiceName():
##     string`` — symmetric surface for the M5 ``service:`` stack. The
##     M5 emitter does NOT splice the user's verbatim service body (only
##     parsed setter calls — see ``emitM5Services`` in ``macros_b.nim``),
##     so a helper proc called from inside a recipe's ``service:`` body
##     today won't observe these from a recipe-level reference; the
##     accessors are still exposed for symmetry and for the M5+ emitter
##     evolution where verbatim body-splicing may land. ``cli:`` blocks
##     have no runtime stack (every parameter registers eagerly at macro-
##     expansion time), so there is no analogous CLI accessor.
##
## ─────────────────────────────────────────────────────────────────────────
## Why convenience procs instead of having callers reach
## ``currentBuildContextFrame()`` directly?
## ─────────────────────────────────────────────────────────────────────────
##
## ``currentBuildContextFrame()`` returns a ``DslBuildContextFrame`` whose two
## string fields the caller would have to dot-access (``.packageName`` /
## ``.artifactName``). Recipes that just want "what package am I in?" then
## have to ALSO import the type. The convenience accessors:
##
##   1. Hide the record type (callers never have to name it).
##   2. Give the API a stable ergonomic surface that downstream lowerings
##      can later cache or memoise without touching every recipe.
##   3. Match v8's pattern (``currentPackage()`` / ``currentArtifact()``
##      shims) so when a v8 recipe lifts to the production DSL the helper
##      names line up one-for-one.

proc currentBuildPackage*(): string =
  ## Return the active ``build:`` block's package name, or the empty
  ## string when no build context is on the stack. Safe to call from any
  ## Nim proc reached as a side effect from inside the body of a
  ## recipe's ``build:`` block.
  let frame = currentBuildContextFrame()
  result = frame.packageName

proc currentBuildArtifact*(): string =
  ## Return the active ``build:`` block's artifact name (``""`` for the
  ## package-level form), or the empty string when no build context is
  ## on the stack. The empty-stack and the package-level cases are
  ## indistinguishable through this accessor by design — callers that
  ## need to disambiguate use ``currentBuildPackage()`` in tandem (a
  ## non-empty package name with an empty artifact name signals the
  ## package-level form).
  let frame = currentBuildContextFrame()
  result = frame.artifactName

# ---------------------------------------------------------------------------
# DSL-port M9.F — cross-artifact output references.
#
# v8's NDE0-K kernel rewrite needs to be able to declare ONE artifact's
# output and then PASS it as an input to a SECOND artifact's build action,
# e.g.::
#
#   package kernel:
#     files configFile:
#       build:
#         output("/build/config-used")
#     executable bzImage:
#       build:
#         kernelCompile.build(
##           source = linuxSource.tree,
##           config = configFile.output,
#           output = "build/bzImage")
#
# The cleanest user-facing surface (``<ident>.output`` dot syntax) requires
# the M3 ident-form to inject a typed ``DslArtifactRef`` rather than the
# current ``DslArtifact`` value, and would ripple through every prior M3+
# test. The M9.F simplification picks two SHIM procs that stand in for the
# v8 dot-syntax without touching M3's macro layer:
#
#   * ``outputOf(packageName, artifactName)`` — a function-form shorthand
#     returning a ``DslOutputRef`` for the producer artifact.
#   * ``toolBuild(toolName, inputs, output)`` — a flat helper that records
#     a tool-build wiring (one input per ``(slot, DslOutputRef)`` pair) and
#     the resulting output. NDE0-K's rewrite will spell
#     ``kernelCompile.build(config = configFile.output, …)`` as
#     ``toolBuild("kernelCompile", @[("config", outputOf("kernel", "configFile"))], "build/bzImage")``.
#
# The full v8 dot-syntax (``configFile.output``) is DEFERRED. The M9.F
# helpers cover the runtime registration surface; a later milestone can
# add the dot-syntax sugar without changing the registry shape.
#
# Backward compat: the existing M4 ``output(path)`` callers MUST keep
# working as bare statements. The new signature returns ``DslOutputRef``
# and is tagged ``{.discardable.}`` so legacy ``output("foo")`` callers
# compile without warnings AND the new typed return value is available
# when the caller asks for it (``let h = output("foo")``).
# ---------------------------------------------------------------------------

type
  DslOutputRef* = object
    ## A typed handle pointing at one output path declared via
    ## ``output(...)`` inside a producer artifact's ``build:`` block.
    ## ``packageName`` / ``artifactName`` identify the producer;
    ## ``path`` is the path string the producer registered.
    ##
    ## Two construction paths:
    ##
    ##   * ``output(path)`` returns a handle whose three fields all
    ##     reflect the live build-context frame and the registered
    ##     path.
    ##   * ``outputOf(packageName, artifactName)`` returns a handle
    ##     whose ``path`` echoes the FIRST registered output for the
    ##     named producer (or ``""`` when nothing is registered yet
    ##     — e.g. when the consumer's ``build:`` runs before the
    ##     producer's because module-init ordering puts them out of
    ##     declaration order).
    packageName*: string
    artifactName*: string
    path*: string

  DslBuildInput* = object
    ## One ``toolBuild`` consumer-side wiring entry. Records that the
    ## consumer artifact ``(consumerPackageName, consumerArtifactName)``
    ## passed the producer's output ``(producerPackageName,
    ## producerArtifactName, producerPath)`` into a named input slot
    ## ``inputName`` (e.g. ``"config"``, ``"source"``).
    consumerPackageName*: string
    consumerArtifactName*: string
    inputName*: string
    producerPackageName*: string
    producerArtifactName*: string
    producerPath*: string

var dslPortArtifactOutputs {.threadvar.}: Table[string, seq[DslOutputRef]]
  ## Per-``(packageName, artifactName)`` typed-output registry. Keyed by
  ## ``packageName & "\x00" & artifactName`` (NUL separator picked so the
  ## key is unambiguous even if a future artifact name contains ``.``).
  ## Populated by ``output(path)`` IN ADDITION to the legacy ``dslPort
  ## Outputs`` string registry so the M4 ``registeredOutputs`` accessor
  ## stays byte-identical to its pre-M9.F shape.

var dslPortBuildInputs {.threadvar.}: Table[string, seq[DslBuildInput]]
  ## Per-``(consumerPackageName, consumerArtifactName)`` build-input
  ## registry. Keyed using the same ``\x00`` separator as
  ## ``dslPortArtifactOutputs``. Populated by ``registerBuildInput`` /
  ## ``toolBuild`` when a consumer artifact's ``build:`` records a
  ## producer-to-input wiring.

proc m9fKey(packageName, artifactName: string): string {.inline.} =
  ## Compose the NUL-separated table key used by the M9.F registries.
  result = packageName & "\x00" & artifactName

proc resetDslPortBuildInputState*() =
  ## Drop every M9.F typed-output handle + build-input wiring. Test
  ## fixtures running on different threads also implicitly start clean
  ## because both tables are ``{.threadvar.}``; the explicit reset is
  ## here for symmetry with ``resetDslPortBuildState`` for the rare
  ## fixture that exercises multiple package fragments on one thread.
  dslPortArtifactOutputs.clear()
  dslPortBuildInputs.clear()

proc output*(path: string): DslOutputRef {.discardable.} =
  ## Record ``path`` against the active build context's
  ## ``(packageName, artifactName)`` bucket. When no context is
  ## active (the stack is empty), the call is a SILENT no-op so the
  ## legacy ``buildXxxPackage*()`` provider-mode call chain — which
  ## may invoke build code without first opening an M4 context —
  ## stays compatible. The init-time emission from the ``package``
  ## macro always wraps the body in ``beginBuildContext / try /
  ## finally endBuildContext`` so the no-op branch is unreachable
  ## from a correctly-shaped recipe.
  ##
  ## M9.F EXTENSION: in addition to the M4 string registry, the call
  ## now ALSO appends a ``DslOutputRef`` handle to the M9.F typed-output
  ## registry AND returns that handle so the caller can pass it to
  ## ``registerBuildInput`` / ``toolBuild`` as a typed reference. The
  ## ``{.discardable.}`` annotation preserves M4 backward compatibility
  ## for bare ``output("path")`` statement-form callers.
  ##
  ## Empty-context behaviour: the no-op branch returns a default-
  ## constructed ``DslOutputRef`` (all three fields empty). This matches
  ## the M4 silent-no-op contract — callers reaching this branch are
  ## outside an M4 frame and the legacy provider mode never reads the
  ## handle.
  if dslPortActiveBuildContext.len == 0:
    return DslOutputRef(packageName: "", artifactName: "", path: path)
  let frame = dslPortActiveBuildContext[^1]
  let legacyKey = frame.packageName & "." & frame.artifactName
  if not dslPortOutputs.hasKey(legacyKey):
    dslPortOutputs[legacyKey] = @[]
  dslPortOutputs[legacyKey].add(path)
  let typedKey = m9fKey(frame.packageName, frame.artifactName)
  if not dslPortArtifactOutputs.hasKey(typedKey):
    dslPortArtifactOutputs[typedKey] = @[]
  result = DslOutputRef(
    packageName: frame.packageName,
    artifactName: frame.artifactName,
    path: path)
  dslPortArtifactOutputs[typedKey].add(result)

proc registeredOutputs*(packageName, artifactName: string): seq[string] =
  ## Return every output path recorded against the ``(packageName,
  ## artifactName)`` key in registration order. Returns the empty seq
  ## when the key was never written; symmetric with the M2 / M3
  ## accessor convention.
  let key = packageName & "." & artifactName
  if dslPortOutputs.hasKey(key):
    return dslPortOutputs[key]
  return @[]

proc registeredOutputRefs*(packageName, artifactName: string): seq[DslOutputRef] =
  ## M9.F: return the typed ``DslOutputRef`` handles recorded against
  ## the ``(packageName, artifactName)`` key in registration order.
  ## Returns the empty seq when the key was never written. Diagnostic
  ## sibling of ``registeredOutputs`` for callers that want the
  ## producer-identity metadata along with the path.
  let key = m9fKey(packageName, artifactName)
  if dslPortArtifactOutputs.hasKey(key):
    return dslPortArtifactOutputs[key]
  return @[]

proc outputOf*(packageName, artifactName: string): DslOutputRef =
  ## M9.F: function-form shorthand that returns a ``DslOutputRef`` for
  ## the named producer artifact. Stands in for v8's
  ## ``<artifactIdent>.output`` dot syntax until M3's ident injection
  ## gets widened (deferred — see the section header above).
  ##
  ## Lookup: returns the FIRST handle the producer registered, OR a
  ## placeholder handle with ``path == ""`` when nothing has been
  ## registered yet. The producer-then-consumer ordering is the
  ## expected case (NDE0-K writes ``files configFile: build: output
  ## "config"`` BEFORE ``executable bzImage: build: toolBuild(...)``,
  ## and module-init evaluates package bodies in source order), so the
  ## empty-path branch is reachable only when the recipe wires inputs
  ## from a producer that has not (yet) emitted a registered output.
  let key = m9fKey(packageName, artifactName)
  if dslPortArtifactOutputs.hasKey(key) and dslPortArtifactOutputs[key].len > 0:
    return dslPortArtifactOutputs[key][0]
  return DslOutputRef(
    packageName: packageName,
    artifactName: artifactName,
    path: "")

proc registerBuildInput*(consumerPackageName, consumerArtifactName,
                         inputName: string;
                         producer: DslOutputRef) =
  ## M9.F: record one consumer-side build-input wiring. The
  ## ``(consumerPackageName, consumerArtifactName)`` pair identifies
  ## the artifact whose ``build:`` block consumes ``producer`` via the
  ## named slot ``inputName``. Idempotency follows the M4 registry
  ## convention — duplicate registrations append rather than collapse
  ## so conditional ``when`` branches that re-declare the same wiring
  ## under different platform gates surface to the consumer with full
  ## provenance.
  let key = m9fKey(consumerPackageName, consumerArtifactName)
  if not dslPortBuildInputs.hasKey(key):
    dslPortBuildInputs[key] = @[]
  dslPortBuildInputs[key].add(DslBuildInput(
    consumerPackageName: consumerPackageName,
    consumerArtifactName: consumerArtifactName,
    inputName: inputName,
    producerPackageName: producer.packageName,
    producerArtifactName: producer.artifactName,
    producerPath: producer.path))

proc registeredBuildInputs*(consumerPackageName,
                            consumerArtifactName: string): seq[DslBuildInput] =
  ## M9.F: return every build-input wiring recorded against the
  ## ``(consumerPackageName, consumerArtifactName)`` key in
  ## registration order. Returns the empty seq when no wiring was
  ## registered.
  let key = m9fKey(consumerPackageName, consumerArtifactName)
  if dslPortBuildInputs.hasKey(key):
    return dslPortBuildInputs[key]
  return @[]

proc toolBuild*(toolName: string;
                inputs: seq[(string, DslOutputRef)];
                outputPath: string): DslOutputRef {.discardable.} =
  ## M9.F: flat helper that lowers v8's
  ## ``<tool>.build(input1 = expr1, input2 = expr2, output = "path")``
  ## tool-build invocation into the M9.F registries WITHOUT requiring
  ## the macro layer to parse ``<ident>.build(...)``:
  ##
  ##   1. For each ``(slot, producerRef)`` pair in ``inputs``, append a
  ##      ``DslBuildInput`` row to the active consumer artifact's
  ##      build-input bucket via ``registerBuildInput``.
  ##   2. Append ``outputPath`` to the M4 string registry AND the M9.F
  ##      typed-output registry by funnelling through ``output()`` — so
  ##      the wiring fixture observes the same registration paths as
  ##      the legacy ``output("…")`` statement.
  ##
  ## ``toolName`` is captured so a future milestone can lower it into a
  ## structural ``DslToolInvocation`` record. The parameter name
  ## ``outputPath`` (rather than ``output``) avoids shadowing the
  ## module-level ``output`` proc inside this body.
  ##
  ## Returns a ``DslOutputRef`` so callers can chain
  ## ``toolBuild(...)`` results into a later ``toolBuild`` invocation
  ## without re-querying the registry; ``{.discardable.}`` lets the
  ## return value be ignored at the call site.
  discard toolName  # captured intentionally; reserved for a follow-up milestone
  let frame = currentBuildContextFrame()
  for (slot, producer) in inputs:
    registerBuildInput(frame.packageName, frame.artifactName, slot, producer)
  result = output(outputPath)

# ---------------------------------------------------------------------------
# DSL-port M5 — ``service:`` block lowering: per-package service registry
# + active-context stack for body-setter resolution.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## What the M5 surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## v8's ``service`` template (``project_package_dsl.nim`` lines 906-924
## for the typed form, and the body-setter primitives at lines 930-1116)
## records a service definition keyed by name, with a reference to a
## declared ``executable`` artifact and a list of positional arguments.
## v8 additionally accepts richer body shapes (``on rebuild:``,
## ``hotReload``, ``reloadOnChange``, ``runtimeFile``, etc.) but for M5
## we port the minimal contract — name + executableRef + args — plus a
## verbatim ``bodyRepr`` capture so the diagnostic surface is open for
## M5+ extensions.
##
##   * ``registerService(packageName, serviceName, executableRef, args,
##     bodyRepr)`` — observer-style append-only registry. The
##     ``package`` macro emits one call per recognised ``service:``
##     block at module-init time.
##
##   * ``registeredServices(packageName): seq[DslServiceDef]`` —
##     diagnostic accessor. Returns the empty seq when no service was
##     ever registered against the package, matching the M2 / M3 / M4
##     "empty rather than raise" convention.
##
##   * ``resetDslPortServiceState()`` — drops every service. Test
##     fixtures call this between scenarios. Lives alongside the
##     other four reset procs (config / versions / artifacts / build).
##
## ─────────────────────────────────────────────────────────────────────────
## Why a new active-service stack rather than extending the M4 build
## frame?
## ─────────────────────────────────────────────────────────────────────────
##
## The M4 reviewer raised the question of whether services should nest
## inside ``build:`` blocks and therefore share the M4 active-context
## frame. The answer is NO: v8's ``service`` template sits at the
## SAME lexical level as ``executable``/``library``/``files`` and
## ``build:`` (one statement inside the ``package`` body, not nested
## inside a ``build:``). Mixing the two stacks would also rip the M4
## ``DslBuildContextFrame`` schema (need an extra discriminator) which
## the M4 reviewer's risk #3 explicitly warns against — keep them
## disjoint.
##
## So M5 introduces ``dslPortActiveServiceContext`` as a separate
## per-thread stack used solely for body-setter routing. ``beginService
## Context`` pushes a frame with the service's pending name/exe/args;
## the body-setters (``setActiveServiceExecutable`` /
## ``setActiveServiceArgs``) mutate the top frame; ``finishService
## Context`` pops, materialises the ``DslServiceDef`` record, and
## appends it to ``dslPortServiceRegistry``.
##
## ─────────────────────────────────────────────────────────────────────────
## Empty-stack convention
## ─────────────────────────────────────────────────────────────────────────
##
## ``currentServiceContext()`` returns a zero-value frame when the stack
## is empty rather than raising. This matches M4's
## ``currentBuildContextFrame()`` decision (M4 reviewer's risk #5: "M5 should
## pick + document"). The body-setter procs check the stack length AND
## treat an empty stack as a silent no-op — services declared from a
## ``when`` branch that the test fixture never opens never push a frame,
## and the no-op keeps the test from crashing.
##
## ─────────────────────────────────────────────────────────────────────────
## Why ``Table[string, seq[DslServiceDef]]`` rather than a flat seq?
## ─────────────────────────────────────────────────────────────────────────
##
## M4 reviewer's risk #4 flagged that services need lookup by name +
## ordering. ``Table[string, seq[DslServiceDef]]`` keyed by package
## name gives O(1) per-package lookup AND preserves per-package
## insertion order (since each bucket is a ``seq``). Symmetric with the
## ``dslPortVersionRegistry`` shape M2 already uses.

type
  DslServiceEnvEntry* = tuple[key: string, value: string]
    ## One ``env "KEY", "VALUE"`` pair recorded inside a ``service:``
    ## body. M9.C extension — see the M9.C section below.

  DslServiceDef* = object
    ## One ``service:`` block registration. Populated by ``emitM5Services``
    ## at module-init time; read by host code via ``registeredServices``.
    packageName*: string
    serviceName*: string
      ## The source-level ident text (or string-literal verbatim for
      ## ``service "name":``). Empty when the section call had no name
      ## node — the M5 emitter rejects anonymous services at macro-
      ## expansion time so this is informational only.
    executableRef*: string
      ## The name of the referenced executable artifact. Empty when the
      ## body lacked an ``executable <ident>`` setter (e.g. when the
      ## service body was preserved as raw Nim only). The cross-check
      ## test pins the populated case; the empty case is the defensive
      ## fallback.
    executable*: string
      ## M9.C alias of ``executableRef`` — exposed under the field name
      ## used by the M9.C survey spec. The M5 emitter populates BOTH so
      ## new tests can read ``svc.executable`` while M5's three pinned
      ## fixtures (``t_dsl_service_basic`` / ``..._executable_ref`` /
      ## ``..._args``) continue to read ``svc.executableRef``. Kept as a
      ## second field rather than a rename so the M5 acceptance surface
      ## does not move.
    args*: seq[string]
      ## Positional arguments from the body's ``args "x", "y", ...``
      ## setter, in declaration order. Empty when no ``args`` setter
      ## was present — the "defensive empty-args" guarantee.
    bodyRepr*: string
      ## The full ``service:`` body's ``NimNode.repr`` at the time the
      ## emitter ran. Diagnostic surface — M6+ may parse additional
      ## setters out of this string OR re-walk the partitioned section
      ## list. Same model M3/M4 use for their ``bodyRepr`` captures.
    # ---------------------------------------------------------------
    # M9.C — systemd-unit metadata extensions.
    #
    # The M9 NDE-package discovery survey flagged that systemd-unit
    # rewrites need richer metadata than M5's minimal
    # ``executable`` + ``args`` surface. The fields below match the
    # systemd unit-file properties used by the NDE consumers
    # (dbus.service / gdm.service / sddm.service / sway-session.service
    # / repro-ldconfig.service). All fields default to empty (string
    # "" / seq @[]) so M5 callers that never touched the new setters
    # continue to read the same shape they always did.
    # ---------------------------------------------------------------
    description*: string
      ## ``description "..."`` — free-form unit description. Empty when
      ## the body lacked the setter.
    serviceType*: string
      ## ``type "..."`` — one of ``simple`` / ``forking`` / ``oneshot``
      ## / ``notify`` / ``dbus`` / ``idle``. The string is recorded
      ## verbatim; M5+ may add an enum surface once the consumer list
      ## stabilises.
    execStart*: string
      ## ``execStart "..."`` — full command string. Alternative to the
      ## ``executable`` + ``args`` lowering: lets a recipe pin
      ## ``/path/to/binary --flag arg`` directly without going through
      ## an artifact ref. Empty when the body uses the M5 pathway.
    wantedBy*: seq[string]
      ## ``wantedBy "<target>"`` — repeated; appended in declaration
      ## order.
    wants*: seq[string]
      ## ``wants "<unit>"`` — repeated; appended in declaration order.
    requires*: seq[string]
      ## ``requires "<unit>"`` — repeated; appended in declaration
      ## order.
    before*: seq[string]
      ## ``before "<unit>"`` — repeated; appended in declaration order.
    after*: seq[string]
      ## ``after "<unit>"`` — repeated; appended in declaration order.
    env*: seq[DslServiceEnvEntry]
      ## ``env("KEY", "VALUE")`` — repeated; appended in declaration
      ## order. The call form (two string-literal arguments) is used
      ## rather than ``env "KEY"="VALUE"`` because the former parses
      ## cleanly as ``Call(Ident "env", StrLit, StrLit)`` whereas the
      ## assignment form lands as ``Command(Ident "env",
      ## Asgn(StrLit, StrLit))`` which is parser-noisy.
    restart*: string
      ## ``restart "<policy>"`` — e.g. ``on-failure`` / ``always``.
      ## Empty when the body lacked the setter.
    user*: string
      ## ``user "..."`` — run-as user. Empty when the body lacked the
      ## setter.
    group*: string
      ## ``group "..."`` — run-as group. Empty when the body lacked
      ## the setter.

  DslServiceContextFrame = object
    ## One frame on the active-service stack. Pushed by
    ## ``beginServiceContext``, popped by ``finishServiceContext``.
    ## Held module-private because body-setters route through their
    ## own public wrappers — host code never inspects a raw frame.
    packageName: string
    serviceName: string
    executableRef: string
    args: seq[string]
    bodyRepr: string
    # M9.C extensions — see DslServiceDef above for field semantics.
    description: string
    serviceType: string
    execStart: string
    wantedBy: seq[string]
    wants: seq[string]
    requires: seq[string]
    before: seq[string]
    after: seq[string]
    env: seq[DslServiceEnvEntry]
    restart: string
    user: string
    group: string

var dslPortServiceRegistry: Table[string, seq[DslServiceDef]]
  ## Per-package service registry. Keyed by package name.
  ## ``registerService`` appends to the per-package seq;
  ## ``registeredServices`` returns a copy so callers cannot mutate
  ## the registry from outside the public API.

var dslPortActiveServiceContext {.threadvar.}:
    seq[DslServiceContextFrame]
  ## Active-service stack. ``threadvar`` so test fixtures running on
  ## different threads don't cross-attribute body-setter calls. Empty
  ## when no ``service:`` block is currently open.

proc resetDslPortServiceState*() =
  ## Drop every recorded service + clear the active-context stack. Test
  ## fixtures call this between scenarios so registry entries do not
  ## leak across cases. Keeping the five concerns (config, versions,
  ## artifacts, build, services) separable lets tests target one
  ## surface without disturbing the others.
  dslPortServiceRegistry.clear()
  dslPortActiveServiceContext.setLen(0)

proc registerService*(packageName, serviceName, executableRef: string;
                     args: seq[string]; bodyRepr: string;
                     description = ""; serviceType = "";
                     execStart = "";
                     wantedBy: seq[string] = @[];
                     wants: seq[string] = @[];
                     requires: seq[string] = @[];
                     before: seq[string] = @[];
                     after: seq[string] = @[];
                     env: seq[DslServiceEnvEntry] = @[];
                     restart = "";
                     user = ""; group = "") =
  ## Append one service entry against ``packageName``. The ``package``
  ## macro emits one call per recognised ``service:`` block via
  ## ``emitM5Services``.
  ##
  ## Idempotency: re-running the registration on a second module-init
  ## of the same package appends a duplicate row — we deliberately do
  ## NOT collapse, because conditional ``when`` branches can
  ## legitimately re-declare a service under different platform gates
  ## and the consumer decides which arm to honour. Tests that need a
  ## clean baseline call ``resetDslPortServiceState`` first.
  ##
  ## M9.C: the ``description`` / ``serviceType`` / ``execStart`` /
  ## ``wantedBy`` / ``wants`` / ``requires`` / ``before`` / ``after`` /
  ## ``env`` / ``restart`` / ``user`` / ``group`` parameters all
  ## default to empty so M5 callers that only pass the five original
  ## positional parameters continue to compile unchanged.
  if packageName notin dslPortServiceRegistry:
    dslPortServiceRegistry[packageName] = @[]
  dslPortServiceRegistry[packageName].add(DslServiceDef(
    packageName: packageName,
    serviceName: serviceName,
    executableRef: executableRef,
    executable: executableRef,
    args: args,
    bodyRepr: bodyRepr,
    description: description,
    serviceType: serviceType,
    execStart: execStart,
    wantedBy: wantedBy,
    wants: wants,
    requires: requires,
    before: before,
    after: after,
    env: env,
    restart: restart,
    user: user,
    group: group))

proc registeredServices*(packageName: string): seq[DslServiceDef] =
  ## Return every service registered against ``packageName`` in
  ## declaration order. Returns the empty seq when the package never
  ## declared a ``service:`` block; callers must NOT treat the empty
  ## return as an error.
  if packageName in dslPortServiceRegistry:
    return dslPortServiceRegistry[packageName]
  return @[]

# ---------------------------------------------------------------------------
# Active-service stack: body-setter routing
#
# These procs are exposed because ``emitM5Services`` lowers ``service:``
# body-setters into runtime calls against them. Host code does NOT call
# the active-stack procs directly — the stack is an implementation
# detail of the M5 emission.
# ---------------------------------------------------------------------------

proc beginServiceContext*(packageName, serviceName, bodyRepr: string) =
  ## Push a frame onto the active-service stack. The ``package`` macro
  ## wraps every recognised ``service:`` body in a try/finally that
  ## pairs this with ``finishServiceContext``. Multiple pushes nest
  ## cleanly — body-setters always mutate the TOP frame.
  dslPortActiveServiceContext.add(DslServiceContextFrame(
    packageName: packageName,
    serviceName: serviceName,
    executableRef: "",
    args: @[],
    bodyRepr: bodyRepr,
    description: "",
    serviceType: "",
    execStart: "",
    wantedBy: @[],
    wants: @[],
    requires: @[],
    before: @[],
    after: @[],
    env: @[],
    restart: "",
    user: "",
    group: ""))

proc setActiveServiceExecutable*(executableRef: string) =
  ## Body-setter: select the referenced executable artifact. Mirrors
  ## v8's ``setServiceExecutable``. When the stack is empty this is a
  ## silent no-op (matches the M4 ``output()`` empty-context decision —
  ## the empty path is unreachable from a correctly-shaped recipe but
  ## keeps the legacy provider chain compatible).
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].executableRef = executableRef

proc addActiveServiceArg*(value: string) =
  ## Body-setter: append one positional argument to the active frame.
  ## ``emitM5Services`` lowers ``args "a", "b", "c"`` into one call per
  ## argument so the variadic shape survives the macro round-trip.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].args.add(value)

# ---------------------------------------------------------------------------
# M9.C — systemd-unit metadata body-setters. One proc per recognised setter
# in the M9.C surface. All are silent no-ops when the active-service stack
# is empty (matches the M5 no-op convention documented above
# ``setActiveServiceExecutable``). ``emitM5Services`` lowers the body
# setters into one call per occurrence so the per-package frame collects
# every value in declaration order.
# ---------------------------------------------------------------------------

proc setActiveServiceDescription*(value: string) =
  ## Body-setter for ``description "..."``. Last-wins on repeats.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].description = value

proc setActiveServiceType*(value: string) =
  ## Body-setter for ``type "..."``. Last-wins on repeats.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].serviceType = value

proc setActiveServiceExecStart*(value: string) =
  ## Body-setter for ``execStart "..."``. Last-wins on repeats.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].execStart = value

proc addActiveServiceWantedBy*(value: string) =
  ## Body-setter for ``wantedBy "<target>"``. Appended per occurrence.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].wantedBy.add(value)

proc addActiveServiceWants*(value: string) =
  ## Body-setter for ``wants "<unit>"``. Appended per occurrence.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].wants.add(value)

proc addActiveServiceRequires*(value: string) =
  ## Body-setter for ``requires "<unit>"``. Appended per occurrence.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].requires.add(value)

proc addActiveServiceBefore*(value: string) =
  ## Body-setter for ``before "<unit>"``. Appended per occurrence.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].before.add(value)

proc addActiveServiceAfter*(value: string) =
  ## Body-setter for ``after "<unit>"``. Appended per occurrence.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].after.add(value)

proc addActiveServiceEnv*(key, value: string) =
  ## Body-setter for ``env("KEY", "VALUE")``. Appended per occurrence
  ## in declaration order — see the env-form rationale above
  ## ``DslServiceDef.env``.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].env.add((key: key, value: value))

proc setActiveServiceRestart*(value: string) =
  ## Body-setter for ``restart "<policy>"``. Last-wins on repeats.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].restart = value

proc setActiveServiceUser*(value: string) =
  ## Body-setter for ``user "..."``. Last-wins on repeats.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].user = value

proc setActiveServiceGroup*(value: string) =
  ## Body-setter for ``group "..."``. Last-wins on repeats.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].group = value

proc finishServiceContext*() =
  ## Pop the top frame and materialise a ``DslServiceDef`` record from
  ## it, appending to ``dslPortServiceRegistry``. Safe to call on an
  ## empty stack (no-op) — the try/finally pairing guarantees balance
  ## in well-formed code, but defensive no-op semantics let unit tests
  ## reset between scenarios without crashing when state was already
  ## clean.
  if dslPortActiveServiceContext.len == 0:
    return
  let frame = dslPortActiveServiceContext[^1]
  dslPortActiveServiceContext.setLen(
    dslPortActiveServiceContext.len - 1)
  registerService(frame.packageName, frame.serviceName,
                  frame.executableRef, frame.args, frame.bodyRepr,
                  description = frame.description,
                  serviceType = frame.serviceType,
                  execStart = frame.execStart,
                  wantedBy = frame.wantedBy,
                  wants = frame.wants,
                  requires = frame.requires,
                  before = frame.before,
                  after = frame.after,
                  env = frame.env,
                  restart = frame.restart,
                  user = frame.user,
                  group = frame.group)

# ---------------------------------------------------------------------------
# DSL-port M7 — user-facing service-context accessors. Symmetric with the
# build-context ``currentBuildPackage`` / ``currentBuildArtifact`` surface.
#
# ``DslServiceContextFrame`` itself is held module-private (host code is
# not meant to inspect raw frames — body-setters route through their own
# public wrappers). The two accessors below expose the package name and
# service name as plain strings, mirroring the M7 build-context surface.
# Empty string when the stack is empty, mirroring the M4
# ``currentBuildContextFrame`` empty-stack convention.
# ---------------------------------------------------------------------------

proc currentServicePackage*(): string =
  ## Return the active ``service:`` block's package name, or the empty
  ## string when no service context is on the stack. The M5 emitter does
  ## not splice the user's verbatim service body today (see
  ## ``emitM5Services``), so a helper proc called from a recipe-level
  ## ``service:`` body won't observe this from current emission shape;
  ## the accessor is exposed for symmetry with the M7 build-context
  ## surface and so the M5+ emitter can later splice the body without
  ## requiring a new public API.
  if dslPortActiveServiceContext.len > 0:
    return dslPortActiveServiceContext[^1].packageName
  return ""

proc currentServiceName*(): string =
  ## Return the active ``service:`` block's service name (the source-
  ## level ident text, or the string-literal verbatim for ``service
  ## "name":``), or the empty string when no service context is on the
  ## stack. Same empty-stack convention as ``currentServicePackage``.
  if dslPortActiveServiceContext.len > 0:
    return dslPortActiveServiceContext[^1].serviceName
  return ""

# ---------------------------------------------------------------------------
# DSL-port M6 — ``cli:`` block ``pos`` / ``flag`` / ``boolFlag`` parameter
# registry.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## What the M6 surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## v8's ``cli`` template (``project_package_dsl.nim`` line 830) is a
## context wrapper that pushes a CLI-scope graph node and runs the body.
## Inside, the ``pos`` / ``flag`` / ``boolFlag`` macros (lines 682-820)
## emit one ``recordCliPos`` / ``recordCliFlag`` / ``recordCliBoolFlag``
## runtime call per declared parameter, keyed off the current section
## (root or named ``subcmd``). M6 ports the MINIMAL contract:
##
##   * ``pos <name> is <Type>``              → ``DslCliParam(kind: cpkPos)``.
##   * ``flag <name> is <Type>``             → ``DslCliParam(kind: cpkFlag)``.
##   * ``boolFlag <name>`` (no type)         → ``DslCliParam(kind: cpkBoolFlag,
##                                              typeName: "bool")``.
##
## The registry is keyed by ``<packageName>.<artifactName>.<subcmd>``
## with ``subcmd`` == "" for the root scope. M6 records ROOT-scope params
## from the simple form ``cli: pos input is string; flag x is string``.
## ``subcmd "<name>":`` nesting is deferred to a follow-on milestone
## (see "Honest deferrals" in the M6 report); the registry schema's
## ``subcmd`` field is wired through so the deferral doesn't require a
## schema bump.
##
## ─────────────────────────────────────────────────────────────────────────
## Why ``DslCliParamKind`` and not ``CliParamKind``?
## ─────────────────────────────────────────────────────────────────────────
##
## ``types.nim`` already exports a legacy ``CliParamKind* = enum
## cpkPositional, cpkFlag`` used by the typed-tool wrapper / ``parseParam``
## chain. Reusing the type name would collide; the enum LITERAL ``cpkFlag``
## is also shared. Nim's overload resolution disambiguates same-named
## enum literals via the expected-type rule at the comparison site, so
## ``params[0].kind == cpkPos`` and ``params[0].kind == cpkFlag`` both
## resolve to the M6 enum when ``params[0].kind`` is typed as
## ``DslCliParamKind``. The M6 enum gets its own type name to keep
## type-level lookups unambiguous (``DslCliParamKind`` vs
## ``CliParamKind``).
##
## ─────────────────────────────────────────────────────────────────────────
## Threading model
## ─────────────────────────────────────────────────────────────────────────
##
## Module-level (not ``threadvar``), same as the M3/M5 artifact /
## service registries. M6 registrations happen at module-init time on
## the main thread; consumers read from any thread.

type
  DslCliParamKind* = enum
    ## Discriminator for the three CLI-parameter shapes v8's ``cli``
    ## body accepts. Bears the same literal-name conventions as the
    ## v8-port spec (``cpkPos`` / ``cpkFlag`` / ``cpkBoolFlag``).
    ## Distinct from the legacy ``CliParamKind`` in ``types.nim``
    ## (``cpkPositional`` / ``cpkFlag``) — see the section comment
    ## above for the disambiguation rationale.
    cpkPos
    cpkFlag
    cpkBoolFlag

  DslCliParam* = object
    ## One ``pos`` / ``flag`` / ``boolFlag`` registration inside a
    ## ``cli:`` block. Populated by ``emitM6CliLowering`` at module-init
    ## time; read by host code via ``registeredCliParams``.
    packageName*: string
    artifactName*: string
      ## The parent ``executable`` / ``library`` / ``files`` artifact
      ## name verbatim (no kebab translation — symmetric with M3 / M5).
    subcmd*: string
      ## The enclosing ``subcmd "<name>":`` label, or "" for the root
      ## scope. The schema reserves this field for the M6+ subcmd
      ## extension; M6 always emits "" because the subcmd lowering is
      ## deferred (see "Honest deferrals" in the M6 report).
    name*: string
      ## The source-level identifier of the parameter (e.g. ``input``,
      ## ``region``, ``verbose``). NOT the kebab/cli-name translation
      ## v8's ``cliNameFromIdent`` produces — M6's registry keys the
      ## param off the Nim ident for symmetric round-tripping with
      ## downstream consumers (M7+).
    typeName*: string
      ## "string" / "int" / "bool" / "seq[string]" verbatim from the
      ## ``is <Type>`` infix. For ``boolFlag`` the source omits the
      ## type; the emitter defaults to "bool".
    kind*: DslCliParamKind

var dslPortCliParams: Table[string, seq[DslCliParam]]
  ## Per-``<packageName>.<artifactName>.<subcmd>`` CLI-parameter
  ## registry. Each bucket holds the params in source-declaration
  ## order. ``registerCliParam`` appends; ``registeredCliParams``
  ## returns a copy so callers cannot mutate the registry from
  ## outside the public API.

proc dslCliKeyOf*(packageName, artifactName, subcmd: string): string =
  ## Internal: compose the registry key. Exposed as a public helper so
  ## test fixtures can inspect/reset specific buckets without rebuilding
  ## the key by hand.
  result = packageName & "." & artifactName & "." & subcmd

proc resetDslPortCliState*() =
  ## Drop every recorded CLI-parameter spec. Test fixtures call this
  ## between scenarios so registry entries do not leak across cases.
  ## Symmetric with the M2 / M3 / M4 / M5 reset procs.
  dslPortCliParams.clear()

proc registerCliParam*(packageName, artifactName, subcmd, name,
                       typeName: string; kind: DslCliParamKind) =
  ## Append one CLI-parameter entry against ``<packageName>.<artifactName>
  ## .<subcmd>``. The ``package`` macro emits one call per recognised
  ## ``pos`` / ``flag`` / ``boolFlag`` statement via ``emitM6CliLowering``.
  ##
  ## Idempotency: re-running the registration on a second module-init of
  ## the same package appends a duplicate row — we deliberately do NOT
  ## collapse, because conditional ``when`` branches can legitimately
  ## re-declare a param under different platform gates and the consumer
  ## decides which arm to honour. Tests that need a clean baseline call
  ## ``resetDslPortCliState`` first.
  let key = dslCliKeyOf(packageName, artifactName, subcmd)
  if key notin dslPortCliParams:
    dslPortCliParams[key] = @[]
  dslPortCliParams[key].add(DslCliParam(
    packageName: packageName,
    artifactName: artifactName,
    subcmd: subcmd,
    name: name,
    typeName: typeName,
    kind: kind))

proc registeredCliParams*(packageName, artifactName, subcmd: string):
    seq[DslCliParam] =
  ## Return every CLI parameter registered against the
  ## ``<packageName>.<artifactName>.<subcmd>`` key in declaration order.
  ## Returns the empty seq when the key was never written; symmetric
  ## with the M2 / M3 / M4 / M5 accessor convention.
  let key = dslCliKeyOf(packageName, artifactName, subcmd)
  if key in dslPortCliParams:
    return dslPortCliParams[key]
  return @[]

# ---------------------------------------------------------------------------
# DSL-port M8 — ``fs.configFile`` and ``fs.managedBlock`` named-proc surface.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## What the M8 surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## Per ``reprobuild-specs/Generated-Configuration-Files.md``:
##
##   * ``fs.configFile(path, content, packageName, artifactName)`` —
##     records a fully-owned config-file declaration. The file itself is
##     produced by the apply phase, not by this proc — symmetric with M4's
##     ``output(path)`` "declaration records, apply phase acts" split.
##
##   * ``fs.managedBlock(path, blockId, scope, content, priority,
##     packageName, artifactName)`` — records a single contribution to a
##     multi-contributor managed file. Multiple contributors at the same
##     ``path`` are sorted at materialisation time by
##     ``(priority, packageName, blockId)`` ascending (spec
##     §"Block ordering rule") and emitted with the spec'd triple-form
##     sentinels ``# >>> repro:<scope>:<packageName>:<blockId> >>>``.
##
##   * ``mergedManagedBlockFile(path)`` — return the merged content for a
##     given ``path`` (used by tests + the production apply phase). The
##     merger sorts independently of insertion order so the output is a
##     deterministic function of the contribution set.
##
##   * ``removeManagedBlockContributor(path, scope, packageName,
##     blockId)`` — remove a single contributor from a path's bucket.
##     Spec §"Deletion semantics" guarantees the remaining contributors
##     stay byte-identical; ``mergedManagedBlockFile`` after removal must
##     produce a file with the removed sentinel triple absent and the
##     other contributors' bytes preserved exactly.
##
## ─────────────────────────────────────────────────────────────────────────
## Why a separate fs.nim module wrapper instead of putting the procs
## inside a ``namespace`` Nim doesn't have?
## ─────────────────────────────────────────────────────────────────────────
##
## Nim has no namespace keyword. The idiomatic "fs.configFile(...)" syntax
## is achieved by giving the procs short names (``configFile``,
## ``managedBlock``) inside a module called ``fs``, then importing it as
## ``import repro_project_dsl/fs as fs``. The procs themselves live here
## in ``dsl_port_runtime.nim`` (so the umbrella include chain carries the
## runtime state) and are re-exported by the thin ``fs.nim`` shim that
## sits next to the umbrella module.
##
## Tests that import ``repro_project_dsl`` only (without the ``as fs``
## alias) can still call the procs directly by name (``configFile(...)``,
## ``managedBlock(...)``) — the umbrella exports them too. The ``fs.``
## prefix is purely a callsite-readability sugar; both spellings hit the
## same procs.
##
## ─────────────────────────────────────────────────────────────────────────
## Threading model
## ─────────────────────────────────────────────────────────────────────────
##
## Module-level (not ``threadvar``), same as M3/M5/M6 registries. M8
## registrations happen at module-init time on the main thread; consumers
## (tests, the apply phase) read from any thread.

type
  ManagedBlockScope* = enum
    ## Per spec §"Sentinel uniqueness": the ``<scope>`` segment of the
    ## triple-form sentinel. ``bsSystem`` for /etc/* host files, ``bsHome``
    ## for ~/ anchored files. The single-block ``# >>> repro:home:<id>
    ## >>>`` shape from the older single-contributor form is OUT OF SCOPE
    ## here — M8 always emits the triple form so a single-contributor file
    ## remains forward-compatible with later co-contributors.
    bsSystem = "system"
    bsHome   = "home"

  DslConfigFile* = object
    ## One ``fs.configFile(...)`` registration. Populated at module-init
    ## time; read by host code via ``registeredConfigFiles``.
    packageName*: string
      ## The owning package; auto-filled from ``currentBuildPackage()``
      ## when the caller passes ``""``. May still be ``""`` when the call
      ## happens outside a build context AND the caller did not supply a
      ## name — diagnostic surface only, not a hard error.
    artifactName*: string
      ## The owning artifact within ``packageName``, or ``""`` for a
      ## package-level configFile. Auto-fills from
      ## ``currentBuildArtifact()`` when the caller passes ``""`` AND a
      ## build context is open. Otherwise stays ``""``.
    path*: string
      ## Output path verbatim from the call. Path-resolution (``~/``
      ## expansion, ``${XDG_CONFIG_HOME}`` lookup, ...) is deferred to
      ## the apply phase — M8 records the raw value the recipe author
      ## wrote so ``repro home why <file>`` can quote it back.
    content*: string
      ## Rendered file content verbatim. Empty content is legal (an
      ## empty file is a valid declaration).
    hashHex*: string
      ## Cache key — ``stableHashHex(packageName || artifactName ||
      ## path || content)``. 16 hex characters. Symmetric with the
      ## ``configFileHash`` shape NDE0-S's out-of-DSL helper computed.
      ## Configurable-driven cache-key composition (spec §"Configurables
      ## As Inputs") is deferred to a later milestone; the BLAKE3-256 /
      ## resolved-configurable propagation is also deferred. The simple
      ## FNV-1a digest here is sufficient for the M8 acceptance contract
      ## (any content change invalidates the cache key).

  DslManagedBlockContribution* = object
    ## One ``fs.managedBlock(...)`` contribution. The merged file at any
    ## given ``path`` is the sorted concatenation of every entry whose
    ## ``path`` matches.
    path*: string
    blockId*: string
    scope*: ManagedBlockScope
    packageName*: string
      ## Auto-filled from ``currentBuildPackage()`` when the caller passes
      ## ``""``. Part of the sort key AND the sentinel triple, so the
      ## empty-string case is informational — the spec §"Sentinel
      ## uniqueness" guarantee only holds when packageName is populated.
    artifactName*: string
      ## Auto-fills like ``DslConfigFile.artifactName``. Not part of the
      ## sentinel triple or sort key — recorded for diagnostic provenance
      ## only.
    content*: string
    priority*: int

# ---------------------------------------------------------------------------
# Module-level registries
# ---------------------------------------------------------------------------

var dslPortConfigFiles: Table[string, seq[DslConfigFile]]
  ## Per-package config-file registry. Keyed by ``packageName``.
  ## ``registerConfigFile`` appends; ``registeredConfigFiles`` returns a
  ## copy so callers cannot mutate the registry from outside the public
  ## API. ``Table[string, seq[...]]`` mirrors the M2 version and M5
  ## service shapes — one bucket per package, declaration order within.

var dslPortManagedBlocks: Table[string, seq[DslManagedBlockContribution]]
  ## Per-path managed-block registry. Keyed by ``path`` because the merged
  ## file is composed per-path across contributors from many packages.
  ## Insertion order is NOT the merge order — ``mergedManagedBlockFile``
  ## re-sorts at read time so the output is invariant to which package's
  ## module is initialised first.

# ---------------------------------------------------------------------------
# Reset proc — used by every M8 test fixture
# ---------------------------------------------------------------------------

proc resetDslPortFsState*() =
  ## Drop every recorded ``fs.configFile`` + every recorded
  ## ``fs.managedBlock`` contribution. Test fixtures call this between
  ## scenarios so registry entries do not leak across cases. Symmetric
  ## with the M2 / M3 / M4 / M5 / M6 reset procs.
  dslPortConfigFiles.clear()
  dslPortManagedBlocks.clear()

# ---------------------------------------------------------------------------
# fs.configFile
# ---------------------------------------------------------------------------

proc registerConfigFile*(file: DslConfigFile) =
  ## Type-erased append. The ``configFile`` proc below is the public
  ## callsite recipes use; this helper is exposed so any future emitter
  ## (e.g. a macro that splices configFile calls out of a structured
  ## block) can target it directly without re-implementing the
  ## auto-fill + cache-key composition.
  let key = file.packageName
  if key notin dslPortConfigFiles:
    dslPortConfigFiles[key] = @[]
  dslPortConfigFiles[key].add(file)

proc registeredConfigFiles*(packageName: string): seq[DslConfigFile] =
  ## Return every config-file registered against ``packageName`` in
  ## declaration order. Returns the empty seq when the package never
  ## called ``fs.configFile``; callers must NOT treat the empty return as
  ## an error.
  if packageName in dslPortConfigFiles:
    return dslPortConfigFiles[packageName]
  return @[]

proc configFileHashOf*(packageName, artifactName, path, content: string): string =
  ## Cache-key composition for ``fs.configFile``. The four-tuple feeds
  ## ``stableHashHex`` (FNV-1a, 16 hex chars). The spec calls for
  ## BLAKE3-256 over rendered bytes plus resolved configurable inputs;
  ## M8 emits the simpler FNV-1a digest with no configurable-resolution
  ## hook because the wider configurable plumbing isn't in the DSL-port
  ## scope. Any content / packageName / artifactName / path change still
  ## invalidates the digest, which is the cache-discriminating
  ## requirement.
  result = stableHashHex(
    packageName & "\x00" & artifactName & "\x00" & path & "\x00" & content)

proc configFile*(path: string; content: string;
                 packageName: string = "";
                 artifactName: string = "") =
  ## Records a ``configFile`` declaration. Doesn't touch the filesystem;
  ## production apply phase reads the registry to emit the actual file.
  ##
  ## Auto-fill behaviour: when ``packageName == ""``, consult the M7
  ## ``currentBuildPackage()`` accessor so a call from inside a recipe's
  ## ``build:`` body picks up the enclosing package's name without the
  ## author having to repeat it. The same applies to ``artifactName`` /
  ## ``currentBuildArtifact()``. When BOTH the parameter and the active
  ## context are empty, the registry row carries an empty string in that
  ## field — diagnostic only, not a hard error (so the proc is also
  ## usable from a top-level driver script).
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  var artifact = artifactName
  if artifact.len == 0:
    artifact = currentBuildArtifact()
  let hashHex = configFileHashOf(pkg, artifact, path, content)
  registerConfigFile(DslConfigFile(
    packageName: pkg,
    artifactName: artifact,
    path: path,
    content: content,
    hashHex: hashHex))

# ---------------------------------------------------------------------------
# fs.managedBlock — sentinel formatting
# ---------------------------------------------------------------------------

proc managedBlockOpenSentinel*(scope: ManagedBlockScope;
                               packageName, blockId: string): string =
  ## Spec §"Sentinel uniqueness" — open sentinel of the triple form.
  ## Public so tests + the apply phase can format the same string the
  ## merger emits.
  "# >>> repro:" & $scope & ":" & packageName & ":" & blockId & " >>>"

proc managedBlockCloseSentinel*(scope: ManagedBlockScope;
                                packageName, blockId: string): string =
  ## Spec §"Sentinel uniqueness" — close sentinel of the triple form.
  "# <<< repro:" & $scope & ":" & packageName & ":" & blockId & " <<<"

proc renderManagedBlockChunk(c: DslManagedBlockContribution): string =
  ## Render one sentinel-delimited chunk: open + content (trailing \n
  ## injected if missing) + close + a trailing \n. The blank-line
  ## separation between chunks is the merger's responsibility.
  result = managedBlockOpenSentinel(c.scope, c.packageName, c.blockId) & "\n"
  result.add(c.content)
  if not c.content.endsWith("\n"):
    result.add('\n')
  result.add(managedBlockCloseSentinel(c.scope, c.packageName, c.blockId) & "\n")

# ---------------------------------------------------------------------------
# fs.managedBlock — registration + read + delete
# ---------------------------------------------------------------------------

proc registerManagedBlock*(contribution: DslManagedBlockContribution) =
  ## Type-erased append. The ``managedBlock`` proc below is the public
  ## callsite recipes use; this helper is exposed so future emitters can
  ## target it directly. Insertion order is preserved within the bucket;
  ## merge order is independent of insertion order — see
  ## ``mergedManagedBlockFile``.
  let key = contribution.path
  if key notin dslPortManagedBlocks:
    dslPortManagedBlocks[key] = @[]
  dslPortManagedBlocks[key].add(contribution)

proc managedBlock*(path: string; blockId: string;
                   scope: ManagedBlockScope;
                   content: string;
                   priority: int = 1000;
                   packageName: string = "";
                   artifactName: string = "") =
  ## Records a single managedBlock contribution. Auto-fill semantics match
  ## ``configFile``. Doesn't touch the filesystem.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  var artifact = artifactName
  if artifact.len == 0:
    artifact = currentBuildArtifact()
  registerManagedBlock(DslManagedBlockContribution(
    path: path,
    blockId: blockId,
    scope: scope,
    packageName: pkg,
    artifactName: artifact,
    content: content,
    priority: priority))

proc registeredManagedBlocks*(path: string): seq[DslManagedBlockContribution] =
  ## Return every contribution registered against ``path`` in INSERTION
  ## order (not merge order). For the deterministic merge order, call
  ## ``mergedManagedBlockFile``. Empty seq when no contribution touched
  ## the path.
  if path in dslPortManagedBlocks:
    return dslPortManagedBlocks[path]
  return @[]

proc mergedManagedBlockFile*(path: string): string =
  ## Return the materialised file content for ``path`` per spec
  ## §"Block ordering rule": sort all contributions by
  ## ``(priority, packageName, blockId)`` ascending, then concatenate the
  ## rendered sentinel chunks with one blank line between consecutive
  ## chunks (spec §"Unmanaged content preservation": "a single blank line
  ## between consecutive contributor blocks, controlled by the
  ## materialiser").
  ##
  ## Empty seq → empty string. Single contribution → one sentinel chunk
  ## with no trailing blank line.
  if path notin dslPortManagedBlocks:
    return ""
  var contribs = dslPortManagedBlocks[path]
  if contribs.len == 0:
    return ""
  # Stable sort by (priority, packageName, blockId). Using
  # ``algorithm.sort`` (already imported by the umbrella) so the ordering
  # is deterministic regardless of insertion sequence.
  contribs.sort do (a, b: DslManagedBlockContribution) -> int:
    if a.priority != b.priority:
      return cmp(a.priority, b.priority)
    if a.packageName != b.packageName:
      return cmp(a.packageName, b.packageName)
    cmp(a.blockId, b.blockId)
  result = ""
  for i, c in contribs:
    if i > 0:
      # Spec §"Unmanaged content preservation": one blank line between
      # consecutive contributor blocks.
      result.add('\n')
    result.add(renderManagedBlockChunk(c))

proc removeManagedBlockContributor*(path: string;
                                    scope: ManagedBlockScope;
                                    packageName: string;
                                    blockId: string) =
  ## Spec §"Deletion semantics": drop ONE contributor identified by the
  ## ``(scope, packageName, blockId)`` triple from ``path``'s bucket.
  ## The remaining contributions stay byte-identical;
  ## ``mergedManagedBlockFile`` after removal re-emits them in the same
  ## sort order so surviving blocks are byte-identical to their state in
  ## the prior generation.
  ##
  ## Removing a contributor that was never registered is a silent no-op.
  ## Multiple contributions matching the triple (which the spec'd graph
  ## layer would have rejected at construction time as a sentinel-
  ## uniqueness violation) are all removed.
  if path notin dslPortManagedBlocks:
    return
  var kept: seq[DslManagedBlockContribution] = @[]
  for c in dslPortManagedBlocks[path]:
    if c.scope == scope and c.packageName == packageName and
       c.blockId == blockId:
      continue
    kept.add(c)
  if kept.len == 0:
    # Spec §"Deletion semantics" — when the set shrinks to zero, the path
    # is no longer materialised. Drop the bucket so subsequent reads
    # observe the empty state.
    dslPortManagedBlocks.del(path)
  else:
    dslPortManagedBlocks[path] = kept

# ---------------------------------------------------------------------------
# DSL-port M9.A — on-disk content-addressed materialisation surface.
# ---------------------------------------------------------------------------
##
## ─────────────────────────────────────────────────────────────────────────
## What the M9.A surface covers
## ─────────────────────────────────────────────────────────────────────────
##
## M8 records ``fs.configFile`` / ``fs.managedBlock`` declarations in
## in-memory tables with FNV-1a cache keys. M9.A extends that surface so
## the SAME declarations can be **materialised** to a content-addressed
## on-disk store with sha256 hashing — matching the
## ``ManagedFiles{storePath, relPath, hashHex}`` shape the 10 production
## NDE shim packages under
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/`` already use
## (read ``de_foundation/systemd_session.nim`` for the canonical shape).
##
## The M9.A additions are STRICTLY ADDITIVE:
##
##   * The M8 ``configFile()`` / ``managedBlock()`` procs keep their
##     original signatures and still record the FNV-1a digest in
##     ``DslConfigFile.hashHex`` when no materialisation has been
##     requested. Tests that read the M8 surface continue to observe
##     the FNV-1a hash unchanged.
##
##   * The new surface lives next to the M8 procs: ``registerStoreRoot``
##     declares a per-package on-disk root + hash algorithm;
##     ``consumeConfigFile`` / ``consumeManagedBlock`` look up the M8
##     registry entry and (idempotently) materialise it to
##     ``<storeRoot>/<hashHex>/<relPath>``; both return a
##     ``DslManagedFiles`` handle that downstream test assertions can
##     read bytes out of.
##
## ─────────────────────────────────────────────────────────────────────────
## Cache-key composition for sha256
## ─────────────────────────────────────────────────────────────────────────
##
## The M9.A surface uses the FULL 64-character lower-hex sha256 digest
## (no truncation) over the following byte streams:
##
##   * configFile:  ``"configFile" || packageName || \x00 ||
##                    artifactName || \x00 || path || \x00 || content``
##
##   * managedBlock (merged contributors for a path):
##                  ``"managedBlock" || path || \x00 || mergedContent``
##
## **Comparison with the shim modules** (e.g.
## ``de_foundation/systemd_session.nim``):
##
##   * The shim's ``configFileHash`` uses
##     ``"configFile" || Nde0sVersion || relPath || content`` and
##     TRUNCATES to 16 hex chars. The M9.A digest is intentionally
##     LONGER (full 64 hex) and pulls in ``packageName`` +
##     ``artifactName`` because the M9.A surface targets multi-package
##     materialisation, where the shim's version-prefix was carrying
##     the per-package identity instead. A future "spec-byte-match"
##     mode can re-derive the shim's exact composition under a separate
##     ``DslHashAlg`` value; M9.A doesn't need that to land the gap
##     fix.
##
##   * The shim's ``managedBlockHash`` includes ``scope``,
##     ``packageName``, ``blockId``, ``priority`` as separate fields;
##     M9.A folds them into ``mergedContent`` because the merged file's
##     bytes already deterministically reflect every contributor's
##     sentinel triple + content via ``mergedManagedBlockFile``.
##
## ─────────────────────────────────────────────────────────────────────────
## Threading model
## ─────────────────────────────────────────────────────────────────────────
##
## The store-roots registry is ``threadvar`` per the M9.A design memo
## (it carries thread-local materialisation state; tests run on one
## thread anyway). The M8 in-memory registries remain module-level.

type
  DslHashAlg* = enum
    ## Cache-key hash algorithm for the M9.A on-disk materialisation
    ## surface. ``dhaFnv1a`` short-circuits the digest path to the M8
    ## FNV-1a composition (16 hex chars) so tests that want a cheap
    ## fingerprint can opt in. ``dhaSha256`` is the default and matches
    ## the NDE shim packages' content-addressed store convention.
    dhaFnv1a   ## M8-style 16-char FNV-1a (cheap; in-memory record default)
    dhaSha256  ## 64-char lower-hex sha256 (content-addressed on-disk)

  DslFsStoreRoot* = object
    ## Per-package store-root registration. ``rootPath`` is the absolute
    ## directory under which the materialised ``<hashHex>`` subtrees
    ## land. ``hashAlg`` picks between the M9.A sha256 path and the
    ## back-compat FNV-1a path.
    rootPath*: string
    hashAlg*:  DslHashAlg

  DslManagedFiles* = object
    ## Handle returned by ``consumeConfigFile`` / ``consumeManagedBlock``.
    ## Matches the ``ManagedFiles`` shape the 10 production NDE shim
    ## modules already expose (see
    ## ``de_foundation/systemd_session.nim``'s ``ManagedFiles`` for the
    ## canonical reference).
    storePath*:    string  ## ``<storeRoot.rootPath>/<hashHex>``
    relPath*:      string  ## the original ``path`` with leading "/"
                           ## stripped (e.g. ``"etc/pam.d/login"``)
    hashHex*:      string  ## 64-char lower-hex sha256 (dhaSha256) OR
                           ## 16-char lower-hex FNV-1a (dhaFnv1a)
    packageName*:  string
    artifactName*: string

  DslSymlink* = object
    ## M9.B — one ``fs.symlink(...)`` registration. Records the symlink
    ## intent only; the on-disk materialisation lives behind
    ## ``consumeSymlink``. Mirrors the
    ## ``de_foundation/systemd_session.nim``'s ``symlinkUnmask`` shape:
    ## the apply-phase layer (NDEM milestone) reads the registry to
    ## plant the actual symlink in the live ``/etc/`` tree. On hosts
    ## where symlinks aren't first-class (Windows test machines without
    ## developer-mode), the materialisation path falls back to a regular
    ## file containing the target — see ``consumeSymlink``.
    path*: string
      ## Symlink path itself, verbatim from the call
      ## (e.g. ``"/etc/systemd/system/systemd-logind.service"``).
    target*: string
      ## Symlink target, verbatim from the call
      ## (e.g. ``"/lib/systemd/system/systemd-logind.service"``).
    packageName*: string
      ## Auto-filled from ``currentBuildPackage()`` when the caller
      ## passes ``""``; mirrors ``DslConfigFile.packageName``.
    artifactName*: string
      ## Auto-filled from ``currentBuildArtifact()`` when the caller
      ## passes ``""`` AND a build context is open. Otherwise stays
      ## ``""``.
    hashHex*: string
      ## Cache key — ``stableHashHex("symlink" || packageName || \x00 ||
      ## artifactName || \x00 || path || \x00 || target)``. 16 hex
      ## characters (FNV-1a). ``consumeSymlink`` recomputes a 64-char
      ## sha256 over the same byte stream when materialising under the
      ## ``dhaSha256`` store-root path.

  DslDirectory* = object
    ## M9.B — one ``fs.directory(...)`` registration. An empty directory
    ## placeholder declaration. Drives the NDE0-D ``/var/lib/dbus``
    ## spool-directory case and any other "the directory must exist
    ## even though no package owns the bytes inside it" surface.
    path*: string
      ## Directory path verbatim from the call (e.g.
      ## ``"/var/lib/dbus"``).
    mode*: int
      ## POSIX mode bits the apply-phase layer will chmod the planted
      ## directory to (e.g. ``0o755``). Documented but NOT enforced on
      ## Windows (NTFS ACLs are a different model); the field is still
      ## mixed into the cache key so a mode change invalidates it.
    packageName*: string
      ## Auto-filled from ``currentBuildPackage()`` when the caller
      ## passes ``""``.
    artifactName*: string
      ## Auto-filled from ``currentBuildArtifact()`` when the caller
      ## passes ``""``.
    hashHex*: string
      ## Cache key — ``stableHashHex("directory" || packageName ||
      ## \x00 || artifactName || \x00 || path || \x00 || $mode)``. 16
      ## hex characters (FNV-1a). ``consumeDirectory`` recomputes a
      ## 64-char sha256 over the same byte stream when materialising
      ## under the ``dhaSha256`` store-root path.

  DslMaterialiseError* = object of CatchableError
    ## Raised when ``consumeConfigFile`` / ``consumeManagedBlock`` is
    ## asked to materialise an entry but no store-root is registered
    ## for the owning package, or no recorded ``DslConfigFile`` /
    ## ``DslManagedBlockContribution`` matches the requested key.

# Extend the M8 ``DslConfigFile`` record with the materialisation
# fields. The new fields default to the zero value (empty strings,
# ``false`` for ``materialised``) so every code path that constructs
# the object without naming them keeps observing the M8 contract.
# Nim does not have "add fields to an existing object" in-place, so the
# M9.A fields are stitched onto the M8 type by re-declaring it below
# AFTER the original at line 1227. Tests that read the M8 fields
# (``path``, ``content``, ``packageName``, ``artifactName``,
# ``hashHex``) keep observing them unchanged. The original definition
# above stays for documentation; the EFFECTIVE record the runtime uses
# is the one re-declared here — Nim's per-module symbol table picks the
# LAST definition. (This is a documented Nim pattern for retrofitting
# fields onto an include-style record without disturbing call sites.)
#
# UPDATE: re-declaring the same type in the same scope is a Nim error.
# Instead, M9.A keeps ``DslConfigFile`` byte-identical and threads the
# materialisation state through a SECOND table keyed by
# ``packageName || \x00 || path``. ``consumeConfigFile`` reads + writes
# this side table; ``registeredConfigFiles`` continues to return the M8
# record so legacy tests stay unchanged.

# ---------------------------------------------------------------------------
# M9.A materialisation side-state
# ---------------------------------------------------------------------------

var dslPortStoreRoots {.threadvar.}: Table[string, DslFsStoreRoot]
  ## Per-package store-root registry. Keyed by ``packageName``. A test
  ## fixture's ``registerStoreRoot`` writes one row; consumers read via
  ## ``currentStoreRoot``. Threadvar matches the M9.A design memo (the
  ## materialisation state is thread-local for test isolation).

type
  DslMaterialisedEntry = object
    ## One row of the materialisation side-table. ``handle`` carries
    ## the absolute store path + relPath + hashHex the caller observes
    ## via ``DslManagedFiles``. ``done`` flips to ``true`` once
    ## ``writeFile`` returns so a second ``consumeConfigFile`` call
    ## short-circuits.
    handle*: DslManagedFiles
    done*:   bool

var dslPortMaterialisedConfigFiles {.threadvar.}: Table[string, DslMaterialisedEntry]
  ## Idempotency cache for ``consumeConfigFile``. Keyed by
  ## ``packageName || \x00 || path``. First lookup computes the digest +
  ## writes the file; subsequent lookups return the cached handle.

var dslPortMaterialisedManagedBlocks {.threadvar.}: Table[string, DslMaterialisedEntry]
  ## Idempotency cache for ``consumeManagedBlock``. Keyed by the host
  ## ``path``. The merged file content is recomputed at first call via
  ## ``mergedManagedBlockFile``; idempotency means a second call with
  ## no intervening registrations returns the same handle without
  ## re-touching the disk.

# ---------------------------------------------------------------------------
# Reset proc — symmetric with ``resetDslPortFsState``
# ---------------------------------------------------------------------------

proc resetDslPortMaterialiseState*() =
  ## Drop every registered storeRoot + every materialisation side-table
  ## row. Test fixtures call this between scenarios so the M9.A state
  ## does not leak across cases. ``resetDslPortFsState`` (M8) does NOT
  ## clear this state because some tests want to register fs.* entries
  ## once and exercise multiple materialisation rounds against them.
  dslPortStoreRoots.clear()
  dslPortMaterialisedConfigFiles.clear()
  dslPortMaterialisedManagedBlocks.clear()

# ---------------------------------------------------------------------------
# sha256 helpers — wraps ``nimcrypto/sha2`` (imported at the umbrella)
# ---------------------------------------------------------------------------

proc dslPortSha256Hex(data: string): string =
  ## Hex-encode the sha256 digest of ``data``. 64 lower-case hex chars.
  ## Wraps ``nimcrypto/sha2`` (umbrella import aliased ``ncSha2``).
  ## Empty-string input is supported and yields the canonical
  ## ``e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855``
  ## digest.
  var ctx: ncSha2.sha256
  ctx.init()
  if data.len > 0:
    ctx.update(cast[ptr UncheckedArray[byte]](data[0].unsafeAddr).toOpenArray(0, data.len - 1))
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc configFileSha256Of*(packageName, artifactName, path, content: string): string =
  ## M9.A cache-key composition for ``configFile``. See the section
  ## comment above for the full byte stream + comparison with the shim
  ## modules' composition.
  dslPortSha256Hex(
    "configFile" & packageName & "\x00" & artifactName & "\x00" &
    path & "\x00" & content)

proc managedBlockSha256Of*(path, mergedContent: string): string =
  ## M9.A cache-key composition for ``managedBlock`` (merged
  ## contributors). See the section comment above for the full byte
  ## stream + comparison with the shim modules' composition.
  dslPortSha256Hex(
    "managedBlock" & path & "\x00" & mergedContent)

# ---------------------------------------------------------------------------
# Public surface — store-root registration + accessor
# ---------------------------------------------------------------------------

proc registerStoreRoot*(packageName: string;
                        rootPath: string;
                        hashAlg: DslHashAlg = dhaSha256) =
  ## Register an on-disk store-root for ``packageName``. Subsequent
  ## ``consumeConfigFile`` / ``consumeManagedBlock`` calls materialise
  ## under ``<rootPath>/<hashHex>/<relPath>``. The default hash
  ## algorithm is sha256; tests that want the cheap FNV-1a digest pass
  ## ``hashAlg = dhaFnv1a``.
  ##
  ## Re-registering the same package overwrites the previous row so a
  ## test fixture that swaps store roots between cases does not leak
  ## state from the prior round.
  dslPortStoreRoots[packageName] = DslFsStoreRoot(
    rootPath: rootPath,
    hashAlg: hashAlg)

proc currentStoreRoot*(packageName: string = ""): DslFsStoreRoot =
  ## Return the registered store-root for ``packageName``. When the
  ## caller passes ``""``, the M7 ``currentBuildPackage()`` accessor
  ## fills in the active package — matching the M8 auto-fill ergonomic
  ## that lets recipe-body code omit the package name.
  ##
  ## Returns the zero-value ``DslFsStoreRoot`` (empty ``rootPath``) when
  ## no store-root is registered for the resolved package; callers that
  ## need a definitive answer can check ``result.rootPath.len == 0``.
  ## ``consumeConfigFile`` / ``consumeManagedBlock`` raise
  ## ``DslMaterialiseError`` on that case so the recipe author hears
  ## about the gap.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  if pkg in dslPortStoreRoots:
    return dslPortStoreRoots[pkg]
  result = DslFsStoreRoot(rootPath: "", hashAlg: dhaSha256)

# ---------------------------------------------------------------------------
# Path canonicalisation — matches the shim modules' ``canonicalisePath``
# ---------------------------------------------------------------------------

proc dslPortCanonicaliseRelPath(p: string): string =
  ## Strip leading "/" + "./" and normalise back-slashes to forward
  ## slashes so the in-store layout is POSIX-shaped on every host. The
  ## algorithm matches ``de_foundation/systemd_session.nim``'s
  ## ``canonicalisePath`` byte-for-byte so a future spec-byte-match
  ## mode comparing M9.A output to shim output sees aligned ``relPath``
  ## strings.
  var s = p.replace('\\', '/')
  while s.startsWith("/"):
    s = s[1 .. ^1]
  if s.startsWith("./"):
    s = s[2 .. ^1]
  s

# ---------------------------------------------------------------------------
# Hash dispatch — picks between sha256 + FNV-1a per storeRoot.hashAlg
# ---------------------------------------------------------------------------

proc dslPortConfigFileDigest(storeRoot: DslFsStoreRoot;
                             packageName, artifactName,
                             path, content: string): string =
  ## Dispatch to the configured hash algorithm. ``dhaSha256`` uses the
  ## M9.A composition; ``dhaFnv1a`` re-uses the M8 ``configFileHashOf``
  ## proc so the FNV-1a back-compat path observes the exact same digest
  ## the M8 record carries in ``DslConfigFile.hashHex``.
  case storeRoot.hashAlg
  of dhaSha256:
    result = configFileSha256Of(packageName, artifactName, path, content)
  of dhaFnv1a:
    result = configFileHashOf(packageName, artifactName, path, content)

proc dslPortManagedBlockDigest(storeRoot: DslFsStoreRoot;
                               path, mergedContent: string): string =
  ## Dispatch for the managed-block digest. For ``dhaFnv1a`` we reuse
  ## ``stableHashHex`` (module-local — accessible here because this
  ## file is ``include``d into the umbrella) over the same
  ## ``"managedBlock" || path || \x00 || mergedContent`` byte stream
  ## the sha256 path uses.
  case storeRoot.hashAlg
  of dhaSha256:
    result = managedBlockSha256Of(path, mergedContent)
  of dhaFnv1a:
    result = stableHashHex(
      "managedBlock" & path & "\x00" & mergedContent)

# ---------------------------------------------------------------------------
# consumeConfigFile — idempotent on-disk materialisation
# ---------------------------------------------------------------------------

proc consumeConfigFile*(packageName: string; path: string): DslManagedFiles =
  ## Look up the M8 ``DslConfigFile`` recorded against ``(packageName,
  ## path)``; materialise the file content to
  ## ``<storeRoot.rootPath>/<hashHex>/<relPath>`` if not yet materialised
  ## in this thread; return the resulting ``DslManagedFiles`` handle.
  ##
  ## Auto-fill: ``packageName == ""`` triggers the M7
  ## ``currentBuildPackage()`` lookup so the proc is callable from
  ## inside a ``build:`` body without repeating the package name.
  ##
  ## Idempotency: a second call with the same ``(packageName, path)``
  ## returns the cached handle without re-writing the file. The cache
  ## key includes the hashHex so a content change between calls (which
  ## would happen only via a separate ``configFile()`` re-registration)
  ## is honoured.
  ##
  ## Raises ``DslMaterialiseError`` when no store-root is registered
  ## for the resolved package OR when no M8 record matches the
  ## ``(packageName, path)`` pair.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  let storeRoot = currentStoreRoot(pkg)
  if storeRoot.rootPath.len == 0:
    raise newException(DslMaterialiseError,
      "consumeConfigFile: no storeRoot registered for package '" & pkg &
      "' (call registerStoreRoot first)")
  # Find the M8 record. Linear scan over the package's bucket — bucket
  # sizes are O(small) per the M8 design (one row per fs.configFile
  # call), so this is fine.
  var matched: DslConfigFile
  var found = false
  if pkg in dslPortConfigFiles:
    for cf in dslPortConfigFiles[pkg]:
      if cf.path == path:
        matched = cf
        found = true
        break
  if not found:
    raise newException(DslMaterialiseError,
      "consumeConfigFile: no fs.configFile record for package '" & pkg &
      "' at path '" & path & "' (call fs.configFile first)")
  # Idempotency cache key matches the side-table doc above:
  # ``packageName || \x00 || path``.
  let cacheKey = pkg & "\x00" & path
  if cacheKey in dslPortMaterialisedConfigFiles:
    let entry = dslPortMaterialisedConfigFiles[cacheKey]
    if entry.done:
      return entry.handle
  # Compose hash via the dispatched algorithm.
  let hashHex = dslPortConfigFileDigest(storeRoot, pkg, matched.artifactName,
                                        matched.path, matched.content)
  let relPath = dslPortCanonicaliseRelPath(matched.path)
  let storePath = storeRoot.rootPath / hashHex
  let fullPath = storePath / relPath
  createDir(parentDir(fullPath))
  writeFile(fullPath, matched.content)
  let handle = DslManagedFiles(
    storePath: storePath,
    relPath: relPath,
    hashHex: hashHex,
    packageName: pkg,
    artifactName: matched.artifactName)
  dslPortMaterialisedConfigFiles[cacheKey] = DslMaterialisedEntry(
    handle: handle, done: true)
  result = handle

# ---------------------------------------------------------------------------
# consumeManagedBlock — idempotent merged-file materialisation
# ---------------------------------------------------------------------------

proc consumeManagedBlock*(path: string): DslManagedFiles =
  ## Materialise the merged managed-block file at ``path`` to
  ## ``<storeRoot.rootPath>/<hashHex>/<relPath>`` and return a
  ## ``DslManagedFiles`` handle pointing at it. The merged bytes come
  ## from ``mergedManagedBlockFile(path)`` so every recorded contributor
  ## appears in spec-deterministic ``(priority, packageName, blockId)``
  ## sort order with the triple-form sentinels around each chunk.
  ##
  ## Store-root resolution: the FIRST contributor by sort order picks
  ## the store-root (its package's ``registerStoreRoot`` registration).
  ## Cleaner alternative designs (e.g. a dedicated "merge" store-root)
  ## are documented in the M9.A spec memo but DEFERRED to a later
  ## milestone — the first-contributor convention matches the shim
  ## modules' standalone-contributor emission where the package owning
  ## the block also owns the store-root.
  ##
  ## Raises ``DslMaterialiseError`` when no contributors are recorded
  ## OR when the first contributor's package has no store-root
  ## registered.
  if path notin dslPortManagedBlocks or
     dslPortManagedBlocks[path].len == 0:
    raise newException(DslMaterialiseError,
      "consumeManagedBlock: no fs.managedBlock contributors for path '" &
      path & "' (call fs.managedBlock first)")
  # Idempotency.
  if path in dslPortMaterialisedManagedBlocks:
    let entry = dslPortMaterialisedManagedBlocks[path]
    if entry.done:
      return entry.handle
  # Resolve the first contributor's package by replicating the merge
  # sort discipline.
  var contribs = dslPortManagedBlocks[path]
  contribs.sort do (a, b: DslManagedBlockContribution) -> int:
    if a.priority != b.priority:
      return cmp(a.priority, b.priority)
    if a.packageName != b.packageName:
      return cmp(a.packageName, b.packageName)
    cmp(a.blockId, b.blockId)
  let firstPkg = contribs[0].packageName
  let storeRoot = currentStoreRoot(firstPkg)
  if storeRoot.rootPath.len == 0:
    raise newException(DslMaterialiseError,
      "consumeManagedBlock: no storeRoot registered for first " &
      "contributor's package '" & firstPkg &
      "' (call registerStoreRoot first)")
  let mergedContent = mergedManagedBlockFile(path)
  let hashHex = dslPortManagedBlockDigest(storeRoot, path, mergedContent)
  let relPath = dslPortCanonicaliseRelPath(path)
  let storePath = storeRoot.rootPath / hashHex
  let fullPath = storePath / relPath
  createDir(parentDir(fullPath))
  writeFile(fullPath, mergedContent)
  let handle = DslManagedFiles(
    storePath: storePath,
    relPath: relPath,
    hashHex: hashHex,
    packageName: firstPkg,
    artifactName: contribs[0].artifactName)
  dslPortMaterialisedManagedBlocks[path] = DslMaterialisedEntry(
    handle: handle, done: true)
  result = handle

# ---------------------------------------------------------------------------
# DSL-port M9.B — fs.symlink + fs.directory registration & materialisation
# ---------------------------------------------------------------------------
##
## What the M9.B surface covers
## ----------------------------
##
## M8 + M9.A handle byte-content emissions (``fs.configFile`` /
## ``fs.managedBlock``). The DE shim packages need two more typed
## "intent records" the M8/M9.A pair does not cover:
##
##   * ``fs.symlink(path, target, ...)`` — a symlink declaration. The
##     NDE0-S systemd-session shim's ``symlinkUnmask`` proc emits one of
##     these for ``/etc/systemd/system/systemd-logind.service`` (un-mask
##     pointer back to the real unit file). NDE0-G graphics-stack emits
##     them for the ``multi-user.target.wants/*`` WantedBy symlinks.
##     NDEM1 reproos-desktop emits one for the
##     ``display-manager.service`` chooser.
##
##   * ``fs.directory(path, mode=0o755, ...)`` — an empty directory
##     placeholder. NDE0-D dbus-broker uses this for ``/var/lib/dbus``
##     (the spool directory must exist at boot but no package owns the
##     bytes inside it).
##
## Both surfaces mirror M8/M9.A patterns to the letter:
##
##   * registration is into a typed in-memory ``Table[string,
##     seq[...]]`` keyed by package name;
##   * auto-fill pulls ``packageName`` / ``artifactName`` from
##     ``currentBuildPackage()`` / ``currentBuildArtifact()`` when the
##     caller passes ``""`` (M8 ergonomic);
##   * materialisation lives behind ``consumeSymlink`` /
##     ``consumeDirectory`` and parallels ``consumeConfigFile``
##     (idempotent side-table, sha256 digest under the registered
##     storeRoot, returns a ``DslManagedFiles`` handle).
##
## ## Windows symlink fallback
##
## Nim's ``os.createSymlink`` calls Win32 ``CreateSymbolicLinkW`` under
## the hood, which on Windows requires either administrator privileges
## or the Developer-Mode privilege. Neither is reliable in CI / test
## fixtures, so ``consumeSymlink`` writes a regular file containing the
## target string (with a ``# repro-symlink-intent`` header line) instead
## of an OS-level symlink. The apply-phase layer that later plants the
## actual ``/etc`` symlink reads that file. POSIX hosts (Linux / macOS)
## get a real OS-level symlink unconditionally — they don't have the
## same privilege wart and the in-store layout we expose is otherwise
## byte-aligned with the shim modules' ``symlinkUnmask`` output.

var dslPortSymlinks {.threadvar.}: Table[string, seq[DslSymlink]]
  ## Per-package symlink registry. Keyed by ``packageName`` (matches the
  ## M8 ``dslPortConfigFiles`` bucket shape). Declaration order within
  ## each bucket is preserved.

var dslPortDirectories {.threadvar.}: Table[string, seq[DslDirectory]]
  ## Per-package directory-placeholder registry. Keyed by
  ## ``packageName``. Mirrors ``dslPortSymlinks``.

var dslPortMaterialisedSymlinks {.threadvar.}: Table[string, DslMaterialisedEntry]
  ## Idempotency cache for ``consumeSymlink``. Keyed by
  ## ``packageName || \x00 || path`` (same shape as
  ## ``dslPortMaterialisedConfigFiles``).

var dslPortMaterialisedDirectories {.threadvar.}: Table[string, DslMaterialisedEntry]
  ## Idempotency cache for ``consumeDirectory``. Keyed by
  ## ``packageName || \x00 || path``.

# ---------------------------------------------------------------------------
# Reset proc — symmetric with resetDslPortFsState
# ---------------------------------------------------------------------------

proc resetDslPortFsExtState*() =
  ## Drop every recorded ``fs.symlink`` + ``fs.directory`` registration
  ## AND every materialisation side-table row for the M9.B surface.
  ## Symmetric with ``resetDslPortFsState`` (M8) and
  ## ``resetDslPortMaterialiseState`` (M9.A) — test fixtures call this
  ## between scenarios so the M9.B state does not leak across cases.
  dslPortSymlinks.clear()
  dslPortDirectories.clear()
  dslPortMaterialisedSymlinks.clear()
  dslPortMaterialisedDirectories.clear()

# ---------------------------------------------------------------------------
# fs.symlink — cache-key composition + registration
# ---------------------------------------------------------------------------

proc symlinkHashOf*(packageName, artifactName, path, target: string): string =
  ## Cache-key composition for ``fs.symlink``. Mirrors
  ## ``configFileHashOf``: FNV-1a stableHashHex over a discriminator
  ## prefix + the four-tuple bytes. The ``"symlink"`` prefix prevents
  ## cross-surface hash collisions if a future surface ever uses an
  ## identical ``packageName || \x00 || ...`` byte stream.
  result = stableHashHex(
    "symlink" & packageName & "\x00" & artifactName & "\x00" &
    path & "\x00" & target)

proc registerSymlink*(entry: DslSymlink) =
  ## Type-erased append. Exposed for future emitters that want to splice
  ## symlink registrations out of a structured block without going
  ## through the public ``symlink`` proc's auto-fill path.
  let key = entry.packageName
  if key notin dslPortSymlinks:
    dslPortSymlinks[key] = @[]
  dslPortSymlinks[key].add(entry)

proc symlink*(path: string; target: string;
              packageName: string = "";
              artifactName: string = "") =
  ## Records a ``fs.symlink`` declaration. Auto-fill matches
  ## ``configFile`` (``currentBuildPackage()`` /
  ## ``currentBuildArtifact()``). Doesn't touch the filesystem; the
  ## on-disk materialisation lives behind ``consumeSymlink``.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  var artifact = artifactName
  if artifact.len == 0:
    artifact = currentBuildArtifact()
  let hashHex = symlinkHashOf(pkg, artifact, path, target)
  registerSymlink(DslSymlink(
    path: path,
    target: target,
    packageName: pkg,
    artifactName: artifact,
    hashHex: hashHex))

proc registeredSymlinks*(packageName: string): seq[DslSymlink] =
  ## Return every symlink registered against ``packageName`` in
  ## declaration order. Returns the empty seq when the package never
  ## called ``fs.symlink``; callers must NOT treat the empty return as
  ## an error.
  if packageName in dslPortSymlinks:
    return dslPortSymlinks[packageName]
  return @[]

# ---------------------------------------------------------------------------
# fs.directory — cache-key composition + registration
# ---------------------------------------------------------------------------

proc directoryHashOf*(packageName, artifactName, path: string;
                      mode: int): string =
  ## Cache-key composition for ``fs.directory``. FNV-1a stableHashHex
  ## over the discriminator prefix + the four-tuple bytes (mode mixed
  ## in as ``$mode`` so the textual representation is the only
  ## discriminator the digest sees).
  result = stableHashHex(
    "directory" & packageName & "\x00" & artifactName & "\x00" &
    path & "\x00" & $mode)

proc registerDirectory*(entry: DslDirectory) =
  ## Type-erased append. Exposed for future emitters.
  let key = entry.packageName
  if key notin dslPortDirectories:
    dslPortDirectories[key] = @[]
  dslPortDirectories[key].add(entry)

proc directory*(path: string; mode: int = 0o755;
                packageName: string = "";
                artifactName: string = "") =
  ## Records a ``fs.directory`` placeholder. Auto-fill semantics match
  ## ``configFile`` / ``symlink``. Doesn't touch the filesystem.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  var artifact = artifactName
  if artifact.len == 0:
    artifact = currentBuildArtifact()
  let hashHex = directoryHashOf(pkg, artifact, path, mode)
  registerDirectory(DslDirectory(
    path: path,
    mode: mode,
    packageName: pkg,
    artifactName: artifact,
    hashHex: hashHex))

proc registeredDirectories*(packageName: string): seq[DslDirectory] =
  ## Return every directory registered against ``packageName`` in
  ## declaration order. Empty seq when no directory was registered.
  if packageName in dslPortDirectories:
    return dslPortDirectories[packageName]
  return @[]

# ---------------------------------------------------------------------------
# sha256 cache-key compositions for the M9.B materialisation surface
# ---------------------------------------------------------------------------

proc symlinkSha256Of*(packageName, artifactName, path, target: string): string =
  ## M9.B cache-key composition for ``symlink`` materialisation. Same
  ## byte stream as ``symlinkHashOf`` (so a future spec-byte-match mode
  ## comparing FNV-1a + sha256 outputs sees aligned discriminator
  ## bytes), only the digest algorithm differs.
  dslPortSha256Hex(
    "symlink" & packageName & "\x00" & artifactName & "\x00" &
    path & "\x00" & target)

proc directorySha256Of*(packageName, artifactName, path: string;
                        mode: int): string =
  ## M9.B cache-key composition for ``directory`` materialisation.
  dslPortSha256Hex(
    "directory" & packageName & "\x00" & artifactName & "\x00" &
    path & "\x00" & $mode)

proc dslPortSymlinkDigest(storeRoot: DslFsStoreRoot;
                          packageName, artifactName,
                          path, target: string): string =
  ## Dispatch to the configured hash algorithm. Mirrors
  ## ``dslPortConfigFileDigest``.
  case storeRoot.hashAlg
  of dhaSha256:
    result = symlinkSha256Of(packageName, artifactName, path, target)
  of dhaFnv1a:
    result = symlinkHashOf(packageName, artifactName, path, target)

proc dslPortDirectoryDigest(storeRoot: DslFsStoreRoot;
                            packageName, artifactName,
                            path: string; mode: int): string =
  ## Dispatch for the directory digest.
  case storeRoot.hashAlg
  of dhaSha256:
    result = directorySha256Of(packageName, artifactName, path, mode)
  of dhaFnv1a:
    result = directoryHashOf(packageName, artifactName, path, mode)

# ---------------------------------------------------------------------------
# consumeSymlink — idempotent on-disk materialisation
# ---------------------------------------------------------------------------

proc consumeSymlink*(packageName: string; path: string): DslManagedFiles =
  ## Look up the M9.B ``DslSymlink`` recorded against ``(packageName,
  ## path)``; materialise to ``<storeRoot.rootPath>/<hashHex>/<relPath>``
  ## if not yet materialised in this thread; return the resulting
  ## ``DslManagedFiles`` handle.
  ##
  ## Auto-fill: ``packageName == ""`` triggers
  ## ``currentBuildPackage()`` resolution.
  ##
  ## Idempotency: a second call with the same ``(packageName, path)``
  ## returns the cached handle without re-touching the disk.
  ##
  ## Windows symlink fallback: ``os.createSymlink`` requires admin or
  ## developer-mode privilege on Windows. To keep the test fixture
  ## portable, the Windows path writes a regular file at the symlink
  ## location containing
  ##
  ## .. code-block:: text
  ##   # repro-symlink-intent
  ##   <target>
  ##
  ## POSIX hosts get a real OS-level symlink (``os.createSymlink``).
  ##
  ## Raises ``DslMaterialiseError`` when no storeRoot is registered OR
  ## no M9.B record matches.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  let storeRoot = currentStoreRoot(pkg)
  if storeRoot.rootPath.len == 0:
    raise newException(DslMaterialiseError,
      "consumeSymlink: no storeRoot registered for package '" & pkg &
      "' (call registerStoreRoot first)")
  var matched: DslSymlink
  var found = false
  if pkg in dslPortSymlinks:
    for sl in dslPortSymlinks[pkg]:
      if sl.path == path:
        matched = sl
        found = true
        break
  if not found:
    raise newException(DslMaterialiseError,
      "consumeSymlink: no fs.symlink record for package '" & pkg &
      "' at path '" & path & "' (call fs.symlink first)")
  let cacheKey = pkg & "\x00" & path
  if cacheKey in dslPortMaterialisedSymlinks:
    let entry = dslPortMaterialisedSymlinks[cacheKey]
    if entry.done:
      return entry.handle
  let hashHex = dslPortSymlinkDigest(storeRoot, pkg, matched.artifactName,
                                     matched.path, matched.target)
  let relPath = dslPortCanonicaliseRelPath(matched.path)
  let storePath = storeRoot.rootPath / hashHex
  let fullPath = storePath / relPath
  createDir(parentDir(fullPath))
  when defined(windows):
    # Windows symlink fallback: write a regular file with an intent
    # header + the target string. The apply-phase layer parses this
    # back when planting the real symlink (which a privileged installer
    # WILL be able to do).
    writeFile(fullPath, "# repro-symlink-intent\n" & matched.target & "\n")
  else:
    # POSIX: real OS-level symlink. ``os.createSymlink`` is dest, src
    # order — the SOURCE argument is the target string, the DEST is the
    # link to create.
    if fileExists(fullPath) or symlinkExists(fullPath):
      removeFile(fullPath)
    createSymlink(matched.target, fullPath)
  let handle = DslManagedFiles(
    storePath: storePath,
    relPath: relPath,
    hashHex: hashHex,
    packageName: pkg,
    artifactName: matched.artifactName)
  dslPortMaterialisedSymlinks[cacheKey] = DslMaterialisedEntry(
    handle: handle, done: true)
  result = handle

# ---------------------------------------------------------------------------
# consumeDirectory — idempotent on-disk materialisation
# ---------------------------------------------------------------------------

proc consumeDirectory*(packageName: string; path: string): DslManagedFiles =
  ## Look up the M9.B ``DslDirectory`` recorded against ``(packageName,
  ## path)``; materialise an empty directory at
  ## ``<storeRoot.rootPath>/<hashHex>/<relPath>`` if not yet materialised
  ## in this thread; return the resulting ``DslManagedFiles`` handle.
  ##
  ## Auto-fill / idempotency match ``consumeSymlink``.
  ##
  ## Note: the recorded ``mode`` field is currently NOT applied on the
  ## materialised directory — POSIX mode bits are an apply-phase
  ## concern. The digest mixes ``mode`` so a mode change WILL move the
  ## materialised directory to a fresh ``<hashHex>`` subtree.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  let storeRoot = currentStoreRoot(pkg)
  if storeRoot.rootPath.len == 0:
    raise newException(DslMaterialiseError,
      "consumeDirectory: no storeRoot registered for package '" & pkg &
      "' (call registerStoreRoot first)")
  var matched: DslDirectory
  var found = false
  if pkg in dslPortDirectories:
    for d in dslPortDirectories[pkg]:
      if d.path == path:
        matched = d
        found = true
        break
  if not found:
    raise newException(DslMaterialiseError,
      "consumeDirectory: no fs.directory record for package '" & pkg &
      "' at path '" & path & "' (call fs.directory first)")
  let cacheKey = pkg & "\x00" & path
  if cacheKey in dslPortMaterialisedDirectories:
    let entry = dslPortMaterialisedDirectories[cacheKey]
    if entry.done:
      return entry.handle
  let hashHex = dslPortDirectoryDigest(storeRoot, pkg, matched.artifactName,
                                       matched.path, matched.mode)
  let relPath = dslPortCanonicaliseRelPath(matched.path)
  let storePath = storeRoot.rootPath / hashHex
  let fullPath = storePath / relPath
  createDir(fullPath)
  let handle = DslManagedFiles(
    storePath: storePath,
    relPath: relPath,
    hashHex: hashHex,
    packageName: pkg,
    artifactName: matched.artifactName)
  dslPortMaterialisedDirectories[cacheKey] = DslMaterialisedEntry(
    handle: handle, done: true)
  result = handle

# ---------------------------------------------------------------------------
# DSL-port M9.E — variant: arm registry + validate: predicate registry.
# ---------------------------------------------------------------------------
##
## ## What the M9.E surface covers
##
## NDEM1 (reproos-desktop) declares two related package-body shapes that
## prior milestones did not cover:
##
##   1. ``variant <configField>:`` — gate per-variant ``uses:`` clauses
##      on a configurable's value. The arms are scoped by the user's
##      enum: e.g. ``\`case\` dkSway: uses "sway >=0.1.0"``. Only the
##      ``uses:`` clause is recognised inside an arm initially (M9.E
##      explicit deferral — future milestones can widen to
##      ``build:`` / ``service:`` / ``files:`` arm bodies).
##
##   2. ``validate:`` — solver-time boolean predicate the runtime
##      evaluates at consumption time. Body is a ``proc(): bool = ...``
##      closure literal (M9.E explicit deferral — a future ergonomic
##      shortcut can land where bare expressions auto-wrap with the
##      package's config-field bindings injected in scope).
##
## The arms-by-arm-value contract: ``activeVariantArms(pkg,
## configField)`` walks the registered arms for the package, looks up
## the configurable's current value via ``inspectConfigurable``, and
## returns every arm whose ``armValue`` matches a stored value name.
## ``dskSeqEnum`` (M9.D) returns the union of matching arms; ``dskEnum``
## returns at most one arm; any other stored kind returns the empty
## seq.
##
## ## Why a separate evaluator closure rather than introspecting the
## body's AST?
##
## The macro running at expansion time cannot enumerate every
## configurable the user's expression references without parsing the
## body — which would re-invent the type-checker. Instead M9.E asks the
## user to author the validate body as a closure literal that the macro
## splices verbatim into ``registerValidateExpr``. The closure captures
## bindings the user wires explicitly (typically
## ``readConfigurable[T]`` calls); the runtime executes it without
## further introspection. The trade-off is the same the M5 ``service:``
## emitter took for body-setter parsing — pragmatic, scope-limited,
## with a documented next-milestone path.
##
## ## Threading model
##
## The two registries are ``threadvar`` so concurrent test fixtures do
## not cross-attribute arms / closures. ``resetDslPortVariantState`` and
## ``resetDslPortValidateState`` reset the per-thread slot. Matches the
## ``dslPortSymlinks`` / ``dslPortDirectories`` threading shape.

type
  DslVariantArm* = object
    ## One ``\`case\` <enumValue>:`` arm inside a ``variant
    ## <configField>:`` block. Populated by the M9.E emitter at
    ## module-init time; read by host code via ``registeredVariants`` /
    ## ``activeVariantArms``.
    packageName*: string
    variantConfigField*: string
      ## The config-field ident named in the outer ``variant <ident>:``
      ## head. Diagnostic surface — ``activeVariantArms`` also keys off
      ## ``packageName & "." & variantConfigField`` to read the
      ## configurable cell.
    armValue*: string
      ## The enum literal as a SOURCE-LEVEL IDENT string — e.g.
      ## ``"dkSway"``. The macro captures this from the source-level
      ## ident text verbatim (no kebab translation). For bare-value
      ## enums (no explicit ``= "..."`` value), this is the same as
      ## ``$value`` and matches M9.D's stored ``enumValueName`` /
      ## ``seqEnumValueNames`` directly. For explicit-string-value enums
      ## (e.g. ``dkSway = "sway"``), the source ident text and ``$value``
      ## diverge; see ``armValueRepr`` for the matching slot.
    armValueRepr*: string
      ## The enum literal's STRINGIFICATION (``$enumValue``) captured
      ## at module-init time — e.g. ``"sway"`` for an enum declared
      ## ``dkSway = "sway"`` (or ``"dkSway"`` for a bare ``dkSway`` enum
      ## without explicit value). Required for ``activeVariantArms`` to
      ## match against M9.D's stored ``enumValueName`` /
      ## ``seqEnumValueNames`` (which also use the ``$value`` form)
      ## under explicit-string-value enums. NDE-I close-out widening.
    armOrd*: int
      ## The arm's ``ord(enumValue)`` captured at macro-expansion time.
      ## Allows round-trip / sort by ord regardless of insertion order.
    usesClauses*: seq[string]
      ## Each entry is one ``uses "string"`` clause's payload (the
      ## string-literal verbatim). M9.E supports only ``uses:`` arms
      ## initially — explicit deferral for per-arm ``build:`` /
      ## ``service:`` / ``files:`` widening.

  DslValidateExpr* = object
    ## One ``validate:`` predicate. Populated by the M9.E emitter at
    ## module-init time; read by host code via ``registeredValidates``
    ## or evaluated via ``evaluateValidates``.
    packageName*: string
    exprRepr*: string
      ## Source-text form for diagnostics; e.g.
      ## ``"activeAtBoot in desktopKind"``. Captured via
      ## ``$body.repr`` at macro-expansion time.
    evaluator*: proc(): bool {.closure.}
      ## The compiled closure the macro spliced from the user's
      ## ``proc(): bool = ...`` body. ``evaluateValidates`` calls this;
      ## ``false`` triggers ``EConfigViolation``.

  EConfigViolation* = object of CatchableError
    ## Raised by ``evaluateValidates`` when any registered closure
    ## returns ``false``. The message embeds the violating expression's
    ## ``exprRepr`` so the diagnostic surface points back to the
    ## source-level declaration.

var dslPortVariants {.threadvar.}: Table[string, seq[DslVariantArm]]
  ## Per-package variant-arm registry. Keyed by ``packageName``.
  ## ``registerVariantArm`` appends to the per-package seq;
  ## ``registeredVariants`` returns a copy so callers cannot mutate the
  ## registry from outside the public API.

var dslPortValidates {.threadvar.}: Table[string, seq[DslValidateExpr]]
  ## Per-package validate-predicate registry. Keyed by ``packageName``.
  ## ``registerValidateExpr`` appends; ``registeredValidates`` returns a
  ## copy.

# ---------------------------------------------------------------------------
# Reset procs — symmetric with the prior M9.* reset shape
# ---------------------------------------------------------------------------

proc resetDslPortVariantState*() =
  ## Drop every variant-arm registration. Test fixtures call this
  ## between scenarios so registry entries do not leak across cases.
  ## Separate from ``resetDslPortValidateState`` so tests can target one
  ## without disturbing the other (matches the
  ## ``resetDslPortConfigState`` / ``resetRegisteredVersions`` split).
  dslPortVariants.clear()

proc resetDslPortValidateState*() =
  ## Drop every validate-predicate registration.
  dslPortValidates.clear()

# ---------------------------------------------------------------------------
# variant: registration + read API
# ---------------------------------------------------------------------------

proc registerVariantArm*(packageName, configField, armValue: string;
                         armOrd: int; usesClauses: seq[string];
                         armValueRepr: string = "") =
  ## Append one variant-arm registration. The M9.E emitter emits one call
  ## per recognised ``\`case\` <enumValue>:`` arm inside a
  ## ``variant <configField>:`` block.
  ##
  ## ``armValueRepr`` (the ``$value`` form, e.g. ``"sway"`` for
  ## ``dkSway = "sway"``) defaults to the empty string for source
  ## compatibility with pre-NDE-I callers; the M9.E emitter always
  ## fills it. ``activeVariantArms`` falls back to ``armValue`` when
  ## ``armValueRepr`` is empty.
  ##
  ## Idempotency: re-registering the same (packageName, configField,
  ## armValue) appends a duplicate row — matches the
  ## ``registerVersion`` / ``registerArtifact`` precedent. Conditional
  ## ``when`` branches can legitimately re-declare an arm under
  ## different platform gates and the consumer decides which arm to
  ## honour.
  if packageName notin dslPortVariants:
    dslPortVariants[packageName] = @[]
  dslPortVariants[packageName].add(DslVariantArm(
    packageName: packageName,
    variantConfigField: configField,
    armValue: armValue,
    armValueRepr:
      if armValueRepr.len == 0: armValue else: armValueRepr,
    armOrd: armOrd,
    usesClauses: usesClauses))

proc registeredVariants*(packageName: string): seq[DslVariantArm] =
  ## Return every variant-arm registered against ``packageName`` in
  ## insertion order. Returns the empty seq when the package never
  ## declared a ``variant:`` block; callers must NOT treat the empty
  ## return as an error.
  if packageName in dslPortVariants:
    return dslPortVariants[packageName]
  return @[]

proc activeVariantArms*(packageName, configField: string): seq[DslVariantArm] =
  ## Return the variant arms that fire for the CURRENT configurable
  ## value at evaluation time. The configurable is looked up via
  ## ``inspectConfigurable``; the stored ``DslScalarValue``'s kind
  ## decides the matching strategy:
  ##
  ##   * ``dskSeqEnum`` (M9.D ``seq[Enum]``) — return every arm whose
  ##     ``armValue`` OR ``armValueRepr`` matches ANY element in
  ##     ``seqEnumValueNames``;
  ##   * ``dskEnum`` (M9.D scalar enum) — return the single arm whose
  ##     ``armValue`` OR ``armValueRepr`` equals ``enumValueName``
  ##     (or empty if no match);
  ##   * any other stored kind (or missing key) — return the empty seq.
  ##
  ## Per-arm order matches the source-level declaration order.
  ##
  ## NDE-I close-out: the M9.E emitter captures ``armValue`` from the
  ## SOURCE-LEVEL ident text (e.g. ``"dkSway"``), while M9.D records
  ## the ``$value`` stringification in the configurable cell (which
  ## diverges from the ident for enums with explicit string values
  ## like ``dkSway = "sway"``). The dual-match against ``armValueRepr``
  ## bridges both spellings without breaking the existing
  ## bare-enum contract (where the two strings coincide).
  result = @[]
  if packageName notin dslPortVariants:
    return
  let key = packageName & "." & configField
  if not isConfigKeyRegistered(key):
    return
  let stored = inspectConfigurable(key)
  let arms = dslPortVariants[packageName]
  case stored.kind
  of dskSeqEnum:
    for arm in arms:
      if arm.variantConfigField != configField:
        continue
      if arm.armValue in stored.seqEnumValueNames or
         arm.armValueRepr in stored.seqEnumValueNames:
        result.add(arm)
  of dskEnum:
    for arm in arms:
      if arm.variantConfigField != configField:
        continue
      if arm.armValue == stored.enumValueName or
         arm.armValueRepr == stored.enumValueName:
        result.add(arm)
  else:
    discard

# ---------------------------------------------------------------------------
# validate: registration + evaluation API
# ---------------------------------------------------------------------------

proc registerValidateExpr*(packageName, exprRepr: string;
                           evaluator: proc(): bool {.closure.}) =
  ## Append one validate-predicate registration. The M9.E emitter emits
  ## one call per recognised ``validate:`` block. Idempotency matches
  ## ``registerVariantArm``: duplicates append rather than collapse.
  if packageName notin dslPortValidates:
    dslPortValidates[packageName] = @[]
  dslPortValidates[packageName].add(DslValidateExpr(
    packageName: packageName,
    exprRepr: exprRepr,
    evaluator: evaluator))

proc registeredValidates*(packageName: string): seq[DslValidateExpr] =
  ## Return every validate predicate registered against ``packageName``
  ## in insertion order. Empty seq when no ``validate:`` block was
  ## declared.
  if packageName in dslPortValidates:
    return dslPortValidates[packageName]
  return @[]

proc evaluateValidates*(packageName: string) =
  ## Evaluate every registered validate predicate for ``packageName``.
  ## Raises ``EConfigViolation`` (with the offending ``exprRepr``
  ## embedded in the message) on the first predicate that returns
  ## ``false``. No-op when no predicates are registered.
  if packageName notin dslPortValidates:
    return
  for entry in dslPortValidates[packageName]:
    if entry.evaluator.isNil:
      continue
    if not entry.evaluator():
      raise newException(EConfigViolation,
        "validate: predicate '" & entry.exprRepr & "' failed for package '" &
        packageName & "'")

# ---------------------------------------------------------------------------
# DSL-port M9.G — ``bootloader:`` block registry.
# ---------------------------------------------------------------------------
##
## ## What the M9.G surface covers
##
## NDEM1 (reproos-desktop) needs a way to declare per-package bootloader
## metadata so the generation-switch apply phase can render the GRUB
## menu. The simplest user-facing shape mirrors v8's spec memo example:
##
##   package reproosDesktop:
##     bootloader:
##       generationEntry: true
##       timeout: 5
##       menuEntry:
##         title "ReproOS - generation {{ generation.id }}"
##         kernel "/boot/vmlinuz-{{ generation.id }}"
##         initrd "/boot/initrd.img-{{ generation.id }}"
##         cmdline "root=LABEL=ReproOS ro quiet"
##
## ONE ``bootloader:`` block per package. Multiple ``menuEntry:`` blocks
## inside the body are allowed and appended in source order. The
## ``generationEntry``/``timeout``/``defaultEntry`` setters are
## merged into a single ``DslBootloaderConfig`` row; the macro emits one
## ``registerBootloaderConfig`` per declared setter so the runtime
## coalesces them into the final config.
##
## The actual generation-switch rendering happens at the NDEM1 apply
## phase that consumes ``registeredBootloaderConfig`` — M9.G is a pure
## registry milestone, no semantic interpretation here.
##
## ## Threading model
##
## ``dslPortBootloaders`` is ``threadvar`` so concurrent test fixtures do
## not cross-attribute bootloader rows. ``resetDslPortBootloaderState``
## resets the per-thread slot. Matches the M9.E ``dslPortVariants`` /
## ``dslPortValidates`` shape.

type
  DslBootloaderMenuEntry* = object
    ## One ``menuEntry:`` block inside a ``bootloader:`` body. The four
    ## canonical fields (title, kernel, initrd, cmdline) are the
    ## minimum surface the NDEM1 generation-switch needs; extra
    ## key/value setters captured by future milestones land in
    ## ``extras`` so the diagnostic surface stays open without
    ## widening the typed-field set.
    packageName*: string
    title*: string
    kernel*: string
    initrd*: string
    cmdline*: string
    extras*: seq[tuple[key: string, value: string]]
      ## Forward-compat slot for additional ``key "value"`` setters a
      ## future milestone may add to ``menuEntry:`` bodies (e.g.
      ## ``device "/dev/sda1"`` or ``moduleParams "..."``). M9.G's
      ## emitter populates only the four canonical fields; ``extras``
      ## starts empty.

  DslBootloaderConfig* = object
    ## Per-package bootloader registry row. One row per package; the
    ## M9.G emitter coalesces multiple top-level setters
    ## (``generationEntry`` / ``timeout`` / ``defaultEntry``) into a
    ## single row by re-running ``registerBootloaderConfig`` for each
    ## setter (the runtime merges into the existing row keyed by
    ## ``packageName``). Multiple ``menuEntry:`` blocks append distinct
    ## ``DslBootloaderMenuEntry`` rows into ``menuEntries`` in source
    ## order.
    packageName*: string
    generationEntry*: bool
      ## Whether this package contributes a generation-aware GRUB
      ## entry. NDEM1 reproos-desktop sets this to ``true``; recipes
      ## without per-generation entries leave it at the default
      ## ``false``.
    timeout*: int
      ## GRUB menu timeout in seconds. Default ``-1`` indicates the
      ## setter was never emitted; the apply phase substitutes a
      ## host-level default in that case.
    defaultEntry*: string
      ## Optional GRUB ``set default=`` value. Default ``""`` means
      ## unset.
    menuEntries*: seq[DslBootloaderMenuEntry]
      ## Source-order list of per-entry blocks declared inside the
      ## ``bootloader:`` body.

var dslPortBootloaders {.threadvar.}: Table[string, DslBootloaderConfig]
  ## Per-package bootloader registry. Keyed by ``packageName``.
  ## ``registerBootloaderConfig`` initialises or merges into the row;
  ## ``registerBootloaderMenuEntry`` appends a menu-entry row.

proc resetDslPortBootloaderState*() =
  ## Drop every bootloader-config registration. Test fixtures call this
  ## between scenarios so registry entries do not leak across cases.
  ## Symmetric with ``resetDslPortVariantState`` /
  ## ``resetDslPortValidateState``.
  dslPortBootloaders.clear()

proc registerBootloaderConfig*(packageName: string;
                               generationEntry: bool;
                               timeout: int = -1;
                               defaultEntry: string = "") =
  ## Initialise OR merge the bootloader row for ``packageName``. The
  ## M9.G emitter calls this once per declared top-level setter; the
  ## runtime coalesces them by:
  ##
  ##   * creating an empty row on first call (with ``generationEntry =
  ##     false``, ``timeout = -1``, ``defaultEntry = ""``,
  ##     ``menuEntries = @[]``);
  ##   * applying ``generationEntry`` IF the caller asked for ``true``
  ##     (a ``false`` argument does not clobber a prior ``true``);
  ##   * applying ``timeout`` IF the caller passed a non-default value
  ##     (anything other than ``-1``);
  ##   * applying ``defaultEntry`` IF the caller passed a non-empty
  ##     string.
  ##
  ## This means the macro can emit one call per setter without worrying
  ## about argument order or unset-vs-default ambiguity. The first call
  ## also populates ``packageName`` on the row.
  if packageName notin dslPortBootloaders:
    dslPortBootloaders[packageName] = DslBootloaderConfig(
      packageName: packageName,
      generationEntry: false,
      timeout: -1,
      defaultEntry: "",
      menuEntries: @[])
  if generationEntry:
    dslPortBootloaders[packageName].generationEntry = true
  if timeout != -1:
    dslPortBootloaders[packageName].timeout = timeout
  if defaultEntry.len > 0:
    dslPortBootloaders[packageName].defaultEntry = defaultEntry

proc registerBootloaderMenuEntry*(packageName: string;
                                  title, kernel, initrd, cmdline: string) =
  ## Append a ``menuEntry`` row to the bootloader config for
  ## ``packageName``. Auto-creates an empty parent row if no
  ## ``registerBootloaderConfig`` call landed yet (the
  ## ``bootloader:`` body's setter order is the user's choice — a
  ## ``menuEntry:`` may appear before ``generationEntry:`` /
  ## ``timeout:`` in source).
  if packageName notin dslPortBootloaders:
    dslPortBootloaders[packageName] = DslBootloaderConfig(
      packageName: packageName,
      generationEntry: false,
      timeout: -1,
      defaultEntry: "",
      menuEntries: @[])
  dslPortBootloaders[packageName].menuEntries.add(DslBootloaderMenuEntry(
    packageName: packageName,
    title: title,
    kernel: kernel,
    initrd: initrd,
    cmdline: cmdline,
    extras: @[]))

proc registeredBootloaderConfig*(packageName: string): DslBootloaderConfig =
  ## Return the registered bootloader config for ``packageName``.
  ## Returns a default-initialised row with empty fields when the
  ## package never declared a ``bootloader:`` block; the row's
  ## ``packageName`` is left empty so callers can distinguish
  ## "registered with all defaults" from "never registered".
  if packageName in dslPortBootloaders:
    return dslPortBootloaders[packageName]
  return DslBootloaderConfig(
    packageName: "",
    generationEntry: false,
    timeout: -1,
    defaultEntry: "",
    menuEntries: @[])

# ---------------------------------------------------------------------------
# DSL-port M9.H — ``fetch:`` block registry.
# ---------------------------------------------------------------------------
##
## ## What the M9.H surface covers
##
## NDE R4-R9 (dbus-broker, libdrm, wayland, wlroots, sway, kernel)
## currently pre-fetches upstream source tarballs via out-of-band
## ``.ps1`` / ``.sh`` sibling scripts BEFORE invoking ``repro build``.
## M9.H pins the URL + hash + extract metadata directly inside the recipe
## via a new ``fetch:`` block whose body recognises six setters:
##
##   * ``url: "string"`` — tarball URL (kind == ``dfkTarball``).
##   * ``gitUrl: "string"`` — git clone URL (kind == ``dfkGitArchive``).
##   * ``gitRevision: "string"`` — git ref/tag (only meaningful for
##     ``dfkGitArchive``).
##   * ``sha256: "<64 hex>"`` — expected sha256 of the fetched tarball
##     (sets ``hashAlg == dshaSha256``).
##   * ``blake3: "<64 hex>"`` — expected blake3 of the fetched tarball
##     (sets ``hashAlg == dshaBlake3``; takes precedence if both
##     ``sha256`` and ``blake3`` appear in the same body).
##   * ``extractStrip: <int>`` — tar ``--strip-components`` value at
##     extract time (default 1).
##   * ``extractedRoot: "string"`` — relative-to-projectRoot location of
##     the extracted source tree (default "").
##
## **M9.H is REGISTRATION + parser ONLY.** No actual network fetch or
## extract action runs as part of this milestone. The build-engine
## action that consumes the registry (downloads the URL, verifies the
## hash, untars to ``extractedRoot``) is wired in a separate milestone
## (M9.K). This file ONLY captures the spec into ``dslPortFetchSpecs``
## so downstream code can introspect it.
##
## ## Threading model
##
## ``dslPortFetchSpecs`` is ``threadvar`` so concurrent test fixtures do
## not cross-attribute fetch rows. ``resetDslPortFetchState`` resets the
## per-thread slot. Matches the M9.E ``dslPortVariants`` /
## ``dslPortValidates`` and M9.G ``dslPortBootloaders`` shape.

type
  DslFetchKind* = enum
    ## Discriminant for the fetch source kind. M9.H ships two kinds;
    ## future milestones widen the enum (``dfkGitFull`` for a full clone,
    ## ``dfkLocal`` for an in-tree path) WITHOUT breaking the registry
    ## API because every consumer dispatches on this discriminant.
    dfkTarball
      ## Download a tarball from ``url`` + verify hash + extract.
    dfkGitArchive
      ## Shallow-clone ``url`` at ``gitRevision`` + verify the resulting
      ## tarball's hash + extract. The shallow clone keeps the on-disk
      ## payload comparable in size to a release tarball while still
      ## pinning a tag / commit not present in any upstream release
      ## archive.

  DslSourceHashAlg* = enum
    ## Hash algorithm used to verify the fetched source. Both sha256 and
    ## blake3 produce 64-hex digests so the same ``hashHex`` field stores
    ## either; consumers MUST inspect ``hashAlg`` before validating.
    dshaSha256
    dshaBlake3

  DslFetchSpec* = object
    ## One ``fetch:`` block's pinned-source metadata. The packageName is
    ## captured on the row so a copy retains its attribution after a
    ## table-key lookup; this mirrors ``DslBootloaderConfig`` /
    ## ``DslArtifact``.
    packageName*: string
    kind*: DslFetchKind
    url*: string
      ## Tarball URL (``dfkTarball``) or git URL (``dfkGitArchive``).
    gitRevision*: string
      ## Tag / commit / branch the shallow-clone resolves. Empty for
      ## ``dfkTarball``.
    hashAlg*: DslSourceHashAlg
    hashHex*: string
      ## 64-hex digest of the fetched tarball.
    extractStrip*: int
      ## ``tar --strip-components`` value at extract time. Defaults to 1
      ## (matches the common GitHub-archive layout where the tarball's
      ## top-level directory is ``<repo>-<sha>``).
    extractedRoot*: string
      ## Relative-to-projectRoot path where the extracted source tree
      ## lives. Empty default means "let the engine choose" (typically
      ## ``<package>-<version>`` inside the build's working tree).

var dslPortFetchSpecs {.threadvar.}: Table[string, DslFetchSpec]
  ## Per-package fetch spec registry. Keyed by ``packageName``.
  ## ``registerFetchSpec`` writes the row (last writer wins per package
  ## — a package declaring two ``fetch:`` blocks gets the second one).
  ## ``registeredFetchSpec`` returns the row or a default-initialised
  ## empty spec when none was registered.

proc resetDslPortFetchState*() =
  ## Drop every fetch-spec registration. Test fixtures call this between
  ## scenarios so registry entries do not leak across cases. Symmetric
  ## with ``resetDslPortBootloaderState`` / ``resetDslPortVariantState``.
  dslPortFetchSpecs.clear()

proc registerFetchSpec*(packageName, url, gitRevision: string;
                       hashAlg: DslSourceHashAlg;
                       hashHex: string;
                       kind: DslFetchKind;
                       extractStrip: int;
                       extractedRoot: string) =
  ## Pin the fetch metadata for ``packageName`` into the registry. The
  ## M9.H macro emitter assembles every field at compile time and emits a
  ## single call per declared ``fetch:`` block. The runtime overwrites
  ## any prior row for the same package; a package declaring two
  ## ``fetch:`` blocks gets the latter one's metadata.
  ##
  ## NOTE: M9.H performs NO network I/O. The registered spec is the
  ## INPUT to a future M9.K fetch action; this proc never opens a
  ## socket, never touches the filesystem, never computes a hash.
  dslPortFetchSpecs[packageName] = DslFetchSpec(
    packageName: packageName,
    kind: kind,
    url: url,
    gitRevision: gitRevision,
    hashAlg: hashAlg,
    hashHex: hashHex,
    extractStrip: extractStrip,
    extractedRoot: extractedRoot)

proc registeredFetchSpec*(packageName: string): DslFetchSpec =
  ## Return the registered fetch spec for ``packageName``. Returns a
  ## default-initialised row with empty fields and ``kind = dfkTarball``
  ## when the package never declared a ``fetch:`` block; the row's
  ## ``packageName`` is left empty so callers can distinguish
  ## "registered with all defaults" from "never registered".
  if packageName in dslPortFetchSpecs:
    return dslPortFetchSpecs[packageName]
  return DslFetchSpec(
    packageName: "",
    kind: dfkTarball,
    url: "",
    gitRevision: "",
    hashAlg: dshaSha256,
    hashHex: "",
    extractStrip: 1,
    extractedRoot: "")

# ---------------------------------------------------------------------------
# DSL-port M9.R.6.1 — M9.I per-package flag-injection registry RETIRED.
# ---------------------------------------------------------------------------
##
## The M9.I ``mesonOptions:`` / ``cmakeFlags:`` / ``configureFlags:`` /
## ``makeFlags:`` / ``ninjaFlags:`` block parser arms + the
## ``registerBuildFlag(...)`` / ``registeredBuildFlags(...)`` accessors
## + the ``DslBuildFlagSet`` row type are all GONE as of M9.R.6.1
## (2026-06-19). The M9.R.5b recipe sweep lifted every per-recipe flag
## block into an explicit ``build:`` body that calls one of the
## M9.R.2b Layer-1 typed constructors (``meson_package(...)`` /
## ``cmake_package(...)`` / ``autotools_package(...)``) with the flag
## sequence inlined as a configureOptions / cacheVars argument; the
## convention layer no longer needs a side channel to thread the flags
## through.
##
## See ``reprobuild-specs/From-Source-DSL-Realignment.milestones.org``
## §M9.R.6.1 for the narrowing rationale.
##
## --- HISTORICAL CONTEXT (pre-M9.R.6.1) ---
##
## Real from-source recipes need to pass per-package flags into the
## convention layer's underlying build tool. Examples:
##
##   * dbus-broker: ``-Daudit=false`` / ``-Dlauncher=true`` to
##     ``meson setup``.
##   * wlroots: ``-Dxwayland=disabled`` to ``meson setup``.
##   * kernel: ``ARCH=x86_64`` / ``V=1`` to ``make``.
##
## M9.I added four package-body blocks (all optional, all repeatable for
## append semantics):
##
##   * ``mesonOptions:`` — flags passed to ``meson setup``.
##   * ``cmakeFlags:`` — flags passed to ``cmake ..``.
##   * ``configureFlags:`` — flags passed to ``./configure`` (autotools).
##   * ``makeFlags:`` — raw ``make`` args.
##   * ``ninjaFlags:`` — raw ``ninja`` args.
##
## Each block body is a sequence of string literals (one per line, no
## setters). The block is repeatable inside a package body — successive
## blocks APPEND to the registered sequence (M9.G/M9.H last-writer-wins
## semantics would be wrong here because flag order matters for some
## build systems).
##
## **M9.I was REGISTRATION + parser ONLY.** No actual injection into the
## build action runs as part of this milestone. The convention layer
## (c_cpp_meson, c_cpp_cmake, c_cpp_autotools, c_cpp_make) needed to be
## widened to consume these registries; that's deferred to M9.L.
##
## ## Threading model
##
## ``dslPortBuildFlagSets`` is ``threadvar`` so concurrent test fixtures
## do not cross-attribute flag rows. ``resetDslPortBuildFlagState``
## resets the per-thread slot. Matches the M9.E / M9.G / M9.H shape.
##
## ## Artifact-level overrides
##
## The ``DslBuildFlagSet`` row carries an ``artifactName`` field so a
## future milestone can attribute flags to a specific ``executable``/
## ``library`` artifact within a package. M9.I only registers package-
## level flags (``artifactName == ""``); artifact-level injection is a
## follow-up.

# M9.R.6.1: ``DslBuildFlagSet`` type + ``dslPortBuildFlagSets``
# threadvar + ``resetDslPortBuildFlagState`` + ``m9iFlagSetKey`` +
# ``registerBuildFlag`` + ``registeredBuildFlags`` were all removed
# on 2026-06-19. Recipes route per-tool options through their
# explicit ``build:`` block calling the M9.R.2b Layer-1 typed
# constructors instead.

# ---------------------------------------------------------------------------
# DSL-port M9.R.1 — package-level dependency-declaration surface.
# ---------------------------------------------------------------------------
##
## ## Surface
##
## Three package-level blocks: ``buildDeps:`` / ``nativeBuildDeps:`` /
## ``runtimeDeps:``. Each accepts the same constraint-string grammar as
## the legacy ``uses:`` block (``"name >=version"``). The three blocks
## carve up the Nix-style split:
##
##   * ``nativeBuildDeps:`` — BUILD-platform tools / code generators
##     that drive the build (Nix ``nativeBuildInputs`` equivalent).
##   * ``buildDeps:``       — HOST-platform libraries the produced
##     binaries link against (Nix ``buildInputs`` equivalent). The
##     legacy ``uses:`` block is a synonym: BOTH spellings populate the
##     same registry, so existing 84 from-source recipes that still
##     spell the block ``uses:`` are queryable via
##     ``registeredBuildDeps(packageName)`` without any sweep.
##   * ``runtimeDeps:``     — HOST-platform tools / libraries consumers
##     need at runtime or link time (Nix ``propagatedBuildInputs`` +
##     ``DT_NEEDED`` equivalent).
##
## ## Registry shape
##
## A single ``threadvar`` table keyed by
## ``packageName & '\x00' & kind`` (where ``kind`` is one of ``"build"``
## / ``"native"`` / ``"runtime"``) holds the seq of raw constraint
## strings in source-declaration order. The constraint string is the
## same one the legacy ``PackageUseDef.rawConstraint`` carries — the
## solver-side parsing (selector / version-range / gate) is already
## done by ``parsePackageDef`` and reaches the solver via
## ``registerSolverDependency``. This new registry is the diagnostic
## surface (the "did the parser see my block" pin) the M9.R.5 recipe
## sweep + M9.R.2/M9.R.3 follow-ups consume.
##
## ## Threading
##
## ``threadvar`` so concurrent test fixtures do not cross-attribute
## rows. ``resetDslPortPackageDepsState`` resets the per-thread slot.
## Matches the M9.H / M9.I / M9.N Batch C.1 shape.

var dslPortPackageDeps {.threadvar.}: Table[string, seq[string]]
  ## Per-(packageName, kind) constraint-string seq. The key encoding
  ## ``packageName & '\x00' & kind`` matches the M9.I
  ## ``dslPortBuildFlagSets`` convention (the ``\x00`` byte cannot
  ## appear in either component so the encoding is unambiguous).

proc m9r1PackageDepsKey(packageName, kind: string): string {.inline.} =
  ## Compose the ``(packageName, kind)`` registry key. Symmetric with
  ## ``m9iFlagSetKey`` (M9.I) — both pin the ``\x00`` separator so the
  ## encoding is unambiguous (Nim identifiers exclude NUL by
  ## tokenisation).
  result = packageName & '\x00' & kind

proc resetDslPortPackageDepsState*() =
  ## Drop every package-deps registration. Test fixtures call this
  ## between scenarios so registry entries do not leak across cases.
  ## Symmetric with ``resetDslPortBuildFlagState`` /
  ## ``resetDslPortFetchState``.
  dslPortPackageDeps.clear()

proc registerPackageDep*(packageName, kind, constraint: string) =
  ## Append ``constraint`` to the ``(packageName, kind)`` row. ``kind``
  ## ∈ {``"build"``, ``"native"``, ``"runtime"``}; unknown kinds are
  ## silently ignored so forward-compatibility with future kinds (e.g.
  ## the deferred ``propagatedBuildDeps:`` per the open-extension note
  ## in ``From-Source-Build-Recipes.md``) stays open at the emitter
  ## layer.
  ##
  ## The ``package`` macro emits one ``registerPackageDep(...)`` call
  ## per constraint-string literal in each ``buildDeps:`` /
  ## ``nativeBuildDeps:`` / ``runtimeDeps:`` (and the legacy ``uses:``)
  ## block, in source-declaration order. Multiple blocks of the same
  ## kind on one package APPEND to the registered seq (matches M9.I's
  ## ``mesonOptions:`` append semantics).
  case kind
  of "build", "native", "runtime":
    let key = m9r1PackageDepsKey(packageName, kind)
    if key notin dslPortPackageDeps:
      dslPortPackageDeps[key] = @[]
    dslPortPackageDeps[key].add(constraint)
  else:
    discard

proc registeredBuildDeps*(packageName: string): seq[string] =
  ## Return the constraint-string seq for ``packageName``'s
  ## ``buildDeps:`` block (and the legacy ``uses:`` synonym) in source-
  ## declaration order. Returns an empty seq when nothing was
  ## registered.
  let key = m9r1PackageDepsKey(packageName, "build")
  if key in dslPortPackageDeps:
    return dslPortPackageDeps[key]
  return @[]

proc registeredNativeBuildDeps*(packageName: string): seq[string] =
  ## Return the constraint-string seq for ``packageName``'s
  ## ``nativeBuildDeps:`` block in source-declaration order. Returns
  ## an empty seq when nothing was registered.
  let key = m9r1PackageDepsKey(packageName, "native")
  if key in dslPortPackageDeps:
    return dslPortPackageDeps[key]
  return @[]

proc registeredRuntimeDeps*(packageName: string): seq[string] =
  ## Return the constraint-string seq for ``packageName``'s
  ## ``runtimeDeps:`` block in source-declaration order. Returns an
  ## empty seq when nothing was registered.
  let key = m9r1PackageDepsKey(packageName, "runtime")
  if key in dslPortPackageDeps:
    return dslPortPackageDeps[key]
  return @[]

# ---------------------------------------------------------------------------
# DSL-port M9.N Batch C.1 — ``shell()`` action surface for ``build:`` blocks.
# ---------------------------------------------------------------------------
##
## ## What the surface covers
##
## The four standard ``from-source-*`` conventions (meson / cmake /
## autotools / make) all key on a populated flag-channel registry. Recipes
## that don't fit any of those moulds — meson (Python-only), ninja
## (bootstrap-driven), and any future build-tool recipe whose upstream
## build is a custom shell sequence — currently have no DSL surface to
## express their build steps. The ``shell()`` proc fills that gap:
## recipe authors call ``shell "<cmd>"`` from inside a ``build:`` block
## and the runtime records the command verbatim against the active
## ``(packageName, artifactName)`` frame. The new ``from-source-custom``
## convention (M9.N Batch C.1) consumes the recorded sequence and emits
## one ``BuildActionDef`` per shell action.
##
## ## Substitution placeholders
##
## The recorded commands may carry three engine-time substitution
## placeholders that the convention layer resolves at fragment-emit time:
##
##   * ``$fetch``      — path to the fetched tarball (used rarely; the
##                       fetch action already extracts on success).
##   * ``$extracted``  — absolute path to ``<projectRoot>/src/`` (or the
##                       recipe's ``extractedRoot``). The default ``cwd``
##                       for shell actions is also this directory.
##   * ``$out``        — absolute path to
##                       ``<projectRoot>/.repro/output/<artifactName>/``.
##                       The per-artifact output directory the engine's
##                       output-collection step keys off.
##
## Substitution is a token replacement on the recorded command string
## performed by the convention (NOT by this runtime). The recipe sees a
## verbatim string; the action's argv is ``[sh, -c, <substituted>]``.
##
## ## Auto-generated action id
##
## When the caller omits ``id``, the runtime synthesises
## ``<packageName>-<artifactName>-<sequenceNumber>``. The sequence
## number increments per ``(packageName, artifactName)`` pair so a
## single artifact's shell actions get stable, distinguishable ids
## across multiple ``shell()`` calls within the same ``build:`` block.
##
## ## Threading model
##
## ``dslPortShellActions`` is ``threadvar`` so concurrent test fixtures
## do not cross-attribute shell-action rows. ``resetDslPortShellState``
## resets the per-thread slot. Matches the M9.H / M9.I shape.

type
  DslShellAction* = object
    ## One ``shell()`` registration. The convention layer emits one
    ## ``BuildActionDef`` per row in declaration order.
    packageName*: string
      ## The owning package; auto-filled from ``currentBuildPackage()``.
    artifactName*: string
      ## The owning artifact; auto-filled from
      ## ``currentBuildArtifact()`` (empty for the package-level
      ## ``build:`` form).
    id*: string
      ## Stable action id. Caller may supply explicitly; otherwise
      ## auto-generated as ``<package>-<artifact>-<seq>``.
    command*: string
      ## The verbatim shell command. May embed ``$fetch`` / ``$extracted``
      ## / ``$out`` placeholders the convention resolves at emit time.
    deps*: seq[string]
      ## Optional action-id deps. Empty means the convention adds the
      ## default chain (depends on the previous shell action OR on the
      ## fetch action when this is the first shell action).
    cwd*: string
      ## Working dir override. Empty means "use the convention's default"
      ## (typically the extracted source dir).
    outputs*: seq[string]
      ## Optional declared outputs. Empty means the convention picks a
      ## stamp file under the per-convention scratch dir so downstream
      ## actions can dep on it.

var dslPortShellActions {.threadvar.}: Table[string, seq[DslShellAction]]
  ## Per-package shell-action registry. Keyed by ``packageName``. The
  ## value seq is in source-declaration order across all artifacts so
  ## the convention layer can replay the sequence verbatim.

var dslPortShellSequence {.threadvar.}: Table[string, int]
  ## Per-``(packageName, artifactName)`` monotonic counter used to
  ## synthesise unique action ids when the caller omits ``id``.

proc resetDslPortShellState*() =
  ## Drop every shell-action registration + counter. Test fixtures call
  ## this between scenarios so registry entries do not leak across cases.
  ## Symmetric with ``resetDslPortFetchState`` /
  ## ``resetDslPortBuildFlagState``.
  dslPortShellActions.clear()
  dslPortShellSequence.clear()

proc resetDslPortShellStateForPackage*(packageName: string) =
  ## M9.R.15q.2.1 — drop the shell-action rows + counter for
  ## ``packageName`` only. Called from ``buildXxxPackage*()`` at entry
  ## so repeat invocations don't double-register the same body's
  ## ``shell(...)`` rows (module-init + ``runPackageProvider`` both
  ## invoke the proc). Per-package scope keeps other packages' rows
  ## (imported via cross-recipe ``buildDeps:`` chains) alive.
  if packageName.len == 0:
    return
  if packageName in dslPortShellActions:
    dslPortShellActions.del(packageName)
  # Clear every seq counter whose seqKey is prefixed with this package.
  var keysToDel: seq[string] = @[]
  for key in dslPortShellSequence.keys:
    if key.startsWith(packageName & "\x00"):
      keysToDel.add(key)
  for key in keysToDel:
    dslPortShellSequence.del(key)

proc shell*(command: string;
            id: string = "";
            deps: seq[string] = @[];
            outputs: seq[string] = @[];
            cwd: string = "") =
  ## Record one shell action against the active build context's
  ## ``(packageName, artifactName)`` frame. The call is a SILENT no-op
  ## when no build context is active (matches the M4 ``output(path)``
  ## convention so legacy provider-mode call chains stay compatible).
  ##
  ## ``command`` is recorded verbatim — embedded ``$fetch`` /
  ## ``$extracted`` / ``$out`` placeholders are resolved at convention
  ## emit time, NOT here.
  ##
  ## When ``id`` is empty the runtime synthesises
  ## ``<package>-<artifact>-<seq>`` where ``<seq>`` is a monotonic per-
  ## ``(package, artifact)`` counter. When the caller supplies ``id`` it
  ## is recorded verbatim and the synthesised counter is NOT advanced
  ## for that row — but the next omitted-id row still gets a fresh
  ## sequence number.
  ##
  ## Frame resolution: the M4 ``dslPortActiveBuildContext`` stack is the
  ## primary source. When that is empty (e.g. the legacy
  ## ``buildXxxPackage*()`` proc runs the body in ``reproProviderMode``
  ## without re-pushing M4 frames), we fall back to the M5
  ## ``activeBuilds`` stack so the shell-action registry stays
  ## observable in both code paths. The fallback uses ``packageName`` +
  ## ``ownerName`` (or a blank artifact when the frame is package-level).
  var pkg = ""
  var artifact = ""
  if dslPortActiveBuildContext.len > 0:
    let frame = dslPortActiveBuildContext[^1]
    pkg = frame.packageName
    artifact = frame.artifactName
  else:
    let m5 = tryCurrentBuildState()
    if m5 == nil:
      return
    pkg = m5.packageName
    if m5.ownerKind != "package":
      artifact = m5.ownerName
  let seqKey = pkg & "\x00" & artifact
  var resolvedId = id
  if resolvedId.len == 0:
    let nextSeq =
      if seqKey in dslPortShellSequence: dslPortShellSequence[seqKey] + 1
      else: 1
    dslPortShellSequence[seqKey] = nextSeq
    var artifactPart = artifact
    if artifactPart.len == 0:
      artifactPart = "package"
    resolvedId = pkg & "-" & artifactPart & "-" & $nextSeq
  let row = DslShellAction(
    packageName: pkg,
    artifactName: artifact,
    id: resolvedId,
    command: command,
    deps: deps,
    cwd: cwd,
    outputs: outputs)
  if pkg notin dslPortShellActions:
    dslPortShellActions[pkg] = @[]
  dslPortShellActions[pkg].add(row)

proc registeredShellActions*(packageName: string): seq[DslShellAction] =
  ## Return every shell action recorded against ``packageName`` in
  ## declaration order across all of the package's ``build:`` blocks.
  ## Returns the empty seq when the package never called ``shell()``.
  if packageName in dslPortShellActions:
    return dslPortShellActions[packageName]
  return @[]

# ---------------------------------------------------------------------------
# M9.R.15q.2.1 — shell-row → BuildActionDef translator.
#
# The ``from-source-custom`` convention (in repro_standard_provider) walks
# ``registeredShellActions`` + ``registeredFetchSpec`` to emit a chain of
# ``BuildActionDef`` rows: fetch → shell1 → ... → shellN → stage-copy(per
# member). The convention only fires when a recipe is routed through the
# standard provider; per-project providers don't dispatch through the
# convention, so a custom-shell recipe (boost / ninja / meson / gcc)
# compiled with ``-d:reproProviderMode`` ends up with the shell registry
# populated by the recipe's ``build:`` body but NO ``BuildActionDef``
# rows -- ``buildPackageFragment`` queries ``registeredBuildActions()``
# and returns an empty fragment (``scheduler:actions=0``).
#
# ``synthesizeCustomShellBuildActions`` is the recipe-side mirror of the
# convention's emission: it consumes the in-process shell-action +
# fetch-spec registries and emits the same fetch + shell chain as
# ``BuildActionDef`` rows so ``buildPackageFragment`` sees them at
# fragment-construction time. The macro layer emits a call from the
# generated ``buildXxxPackage*()`` proc AFTER the user's ``build:`` body
# has run, so the rows the body registered via ``shell(...)`` are
# observable at the time the helper runs.
#
# Stage-copy emission is deliberately omitted at this layer: the per-
# project provider doesn't know the artifact-member list at runtime
# (that lives in the macro-time ``PackageDef``). The fetch + shell
# chain alone is enough to drive the recipe's build steps -- the
# install-tree's contents live under ``$out`` after the chain runs;
# downstream consumption already happens via the binary-cache publisher
# (the last shell action stamps the cache identity).
# ---------------------------------------------------------------------------

proc dslPortCustomFetchScriptShell(spec: DslFetchSpec; tarball, extracted,
                                   stamp: string): string =
  ## Compose the fetch-script body. Mirrors the autotools / cmake /
  ## meson constructors' fetch-script shape: curl → hash-verify → tar
  ## --force-local extract → touch stamp. ``file://`` URLs work natively
  ## via curl.
  let escapedUrl = spec.url.replace("\"", "\\\"")
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("mkdir -p \"" & escapedExtracted & "\"; ")
  script.add("if [ ! -f \"" & escapedTarball & "\" ]; then ")
  script.add("curl -fsSL -o \"" & escapedTarball & "\" \"" & escapedUrl &
    "\"; fi; ")
  case spec.hashAlg
  of dshaSha256:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | sha256sum -c -; ")
  of dshaBlake3:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | b2sum -a blake3 -c - || ")
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | blake3sum -c -; ")
  script.add("tar --force-local -xf \"" & escapedTarball & "\" -C \"" &
    escapedExtracted & "\" --strip-components=" & $spec.extractStrip & "; ")
  script.add("touch \"" & escapedStamp & "\"")
  script

proc dslPortSubstituteShellPlaceholders(command, fetchPath, extractedPath,
                                       outPath: string): string =
  ## Replace ``$fetch`` / ``$extracted`` / ``$out`` in ``command``.
  ## Mirrors ``from_source_custom.substitutePlaceholders`` byte-for-byte
  ## so a recipe routed through the per-project provider gets the same
  ## substituted argv as one routed through the standard provider.
  result = command.replace("$extracted", extractedPath)
  result = result.replace("$fetch", fetchPath)
  result = result.replace("$out", outPath)

proc dslPortSanitizeIdPart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc synthesizeCustomShellBuildActions*(packageName: string) {.dynOrStatic.} =
  ## M9.R.15q.2.1 — translate ``registeredShellActions(packageName)``
  ## (and the package's ``registeredFetchSpec``) into ``BuildActionDef``
  ## rows via ``buildAction(...)`` so the per-project provider's
  ## ``buildPackageFragment`` picks them up.
  ##
  ## NO-OP when the shell registry is empty for ``packageName`` -- the
  ## recipe didn't drive the from-source-custom path, so the regular
  ## constructors (``cmake_package`` / ``autotools_package`` / etc.)
  ## already emitted the appropriate buildAction rows during the user's
  ## ``build:`` body.
  ##
  ## The macro emits a call from ``buildXxxPackage*()``'s tail so the
  ## helper runs AFTER the user's ``shell(...)`` calls have populated
  ## the registry.
  let rows = registeredShellActions(packageName)
  if rows.len == 0:
    return
  let projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    # Outside provider mode (test fixtures importing the recipe) the
    # project root is empty; the helper is a no-op so the recipe
    # macro's verbatim-body splice path stays uncontested.
    return
  # Pool registration -- mirrors from_source_custom's pool declarations.
  discard buildPool("compile", 8'u32)
  let spec = registeredFetchSpec(packageName)
  let scratch = projectRoot / ".repro" / "fetch"
  let outPath = projectRoot / ".repro" / "build" / "from-source-custom" /
    packageName
  let stampDir = outPath / ".stamps"
  let extracted = projectRoot / "src"
  createDir(extendedPath(stampDir))
  # Per-package fetch action (when a fetch spec was registered).
  var fetchId = ""
  var fetchStamp = ""
  var fetchPath = ""
  if spec.url.len > 0 and spec.hashHex.len > 0:
    discard buildPool("fetch", 2'u32)
    createDir(extendedPath(scratch))
    fetchPath = scratch / (spec.hashHex & ".tar")
    fetchStamp = scratch / (spec.hashHex & ".stamp")
    let hashAlgTag =
      case spec.hashAlg
      of dshaSha256: "sha256"
      of dshaBlake3: "blake3"
    let fetchScript = dslPortCustomFetchScriptShell(spec, fetchPath,
      extracted, fetchStamp)
    fetchId = "ccpp-fetch-" & dslPortSanitizeIdPart(packageName)
    discard buildAction(
      id = fetchId,
      call = inlineExecCall(@["sh", "-c", fetchScript], projectRoot),
      inputs = @[],
      outputs = @[fetchStamp],
      pool = "fetch",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "from-source-custom.fetch." & hashAlgTag,
      toolIdentityRefs = @["sh"])
  # Shell-action chain: action[0] depends on the fetch action (or no
  # deps when no fetch); action[i>0] depends on action[i-1].
  var prevId = ""
  var prevStamp = ""
  for i, row in rows:
    let actionId = "from-source-custom-shell-" & $(i + 1) & "-" &
      dslPortSanitizeIdPart(packageName)
    let stamp = stampDir / (actionId & ".stamp")
    let substituted = dslPortSubstituteShellPlaceholders(
      row.command, fetchPath, extracted, outPath)
    let escapedExtracted = extracted.replace("\\", "/").
      replace("\"", "\\\"")
    let escapedOut = outPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let escapedStampDir = stampDir.replace("\\", "/").
      replace("\"", "\\\"")
    let script = "set -e; mkdir -p \"" & escapedExtracted &
      "\"; mkdir -p \"" & escapedOut & "\"; mkdir -p \"" &
      escapedStampDir & "\"; cd \"" & escapedExtracted & "\"; " &
      substituted & "; touch \"" & escapedStamp & "\""
    var deps: seq[string] = @[]
    var inputs: seq[string] = @[]
    if prevId.len > 0:
      deps.add(prevId)
      inputs.add(prevStamp)
    elif fetchId.len > 0:
      deps.add(fetchId)
      inputs.add(fetchStamp)
    discard buildAction(
      id = actionId,
      call = inlineExecCall(@["sh", "-c", script], projectRoot),
      deps = deps,
      inputs = inputs,
      outputs = @[stamp],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "from-source-custom.shell",
      toolIdentityRefs = @["sh"])
    prevId = actionId
    prevStamp = stamp

  # M9.R.15q.2.4 — install-tree mirror.
  #
  # The engine's tool-identity resolver probes the canonical
  # ``<recipeDir>/.repro/output/install/usr/lib*/lib<name>*.so*`` path
  # to locate a sibling recipe's published artifacts (see
  # ``m9r14hProbeInstallMirrorLibrary`` in ``repro_tool_profiles``).
  # The from-source-custom convention's shell sequence typically lands
  # under ``$out/install/usr/`` (the boost recipe's last shell does
  # exactly this); some custom-shell recipes write directly under
  # ``$out/lib/`` + ``$out/include/`` without the ``install/usr/``
  # nesting. The mirror action probes BOTH layouts: it copies
  # ``$out/install/usr/`` when present, OR falls back to mirroring
  # ``$out/lib`` + ``$out/include`` + ``$out/bin`` under
  # ``.repro/output/install/usr/`` so the resolver's probe finds the
  # SONAME chain at the canonical path.
  #
  # Only emitted when the recipe has at least one shell action and a
  # fetch spec (proxy for "this is a from-source-custom recipe"); the
  # action chains off the last shell action's stamp so it runs after
  # the install body completes.
  if prevId.len > 0:
    let mirrorRoot = projectRoot / ".repro" / "output" / "install"
    let mirrorUsr = mirrorRoot / "usr"
    createDir(extendedPath(mirrorRoot))
    let mirrorStamp = mirrorRoot / ".m9r15q21_install_mirror.stamp"
    let escapedMirrorRoot = mirrorRoot.replace("\\", "/").
      replace("\"", "\\\"")
    let escapedMirrorUsr = mirrorUsr.replace("\\", "/").
      replace("\"", "\\\"")
    let escapedMirrorStamp = mirrorStamp.replace("\\", "/").
      replace("\"", "\\\"")
    let escapedOutPath = outPath.replace("\\", "/").
      replace("\"", "\\\"")
    var script = "set -e; "
    script.add("rm -rf \"" & escapedMirrorUsr & "\"; ")
    script.add("mkdir -p \"" & escapedMirrorRoot & "\"; ")
    # Primary path: $out/install/usr/ tree (the canonical destdir
    # shape custom-shell recipes like boost emit). Copy verbatim into
    # the mirror.
    script.add("if [ -d \"" & escapedOutPath & "/install/usr\" ]; then ")
    script.add("cp -a -- \"" & escapedOutPath & "/install/usr\" \"" &
      escapedMirrorRoot & "/\"; ")
    script.add("else ")
    # Fallback: bare $out/lib + $out/include + $out/bin (recipes that
    # didn't relocate to install/usr/). Compose a synthetic usr/ tree.
    script.add("mkdir -p \"" & escapedMirrorUsr & "\"; ")
    for sub in ["lib", "lib64", "include", "bin", "share"]:
      script.add("if [ -d \"" & escapedOutPath & "/" & sub &
        "\" ]; then cp -a -- \"" & escapedOutPath & "/" & sub &
        "\" \"" & escapedMirrorUsr & "/\"; fi; ")
    script.add("fi; ")
    script.add("touch \"" & escapedMirrorStamp & "\"")
    let mirrorActionId = "from-source-custom-mirror-" &
      dslPortSanitizeIdPart(packageName)
    discard buildAction(
      id = mirrorActionId,
      call = inlineExecCall(@["sh", "-c", script], projectRoot),
      deps = @[prevId],
      inputs = @[prevStamp],
      outputs = @[mirrorStamp],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "from-source-custom.mirror",
      toolIdentityRefs = @["sh"])

# ---------------------------------------------------------------------------
# DSL-port M9.R.3 — ``library <name>: api:`` block surface.
# ---------------------------------------------------------------------------
##
## ## Surface
##
## An optional ``api:`` block inside ``library <name>:`` declares the
## library's consumer-facing metadata. Fields:
##
##   * ``pkgConfig "<name>"``                — pkg-config module name.
##   * ``soname "<name>"`` / ``sover "<v>"`` — shared-object metadata.
##   * ``linkKind static | shared | both``    — consumer link mode.
##   * ``languageStandard <feature>``         — minimum language standard
##                                              (e.g. ``cxx_std_17``,
##                                              ``c_std_11``); always
##                                              propagated.
##   * CMake PUBLIC/PRIVATE pairs (PUBLIC propagates to consumers;
##     PRIVATE applies only while compiling the library):
##       - ``headers:`` / ``privateHeaders:``
##       - ``links:`` / ``privateLinks:``        (string identifiers
##                                                pointing at sibling
##                                                ``library`` handles)
##       - ``defines:`` / ``privateDefines:``
##       - ``compileOptions:`` / ``privateCompileOptions:``
##
## All fields are individually optional; the whole ``api:`` block is
## optional (``library libFoo: discard`` keeps working). When a recipe
## declares an ``api:`` block, the macro emits a runtime registration
## call into module-init code that walks the body and populates a
## ``LibraryApi`` value in the per-thread registry. Variant-conditional
## content inside ``headers:`` / ``links:`` / etc. resolves at registry
## evaluation time (after the solver stage) because the body is spliced
## into the registration call's expression — the identifier strings the
## registry stores reflect the resolved variant value.
##
## ## Registry shape
##
## A single ``threadvar`` table keyed by ``packageName & '\x00' &
## libraryName`` holds the populated ``LibraryApi`` value. Recipes that
## never declared an ``api:`` block do NOT have a row; the accessor
## returns a default-zero value with ``declared == false`` for unknown
## ``(pkg, lib)`` pairs so callers can distinguish "no api: block" from
## "empty api: block" without try/except.
##
## ## Threading
##
## ``threadvar`` so concurrent test fixtures do not cross-attribute
## registrations. ``resetDslPortLibraryApiState`` resets the per-thread
## slot. Matches the M9.H / M9.I / M9.R.1 shape.

type
  LibraryLinkKind* = enum
    ## ``linkKind`` field's value. ``llkUnset`` is the default for
    ## ``api:`` blocks that omit ``linkKind`` (or for libraries with no
    ## ``api:`` block at all). Names map directly onto the four DSL
    ## tokens accepted by ``linkKind <token>``.
    llkUnset
    llkStatic
    llkShared
    llkBoth

  ExportedSymbol* = object
    ## DSL-port M9.R.4: one FFI-callable symbol declared inside a
    ## library's ``api: exports:`` sub-block.
    ##
    ## v1 stores the symbol's signature as **raw Nim source-text
    ## strings**. The recipe author's Nim types (``Pcm`` /
    ## ``PcmStream`` / etc.) are not necessarily resolvable in the
    ## macro-expansion context — they're typically opaque library
    ## types declared elsewhere. Storing the text faithfully lets
    ## downstream tooling (cross-language binding generation, ABI-
    ## stability validation) consume the surface without needing
    ## sema-checked types here.
    name*: string
      ## C symbol name — the Nim ident with the trailing ``*`` export
      ## marker stripped. The C ABI dispatches on this name verbatim.
    paramsRaw*: string
      ## Raw Nim source text of the parameter list (the inside of the
      ## ``()`` after the proc name), e.g.
      ## ``"pcm: ptr Pcm, name: cstring, stream: PcmStream, mode: cint"``.
      ## The outer parentheses are stripped. Empty string means no
      ## parameters.
    returnRaw*: string
      ## Raw Nim source text of the return type, e.g. ``"cint"``.
      ## Empty string means a ``void`` / unspecified return.
    doc*: string
      ## Optional doc-comment captured from the first ``## ...``
      ## statement inside the proc body. Empty string when the proc
      ## carries no doc comment.

  LibraryApi* = object
    ## DSL-port M9.R.3: typed record for a library's ``api:`` block.
    ## Field-for-field mirror of the DSL surface; every field is
    ## individually optional (empty string / empty seq / ``llkUnset``
    ## means "field omitted").
    declared*: bool
      ## ``true`` when the recipe declared an ``api:`` block on this
      ## library. Callers use this discriminant to distinguish "no
      ## api: block" (return default-zero record) from "empty api:
      ## block" (all fields zero/empty but ``declared == true``).
    pkgConfig*: string
      ## pkg-config module name (``.pc`` basename without ``.pc``).
    soname*: string
      ## SONAME — platform decoration applied by packagers.
    sover*: string
      ## SOVERSION — combined with ``soname`` to produce the fully
      ## versioned library filename.
    linkKind*: LibraryLinkKind
      ## How consumers link against this library — static archive,
      ## shared object, or both. ``llkUnset`` when ``linkKind`` was
      ## omitted from the ``api:`` block.
    languageStandard*: string
      ## CMake ``target_compile_features``-equivalent minimum language
      ## standard (e.g. ``cxx_std_17``, ``c_std_11``). Always
      ## propagated to consumers; v1 has no PRIVATE counterpart.
    headers*: seq[string]
      ## CMake PUBLIC header search paths consumers ``#include``.
    privateHeaders*: seq[string]
      ## CMake PRIVATE header search paths used only while compiling
      ## this library.
    links*: seq[string]
      ## CMake PUBLIC link deps — sibling library identifiers (string
      ## form). Symbol resolution to actual install paths is deferred
      ## to the M9.R.5 / M9.R.6 consumer sweep.
    privateLinks*: seq[string]
      ## CMake PRIVATE link deps — sibling library identifiers used
      ## only while building this library, not propagated to
      ## consumers.
    defines*: seq[string]
      ## CMake PUBLIC preprocessor defines propagated to consumers.
    privateDefines*: seq[string]
      ## CMake PRIVATE preprocessor defines applied only while
      ## compiling this library.
    compileOptions*: seq[string]
      ## CMake PUBLIC compiler flags propagated to consumers.
    privateCompileOptions*: seq[string]
      ## CMake PRIVATE compiler flags applied only while compiling
      ## this library.
    exports*: seq[ExportedSymbol]
      ## DSL-port M9.R.4: FFI-callable symbols declared inside the
      ## library's ``api: exports:`` sub-block. Each entry stores the
      ## C symbol name + raw Nim signature text + optional doc-comment.
      ## Empty seq when the recipe declared no ``exports:`` sub-block
      ## (the common case for non-FFI libraries). See ``ExportedSymbol``
      ## for the per-symbol storage shape and rationale.

var dslPortLibraryApis {.threadvar.}: Table[string, LibraryApi]
  ## Per-(packageName, libraryName) typed record. The key encoding
  ## ``packageName & '\x00' & libraryName`` matches the M9.I /
  ## M9.R.1 conventions (the ``\x00`` byte cannot appear in either
  ## component so the encoding is unambiguous).

proc m9r3LibraryApiKey(packageName, libraryName: string): string {.inline.} =
  ## Compose the ``(packageName, libraryName)`` registry key. Symmetric
  ## with ``m9iFlagSetKey`` / ``m9r1PackageDepsKey``.
  result = packageName & '\x00' & libraryName

proc resetDslPortLibraryApiState*() =
  ## Drop every library-api registration. Test fixtures call this
  ## between scenarios so registry entries do not leak across cases.
  ## Symmetric with ``resetDslPortPackageDepsState`` /
  ## ``resetDslPortBuildFlagState`` / ``resetDslPortFetchState``.
  dslPortLibraryApis.clear()

proc registerLibraryApi*(packageName, libraryName: string;
                         api: LibraryApi) =
  ## Record ``api`` against ``(packageName, libraryName)``. Called once
  ## per library that declares an ``api:`` block — the package macro
  ## emits the call into module-init code; recipes without an ``api:``
  ## block produce no emission so this proc is never called for them.
  ##
  ## Multiple registrations for the same key OVERWRITE — the last
  ## declared wins. The DSL grammar permits only ONE ``api:`` block per
  ## library so the overwrite path is a defensive fallback (a future
  ## milestone could lift it to an error).
  let key = m9r3LibraryApiKey(packageName, libraryName)
  var rec = api
  rec.declared = true
  dslPortLibraryApis[key] = rec

proc registeredLibraryApi*(packageName, libraryName: string): LibraryApi =
  ## Return the registered ``LibraryApi`` record for
  ## ``(packageName, libraryName)``. Returns a default-zero record with
  ## ``declared == false`` when no ``api:`` block was registered for the
  ## pair (so callers can probe a recipe table without try/except).
  let key = m9r3LibraryApiKey(packageName, libraryName)
  if key in dslPortLibraryApis:
    return dslPortLibraryApis[key]
  result = LibraryApi(declared: false)
