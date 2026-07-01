## Bootstrap-And-Self-Build Deferred-D3: reprobuild's split ct-test runner
## inputs are locked, and the legacy live-sibling ``CT_TEST_SRC`` override is
## gone from ``scripts/run_tests.sh``.
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
## D3 closed the gap by moving the build-side ct-test packages in-tree and
## keeping only the run-side adapter / shared contract as split flake inputs.
## This test is the structural regression guard: those inputs must remain
## locked, and a revert of the run_tests.sh edit must fail this test.
##
## Strategy
## --------
## Two structural assertions, both on-disk text only — no engine, no
## ct-test build, no nix evaluation:
##
##   1. ``flake.lock`` carries full-SHA locks for
##      ``reprobuild-ct-test-runner-src`` and
##      ``reprobuild-test-adapters-src``.
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

proc lockedInputRev(repoRoot, inputName: string): string =
  ## Parse ``flake.lock`` and return the ``rev`` field of the input's
  ## ``locked`` block. Raises on missing input — a missing input is itself a
  ## regression worth flagging.
  let lockPath = repoRoot / "flake.lock"
  check fileExists(lockPath)
  let root = parseFile(lockPath)
  check root.kind == JObject
  check root.hasKey("nodes")
  let nodes = root["nodes"]
  check nodes.kind == JObject
  check nodes.hasKey(inputName)
  let entry = nodes[inputName]
  check entry.kind == JObject
  check entry.hasKey("locked")
  let locked = entry["locked"]
  check locked.kind == JObject
  check locked.hasKey("rev")
  let rev = locked["rev"]
  check rev.kind == JString
  result = rev.getStr()

suite "Deferred-D3: ct-test flake input carries the B3+B4 buildNimUnittest API":

  test "structural: flake.lock carries the split ct-test runner inputs":
    let repoRoot = findRepoRoot()
    for inputName in [
      "reprobuild-ct-test-runner-src",
      "reprobuild-test-adapters-src",
    ]:
      let rev = lockedInputRev(repoRoot, inputName)
      checkpoint("flake.lock " & inputName & " rev: " & rev)

      # GitHub inputs always lock to a full SHA. A short-form hit here would
      # mean the lock file shape changed and the test needs a refresh.
      check rev.len == 40
      for ch in rev:
        check ch in {'0'..'9', 'a'..'f'}

      # The old monorepo ct-test snapshot is no longer a valid source for
      # these split inputs.
      check rev != PreB3CtTestSha
    checkpoint("split ct-test runner inputs locked: OK")

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
