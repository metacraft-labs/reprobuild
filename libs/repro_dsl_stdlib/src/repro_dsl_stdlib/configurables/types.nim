## Public types for the Configurable system.
##
## A `Configurable[T]` is a typed deferred value identified by its
## construction site within an `evalConfig` context. The actual
## node state (contributions, dependencies, compute closure, resolved
## value) lives inside the surrounding `ConfigContext`; the handle
## just carries the construction id plus enough information for the
## type system to distinguish concrete value types.
##
## `ConfigurableVal[T]` is the staged-field-access proxy. Before the
## surrounding `evalConfig` finalizes, `c.val` returns a
## `ConfigurableVal[T]` whose dot operator is overloaded to produce
## further `Configurable[F]` values. After finalization, `c.val`
## returns a plain `T`.
##
## All structured exceptions raised by the Configurable system inherit
## from `ConfigurableError`.

import std/[tables]

type
  ConstructionId* = uint64
    ## Dense, in-process construction id. Never persisted. Reset to
    ## zero whenever a new `ConfigContext` is opened.

  ContributionPriority* = enum
    prDefault = 0
    prSet = 1
    prOverride = 2
    prForce = 3

  ContributionKind* = enum
    ckDefault
    ckSet
    ckOverride
    ckForce

  SourceSite* = object
    ## Captured at contribution time. `kind` records WHY the
    ## contribution was made (default, set, override, force); the
    ## file/line/column point at the call site.
    file*: string
    line*: int
    column*: int
    kind*: ContributionKind

  ConfigurableValueKind* = enum
    cvkBool
    cvkInt
    cvkString
    cvkBytes
      ## Opaque blob used for compound values that are not directly
      ## representable as bool/int/string. The graph stores the
      ## stringified form for resolution; the typed `Configurable[T]`
      ## handle is responsible for serialization-on-store and
      ## deserialization-on-read for its `T`.
    cvkAny
      ## In-process-only erased value, used for object-typed
      ## configurables whose Nim representation is not directly
      ## persistable. `cvkAny` values are NEVER written to RBCG;
      ## persistence-bound configurables must use one of the typed
      ## kinds. The `payload` is a `ref object` carrying the runtime
      ## type; the typed `Configurable[T]` knows how to cast it.

  AnyPayload* = ref object of RootObj
    ## Opaque base class for `cvkAny` values. Concrete instances are
    ## generic subclasses defined in `api.nim` (`TypedPayload[T]`).

  ConfigurableValue* = object
    ## Type-erased value carried in a contribution. The
    ## `ConfigurableValueKind` distinguishes the active branch.
    case kind*: ConfigurableValueKind
    of cvkBool: boolVal*: bool
    of cvkInt: intVal*: int64
    of cvkString: strVal*: string
    of cvkBytes: bytesVal*: seq[byte]
    of cvkAny: anyVal*: AnyPayload

  Contribution* = object
    priority*: ContributionPriority
    value*: ConfigurableValue
    site*: SourceSite

  CollectionMergeRule* = enum
    cmrScalarLastWins
    cmrCollectionAppend
    cmrSetUnion
    cmrMapUnion

  ComputeProc* = proc(values: openArray[ConfigurableValue]):
    ConfigurableValue {.closure.}

  ConfigurableNode* = ref object
    id*: ConstructionId
    scopeDerivedName*: string
    explicitId*: string
    description*: string
    descriptionFile*: string
    descriptionLine*: int
    descriptionColumn*: int
    valueKind*: ConfigurableValueKind
    mergeRule*: CollectionMergeRule
    contributions*: seq[Contribution]
    deps*: seq[ConstructionId]
    compute*: ComputeProc
    resolved*: bool
    resolvedVal*: ConfigurableValue
    forceSite*: SourceSite
    hasForce*: bool

  ConfigContextState* = enum
    ccsOpen
    ccsFinalized

  ConfigContext* = ref object
    nodes*: seq[ConfigurableNode]
      ## Indexed by `ConstructionId` (zero-based, dense).
    byScope*: Table[string, ConstructionId]
    byExplicitId*: Table[string, ConstructionId]
    state*: ConfigContextState
    parent*: ConfigContext
      ## Set for child contexts produced by `withOverrides`. Nodes the
      ## child does not know about are read through the parent chain.
    finalizers*: seq[proc() {.closure.}]
    persistedEntries*: Table[string, ConfigurableNode]
      ## Persisted entries loaded from an RBCG envelope but not yet
      ## bound to a current declaration. Keyed by explicit id when
      ## available, otherwise by scope-derived name.
    persistedByScope*: Table[string, string]
      ## scope-derived-name -> the actual table key in
      ## `persistedEntries`. Lets the lookup algorithm reach an entry
      ## by scope-derived name even when the entry is stored under
      ## its explicit id.
    refinalizeStats*: RefinalizeStats

  RefinalizeStats* = object
    ## Diagnostics used by the `withOverrides` gate to verify the
    ## dirty closure was actually pruned.
    visited*: int
    recomputed*: int
    cutoffs*: int

  Configurable*[T] = object
    ## Typed handle to a configurable node. Carries the construction
    ## id plus a phantom type parameter; the actual data lives in the
    ## surrounding `ConfigContext`.
    id*: ConstructionId

  ConfigurableVal*[T] = object
    ## Staged-field-access proxy. During staging, `.field` on a
    ## `ConfigurableVal[T]` is rewritten by the dot macro into a
    ## `mapField` call against the parent configurable. After
    ## finalize, `c.val` returns the raw `T` and ordinary Nim field
    ## access takes over.
    parent*: Configurable[T]

  ConfigurableError* = object of CatchableError
  EConfigurable* = object of ConfigurableError
    ## Catch-all base. Specific kinds inherit and are raised by name.

  ENoContext* = object of ConfigurableError
  EAlreadyFinalized* = object of ConfigurableError
  ENotFinalized* = object of ConfigurableError
  EDuplicateForce* = object of ConfigurableError
  EDuplicateId* = object of ConfigurableError
  EAmbiguousLookup* = object of ConfigurableError
  EUnknownDirective* = object of ConfigurableError
  EFutureDirective* = object of ConfigurableError
  EConfigurableMutation* = object of ConfigurableError
  EUnknownConfigurable* = object of ConfigurableError
  ECorruptEnvelope* = object of ConfigurableError
  ESchemaVersionMismatch* = object of ConfigurableError
    ## Raised when an RBCG envelope's schema version is recognized as
    ## an older or otherwise incompatible version that this build does
    ## not know how to decode. Distinct from `ECorruptEnvelope` so
    ## callers can offer a "regenerate the persisted graph" path
    ## instead of treating it as data corruption.
  EInvalidId* = object of ConfigurableError

proc newSourceSite*(file: string; line, column: int;
                    kind: ContributionKind): SourceSite =
  SourceSite(file: file, line: line, column: column, kind: kind)

proc cvBool*(v: bool): ConfigurableValue =
  ConfigurableValue(kind: cvkBool, boolVal: v)

proc cvInt*(v: SomeInteger): ConfigurableValue =
  ConfigurableValue(kind: cvkInt, intVal: int64(v))

proc cvString*(v: string): ConfigurableValue =
  ConfigurableValue(kind: cvkString, strVal: v)

proc cvBytes*(v: seq[byte]): ConfigurableValue =
  ConfigurableValue(kind: cvkBytes, bytesVal: v)

proc cvAny*(v: AnyPayload): ConfigurableValue =
  ConfigurableValue(kind: cvkAny, anyVal: v)

proc `==`*(a, b: ConfigurableValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of cvkBool: a.boolVal == b.boolVal
  of cvkInt: a.intVal == b.intVal
  of cvkString: a.strVal == b.strVal
  of cvkBytes: a.bytesVal == b.bytesVal
  of cvkAny: a.anyVal == b.anyVal   # reference equality

proc `$`*(v: ConfigurableValue): string =
  case v.kind
  of cvkBool: $v.boolVal
  of cvkInt: $v.intVal
  of cvkString: v.strVal
  of cvkBytes:
    var s = newStringOfCap(v.bytesVal.len * 2 + 2)
    s.add("0x")
    const HEX = "0123456789abcdef"
    for b in v.bytesVal:
      s.add HEX[int(b shr 4) and 0xF]
      s.add HEX[int(b) and 0xF]
    s
  of cvkAny: "<any>"
