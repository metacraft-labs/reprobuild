## `repro build --publish` does not publish an installed prefix built from a
## modified tree (reprobuild-pm Distribution-And-Packaging.md §5.3: "A dirty
## tree is allowed for a development build: the record marks it `-dirty`.
## `repro build --publish` refuses a dirty prefix.").
##
## The decision is `prefixRecordDirtyLines` over the prefix's real build
## record, written here into a temp dir; `publishBuildForProfileEdge` refuses
## when it returns anything, before deriving a key or loading a key pair.

import std/[os, tempfiles, unittest]

import repro_cli_support/infra

suite "a dirty prefix is not published":
  test "a record naming -dirty anywhere is reported line by line":
    let root = createTempDir("dirty-prefix-", "")
    defer: removeDir(root)
    createDir(root / "share" / "repro")
    writeFile(root / "share" / "repro" / "cross-build-info",
      "triple=armv7-unknown-linux-gnueabihf\n" &
      "source_revision=abc123-dirty\n" &
      "source IO_MON_SRC=io-mon/src def456\n" &
      "source SHM_QUEUE_SRC=nim-shm-queue/src 789abc-dirty\n")
    check prefixRecordDirtyLines(root) == @[
      "source_revision=abc123-dirty",
      "source SHM_QUEUE_SRC=nim-shm-queue/src 789abc-dirty"]

  test "a clean record, and a tree with no record, are not refused":
    let root = createTempDir("clean-prefix-", "")
    defer: removeDir(root)
    check prefixRecordDirtyLines(root).len == 0
    createDir(root / "share" / "repro")
    writeFile(root / "share" / "repro" / "cross-build-info",
      "triple=x\nsource_revision=abc123\n")
    check prefixRecordDirtyLines(root).len == 0
