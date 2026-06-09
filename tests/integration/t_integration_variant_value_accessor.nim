## Spec-Implementation M1 — variant ``.value`` accessor semantics.
##
## Asserts the phase-ordering contract from
## ``Configurable-System.md`` §"Static-Value Contract":
##
##   * After finalize, ``variant.value`` returns the concrete ``T``.
##   * Before finalize, ``variant.value`` raises ``EVariantNotResolved``
##     with a diagnostic naming the violated phase ordering.
##
## A successful read of ``.value`` on a non-variant raises
## ``ENotAVariant`` so authors do not accidentally blend the variant
## accessor surface onto a plain Configurable.

import std/[strutils, unittest]

import repro_dsl_stdlib/configurables

template makeBoolVariant(): Configurable[bool] =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[bool](
    defaultValue = true,
    scopeName = "flag",
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

suite "Spec-Implementation M1: variant.value accessor":

  setup:
    resetVariantState()

  test "value read before finalize raises EVariantNotResolved":
    let v = makeBoolVariant()
    expect EVariantNotResolved:
      discard v.value

  test "value read after finalize returns the default":
    let v = makeBoolVariant()
    finalizeVariants()
    check v.value == true

  test "value diagnostic names the phase-ordering violation":
    let v = makeBoolVariant()
    var msg = ""
    try:
      discard v.value
    except EVariantNotResolved as err:
      msg = err.msg
    check msg.len > 0
    # Diagnostic should reference the finalization concept so the
    # author can locate the violated invariant.
    check ("finalize" in msg) or ("stage" in msg)

  test "value on a plain Configurable raises ENotAVariant":
    # A plain Configurable lives in an explicit evalConfig context,
    # NOT the ambient variant context. The variant accessor refuses
    # to coerce.
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    # Manually allocate a non-variant Configurable inside the ambient
    # context, simulating the case where API misuse mixes the two
    # surfaces. The handle has the variant context's id but missing
    # tag.
    let ctx = ensureAmbientVariantContext()
    let handle = allocConfigurable[bool](ctx, "plain", false, site,
      description = "")
    let node = ctx.nodeOf(handle.id)
    check not node.solverParticipating
    finalizeVariants()
    expect ENotAVariant:
      discard handle.value
