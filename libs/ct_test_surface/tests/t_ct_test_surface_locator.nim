## t_ct_test_surface_locator — the canonical-surface lookup resolves in the
## documented order, and the identity mapping is exactly CodeTracer's.
##
## Why this exists
## ---------------
## Two separate things can silently make "Reprobuild consumes the canonical
## ``ct test`` surface" false while every test still passes.
##
## 1. *The lookup quietly falls back.* This repository already has a lookup
##    that ends at ``build/bin/repro_test_runner``, and the whole point of the
##    new one is that it has no such tail. A regression that added one would
##    make every downstream measurement pass while measuring the wrong
##    program. So the order is pinned here, including the fact that an
##    unresolvable surface yields ``none`` rather than something.
## 2. *The identity mapping drifts.* ``ctTestItemIdFor`` reconstructs
##    CodeTracer's ``TestItem.id`` from a case's ``suite``/``name``. If it
##    drifts, a consumer's set comparison silently degrades to "nothing
##    matches", which reads as "the surface found nothing" rather than as a
##    bug here. The values below are pinned against a real ``ct test``
##    document, quoted in the test body with the command that produced it.
##
## Mocking: the lookup tests use *real executables* — tiny shell scripts made
## executable in a temporary directory — rather than a stubbed ``findExe``.
## The proc under test is a ``PATH`` search, so replacing the filesystem would
## replace the thing being tested. No behaviour of the ``ct test`` surface is
## simulated anywhere in this file; the surface's own behaviour is asserted in
## ``tests/integration/t_ct_test_surface_case_addressability.nim`` against the
## real binary.

import std/[options, os, strutils, tempfiles, unittest]

import ct_test_surface

proc writeExecutable(path: string) =
  writeFile(path, "#!/bin/sh\nexit 0\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
                            fpGroupRead, fpGroupExec,
                            fpOthersRead, fpOthersExec})

template withEnvironment(pathValue, ctTestValue: string; body: untyped) =
  ## Run ``body`` with ``PATH`` and ``CT_TEST`` set exactly as given, and the
  ## previous values restored afterwards whatever happens.
  let
    savedPath = getEnv("PATH")
    savedCtTestExists = existsEnv(CtTestSurfaceEnvVar)
    savedCtTest = getEnv(CtTestSurfaceEnvVar)
  putEnv("PATH", pathValue)
  if ctTestValue.len > 0: putEnv(CtTestSurfaceEnvVar, ctTestValue)
  else: delEnv(CtTestSurfaceEnvVar)
  try:
    body
  finally:
    putEnv("PATH", savedPath)
    if savedCtTestExists: putEnv(CtTestSurfaceEnvVar, savedCtTest)
    else: delEnv(CtTestSurfaceEnvVar)

suite "ct_test_surface locator and identity mapping":

  test "an empty PATH with no CT_TEST resolves to nothing at all":
    # The negative case first, because it is the one a fallback would hide.
    # If this ever returns `some`, the lookup has grown a tail.
    let sandbox = createTempDir("ct-test-surface-empty-", "")
    defer: removeDir(sandbox)
    withEnvironment(sandbox, ""):
      let located = locateCtTestSurface()
      check located.isNone

  test "PATH resolution prefers ct-test over ct":
    let sandbox = createTempDir("ct-test-surface-path-", "")
    defer: removeDir(sandbox)
    writeExecutable(sandbox / "ct")
    writeExecutable(sandbox / "ct-test")
    withEnvironment(sandbox, ""):
      let located = locateCtTestSurface()
      require located.isSome
      check located.get.origin == ctsoPathCtTest
      check located.get.binary.endsWith("ct-test")

  test "ct is accepted when ct-test is absent":
    let sandbox = createTempDir("ct-test-surface-ct-", "")
    defer: removeDir(sandbox)
    writeExecutable(sandbox / "ct")
    withEnvironment(sandbox, ""):
      let located = locateCtTestSurface()
      require located.isSome
      check located.get.origin == ctsoPathCt
      check located.get.binary.endsWith("ct")

  test "CT_TEST outranks both PATH candidates":
    let sandbox = createTempDir("ct-test-surface-env-", "")
    defer: removeDir(sandbox)
    writeExecutable(sandbox / "ct")
    writeExecutable(sandbox / "ct-test")
    let explicit = sandbox / "explicit-ct-test"
    writeExecutable(explicit)
    withEnvironment(sandbox, explicit):
      let located = locateCtTestSurface()
      require located.isSome
      check located.get.origin == ctsoEnvironment
      check located.get.binary == absolutePath(explicit)

  test "a CT_TEST that names no file does not resolve to it":
    # An override that points at nothing must not silently become "use
    # whatever is on PATH under a lie about where it came from" — the origin
    # is part of the evidence, so a mis-set variable has to fall through
    # visibly to the PATH candidate and be labelled as one.
    let sandbox = createTempDir("ct-test-surface-badenv-", "")
    defer: removeDir(sandbox)
    writeExecutable(sandbox / "ct-test")
    withEnvironment(sandbox, sandbox / "does-not-exist"):
      let located = locateCtTestSurface()
      require located.isSome
      check located.get.origin == ctsoPathCtTest

  test "the lookup order description names every step in order":
    let described = lookupOrderDescription()
    check described.contains("$" & CtTestSurfaceEnvVar)
    check described.find("`ct-test` on PATH") < described.find("`ct` on PATH")
    check described.find("$" & CtTestSurfaceEnvVar) <
      described.find("`ct-test` on PATH")

  test "the identity mapping reproduces a real ct test item id":
    # Pinned against a document produced by the real surface:
    #
    #   ct-test test discover --workspace <repo> \
    #     --file libs/ct_test_interface/tests/t_smoke_ct_test_interface.nim \
    #     --json
    #
    # whose only `case` item carries exactly this `id`. Written as a literal
    # rather than recomputed, because a mapping asserted against itself
    # asserts nothing.
    check ctTestItemIdFor(
        "libs/ct_test_interface/tests/t_smoke_ct_test_interface.nim",
        "t_smoke_ct_test_interface", "t_smoke_ct_test_interface") ==
      "nim-unittest/nim/std/unittest/libs/ct_test_interface/tests/" &
      "t_smoke_ct_test_interface.nim::t_smoke_ct_test_interface::" &
      "t_smoke_ct_test_interface"

  test "a case declared outside any suite keeps the provider's empty head":
    # `::name`, not `name`. The leading empty component is how CodeTracer's
    # provider spells "no enclosing suite"; dropping it would make every
    # suiteless case in this repository unmatchable while every count still
    # agreed.
    check ctTestSelectorFor("", "solo") == "::solo"
    check ctTestItemIdFor("tests/unit/t_x.nim", "", "solo") ==
      "nim-unittest/nim/std/unittest/tests/unit/t_x.nim::::solo"

  test "backslash-separated paths normalise to the provider's spelling":
    check ctTestItemIdFor("tests\\unit\\t_x.nim", "S", "c") ==
      ctTestItemIdFor("tests/unit/t_x.nim", "S", "c")
