## t_e2e_engine_shim_removed — Spec-Implementation M4 verification.
##
## Two-part verification that the M4 engine-shim retirement actually
## landed and that the replacement path still drives a clean compile:
##
##   1. Structural: ``libs/repro_cli_support/src/repro_cli_support.nim``
##      no longer contains the M3-and-earlier
##      ``buildNimUnittest.build`` translation block. The marker
##      strings ``"ct_test_nim_unittest.buildNimUnittest"`` and
##      ``payload.call.subcommand == "build"`` that uniquely identified
##      the shim's conditional must have been removed from any
##      executable branch. (The historical comment block is allowed —
##      a retired-shim marker comment names the removed code so future
##      readers can find what was deleted.) The check looks for the
##      live ``if`` statement, not the comment.
##
##   2. End-to-end: a ``buildNimUnittest.build(...)`` call inside a
##      project's ``build:`` block lands a ``BuildActionDef`` with the
##      M4 shape — ``packageName == "nim"`` and ``executableName ==
##      "nim"`` and ``subcommand == "c"`` so the engine's normal
##      ``lowerGraphAction`` path resolves it through the ``nim``
##      profile (with no shim translation).
##
## No skip()/mocks: the test reads the real
## ``repro_cli_support.nim`` file from disk and exercises the real
## ``buildNimUnittest.build`` typed-tool against the live DSL runtime.

import std/[os, strutils, unittest]

import repro_project_dsl
import ct_test_nim_unittest

const repoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / repoMarker) and
        dirExists(dir / "libs" / "repro_cli_support"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

suite "t_e2e_engine_shim_removed":
  test "repro_cli_support.nim no longer holds the live shim if-statement":
    let root = findRepoRoot()
    let shimPath = root / "libs" / "repro_cli_support" / "src" /
      "repro_cli_support.nim"
    check fileExists(shimPath)
    let contents = readFile(shimPath)

    # Mandatory: the comment marker recording WHY the shim is gone
    # must be in place so future readers can find the retirement note.
    check "Spec-Implementation M4 retired" in contents

    # Hard structural assertion: the live conditional
    #   ``if executableName == "ct_test_nim_unittest.buildNimUnittest" and``
    #   ``    payload.call.subcommand == "build":``
    # must be gone from the file (it lived in ``lowerGraphAction``
    # around line 1298 pre-M4 and was the gateway into the shim block).
    let livingCondition = "if executableName == \"" &
      "ct_test_nim_unittest.buildNimUnittest\""
    check livingCondition notin contents

    # Defensive: the shim's hand-rolled argv synthesis is gone too.
    # ``argv: seq[string] = @[nimProfile.resolvedExecutablePath, "c"]``
    # was its signature line.
    check "@[nimProfile.resolvedExecutablePath, \"c\"]" notin contents

  test "buildNimUnittest.build records a call against the nim profile":
    # Spin up an active build context so the typed-tool wrapper can
    # call recordToolInvocation.
    let state = beginBuildBlock("t_e2e_engine_shim_removed")
    defer: endBuildBlock(state)

    let edge = buildNimUnittest.build(
      source = "tests/fixture_source.nim",
      binary = "build/test-bin/t_e2e_engine_shim_removed_artifact",
      defines = @["release"])

    # The edge's ``action`` carries the recorded ``PublicCliCall``;
    # M4's reshape routes it through the ``nim`` profile so the
    # engine's normal typed-tool resolution drives the action.
    check edge.action.id.len > 0
    check edge.action.id.startsWith("nim-c-")
    check edge.action.call.packageName == "nim"
    check edge.action.call.executableName == "nim"
    check edge.action.call.subcommand == "c"

    # Spot-check the argument shape — the call must carry the
    # ``--out:`` output flag, the positional source, and the ``-d:``
    # defines, mirroring the long-standing ``nim.c`` typed-tool
    # surface so ``argvForCall`` produces the same argv shape the
    # pre-M4 shim was synthesising.
    var sawOutput = false
    var sawSource = false
    var sawDefines = false
    for arg in edge.action.call.arguments:
      case arg.name
      of "output":
        sawOutput = true
        check arg.alias == "--out:"
        check arg.encodedValue ==
          "build/test-bin/t_e2e_engine_shim_removed_artifact"
      of "source":
        sawSource = true
        check arg.encodedValue == "tests/fixture_source.nim"
      of "defines":
        sawDefines = true
        check arg.alias == "-d:"
        check arg.encodedValue == "release"
      else:
        discard
    check sawOutput
    check sawSource
    check sawDefines

    # Typed-output binding: ``edge.testBinary`` carries the path the
    # build wrote to so UFCS ``edge.testBinary.run(...)`` reaches the
    # exec-edge proc with the right input.
    check edge.testBinary.path ==
      "build/test-bin/t_e2e_engine_shim_removed_artifact"
