## The nim unittest compile edge declares its nimcache as removed before it
## runs (the ``removeBeforeRun`` declaration), so the files nim writes there are
## an output the edge owns rather than an untracked read.
##
## THE DEFECT. ``buildNimUnittest.build`` passed ``--nimcache:build/nimcache/<stem>``
## to ``nim c`` but declared nothing about that directory. A certificate's
## untracked-input rule then judged the edge's read-back of its own generated
## ``.nim.c`` and ``.nim.c.o`` files as reads of untracked files, and refused to
## certify a repository whose tests were built by this edge (term-assert-cmd,
## 2026-11-23: ``-lc, -ldl, ... build/nimcache/test_cli_smoke/...nim.c``).
##
## THE FIX, and what this test asserts. The edge names its nimcache argument in
## ``removeBeforeRun``, the declaration Test-Certificates.md exempts ("a file
## under an output the engine removes before such an action runs"). The test
## reads the registry the real ``build`` call filled, so nothing is mocked:
## the nimcache directory is in the registered action's ``removeBeforeRun``, and
## the source file, which is an input and not a product, is not.

import std/[strutils, unittest]

import repro_project_dsl
import ct_test_nim_unittest

const
  Binary = "build/test-bin/t_probe"
  Nimcache = "build/nimcache/t_probe"

proc freshRegistry() =
  resetBuildActionRegistry()
  resetTargetExportRegistry()

proc registeredRemoveBeforeRun(actionId: string): seq[string] =
  for entry in registeredBuildActions():
    if entry.id == actionId:
      return entry.removeBeforeRun
  @[]

suite "the nim unittest compile edge removes its nimcache before it runs":

  test "the nimcache directory is declared removed before the compile":
    freshRegistry()
    let edge = buildNimUnittest.build(
      source = "tests/t_probe.nim", binary = Binary)
    let removed = registeredRemoveBeforeRun(edge.action.id)
    checkpoint("removeBeforeRun: " & removed.join(", "))
    check Nimcache in removed

  test "only the nimcache is declared removed, not the source or the binary":
    freshRegistry()
    let edge = buildNimUnittest.build(
      source = "tests/t_probe.nim", binary = Binary)
    let removed = registeredRemoveBeforeRun(edge.action.id)
    check "tests/t_probe.nim" notin removed
    check Binary notin removed
    check removed.len == 1
