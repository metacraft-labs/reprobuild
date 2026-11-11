## Concurrent first opens of one store wait for each other.
##
## `openStore` on a fresh store switches its index to WAL mode. That switch
## reads the database header and then upgrades its read lock to a write lock,
## and SQLite never calls the busy handler for such an upgrade while another
## connection holds the write lock: it returns SQLITE_BUSY at once
## (https://www.sqlite.org/c3ref/busy_handler.html). The store's 30 s busy
## timeout therefore did not cover it, and of several `repro` processes that
## opened one new store together, the ones that lost the race failed with
## "database is locked (SQL: PRAGMA journal_mode = WAL)" instead of waiting.
##
## The first test reproduces the losing position deterministically: another
## connection holds the write lock of the fresh index when `openStore` runs,
## and releases it a moment later. The second opens one fresh store from
## several threads at once, which is the race as `repro` processes met it.

import std/[atomics, os, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_local_store

const HoldMs = 1_000

var lockHeld: Atomic[bool]
var failedOpens: Atomic[int]

proc holdWriteLock(indexPath: string) {.thread.} =
  ## Take the fresh index's write lock the way a competing opener does, and
  ## let it go after `HoldMs`.
  var db = sqlite3_binding.open(indexPath)
  db.exec("BEGIN IMMEDIATE")
  lockHeld.store(true)
  sleep(HoldMs)
  db.exec("COMMIT")
  db.close()

proc openAndClose(root: string) {.thread.} =
  ## An exception may not leave a thread, so a failed open is counted.
  try:
    var store = openStore(root)
    store.close()
  except CatchableError:
    failedOpens.atomicInc()

proc journalMode(indexPath: string): string =
  var db = sqlite3_binding.open(indexPath)
  defer: db.close()
  var q = db.prepare("PRAGMA journal_mode")
  defer: q.finalize()
  if q.step() == SqliteRow:
    result = q.columnText(0)

suite "store concurrent first open":
  test "an opener that finds the fresh index write-locked waits for it":
    let dir = createTempDir("repro-store-first-open-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let root = dir / "store"
    createDir(root)
    let indexPath = root / "index.db"

    lockHeld.store(false)
    var holder: Thread[string]
    createThread(holder, holdWriteLock, indexPath)
    while not lockHeld.load():
      sleep(5)

    let started = epochTime()
    var failure = ""
    try:
      var store = openStore(root)
      store.close()
    except CatchableError as err:
      failure = err.msg
    let waitedMs = int((epochTime() - started) * 1000)
    joinThread(holder)

    check failure == ""
    # It got the index by waiting for the holder, not by racing past it.
    check waitedMs >= HoldMs div 2
    check journalMode(indexPath) == "wal"

  test "several openers of one fresh store all open it":
    const Openers = 8
    for round in 0 ..< 5:
      let dir = createTempDir("repro-store-first-open-race-", "")
      defer:
        try: removeDir(extendedPath(dir)) except OSError: discard
      let root = dir / "store"
      failedOpens.store(0)
      var openers: array[Openers, Thread[string]]
      for i in 0 ..< Openers:
        createThread(openers[i], openAndClose, root)
      joinThreads(openers)
      check failedOpens.load() == 0

      var store = openStore(root)
      defer: store.close()
      check journalMode(store.indexPath) == "wal"
      var row = PrefixRow(packageName: "probe", version: "1",
        realizedPath: "prefixes/probe-1", adapter: "probe",
        createdAtUnix: getTime().toUnix)
      row.prefixId[0] = byte(round + 1)
      check store.insertPrefixOrIgnore(row)
