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
    ## (``int``, ``string``, ``bool``, ``float``). Future kinds (e.g.
    ## ``seq[string]``) widen this enum WITHOUT a schema bump because
    ## ``readConfigurable[T]`` raises ``EDslPortTypeMismatch`` when a
    ## caller asks for the wrong type — never silently coerces.
    dskBool
    dskInt
    dskString
    dskFloat

  DslScalarValue* = object
    ## Discriminated record holding one configurable's payload. Stored
    ## in both the default-value table and the override table.
    case kind*: DslScalarKind
    of dskBool: boolVal*: bool
    of dskInt: intVal*: int
    of dskString: strVal*: string
    of dskFloat: floatVal*: float

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
  let key = packageName & "." & name
  when T is bool:
    recordConfigDefaultRaw(key, dslScalarBool(default))
  elif T is SomeInteger:
    recordConfigDefaultRaw(key, dslScalarInt(int(default)))
  elif T is string:
    recordConfigDefaultRaw(key, dslScalarString(default))
  elif T is SomeFloat:
    recordConfigDefaultRaw(key, dslScalarFloat(float(default)))
  else:
    {.error: "recordConfigDefault: unsupported configurable type " &
       $T & "; M2 supports bool / int / string / float".}

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
  else:
    {.error: "readConfigurable: unsupported type " & $T &
       "; M2 supports bool / int / string / float".}

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
  else:
    {.error: "setConfigurable: unsupported type " & $T &
       "; M2 supports bool / int / string / float".}

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
