## t_integration_test_runner_adapter_registered —
## Spec-Implementation M4 verification.
##
## Confirms that the ``ct_test_runner_adapter`` package, when imported
## from inside an active reprobuild build context, REPLACES the M3
## stdlib default ``TestRunner`` with the ct-test-backed adapter:
##
##   * Before the adapter is wired, ``currentBuildContext().testRunner``
##     returns the stdlib's ``default-test-runner`` (the
##     direct-binary fallback).
##   * After calling ``installCtTestRunner(currentBuildContext())``,
##     the slot is the ct-test adapter with
##     ``name == "ct-test-runner-adapter"`` and the M3 ``validate``
##     contract still holds (every vtable proc populated).
##   * The slot survives multiple ``currentBuildContext()`` calls
##     within the same build frame — the M3 stdlib doesn't reset the
##     slot once a non-default adapter is installed.
##
## No skip()/mocks: the adapter ships and registers via the real
## stdlib context plumbing.

import std/unittest

import repro_project_dsl
import repro_dsl_stdlib/active_context
import repro_dsl_stdlib/interfaces/test_runner
import ct_test_runner_install

suite "t_integration_test_runner_adapter_registered":
  test "stdlib default is the direct-binary runner before adapter install":
    let state = beginBuildBlock("t_integration_adapter_default_first")
    defer: endBuildBlock(state)

    let ctx = currentBuildContext()
    let before = ctx.testRunner
    check before != nil
    check before.name == "default-test-runner"
    check before.run != nil

  test "installCtTestRunner replaces the slot with the adapter":
    let state = beginBuildBlock("t_integration_adapter_install")
    defer: endBuildBlock(state)

    let ctx = currentBuildContext()
    # First read pins the stdlib default into the slot.
    let stdlibDefault = ctx.testRunner
    check stdlibDefault.name == "default-test-runner"

    # The adapter's explicit installer overrides the slot.
    installCtTestRunner(ctx)
    let after = ctx.testRunner
    check after != nil
    check after.name == "ct-test-runner-adapter"
    check after.run != nil
    check after.list != nil
    check after.enumerate != nil

    # The M3 validate contract is still satisfied.
    var validated = false
    try:
      validate(after)
      validated = true
    except AssertionDefect:
      validated = false
    check validated

  test "adapter persists across repeated currentBuildContext lookups":
    let state = beginBuildBlock("t_integration_adapter_persists")
    defer: endBuildBlock(state)

    let ctx1 = currentBuildContext()
    installCtTestRunner(ctx1)
    check ctx1.testRunner.name == "ct-test-runner-adapter"

    # A second fetch of the context handle returns a fresh BuildContext
    # facade but points at the same underlying PackageBuildState. The
    # slot installation is on the state, so the second handle sees the
    # adapter.
    let ctx2 = currentBuildContext()
    check ctx2.testRunner.name == "ct-test-runner-adapter"
    check ctx2.state == ctx1.state
