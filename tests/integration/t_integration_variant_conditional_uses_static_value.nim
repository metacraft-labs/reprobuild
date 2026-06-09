## Spec-Implementation M1 — variant ``.value`` is a static Nim value
## at graph emission time.
##
## After ``finalizeVariants`` runs, recipe code can read a variant's
## ``.value`` and use ordinary Nim control flow against the result.
## This is the contract from ``Configurable-System.md`` §"Static-Value
## Contract": ``variant.value`` returns ``T`` (not ``Configurable[T]``)
## inside any package body at stage 4 or later.
##
## The test exercises the typical ``if variant.value: ...`` and
## ``case variant.value of ...`` shapes that the spec-example
## fixtures rely on for conditional ``uses:`` arms and conditional
## ``build:`` bodies.

import std/[unittest]

import repro_dsl_stdlib/configurables

suite "Spec-Implementation M1: variant.value at graph emission time":

  setup:
    resetVariantState()

  test "if variant.value: branch selects against the resolved value":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let enableTLS = declareVariant[bool](
      defaultValue = true,
      scopeName = "enableTLS",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    let ctx = currentVariantContext()
    # Simulate a workspace override of enableTLS = false.
    let overrideSite = newSourceSite(info.filename, info.line + 1,
      info.column, ckOverride)
    ctx.addContribution(ctx.nodeOf(enableTLS.id), prOverride,
      cvBool(false), overrideSite)
    finalizeVariants()
    var picked: seq[string] = @[]
    if enableTLS.value:
      picked.add("openssl >=3.3 <4.0")
    picked.add("nim >=2.2 <3.0")
    check picked == @["nim >=2.2 <3.0"]
    # And when the variant resolves true, the TLS dep IS picked.
    resetVariantState()
    let enableTLS2 = declareVariant[bool](
      defaultValue = true,
      scopeName = "enableTLS",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    var picked2: seq[string] = @[]
    if enableTLS2.value:
      picked2.add("openssl >=3.3 <4.0")
    picked2.add("nim >=2.2 <3.0")
    check picked2 == @["openssl >=3.3 <4.0", "nim >=2.2 <3.0"]

  test "case variant.value selector lands in the right arm":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let compiler = declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    var selected = ""
    case compiler.value
    of "gcc": selected = "gcc-adapter"
    of "clang": selected = "clang-adapter"
    else: selected = "unknown"
    check selected == "gcc-adapter"

  test "variant.value returns T (not Configurable[T])":
    # Type-level guarantee: the result of ``variant.value`` is the
    # underlying ``T``. We confirm this by binding to a typed local;
    # the test compiles iff the type matches.
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    let port = declareVariant[int](
      defaultValue = 8080,
      scopeName = "port",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let resolved: int = port.value
    check resolved == 8080
