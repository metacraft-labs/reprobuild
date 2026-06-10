## Spec-Implementation M5 — cross-aarch64-linux-gnu adapter
## interface-conformance + variant-driven selection.
##
## The adapter package at
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/adapters/cross_aarch64_linux_gnu.nim``
## supplies both a ``Toolchain`` and a ``CrossTarget`` for the
## ``aarch64-linux-gnu`` triple. The active build context's
## ``resolveToolchain`` / ``resolveCrossTarget`` consult the
## ``targetTriple`` variant (via the M2d solver solution) and pick
## the cross adapter when the triple matches.
##
## Asserts:
##   1. ``crossAarch64LinuxGnuToolchain()`` produces a populated
##      ``Toolchain`` whose ``compile``/``link``/``archiveExecutable``
##      procs are all non-nil and survive ``validate``.
##   2. ``crossAarch64LinuxGnuTarget()`` produces a populated
##      ``CrossTarget`` whose ``triple`` is ``aarch64-linux-gnu``, is
##      not native, and survives ``validate``.
##   3. The adapter's ``compile`` action's argv carries the cross
##      compiler binary's path (the static probe → bare fallback if
##      the host has no cross-gcc) — not the host ``gcc``.
##   4. ``isCrossAarch64Triple`` accepts both the canonical
##      ``aarch64-linux-gnu`` triple AND the nixpkgs synonym
##      ``aarch64-unknown-linux-gnu``.
##   5. With the ``targetTriple`` variant overridden to
##      ``aarch64-linux-gnu`` the active build context's toolchain
##      slot resolves to the cross adapter (NOT gcc-toolchain) and
##      ``crossTarget`` resolves to the cross adapter (NOT
##      ``nativeCrossTarget``).

import std/[os, strutils, unittest]

import repro_dsl_stdlib
import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/adapters/cross_aarch64_linux_gnu

import repro_project_dsl

suite "Spec-Implementation M5: cross-aarch64-linux-gnu adapter":

  setup:
    resetVariantState()

  test "crossAarch64LinuxGnuToolchain populates the Toolchain vtable":
    let tc = crossAarch64LinuxGnuToolchain()
    check tc != nil
    check tc.name == "cross-aarch64-linux-gnu-toolchain"
    check tc.compile != nil
    check tc.link != nil
    check tc.archiveExecutable != nil
    # ``validate`` raises on a malformed adapter; passing through is
    # the assertion.
    validate(tc)

  test "crossAarch64LinuxGnuTarget populates the CrossTarget vtable":
    let ct = crossAarch64LinuxGnuTarget()
    check ct != nil
    check ct.name == "cross-aarch64-linux-gnu"
    check ct.triple == "aarch64-linux-gnu"
    check not ct.isNative
    check ct.targetTriple != nil
    check ct.hostPrefix != nil
    check ct.splice != nil
    check ct.targetTriple() == "aarch64-linux-gnu"
    check ct.hostPrefix() == "aarch64-linux-gnu-"
    validate(ct)

  test "compile action carries a cross-gcc binary in its argv":
    let tc = crossAarch64LinuxGnuToolchain()
    let action = tc.compile("src/foo.c", "build/foo.o", @[])
    check action.argv.len >= 4
    check action.argv[0].contains("aarch64")
    check action.argv[0].endsWith("-gcc")
    check "-c" in action.argv
    check action.inputs == @["src/foo.c"]
    check action.outputs == @["build/foo.o"]
    # The host gcc must not have slipped through.
    check not (action.argv[0] == "gcc")

  test "isCrossAarch64Triple accepts both canonical and nixpkgs spellings":
    check isCrossAarch64Triple("aarch64-linux-gnu")
    check isCrossAarch64Triple("aarch64-unknown-linux-gnu")
    check not isCrossAarch64Triple("native")
    check not isCrossAarch64Triple("aarch64-darwin")
    check not isCrossAarch64Triple("x86_64-linux-gnu")

  test "active build context resolves cross slots under variant override":
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
      check ctx.crossTarget.name == "cross-aarch64-linux-gnu"
      check ctx.crossTarget.triple == "aarch64-linux-gnu"
      check not ctx.crossTarget.isNative
      check ctx.toolchain.name == "cross-aarch64-linux-gnu-toolchain"

      # Recipe-visible: ``ctx.toolchain.compile`` produces an action
      # whose argv reaches the cross compiler binary.
      let action = ctx.toolchain.compile("src/x.c", "build/x.o", @[])
      check action.argv[0].contains("aarch64")
    finally:
      endBuildBlock(state)

  test "resolveCrossAarch64Compiler honours REPRO_AARCH64_GCC env override":
    let original = getEnv("REPRO_AARCH64_GCC")
    putEnv("REPRO_AARCH64_GCC", "/custom/path/to/cross-cc")
    let resolved = resolveCrossAarch64Compiler()
    if original.len > 0:
      putEnv("REPRO_AARCH64_GCC", original)
    else:
      delEnv("REPRO_AARCH64_GCC")
    check resolved == "/custom/path/to/cross-cc"
