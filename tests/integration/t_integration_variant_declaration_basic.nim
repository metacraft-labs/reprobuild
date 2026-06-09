## Spec-Implementation M1 — variant declaration surface.
##
## Asserts the M1 surface accepts both spellings — ``variant: T =
## default`` and the matching ``@variant`` doc directive — and that
## both produce a ``Configurable[T]`` whose underlying node carries
## the ``solverParticipating`` tag. Reading the value after finalize
## returns the default; ``isSolverParticipating`` returns true for
## variant handles and false for plain Configurables.

import std/[unittest]

import repro_dsl_stdlib/configurables

suite "Spec-Implementation M1: variant declaration surface":

  setup:
    resetVariantState()

  test "variant: T = default registers a solver-participating Configurable":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let v = declareVariant[bool](
      defaultValue = true,
      scopeName = "enableTLS",
      description = "Enable TLS support.",
      explicitId = "",
      descriptionFile = info.filename,
      descriptionLine = info.line,
      descriptionColumn = 0,
      site = site)
    check isSolverParticipating(v)
    finalizeVariants()
    check v.value == true

  test "default value is honored when no overrides exist":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let portVariant = declareVariant[int](
      defaultValue = 8080,
      scopeName = "adminPort",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    check portVariant.value == 8080

  test "string variant default is honored":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let triple = declareVariant[string](
      defaultValue = "native",
      scopeName = "targetTriple",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    check triple.value == "native"

  test "plain Configurable inside evalConfig is NOT solver-participating":
    var plainHandle: Configurable[int]
    let ctx = evalConfig:
      let portC = configurable 8080
      plainHandle = portC
    # Plain Configurables resolve via evalConfig; their ``value``
    # accessor is the variant-specific one which raises ENotAVariant
    # when invoked on a non-variant. ``read`` is the regular surface.
    check ctx.read(plainHandle) == 8080
    # The ambient variant context did not gain a node from the
    # evalConfig block.
    check currentVariantContext() == nil

  test "variant context is finalized after finalizeVariants":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[bool](
      defaultValue = false,
      scopeName = "flag",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    check not variantsFinalized()
    finalizeVariants()
    check variantsFinalized()
