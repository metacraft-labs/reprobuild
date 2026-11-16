## `.repro/workspace/force-pushes.json` is the recovery record for a rewritten
## remote and cannot be reconstructed once dropped (Workspace-And-Develop-Mode
## .md §"Remote history was rewritten under the checkout"; reprobuild-pm issue
## 2026-11-12-force-pushes-json-recovery-records-are-lost-on-a-torn-write).
##
## THE DEFECT. The file was written with a plain `writeFile` and an
## unparsable file was read as `[]`, so a crash or a concurrent `sync` that
## left invalid JSON made the NEXT write replace every superseded-SHA record.
##
## Asserted:
##   1. An unparsable file is quarantined byte for byte, the reader reports
##      "absent", and the following write does not destroy the bytes.
##   2. A write is all-or-nothing: no temporary file is left behind, and a
##      write whose rename fails leaves the previous file untouched.
##   3. The lock excludes a second holder for the whole load-modify-save
##      cycle.
##
## Test-double policy: no mocks; the real filesystem and real file locks.
## Falsifiability: with the old reader (`parseFile` failing -> `[]`, plain
## `writeFile`) case 1 finds no quarantined copy and the torn bytes gone.
import std/[json, os, sequtils, strutils, unittest]
import repro_core/file_lock
import repro_cli_support/force_push_records

proc scratch(name: string): string =
  result = getTempDir() / ("repro-fp-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / ".repro" / "workspace")

proc quarantined(root: string): seq[string] =
  for f in walkFiles(forcePushesPath(root) & ".corrupt-*"):
    result.add(f)

suite "force-pushes.json survives a torn write":

  test "an unparsable file is quarantined, not replaced":
    let root = scratch("torn")
    defer: removeDir(root)
    let torn = "[{\"repo\": \"a\", \"superseded\": \"" & repeat('a', 40) & "\"},\n{\"re"
    writeFile(forcePushesPath(root), torn)
    check readForcePushesNode(forcePushesPath(root)).isNil
    let q = quarantined(root)
    check q.len == 1
    check readFile(q[0]) == torn
    check not fileExists(forcePushesPath(root))
    writeForcePushesAtomic(forcePushesPath(root), "[]\n")
    check readFile(q[0]) == torn

  test "a second quarantine never overwrites the first":
    let root = scratch("twice")
    defer: removeDir(root)
    for i in 1 .. 2:
      writeFile(forcePushesPath(root), "{torn " & $i)
      check readForcePushesNode(forcePushesPath(root)).isNil
    check quarantined(root).mapIt(readFile(it)).len == 2

  test "a valid file is read and an absent one is nil":
    let root = scratch("valid")
    defer: removeDir(root)
    check readForcePushesNode(forcePushesPath(root)).isNil
    writeForcePushesAtomic(forcePushesPath(root), "[1]\n")
    check readForcePushesNode(forcePushesPath(root)) == %[1]
    check quarantined(root).len == 0

  test "an atomic write leaves no temporary file and keeps the old file on failure":
    let root = scratch("atomic")
    defer: removeDir(root)
    let path = forcePushesPath(root)
    writeForcePushesAtomic(path, "[\"old\"]\n")
    check readFile(path) == "[\"old\"]\n"
    check toSeq(walkFiles(path & ".tmp-*")).len == 0
    # Force the rename to fail: the target is a non-empty directory.
    let blocked = root / "blocked.json"
    createDir(blocked)
    writeFile(blocked / "x", "x")
    expect CatchableError:
      writeForcePushesAtomic(blocked, "[\"new\"]\n")
    check dirExists(blocked) and fileExists(blocked / "x")
    check toSeq(walkFiles(blocked & ".tmp-*")).len == 0

  test "the lock excludes a second holder across a load-modify-save cycle":
    let root = scratch("lock")
    defer: removeDir(root)
    var other: ReproFileLock
    withForcePushesLock(root):
      check not tryAcquireExclusiveFileLock(
        forcePushesPath(root) & ".lock", other)
    check tryAcquireExclusiveFileLock(forcePushesPath(root) & ".lock", other)
    releaseExclusiveFileLock(other)
