## Spec-Implementation M3 — recipe code consuming the M3 interfaces.
##
## Simulates a recipe body that reads from
## ``currentBuildContext().toolchain``, ``crossTarget``, and
## ``featureSet`` to emit a build action. The simulation mirrors the
## shape a real ``build:`` block would have, but routes through the
## raw ``beginBuildBlock`` / ``endBuildBlock`` surface so the test
## doesn't depend on the ``package`` macro's full lowering.
##
## Asserts:
##   1. A "recipe" that reads ``currentBuildContext().toolchain.compile``
##      produces a non-empty ``BuildAction`` whose argv carries the
##      requested flags.
##   2. The same recipe under a ``compiler = "clang"`` override
##      produces a clang-flavoured argv (the slot routes through the
##      variant-driven adapter resolver).
##   3. ``currentBuildContext().featureSet.enabled`` returns the
##      solver's resolved truth-value for a declared boolean variant.
##   4. ``currentBuildContext().crossTarget.tripleOrEmpty`` returns
##      the empty string under the default (native) state, and the
##      configured triple after a non-native override.

import std/[strutils, unittest]

import repro_dsl_stdlib
import repro_dsl_stdlib/configurables

proc emitCompileAction(): BuildAction =
  ## Stand-in for a recipe body. Reads the active toolchain slot and
  ## asks it to build a compile action for a synthetic source path.
  let ctx = currentBuildContext()
  ctx.toolchain.compile("src/foo.c", "build/foo.o", @["-O0"])

proc activeFeatureEnabled(name: string): bool =
  let ctx = currentBuildContext()
  ctx.featureSet.enabled(name)

proc activeTripleOrEmpty(): string =
  let ctx = currentBuildContext()
  tripleOrEmpty(ctx.crossTarget)

suite "Spec-Implementation M3: recipe consumes interface":

  setup:
    resetVariantState()

  test "recipe emits a compile action through the toolchain slot":
    finalizeVariants()
    let state = beginBuildBlock("myapp")
    try:
      let action = emitCompileAction()
      check action.argv.len > 0
      check action.argv[0] == "gcc"
      check "-O0" in action.argv
      check action.inputs == @["src/foo.c"]
      check action.outputs == @["build/foo.o"]
    finally:
      endBuildBlock(state)

  test "compiler = 'clang' switches the recipe's argv":
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
      let action = emitCompileAction()
      check action.argv[0] == "clang"
      check action.actionId.startsWith("clang-")
    finally:
      endBuildBlock(state)

  test "recipe reads featureSet.enabled for the resolved variant":
    let info = instantiationInfo(fullPaths = true)
    let site = newSourceSite(info.filename, info.line, info.column, ckDefault)
    discard declareVariant[bool](
      defaultValue = true,
      scopeName = "tls",
      description = "",
      explicitId = "",
      descriptionFile = "",
      descriptionLine = 0,
      descriptionColumn = 0,
      site = site)
    finalizeVariants()
    let state = beginBuildBlock("myapp")
    try:
      check activeFeatureEnabled("tls")
      check not activeFeatureEnabled("missing")
    finally:
      endBuildBlock(state)

  test "crossTarget switches under a triple override":
    # Native first.
    finalizeVariants()
    let state1 = beginBuildBlock("myapp")
    try:
      check activeTripleOrEmpty() == ""
    finally:
      endBuildBlock(state1)

    resetVariantState()
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
    let state2 = beginBuildBlock("myapp")
    try:
      check activeTripleOrEmpty() == "aarch64-linux-gnu"
    finally:
      endBuildBlock(state2)
