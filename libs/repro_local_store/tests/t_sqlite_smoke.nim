## Smoke test for the M56 SQLite binding and store skeleton. This is
## not the verification gate — it exists so the binding can be checked
## fast during development.

import std/[os, tempfiles, unittest]

import repro_local_store

suite "sqlite_binding_smoke":
  test "library version is populated":
    let v = libVersion()
    check v.len > 0

  test "open and exec on a real temp file":
    let dir = createTempDir("repro-store-smoke-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    var db = sqlite3_binding.open(dir / "smoke.db")
    defer: db.close()
    db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)")
    var stmt = db.prepare("INSERT INTO t(name) VALUES (?)")
    stmt.bindText(1, "alpha")
    check stmt.step() == SqliteDone
    stmt.finalize()
    var sel = db.prepare("SELECT id, name FROM t")
    defer: sel.finalize()
    check sel.step() == SqliteRow
    check sel.columnInt(0) == 1
    check sel.columnText(1) == "alpha"

  test "openStore creates layout":
    let dir = createTempDir("repro-store-layout-", "")
    defer:
      try: removeDir(dir) except OSError: discard
    var s = openStore(dir / "store")
    defer: s.close()
    check dirExists(s.casRoot)
    check dirExists(s.prefixesRoot)
    check dirExists(s.tmpRoot)
    check dirExists(s.gcPendingRoot)
    check fileExists(s.indexPath)
    check s.db.userVersion() == StoreSchemaVersion
