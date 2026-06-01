## M10 — dedicated unit test for the junction-aware-remove helper
## (see ``libs/repro_home_apply/src/repro_home_apply/junction_aware_remove.nim``).
##
## CRITICAL — per project memories
## ``project_reprobuild_store_junction_hazard`` and
## ``feedback_nim_removedir_junction_destructive``: an mklink-created
## junction-into-tmp-tree is parent-deleted via
## ``removeJunctionAware``; the tmp-tree's byte-identical contents
## are asserted before + after. Fails CLOSED if any target byte
## changes.
##
## This is the M10 spec's "t_junction_aware_remove_does_not_mutate_target"
## verification gate.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_apply/junction_aware_remove

const FixtureRoot = "build/test-tmp/t-junction-aware-remove"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    # Bootstrap reset uses the helper itself so this test can run
    # repeatedly without leaking state — and so the bootstrap path
    # is also junction-aware (defensive — if a prior test crashed
    # mid-run we MUST NOT recurse through a leftover junction).
    removeJunctionAware(path)
  createDir(extendedPath(path))

proc readBytes(path: string): string =
  result = readFile(extendedPath(path))

suite "M10 — junction-aware-remove helper":

  test "isJunction reports false for a real directory":
    let dir = FixtureRoot / "real-dir"
    resetDir(dir)
    createDir(extendedPath(dir / "sub"))
    writeFile(extendedPath(dir / "sub" / "file.txt"), "content")
    check (not isJunction(dir))
    check (not isJunction(dir / "sub"))

  test "isJunction reports false for a regular file":
    let dir = FixtureRoot / "real-file"
    resetDir(dir)
    writeFile(extendedPath(dir / "f.txt"), "data")
    check (not isJunction(dir / "f.txt"))

  test "removeJunctionAware deletes an empty real directory":
    let dir = FixtureRoot / "empty-real"
    resetDir(dir)
    removeJunctionAware(dir)
    check (not dirExists(extendedPath(dir)))

  test "removeJunctionAware recursively deletes a non-junction tree":
    let dir = FixtureRoot / "real-tree"
    resetDir(dir)
    createDir(extendedPath(dir / "a" / "b"))
    writeFile(extendedPath(dir / "top.txt"), "top")
    writeFile(extendedPath(dir / "a" / "mid.txt"), "mid")
    writeFile(extendedPath(dir / "a" / "b" / "leaf.txt"), "leaf")
    removeJunctionAware(dir)
    check (not dirExists(extendedPath(dir)))

  test "test_m10_junction_aware_remove_does_not_mutate_target":
    ## THE JUNCTION-HAZARD REGRESSION. Build an mklink /J junction
    ## into a separate "user-data" dir; delete the PARENT containing
    ## the junction; assert the user-data target's bytes are
    ## identical before + after (per-file content compare).
    when defined(windows):
      let parent = FixtureRoot / "hazard-parent"
      let userData = FixtureRoot / "hazard-userdata-target"
      resetDir(parent)
      resetDir(userData)
      writeFile(extendedPath(userData / "must-survive.txt"),
        "the user's REAL data — removeJunctionAware MUST NOT touch this\n")
      writeFile(extendedPath(userData / "second.txt"),
        "second file, also intact\n")
      createDir(extendedPath(userData / "nested"))
      writeFile(extendedPath(userData / "nested" / "deep.txt"),
        "deep content\n")
      # Snapshot user-data bytes BEFORE.
      let beforeMain = readBytes(userData / "must-survive.txt")
      let beforeSecond = readBytes(userData / "second.txt")
      let beforeDeep = readBytes(userData / "nested" / "deep.txt")

      let junctionPath = parent / "junction-into-userdata"
      let mklinkRes = execShellCmd("cmd /c mklink /J " &
        quoteShell(junctionPath) & " " & quoteShell(absolutePath(userData)))
      check mklinkRes == 0
      check isJunction(junctionPath)
      # Sanity: walking THROUGH the junction sees the target's files.
      check fileExists(extendedPath(junctionPath / "must-survive.txt"))

      # Now the dangerous op: recursively delete the parent dir
      # containing the junction. Nim's stdlib removeDir WOULD
      # destroy the target's contents here.
      removeJunctionAware(parent)

      # The junction itself + the parent are GONE:
      check (not dirExists(extendedPath(junctionPath)))
      check (not dirExists(extendedPath(parent)))
      # The target's bytes are BYTE-IDENTICAL — failure mode of
      # the hazard memory would have already wiped these files.
      check dirExists(extendedPath(userData))
      check fileExists(extendedPath(userData / "must-survive.txt"))
      check fileExists(extendedPath(userData / "second.txt"))
      check fileExists(extendedPath(userData / "nested" / "deep.txt"))
      check readBytes(userData / "must-survive.txt") == beforeMain
      check readBytes(userData / "second.txt") == beforeSecond
      check readBytes(userData / "nested" / "deep.txt") == beforeDeep
    else:
      # POSIX path: symlink-to-dir behaves like pcLinkToDir; the
      # helper unlinks the symlink without recursing into the target.
      let parent = FixtureRoot / "hazard-parent-posix"
      let userData = FixtureRoot / "hazard-userdata-target-posix"
      resetDir(parent)
      resetDir(userData)
      writeFile(extendedPath(userData / "must-survive.txt"),
        "the user's REAL data\n")
      writeFile(extendedPath(userData / "second.txt"), "also intact\n")
      let beforeMain = readBytes(userData / "must-survive.txt")
      let beforeSecond = readBytes(userData / "second.txt")
      let linkPath = parent / "link-into-userdata"
      createSymlink(absolutePath(userData), linkPath)
      check isJunction(linkPath)
      check fileExists(extendedPath(linkPath / "must-survive.txt"))
      removeJunctionAware(parent)
      check (not dirExists(extendedPath(parent)))
      check dirExists(extendedPath(userData))
      check readBytes(userData / "must-survive.txt") == beforeMain
      check readBytes(userData / "second.txt") == beforeSecond

  test "removeJunctionAware on a direct junction unlinks without recursing":
    when defined(windows):
      let parent = FixtureRoot / "direct-junction"
      let userData = FixtureRoot / "direct-junction-target"
      resetDir(parent)
      resetDir(userData)
      writeFile(extendedPath(userData / "keep.txt"), "keep me\n")
      let junctionPath = parent / "direct"
      let mklinkRes = execShellCmd("cmd /c mklink /J " &
        quoteShell(junctionPath) & " " & quoteShell(absolutePath(userData)))
      check mklinkRes == 0
      check isJunction(junctionPath)
      # Delete the junction directly (not its parent).
      removeJunctionAware(junctionPath)
      check (not dirExists(extendedPath(junctionPath)))
      check dirExists(extendedPath(userData))
      check fileExists(extendedPath(userData / "keep.txt"))
      check readBytes(userData / "keep.txt") == "keep me\n"

  test "directorySizeBytes sums file sizes; skips junctions":
    let dir = FixtureRoot / "size-walk"
    resetDir(dir)
    writeFile(extendedPath(dir / "a.txt"), "12345")        # 5 bytes
    writeFile(extendedPath(dir / "b.txt"), "1234567890")   # 10 bytes
    createDir(extendedPath(dir / "sub"))
    writeFile(extendedPath(dir / "sub" / "c.txt"), "abc")  # 3 bytes
    let baseSize = directorySizeBytes(dir)
    check baseSize == 18  # 5 + 10 + 3

    when defined(windows):
      # Add a junction into a HUGE-content dir; the junction itself
      # adds ~0 bytes (the reparse point only), the target's bytes
      # MUST be excluded from the sum.
      let bigTarget = FixtureRoot / "size-walk-big-target"
      resetDir(bigTarget)
      writeFile(extendedPath(bigTarget / "huge.txt"),
        "x".repeat(10_000))  # 10 KB — would obviously inflate sum
      let j = dir / "junction"
      discard execShellCmd("cmd /c mklink /J " & quoteShell(j) & " " &
        quoteShell(absolutePath(bigTarget)))
      check isJunction(j)
      let sumWithJunction = directorySizeBytes(dir)
      # The junction's reparse point is excluded; only the 18 bytes
      # of REAL files under `dir` are counted.
      check sumWithJunction == baseSize
