## Standard-Configurations — the built-in ``buildType`` axis drives the
## optimization / debug-info flags of the Layer-2 ``compile`` operation,
## without the recipe declaring the variant.
##
## Asserts:
##   1. ``currentBuildType()`` defaults to ``btDebug`` and is driven by the
##      thread-local override and by ``REPRO_VARIANTS=buildType=…``.
##   2. ``compileFlagsFor`` maps the four standard build types to the
##      conventional gcc/clang ``-O`` level + debug-info.
##   3. ``compile(opts)`` (→ ``gccCompile``) emits ``-O0 -g3`` under the
##      default debug build and ``-O2`` with no debug info under release —
##      so a recipe that never declared ``buildType`` still gets the right
##      flags from ``--release`` / the env override.

import std/[os, unittest]

import repro_project_dsl
import repro_dsl_stdlib/operations/compile
import repro_dsl_stdlib/operations/toolchain
import repro_dsl_stdlib/operations/buildtype
import repro_dsl_stdlib/types/options

proc optimizationOf(edge: BuildActionDef): tuple[present: bool; value: string] =
  callArgEncodedValue(edge.call, "optimization")

proc debugInfoOf(edge: BuildActionDef): bool =
  callArgEncodedValue(edge.call, "debug3").present

suite "Standard-Configurations: buildType drives compile flags":

  setup:
    setBuildTypeOverride("")
    setCompilerOverride("gcc")

  teardown:
    setBuildTypeOverride("")
    setCompilerOverride("")

  test "currentBuildType defaults to debug":
    check currentBuildType() == btDebug

  test "thread-local override drives currentBuildType":
    setBuildTypeOverride("release")
    check currentBuildType() == btRelease
    setBuildTypeOverride("relWithDebInfo")
    check currentBuildType() == btRelWithDebInfo

  test "REPRO_VARIANTS env drives currentBuildType (no variant declared)":
    putEnv("REPRO_VARIANTS", "buildType=release")
    check currentBuildType() == btRelease
    putEnv("REPRO_VARIANTS", "compiler=clang,buildType=minSizeRel")
    check currentBuildType() == btMinSizeRel
    delEnv("REPRO_VARIANTS")
    check currentBuildType() == btDebug

  test "compileFlagsFor maps the four standard build types":
    check compileFlagsFor(btDebug) == BuildTypeCompileFlags(optimization: "0", debugInfo: true)
    check compileFlagsFor(btRelease) == BuildTypeCompileFlags(optimization: "2", debugInfo: false)
    check compileFlagsFor(btRelWithDebInfo) == BuildTypeCompileFlags(optimization: "2", debugInfo: true)
    check compileFlagsFor(btMinSizeRel) == BuildTypeCompileFlags(optimization: "s", debugInfo: false)

  test "default debug build → gcc compile emits -O0 -g3":
    let edge = compile(CompileOptions(source: "a.c", target: "a.o"))
    let opt = optimizationOf(edge)
    check opt.present
    check opt.value == "0"
    check debugInfoOf(edge)

  test "release build → gcc compile emits -O2, no debug info":
    setBuildTypeOverride("release")
    let edge = compile(CompileOptions(source: "b.c", target: "b.o"))
    let opt = optimizationOf(edge)
    check opt.present
    check opt.value == "2"
    check not debugInfoOf(edge)

  test "minSizeRel build → gcc compile emits -Os":
    setBuildTypeOverride("minSizeRel")
    let edge = compile(CompileOptions(source: "c.c", target: "c.o"))
    check optimizationOf(edge).value == "s"
    check not debugInfoOf(edge)
