## Spec-Implementation M1 — ``--variant name=value`` CLI flag.
##
## ``runBuildCommand`` (and ``runReproTestCommand`` via the same parser
## shape) accepts ``--variant name=value`` and propagates the
## contribution into the provider process via the ``REPRO_VARIANTS``
## env var. The variants module reads the env var on first ambient
## context creation and registers each pair as a ``prSet`` contribution
## against the named variant at declaration time. Workspace
## ``override`` still wins (``prOverride > prSet``); workspace
## ``force`` overrides everything.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/configurables

template makeBoolVariant(name: string; default: bool): Configurable[bool] =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[bool](
    defaultValue = default,
    scopeName = name,
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

template makeStringVariant(name: string; default: string): Configurable[string] =
  let info = instantiationInfo(fullPaths = true)
  let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
  declareVariant[string](
    defaultValue = default,
    scopeName = name,
    description = "",
    explicitId = "",
    descriptionFile = "",
    descriptionLine = 0,
    descriptionColumn = 0,
    site = site)

suite "Spec-Implementation M1: --variant CLI flag":

  setup:
    resetVariantState()
    delEnv("REPRO_VARIANTS")

  test "addVariantCliOverride registers a prSet against the named variant":
    addVariantCliOverride("enableTLS", "false")
    let v = makeBoolVariant("enableTLS", true)
    finalizeVariants()
    check v.value == false

  test "CLI override is overridden by workspace override (prOverride > prSet)":
    addVariantCliOverride("enableTLS", "false")
    let v = makeBoolVariant("enableTLS", true)
    let ctx = currentVariantContext()
    let node = ctx.nodeOf(v.id)
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column,
      ckOverride)
    ctx.addContribution(node, prOverride, cvBool(true), site)
    finalizeVariants()
    check v.value == true

  test "REPRO_VARIANTS env var seeds the override at ambient context creation":
    putEnv("REPRO_VARIANTS", "compiler=clang")
    let v = makeStringVariant("compiler", "gcc")
    finalizeVariants()
    check v.value == "clang"

  test "REPRO_VARIANTS accepts multiple comma-separated entries":
    putEnv("REPRO_VARIANTS", "compiler=clang,enableTLS=false")
    let compiler = makeStringVariant("compiler", "gcc")
    let tls = makeBoolVariant("enableTLS", true)
    finalizeVariants()
    check compiler.value == "clang"
    check tls.value == false

  test "REPRO_VARIANTS skips empty entries gracefully":
    putEnv("REPRO_VARIANTS", ",enableTLS=false,")
    let tls = makeBoolVariant("enableTLS", true)
    finalizeVariants()
    check tls.value == false

  test "CLI override against an unknown variant is silently inert":
    # The override is registered against a name but no variant by that
    # name is ever declared. The default-named variant is unaffected.
    addVariantCliOverride("unrelated", "false")
    let v = makeBoolVariant("enableTLS", true)
    finalizeVariants()
    check v.value == true

  test "bool variant accepts 1/0/yes/no/on/off as well as true/false":
    putEnv("REPRO_VARIANTS", "enableTLS=0")
    let v = makeBoolVariant("enableTLS", true)
    finalizeVariants()
    check v.value == false

  teardown:
    delEnv("REPRO_VARIANTS")
