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
##   stored type does not match the requested ``T``; raises
##   ``EDslPortUnsatisfiedRequired`` when the key is a REQUIRED
##   configurable (declared with no default,
##   ``recordConfigRequired[T]``) that nothing has satisfied — the
##   stored row is then a SHAPE and not a value, and this is the one
##   lane it can be reached through.
##
## * ``setConfigurable[T]`` — store an override against the key.
##
## * ``resetConfigurable`` — drop any override so the default
##   re-emerges, or, for a REQUIRED key (one with no default), so the
##   slot returns to UNSATISFIED and the next read raises.
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
    dskSeqString

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
    of dskSeqString:
      ## Shared-Development-Services L8 — the ORDERED COLLECTION arm,
      ## and the only kind a CONTRIBUTION POINT may have today.
      ##
      ## The enum's own doc comment above predicted this one: "Future
      ## kinds (e.g. ``seq[string]``) widen this enum WITHOUT a schema
      ## bump". It is appended LAST so no existing ordinal moves.
      ##
      ## WHY ``seq[string]`` HAD NO SLOT BEFORE, which is a gap and not
      ## a design: ``recordConfigDefault`` carried ``seq[Enum]`` and
      ## fell through to a static error for every other element type,
      ## and ``m2TypeReprIsSupportedScalar`` rejected ``seq[string]`` by
      ## name. So an activity that declared ``relyingParties:
      ## seq[string]`` got NO configurable cell -- the key was simply
      ## not registered, and the environment walker then refused a
      ## binding to it with a diagnostic about a type "the configurable
      ## lane does not carry". L8 needs exactly that type, because §5's
      ## contribution point is "a configurable whose type is a
      ## collection".
      seqStrVals*: seq[string]

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

  EDslPortUnsatisfiedRequired* = object of CatchableError
    ## Raised when a REQUIRED configurable is read while nothing has
    ## satisfied it.
    ##
    ## Shared-Development-Services L5 (§6). A ``config:`` key declared
    ## WITHOUT a default is a **required configurable**: the slot
    ## exists, and it has NO SEED. Two things may satisfy it -- an
    ## ``environment`` binding (§6) or an argument at
    ## ``enable <activity>(...)`` (L2) -- and until one of them does,
    ## the cell holds the type's zero value as a SHAPE and not as a
    ## value, so reading it has to raise rather than hand back a zero
    ## somebody could mistake for the author's intent.
    ##
    ## Deliberately NOT a subtype of ``EDslPortMissingKey``: the
    ## fallback-flavoured ``readConfigurable`` overloads catch that one
    ## and return their fallback, which is exactly the silent
    ## substitution this exception exists to prevent.

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

var dslPortRequired: Table[string, bool]
  ## The REQUIRED keys: a slot exists, with NO seed. Written by
  ## ``recordConfigRequired``; a key is satisfied once ``dslPortOverrides``
  ## carries a row for it (an ``environment`` binding goes through
  ## ``setConfigurable``, which writes exactly that row).
  ##
  ## A separate registry rather than a sentinel inside
  ## ``DslScalarValue``: the discriminated record is what
  ## ``setConfigurableRaw``'s KIND check compares, so a required key has
  ## to carry a real kind in ``dslPortDefaults`` for a binding to be
  ## accepted at all. "Which kind" and "is there a seed" are two facts,
  ## and folding them into one field would make an unsatisfied key
  ## unbindable.

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

proc dslScalarSeqString*(values: seq[string]): DslScalarValue =
  ## Shared-Development-Services L8 constructor for the ordered-collection
  ## arm. The members are stored VERBATIM and in order; nothing sorts,
  ## dedupes or normalises them here, because §5's merge rule for an
  ## ordered collection is "append in contribution order" and a
  ## constructor that reordered would make the fold's own ordering
  ## unobservable.
  DslScalarValue(kind: dskSeqString, seqStrVals: values)

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
  dslPortRequired.clear()
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

proc recordConfigRequiredRaw*(key: string; shape: DslScalarValue) =
  ## Register a REQUIRED configurable: the slot exists and has NO seed.
  ##
  ## Shared-Development-Services L5 (§6) and the conflation this undoes.
  ## "No default" used to mean "no slot": ``emitL5ActivityConfigDefaults``
  ## skipped a key whose ``config:`` entry carried no ``= default``,
  ## nothing was ever registered, and an ``environment`` binding to it
  ## was refused at compile time -- which made
  ## ``Shared-Development-Services.md``'s OWN worked examples (§6, line
  ## 421; §9.1, line 646) illegal, because both declare
  ## ``externalDomain: string`` with no default and bind it from an
  ## ``environment`` block. A key with no default is not slotless; it is
  ## REQUIRED.
  ##
  ## ``shape`` is the type's zero value and is stored for ONE reason: it
  ## is what ``setConfigurableRaw``'s kind check compares an incoming
  ## binding against, so without it no binding could be accepted. It is
  ## never a readable value -- ``dslPortLookup`` raises
  ## ``EDslPortUnsatisfiedRequired`` for a key in ``dslPortRequired``
  ## that has no override row, so the zero cannot leak out as if the
  ## author had written it.
  if key notin dslPortDefaults:
    dslPortKeyOrder.add(key)
  dslPortDefaults[key] = shape
  dslPortRequired[key] = true

proc recordConfigRequired*[T](packageName, name: string) =
  ## Generic facade -- the ``package`` macro emits one call per
  ## ``config:`` key declared ``name: T`` with no ``= default``.
  ##
  ## The ``T`` set is the one ``recordConfigDefault`` carries, because
  ## the slot set has to be decided by ONE predicate over both
  ## authoring surfaces (``m2TypeReprIsSupportedScalar``). A key whose
  ## type the configurable lane does not carry gets no slot at all,
  ## required or not, and the environment walker refuses a binding to it
  ## by name -- a DIFFERENT refusal from this one, and deliberately not
  ## merged with it.
  let key = packageName & "." & name
  when T is bool:
    recordConfigRequiredRaw(key, dslScalarBool(false))
  elif T is SomeInteger:
    recordConfigRequiredRaw(key, dslScalarInt(0))
  elif T is string:
    recordConfigRequiredRaw(key, dslScalarString(""))
  elif T is SomeFloat:
    recordConfigRequiredRaw(key, dslScalarFloat(0.0))
  elif T is enum:
    recordConfigRequiredRaw(key, dslScalarEnum(T.low.ord, $T, $T.low))
  elif T is seq:
    var probe: T
    type Elem = typeof(probe[0])
    when Elem is enum:
      recordConfigRequiredRaw(key, dslScalarSeqEnum($Elem,
        newSeq[(int, string)]()))
    else:
      {.error: "recordConfigRequired: unsupported configurable type " &
         $T & "; M9.D seq support is restricted to seq[Enum]".}
  else:
    {.error: "recordConfigRequired: unsupported configurable type " &
       $T & "; M2/M9.D supports bool / int / string / float / enum / seq[enum]".}

proc configurableIsRequired*(key: string): bool =
  ## Whether ``key`` was declared without a default -- i.e. has a slot
  ## and no seed.
  key in dslPortRequired

proc configurableIsSatisfied*(key: string): bool =
  ## Whether ``key`` holds a value something actually supplied.
  ##
  ## True for every key that is not required (its seed IS a value the
  ## author wrote), and for a required key once a contribution has
  ## written an override row. An ``environment`` binding is such a row,
  ## because ``bindEnvironmentConfigurable`` delegates to
  ## ``setConfigurable``.
  (key notin dslPortRequired) or (key in dslPortOverrides)

proc unsatisfiedRequiredConfigKeys*(): seq[string] =
  ## Every required key nothing has satisfied, in registration order.
  for key in dslPortKeyOrder:
    if key in dslPortRequired and key notin dslPortOverrides:
      result.add(key)

proc configurableOverrideSnapshot*(): Table[string, DslScalarValue] =
  ## A copy of the override table, for a caller that must apply a GROUP
  ## of overrides all-or-nothing. `restoreConfigurableOverrides` puts it
  ## back.
  ##
  ## WHY THIS IS PUBLIC AND WHO NEEDS IT. An `environment <name>:`
  ## applies several bindings in sequence (§6), and before this existed
  ## a binding that raised partway left the EARLIER bindings in force:
  ## the environment was applied PARTIALLY, which is worse than either
  ## outcome -- the author sees an error, and the process continues with
  ## a configuration no environment declares. `applyEnvironment` now
  ## snapshots, applies, and restores on any failure. The snapshot is
  ## the whole override table rather than the keys the environment names
  ## because the restore has to undo rows the FAILING call may have
  ## written too, and because "set" and "was already set to something
  ## else" are different states that a per-key undo would conflate.
  dslPortOverrides

proc restoreConfigurableOverrides*(snapshot: Table[string, DslScalarValue]) =
  ## Replace the override table with `snapshot`. See
  ## `configurableOverrideSnapshot`.
  dslPortOverrides = snapshot

proc registeredConfigKeys*(): seq[string] =
  ## Return every ``<package>.<name>`` key in insertion order. A copy
  ## so callers cannot mutate the registry.
  result = dslPortKeyOrder

proc isConfigKeyRegistered*(key: string): bool =
  key in dslPortDefaults

# ---------------------------------------------------------------------------
# Shared-Development-Services L8 — CONTRIBUTION POINTS.
#
# `Shared-Development-Services.md` §5 is the authority, and its third
# paragraph is the whole of why there is no new primitive here:
#
#   "This needs no new mechanism. A collection is a configurable."
#
# So a contribution point IS a row in the same `dslPortDefaults` /
# `dslPortKeyOrder` registries every other `config:` key lives in. What
# is new is (a) a collection-typed arm for it to hold (`dskSeqString`)
# and (b) the SECOND AXIS the L5 section above said it was deferring:
#
#   "the CONTRIBUTION operation axis (`append` / `replace`, §5.1) is L8.
#    An environment binding is a `replace` at `epOverride` in the terms
#    L8 will introduce, and this code does not pre-empt the spelling."
#
# That prediction is honoured literally below: `setConfigurableRaw` --
# which is the route an `environment` binding takes -- lands as a
# `coReplace` at `epOverride`, and nothing about the environment lane
# changed to make that true.
#
# WHAT THE PORT COULD NOT DO BEFORE, stated as a limitation at
# `bindEnvironmentConfigurable`: "`epOverride` IS A RECORDED LABEL HERE,
# NOT AN ORDERING THIS PORT CAN ENFORCE ... A later `epForce` does not
# outrank an `epOverride` and an earlier one is not protected from it."
# For a CONTRIBUTION POINT that is no longer true -- the fold below is
# `Configurable-System.md` §Resolution's four steps, so the ladder is
# enforced. It is still true for a SCALAR key, deliberately: changing
# scalar resolution would change the resolved value of every existing
# `config:` key in the repository, which is not L8's gate and would be a
# silent behaviour change across 11 production NDE packages.
# ---------------------------------------------------------------------------

type
  ConfigContribution* = object
    ## ONE contribution to ONE configurable: the (priority, value,
    ## provenance) triple `Configurable-System.md` specifies, plus the
    ## OPERATION that makes the two axes independent.
    key*: string
      ## The configurable's full key, `<package>.<name>` or
      ## `<package>.<activity>.<name>` -- byte-identical to the key
      ## `recordConfigDefault` registers, which is what makes a
      ## contribution a contributor into the EXISTING table rather than
      ## a second one.
    package*: string
      ## The CONTRIBUTING package. This is the attribution §5 requires
      ## ("every converged member can already name the package that
      ## contributed it, and a withdrawn dependency's members can be
      ## identified for removal").
      ##
      ## IT IS A FIELD AND NOT DERIVED FROM `sourceFile`, and the
      ## distinction is load-bearing for `withdrawPackageContributions`:
      ## a file path does not name a package (one file may lower several
      ## packages, and a generated recipe's path names no package at
      ## all), so a withdrawal keyed on the path would remove the wrong
      ## rows. The empty string means "the port itself" -- a
      ## construction default or a `setConfigurable` from code that is
      ## not a package body.
    precedence*: EnvironmentPrecedence
      ## The priority axis. `EnvironmentPrecedence` is REUSED rather
      ## than mirrored a second time: it is already declared as this
      ## library's mirror of `Configurable-System.md`'s
      ## `ContributionPriority`, the drift assertion that keeps the two
      ## aligned already exists
      ## (`tests/dsl_port/t_dsl_environment_binds_configurables.nim`,
      ## "EnvironmentPrecedence mirrors ContributionPriority, ordinal
      ## for ordinal"), and a third spelling of one ladder inside one
      ## library is the drift this campaign has already paid for once.
      ## Its NAME is environment-flavoured; its ROLE from L8 on is the
      ## port's contribution ladder.
    operation*: ContributionOperation
      ## The operation axis, independent of `precedence`.
    value*: DslScalarValue
      ## For `coReplace`, the entire value. For `coAppend`, the members
      ## to add -- so an append carries a `dskSeqString` holding just
      ## its own members, never the running total.
    sourceFile*: string
    sourceLine*: int
      ## The call site, for the step-4 diagnostic. An empty file is a
      ## contribution made from code that captured no site; the
      ## diagnostic says `<unknown site>` rather than rendering `:0`.

  DiscardedContribution* = object
    ## `Configurable-System.md` §Resolution step 4: "Every `append`
    ## whose priority is BELOW R's is **discarded**, and each discard
    ## MUST emit a structured diagnostic naming both sites -- the
    ## discarded contribution and the `replace` that superseded it."
    ##
    ## STRUCTURED, not a string. A caller that wants the message calls
    ## `renderDiscardedContribution`; a caller that wants to assert on
    ## which site lost reads the fields. A pre-rendered string would
    ## make the second impossible, and step 4's whole purpose is that
    ## the engine "can say which contribution was dropped and which one
    ## dropped it".
    key*: string
    discarded*: ConfigContribution
    supersededBy*: ConfigContribution

  ContributionFold* = object
    ## The result of folding one contribution point: the resolved
    ## members, who contributed each one, and what was discarded.
    members*: seq[string]
    memberPackages*: seq[string]
      ## Parallel to `members`: the contributing package of each. Two
      ## parallel seqs rather than a seq of tuples so `members` can be
      ## handed to `dslScalarSeqString` without a rebuild.
    discarded*: seq[DiscardedContribution]

  EDslPortNotAContributionPoint* = object of CatchableError
    ## Raised when `coAppend` is aimed at a key that is not a
    ## contribution point. "Append 4 to the worker count" is not a thing
    ## an author can have meant, so it is refused BY NAME rather than
    ## silently treated as a replace -- which is the shape of defect
    ## this campaign has found twenty-plus times.

  EDslPortDuplicateForceReplace* = object of CatchableError
    ## `Configurable-System.md` §"`prForce` is limited per operation,
    ## not per configurable": "at most one `prForce` `replace` per
    ## configurable, and a second is an error". SEVERAL `prForce`
    ## APPENDS ARE NOT AN ERROR and must not raise this -- that is the
    ## distinction the one-axis rule got wrong.

  EDslPortContradictoryReplace* = object of CatchableError
    ## §Resolution step 1: "Several `replace` contributions tied at that
    ## priority resolve by the equal-priority rules above -- which for a
    ## collection is an **error**, because two different 'the value is
    ## exactly this' claims at equal authority are a genuine
    ## contradiction rather than something to merge."
    ##
    ## Two claims with the SAME value are not a contradiction and do not
    ## raise: that is a replay, not a disagreement.

var dslPortContributionPoints: Table[string, bool]
  ## Every key declared as a contribution point. A separate registry
  ## from `dslPortDefaults` for the reason `dslPortRequired` is separate:
  ## "which kind" and "is this a contribution point" are two facts, and
  ## a key's kind alone cannot decide the second -- a plain
  ## `seq[string]` scalar key would be indistinguishable from a
  ## contribution point if the discriminant were the only evidence.

var dslPortContributions: Table[string, seq[ConfigContribution]]
  ## Every contribution to every contribution point, in contribution
  ## order. `Configurable-System.md`'s `c.contributions` for this port.

var dslPortContributionPointOrder: seq[string]
  ## Insertion-order list of contribution-point keys, for stable
  ## enumeration (same reason `dslPortKeyOrder` exists).

proc isContributionPoint*(key: string): bool =
  ## Whether `key` was declared as an ordered-collection contribution
  ## point.
  key in dslPortContributionPoints

proc registeredContributionPoints*(): seq[string] =
  ## Every contribution-point key in declaration order.
  result = dslPortContributionPointOrder

proc recordContributionPointRaw*(key: string; default: DslScalarValue;
                                 sourceFile = ""; sourceLine = 0) =
  ## Declare `key` as an ordered-collection contribution point whose
  ## construction default is `default`.
  ##
  ## The default is recorded as a `coReplace` contribution at
  ## `epDefault`, which is what makes §Resolution's steps 1 and 2
  ## collapse correctly rather than needing a special case: "the base
  ## value is R's value, or the construction default when there is no
  ## `replace`" -- with the default itself a replace at the bottom rung,
  ## R always exists and step 2 is just "R's value".
  ##
  ## IDEMPOTENT ON REPLAY. A module-init replay re-runs this; the second
  ## call leaves the existing rows alone, exactly as
  ## `recordConfigDefault` does. Without that, `rerunServiceDeclarators`
  ## would double every default.
  if default.kind != dskSeqString:
    raise newException(EDslPortTypeMismatch,
      "recordContributionPoint('" & key & "'): a contribution point " &
      "must be an ordered collection (dskSeqString), not " &
      $default.kind)
  if key in dslPortContributionPoints:
    return
  if key notin dslPortDefaults:
    dslPortKeyOrder.add(key)
  dslPortDefaults[key] = default
  dslPortContributionPoints[key] = true
  dslPortContributionPointOrder.add(key)
  dslPortContributions[key] = @[ConfigContribution(
    key: key, package: "", precedence: epDefault, operation: coReplace,
    value: default, sourceFile: sourceFile, sourceLine: sourceLine)]

proc recordContributionPoint*[T](packageName, name: string; default: T;
                                 sourceFile = ""; sourceLine = 0) =
  ## Generic facade. `T` is `seq[string]` today and the static error
  ## names the restriction rather than falling through to a scalar arm.
  ##
  ## A CONTRIBUTION POINT DECLARED WITHOUT A DEFAULT IS *NOT* REQUIRED,
  ## and the `config:` lowering passes `@[]` for it. L5's rule -- "a key
  ## with no default is REQUIRED" -- is right for a scalar and wrong
  ## for a collection: "no relying parties have been contributed yet" is
  ## a VALUE, not an absence, and raising `EDslPortUnsatisfiedRequired`
  ## for it would make a contribution point unreadable until somebody
  ## contributed, i.e. would make the owner's own `renderConfig` fail on
  ## a workspace where no consumer is enabled.
  when T is seq[string]:
    recordContributionPointRaw(packageName & "." & name,
      dslScalarSeqString(default), sourceFile, sourceLine)
  else:
    {.error: "recordContributionPoint: unsupported contribution-point " &
       "type " & $T & "; L8 carries seq[string]".}

proc contributionRowsEqual(a, b: ConfigContribution): bool =
  a.key == b.key and a.package == b.package and
    a.precedence == b.precedence and a.operation == b.operation and
    a.sourceFile == b.sourceFile and a.sourceLine == b.sourceLine and
    a.value.kind == b.value.kind and
    a.value.seqStrVals == b.value.seqStrVals

proc renderContributionSite*(c: ConfigContribution): string =
  ## One contribution's site, for a diagnostic. Names the package as
  ## well as the file, because "which package" is the fact an author
  ## acts on and a path may not reveal it.
  let where =
    if c.sourceFile.len == 0: "<unknown site>"
    else: c.sourceFile & ":" & $c.sourceLine
  let who = if c.package.len == 0: "<the port>" else: c.package
  who & " at " & where & " (" & $c.operation & ", " & $c.precedence & ")"

proc renderDiscardedContribution*(d: DiscardedContribution): string =
  ## §Resolution step 4's diagnostic, naming BOTH sites.
  "contribution to `" & d.key & "` was DISCARDED: the " &
    $d.discarded.operation & " contributed by " &
    renderContributionSite(d.discarded) &
    " is below the winning replace contributed by " &
    renderContributionSite(d.supersededBy) &
    ", so its members are not present. Raise the append to " &
    $d.supersededBy.precedence &
    " or stop replacing the collection."

proc foldContributionRows*(key: string;
                           rows: seq[ConfigContribution]): ContributionFold =
  ## `Configurable-System.md` §Resolution, the four steps, in order,
  ## over an EXPLICIT row set.
  ##
  ## WHY THIS IS THE ONE WITH THE ALGEBRA IN IT. D-SS11's cross-process
  ## lane folds rows that were written by ANOTHER PROCESS and read back
  ## from a store, so they are not in `dslPortContributions` and cannot
  ## be. Folding them with a second implementation would mean two
  ## answers to "which append wins" -- the drift this campaign has paid
  ## for repeatedly -- so the registry-backed `foldContributionPoint`
  ## below is now a one-line caller of this proc and both lanes resolve
  ## by the same four steps.
  ##
  ## `key` is used only in diagnostics; the rows are the whole input.
  # Step 1: R is the highest-priority `replace`.
  var rIdx = -1
  for i in 0 ..< rows.len:
    if rows[i].operation == coReplace:
      if rIdx < 0 or ord(rows[i].precedence) > ord(rows[rIdx].precedence):
        rIdx = i
  if rIdx < 0:
    # Unreachable while `recordContributionPointRaw` seeds a default
    # replace, and asserted rather than assumed: a contribution point
    # with no replace at all would mean the seed row was removed, which
    # `withdrawPackageContributions` is explicitly forbidden to do.
    raise newException(EDslPortNotAContributionPoint,
      "foldContributionPoint('" & key & "'): no `replace` contribution " &
      "remains, not even the construction default -- the seed row was " &
      "removed, which nothing is allowed to do")

  # Step 1b: two DIFFERENT replaces tied at R's priority contradict.
  for i in 0 ..< rows.len:
    if i == rIdx: continue
    if rows[i].operation != coReplace: continue
    if rows[i].precedence != rows[rIdx].precedence: continue
    if rows[i].value.seqStrVals == rows[rIdx].value.seqStrVals: continue
    raise newException(EDslPortContradictoryReplace,
      "two different `replace` contributions to `" & key &
      "` at equal authority: " & renderContributionSite(rows[rIdx]) &
      " claims " & $rows[rIdx].value.seqStrVals & " and " &
      renderContributionSite(rows[i]) & " claims " &
      $rows[i].value.seqStrVals & ". Two 'the value is exactly this' " &
      "claims at one priority are a contradiction, not something to " &
      "merge.")

  # Step 2: the base value is R's.
  result.members = rows[rIdx].value.seqStrVals
  for _ in result.members:
    result.memberPackages.add(rows[rIdx].package)

  # Steps 3 and 4: every append at or above R's priority applies, in
  # priority order and then contribution order; every append below R's
  # is discarded WITH a diagnostic naming both sites.
  for rung in ord(rows[rIdx].precedence) .. ord(high(EnvironmentPrecedence)):
    for i in 0 ..< rows.len:
      if rows[i].operation != coAppend: continue
      if ord(rows[i].precedence) != rung: continue
      for m in rows[i].value.seqStrVals:
        result.members.add(m)
        result.memberPackages.add(rows[i].package)
  for i in 0 ..< rows.len:
    if rows[i].operation != coAppend: continue
    if ord(rows[i].precedence) >= ord(rows[rIdx].precedence): continue
    result.discarded.add(DiscardedContribution(
      key: key, discarded: rows[i], supersededBy: rows[rIdx]))

proc foldContributionPoint*(key: string): ContributionFold =
  ## `Configurable-System.md` §Resolution for a key this process's
  ## registry holds. The four steps live in `foldContributionRows`; this
  ## proc is the registry lookup and nothing else.
  if key notin dslPortContributionPoints:
    raise newException(EDslPortNotAContributionPoint,
      "foldContributionPoint('" & key & "'): not a contribution point")
  foldContributionRows(key, dslPortContributions.getOrDefault(key))

proc configurableContributions*(key: string): seq[ConfigContribution] =
  ## `Configurable-System.md`'s `c.contributions`: every contribution to
  ## `key`, in contribution order, with its priority, operation, value
  ## and provenance. A copy, so a caller cannot mutate the registry.
  dslPortContributions.getOrDefault(key)

proc contributionMemberAttribution*(key: string):
                                    seq[tuple[member, package: string]] =
  ## Every converged member paired with the package that contributed it.
  ## §5's "Attribution" property, read off the fold.
  let folded = foldContributionPoint(key)
  for i in 0 ..< folded.members.len:
    result.add((member: folded.members[i],
                package: folded.memberPackages[i]))

proc discardedContributions*(key: string): seq[DiscardedContribution] =
  ## Every step-4 discard for `key`, recomputed from the current
  ## contribution set. Recomputed rather than accumulated: a cached list
  ## would still name a discard after the `replace` that caused it was
  ## withdrawn.
  foldContributionPoint(key).discarded

proc allDiscardedContributions*(): seq[DiscardedContribution] =
  ## Every step-4 discard across every contribution point, in
  ## declaration order.
  for key in dslPortContributionPointOrder:
    for d in foldContributionPoint(key).discarded:
      result.add(d)

proc contributeConfigurableRaw*(key, package: string;
                                precedence: EnvironmentPrecedence;
                                operation: ContributionOperation;
                                value: DslScalarValue;
                                sourceFile = ""; sourceLine = 0) =
  ## The ONE funnel every contribution goes through.
  ##
  ## IDEMPOTENT ON AN IDENTICAL ROW. A byte-identical contribution --
  ## same key, package, priority, operation, value and site -- is a
  ## replay and is dropped. This is what makes convergence idempotent
  ## structurally rather than by a caller remembering to check:
  ## `rerunServiceDeclarators` re-executes every service and activity
  ## body during provider-graph emission, so every contribution in the
  ## repository is made at least twice.
  if key notin dslPortDefaults:
    raise newException(EDslPortMissingKey,
      "contributeConfigurable: no configurable registered for key '" &
      key & "' -- declare it in a `config:` block first")
  if operation == coAppend and key notin dslPortContributionPoints:
    raise newException(EDslPortNotAContributionPoint,
      "contributeConfigurable('" & key & "'): `append` is only " &
      "available on an ordered-collection contribution point; `" & key &
      "` is a " & $dslPortDefaults[key].kind & " scalar. A scalar's " &
      "only operation is `replace` (Configurable-System.md " &
      "§\"Operation is a SECOND axis\").")
  let registered = dslPortDefaults[key]
  if registered.kind != value.kind:
    raise newException(EDslPortTypeMismatch,
      "contributeConfigurable('" & key & "'): contribution kind " &
      $value.kind & " does not match registered kind " &
      $registered.kind)
  let row = ConfigContribution(key: key, package: package,
    precedence: precedence, operation: operation, value: value,
    sourceFile: sourceFile, sourceLine: sourceLine)
  var rows = dslPortContributions.getOrDefault(key)
  if precedence == epForce and operation == coReplace:
    for existing in rows:
      if existing.precedence == epForce and existing.operation == coReplace:
        if contributionRowsEqual(existing, row):
          return
        raise newException(EDslPortDuplicateForceReplace,
          "`" & key & "` already has a `force` `replace` contributed " &
          "by " & renderContributionSite(existing) & "; " &
          renderContributionSite(row) & " is a second one. At most one " &
          "`force` `replace` per configurable (Configurable-System.md " &
          "§\"`prForce` is limited per operation\"). Several `force` " &
          "`append` contributions are NOT a contradiction and are " &
          "permitted.")
  for existing in rows:
    if contributionRowsEqual(existing, row):
      return
  rows.add(row)
  dslPortContributions[key] = rows

proc contributeConfigurable*[T](key, package: string;
                                precedence: EnvironmentPrecedence;
                                operation: ContributionOperation;
                                value: T;
                                sourceFile = ""; sourceLine = 0) =
  ## Generic facade over `contributeConfigurableRaw`.
  when T is seq[string]:
    contributeConfigurableRaw(key, package, precedence, operation,
      dslScalarSeqString(value), sourceFile, sourceLine)
  elif T is string:
    contributeConfigurableRaw(key, package, precedence, operation,
      dslScalarString(value), sourceFile, sourceLine)
  elif T is bool:
    contributeConfigurableRaw(key, package, precedence, operation,
      dslScalarBool(value), sourceFile, sourceLine)
  elif T is SomeInteger:
    contributeConfigurableRaw(key, package, precedence, operation,
      dslScalarInt(int(value)), sourceFile, sourceLine)
  else:
    {.error: "contributeConfigurable: unsupported type " & $T.}

proc withdrawPackageContributions*(package: string): int {.discardable.} =
  ## Remove every contribution `package` made, and NOTHING else.
  ##
  ## §5's second attribution property: "a withdrawn dependency's members
  ## can be identified for removal". A withdrawal that also dropped the
  ## construction default would leave the point unresolvable, so the
  ## seed row -- `package == ""` at `epDefault` -- is explicitly held:
  ## `withdrawPackageContributions("")` removes no seed, and the fold's
  ## "no replace remains" refusal is the control that says so.
  ##
  ## Returns the number of rows removed, so a caller can tell "withdrew
  ## nothing" from "withdrew everything" rather than guessing.
  for key in dslPortContributionPointOrder:
    var kept: seq[ConfigContribution] = @[]
    for row in dslPortContributions.getOrDefault(key):
      if row.package == package and
         not (row.package.len == 0 and row.precedence == epDefault and
              row.operation == coReplace):
        inc result
      else:
        kept.add(row)
    dslPortContributions[key] = kept

proc l8ContributionMembers*(v: string): seq[string] =
  ## One member, written as a bare string at the contribution site.
  ## Shared-Development-Services L8: both `x = "a"` and `x = @["a","b"]`
  ## are authorable, and the two overloads are what makes the single
  ## emitted call shape carry either without the macro having to decide
  ## the author's type.
  @[v]

proc l8ContributionMembers*(v: seq[string]): seq[string] =
  ## Several members, written as a seq literal at the contribution site.
  v

proc contributeMembers*(key, package: string;
                        precedence: EnvironmentPrecedence;
                        operation: ContributionOperation;
                        members: seq[string];
                        sourceFile = ""; sourceLine = 0) =
  ## The call the `contribute:` lowering emits, one per contribution.
  contributeConfigurableRaw(key, package, precedence, operation,
    dslScalarSeqString(members), sourceFile, sourceLine)

# ---------------------------------------------------------------------------
# Shared-Development-Services D-SS11 (§4.6) — the RESOLVER's runtime
# record, and the CROSS-PROCESS contribution lane's consumer end.
#
# §4.6 decides three things together, and this is the third: "the
# consumer's contributions are **arguments of the resolver call**,
# carried on the interface the owner already lifts, and applied by the
# owner's instance when it converges."
#
# WHY A REGISTRY HERE AND NOT A CONTRIBUTION. `contributeMembers` is the
# INTRA-PROCESS lane: it writes into `dslPortContributions`, which is a
# table of this process, folded by this process's `mergeTypedServiceFacts`
# for services this process declares. A consumer does not declare the
# owner's service, so there is no fold here for its members to land in,
# and writing them into `dslPortContributions` would be precisely the
# "declared, looks wired, does nothing" defect L9's F2 measured: in the
# consumer's process the fold would show the member and the owner's
# instance would never see it.
#
# So a resolver records a RESOLUTION instead. The resolution travels on
# the consumer's dev-env artifact to the consumer's `repro up`, which
# attaches to the instance and deposits the contributions in the
# instance's own identity-keyed store, where the OWNER's converge reads
# them. Every step of that is a different process reading a file the
# previous one wrote, which is what makes the lane cross-process rather
# than a second name for the intra-process one.
# ---------------------------------------------------------------------------

type
  EDslPortSharedServiceRefusal* = object of CatchableError
    ## Every refusal of this surface. A resolver that cannot be honoured
    ## raises; none of them returns a handle that does nothing.

var dslPortSharedResolutions: seq[SharedServiceResolution]
  ## Every resolver call this evaluation made, in call order.

var dslPortResolverPackages: seq[string]
  ## The stack of packages whose dev-env bodies are being lowered. A
  ## STACK and not a scalar because one process lowers several packages
  ## (a sibling `include` shim expands two `package` blocks), and a
  ## scalar would leave the second attributing its resolvers to the
  ## first after the first's `finally` cleared it.

proc beginResolverPackage*(packageName: string) =
  ## Enter `packageName`'s dev-env lowering. Emitted by the `package`
  ## macro around the generated `devEnv<Pkg>Package()` body.
  dslPortResolverPackages.add(packageName)

proc endResolverPackage*() =
  ## Leave it. Emitted in a `finally`, so a body that raises does not
  ## leak the ambient into whatever is lowered next.
  if dslPortResolverPackages.len > 0:
    dslPortResolverPackages.setLen(dslPortResolverPackages.len - 1)

proc currentResolverPackage*(): string =
  ## The package a resolver call is being evaluated for, or "" outside
  ## any dev-env lowering. `resolveSharedService` REFUSES the empty
  ## case rather than recording an unattributed contribution.
  if dslPortResolverPackages.len == 0: ""
  else: dslPortResolverPackages[^1]

proc resetSharedServiceResolutions*() =
  ## Drop every recorded resolution. Called by the port's own reset
  ## between test cases, and by nothing in a recipe.
  dslPortSharedResolutions.setLen(0)
  dslPortResolverPackages.setLen(0)

proc registeredSharedServiceResolutions*(): seq[SharedServiceResolution] =
  ## The resolutions recorded so far, in call order.
  dslPortSharedResolutions

proc sharedResolutionsEqual(a, b: SharedServiceResolution): bool =
  ## Whether two resolutions are the SAME call, site included. Used only
  ## to drop a replay; a difference in anything is a real second
  ## resolver and is refused rather than merged.
  if a.declaration != b.declaration: return false
  if a.consumerPackage != b.consumerPackage: return false
  if a.sourceFile != b.sourceFile or a.sourceLine != b.sourceLine:
    return false
  if a.contributions.len != b.contributions.len: return false
  for i in 0 ..< a.contributions.len:
    if a.contributions[i] != b.contributions[i]: return false
  return true

proc renderSharedResolutionSite(r: SharedServiceResolution): string =
  if r.sourceFile.len == 0: "<unknown site>"
  else: r.sourceFile & ":" & $r.sourceLine

proc resolveSharedService*[T](declaration: SharedServiceDeclarationDef;
                              consumerPackage: string;
                              contributions: seq[SharedContributionDef];
                              sourceFile = ""; sourceLine = 0):
    SharedServiceHandle[T] =
  ## THE RESOLVER. `<package>.<service>.shared(...)` lowers to this.
  ##
  ## It records the resolution and returns a handle. It does NOT contact
  ## the daemon, take a lease or compare a fingerprint: evaluation
  ## happens while the dev-env artifact is being produced, before any
  ## instance exists to decide against. §4.6's "the resolver is where
  ## the machinery of §4 is triggered" is honoured by the resolution
  ## travelling to `repro up`, which resolves `(identity, scope,
  ## environment)`, takes the lease and runs §4.3's attach decision AT
  ## THIS CALL SITE -- the site is carried in the record so the
  ## diagnostic lands on the consumer's own line, which is the property
  ## §4.6 asks for ("a fingerprint mismatch warns *here*, at a named
  ## call site in the consumer's recipe").
  ##
  ## FOUR REFUSALS, NONE OF THEM A DROP:
  ##   1. a declaration with no owner package or no service name -- a
  ##      const that was not produced by the lift;
  ##   2. a contribution naming a point the DECLARATION does not carry
  ##      (the resolver macro refuses this at compile time; this is the
  ##      same check for a direct caller, because a public proc that
  ##      trusted its arguments would make the macro's check the only
  ##      one and a library caller's mistake silent);
  ##   3. a `replace` operation -- §5.1 / D-SS9;
  ##   4. a SECOND resolver for one service in one consumer package.
  ##      Two resolvers would take two leases and deposit two
  ##      contribution sets for one key, and the second write would have
  ##      to either lose or duplicate the first. A byte-identical replay
  ##      is not a second resolver and is dropped silently, because
  ##      module init replays (`rerunServiceDeclarators`).
  if consumerPackage.len == 0:
    raise newException(EDslPortSharedServiceRefusal,
      "shared(" & declaration.ownerPackage & "." &
      declaration.serviceName & "): no CONSUMING package is in scope, " &
      "so this resolution could not be attributed to one. A resolver " &
      "belongs at an `enable <activity>(...)` call inside a " &
      "`devEnv:` block of a `package` body " &
      "(Shared-Development-Services.md §4.6: \"In the consuming " &
      "project's own recipe, at its `enable <activity>(...)` call\"), " &
      "which is the scope that names the contributor. An " &
      "unattributed contribution is refused rather than recorded: §5 " &
      "requires every converged member to name the package that " &
      "contributed it, and a blank contributor can never be withdrawn.")
  if declaration.ownerPackage.len == 0 or declaration.serviceName.len == 0:
    raise newException(EDslPortSharedServiceRefusal,
      "shared(): the declaration record names no owner package or no " &
      "service (" & declaration.ownerPackage & "." &
      declaration.serviceName & "). A resolver is spelled against a " &
      "declaration the OWNER's interface lift produced; a hand-built " &
      "one is refused rather than resolved against a default key.")
  for c in contributions:
    if c.point.len == 0:
      raise newException(EDslPortSharedServiceRefusal,
        "shared(" & declaration.ownerPackage & "." &
        declaration.serviceName & "): a contribution names no point. " &
        "An unnamed contribution cannot be matched against a declared " &
        "point, so it is refused rather than carried to an instance " &
        "that would ignore it.")
    if c.operation != coAppend:
      # STAGE 2 of §5.1's three refusals, and it is NOT redundant with
      # the macro's: this runs on a `SharedServiceResolution` VALUE, so
      # it is what refuses a resolution the resolver macro did not write.
      # The judgement is the shared one; the subject and the stage note
      # are local.
      raise newException(EDslPortSharedServiceRefusal,
        "shared(" & declaration.ownerPackage & "." &
        declaration.serviceName & "): `" & c.point & "` is contributed " &
        "with `" & $c.operation & "`. " & sharedServiceReplaceRefusal() &
        " Refused at EVALUATION, where the resolution record is read " &
        "rather than written, so a resolution the resolver macro did " &
        "not produce is refused too.")
    if not declaration.contributionPoints.contains(c.point):
      raise newException(EDslPortSharedServiceRefusal,
        "shared(" & declaration.ownerPackage & "." &
        declaration.serviceName & "): service `" &
        declaration.serviceName & "` of package `" &
        declaration.ownerPackage & "` declares no contribution point " &
        "`" & c.point & "`. It converges " &
        (if declaration.contributionPoints.len == 0: "no points at all"
         else: "`" & declaration.contributionPoints.join("`, `") & "`") &
        ". Shared-Development-Services.md §4.6: a contribution to a " &
        "point the instance does not declare is REFUSED, never dropped.")
  let row = SharedServiceResolution(
    declaration: declaration, consumerPackage: consumerPackage,
    contributions: contributions,
    sourceFile: sourceFile, sourceLine: sourceLine)
  for existing in dslPortSharedResolutions:
    if existing.declaration.ownerPackage != declaration.ownerPackage or
       existing.declaration.serviceName != declaration.serviceName or
       existing.consumerPackage != consumerPackage:
      continue
    if sharedResolutionsEqual(existing, row):
      return SharedServiceHandle[T](
        ownerPackage: declaration.ownerPackage,
        serviceName: declaration.serviceName,
        activityName: declaration.activityName,
        consumerPackage: consumerPackage,
        sourceFile: sourceFile, sourceLine: sourceLine)
    raise newException(EDslPortSharedServiceRefusal,
      "package `" & consumerPackage & "` resolves `" &
      declaration.ownerPackage & "." & declaration.serviceName &
      "` twice: " & renderSharedResolutionSite(existing) & " and " &
      (if sourceFile.len == 0: "<unknown site>"
       else: sourceFile & ":" & $sourceLine) &
      ". One consumer takes ONE lease on one instance and deposits ONE " &
      "contribution set for it, so a second resolver would have to " &
      "either lose or duplicate the first's contributions. Resolve " &
      "once and pass the handle to every activity that needs it.")
  dslPortSharedResolutions.add(row)
  SharedServiceHandle[T](
    ownerPackage: declaration.ownerPackage,
    serviceName: declaration.serviceName,
    activityName: declaration.activityName,
    consumerPackage: consumerPackage,
    sourceFile: sourceFile, sourceLine: sourceLine)

proc sharedContribution*(point: string; members: seq[string];
                         precedence = epSet;
                         operation = coAppend;
                         sourceFile = ""; sourceLine = 0):
    SharedContributionDef =
  ## One contribution, as the resolver macro builds it.
  SharedContributionDef(point: point, operation: operation,
    precedence: precedence, members: members,
    sourceFile: sourceFile, sourceLine: sourceLine)

proc contributionRowsOfResolution*(r: SharedServiceResolution;
                                   resolveKey: proc (point: string): string):
    seq[ConfigContribution] =
  ## Project one resolution's contributions onto the SAME row type the
  ## intra-process lane folds (`ConfigContribution`), so the
  ## cross-process fold is `foldContributionRows` and not a second
  ## algebra. `resolveKey` maps a bare point name to the owner's
  ## fully-qualified configurable key; the caller supplies it because
  ## only the owner knows its own activity name.
  for c in r.contributions:
    result.add(ConfigContribution(
      key: resolveKey(c.point), package: r.consumerPackage,
      precedence: c.precedence, operation: c.operation,
      value: dslScalarSeqString(c.members),
      sourceFile: c.sourceFile, sourceLine: c.sourceLine))

proc contributionSnapshot*(): Table[string, seq[ConfigContribution]] =
  ## A copy of the contribution registry, for a caller that must apply a
  ## GROUP of contributions all-or-nothing -- the same contract
  ## `configurableOverrideSnapshot` has, and needed for the same reason:
  ## `applyEnvironment` binds several configurables in sequence and one
  ## of them may be a contribution point, so a partial apply has to be
  ## undoable on both registries or neither.
  dslPortContributions

proc restoreContributions*(snapshot: Table[string, seq[ConfigContribution]]) =
  ## Replace the contribution registry with `snapshot`.
  dslPortContributions = snapshot

proc dslPortLookup(key: string): DslScalarValue =
  ## Internal: consult overrides first, then defaults. Raises
  ## ``EDslPortMissingKey`` when neither table knows the key.
  ##
  ## A CONTRIBUTION POINT IS RESOLVED BY THE FOLD AND NOTHING ELSE
  ## (Shared-Development-Services L8). It is checked FIRST, before the
  ## override table, because a `setConfigurable` against such a key is
  ## routed into the contribution registry as a `coReplace` at
  ## `epOverride` -- so if the override row were consulted first it
  ## would shadow the ladder the fold exists to enforce, and an
  ## `epForce` append would silently lose to an `epOverride` replace.
  if key in dslPortContributionPoints:
    return dslScalarSeqString(foldContributionPoint(key).members)
  if key in dslPortOverrides:
    return dslPortOverrides[key]
  if key in dslPortRequired:
    # A REQUIRED key with no contribution. The row in
    # ``dslPortDefaults`` is a SHAPE (the type's zero), kept only so
    # ``setConfigurableRaw``'s kind check can accept a binding; it is
    # not a value and must never be handed back as one. Returning the
    # zero here is the whole failure Shared-Development-Services L5
    # guards against: an empty external domain reads as a hostname
    # nobody chose. The precise, routed diagnostic is
    # ``requiredConfigurableValue``'s -- this is the funnel every other
    # reader goes through, so nothing can reach the seed by a different
    # door.
    raise newException(EDslPortUnsatisfiedRequired,
      "readConfigurable: `" & key & "` is a REQUIRED configurable -- " &
      "declared in a `config:` block with no default, so its slot has " &
      "no seed -- and nothing has satisfied it. Bind it in an " &
      "`environment` block (Shared-Development-Services.md §6) or pass " &
      "it at the `enable <activity>(...)` site.")
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
  ## stored kind; raises ``EDslPortUnsatisfiedRequired`` when the key is
  ## REQUIRED (Shared-Development-Services L5, §6: declared in a
  ## ``config:`` block with no default) and nothing has satisfied it.
  ## That last one is ``dslPortLookup``'s, so it is raised before any
  ## kind check: the row behind a required key is the type's zero kept
  ## as a SHAPE for ``setConfigurableRaw``, and handing it back would be
  ## the silent substitution L5 exists to stop.
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
  elif T is seq[string]:
    # Shared-Development-Services L8: the ordered-collection arm. For a
    # CONTRIBUTION POINT the value `dslPortLookup` returned is already
    # the fold's result, so this reader never sees an unresolved
    # collection and never has to know about the ladder.
    if stored.kind != dskSeqString:
      raise newException(EDslPortTypeMismatch,
        "readConfigurable[seq[string]]('" & key & "'): stored kind is " &
        $stored.kind & ", not dskSeqString")
    return stored.seqStrVals
  else:
    {.error: "readConfigurable: unsupported type " & $T &
       "; M2/M9.D supports bool / int / string / float / enum / " &
       "seq[enum]; L8 adds seq[string]".}

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
  ##
  ## IT DOES RAISE FOR ONE CASE, and that case is deliberate: a
  ## REQUIRED configurable nothing has satisfied
  ## (``EDslPortUnsatisfiedRequired``, Shared-Development-Services L5
  ## §6). ``seq[Enum]`` is in ``recordConfigRequired``'s type set, so
  ## this overload can meet one. The ``except`` below catches
  ## ``EDslPortMissingKey`` ONLY, and
  ## ``EDslPortUnsatisfiedRequired`` is deliberately not a subtype of
  ## it, so the exception propagates rather than being answered with
  ## ``fallback`` — answering with a fallback is exactly the silent
  ## substitution that exception exists to prevent.
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
  ## otherwise returns ``fallback``. Callers use this overload when the
  ## spec calls for graceful degradation rather than a hard
  ## type-mismatch error.
  ##
  ## RAISES ``EDslPortUnsatisfiedRequired`` FOR EXACTLY ONE CASE: a
  ## REQUIRED configurable -- declared in a ``config:`` block with no
  ## default, so its slot has no seed -- that nothing has satisfied
  ## (Shared-Development-Services L5, §6). An unknown key is still
  ## answered with ``fallback``; the ``except`` below catches
  ## ``EDslPortMissingKey`` ONLY, and ``EDslPortUnsatisfiedRequired``
  ## is deliberately not a subtype of it.
  ##
  ## THIS COMMENT SAID "Never raises" UNTIL L5's required-configurable
  ## work, and the exception is the point rather than an oversight:
  ## answering a required key with a fallback would substitute a value
  ## nobody wrote for the one the author was told to supply, which is
  ## the failure §6 names. Asserted by a test rather than left to this
  ## comment -- ``libs/repro_project_dsl/tests/
  ## t_l5_environment_reaches_the_service_argv.nim``, case "the seed is
  ## a SHAPE and not a value: reading the slot directly refuses too",
  ## which expects the raise from THIS overload and carries the control
  ## that the same read succeeds once the environment has satisfied the
  ## key.
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
    elif T is seq[string]:
      if stored.kind != dskSeqString: return fallback
      return stored.seqStrVals
    else:
      {.error: "readConfigurable: unsupported type " & $T &
         "; M2/M9.D supports bool / int / string / float / enum / " &
         "seq[enum]; L8 adds seq[string]".}
  except EDslPortMissingKey:
    return fallback

proc inspectConfigurable*(key: string): DslScalarValue =
  ## M9.D test-side accessor: return the raw stored ``DslScalarValue``
  ## at ``key`` (override-preferred, defaults fallback), or raise
  ## ``EDslPortMissingKey`` when the key is unknown -- or
  ## ``EDslPortUnsatisfiedRequired`` when the key is REQUIRED and
  ## nothing has satisfied it, because the row behind such a key is the
  ## type's zero kept as a SHAPE and this accessor must not be the door
  ## it leaks out of (Shared-Development-Services L5, §6). Tests use this to
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
  if key in dslPortContributionPoints:
    # Shared-Development-Services L8. The L5 section below predicted
    # exactly this: "An environment binding is a `replace` at
    # `epOverride` in the terms L8 will introduce". `setConfigurable` is
    # the route an `environment` binding takes, so it lands as one --
    # and nothing in the environment lane had to change to make that
    # true.
    #
    # IT OVERWRITES RATHER THAN APPENDING A ROW, which is what keeps it
    # equivalent to the `dslPortOverrides[key] = value` it replaces:
    # applying environment `dev` and then environment `production` to
    # the same key must leave the second's value in force, not two
    # contradictory `replace` claims at one priority (which the fold
    # would correctly refuse). One row per (key, `""` package,
    # `epOverride`, `coReplace`), overwritten in place.
    var rows = dslPortContributions.getOrDefault(key)
    let row = ConfigContribution(key: key, package: "",
      precedence: epOverride, operation: coReplace, value: value,
      sourceFile: "", sourceLine: 0)
    var replaced = false
    for i in 0 ..< rows.len:
      if rows[i].package.len == 0 and rows[i].precedence == epOverride and
         rows[i].operation == coReplace:
        rows[i] = row
        replaced = true
        break
    if not replaced:
      rows.add(row)
    dslPortContributions[key] = rows
    return
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
    elif Elem is string:
      # Shared-Development-Services L8: a `replace` of an
      # ordered-collection contribution point. This is the route an
      # `environment` binding to such a point takes.
      setConfigurableRaw(key, dslScalarSeqString(value))
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
  ##
  ## FOR A REQUIRED KEY THERE IS NO DEFAULT TO RETURN TO. Clearing the
  ## override of a key declared with no default puts it back to
  ## UNSATISFIED, and the next read raises
  ## ``EDslPortUnsatisfiedRequired`` rather than returning anything
  ## (Shared-Development-Services L5, §6). That is the intended
  ## behaviour -- the row left behind is the type's zero kept as a
  ## SHAPE for ``setConfigurableRaw``'s kind check -- and it is how a
  ## test fixture resets between environments.
  if key notin dslPortDefaults:
    raise newException(EDslPortMissingKey,
      "resetConfigurable: no configurable registered for key '" & key &
      "'")
  if key in dslPortContributionPoints:
    # Shared-Development-Services L8: drop the row `setConfigurable`
    # owns, and ONLY that row. A reset is the inverse of a `set`, so it
    # must not take a consumer's `coAppend` contributions with it -- that
    # is `withdrawPackageContributions`'s job and it is keyed by package.
    var kept: seq[ConfigContribution] = @[]
    for row in dslPortContributions.getOrDefault(key):
      if row.package.len == 0 and row.precedence == epOverride and
         row.operation == coReplace:
        continue
      kept.add(row)
    dslPortContributions[key] = kept
    return
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

proc latestRegisteredPackageVersion*(packageName: string): string =
  ## Return the last non-empty version registered for ``packageName``.
  ## Empty means the package did not declare a publishable version; emit
  ## paths must then skip store publication instead of inventing one.
  let versions = registeredVersions(packageName)
  if versions.len == 0:
    return ""
  for i in countdown(versions.high, 0):
    if versions[i].version.len > 0:
      return versions[i].version
  ""

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
    # Shared-Development-Services L1 — the TYPED service record.
    #
    # ``Shared-Development-Services.md`` §1 states the defect these
    # fields close: "A dev-env service is declared with
    # `servicePlaceholder(name, metadata, activities)` — a name, an
    # activity list and an **opaque metadata string** the engine
    # interprets. There is no composition, no typed reference".
    #
    # ``executableRef`` / ``args`` above stay byte-identical (they are
    # the M5 acceptance surface); the fields below carry what a string
    # cannot: WHICH EDGE produces each path. ``servicePayload`` encodes
    # them into the ``gnkService`` graph node and
    # ``buildPackageFragment`` emits one ``gekDependsOn`` /
    # ``gekConsumes`` edge per producer.
    # ---------------------------------------------------------------
    executableTyped*: ServiceExecutableRef
      ## The typed ``executable <expr>`` edge. ``sxkUnset`` when the
      ## body has no ``executable`` setter.
    typedArgs*: seq[ServiceArgDef]
      ## ``args`` in declaration order, each tagged literal or
      ## build-output. The parallel ``args*: seq[string]`` field holds
      ## the same tokens' values, so an M5-era reader is unaffected.
    runtimeFiles*: seq[ServiceRuntimeFileDef]
      ## ``runtimeFile <buildOutput>`` setters, in declaration order.
    triggers*: seq[ServiceTriggerDef]
      ## ``on <trigger>:`` blocks and the short-form atoms
      ## (``hotReload`` / ``restartOnCrash`` / ``reloadOnChange``), in
      ## declaration order.
    # ---------------------------------------------------------------
    # Shared-Development-Services L4 — INSTANCE IDENTITY AND SCOPE.
    #
    # ``Shared-Development-Services.md`` §4: "Two fields answer it, and
    # they are **orthogonal**. Conflating them is the mistake this
    # section is written to prevent. Identity answers *are these the
    # same instance?* Scope answers *how widely is one instance
    # shared?*"
    #
    # Both are ground-state-zero (``sikDerived`` / ``sscProject``), so a
    # record that never saw the setters -- every pre-L4 recipe, and the
    # legacy positional ``registerService`` -- carries the DEFAULT, which
    # is also "today's only behaviour". There is no third "unset" state,
    # deliberately: §4.1 and §4.2 both name a default, so an unset value
    # would be a state the spec does not have.
    # ---------------------------------------------------------------
    identity*: ServiceIdentityDef
      ## ``identity derived`` (the default) or ``identity stable
      ## "<id>"``.
    scope*: ServiceScope
      ## ``scope project`` (the default) | ``workspace`` | ``user`` |
      ## ``system``.
    convergePoints*: seq[string]
      ## Shared-Development-Services L8: the BARE names of the
      ## contribution points this service converges when its instance
      ## answers -- `converge relyingParties, fixtureUsers`.
      ##
      ## BARE, not fully qualified, and resolved later. The service
      ## emitter is shared by the package-level walker and the dev-env
      ## `activity` walker (L2 extracted it precisely so the two cannot
      ## drift), and only the second knows an activity name -- so
      ## qualifying here would mean either threading the activity name
      ## through the shared emitter or writing a second emitter. The
      ## resolution is `resolveServiceConvergePoint`, which searches the
      ## package's registered contribution points and REFUSES an
      ## ambiguous or unknown name by name.
    # ---------------------------------------------------------------
    # Shared-Development-Services L9 — THE SUPERVISION FACTS, which
    # until now existed only inside a `servicePlaceholder`'s opaque
    # JSON metadata.
    #
    # L8's review recorded the remainder and L9's gate carries it: "the
    # `instance` block and `readiness` still require a
    # `servicePlaceholder`, so `declared once` is only PARTLY
    # unblocked." These four fields are the rest of that channel. With
    # them a shared service is declarable in ONE place -- the typed
    # `service` block -- and `infra/repro.nim`'s `servicePlaceholder`
    # goes away rather than being kept beside the typed block for the
    # two facts it alone could carry.
    # ---------------------------------------------------------------
    readiness*: ServiceReadinessDef
      ## `readiness none` | `fileExists(...)` | `httpGet(...)`.
      ## `srkUnset` when the body declared none.
    workingDirectory*: string
      ## `workingDirectory "<dir>"` -- the placeholder's `cwd`. Empty
      ## when undeclared, which the supervisor reads as the project
      ## root.
    stateDirectories*: seq[string]
      ## `stateDirectory "<dir>"`, repeating -- the placeholder's
      ## `resources: [{"kind": "directory", ...}]`. In declaration
      ## order.
    instance*: ServiceInstanceDef
      ## `instance:` block. `declared == false` for a session-owned
      ## service.
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

  ServiceArgTemplateItemKind* = enum
    ## Shared-Development-Services, reprobuild issue #498 — what ONE
    ## `args` token on a service's command line is derived FROM.
    satkLiteral
      ## A token whose text was known when the body ran: a string
      ## literal, a build output's path, an interpolated expression.
    satkContributionPoint
      ## `args <contributionPoint>`. NOT a token but a HOLE: the
      ## point's folded members go here, one token each, and the fold
      ## is performed at FINALIZATION rather than when the body ran.

  ServiceArgTemplateItem* = object
    ## One slot in a service's argv template.
    ##
    ## WHY A TEMPLATE AND NOT A LIST OF STRINGS. #498: `args <point>`
    ## resolved EAGERLY — Nim evaluates the argument before `args` is
    ## called, so the point was folded while the activity's body ran and
    ## the strings were copied into the frame, where nothing re-read
    ## them. A contribution made by a LATER activity's body therefore
    ## reached `registrationMembers` (folded late, by
    ## `mergeTypedServiceFacts`) and never reached argv, and the same
    ## artifact stated two different member sets for one point. The
    ## template keeps the HOLE open so the fold can happen once, after
    ## every body has run — which is the staging
    ## `Shared-Development-Services.md` §7 already specifies
    ## (instantiation -> resolution -> finalization -> materialization)
    ## and which the eager fold was violating.
    case kind*: ServiceArgTemplateItemKind
    of satkLiteral:
      arg*: ServiceArgDef
    of satkContributionPoint:
      pointKey*: string

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
    # Shared-Development-Services L1 — typed edges; see DslServiceDef.
    executableTyped: ServiceExecutableRef
    typedArgs: seq[ServiceArgDef]
    runtimeFiles: seq[ServiceRuntimeFileDef]
    triggers: seq[ServiceTriggerDef]
    openTrigger: ServiceTriggerDef
    triggerOpen: bool
    # Shared-Development-Services L4 — see DslServiceDef.
    identity: ServiceIdentityDef
    scope: ServiceScope
    convergePoints: seq[string]
      ## Shared-Development-Services L8: the bare `converge <point>`
      ## names collected by `addActiveServiceConvergePoint`.
    argTemplate: seq[ServiceArgTemplateItem]
      ## Shared-Development-Services #498: the argv template, parallel
      ## to `args` / `typedArgs` except that a contribution point
      ## occupies ONE slot here and as many tokens as it has members
      ## there. Kept on the frame rather than derived afterwards
      ## because only the body knows which token came from which
      ## point.
    identityDeclared: bool
      ## Whether this body already ran an ``identity`` setter. The macro
      ## refuses a second one at expansion time, so this is the runtime
      ## half of the same guard: a body reaching the setter twice through
      ## some other route must not have the first declaration silently
      ## replaced.
    scopeDeclared: bool
    # Shared-Development-Services L9 — see DslServiceDef.
    readiness: ServiceReadinessDef
    workingDirectory: string
    stateDirectories: seq[string]
    instance: ServiceInstanceDef
    readinessDeclared: bool
      ## First-wins, for ``identityDeclared``'s reason: a second
      ## ``readiness`` would decide, by statement order, whether a
      ## consumer that ``dependsOn`` this service starts against a
      ## seeded instance or a merely listening one.
    workingDirectoryDeclared: bool

var dslPortServiceRegistry: Table[string, seq[DslServiceDef]]
  ## Per-package service registry. Keyed by package name.
  ## ``registerService`` appends to the per-package seq;
  ## ``registeredServices`` returns a copy so callers cannot mutate
  ## the registry from outside the public API.

var dslPortServiceArgTemplates:
    Table[string, seq[seq[ServiceArgTemplateItem]]]
  ## Shared-Development-Services #498 — the argv TEMPLATE of each row in
  ## `dslPortServiceRegistry`, index for index.
  ##
  ## A PARALLEL TABLE AND NOT A FIELD ON `DslServiceDef`, which would be
  ## the obvious shape. `DslServiceDef` crosses a positional codec
  ## (`dslServiceDefPayload` / its reader) and reaches the interface
  ## lift; a template is PROCESS-LOCAL scaffolding that exists between a
  ## body running and the package's dev-env being finalised, and nothing
  ## outside this process has any use for it. Putting it on the record
  ## would have versioned the wire for a value no reader wants.
  ##
  ## Index alignment is maintained by appending here in
  ## `registerServiceRecord` — the registry's ONE append site — so a row
  ## registered through the positional `registerService` path gets an
  ## empty template rather than shifting its neighbours' by one.

var dslPortActiveServiceContext {.threadvar.}:
    seq[DslServiceContextFrame]
  ## Active-service stack. ``threadvar`` so test fixtures running on
  ## different threads don't cross-attribute body-setter calls. Empty
  ## when no ``service:`` block is currently open.

type
  ServiceDeclarator* = object
    ## Shared-Development-Services L1 — one ``service <ident>:`` body,
    ## re-runnable.
    ##
    ## WHY A CLOSURE AND NOT JUST THE EAGER REGISTRATION. A service's
    ## config file is a BUILD OUTPUT, and a build output does not exist
    ## until the ``build:`` body has run. In provider mode the ``build:``
    ## body is deliberately NOT executed at module-init time (see the
    ## ``when not defined(reproProviderMode)`` gate in
    ## ``emitM4BuildActions``) — it runs inside ``buildPackageFragment``,
    ## i.e. AFTER module init. A service body evaluated only at module
    ## init would therefore read an unassigned handle and record an empty
    ## path, silently.
    ##
    ## So the emitter registers the body here as well as running it
    ## eagerly, and ``buildPackageFragment`` re-runs it once the build
    ## body has produced the outputs. The eager run is retained
    ## unchanged so every non-provider-mode reader of
    ## ``registeredServices`` sees exactly what it saw before.
    packageName*: string
    serviceName*: string
    declare*: proc () {.closure.}

var dslPortServiceDeclarators: seq[ServiceDeclarator]
  ## Declaration-ordered; one entry per ``service <ident>:`` block the
  ## ``package`` macro expanded in this process.

proc registerServiceDeclarator*(packageName, serviceName: string;
                                declare: proc () {.closure.}) =
  ## Record a re-runnable service body. Appended, never deduplicated: a
  ## ``when`` arm may legitimately declare the same service name twice
  ## and the consumer decides which arm to honour (the same rule
  ## ``registerService`` documents).
  dslPortServiceDeclarators.add(ServiceDeclarator(
    packageName: packageName, serviceName: serviceName, declare: declare))

proc clearRegisteredServices*(packageName: string) =
  ## Drop every service recorded against ``packageName``, leaving other
  ## packages alone. ``rerunServiceDeclarators`` calls this first so the
  ## re-run replaces rather than duplicates.
  if packageName in dslPortServiceRegistry:
    dslPortServiceRegistry[packageName] = @[]
  # #498: the argv templates go with the rows they describe. Leaving
  # them would misalign the next re-run's indices by exactly the number
  # of rows this call dropped.
  if packageName in dslPortServiceArgTemplates:
    dslPortServiceArgTemplates[packageName] = @[]

proc rerunServiceDeclarators*(packageName: string) =
  ## Re-evaluate ``packageName``'s service bodies against the CURRENT
  ## build state, replacing its registry bucket. Idempotent: running it
  ## twice with the same build state yields the same records.
  ##
  ## A package with no declarators (nothing declared a ``service``, or an
  ## out-of-tree caller that only used ``registerService``) keeps its
  ## bucket untouched — clearing it would delete rows this function
  ## cannot reconstruct.
  var any = false
  for declarator in dslPortServiceDeclarators:
    if declarator.packageName == packageName and declarator.declare != nil:
      any = true
      break
  if not any:
    return
  clearRegisteredServices(packageName)
  for declarator in dslPortServiceDeclarators:
    if declarator.packageName == packageName and declarator.declare != nil:
      declarator.declare()

proc resetDslPortServiceState*() =
  ## Drop every recorded service + clear the active-context stack. Test
  ## fixtures call this between scenarios so registry entries do not
  ## leak across cases. Keeping the five concerns (config, versions,
  ## artifacts, build, services) separable lets tests target one
  ## surface without disturbing the others.
  dslPortServiceRegistry.clear()
  dslPortServiceArgTemplates.clear()
  dslPortActiveServiceContext.setLen(0)
  dslPortServiceDeclarators.setLen(0)

proc registerServiceRecord*(def: DslServiceDef;
                            argTemplate: seq[ServiceArgTemplateItem] = @[]) =
  ## Append one fully-built ``DslServiceDef`` against ``def.packageName``.
  ##
  ## Shared-Development-Services L1 split this out of ``registerService``
  ## so the typed fields (``executableTyped`` / ``typedArgs`` /
  ## ``runtimeFiles`` / ``triggers``) have a route in. ``registerService``
  ## remains the M5/M9.C positional entry point and delegates here, so its
  ## callers are unaffected and the registry has exactly one append site.
  if def.packageName notin dslPortServiceRegistry:
    dslPortServiceRegistry[def.packageName] = @[]
  dslPortServiceRegistry[def.packageName].add(def)
  # #498: one template per row, ALWAYS, so the two seqs are index for
  # index. A caller that built its record without a template (the
  # positional `registerService` path, an out-of-tree caller) gets an
  # empty one, which `foldDeferredServiceArgv` reads as "this row's argv
  # is already final".
  if def.packageName notin dslPortServiceArgTemplates:
    dslPortServiceArgTemplates[def.packageName] = @[]
  dslPortServiceArgTemplates[def.packageName].add(argTemplate)

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
  registerServiceRecord(DslServiceDef(
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
# Shared-Development-Services L2 — the dev-env activity DECLARATION record.
#
# ``Package-Model.md`` §"Activity declaration shape": "Activities are
# declared with a function-call shape. Required dependencies are
# constructor-style typed parameters; everything that has a default lives
# in an inner ``config:`` block."
#
# This registry records WHAT WAS DECLARED — the parameter names with their
# written type expressions, and the ``config:`` keys with their written
# type and default expressions. It deliberately does NOT record VALUES:
# the parameters and the config keys are real Nim parameters of the
# generated activity proc, so their values live in the Nim call and reach
# the body (and the body's rendered configuration) by ordinary parameter
# passing, with the compiler type-checking every one. A registry of values
# would be a second, weaker channel for the same thing.
#
# The declaration record exists because L3 lifts it: "``libs/repro_
# interface_artifacts`` carries, per exported service and activity, the
# handle type and its members, ... and the ``config:`` surface with
# defaults". The type and default EXPRESSIONS are what a consuming
# project's generated symbols are built from, and they are only knowable
# at the declaration site.
# ---------------------------------------------------------------------------

type
  DslActivityParamDef* = object
    ## One constructor-style typed parameter of an activity.
    name*: string
      ## The parameter name, as written.
    typeRepr*: string
      ## The parameter's type EXPRESSION, as written (``ManagedPostgres``,
      ## ``seq[string]``, ``range[1..256]``). Source text rather than a
      ## resolved type, because the declaration is recorded at macro
      ## expansion time where no type is resolved yet — and because that
      ## is exactly what L3 has to re-emit into a consumer.

  DslActivityConfigDef* = object
    ## One ``config:`` key of an activity.
    name*: string
    typeRepr*: string
    defaultRepr*: string
      ## The default EXPRESSION, as written. Empty when the key was
      ## declared without one (``externalDomain: string``), which makes
      ## the generated parameter REQUIRED at the ``enable`` site.
    hasDefault*: bool
      ## Distinguishes "no default" from "a default whose source text is
      ## the empty string" (``name: string = ""``). Without this field the
      ## two are the same record and the second would read as required.
    description*: string
      ## The doc comment immediately above the key, with its ``##``
      ## markers stripped. ``Package-Model.md``'s worked example carries
      ## one per key ("TCP port the API server binds. 0 disables the
      ## network listener."), and L3 lifts it to the consumer.

  DslActivityDef* = object
    ## One ``activity <name>(<params>): <body>`` declaration.
    packageName*: string
    activityName*: string
    params*: seq[DslActivityParamDef]
      ## In declaration order, which is also the generated proc's
      ## positional parameter order.
    config*: seq[DslActivityConfigDef]
      ## In declaration order, after every parameter.
    bodyRepr*: string
      ## The activity body's source text, ``config:`` block included.
      ## Diagnostic surface only — symmetric with
      ## ``DslServiceDef.bodyRepr``.

var dslPortActivityRegistry: Table[string, seq[DslActivityDef]]
  ## Per-package activity-declaration registry, keyed by package name.
  ## Separate from ``devEnvActivityRegistry`` in ``runtime_core`` on
  ## purpose: that one is the flat list of activity NAMES the dev-env
  ## selector gates on (``activity "default"`` appends to it and nothing
  ## else), and a parameterised activity appends its name there too so
  ## selection keeps working. This registry is the richer declaration
  ## record, and nothing in the dev-env lowering reads it.

proc resetActivityRegistry*() =
  ## Drop every recorded activity declaration. Test fixtures that
  ## re-run a package's dev-env body call this between scenarios;
  ## production never does.
  dslPortActivityRegistry.clear()

proc registerActivityDeclaration*(def: DslActivityDef) =
  ## Append one declaration. Re-declaring the same name in the same
  ## package is NOT deduplicated here — the generated proc would be a
  ## Nim redefinition error long before this runs, so a duplicate in
  ## this registry can only come from the dev-env body being run twice,
  ## which is a legitimate thing for a fixture to do.
  if def.packageName notin dslPortActivityRegistry:
    dslPortActivityRegistry[def.packageName] = @[]
  dslPortActivityRegistry[def.packageName].add(def)

proc registeredActivities*(packageName: string): seq[DslActivityDef] =
  ## Every activity declared by ``packageName``, in declaration order.
  ## Empty when the package declares none; callers must NOT read the
  ## empty return as an error.
  if packageName in dslPortActivityRegistry:
    return dslPortActivityRegistry[packageName]
  return @[]

# ---------------------------------------------------------------------------
# Shared-Development-Services L1 — ``BuildOutput`` and the rendering helper.
#
# ``Shared-Development-Services.md`` §2: "Because `service` takes no
# `config:` block and consumes a rendered `BuildOutput` instead, a
# service's expensive setup becomes an ordinary cached edge. This matters
# immediately: today the identity provider's configuration and steps files
# are written by a shell script at run time, so its first-boot schema
# migration and instance bootstrap — tens of seconds — are an uncacheable
# runtime side effect redone on every reset. Declared as build outputs they
# are keyed like anything else."
#
# So the helper below does not write a file. It registers a build ACTION
# that writes the file and hands back the handle, which is why a second
# reconcile with unchanged content is a cache hit rather than a re-render:
# the engine keys ``reprobuild.builtin.fs writeText`` on a weak fingerprint
# computed over the encoded payload, rendered bytes included.
# ---------------------------------------------------------------------------

proc `$`*(p: BuildOutputPath): string =
  ## Dropping to a plain string DROPS THE CONTEXT, exactly as
  ## interpolating a Nix string-with-context into a context-free string
  ## does. Spelled out because the loss is silent.
  p.value

proc `&`*(a: BuildOutputPath; b: string): BuildOutputPath =
  ## Concatenation PRESERVES the producer, so ``"--config=" & cfg.path``
  ## and ``cfg.path & ".bak"`` still record the edge. ``producerPath``
  ## stays the FILE's own path, which is what the graph matches on.
  result = a
  result.value = a.value & b

proc `&`*(a: string; b: BuildOutputPath): BuildOutputPath =
  result = b
  result.value = a & b.value

proc executableAtPath*(path: string): ServiceExecutableRef =
  ## ``executable executableAtPath("/usr/bin/zitadel")`` — a binary named by
  ## literal path rather than by artifact or package. Separate from the
  ## bare-string form because ``setActiveServiceExecutable(string)`` has
  ## always meant "an artifact of this package" and changing that would
  ## reinterpret every existing recipe.
  ServiceExecutableRef(kind: sxkPath, path: path)

proc newBuildOutput*(packageName, actionId, filePath: string): BuildOutput =
  ## The ONE constructor for a build-output handle: it is what keeps the
  ## ``path`` field (the context-carrying proxy ``args`` and
  ## ``runtimeFile`` take) in sync with ``filePath`` and the producer. A
  ## hand-written ``BuildOutput(...)`` object constructor would compile
  ## and leave ``path`` empty.
  BuildOutput(
    packageName: packageName,
    actionId: actionId,
    filePath: filePath,
    path: BuildOutputPath(
      value: filePath,
      producerPackage: packageName,
      producerActionId: actionId,
      producerPath: filePath))

proc buildOutputOf*(packageName, actionId, filePath: string): BuildOutput =
  ## Construct a handle for an output produced by an action this recipe
  ## already registered under ``actionId``. The rendering helpers are the
  ## normal route; this is the escape hatch for an edge emitted by a
  ## typed-tool wrapper whose handle the author did not capture.
  newBuildOutput(packageName, actionId, filePath)

proc renderConfigFile*(path: string; content: string;
                       actionId = ""; packageName = ""): BuildOutput
                      {.discardable.} =
  ## Render ``content`` to ``path`` as a CACHED BUILD OUTPUT and return
  ## its handle.
  ##
  ## This is the ``literalConfigFile``-shaped helper ``Package-Model.md``
  ## §Collections names: "Configuration is the package's job:
  ## package-level ``config:`` configurables plus rendering helpers
  ## (``literalConfigFile``, ``configFile``, etc.) produce a
  ## ``BuildOutput``, and the service consumes that output the same way
  ## any other build output is consumed — either by reference on argv or
  ## via ``runtimeFile``."
  ##
  ## NOT to be confused with ``configFile`` further down this module:
  ## that one is the home-manager/profile ``fs.configFile`` registry
  ## (M8), which records a declaration an APPLY phase materialises. This
  ## one emits a build-graph edge, which is the thing the L1 gate
  ## measures a cache hit on.
  ##
  ## ``actionId`` defaults to ``fs-writeText-<sanitised path>``, which is
  ## a function of the path alone — so the id is stable across runs and
  ## two renders of different paths never collide.
  var pkg = packageName
  if pkg.len == 0:
    pkg = currentBuildPackage()
  let edge = ReproFs().writeText(path, content, actionId = actionId)
  newBuildOutput(pkg, edge.id, path)

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
    group: "",
    identity: ServiceIdentityDef(kind: sikDerived, stableId: ""),
    scope: sscProject,
    identityDeclared: false,
    scopeDeclared: false,
    # Shared-Development-Services L9. `srkUnset` / "" / @[] /
    # `declared: false` are the ground states that mean "this body said
    # nothing", which is what keeps a pre-L9 recipe's record
    # byte-identical to what it was.
    readiness: ServiceReadinessDef(kind: srkUnset),
    workingDirectory: "",
    stateDirectories: @[],
    instance: ServiceInstanceDef(declared: false,
      leaseTtlSeconds: SharedServiceInstanceKeepTtlSeconds),
    readinessDeclared: false,
    workingDirectoryDeclared: false))

proc setActiveServiceIdentity*(kind: ServiceIdentityKind;
                               stableId = "") =
  ## Body-setter for ``identity derived`` / ``identity stable "<id>"``
  ## (Shared-Development-Services §4.2).
  ##
  ## The empty-stack case is a silent no-op, matching every other
  ## body-setter in this module (see ``setActiveServiceExecutable``).
  ##
  ## A SECOND declaration is DROPPED here rather than overwriting the
  ## first, and that is not the silent drop this campaign keeps finding:
  ## the macro refuses a second ``identity`` setter at expansion time
  ## with a diagnostic, so this branch is unreachable from a recipe. It
  ## exists because the proc is public, and last-wins would make
  ## ``identity`` the one setter whose value depends on evaluation order
  ## -- on the field that decides whether a developer's database
  ## survives.
  if dslPortActiveServiceContext.len == 0:
    return
  if dslPortActiveServiceContext[^1].identityDeclared:
    return
  dslPortActiveServiceContext[^1].identity = ServiceIdentityDef(
    kind: kind,
    stableId: (if kind == sikStable: stableId else: ""))
  dslPortActiveServiceContext[^1].identityDeclared = true

proc setActiveServiceScope*(scope: ServiceScope) =
  ## Body-setter for ``scope project`` | ``workspace`` | ``user`` |
  ## ``system`` (§4.1). Same first-wins rule, same reason, as
  ## ``setActiveServiceIdentity``.
  if dslPortActiveServiceContext.len == 0:
    return
  if dslPortActiveServiceContext[^1].scopeDeclared:
    return
  dslPortActiveServiceContext[^1].scope = scope
  dslPortActiveServiceContext[^1].scopeDeclared = true

proc selectedEnvironmentName*(): string
  ## FORWARD DECLARATION. The definition is in this file's L5 section,
  ## several thousand lines below; `setActiveServiceInstance` needs it
  ## HERE because the environment component of an instance key is
  ## derived from the selection rather than declared, and this file is
  ## `include`d into one module compiled top to bottom.
  ##
  ## Forward-declared rather than moved: the L5 section is where a
  ## reader looks for environment selection, and relocating the proc to
  ## satisfy an ordering constraint would put it where nobody looks.

# ---------------------------------------------------------------------------
# Shared-Development-Services L9 — the SUPERVISION body-setters.
#
# These are what makes "declared once" true for the last two facts L8's
# review left behind: `readiness`, and the `instance` block. Before them
# a recipe that wanted a SHARED instance wrote a typed `service` block
# for the identity and a `servicePlaceholder` for the probe, joined by
# the service name, and `infra/repro.nim` is the production instance of
# exactly that.
#
# Every one of them is FIRST-WINS with the macro refusing the second
# occurrence at expansion time, for `setActiveServiceIdentity`'s reason:
# last-wins would make the decision depend on statement order, and these
# particular fields decide whether a dependent starts against a seeded
# instance and whether a developer's identity database is reaped.
# ---------------------------------------------------------------------------

proc setActiveServiceReadiness*(readiness: ServiceReadinessDef) =
  ## Body-setter for ``readiness none`` / ``fileExists(...)`` /
  ## ``httpGet(...)``.
  ##
  ## ``srkUnset`` is REFUSED rather than recorded: it is the ground
  ## state meaning "this body declared no readiness", so writing it
  ## through the setter would make a declaration indistinguishable from
  ## its absence, and the absence is what sends the supervisor to the
  ## placeholder's probe.
  if dslPortActiveServiceContext.len == 0:
    return
  if readiness.kind == srkUnset:
    return
  if dslPortActiveServiceContext[^1].readinessDeclared:
    return
  dslPortActiveServiceContext[^1].readiness = readiness
  dslPortActiveServiceContext[^1].readinessDeclared = true

proc setActiveServiceWorkingDirectory*(dir: string) =
  ## Body-setter for ``workingDirectory "<dir>"`` — the placeholder's
  ## ``cwd``.
  if dslPortActiveServiceContext.len == 0:
    return
  if dslPortActiveServiceContext[^1].workingDirectoryDeclared:
    return
  dslPortActiveServiceContext[^1].workingDirectory = dir
  dslPortActiveServiceContext[^1].workingDirectoryDeclared = true

proc addActiveServiceStateDirectory*(dir: string) =
  ## Body-setter for ``stateDirectory "<dir>"`` — one of the
  ## placeholder's ``resources`` entries, which the supervisor creates
  ## before the service starts.
  ##
  ## REPEATING, like ``runtimeFile``: a service may own several state
  ## directories, and the placeholder's ``resources`` is a list. An
  ## EMPTY path is dropped rather than recorded, because
  ## ``createDir("")`` is a silent no-op in the supervisor and a
  ## recorded empty entry would read as a declared directory that
  ## nothing creates.
  if dslPortActiveServiceContext.len == 0:
    return
  if dir.len == 0:
    return
  dslPortActiveServiceContext[^1].stateDirectories.add(dir)

proc setActiveServiceInstance*(leaseTtlSeconds: int64) =
  ## Body-setter for the ``instance:`` block — "this service is a SHARED
  ## instance the daemon owns", with D-SS5's lease.
  ##
  ## The block's mere PRESENCE is the declaration; the lease is its one
  ## setting. `environment` is not a setting of it — see
  ## ``ServiceInstanceDef``'s note — and the macro refuses the word by
  ## name rather than leaving an author to discover that it parsed and
  ## did nothing.
  if dslPortActiveServiceContext.len == 0:
    return
  if dslPortActiveServiceContext[^1].instance.declared:
    return
  dslPortActiveServiceContext[^1].instance = ServiceInstanceDef(
    declared: true,
    leaseTtlSeconds: leaseTtlSeconds,
    # DERIVED, not declared. The selection is a tracked input (§6.4) and
    # part of the instance key (§6.5); reading it here is the one
    # reading, so a recipe cannot hold a second, disagreeing answer.
    environment: selectedEnvironmentName())

proc setActiveServiceExecutable*(executableRef: string) =
  ## Body-setter: select the referenced executable artifact. Mirrors
  ## v8's ``setServiceExecutable``. When the stack is empty this is a
  ## silent no-op (matches the M4 ``output()`` empty-context decision —
  ## the empty path is unreachable from a correctly-shaped recipe but
  ## keeps the legacy provider chain compatible).
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].executableRef = executableRef
  # Shared-Development-Services L1: the same selection, typed. The STRING
  # form is an artifact name of this package (that is what this proc has
  # always meant), so it lowers to ``sxkArtifact``. A literal path goes
  # through ``executableAtPath``, a third-party binary through the
  # ``SelectedExecutable`` overload, and a binary this graph builds
  # through the ``BuildOutput`` one.
  dslPortActiveServiceContext[^1].executableTyped = ServiceExecutableRef(
    kind: sxkArtifact,
    packageName: dslPortActiveServiceContext[^1].packageName,
    executableName: executableRef)

proc setActiveServiceExecutable*(value: SelectedExecutable) =
  ## Body-setter for ``executable <pkg>.executable("<name>")`` — the
  ## third-party form ``Package-Model.md`` names ("any other expression
  ## that evaluates to an ``Executable[name]``, such as
  ## ``redis.executable("redis-server")`` for third-party software pulled
  ## in via ``uses``").
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].executableRef = value.executableName
  dslPortActiveServiceContext[^1].executableTyped = ServiceExecutableRef(
    kind: sxkPackageExecutable,
    packageName: value.packageName,
    executableName: value.executableName)

proc setActiveServiceExecutable*(value: ServiceExecutableRef) =
  ## Body-setter for an explicitly constructed reference —
  ## ``executable executableAtPath("/usr/bin/zitadel")``.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].executableRef = value.executableName
  dslPortActiveServiceContext[^1].executableTyped = value

proc setActiveServiceExecutable*(value: BuildOutput) =
  ## Body-setter for ``executable <buildOutput>`` — a binary THIS graph
  ## builds. The producing action id travels with it, which is what makes
  ## the service's dependency on its own binary an edge.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].executableRef = value.filePath
  dslPortActiveServiceContext[^1].executableTyped = ServiceExecutableRef(
    kind: sxkBuildOutput,
    packageName: value.packageName,
    path: value.filePath,
    actionId: value.actionId)

proc setActiveServiceExecutable*(value: BuildOutputPath) =
  ## ``executable <buildOutput>.path`` — same edge, reached through the
  ## context-carrying path proxy.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].executableRef = value.producerPath
  dslPortActiveServiceContext[^1].executableTyped = ServiceExecutableRef(
    kind: sxkBuildOutput,
    packageName: value.producerPackage,
    path: value.producerPath,
    actionId: value.producerActionId)

proc setActiveServiceExecutable*[T: object](handle: T) =
  ## ``executable <pkg>.executable("<name>")`` where ``<pkg>`` is a
  ## package handle: the ``package`` macro emits a PER-PACKAGE wrapper
  ## type (``macros_a.nim``'s ``exeTypeName``) whose single field is the
  ## ``SelectedExecutable``. There is no shared base type to overload on
  ## — the type does not exist until that package's macro expands — so
  ## the wrapper is unwrapped structurally. Concrete overloads above win
  ## for every type that has one, so this arm only ever sees the
  ## generated wrappers.
  when compiles(handle.value) and handle.value is SelectedExecutable:
    setActiveServiceExecutable(handle.value)
  else:
    {.error: "a service's `executable` setter takes an executable " &
      "artifact ident, a `<pkg>.executable(\"<name>\")` handle, a " &
      "`BuildOutput`, or `executableAtPath(\"<path>\")`".}

proc addActiveServiceArg*(value: string) =
  ## Body-setter: append one positional argument to the active frame.
  ## ``emitM5Services`` lowers ``args "a", "b", "c"`` into one call per
  ## argument so the variadic shape survives the macro round-trip.
  if dslPortActiveServiceContext.len == 0:
    return
  let arg = ServiceArgDef(kind: svakLiteral, value: value)
  dslPortActiveServiceContext[^1].args.add(value)
  dslPortActiveServiceContext[^1].typedArgs.add(arg)
  dslPortActiveServiceContext[^1].argTemplate.add(
    ServiceArgTemplateItem(kind: satkLiteral, arg: arg))

proc addActiveServiceArg*(value: BuildOutputPath) =
  ## Body-setter for a build output's path on argv. ``Package-Model.md``:
  ## "When the file *is* passed on argv, no ``runtimeFile`` line is
  ## needed: a ``BuildOutput.path`` reaches ``args`` as a
  ## context-carrying string and the framework records the edge through
  ## the typed proxy". This overload is that framework step — the
  ## argument's producing edge is recorded alongside its text.
  if dslPortActiveServiceContext.len == 0:
    return
  let arg = ServiceArgDef(
    kind: svakBuildOutput,
    value: value.value,
    producerPackage: value.producerPackage,
    producerActionId: value.producerActionId,
    producerPath: value.producerPath)
  dslPortActiveServiceContext[^1].args.add(value.value)
  dslPortActiveServiceContext[^1].typedArgs.add(arg)
  dslPortActiveServiceContext[^1].argTemplate.add(
    ServiceArgTemplateItem(kind: satkLiteral, arg: arg))

proc addActiveServiceArg*(value: BuildOutput) =
  ## ``args <buildOutput>`` — the handle itself on argv, equivalent to
  ## ``<buildOutput>.path``.
  addActiveServiceArg(value.path)

proc addActiveServiceConvergePoint*(name: string) =
  ## Body-setter: record one `converge <point>` of the active frame.
  ##
  ## IDEMPOTENT ON A REPEATED NAME. `converge relyingParties` written
  ## twice in one body, or a body re-run by `rerunServiceDeclarators`,
  ## records one point -- otherwise the registration pass would be asked
  ## to reconcile the same member set twice and the second pass would be
  ## indistinguishable from a second consumer.
  if dslPortActiveServiceContext.len == 0:
    return
  for existing in dslPortActiveServiceContext[^1].convergePoints:
    if existing == name:
      return
  dslPortActiveServiceContext[^1].convergePoints.add(name)

proc resolveServiceConvergePoint*(packageName, bareName: string): string =
  ## Resolve a `converge <bareName>` to the full contribution-point key.
  ##
  ## Searches the package's registered contribution points for one whose
  ## last dotted segment is `bareName`. An UNKNOWN name and an AMBIGUOUS
  ## one are both refused, by name, naming the candidates -- the two
  ## failure modes a suffix search has, and both silent if unchecked:
  ## unknown would register nothing, ambiguous would register whichever
  ## came first in a hash-ordered walk.
  var matches: seq[string] = @[]
  let suffix = "." & bareName
  for key in dslPortContributionPointOrder:
    if not key.startsWith(packageName & "."):
      continue
    if key.endsWith(suffix):
      matches.add(key)
  if matches.len == 1:
    return matches[0]
  var declared: seq[string] = @[]
  for key in dslPortContributionPointOrder:
    if key.startsWith(packageName & "."):
      declared.add(key)
  if matches.len == 0:
    raise newException(EDslPortMissingKey,
      "`converge " & bareName & "` in package `" & packageName &
      "` names no contribution point. The ordered-collection `config:` " &
      "keys of this package are: " &
      (if declared.len == 0: "(none)" else: declared.join(", ")) &
      ". A contribution point is a `config:` key whose type is " &
      "`seq[string]`.")
  raise newException(EDslPortMissingKey,
    "`converge " & bareName & "` in package `" & packageName &
    "` is AMBIGUOUS: " & matches.join(", ") & " all end in `." &
    bareName & "`. Two activities declaring a point of the same bare " &
    "name is legal; converging one of them by that name is not.")

proc addActiveServiceArg*(values: seq[string]) =
  ## Shared-Development-Services L8: `args <contributionPoint>` puts
  ## EVERY folded member on argv as its own token, in fold order.
  ##
  ## ONE TOKEN PER MEMBER, not a joined string, and the distinction is
  ## the gate's: §5's contribution point is a collection, and a service
  ## that received `"a b c"` where it expected three arguments would
  ## have been handed a different command line than the one the
  ## contributions describe. `$seq` would also render Nim's `@["a"]`
  ## syntax into argv, which no program parses.
  ##
  ## An EMPTY collection contributes NO tokens -- not an empty-string
  ## argument. A workspace where nothing has contributed therefore runs
  ## the owner's service with the flag and no values, which is the same
  ## command line it ran before any consumer existed.
  for value in values:
    addActiveServiceArg(value)

proc addActiveServiceArgPoint*(pointKey: string; eager: seq[string]) =
  ## Shared-Development-Services, reprobuild issue #498 —
  ## `args <contributionPoint>` as a DEFERRED slot.
  ##
  ## THE DECISION THIS IMPLEMENTS, AND WHY IT IS THIS ONE. §9.1.1
  ## measured a cross-activity contribution reaching the owning
  ## service's argv only when the contributing activity was declared
  ## FIRST — and, with a `converge` on the owning service, one dev-env
  ## artifact stating two different member sets for one point: the
  ## launcher's command line without the member, the converge lane's
  ## `registrationMembers` with it. Both arrangements exited 0.
  ##
  ## Two fixes were on the table. REFUSING a contribution that arrives
  ## after the fold is NOT the one taken, for three reasons:
  ##
  ##   1. `t_l8_contribution_operation_is_a_second_axis.nim`'s "a second
  ##      consumer arriving does not renumber or re-make the first's"
  ##      reads a point, contributes to it and asserts the late member
  ##      LANDS. A late contribution reaching the fold is an ASSERTED
  ##      property of the configurable system, so a refusal would
  ##      contradict an existing semantic rather than add a guard.
  ##   2. Declaration order must not be semantically significant in a
  ##      declarative DSL. A refusal makes the current behaviour honest;
  ##      it does not make the recipe `Shared-Development-Services.md`
  ##      §9.1 writes implementable.
  ##   3. A collection IS a configurable (§5), so its final value is
  ##      only knowable once every contributor has run. The documented
  ##      staging — instantiation, resolution, finalization,
  ##      materialization — already requires that; the eager fold was
  ##      the implementation disagreeing with the staging, and this
  ##      aligns them.
  ##
  ## So the point's members are NOT read here. The slot is recorded and
  ## `foldDeferredServiceArgv` fills it after every activity body in the
  ## package has run, which is the same moment
  ## `mergeTypedServiceFacts` folds `registrationMembers` — one fold, at
  ## one time, so the two views of one point cannot disagree.
  ##
  ## `eager` IS STILL READ, FOR ONE THING: to tell a point READ FROM ITS
  ## SLOT from a value the author passed EXPLICITLY at the `enable`
  ## site. The activity's `config:` key lowers to a parameter whose
  ## DEFAULT reads the fold, so `enable sso()` yields the fold and
  ## `enable sso(members = @["x"])` yields `@["x"]` and never evaluates
  ## the default. Deferring the latter would let a later contribution
  ## overwrite an explicit argument — an owner overriding its own
  ## environment at its own enable site (§6.6) silently undone. So when
  ## `eager` differs from the point's fold AT THIS MOMENT the tokens are
  ## FROZEN as literals, and only the matching case defers.
  if dslPortActiveServiceContext.len == 0:
    return
  var deferred = isContributionPoint(pointKey)
  if deferred:
    # The fold is read HERE only to compare, never to emit: what is
    # emitted in the deferring case is the hole.
    deferred = foldContributionPoint(pointKey).members == eager
  if not deferred:
    for value in eager:
      addActiveServiceArg(value)
    return
  dslPortActiveServiceContext[^1].argTemplate.add(ServiceArgTemplateItem(
    kind: satkContributionPoint, pointKey: pointKey))
  # The EAGER tokens are still written into `args` / `typedArgs`, so a
  # reader that never reaches finalization (a test driving a service
  # body directly, the package-level `service` lane) sees exactly what
  # it saw before this change. `foldDeferredServiceArgv` REPLACES them.
  for value in eager:
    dslPortActiveServiceContext[^1].args.add(value)
    dslPortActiveServiceContext[^1].typedArgs.add(ServiceArgDef(
      kind: svakLiteral, value: value))

proc addActiveServiceRuntimeFile*(value: BuildOutput) =
  ## Body-setter for ``runtimeFile <buildOutput>`` — "declares a build
  ## output that the service must have alongside it at runtime even
  ## though the path does not appear on argv" (``Package-Model.md``).
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].runtimeFiles.add(ServiceRuntimeFileDef(
    path: value.filePath,
    producerPackage: value.packageName,
    producerActionId: value.actionId))

proc addActiveServiceRuntimeFile*(value: BuildOutputPath) =
  ## ``runtimeFile <buildOutput>.path`` — same edge.
  if dslPortActiveServiceContext.len == 0:
    return
  dslPortActiveServiceContext[^1].runtimeFiles.add(ServiceRuntimeFileDef(
    path: value.producerPath,
    producerPackage: value.producerPackage,
    producerActionId: value.producerActionId))

proc beginActiveServiceTrigger*(kind: ServiceTriggerKind;
                                subject = ""; producerActionId = "") =
  ## Open an ``on <trigger>:`` block on the active frame. Paired with
  ## ``finishActiveServiceTrigger`` by the emitter's try/finally.
  if dslPortActiveServiceContext.len == 0:
    return
  if dslPortActiveServiceContext[^1].triggerOpen:
    # A nested ``on:`` is not a shape the macro emits; closing the outer
    # one keeps its actions rather than losing them.
    dslPortActiveServiceContext[^1].triggers.add(
      dslPortActiveServiceContext[^1].openTrigger)
  dslPortActiveServiceContext[^1].openTrigger = ServiceTriggerDef(
    kind: kind, subject: subject, producerActionId: producerActionId,
    actions: @[])
  dslPortActiveServiceContext[^1].triggerOpen = true

proc beginActiveServiceTrigger*(kind: ServiceTriggerKind;
                                output: BuildOutput) =
  ## ``on change <buildOutput>:`` — the watched path AND the edge that
  ## produces it, so a lowering can order the watch after the producer.
  beginActiveServiceTrigger(kind, output.filePath, output.actionId)

proc beginActiveServiceTrigger*(kind: ServiceTriggerKind;
                                output: BuildOutputPath) =
  beginActiveServiceTrigger(kind, output.producerPath,
    output.producerActionId)

proc addActiveServiceTriggerAction*(kind: ServiceTriggerActionKind;
                                    argument = "") =
  ## Append one action to the open ``on <trigger>:`` body.
  if dslPortActiveServiceContext.len == 0:
    return
  if not dslPortActiveServiceContext[^1].triggerOpen:
    return
  dslPortActiveServiceContext[^1].openTrigger.actions.add(
    ServiceTriggerAction(kind: kind, argument: argument))

proc finishActiveServiceTrigger*() =
  ## Close the open ``on <trigger>:`` block and append it to the frame.
  if dslPortActiveServiceContext.len == 0:
    return
  if not dslPortActiveServiceContext[^1].triggerOpen:
    return
  dslPortActiveServiceContext[^1].triggers.add(
    dslPortActiveServiceContext[^1].openTrigger)
  dslPortActiveServiceContext[^1].triggerOpen = false

# ---------------------------------------------------------------------------
# Shared-Development-Services L1 — the ``gnkService`` node payload.
#
# ``GraphNodeKind`` has carried ``gnkService`` since the provider protocol
# was written and NOTHING ever emitted one; services reached the engine
# only as the opaque ``DevEnvServiceMetadata.metadata`` JSON string that
# ``Shared-Development-Services.md`` §1 names as the defect. This codec is
# what makes the node emittable, and it is deliberately a TYPED record
# rather than a JSON blob: the producing action id of every path travels
# with it, which is what ``buildPackageFragment`` turns into graph edges.
#
# Envelope layout matches the build-target / build-pool payloads in
# ``runtime_core`` byte for byte (4-byte magic, u16 version, u32 length),
# so a stale decoder reports "unsupported ... version" rather than
# "corrupt".
# ---------------------------------------------------------------------------

const
  ServicePayloadMagic = [byte(ord('R')), byte(ord('S')), byte(ord('V')),
    byte(ord('C'))]
  ServicePayloadVersion = 2'u16
    ## v2 (current): Shared-Development-Services L4 appends the declared
    ## INSTANCE IDENTITY and SCOPE (§4.1 / §4.2) -- one identity-kind
    ## byte, the stable id string, one scope byte -- after the M9.C
    ## systemd slice, which is the payload's tail. Appended rather than
    ## inserted for the reason ``BuildTargetKind`` gives one type section
    ## up: every field before it is positional, so a v1 body has to keep
    ## decoding unchanged.
    ##
    ## v1 bodies DO still decode: ``decodeServicePayload`` gates the new
    ## reads on ``version >= 2`` and leaves the zero values
    ## (``sikDerived`` / ``sscProject``), which are the §4 DEFAULTS, so a
    ## v1 payload decodes to exactly the behaviour it described. A version
    ## ABOVE the current one is still refused rather than misread -- that
    ## property is what the magic+version envelope exists for, and
    ## widening the check to a range keeps it for v3.

proc servicePayloadVersion*(): uint16 =
  ## The service-payload envelope version THIS BUILD writes, and -- the
  ## decoder's check being a RANGE (`0 < version <= current`) -- the
  ## highest it reads.
  ServicePayloadVersion

proc firstUnknownServicePayloadVersion*(): uint16 =
  ## One past `servicePayloadVersion()`: the lowest version above the
  ## range this build accepts.
  ##
  ## What an "a FUTURE version is refused rather than misread" probe
  ## wants. Before this name that probe poked a literal `3`, chosen when
  ## the current version was 2; the next bump to 3 would have turned it
  ## into a probe that the CURRENT version is refused -- which is false,
  ## so it would have failed loudly. That is the lucky half of the class.
  ## The unlucky half is the same shape one version further on, where the
  ## literal lands inside the accepted range and the probe quietly stops
  ## testing a refusal at all.
  ##
  ## AN ACCESSOR AND NOT AN EXPORT OF `ServicePayloadVersion`, and not for
  ## the ambiguity reason an earlier round gave -- that reason was measured
  ## FALSE (Nim diagnoses a clashing imported name at the USE site, so
  ## exporting two same-named consts compiles until something references
  ## the bare name). The reason is that `firstUnknown...` is a DERIVED
  ## value: exporting the const would put `+ 1` at every call site, and
  ## `+ 1` is only correct while the accepted range is contiguous and
  ## open-topped. Keeping the arithmetic beside the decoder that defines
  ## the range means one place to change if it ever is not.
  ServicePayloadVersion + 1

proc writeServiceExecutable(outp: var seq[byte]; value: ServiceExecutableRef) =
  outp.writeByte(byte(ord(value.kind)))
  outp.writeString(value.packageName)
  outp.writeString(value.executableName)
  outp.writeString(value.path)
  outp.writeString(value.actionId)

proc readServiceExecutable(bytes: openArray[byte]; pos: var int):
    ServiceExecutableRef =
  let kindByte = readByte(bytes, pos)
  if kindByte > byte(ord(sxkPath)):
    raisePayload("invalid service executable kind in service payload")
  ServiceExecutableRef(
    kind: ServiceExecutableKind(kindByte),
    packageName: readString(bytes, pos),
    executableName: readString(bytes, pos),
    path: readString(bytes, pos),
    actionId: readString(bytes, pos))

proc encodeServicePayload*(def: DslServiceDef): seq[byte] =
  var payload: seq[byte] = @[]
  payload.writeString(def.packageName)
  payload.writeString(def.serviceName)
  payload.writeServiceExecutable(def.executableTyped)
  # ``executableRef`` and ``args`` are written explicitly rather than
  # DERIVED from the typed fields on decode. They can legitimately
  # diverge: a record built through the legacy positional
  # ``registerService`` has them populated and the typed fields empty, and
  # for ``sxkBuildOutput`` ``executableRef`` holds the output PATH while
  # ``executableTyped.executableName`` is empty. Deriving would have made
  # the round-trip lossy in exactly those two cases.
  payload.writeString(def.executableRef)
  payload.writeStringSeq(def.args)
  payload.writeU32Le(uint32(def.typedArgs.len))
  for arg in def.typedArgs:
    payload.writeByte(byte(ord(arg.kind)))
    payload.writeString(arg.value)
    payload.writeString(arg.producerPackage)
    payload.writeString(arg.producerActionId)
    payload.writeString(arg.producerPath)
  payload.writeU32Le(uint32(def.runtimeFiles.len))
  for file in def.runtimeFiles:
    payload.writeString(file.path)
    payload.writeString(file.producerPackage)
    payload.writeString(file.producerActionId)
  payload.writeU32Le(uint32(def.triggers.len))
  for trigger in def.triggers:
    payload.writeByte(byte(ord(trigger.kind)))
    payload.writeString(trigger.subject)
    payload.writeString(trigger.producerActionId)
    payload.writeU32Le(uint32(trigger.actions.len))
    for action in trigger.actions:
      payload.writeByte(byte(ord(action.kind)))
      payload.writeString(action.argument)
  # The M9.C systemd-unit slice, so a lowering that writes a unit file
  # does not have to go back to the DSL registry for it.
  payload.writeString(def.description)
  payload.writeString(def.serviceType)
  payload.writeString(def.execStart)
  payload.writeStringSeq(def.wantedBy)
  payload.writeStringSeq(def.wants)
  payload.writeStringSeq(def.requires)
  payload.writeStringSeq(def.before)
  payload.writeStringSeq(def.after)
  payload.writeU32Le(uint32(def.env.len))
  for entry in def.env:
    payload.writeString(entry.key)
    payload.writeString(entry.value)
  payload.writeString(def.restart)
  payload.writeString(def.user)
  payload.writeString(def.group)
  # v2 (L4): the declared identity and scope. Written unconditionally --
  # this encoder only ever emits the CURRENT version, and a reader of an
  # older body is the compatibility direction (see the decoder).
  payload.writeByte(byte(ord(def.identity.kind)))
  payload.writeString(def.identity.stableId)
  payload.writeByte(byte(ord(def.scope)))

  result.add(ServicePayloadMagic)
  result.writeU16Le(ServicePayloadVersion)
  result.writeU32Le(uint32(payload.len))
  result.add(payload)

proc decodeServicePayload*(bytes: openArray[byte]): DslServiceDef =
  if bytes.len < 10:
    raisePayload("truncated service payload envelope")
  for i in 0 ..< ServicePayloadMagic.len:
    if bytes[i] != ServicePayloadMagic[i]:
      raisePayload("unknown service payload magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version == 0'u16 or version > ServicePayloadVersion:
    raisePayload("unsupported service payload version")
  let payloadLength = int(readU32Le(bytes, pos))
  if pos + payloadLength != bytes.len:
    raisePayload("service payload length mismatch")
  result.packageName = readString(bytes, pos)
  result.serviceName = readString(bytes, pos)
  result.executableTyped = readServiceExecutable(bytes, pos)
  result.executableRef = readString(bytes, pos)
  result.executable = result.executableRef
  result.args = readStringSeq(bytes, pos)
  var count = int(readU32Le(bytes, pos))
  for _ in 0 ..< count:
    let kindByte = readByte(bytes, pos)
    if kindByte > byte(ord(svakBuildOutput)):
      raisePayload("invalid service argument kind in service payload")
    result.typedArgs.add(ServiceArgDef(
      kind: ServiceArgKind(kindByte),
      value: readString(bytes, pos),
      producerPackage: readString(bytes, pos),
      producerActionId: readString(bytes, pos),
      producerPath: readString(bytes, pos)))
  count = int(readU32Le(bytes, pos))
  for _ in 0 ..< count:
    result.runtimeFiles.add(ServiceRuntimeFileDef(
      path: readString(bytes, pos),
      producerPackage: readString(bytes, pos),
      producerActionId: readString(bytes, pos)))
  count = int(readU32Le(bytes, pos))
  for _ in 0 ..< count:
    let kindByte = readByte(bytes, pos)
    if kindByte > byte(ord(stkCrash)):
      raisePayload("invalid service trigger kind in service payload")
    var trigger = ServiceTriggerDef(
      kind: ServiceTriggerKind(kindByte),
      subject: readString(bytes, pos),
      producerActionId: readString(bytes, pos))
    let actionCount = int(readU32Le(bytes, pos))
    for _ in 0 ..< actionCount:
      let actionKindByte = readByte(bytes, pos)
      if actionKindByte > byte(ord(stakNotify)):
        raisePayload("invalid service trigger action kind in service payload")
      trigger.actions.add(ServiceTriggerAction(
        kind: ServiceTriggerActionKind(actionKindByte),
        argument: readString(bytes, pos)))
    result.triggers.add(trigger)
  result.description = readString(bytes, pos)
  result.serviceType = readString(bytes, pos)
  result.execStart = readString(bytes, pos)
  result.wantedBy = readStringSeq(bytes, pos)
  result.wants = readStringSeq(bytes, pos)
  result.requires = readStringSeq(bytes, pos)
  result.before = readStringSeq(bytes, pos)
  result.after = readStringSeq(bytes, pos)
  count = int(readU32Le(bytes, pos))
  for _ in 0 ..< count:
    let key = readString(bytes, pos)
    let value = readString(bytes, pos)
    result.env.add((key: key, value: value))
  result.restart = readString(bytes, pos)
  result.user = readString(bytes, pos)
  result.group = readString(bytes, pos)
  # v2 (L4). A v1 body ends here; the identity and scope fields keep
  # their zero values, which ARE the §4 defaults -- ``identity derived``
  # and ``scope project`` -- so a v1 payload decodes to the behaviour it
  # described rather than to an invented "unset".
  if version >= 2'u16:
    let identityKindByte = readByte(bytes, pos)
    if identityKindByte > byte(ord(sikStable)):
      raisePayload("invalid service identity kind in service payload")
    result.identity = ServiceIdentityDef(
      kind: ServiceIdentityKind(identityKindByte),
      stableId: readString(bytes, pos))
    let scopeByte = readByte(bytes, pos)
    if scopeByte > byte(ord(sscSystem)):
      raisePayload("invalid service scope in service payload")
    result.scope = ServiceScope(scopeByte)
  if pos != bytes.len:
    raisePayload("trailing service payload bytes")

proc servicePayload*(def: DslServiceDef): string =
  fromBytes(encodeServicePayload(def))

proc serviceProducerActionIds*(def: DslServiceDef): seq[string] =
  ## Every build action this service depends on, deduplicated and in
  ## declaration order: the executable's producer, then each
  ## build-output argument's, then each runtime file's, then each watched
  ## output's. This is the edge set ``buildPackageFragment`` emits, named
  ## once so the emitter and any consumer agree on it.
  proc push(ids: var seq[string]; id: string) =
    if id.len > 0 and ids.find(id) < 0:
      ids.add(id)
  if def.executableTyped.actionId.len > 0:
    result.push(def.executableTyped.actionId)
  for arg in def.typedArgs:
    if arg.kind == svakBuildOutput:
      result.push(arg.producerActionId)
  for file in def.runtimeFiles:
    result.push(file.producerActionId)
  for trigger in def.triggers:
    if trigger.kind == stkChangeOutput:
      result.push(trigger.producerActionId)

proc serviceConsumedOutputs*(def: DslServiceDef):
    seq[tuple[actionId: string; path: string]] =
  ## Every (producing action, declared output path) pair the service
  ## consumes — argv references, runtime files and watched outputs. One
  ## ``gekConsumes`` edge each.
  proc push(items: var seq[tuple[actionId: string; path: string]];
            actionId, path: string) =
    if actionId.len == 0 or path.len == 0:
      return
    for item in items:
      if item.actionId == actionId and item.path == path:
        return
    items.add((actionId: actionId, path: path))
  if def.executableTyped.kind == sxkBuildOutput:
    result.push(def.executableTyped.actionId, def.executableTyped.path)
  for arg in def.typedArgs:
    if arg.kind == svakBuildOutput:
      result.push(arg.producerActionId, arg.producerPath)
  for file in def.runtimeFiles:
    result.push(file.producerActionId, file.path)
  for trigger in def.triggers:
    if trigger.kind == stkChangeOutput:
      result.push(trigger.producerActionId, trigger.subject)

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
  var frame = dslPortActiveServiceContext[^1]
  dslPortActiveServiceContext.setLen(
    dslPortActiveServiceContext.len - 1)
  # Shared-Development-Services L1: an ``on <trigger>:`` block left open
  # by a malformed body is closed here rather than dropped, so its
  # actions still reach the record and the author sees them.
  if frame.triggerOpen:
    frame.triggers.add(frame.openTrigger)
    frame.triggerOpen = false
  registerServiceRecord(DslServiceDef(
    packageName: frame.packageName,
    serviceName: frame.serviceName,
    executableRef: frame.executableRef,
    executable: frame.executableRef,
    args: frame.args,
    bodyRepr: frame.bodyRepr,
    description: frame.description,
    serviceType: frame.serviceType,
    execStart: frame.execStart,
    wantedBy: frame.wantedBy,
    wants: frame.wants,
    requires: frame.requires,
    before: frame.before,
    after: frame.after,
    env: frame.env,
    restart: frame.restart,
    user: frame.user,
    group: frame.group,
    executableTyped: frame.executableTyped,
    typedArgs: frame.typedArgs,
    runtimeFiles: frame.runtimeFiles,
    triggers: frame.triggers,
    identity: frame.identity,
    scope: frame.scope,
    convergePoints: frame.convergePoints,
    readiness: frame.readiness,
    workingDirectory: frame.workingDirectory,
    stateDirectories: frame.stateDirectories,
    instance: frame.instance),
    frame.argTemplate)


proc foldDeferredServiceArgv*(packageName: string): int {.discardable.} =
  ## Shared-Development-Services, reprobuild issue #498 — FINALIZATION:
  ## fill every deferred `args <contributionPoint>` slot of
  ## `packageName`'s services from the point's fold AS IT NOW STANDS.
  ##
  ## Called once, after every activity body in the package has run, by
  ## `buildPackageDevEnv` (and by `buildPackageFragment` after its
  ## service-declarator re-run, so the build lane cannot drift from the
  ## dev-env lane on this). The same moment `mergeTypedServiceFacts`
  ## folds `registrationMembers`, which is the point: ONE fold of one
  ## contribution point at ONE time, so the launcher's command line and
  ## the converge lane's member set are two READINGS of one value rather
  ## than two values.
  ##
  ## Returns the number of services whose argv CHANGED. A caller that
  ## wants to know whether anything was deferred at all can read it;
  ## more importantly a test can, which is how "the deferral is wired"
  ## is measurable rather than inferred from the result being correct
  ## for some other reason.
  ##
  ## IDEMPOTENT. The template is the source and the row is the
  ## derivation, so running this twice against one contribution set
  ## rewrites the same bytes and the second call returns 0.
  if packageName notin dslPortServiceRegistry:
    return 0
  if packageName notin dslPortServiceArgTemplates:
    return 0
  var rows = dslPortServiceRegistry[packageName]
  let templates = dslPortServiceArgTemplates[packageName]
  if templates.len != rows.len:
    # NOT a silent `min(len)` walk. A misalignment here would rewrite
    # one service's argv from another's template, which is a wrong
    # command line that looks right.
    raise newException(ValueError,
      "foldDeferredServiceArgv(`" & packageName & "`): " &
      $rows.len & " service row(s) against " & $templates.len &
      " argv template(s). The two are maintained index for index by " &
      "`registerServiceRecord`, so a disagreement means a row reached " &
      "the registry by a route that did not record one.")
  for i in 0 ..< rows.len:
    var deferred = false
    for item in templates[i]:
      if item.kind == satkContributionPoint:
        deferred = true
        break
    if not deferred:
      continue
    var args: seq[string] = @[]
    var typedArgs: seq[ServiceArgDef] = @[]
    for item in templates[i]:
      case item.kind
      of satkLiteral:
        args.add(item.arg.value)
        typedArgs.add(item.arg)
      of satkContributionPoint:
        # ONE TOKEN PER MEMBER, in fold order, and NO token for an empty
        # collection -- the same rule `addActiveServiceArg(seq[string])`
        # states, read from one place so the deferred and the eager
        # paths cannot render a point differently.
        for member in foldContributionPoint(item.pointKey).members:
          args.add(member)
          typedArgs.add(ServiceArgDef(kind: svakLiteral, value: member))
    if args != rows[i].args:
      inc result
    rows[i].args = args
    rows[i].typedArgs = typedArgs
  dslPortServiceRegistry[packageName] = rows

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
##   * ``dataFile: true`` — download and verify a single file without
##     archive extraction (kind == ``dfkDataFile``).
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
    ## Discriminant for the fetch source kind.
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
    dfkDataFile
      ## Download a single file from ``url`` and place it at
      ## ``<extractedRoot>/source`` without archive extraction.

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
      ## Tarball/data URL or git URL, according to ``kind``.
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

proc sourceFetchHashTool*(hashAlg: DslSourceHashAlg): string =
  case hashAlg
  of dshaSha256: "sha256sum"
  of dshaBlake3: "b3sum"

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

var dslPortGeneratedToolDeps {.threadvar.}: Table[string, seq[string]]
  ## The subset of ``dslPortPackageDeps`` rows that reprobuild's own
  ## emitters added, rather than the recipe author.
  ##
  ## ``registerSourceFetchTools`` / ``registerInstallMirrorTools`` declare
  ## the external commands the GENERATED fetch and install-mirror shell
  ## scripts run (``sh``, ``curl``, ``tar``, ``sed``, ``patchelf``, …) so
  ## those tools are solved and present before a build body runs. Those
  ## rows belong in the dep list — the mirror's rpath patching reads them
  ## back out through ``registeredNativeBuildDeps``.
  ##
  ## They are NOT, however, statements about the recipe's own build
  ## system, and one consumer reads the same row as exactly that: the
  ## M9.R.6 convention narrowing infers meson / cmake / autotools / make /
  ## CUSTOM from the declared toolset. Since every generated fetch script
  ## runs through ``sh``, an unannotated read made every ``fetch:``-bearing
  ## recipe look shell-driven. Recording the provenance lets each consumer
  ## ask for the list it actually means.
  ##
  ## Same ``packageName & '\x00' & kind`` key encoding as
  ## ``dslPortPackageDeps``, and the same ``threadvar`` lifetime.

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
  dslPortGeneratedToolDeps.clear()

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
  ##
  ## The append is SET-like: re-registering a ``(packageName, kind,
  ## constraint)`` triple that is already present is a no-op. A
  ## package's dep list is a set of constraints, so a repeat carries no
  ## information — but it is NOT harmless to record it. One recipe
  ## module can be instantiated several times in a single process (the
  ## per-consumer sibling shims give each consumer its own module
  ## instance, so a diamond in the source dep closure re-runs a shared
  ## recipe's module init once per path to it), and every instance
  ## replays the same registration calls. Appending blindly made the
  ## registered list grow with the number of instantiations, and the
  ## Layer-1 package constructors read that list to auto-thread cache
  ## vars / link dirs / CMake module paths — so the lowered graph
  ## stopped being a pure function of the recipe. Collapsing the repeat
  ## keeps every instantiation observing the declared list verbatim.
  ##
  ## Registering a constraint HERE also clears any generated-tool mark on
  ## it (see ``registerGeneratedToolDep``): a recipe that spells ``sh`` in
  ## its own ``nativeBuildDeps:`` owns that entry no matter which emitter
  ## also asked for it, and no matter which ran first.
  case kind
  of "build", "native", "runtime":
    let key = m9r1PackageDepsKey(packageName, kind)
    if key notin dslPortPackageDeps:
      dslPortPackageDeps[key] = @[]
    if constraint notin dslPortPackageDeps[key]:
      dslPortPackageDeps[key].add(constraint)
    if key in dslPortGeneratedToolDeps:
      let generatedIndex = dslPortGeneratedToolDeps[key].find(constraint)
      if generatedIndex >= 0:
        dslPortGeneratedToolDeps[key].delete(generatedIndex)
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

proc registerGeneratedToolDep*(packageName, kind, constraint: string) =
  ## Register a dep that a reprobuild EMITTER needs, not one the recipe
  ## author wrote. Appends through ``registerPackageDep`` — so every
  ## existing reader still sees it — and additionally records the
  ## provenance so ``registeredAuthoredNativeBuildDeps`` can subtract it.
  ##
  ## Use this for the external commands a GENERATED script runs. Anything
  ## the recipe spelled in a ``buildDeps:`` / ``nativeBuildDeps:`` /
  ## ``runtimeDeps:`` block goes through ``registerPackageDep`` directly.
  ##
  ## An entry the recipe ALREADY declared stays authored: the mark is only
  ## taken when this call is what introduced the constraint. Together with
  ## the un-marking in ``registerPackageDep`` this makes provenance
  ## independent of emission order — a recipe that lists ``sh`` itself and
  ## also declares ``fetch:`` keeps narrowing to the custom convention,
  ## whichever registration the macro emits first.
  case kind
  of "build", "native", "runtime":
    let key = m9r1PackageDepsKey(packageName, kind)
    # Three states before this call, and only the first must not be
    # marked: authored already (leave it authored), marked generated
    # already (a replayed or overlapping emitter call — keep the mark),
    # or absent (this call introduces it — mark it).
    let alreadyGenerated =
      key in dslPortGeneratedToolDeps and
      constraint in dslPortGeneratedToolDeps[key]
    let alreadyAuthored =
      not alreadyGenerated and
      key in dslPortPackageDeps and constraint in dslPortPackageDeps[key]
    # Clears the mark, so the re-mark below must follow it.
    registerPackageDep(packageName, kind, constraint)
    if not alreadyAuthored:
      if key notin dslPortGeneratedToolDeps:
        dslPortGeneratedToolDeps[key] = @[]
      if constraint notin dslPortGeneratedToolDeps[key]:
        dslPortGeneratedToolDeps[key].add(constraint)
  else:
    discard

proc registeredNativeBuildDeps*(packageName: string): seq[string] =
  ## Return the constraint-string seq for ``packageName``'s
  ## ``nativeBuildDeps:`` block in source-declaration order. Returns
  ## an empty seq when nothing was registered.
  ##
  ## This is the COMPLETE build-time tool set: the recipe's own
  ## ``nativeBuildDeps:`` entries plus whatever reprobuild's fetch and
  ## install-mirror emitters need in order to run their generated
  ## scripts. Callers resolving tools, lib dirs or solver edges want this
  ## list. Callers INFERRING SOMETHING ABOUT THE RECIPE from it want
  ## ``registeredAuthoredNativeBuildDeps`` instead.
  let key = m9r1PackageDepsKey(packageName, "native")
  if key in dslPortPackageDeps:
    return dslPortPackageDeps[key]
  return @[]

proc registeredAuthoredNativeBuildDeps*(packageName: string): seq[string] =
  ## ``registeredNativeBuildDeps`` minus the entries reprobuild's own
  ## emitters contributed — i.e. exactly what the recipe's
  ## ``nativeBuildDeps:`` block said, in source-declaration order.
  ##
  ## Read this when the answer is a statement ABOUT THE RECIPE, such as
  ## "which build system does this package use". A generated fetch script
  ## needing ``sh`` says nothing about whether the upstream project is
  ## meson-driven; including it made every ``fetch:``-bearing recipe
  ## narrow to the custom (shell-driver) convention.
  let key = m9r1PackageDepsKey(packageName, "native")
  if key notin dslPortPackageDeps:
    return @[]
  let generated =
    if key in dslPortGeneratedToolDeps: dslPortGeneratedToolDeps[key]
    else: @[]
  if generated.len == 0:
    return dslPortPackageDeps[key]
  for constraint in dslPortPackageDeps[key]:
    if constraint notin generated:
      result.add(constraint)

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
  ## extract → touch stamp. ``file://`` URLs work natively
  ## via curl.
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  let staged = extracted & ".repro-extract-" & spec.hashHex
  let escapedStaged = staged.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("rm -rf \"" & escapedStaged & "\"; ")
  script.add("mkdir -p \"" & escapedStaged & "\"; ")
  script.appendCurlDownload(tarball, spec.url)
  case spec.hashAlg
  of dshaSha256:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | sha256sum -c -; ")
  of dshaBlake3:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | b3sum -c -; ")
  if spec.kind == dfkDataFile:
    script.add("cp \"" & escapedTarball & "\" \"" &
      escapedStaged & "/source\"; ")
  else:
    script.appendTarExtraction(tarball, staged, spec.extractStrip)
  script.add("rm -rf \"" & escapedExtracted & "\"; ")
  script.add("mv \"" & escapedStaged & "\" \"" & escapedExtracted & "\"; ")
  script.appendVerifiedFetchStamp(stamp)
  script

proc dslPortSubstituteShellPlaceholders*(command, fetchPath, extractedPath,
                                        outPath: string): string =
  ## Replace ``$fetch`` / ``$extracted`` / ``$out`` in ``command``.
  ## Mirrors ``from_source_custom.substitutePlaceholders`` byte-for-byte
  ## so a recipe routed through the per-project provider gets the same
  ## substituted argv as one routed through the standard provider.
  let shellFetchPath = fetchPath.replace("\\", "/")
  let shellExtractedPath = extractedPath.replace("\\", "/")
  let shellOutPath = outPath.replace("\\", "/")
  result = command.replace("$extracted", shellExtractedPath)
  result = result.replace("$fetch", shellFetchPath)
  result = result.replace("$out", shellOutPath)

proc dslPortSanitizeIdPart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc dslPortInstallMirrorPublishVersion(packageName: string): string =
  result = latestRegisteredPackageVersion(packageName)

const customMirrorFallbackSubdirs* = [
  "lib", "lib64", "libexec", "include", "bin", "share"
]

proc dslPortStripDepConstraint(value: string): string =
  for i, ch in value:
    if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
        ch == '~' or ch == '^':
      return value[0 ..< i]
  value

proc dslPortCustomShellToolIdentityRefs*(packageName: string):
    seq[string] {.dynOrStatic.} =
  ## Attach every declared dependency profile to custom shell actions.
  ## This supplies PATH and the auxiliary CPATH/LIBRARY_PATH channels
  ## while preserving the shell as the command interpreter identity.
  result = @["sh", "mkdir", "touch"]
  for raw in registeredNativeBuildDeps(packageName):
    let dep = dslPortStripDepConstraint(raw)
    if dep.len > 0 and dep notin result:
      result.add(dep)
  for raw in registeredBuildDeps(packageName):
    let dep = dslPortStripDepConstraint(raw)
    if dep.len > 0 and dep notin result:
      result.add(dep)

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
  let shellToolRefs = dslPortCustomShellToolIdentityRefs(packageName)
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
    let hashTools = @[sourceFetchHashTool(spec.hashAlg)]
    let fetchToolRefs = shellFetchToolIdentityRefs(hashTools,
      copiesDataFile = spec.kind == dfkDataFile,
      archiveUrl = spec.url)
    fetchId = "ccpp-fetch-" & dslPortSanitizeIdPart(packageName)
    discard buildAction(
      id = fetchId,
      call = inlineExecCall(@["sh", "-c", fetchScript], projectRoot),
      inputs = @[],
      outputs = @[fetchStamp],
      pool = "fetch",
      cacheable = false,
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "from-source-custom.fetch." & hashAlgTag,
      env = shellFetchRuntimeEnv(),
      toolIdentityRefs = fetchToolRefs)
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
    let outMirrorRoot = (projectRoot / ".repro" / "output" / "install").
      replace("\\", "/")
    let shellEnv = @[("OUT_MIRROR", outMirrorRoot)]
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
      env = shellEnv,
      toolIdentityRefs = shellToolRefs)
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
    let recipesRoot = parentDir(projectRoot)
    let recipeName = projectRoot.extractFilename
    let publishVersion = dslPortInstallMirrorPublishVersion(packageName)
    var script = "set -e; "
    script.add("rm -rf \"" & escapedMirrorUsr & "\"; ")
    script.add("mkdir -p \"" & escapedMirrorRoot & "\"; ")
    # Primary path: $out/install/usr/ tree (the canonical destdir
    # shape custom-shell recipes like boost emit). Copy verbatim into
    # the mirror.
    script.add("if [ -d \"" & escapedOutPath & "/install/usr\" ]; then ")
    script.add("cp -a -- \"" & escapedOutPath & "/install/usr\" \"" &
      escapedMirrorRoot & "/\"; ")
    script.add("elif [ -d \"" & escapedOutPath & "/usr\" ]; then ")
    script.add("cp -a -- \"" & escapedOutPath & "/usr\" \"" &
      escapedMirrorRoot & "/\"; ")
    script.add("else ")
    # Fallback: bare $out/lib + $out/include + $out/bin (recipes that
    # didn't relocate to install/usr/). Compose a synthetic usr/ tree.
    script.add("mkdir -p \"" & escapedMirrorUsr & "\"; ")
    for sub in customMirrorFallbackSubdirs:
      script.add("if [ -d \"" & escapedOutPath & "/" & sub &
        "\" ]; then cp -a -- \"" & escapedOutPath & "/" & sub &
        "\" \"" & escapedMirrorUsr & "/\"; fi; ")
    script.add("fi; ")
    script.add("for pcdir in \"" & escapedMirrorUsr & "/lib/pkgconfig\" \"" &
      escapedMirrorUsr & "/lib64/pkgconfig\" \"" & escapedMirrorUsr &
      "/share/pkgconfig\"; do ")
    script.add("if [ -d \"$pcdir\" ]; then for pc in \"$pcdir\"/*.pc; do ")
    script.add("if [ -f \"$pc\" ]; then sed -i ")
    script.add("'1,/^prefix=/{ s|^prefix=.*$|prefix=" & escapedMirrorUsr & "|; } ")
    script.add("; s|^exec_prefix=/usr|exec_prefix=" & escapedMirrorUsr & "| ")
    script.add("; s|^libdir=/usr/lib64|libdir=" & escapedMirrorUsr & "/lib64| ")
    script.add("; s|^libdir=/usr/lib|libdir=" & escapedMirrorUsr & "/lib| ")
    script.add("; s|^includedir=/usr/include|includedir=" & escapedMirrorUsr & "/include| ")
    script.add("; s|^datadir=/usr/share|datadir=" & escapedMirrorUsr & "/share| ")
    script.add("; s|^datarootdir=/usr/share|datarootdir=" & escapedMirrorUsr & "/share|' ")
    script.add("\"$pc\"; fi; done; fi; done; ")
    let mirrorDeps = registeredNativeBuildDeps(packageName) &
      registeredBuildDeps(packageName) & registeredRuntimeDeps(packageName)
    # Not on Windows — see the matching guard in `emitInstallTreeMirror`: no
    # ELF to patch, and the snippet's `command -v patchelf` would make the
    # mirror depend on the user's PATH.
    when not defined(windows):
      script.add(m9r14fEmitRpathPatchScript(escapedMirrorUsr,
        installMirrorDepLibDirs(projectRoot, mirrorDeps),
        depManifestPaths = installMirrorDepManifestPaths(projectRoot, mirrorDeps),
        ownManifestPath = (mirrorRoot / m9r30PropagatedManifestName).replace("\\", "/"),
        packageName = packageName,
        recipesRoot = recipesRoot))
    script.add("touch \"" & escapedMirrorStamp & "\"; ")
    script.add(emitInstallMirrorStorePublish(recipesRoot, recipeName,
      publishVersion, mirrorRoot))
    let mirrorActionId = "from-source-custom-mirror-" &
      dslPortSanitizeIdPart(packageName)
    let packageVersion = block:
      let versions = registeredVersions(packageName)
      if versions.len > 0: versions[^1].version else: ""
    let cacheIdentity = sourceCacheEntryIdentity(
      projectRoot, packageName, packageVersion, "custom")
    var mirrorOutputs = @[mirrorStamp]
    if publishVersion.len > 0:
      mirrorOutputs.add(realizationInfoPath(recipesRoot, recipeName))
    discard buildAction(
      id = mirrorActionId,
      call = inlineExecCall(@["sh", "-c", script], projectRoot),
      deps = @[prevId],
      inputs = @[prevStamp],
      outputs = mirrorOutputs,
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "from-source-custom.mirror",
      publishToBinaryCache = true,
      cacheEntryIdentity = some(cacheIdentity),
      toolIdentityRefs = installMirrorToolIdentityRefs(packageName, mirrorDeps),
      declaredOutputs = @[mirrorRoot])

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
##   * ``multiVersion forbidden | allowed``   — Named-Lock-Files §9.3: may
##                                              two versions of this library
##                                              be linked into one binary?
##                                              Omitted means the answer is
##                                              INHERITED from the language
##                                              convention (Q-11), and the
##                                              terminus of that inheritance
##                                              is ``forbidden``.
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
    multiVersion*: MultiVersionPolicy
      ## Named-Lock-Files NLF-M8 (§9.3) — whether several versions of THIS
      ## library may be linked into one binary.
      ##
      ## It lives in `api:` beside `linkKind` / `soname` / `sover` because it
      ## is consumption metadata of exactly that kind, and it belongs to the
      ## library rather than to the linkage site because "whether two versions
      ## of it can share one binary is a fact only its author knows" (§9.5,
      ## closing Q-2).
      ##
      ## `mvUnset` — the default — is NOT `mvAllowed`. §9.3: "the property is
      ## named such that **silence means safe**: a library that declares
      ## nothing is `forbidden`". The resolution from `mvUnset` to an
      ## effective answer runs through the per-language conventions (Q-11) in
      ## `repro_lock_files/diamond.resolveMultiVersion`, and the diagnostic
      ## says which convention it came from.
    multiVersionSourceFile*: string
      ## §9.4 requires the co-linking error to cite "the declaration's
      ## file:line". Captured at macro-expansion time from the `multiVersion`
      ## line's own position, not the library's, because the line the author
      ## has to change is the one that made the claim.
    multiVersionSourceLine*: int
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

# ---------------------------------------------------------------------------
# Shared-Development-Services L5 — ENVIRONMENTS.
#
# `Shared-Development-Services.md` §6 is the authority, and its first
# sentence is the whole specification of this section:
#
#   "An environment is a named set of bindings to configurables, and
#    nothing else. The service or activity declares its configurables; an
#    environment binds them; the existing late-binding machinery
#    assembles the result."
#
# So what is HERE is a registry of names to binding sets, plus the one
# proc that hands those bindings to the EXISTING override lane
# (`setConfigurableRaw`, the table `readConfigurable` consults before the
# registered default). There is no new staging, no new merge rule and no
# new precedence model, which is §6.1's requirement stated as a
# constraint on this code: `applySelectedEnvironment` calls nothing that
# did not already exist, and an environment reaches a configurable by
# exactly the route a `setConfigurable` from any other contributor does.
#
# WHAT IS DELIBERATELY NOT HERE:
#
#   * the ATTACH DECISION (§4.3) is L6;
#   * the instance REGISTRY and `repro up` convergence (§4.5) are L7;
#   * the CONTRIBUTION operation axis (`append` / `replace`, §5.1) is L8.
#     An environment binding is a `replace` at `epOverride` in the terms
#     L8 will introduce, and this code does not pre-empt the spelling.
# ---------------------------------------------------------------------------

const
  ReproEnvironmentEnvVar* = "REPRO_ENVIRONMENT"
    ## The variable that SELECTS an environment for this invocation.
    ##
    ## §6.4 requires that the selected environment "MUST be a tracked
    ## solver input that participates in the graph cache key. An ambient
    ## `getEnv` is silently ignored when a lowered graph is served from
    ## cache, so an environment selected that way could hand a developer
    ## a production issuer out of a warm cache."
    ##
    ## Reading the selection from the process environment is not what
    ## makes a selector ambient; FAILING TO FOLD IT INTO THE KEY is. This
    ## variable is the transport, and `canonicalEnvironmentSelection`
    ## below is the tracked projection that
    ## `repro_cli_support`'s `loweredGraphCacheKey` and
    ## `providerGraphStoreRoot` both fold in -- the same two places, and
    ## the same treatment, `REPRO_VARIANTS` already gets.

var dslPortEnvironmentRegistry: Table[string, seq[DslEnvironmentDef]]
  ## Per-package environment registry, keyed by package name. Parallel in
  ## shape to `dslPortServiceRegistry`, and separate from it on purpose:
  ## an environment is not a member of a service and a service is not a
  ## member of an environment (§6.2).

var dslPortEnvironmentOrder: seq[string]
  ## `<package>\x1f<environment>` in declaration order, so enumeration is
  ## stable regardless of hash-table bucket layout -- the reason
  ## `dslPortKeyOrder` exists beside `dslPortDefaults`.

var dslPortEnvironmentAppliers: Table[string, proc () {.closure.}]
  ## `<package>\x1f<environment>` -> the closure that performs that
  ## environment's bindings.
  ##
  ## A CLOSURE and not a value table, because a binding's value is the
  ## author's EXPRESSION and only the author's scope can evaluate it --
  ## the same reason L1 wraps a `service` body in a re-runnable closure
  ## (`registerServiceDeclarator`) instead of recording its argv as
  ## strings. `DslEnvironmentDef.bindings` carries the expression's
  ## `repr` for diagnostics and for the key; this carries the means to
  ## evaluate it.

var dslPortConsumerOverrides: seq[ConsumerInstanceOverrideDef]
  ## §6.6's left column, in declaration order. A flat seq rather than a
  ## table: the key would be `(consumer, target package, target service)`
  ## and nothing reads it by key yet -- L6 and L7 do.

proc dslPortEnvironmentKey(packageName, environmentName: string): string =
  packageName & "\x1f" & environmentName

proc resetDslPortEnvironmentState*() =
  ## Drop every registered environment and consumer override. Test
  ## fixtures call this between scenarios so registry entries do not leak
  ## across cases. Symmetric with `resetDslPortServiceState`.
  dslPortEnvironmentRegistry.clear()
  dslPortEnvironmentOrder.setLen(0)
  dslPortEnvironmentAppliers.clear()
  dslPortConsumerOverrides.setLen(0)

proc registerEnvironment*(def: DslEnvironmentDef) =
  ## Record one `environment <name>:` declaration.
  ##
  ## FIRST-WINS on a repeated `(package, name)` pair, which is the
  ## behaviour `DslServiceContextFrame`'s identity guard has and for the
  ## same reason: the macro already refuses a second `environment dev:`
  ## at expansion time, so this branch is unreachable from a recipe, and
  ## if it were reachable last-wins would make which issuer a developer
  ## gets depend on statement order.
  let key = dslPortEnvironmentKey(def.packageName, def.name)
  if key in dslPortEnvironmentOrder:
    return
  if def.packageName notin dslPortEnvironmentRegistry:
    dslPortEnvironmentRegistry[def.packageName] = @[]
  dslPortEnvironmentRegistry[def.packageName].add(def)
  dslPortEnvironmentOrder.add(key)

proc registerEnvironmentApplier*(packageName, environmentName: string;
                                 applier: proc () {.closure.}) =
  ## Record the closure that applies `(packageName, environmentName)`'s
  ## bindings. FIRST-WINS, for `registerEnvironment`'s reason -- the two
  ## registries must agree on which declaration won.
  let key = dslPortEnvironmentKey(packageName, environmentName)
  if key in dslPortEnvironmentAppliers:
    return
  dslPortEnvironmentAppliers[key] = applier

proc registeredEnvironments*(packageName: string): seq[DslEnvironmentDef] =
  ## Every environment `packageName` declared, in declaration order. A
  ## copy, so a caller cannot mutate the registry.
  if packageName in dslPortEnvironmentRegistry:
    return dslPortEnvironmentRegistry[packageName]
  @[]

proc registeredEnvironmentNames*(packageName: string): seq[string] =
  for def in registeredEnvironments(packageName):
    result.add(def.name)

proc registeredEnvironment*(packageName, environmentName: string):
    DslEnvironmentDef =
  ## The named environment, or a zero record whose `name` is empty.
  ##
  ## MATCHED UNDER NIM IDENTIFIER EQUALITY (`normalize` on both sides),
  ## because every other lane that handles an environment name already
  ## does. `l5EnvironmentEmission` refuses a second `environment Dev:`
  ## beside `environment dev:` with `envName.normalize in seenNames`, so
  ## the DSL has already decided those are ONE name; and
  ## `canonicalEnvironmentSelection` normalizes, so `REPRO_ENVIRONMENT=Dev`
  ## and `=dev` are ONE lowered-graph cache entry. A verbatim lookup here
  ## disagreed with both: `Dev` was refused as an environment the package
  ## does not declare, under a cache key that says it is the same build
  ## as `dev`. Two lanes that disagree about which selections are equal
  ## is §6.4's hazard, so there is one rule.
  let wanted = environmentName.normalize
  for def in registeredEnvironments(packageName):
    if def.name.normalize == wanted:
      return def
  DslEnvironmentDef()

proc environmentOwnedConfigKeys*(packageName: string): seq[string] =
  ## Every configurable key SOME environment of `packageName` binds,
  ## de-duplicated, in first-binding order.
  ##
  ## This is the set §6.6's right column names -- "Bind any configurable
  ## the environment owns" -- and it is DERIVED rather than declared: a
  ## configurable becomes environment-owned by being bound in an
  ## environment, so there is no second place for the ownership to
  ## disagree with the bindings.
  for def in registeredEnvironments(packageName):
    for binding in def.bindings:
      if binding.key notin result:
        result.add(binding.key)

proc environmentBindingSite*(packageName, key: string): string =
  ## `"<environment> (<file>:<line>)"` for the FIRST environment that
  ## binds `key`, or "" when none does. The consumer-side refusal quotes
  ## it so the author can go and read the binding that owns the value.
  for def in registeredEnvironments(packageName):
    for binding in def.bindings:
      if binding.key == key:
        return def.name & " (" & binding.sourceFile & ":" &
          $binding.sourceLine & ")"
  ""

proc registerConsumerInstanceOverride*(def: ConsumerInstanceOverrideDef) =
  ## Record one `instanceOverrides <package>.<service>:` block (§6.6).
  dslPortConsumerOverrides.add(def)

proc registeredConsumerInstanceOverrides*(consumerPackage: string):
    seq[ConsumerInstanceOverrideDef] =
  for def in dslPortConsumerOverrides:
    if def.consumerPackage == consumerPackage:
      result.add(def)

proc consumerInstanceOverride*(consumerPackage, targetPackage,
                               targetService: string):
    ConsumerInstanceOverrideDef =
  ## The override this consumer declared for that service, or a zero
  ## record whose `targetService` is empty.
  for def in dslPortConsumerOverrides:
    if def.consumerPackage == consumerPackage and
        def.targetPackage == targetPackage and
        def.targetService == targetService:
      return def
  ConsumerInstanceOverrideDef()

proc bindEnvironmentConfigurable*[T](packageName, environmentName,
                                     key: string; value: T) =
  ## Contribute ONE environment binding into the EXISTING override lane.
  ##
  ## `packageName` and `environmentName` are carried for the diagnostic
  ## and are not part of the key: §6 binds a configurable that already
  ## exists, so the key is the one `recordConfigDefault` registered and
  ## not a per-environment variant of it. Two environments do not hold
  ## two values at once -- ONE is selected per invocation (§6.4), and
  ## `applySelectedEnvironment` applies that one.
  ##
  ## The call delegates to `setConfigurable`, which is `prOverride` in
  ## `Configurable-System.md`'s ladder as this port implements it: the
  ## one table `readConfigurable` consults BEFORE the registered
  ## default. That is D-SS6's declared position (`epOverride`), and the
  ## reason this proc introduces no merge rule, no second table and no
  ## new staging of its own -- §6.1's "needs no new staging, no new
  ## merge rules and no new precedence model" is a constraint on this
  ## body, and the body satisfies it by calling nothing that L5 added.
  ##
  ## `epOverride` IS A RECORDED LABEL HERE, NOT AN ORDERING THIS PORT CAN
  ## ENFORCE, and saying so is the honest version of the paragraph above.
  ## `setConfigurableRaw` writes `dslPortOverrides[key] = value` after a
  ## kind check and compares no priority, and `readConfigurable` consults
  ## that one table before the defaults table. So an environment does beat
  ## a registered DEFAULT -- there are two tables and the override one
  ## wins -- and against any other contributor it is LAST-WRITE-WINS,
  ## whatever rung either claims. A later `epForce` does not outrank an
  ## `epOverride` and an earlier one is not protected from it. D-SS6's
  ## entry in the milestone file carries the measurement and names what a
  ## real ladder would need (a per-rung table, nobody's milestone yet);
  ## `EnvironmentBindingDef.precedence` is provenance for whoever builds
  ## it.
  ##
  ## WHY THE UNKNOWN-KEY CASE RE-RAISES WITH §6's SENTENCE RATHER THAN
  ## CHECKING FIRST. `setConfigurable` already refuses an unregistered
  ## key, and its message is about `config:` blocks in general. The
  ## author here wrote an environment binding, so the sentence that
  ## helps is §6's own ordering rule. Catching rather than pre-checking
  ## keeps ONE registration test (`setConfigurableRaw`'s) rather than
  ## two that can disagree.
  try:
    setConfigurable(key, value)
  except EDslPortMissingKey:
    raise newException(EDslPortMissingKey,
      "environment `" & environmentName & "` of package `" & packageName &
      "` binds `" & key & "`, which no `config:` block registered. " &
      "Shared-Development-Services.md §6: \"The service or activity " &
      "declares its configurables; an environment binds them\" -- so the " &
      "declaration has to exist first.")

template environmentBoundValue*(key: string; declared: untyped): untyped =
  ## The value an activity `config:` key has after the selected
  ## environment has contributed, or the author's declared default when
  ## it has not.
  ##
  ## This is what L2's generated activity entry point uses as the
  ## PARAMETER DEFAULT for each `config:` key, and the whole of what
  ## makes §6's own example work:
  ##
  ##     activity sso(pg: ManagedPostgres):
  ##       config:
  ##         externalDomain: string
  ##     environment dev:
  ##       sso.externalDomain = "login.metacraft-labs.test"
  ##
  ## A parameter default is evaluated at CALL time, and the `enable`
  ## call that invokes the entry point runs long after module init --
  ## which is where `applySelectedEnvironment` ran. So the read sees the
  ## binding with no new staging and no explicit ordering: the existing
  ## Nim evaluation order already puts the contribution before the read.
  ##
  ## An `enable` override that passes the argument EXPLICITLY still
  ## wins, because it supplies the argument and the default is then not
  ## evaluated at all. That is the correct precedence for a SAME-PACKAGE
  ## `enable` (the owner overriding its own environment), and it is not
  ## a consumer-side bind: §6.6's refusal is enforced at the binding
  ## site, in the consumer's own compilation, and is not a function of
  ## this read.
  ##
  ## THIS TEMPLATE IS FOR A KEY THAT HAS A DEFAULT. A key declared with
  ## NO default is a REQUIRED configurable and its parameter default is
  ## `requiredConfigurableValue` instead -- there is no `declared`
  ## expression to fall back to, which is the whole difference.
  ##
  ## `when compiles(...)` rather than an unconditional read: the port's
  ## configurable lane carries bool / int / string / float / enum /
  ## seq[enum], and an activity may legitimately declare a `config:` key
  ## of an object type. For such a key the declared default is used
  ## directly, and nothing is silently lost BECAUSE THE WALKER REFUSES
  ## THE BINDING AT THE AUTHOR'S OWN LINE -- `macros_b.nim`'s
  ## `l5ParseEnvironmentBody` refuses a target whose type the
  ## configurable lane does not carry, by name.
  ##
  ## AN EARLIER REVISION OF THIS COMMENT ALSO CLAIMED A REFUSAL FOR A
  ## TARGET DECLARED WITH NO DEFAULT. There was one for a while, and it
  ## is deliberately gone: such a key is REQUIRED, not slotless, and
  ## refusing a binding to it made §6's own example illegal. The two
  ## refusals that replaced it are
  ## `l5RefuseUnsatisfiableRequiredKeys` (expansion) and
  ## `requiredConfigurableValue` (resolution).
  when compiles(readConfigurable[typeof(declared)](key, declared)):
    readConfigurable[typeof(declared)](key, declared)
  else:
    declared

proc selectedEnvironmentName*(): string =
  ## The environment selected for this invocation, or "" when none is.
  ##
  ## "" is NOT a default environment: it means no environment was
  ## selected, and the configurables keep their declared defaults. §6
  ## gives an environment no ground state to fall back to, and inventing
  ## one here would pick a hostname for an author who picked none.
  getEnv(ReproEnvironmentEnvVar, "").strip()

proc canonicalEnvironmentSelection*(): string =
  ## The canonical form of the selected environment, for the cache keys.
  ##
  ## §6.4's requirement in one proc: `repro_cli_support` folds this into
  ## `loweredGraphCacheKey` AND gives `providerGraphStoreRoot` its own
  ## subdirectory per value, which is exactly what
  ## `canonicalVariantAssignments` already does for `REPRO_VARIANTS`.
  ## Trimmed and lowercased so `dev`, `Dev` and ` dev ` are one cache
  ## entry rather than three; empty when nothing is selected, so the key
  ## is byte-identical to the pre-L5 one for every build that selects no
  ## environment.
  selectedEnvironmentName().normalize

proc requiredConfigurableValue*[T](packageName, key,
                                   qualifier, name: string): T =
  ## The value of a REQUIRED `config:` key, or the RESOLUTION-TIME
  ## refusal (Shared-Development-Services L5, §6).
  ##
  ## This is what L2's generated activity entry point uses as the
  ## PARAMETER DEFAULT for a `config:` key declared with no default, the
  ## way `environmentBoundValue` is used for one that has a default. A
  ## parameter default is evaluated at CALL time, so an `enable
  ## <activity>(<name> = ...)` that passes the argument explicitly never
  ## evaluates this at all -- which is the second of §6's two routes
  ## doing its job without this proc being involved.
  ##
  ## WHY THERE ARE TWO REFUSALS AND WHAT THIS ONE MEANS. The macro
  ## refuses, at expansion, a required key that NO declared environment
  ## binds and NO `enable` site supplies: that one means "this can never
  ## work", and it has to be the macro's because a check that fired only
  ## when a particular environment was SELECTED would leave the defect
  ## silently inert for every other build. This one means "this
  ## configuration does not work": the key IS bindable -- some
  ## environment of this package binds it -- and the environment
  ## actually selected does not. The two are deliberately distinguishable
  ## in their text.
  ##
  ## The message names the key, the selected environment, BOTH routes,
  ## and the environments that do bind the key, because "bind it in an
  ## environment" is not actionable when the author's real mistake is
  ## having selected the wrong one of three.
  if not configurableIsSatisfied(key):
    let selected = selectedEnvironmentName()
    var binders: seq[string] = @[]
    for def in registeredEnvironments(packageName):
      for binding in def.bindings:
        if binding.key == key and def.name notin binders:
          binders.add(def.name)
    let selectionText =
      if selected.len == 0:
        "NO environment is selected (`" & ReproEnvironmentEnvVar &
          "` is unset)"
      else:
        "the selected environment `" & selected & "` does not bind it"
    let binderText =
      if binders.len == 0:
        "No environment of package `" & packageName & "` binds it."
      else:
        "Environments of package `" & packageName &
          "` that DO bind it: " & binders.join(", ") & "."
    raise newException(EDslPortUnsatisfiedRequired,
      "required `config:` key `" & qualifier & "." & name &
      "` of package `" & packageName & "` IS UNSATISFIED: it is " &
      "declared without a default, which makes it REQUIRED -- the slot " &
      "exists and has no seed -- " & selectionText & ", and the " &
      "`enable " & qualifier & "(...)` site did not pass it. " &
      binderText & " Shared-Development-Services.md §6: \"the service " &
      "or activity declares its configurables; an environment binds " &
      "them\" -- so satisfy it either by binding it in the selected " &
      "environment (`environment <name>: " & qualifier & "." & name &
      " = <value>`) or by passing it at the enable site (`enable " &
      qualifier & "(" & name & " = <value>)`).")
  when compiles(readConfigurable[T](key)):
    readConfigurable[T](key)
  else:
    # `seq[<enum>]`, which has no key-only `readConfigurable` overload.
    # The fallback can never be returned here: the satisfaction check
    # above has already established that an override row exists.
    readConfigurable(key, default(T))

proc applyEnvironment*(packageName, environmentName: string) =
  ## Apply ONE named environment's bindings for `packageName`.
  ##
  ## Separated from `applySelectedEnvironment` so the selection and the
  ## application are two operations rather than one. L7's resolver
  ## needs that split -- it resolves `(identity, scope, environment)`
  ## per consuming edge and cannot re-read the process environment per
  ## edge -- and a test needs it to exercise two environments without
  ## two processes. Raises `EDslPortMissingKey` when the package
  ## declares no environment by that name, naming the ones it does.
  let def = registeredEnvironment(packageName, environmentName)
  if def.name.len == 0:
    let declared = registeredEnvironmentNames(packageName)
    raise newException(EDslPortMissingKey,
      "package `" & packageName & "` declares no environment named `" &
      environmentName & "`; it declares " &
      (if declared.len == 0: "none at all"
       else: "`" & declared.join("`, `") & "`") & ".")
  # KEYED ON `def.name`, NOT ON `environmentName`. `registeredEnvironment`
  # above matches under Nim identifier equality while this table is
  # keyed on the DECLARED spelling, so looking the applier up by the
  # caller's spelling would find the environment and then no applier --
  # and `applier == nil` is silent. The def that was found names the key
  # that exists.
  let applier = dslPortEnvironmentAppliers.getOrDefault(
    dslPortEnvironmentKey(def.packageName, def.name), nil)
  if applier == nil:
    return
  # ALL-OR-NOTHING, and this is a behaviour decision rather than
  # hygiene. An environment is "a named set of bindings" (§6); a set
  # half of which is in force is not one of the two outcomes §6
  # describes. Before this, a binding that raised partway -- an
  # unregistered key, a type mismatch -- left every PRECEDING binding
  # applied and then propagated the exception, so a recipe that refused
  # to start also carried a configuration no environment declares. The
  # author now sees the same error and the configurables are back where
  # the declared defaults put them.
  #
  # The alternative was to validate every binding before applying any.
  # It is rejected because a binding's value is the author's EXPRESSION
  # and validating it means evaluating it, so a "validation" pass is the
  # apply pass with the write suppressed -- two code paths that can
  # disagree about what is bindable, which is the defect family this
  # milestone keeps finding. Snapshot-and-restore needs one path.
  #
  # SHARED-DEVELOPMENT-SERVICES L8 ADDED A SECOND REGISTRY, SO THE
  # SNAPSHOT HAD TO GROW WITH IT. A binding to a CONTRIBUTION POINT no
  # longer writes `dslPortOverrides`; it writes a `coReplace` row into
  # `dslPortContributions` (see `setConfigurableRaw`). Snapshotting only
  # the override table would therefore have restored the scalar half of
  # a half-applied environment and LEFT the collection half in force --
  # exactly the partial apply the paragraph above exists to prevent,
  # re-introduced one registry over. Both are snapshotted and both are
  # restored, in one `try`.
  let snapshot = configurableOverrideSnapshot()
  let contributions = contributionSnapshot()
  try:
    applier()
  except CatchableError:
    restoreConfigurableOverrides(snapshot)
    restoreContributions(contributions)
    raise

proc applySelectedEnvironment*(packageName: string): string =
  ## Apply the SELECTED environment's bindings for `packageName`, and
  ## return the name applied ("" when none was).
  ##
  ## Raises `EDslPortMissingKey` when an environment is selected that
  ## this package does not declare, naming the ones it does. Silence
  ## there would be the §6.4 failure in its other form: a developer who
  ## selected `production` and got development bindings, with nothing
  ## said.
  let selected = selectedEnvironmentName()
  if selected.len == 0:
    return ""
  let def = registeredEnvironment(packageName, selected)
  if def.name.len == 0:
    let declared = registeredEnvironmentNames(packageName)
    raise newException(EDslPortMissingKey,
      "environment `" & selected & "` is selected (" &
      ReproEnvironmentEnvVar & ") and package `" & packageName &
      "` declares no environment by that name; it declares " &
      (if declared.len == 0: "none at all"
       else: "`" & declared.join("`, `") & "`") & ".")
  applyEnvironment(packageName, def.name)
  def.name
