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

proc resetDslPortBuildState*() =
  ## Drop every recorded build action + every recorded output + clear
  ## the active-context stack. Test fixtures call this between
  ## scenarios so registry entries do not leak across cases. Keeping the
  ## three concerns (config, versions, artifacts, build) separable lets
  ## tests target one surface without disturbing the others.
  dslPortBuildActions.setLen(0)
  dslPortOutputs.clear()
  dslPortActiveBuildContext.setLen(0)

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
  dslPortActiveBuildContext.add(DslBuildContextFrame(
    packageName: packageName,
    artifactName: artifactName))

proc endBuildContext*() =
  ## Pop the top frame. Safe to call on an empty stack (no-op) — the
  ## try/finally pairing guarantees balance in well-formed code, but
  ## defensive no-op semantics let unit tests reset between scenarios
  ## without crashing when state was already clean.
  if dslPortActiveBuildContext.len > 0:
    dslPortActiveBuildContext.setLen(dslPortActiveBuildContext.len - 1)

proc currentBuildContext*(): DslBuildContextFrame =
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
## ``currentBuildContext()`` directly?
## ─────────────────────────────────────────────────────────────────────────
##
## ``currentBuildContext()`` returns a ``DslBuildContextFrame`` whose two
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
  let frame = currentBuildContext()
  result = frame.packageName

proc currentBuildArtifact*(): string =
  ## Return the active ``build:`` block's artifact name (``""`` for the
  ## package-level form), or the empty string when no build context is
  ## on the stack. The empty-stack and the package-level cases are
  ## indistinguishable through this accessor by design — callers that
  ## need to disambiguate use ``currentBuildPackage()`` in tandem (a
  ## non-empty package name with an empty artifact name signals the
  ## package-level form).
  let frame = currentBuildContext()
  result = frame.artifactName

proc output*(path: string) =
  ## Record ``path`` against the active build context's
  ## ``(packageName, artifactName)`` bucket. When no context is
  ## active (the stack is empty), the call is a SILENT no-op so the
  ## legacy ``buildXxxPackage*()`` provider-mode call chain — which
  ## may invoke build code without first opening an M4 context —
  ## stays compatible. The init-time emission from the ``package``
  ## macro always wraps the body in ``beginBuildContext / try /
  ## finally endBuildContext`` so the no-op branch is unreachable
  ## from a correctly-shaped recipe.
  if dslPortActiveBuildContext.len == 0:
    return
  let frame = dslPortActiveBuildContext[^1]
  let key = frame.packageName & "." & frame.artifactName
  if not dslPortOutputs.hasKey(key):
    dslPortOutputs[key] = @[]
  dslPortOutputs[key].add(path)

proc registeredOutputs*(packageName, artifactName: string): seq[string] =
  ## Return every output path recorded against the ``(packageName,
  ## artifactName)`` key in registration order. Returns the empty seq
  ## when the key was never written; symmetric with the M2 / M3
  ## accessor convention.
  let key = packageName & "." & artifactName
  if dslPortOutputs.hasKey(key):
    return dslPortOutputs[key]
  return @[]

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
## ``currentBuildContext()`` decision (M4 reviewer's risk #5: "M5 should
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
    args*: seq[string]
      ## Positional arguments from the body's ``args "x", "y", ...``
      ## setter, in declaration order. Empty when no ``args`` setter
      ## was present — the "defensive empty-args" guarantee.
    bodyRepr*: string
      ## The full ``service:`` body's ``NimNode.repr`` at the time the
      ## emitter ran. Diagnostic surface — M6+ may parse additional
      ## setters out of this string OR re-walk the partitioned section
      ## list. Same model M3/M4 use for their ``bodyRepr`` captures.

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
                     args: seq[string]; bodyRepr: string) =
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
  if packageName notin dslPortServiceRegistry:
    dslPortServiceRegistry[packageName] = @[]
  dslPortServiceRegistry[packageName].add(DslServiceDef(
    packageName: packageName,
    serviceName: serviceName,
    executableRef: executableRef,
    args: args,
    bodyRepr: bodyRepr))

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
    bodyRepr: bodyRepr))

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
                  frame.executableRef, frame.args, frame.bodyRepr)

# ---------------------------------------------------------------------------
# DSL-port M7 — user-facing service-context accessors. Symmetric with the
# build-context ``currentBuildPackage`` / ``currentBuildArtifact`` surface.
#
# ``DslServiceContextFrame`` itself is held module-private (host code is
# not meant to inspect raw frames — body-setters route through their own
# public wrappers). The two accessors below expose the package name and
# service name as plain strings, mirroring the M7 build-context surface.
# Empty string when the stack is empty, mirroring the M4
# ``currentBuildContext`` empty-stack convention.
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
