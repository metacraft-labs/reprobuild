## A provisioning receipt is published without ever changing the bytes a
## reader is holding, and republishing the same receipt leaves it alone.
##
## reprobuild-pm issue 2026-11-08 "concurrent provisioning of one tool races
## on its receipt": several `repro` processes provisioning the same tool into
## one tool store each write the same receipt file in place
## (`prepareBuiltinFileOutput` + `writeFile`, which truncates first). The
## store then ingests that receipt as an action output by reading it after
## measuring its size, and a reader that meets the truncated or half-written
## file reports `file changed while hashing`, failing the build that had
## provisioned the tool correctly.
##
## MOCK POLICY -- NO MOCKS. Every case drives the real publisher and the real
## file system in a real temporary directory. The reader is an ordinary open
## file handle, and the concurrent ingest goes through the real store
## (`openStore` / `storeFileBlob`) that the engine's output capture uses.

import std/[atomics, os, strutils, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_build_engine
import repro_local_store

const
  FirstReceipt =
    "/nix/store/aaaaaaaa-gcc-15.2.0\n/nix/store/aaaaaaaa-gcc-15.2.0-dev\n"
  SecondReceipt = "/nix/store/bbbbbbbb-gcc-15.2.1\n"
  IngestRounds = 300
  IssueMessage = "file changed while hashing"

var publishFailures: Atomic[int]
var ingestFailures: Atomic[int]
var stopPublishing: Atomic[bool]

proc republishUntilStopped(receipt: string) {.thread.} =
  ## Another provisioner of the same tool, publishing the same receipt again
  ## and again while the ingest below runs.
  while not stopPublishing.load():
    try:
      publishBuiltinFileOutput(receipt, FirstReceipt)
    except CatchableError:
      publishFailures.atomicInc()

proc receiptIn(root: string): string =
  ## The receipt path a tool store gives one tool request.
  root / "receipts" / "nix-tool-provision.gcc.0123456789ab.receipt"

suite "a provisioning receipt is republished without disturbing a reader":
  test "a reader that began before a republish reads the bytes it began with":
    # The receipt names a different realization, so its length changes. The
    # reader opened the old file before the republish; it must read the old
    # bytes to the end, as a store ingest of the old receipt does.
    let root = createTempDir("repro-receipt-publish-", "")
    defer: removeDir(root)
    let receipt = receiptIn(root)
    publishBuiltinFileOutput(receipt, FirstReceipt)
    var reader = open(extendedPath(receipt), fmRead)
    defer: reader.close()
    publishBuiltinFileOutput(receipt, SecondReceipt)
    check reader.readAll() == FirstReceipt
    check readFile(extendedPath(receipt)) == SecondReceipt

  test "republishing identical receipt text leaves the file untouched":
    let root = createTempDir("repro-receipt-publish-", "")
    defer: removeDir(root)
    let receipt = receiptIn(root)
    publishBuiltinFileOutput(receipt, FirstReceipt)
    let written = getLastModificationTime(extendedPath(receipt))
    # Filesystem timestamps are not compared across an interval shorter than
    # their resolution; the gap makes a rewrite visible as a new timestamp.
    sleep(20)
    publishBuiltinFileOutput(receipt, FirstReceipt)
    check getLastModificationTime(extendedPath(receipt)) == written
    check readFile(extendedPath(receipt)) == FirstReceipt

  test "ingesting a receipt while others republish it does not fail":
    # The issue's case: the same tool, the same pin, so every provisioner
    # writes the same bytes. Each round measures the size and ingests the
    # file the way the engine's output capture does; a round that fails has
    # met a receipt another provisioner was rewriting.
    let root = createTempDir("repro-receipt-publish-", "")
    defer: removeDir(root)
    let receipt = receiptIn(root)
    publishBuiltinFileOutput(receipt, FirstReceipt)
    var store = openStore(root / "store")
    defer: store.close()
    stopPublishing.store(false)
    publishFailures.store(0)
    ingestFailures.store(0)
    var writer: Thread[string]
    createThread(writer, republishUntilStopped, receipt)
    try:
      for round in 0 ..< IngestRounds:
        try:
          discard store.storeFileBlob(receipt,
            uint64(getFileSize(extendedPath(receipt))))
        except CatchableError as err:
          if not err.msg.startsWith(IssueMessage):
            raise
          ingestFailures.atomicInc()
    finally:
      stopPublishing.store(true)
      joinThread(writer)
    check publishFailures.load() == 0
    check ingestFailures.load() == 0
