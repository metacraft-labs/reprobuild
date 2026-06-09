## Spec-Implementation M3 — active-build-context default slot wiring.
##
## Asserts:
##   1. ``currentBuildContext()`` raises ``ValueError`` when called
##      outside an active ``build:`` block (mirrors
##      ``currentBuildState`` semantics).
##   2. Inside an active block, all four slots are populated lazily
##      with the stdlib defaults: a ``default-test-runner`` runner,
##      the gcc toolchain (M3 default), the native cross-target, and
##      the solver-backed feature-set.
##   3. ``validate`` passes for every slot the accessor exposes.
##   4. Repeated calls to ``currentBuildContext()`` inside the same
##      block return handles that wrap the same underlying
##      ``PackageBuildState`` (slot identity is preserved).

import std/unittest

import repro_dsl_stdlib
import repro_dsl_stdlib/configurables

suite "Spec-Implementation M3: active-build-context default slots":

  setup:
    resetVariantState()

  test "currentBuildContext outside a build block raises":
    expect ValueError:
      discard currentBuildContext()

  test "default slots populate lazily":
    let state = beginBuildBlock("myapp")
    try:
      let ctx = currentBuildContext()
      check ctx.state == state
      let runner = ctx.testRunner
      validate(runner)
      check runner.name == "default-test-runner"
      let tc = ctx.toolchain
      validate(tc)
      check tc.name == "gcc-toolchain"
      let cross = ctx.crossTarget
      validate(cross)
      check cross.isNative
      check cross.name == "native"
      let fs = ctx.featureSet
      validate(fs)
      check fs.name == "solver-feature-set"
    finally:
      endBuildBlock(state)

  test "slot identity is preserved across calls":
    let state = beginBuildBlock("myapp")
    try:
      let ctx1 = currentBuildContext()
      let ctx2 = currentBuildContext()
      # Both handles wrap the same state ref.
      check ctx1.state == ctx2.state
      # The slot objects themselves are the same ref — the lazy
      # installer only runs once.
      check ctx1.testRunner == ctx2.testRunner
      check ctx1.toolchain == ctx2.toolchain
      check ctx1.crossTarget == ctx2.crossTarget
      check ctx1.featureSet == ctx2.featureSet
    finally:
      endBuildBlock(state)

  test "setTestRunner override replaces the slot":
    let state = beginBuildBlock("myapp")
    try:
      let ctx = currentBuildContext()
      let original = ctx.testRunner
      check original.name == "default-test-runner"
      proc customRun(binary: TestBinary; filter: string): ExitCode = 7
      proc customList(binary: TestBinary): seq[TestCase] = @[]
      proc customEnum(binary: TestBinary): seq[QualifiedName] = @[]
      let custom = newTestRunner(
        name = "custom-runner",
        run = customRun,
        list = customList,
        enumerate = customEnum)
      setTestRunner(ctx, custom)
      let after = ctx.testRunner
      check after.name == "custom-runner"
      check after != original
    finally:
      endBuildBlock(state)
