## Spec-Implementation M1 — spec-example fixtures compile.
##
## Sibling to ``t_spec_example_fixtures_present.nim`` (structural).
## This test invokes ``nim check`` on the two M1-relevant fixtures
## (``simple-test-collection`` and ``variant-feature-flag``) and
## asserts a clean exit. The third fixture (``selectable-toolchain``)
## stays gated on M2 — its constraint-expression surface
## (``requires:`` / ``conflicts:`` / ``propagates:`` + the SAT
## extension) is not part of the M1 scope.
##
## Compilation is the M1 bar for the fixtures; end-to-end execution
## against the engine (the cross-cutting ``TestRunner`` adapter, the
## auto-enrollment of test edges into the ``test`` build graph
## collection) lands in later milestones.

import std/[os, osproc, strutils, unittest]

const FixturesRoot = currentSourcePath().parentDir.parentDir /
                     "fixtures" / "spec-examples"

proc fixtureCompiles(relPath: string): tuple[ok: bool; output: string] =
  let path = FixturesRoot / relPath
  doAssert fileExists(path),
    "spec-example fixture missing: " & relPath
  # ``nim check`` is sufficient — we only need the compiler to type-
  # check the package macro expansion, not to produce a binary. The
  # repo's ``config.nims`` configures the import path so the fixtures
  # find ``repro_project_dsl`` / ``ct_test_nim_unittest`` without
  # additional flags.
  let cmd = "nim check --hints:off --warnings:off " & path.quoteShell
  let (output, exitCode) = execCmdEx(cmd)
  result = (exitCode == 0, output)

suite "Spec-Implementation M1: spec-example fixtures compile":

  test "simple-test-collection compiles":
    let (ok, output) = fixtureCompiles("simple-test-collection/repro.nim")
    if not ok:
      checkpoint(output)
    check ok

  test "variant-feature-flag compiles":
    let (ok, output) = fixtureCompiles("variant-feature-flag/repro.nim")
    if not ok:
      checkpoint(output)
    check ok
