## Spec-Implementation M3 — variant-driven default slot resolution.
##
## Asserts that the active-build-context's slot-resolution path
## consults the M2d solver solution:
##   1. With the default ``compiler`` variant (``"gcc"``), the
##      ``toolchain`` slot resolves to ``gcc-toolchain``.
##   2. With ``compiler = "clang"`` (via the CLI override path), the
##      slot resolves to ``clang-toolchain``.
##   3. With ``targetTriple = "native"`` the ``crossTarget`` slot
##      resolves to the native adapter.
##   4. With ``targetTriple = "aarch64-linux-gnu"`` the slot resolves
##      to a non-native adapter whose triple matches.

import std/[unittest]

import repro_dsl_stdlib
import repro_dsl_stdlib/configurables

suite "Spec-Implementation M3: variant-driven slot resolution":

  setup:
    resetVariantState()

  test "default compiler variant picks gcc toolchain":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let state = beginBuildBlock("myapp")
    try:
      let ctx = currentBuildContext()
      check ctx.toolchain.name == "gcc-toolchain"
    finally:
      endBuildBlock(state)

  test "compiler = 'clang' override switches the slot":
    addVariantCliOverride("compiler", "clang")
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[string](
      defaultValue = "gcc",
      scopeName = "compiler",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let state = beginBuildBlock("myapp")
    try:
      let ctx = currentBuildContext()
      check ctx.toolchain.name == "clang-toolchain"
      check ctx.toolchain.cCompilerPath == "clang"
    finally:
      endBuildBlock(state)

  test "targetTriple = 'native' resolves to native adapter":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[string](
      defaultValue = "native",
      scopeName = "targetTriple",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let state = beginBuildBlock("myapp")
    try:
      let ctx = currentBuildContext()
      check ctx.crossTarget.isNative
      check ctx.crossTarget.name == "native"
    finally:
      endBuildBlock(state)

  test "targetTriple non-native picks crossTargetFromTriple":
    addVariantCliOverride("targetTriple", "aarch64-linux-gnu")
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[string](
      defaultValue = "native",
      scopeName = "targetTriple",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let state = beginBuildBlock("myapp")
    try:
      let ctx = currentBuildContext()
      check not ctx.crossTarget.isNative
      check ctx.crossTarget.triple == "aarch64-linux-gnu"
      check ctx.crossTarget.hostPrefix() == "aarch64-linux-gnu-"
    finally:
      endBuildBlock(state)
