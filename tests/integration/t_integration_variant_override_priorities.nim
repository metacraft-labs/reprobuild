## Spec-Implementation M1 — variant priority lattice.
##
## A variant is an ordinary ``Configurable[T]`` per
## ``Configurable-System.md`` §"Why Not a Parallel Primitive"; the
## priority lattice (``prDefault < prSet < prOverride < prForce``)
## therefore applies unchanged. This integration test exercises each
## band on a single variant handle to confirm the M1 wiring does not
## diverge from the regular Configurable priority semantics.

import std/[strutils, unittest]

import repro_dsl_stdlib/configurables

template makeIntVariant(default: int): Configurable[int] =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[int](
    defaultValue = default,
    scopeName = "port",
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

proc captureSiteAt(kind: ContributionKind): SourceSite =
  let info = instantiationInfo(fullPaths = true)
  newSourceSite(info.filename, info.line, info.column, kind)

suite "Spec-Implementation M1: variant priority lattice":

  setup:
    resetVariantState()

  test "default contribution wins when no other priority lands":
    let v = makeIntVariant(8080)
    finalizeVariants()
    check v.value == 8080

  test "prSet outranks prDefault":
    let v = makeIntVariant(8080)
    let ctx = currentVariantContext()
    let node = ctx.nodeOf(v.id)
    ctx.addContribution(node, prSet, cvInt(9000),
      captureSiteAt(ckSet))
    finalizeVariants()
    check v.value == 9000

  test "prOverride outranks prDefault":
    let v = makeIntVariant(8080)
    let ctx = currentVariantContext()
    let node = ctx.nodeOf(v.id)
    ctx.addContribution(node, prOverride, cvInt(10_000),
      captureSiteAt(ckOverride))
    finalizeVariants()
    check v.value == 10_000

  test "prOverride outranks prSet":
    let v = makeIntVariant(8080)
    let ctx = currentVariantContext()
    let node = ctx.nodeOf(v.id)
    ctx.addContribution(node, prSet, cvInt(9000),
      captureSiteAt(ckSet))
    ctx.addContribution(node, prOverride, cvInt(10_000),
      captureSiteAt(ckOverride))
    finalizeVariants()
    check v.value == 10_000

  test "prForce outranks every other priority":
    let v = makeIntVariant(8080)
    let ctx = currentVariantContext()
    let node = ctx.nodeOf(v.id)
    ctx.addContribution(node, prSet, cvInt(9000),
      captureSiteAt(ckSet))
    ctx.addContribution(node, prOverride, cvInt(10_000),
      captureSiteAt(ckOverride))
    ctx.addContribution(node, prForce, cvInt(99_999),
      captureSiteAt(ckForce))
    finalizeVariants()
    check v.value == 99_999

  test "contributions list preserves declaration order":
    let v = makeIntVariant(8080)
    let ctx = currentVariantContext()
    let node = ctx.nodeOf(v.id)
    ctx.addContribution(node, prSet, cvInt(9000),
      captureSiteAt(ckSet))
    ctx.addContribution(node, prOverride, cvInt(10_000),
      captureSiteAt(ckOverride))
    let contribs = variantContributions(v)
    check contribs.len == 3
    check contribs[0].priority == prDefault
    check contribs[1].priority == prSet
    check contribs[2].priority == prOverride
