## Public construction and access surface for the Configurable system.
##
## The big-picture is:
##
## - `configurable v` creates a `Configurable[T]` with default value `v`
##   in the current context. `configurable c` where `c` is already a
##   `Configurable[T]` is idempotent and returns `c` unchanged.
## - `c.override v`, `c := v`, `c.force v` record contributions.
## - `c.val` returns the staged proxy (`ConfigurableVal[T]`). The dot
##   operator on the proxy is overloaded by a macro to produce a new
##   `Configurable[F]` for a named field.
## - `read(ctx, c)` (and `c.read(ctx)`) returns the raw `T` from a
##   finalized context.
## - Operators (`+`, `&`, `$`, ...) compose configurables.
## - `mapField` and `mapClosure` are the two staged-derivation
##   primitives the dot macro lowers to.

import std/[macros]

import ./types
import ./context

# ---------------------------------------------------------------------------
# Internal helpers per value kind
# ---------------------------------------------------------------------------

proc valueKindOf*(t: typedesc): ConfigurableValueKind =
  when t is bool: cvkBool
  elif t is SomeInteger: cvkInt
  elif t is string: cvkString
  elif t is seq[byte]: cvkBytes
  else: cvkAny

proc unwrapBool*(v: ConfigurableValue): bool =
  if v.kind != cvkBool:
    raise newException(EConfigurable,
      "expected bool configurable, got " & $v.kind)
  v.boolVal

proc unwrapInt*(v: ConfigurableValue): int =
  if v.kind != cvkInt:
    raise newException(EConfigurable,
      "expected int configurable, got " & $v.kind)
  int(v.intVal)

proc unwrapString*(v: ConfigurableValue): string =
  if v.kind != cvkString:
    raise newException(EConfigurable,
      "expected string configurable, got " & $v.kind)
  v.strVal

proc unwrapBytes*(v: ConfigurableValue): seq[byte] =
  if v.kind != cvkBytes:
    raise newException(EConfigurable,
      "expected bytes configurable, got " & $v.kind)
  v.bytesVal

type
  TypedPayload*[T] = ref object of AnyPayload
    payload*: T

proc wrapValue*[T](x: T): ConfigurableValue =
  when T is bool: cvBool(x)
  elif T is SomeInteger: cvInt(x)
  elif T is string: cvString(x)
  elif T is seq[byte]: cvBytes(x)
  else:
    let payload = TypedPayload[T](payload: x)
    cvAny(payload)

proc unwrapValue*[T](v: ConfigurableValue): T =
  when T is bool: unwrapBool(v)
  elif T is int: unwrapInt(v)
  elif T is int64: int64(unwrapInt(v))
  elif T is uint: uint(unwrapInt(v))
  elif T is string: unwrapString(v)
  elif T is seq[byte]: unwrapBytes(v)
  else:
    if v.kind != cvkAny:
      raise newException(EConfigurable,
        "expected object configurable, got " & $v.kind)
    let tp = TypedPayload[T](v.anyVal)
    if tp.isNil:
      raise newException(EConfigurable,
        "configurable value cannot be cast to the requested type")
    tp.payload

# ---------------------------------------------------------------------------
# Site capture
# ---------------------------------------------------------------------------

template captureSite*(contribKind: ContributionKind): SourceSite =
  let info {.gensym.} = instantiationInfo(fullPaths = true)
  newSourceSite(info.filename, info.line, info.column, contribKind)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc allocConfigurable*[T](ctx: ConfigContext;
                           scopeName: string;
                           defaultValue: T;
                           site: SourceSite;
                           description = "";
                           descriptionFile = "";
                           descriptionLine = 0;
                           descriptionColumn = 0;
                           explicitId = ""): Configurable[T] =
  let node = ctx.allocNode(scopeName, valueKindOf(T))
  node.description = description
  node.descriptionFile = descriptionFile
  node.descriptionLine = descriptionLine
  node.descriptionColumn = descriptionColumn
  if explicitId.len > 0:
    ctx.registerExplicitId(node, explicitId, site)
  ctx.addContribution(node, prDefault, wrapValue(defaultValue), site)
  discard ctx.adoptFromPersisted(node, explicitId, scopeName)
  Configurable[T](id: node.id)

# Idempotent constructor — passes a Configurable[T] through unchanged.
proc configurable*[T](c: Configurable[T]): Configurable[T] {.inline.} = c
proc configurable*[T](c: ConfigurableVal[T]): Configurable[T] {.inline.} =
  c.parent

proc configurableImpl*[T](defaultValue: T;
                          scopeName: string;
                          site: SourceSite;
                          description = "";
                          explicitId = ""): Configurable[T] =
  let ctx = currentContext()
  allocConfigurable[T](ctx, scopeName, defaultValue, site,
    description = description, explicitId = explicitId)

template configurable*[T](defaultValue: T): Configurable[T] =
  let site {.gensym.} = captureSite(ckDefault)
  configurableImpl[T](defaultValue, "", site)

template configurable*[T](defaultValue: T;
                          description: string): Configurable[T] =
  let site {.gensym.} = captureSite(ckDefault)
  configurableImpl[T](defaultValue, "", site, description = description)

# Form for fully-explicit declaration: name (scope-derived or @id),
# default, description, and explicit id. Used by macro-expanded
# block configurable: declarations.
proc declareConfigurable*[T](defaultValue: T;
                             scopeName, description, explicitId: string;
                             descriptionFile: string;
                             descriptionLine, descriptionColumn: int;
                             site: SourceSite): Configurable[T] =
  let ctx = currentContext()
  allocConfigurable[T](ctx, scopeName, defaultValue, site,
    description = description,
    descriptionFile = descriptionFile,
    descriptionLine = descriptionLine,
    descriptionColumn = descriptionColumn,
    explicitId = explicitId)

# ---------------------------------------------------------------------------
# Contribution helpers
# ---------------------------------------------------------------------------

proc setImpl[T](c: Configurable[T]; value: T; site: SourceSite) =
  let ctx = currentContext()
  ctx.addContribution(ctx.nodeOf(c.id), prSet, wrapValue(value), site)

template set*[T](c: Configurable[T]; value: T) =
  setImpl(c, value, captureSite(ckSet))

template `:=`*[T](c: Configurable[T]; value: T) =
  setImpl(c, value, captureSite(ckSet))

proc overrideImpl[T](c: Configurable[T]; value: T; site: SourceSite) =
  let ctx = currentContext()
  ctx.addContribution(ctx.nodeOf(c.id), prOverride, wrapValue(value), site)

template override*[T](c: Configurable[T]; value: T) =
  overrideImpl(c, value, captureSite(ckOverride))

proc forceImpl[T](c: Configurable[T]; value: T; site: SourceSite) =
  let ctx = currentContext()
  ctx.addContribution(ctx.nodeOf(c.id), prForce, wrapValue(value), site)

template force*[T](c: Configurable[T]; value: T) =
  forceImpl(c, value, captureSite(ckForce))

proc contributeImpl[T](c: Configurable[T]; priority: ContributionPriority;
                       value: T; site: SourceSite) =
  let ctx = currentContext()
  ctx.addContribution(ctx.nodeOf(c.id), priority, wrapValue(value), site)

template contribute*[T](c: Configurable[T];
                        priority: ContributionPriority; value: T) =
  let kind = case priority
             of prDefault: ckDefault
             of prSet: ckSet
             of prOverride: ckOverride
             of prForce: ckForce
  let site {.gensym.} = captureSite(kind)
  contributeImpl(c, priority, value, site)

proc contributions*[T](ctx: ConfigContext;
                       c: Configurable[T]): seq[Contribution] =
  ctx.nodeOf(c.id).contributions

proc contributions*[T](c: Configurable[T]): seq[Contribution] =
  currentContext().contributions(c)

proc description*[T](ctx: ConfigContext; c: Configurable[T]): string =
  ctx.nodeOf(c.id).description

proc description*[T](c: Configurable[T]): string =
  currentContext().description(c)

proc descriptionSite*[T](ctx: ConfigContext;
                         c: Configurable[T]):
                       tuple[file: string; line, column: int] =
  let n = ctx.nodeOf(c.id)
  (n.descriptionFile, n.descriptionLine, n.descriptionColumn)

proc descriptionSite*[T](c: Configurable[T]):
                       tuple[file: string; line, column: int] =
  currentContext().descriptionSite(c)

proc persistentId*[T](ctx: ConfigContext; c: Configurable[T]): string =
  ctx.nodeOf(c.id).explicitId

proc persistentId*[T](c: Configurable[T]): string =
  currentContext().persistentId(c)

proc scopeDerivedName*[T](ctx: ConfigContext;
                          c: Configurable[T]): string =
  ctx.nodeOf(c.id).scopeDerivedName

proc scopeDerivedName*[T](c: Configurable[T]): string =
  currentContext().scopeDerivedName(c)

# ---------------------------------------------------------------------------
# Reading resolved values
# ---------------------------------------------------------------------------

proc read*[T](ctx: ConfigContext; c: Configurable[T]): T =
  ## Return the resolved raw `T` from a finalized context. The
  ## post-finalize counterpart of `.val`.
  unwrapValue[T](ctx.resolvedValueOf(c.id))

proc read*[T](c: Configurable[T]; ctx: ConfigContext): T {.inline.} =
  read(ctx, c)

proc val*[T](c: Configurable[T]): ConfigurableVal[T] {.inline.} =
  ## Return the staged proxy. The dot operator on a `ConfigurableVal[T]`
  ## is macro-overloaded to produce a `Configurable[F]` for any named
  ## field; mutable field assignment is rejected at macro expansion.
  ##
  ## After finalize, prefer `read(ctx, c)` to obtain the raw `T`.
  ConfigurableVal[T](parent: c)

# ---------------------------------------------------------------------------
# mapClosure: the general staged-derivation primitive
# ---------------------------------------------------------------------------

proc mapClosureImpl*[T, R](parent: Configurable[T];
                           name: string;
                           fn: proc(v: T): R): Configurable[R] =
  let ctx = currentContext()
  let parentId = parent.id
  let compute = proc(values: openArray[ConfigurableValue]):
                ConfigurableValue =
    let v = unwrapValue[T](values[0])
    wrapValue(fn(v))
  let node = ctx.allocNode(name, valueKindOf(R))
  node.deps = @[parentId]
  node.compute = compute
  Configurable[R](id: node.id)

template mapClosure*[T, R](parent: Configurable[T];
                           fn: proc(v: T): R): Configurable[R] =
  mapClosureImpl[T, R](parent, "", fn)

# ---------------------------------------------------------------------------
# Idempotence on ConfigurableVal[T]
# ---------------------------------------------------------------------------

proc configurableVal*[T](v: ConfigurableVal[T]): ConfigurableVal[T] {.inline.} =
  v
