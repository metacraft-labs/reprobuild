## Spec-Implementation M1 — Solver-participating Configurables (variants).
##
## A *variant* is an ordinary ``Configurable[T]`` whose underlying
## ``ConfigurableNode`` carries the ``solverParticipating`` tag. See
## ``Configurable-System.md`` §"Solver-Participating Configurables
## (Variants)" for the design rationale and §"Why Not a Parallel
## Primitive" for the explicit choice not to introduce a separate type.
##
## M1 lifts the **declaration surface** (``variant: T = default`` and
## the ``@variant`` doc directive), the **runtime data-model tag**
## (``solverParticipating`` on the node), the **``.value`` accessor**
## (returns ``T`` once the surrounding ``evalConfig`` has finalized;
## raises ``EVariantNotResolved`` before that), and the **CLI hook**
## (``--variant name=value`` registers a ``prSet`` contribution before
## evaluation begins). NO solver integration yet — variants resolve at
## ``evalConfig`` finalize time using the same priority lattice
## (``prDefault < prSet < prOverride < prForce``) as every other
## ``Configurable[T]``.
##
## The variant identity store is a thread-local ``ConfigContext`` that
## the ``package`` macro opens lazily on the first variant declaration
## and finalizes once the ``config:`` block completes. The
## ``.value`` accessor consults the context's state; reading before
## finalize raises the structured ``EVariantNotResolved`` error rather
## than returning the default value silently.

import std/[os, strutils]

import ./types
import ./context
import ./api

# ---------------------------------------------------------------------------
# Process-wide ambient variant context
# ---------------------------------------------------------------------------
#
# The DSL's existing Configurable surface lives inside an explicit
# ``evalConfig:`` block. Variants declared via the ``package`` macro's
# ``config:`` section need to be reachable from the package's ``uses:``
# / ``build:`` blocks at module load time, without requiring authors
# to wrap the package in an ``evalConfig:``. We therefore maintain a
# thread-local *ambient* variant context that is auto-created on the
# first variant declaration and is explicitly finalised by the
# ``package`` macro's emitted code once the ``config:`` block ends.

type
  VariantCliContribution* = object
    name*: string
    value*: string

const VariantEnvVar* = "REPRO_VARIANTS"
  ## Environment variable carrying ``name=value`` pairs (comma-
  ## separated) propagated from the CLI's ``--variant`` flag into the
  ## provider / build process. Format mirrors typical key/value env
  ## conventions; values may contain ``=`` after the first separator.
  ## Empty pairs are skipped.

var ambientVariantContext {.threadvar.}: ConfigContext
var pendingCliOverrides {.threadvar.}: seq[VariantCliContribution]
var loadedEnvOverrides {.threadvar.}: bool

proc parseEnvOverrides() =
  if loadedEnvOverrides:
    return
  loadedEnvOverrides = true
  let raw = getEnv(VariantEnvVar)
  if raw.len == 0:
    return
  for entry in raw.split(','):
    let stripped = entry.strip()
    if stripped.len == 0: continue
    let eqIdx = stripped.find('=')
    if eqIdx <= 0: continue
    let name = stripped[0 ..< eqIdx].strip()
    let value = stripped[eqIdx + 1 .. ^1]
    if name.len == 0: continue
    pendingCliOverrides.add(VariantCliContribution(name: name, value: value))

proc ensureAmbientVariantContext*(): ConfigContext =
  ## Return the ambient (auto-managed) variant context, creating a
  ## fresh one if needed. Re-creates the context after
  ## ``resetVariantState`` even when the previous context was
  ## finalized.
  parseEnvOverrides()
  if ambientVariantContext.isNil or
      ambientVariantContext.state == ccsFinalized:
    ambientVariantContext = newConfigContext()
    pushContext(ambientVariantContext)
  result = ambientVariantContext

proc currentVariantContext*(): ConfigContext =
  ## Return the ambient variant context without creating one. Returns
  ## ``nil`` when no variant has been declared yet.
  ambientVariantContext

proc resetVariantState*() =
  ## Reset the ambient variant context AND the pending CLI overrides.
  ## Test helpers call this between scenarios so registry entries don't
  ## leak across cases.
  if not ambientVariantContext.isNil and
      tryCurrentContext() == ambientVariantContext:
    discard popContext()
  ambientVariantContext = nil
  pendingCliOverrides.setLen(0)
  loadedEnvOverrides = false

# ---------------------------------------------------------------------------
# CLI overrides
# ---------------------------------------------------------------------------

proc addVariantCliOverride*(name, value: string) =
  ## Register a pending ``--variant name=value`` contribution. Applied
  ## as a ``prSet`` against the variant when ``declareVariant`` runs.
  ## The CLI dispatches this from ``runBuildCommand`` /
  ## ``runReproTestCommand`` before invoking the user's build proc.
  pendingCliOverrides.add(VariantCliContribution(name: name, value: value))

proc pendingVariantCliOverrides*(): seq[VariantCliContribution] =
  pendingCliOverrides

proc applyCliContributionFor[T](ctx: ConfigContext;
                                node: ConfigurableNode; name: string) =
  ## Walk the pending CLI overrides and apply any that target ``name``.
  ## The match is by scope-derived name (the variant's declaration
  ## ident). Values are parsed from strings into ``T`` via Nim's
  ## standard parsing surface.
  for entry in pendingCliOverrides:
    if entry.name != name:
      continue
    let site = SourceSite(file: "<cli>", line: 0, column: 0,
      kind: ckSet)
    when T is bool:
      let lower = entry.value.toLowerAscii()
      let v =
        if lower in ["true", "1", "yes", "on"]: true
        elif lower in ["false", "0", "no", "off"]: false
        else:
          raise newException(EConfigurable,
            "cannot parse --variant " & entry.name & "=" & entry.value &
              " as bool")
      ctx.addContribution(node, prSet, cvBool(v), site)
    elif T is SomeInteger:
      try:
        let v = parseInt(entry.value)
        ctx.addContribution(node, prSet, cvInt(v), site)
      except ValueError:
        raise newException(EConfigurable,
          "cannot parse --variant " & entry.name & "=" & entry.value &
            " as int")
    elif T is string:
      ctx.addContribution(node, prSet, cvString(entry.value), site)
    else:
      raise newException(EConfigurable,
        "unsupported variant value type for --variant " & entry.name)

# ---------------------------------------------------------------------------
# Declaration
# ---------------------------------------------------------------------------

proc declareVariantImpl*[T](defaultValue: T;
                            scopeName, description, explicitId: string;
                            descriptionFile: string;
                            descriptionLine, descriptionColumn: int;
                            site: SourceSite): Configurable[T] =
  ## Allocate a variant in the ambient variant context. Sets the
  ## ``solverParticipating`` tag on the underlying node and applies any
  ## matching ``--variant name=value`` CLI overrides as ``prSet``
  ## contributions before returning the handle.
  ##
  ## The accessor surface (``.value``) plus the priority lattice
  ## (``prDefault`` from the declaration, ``prSet`` from the CLI,
  ## ``prOverride`` from workspace ``Configurable.override``, ``prForce``
  ## from explicit ``force`` calls) is identical to every other
  ## ``Configurable[T]``. The tag exists for the solver stage that
  ## lands in M2.
  let ctx = ensureAmbientVariantContext()
  let handle = allocConfigurable[T](ctx, scopeName, defaultValue, site,
    description = description,
    descriptionFile = descriptionFile,
    descriptionLine = descriptionLine,
    descriptionColumn = descriptionColumn,
    explicitId = explicitId)
  let node = ctx.nodeOf(handle.id)
  node.solverParticipating = true
  applyCliContributionFor[T](ctx, node, scopeName)
  handle

template declareVariant*[T](defaultValue: T;
                            scopeName, description, explicitId: string;
                            descriptionFile: string;
                            descriptionLine, descriptionColumn: int;
                            site: SourceSite): Configurable[T] =
  declareVariantImpl[T](defaultValue, scopeName, description, explicitId,
    descriptionFile, descriptionLine, descriptionColumn, site)

proc variantImpl*[T](defaultValue: T; scopeName: string;
                     site: SourceSite): Configurable[T] =
  declareVariantImpl[T](defaultValue, scopeName, "", "", "", 0, 0, site)

template variant*[T](defaultValue: T): Configurable[T] =
  let site {.gensym.} = captureSite(ckDefault)
  variantImpl[T](defaultValue, "", site)

# ---------------------------------------------------------------------------
# Finalisation + the ``.value`` accessor
# ---------------------------------------------------------------------------

proc finalizeVariants*() =
  ## Finalize the ambient variant context. Authors do NOT call this
  ## directly — the ``package`` macro emits a single call at the end of
  ## its lowered ``config:`` block. After this proc returns, every
  ## declared variant's ``.value`` returns the resolved ``T``.
  ##
  ## Safe to call when no ambient context exists (no variants declared)
  ## — the call is a no-op in that case.
  if ambientVariantContext.isNil: return
  if ambientVariantContext.state == ccsFinalized: return
  let ctx = ambientVariantContext
  ctx.finalize()
  # Pop the ambient context off the thread-local stack so subsequent
  # explicit ``evalConfig:`` blocks see a clean slate. Idempotent: if
  # another context was pushed on top after ours we leave it alone.
  if tryCurrentContext() == ctx:
    discard popContext()

proc variantNodeOf[T](c: Configurable[T]): ConfigurableNode =
  let ctx = currentVariantContext()
  if ctx.isNil:
    raise newException(ENoContext,
      "no ambient variant context — declare the variant via " &
      "`variant: T = default` inside a package `config:` block")
  ctx.nodeOf(c.id)

proc value*[T](c: Configurable[T]): T =
  ## Return the resolved variant value. Raises ``EVariantNotResolved``
  ## when the ambient variant context has not yet been finalised; the
  ## diagnostic names the violated phase ordering per
  ## ``Configurable-System.md`` §"Static-Value Contract".
  ##
  ## When the configurable is NOT a variant (no ``solverParticipating``
  ## tag) the call raises ``ENotAVariant`` so authors do not silently
  ## blend the variant-specific accessor onto a plain Configurable.
  let ctx = currentVariantContext()
  if ctx.isNil:
    raise newException(EVariantNotResolved,
      "variant.value read before any variant context exists — " &
      "ensure the package's `config:` block has been evaluated " &
      "before `build:` reads the variant")
  if ctx.state != ccsFinalized:
    raise newException(EVariantNotResolved,
      "variant.value read before finalize — recipe code at " &
      "graph emission time (stage 4) requires the variant context " &
      "to have completed `evalConfig` finalisation (stage 2/3)")
  let node = ctx.nodeOf(c.id)
  if not node.solverParticipating:
    raise newException(ENotAVariant,
      "Configurable '" & node.scopeDerivedName & "' is not a variant; " &
      "use `read(ctx, c)` for plain Configurables")
  unwrapValue[T](node.resolvedVal)

proc isSolverParticipating*[T](c: Configurable[T]): bool =
  ## Whether the underlying node carries the variant tag. Test helpers
  ## consume this to verify the declaration surface lands the tag
  ## correctly.
  let ctx = currentVariantContext()
  if ctx.isNil: return false
  let node = ctx.nodeOf(c.id)
  node.solverParticipating

proc variantContributions*[T](c: Configurable[T]): seq[Contribution] =
  ## Expose the variant's contribution list for test assertions. The
  ## list preserves declaration order; callers should inspect priority
  ## bands rather than positional offsets.
  let ctx = currentVariantContext()
  if ctx.isNil: return @[]
  ctx.nodeOf(c.id).contributions

proc variantsFinalized*(): bool =
  ## True iff the ambient variant context has been finalised. Used by
  ## diagnostic helpers and by tests asserting the finalize lifecycle.
  let ctx = currentVariantContext()
  not ctx.isNil and ctx.state == ccsFinalized
