## Bootstrap-And-Self-Build Deferred-D3: the ``ct-test-src`` flake
## input is pinned past the B3/B4 API additions so the in-tree
## ``scripts/run_tests.sh`` does not need the live-sibling
## ``CT_TEST_SRC`` override.
##
## Background
## ----------
## The B5 outcome carried a workaround in ``scripts/run_tests.sh``::
##
##     if [[ -d "../ct-test" && -d "../ct-test/libs/ct_test_nim_unittest" ]]; then
##       CT_TEST_SRC_ABS="$(cd ../ct-test && pwd)"
##       export CT_TEST_SRC="${CT_TEST_SRC_ABS}"
##     fi
##
## The override pointed ``CT_TEST_SRC`` at the workspace sibling
## because the flake input was still pinned at the pre-B3 ct-test SHA
## ``f746367c7f996b1599508971fdab3f37832c3dfe`` — a snapshot that did
## not yet expose B3's ``requiredBinaries`` / ``extraInputs`` /
## etc. parameters or B4's ``extraPassC`` / ``extraPassL`` parameters
## on ``buildNimUnittest.build``. Without the override the in-tree
## DSL call sites would fail to compile against the stale snapshot.
##
## D3 closed the gap by bumping the lock to ct-test's current ``main``
## (post-B4) and dropped the override. This test is the structural
## regression guard: a future ``nix flake update`` that accidentally
## rolled the input back, or a revert of the run_tests.sh edit, must
## fail this test.
##
## Strategy
## --------
## Two structural assertions, both on-disk text only — no engine, no
## ct-test build, no nix evaluation:
##
##   1. ``flake.lock`` ct-test-src entry's ``rev`` field is NOT the
##      pre-B3 SHA. We intentionally do not pin the new SHA; the lock
##      should be free to roll forward as ct-test ``main`` advances.
##      The negative assertion catches the specific regression we
##      care about (back to pre-B3) without locking the test to a
##      single snapshot.
##
##   2. ``scripts/run_tests.sh`` no longer contains the live-sibling
##      override block (the ``CT_TEST_SRC_ABS`` literal). A revert
##      that re-introduces the workaround must fail.

import std/[json, os, strutils, unittest]

const RepoMarker = "repro.nim"

## The pre-B3 ct-test SHA the flake input was pinned at before D3.
## Bumping the input back to this snapshot would break the in-tree
## ``buildNimUnittest.build`` call sites (they use B3 + B4 keyword
## parameters that this snapshot does not yet expose) — exactly the
## breakage D3 closed.
const PreB3CtTestSha = "f746367c7f996b1599508971fdab3f37832c3dfe"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc lockedCtTestRev(repoRoot: string): string =
  ## Parse ``flake.lock`` and return the ``rev`` field of the
  ## ``ct-test-src`` input's ``locked`` block. Raises on missing
  ## input — a missing input is itself a regression worth flagging.
  let lockPath = repoRoot / "flake.lock"
  check fileExists(lockPath)
  let root = parseFile(lockPath)
  check root.kind == JObject
  check root.hasKey("nodes")
  let nodes = root["nodes"]
  check nodes.kind == JObject
  check nodes.hasKey("ct-test-src")
  let entry = nodes["ct-test-src"]
  check entry.kind == JObject
  check entry.hasKey("locked")
  let locked = entry["locked"]
  check locked.kind == JObject
  check locked.hasKey("rev")
  let rev = locked["rev"]
  check rev.kind == JString
  result = rev.getStr()

suite "Deferred-D3: ct-test flake input carries the B3+B4 buildNimUnittest API":

  test "structural: flake.lock ct-test-src rev is past the pre-B3 snapshot":
    let repoRoot = findRepoRoot()
    let rev = lockedCtTestRev(repoRoot)
    checkpoint("flake.lock ct-test-src rev: " & rev)

    # The pinned rev must be a full 40-char hex SHA (github inputs
    # always lock to a full SHA — a short-form hit here would mean
    # the lock file shape changed and the test needs a refresh).
    check rev.len == 40
    for ch in rev:
      check ch in {'0'..'9', 'a'..'f'}

    # The critical regression guard: bumping back to the pre-B3
    # snapshot would re-break ``scripts/run_tests.sh`` without the
    # live-sibling override.
    check rev != PreB3CtTestSha
    checkpoint("ct-test-src lock past pre-B3 snapshot: OK")

  test "structural: scripts/run_tests.sh no longer overrides CT_TEST_SRC":
    let repoRoot = findRepoRoot()
    let runTests = repoRoot / "scripts" / "run_tests.sh"
    check fileExists(runTests)
    let text = readFile(runTests)

    # The override block in B5 introduced a ``CT_TEST_SRC_ABS`` shell
    # variable holding ``$(cd ../ct-test && pwd)``. D3 removed the
    # block; its disappearance is the visible delta. Assert the
    # literal is gone so a revert that re-introduces the override
    # is caught.
    check "CT_TEST_SRC_ABS" notin text

    # Belt-and-suspenders: the override also exported ``CT_TEST_SRC``
    # from the script. A future workaround that uses a different
    # intermediate variable name but still mutates ``CT_TEST_SRC``
    # would also be a regression — assert no ``export CT_TEST_SRC``
    # line survives. (The flake's devShell exports the variable for
    # us; the script must not re-export it.)
    for line in text.splitLines:
      let stripped = line.strip()
      check not stripped.startsWith("export CT_TEST_SRC=")
    checkpoint("CT_TEST_SRC override gone from run_tests.sh: OK")
