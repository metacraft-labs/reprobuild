## A use record that loses the race for the index lock must leave the store's
## connection as it found it.
##
## `touchCasBlob` does not wait for the lock: when another connection is
## writing, its write fails with SQLITE_BUSY and the use is not recorded.
## SQLite leaves a statement that stopped on SQLITE_BUSY suspended, and still
## counted as an active writer of its connection. Before the fix that statement
## was neither reset nor finalized, so the connection's NEXT write --
## `insertPrefixOrIgnore` here, any index write in a real process -- never
## committed: it held the WAL write lock until the process exited, and every
## other process writing the same store failed with "database is locked" after
## its 30 s busy timeout (full suite run 48, bootstrap C-compiler provisioning
## against the shared tool store).

import std/[os, tempfiles, times, unittest]
from repro_core/paths import extendedPath

import repro_local_store

suite "store use record lost to a writer":
  test "the next write on the connection commits and releases the lock":
    let dir = createTempDir("repro-store-use-busy-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    var store = openStore(dir / "store")
    defer: store.close()
    let digest = store.storeCasBlob(@[1'u8, 2, 3])

    # Another connection holds the write lock while the use is recorded. Its
    # short busy timeout is what the lock check below waits at most.
    var other = sqlite3_binding.open(store.indexPath, busyTimeoutMs = 2_000)
    defer: other.close()
    other.exec("BEGIN IMMEDIATE")
    let later = getTime().toUnix + 2 * LastUseResolutionSeconds
    # The record is stale at `later`, so the touch reaches its write and
    # loses the race for the lock.
    require not store.touchCasBlob(digest, later)
    other.exec("COMMIT")

    var row = PrefixRow(packageName: "probe", version: "1",
      realizedPath: "prefixes/probe-1", adapter: "probe",
      createdAtUnix: getTime().toUnix)
    row.prefixId[0] = 7
    check store.insertPrefixOrIgnore(row)

    # The insert committed: another connection sees it ...
    var seen = other.prepare("SELECT count(*) FROM prefixes WHERE prefix_id = ?")
    seen.bindBlob(1, row.prefixId)
    check seen.step() == SqliteRow
    check seen.columnInt(0) == 1
    seen.finalize()

    # ... and can take the write lock the insert held.
    var locked = ""
    try:
      other.exec("BEGIN IMMEDIATE")
      other.exec("COMMIT")
    except SqliteError as err:
      locked = err.msg
    check locked == ""

    # The use the lost race skipped is recorded once the lock is free.
    check store.touchCasBlob(digest, later)
