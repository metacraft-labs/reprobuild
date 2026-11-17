## A Nim test's execute edge launches the file its compile edge declares.
##
## THE DEFECT (reprobuild-pm issue 2026-11-17-windows-test-execute-edge-
## launches-the-test-binary-without-its-exe-suffix). On Windows
## ``buildNimUnittest.build`` declared ``--out:<binary>.exe`` (``nim c``
## appends the suffix) but returned a handle carrying the bare ``<binary>``.
## ``run`` / ``runTest`` / ``list`` turn the handle's path into the program
## the execute edge launches and into the input that orders the compile
## before it. So ``repro build '.#test#<name>'`` launched
## ``build\test-bin\<stem>`` (``CreateProcessW failed (err=2)``), and since no
## edge declared that bare path as an output, the compile edge was never even
## scheduled.
##
## WHAT IS ASSERTED, and why that is enough. The engine schedules a producer
## before a consumer by matching the consumer's input path against the
## producer's declared outputs, and the NimUnittest execute site launches the
## ``binary`` argument's value verbatim
## (``repro_cli_support``: ``argv = @[resolvedBinary]``). Both halves are
## fields of the recorded ``BuildActionDef``, so the arms read them straight
## from the registry the real recipe evaluation fills. Nothing is mocked.
##
## ``helper`` pins the Windows rule itself on every host, through the
## ``windowsTarget`` parameter, so a Linux run catches a helper that stops
## adding the suffix. ``agreement`` and ``bare handle`` check that the
## compile's declared output, the typed handle, and each execute edge's
## launched path are the same string FOR THE HOST BEING BUILT; on Windows
## that is the arm that failed before the fix.

import std/[strutils, unittest]

import repro_project_dsl
import ct_test_nim_unittest

const Binary = "build/test-bin/t_probe"

proc binaryArgOf(act: BuildActionDef): string =
  ## The ``binary`` argument: what the engine's NimUnittest execute site
  ## launches as argv[0].
  for arg in act.call.arguments:
    if arg.name == "binary":
      return arg.encodedValue
  ""

proc freshRegistry() =
  ## The action registry and the implicit-target table both persist across
  ## test cases; a recipe evaluation starts with both empty.
  resetBuildActionRegistry()
  resetTargetExportRegistry()

proc outputArgOf(act: BuildActionDef): string =
  for arg in act.call.arguments:
    if arg.name == "output":
      return arg.encodedValue
  ""

suite "a Nim test's execute edge launches its compile edge's output":

  test "helper: Windows gains .exe, idempotently; other hosts unchanged":
    check nimUnittestExecutablePath(Binary, windowsTarget = true) ==
      Binary & ".exe"
    check nimUnittestExecutablePath(Binary & ".exe", windowsTarget = true) ==
      Binary & ".exe"
    check nimUnittestExecutablePath("", windowsTarget = true) == ""
    check nimUnittestExecutablePath(Binary, windowsTarget = false) == Binary
    check nimUnittestExecutablePath(Binary) ==
      (when defined(windows): Binary & ".exe" else: Binary)

  test "agreement: declared output, typed handle and launched path coincide":
    freshRegistry()
    let edge = buildNimUnittest.build(
      source = "tests/t_probe.nim", binary = Binary)
    let declared = nimUnittestExecutablePath(Binary)
    checkpoint("declared output: " & declared)
    check outputArgOf(edge.action) == declared
    check declared in edge.action.outputs
    check edge.testBinary.path == declared

    let execute = edge.testBinary.run(actionId = "probe.execute",
      registerImplicitName = false)
    check binaryArgOf(execute) == declared
    # The ordering half: the execute edge's input names the compile's output.
    check declared in execute.inputs
    # ``runTest`` / ``list`` always register the binary's implicit target
    # name, which the compile above already holds, so each gets fresh
    # registries; the handle is the one the compile returned.
    let handle = edge.testBinary
    freshRegistry()
    check binaryArgOf(handle.runTest("suite::case",
      actionId = "probe.runTest")) == declared
    freshRegistry()
    check binaryArgOf(handle.list(actionId = "probe.list")) == declared

  test "bare handle: a caller-built handle still launches the declared file":
    freshRegistry()
    let execute = NimUnittestBinary(path: Binary).run(
      actionId = "probe.bare", registerImplicitName = false)
    check binaryArgOf(execute) == nimUnittestExecutablePath(Binary)
    when defined(windows):
      check binaryArgOf(execute).endsWith(".exe")
