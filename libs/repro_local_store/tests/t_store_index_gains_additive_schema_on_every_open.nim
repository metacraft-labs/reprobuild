## A store index gains the ADDITIVE schema (the last-use columns, the cached
## prefix size, the published tree digest, `cas_use`, `adapter_installs`,
## `prefix_references`) on
## every open, by introspection, and never through `user_version`.
##
## Spec: reprobuild-pm `spec/CLI/store/gc.md` §Budget Mode and
## `spec/Shared-Store-Budgeted-Eviction.md` §6: these additions are
## additive, so `user_version` is NOT bumped and an older build that opens a
## shared store keeps working. `spec/Local-Content-Addressed-Store.md`
## §Schema reserves the version bump for changes that need a migration.
## Issue: reprobuild-pm
## `issues/2026-11-12-budget-gc-deliberately-skips-the-user-version-bump.md`.
##
## The hazard that rule has to survive: an OLDER build -- one that predates
## the additions -- rebuilds a corrupt index. It recreates the tables it
## knows, without the additions, and stamps the same `user_version`. A newer
## build opening that index cannot tell from the version that anything is
## missing, so it must look at the tables every time it opens one. The first
## case recreates exactly that sequence and then drives every reader and
## writer of the additions, ending with the budget collector.
##
## MOCK POLICY: none. Every case runs a real `Store` on a real temporary
## directory through `openStore` / `realizeDirectoryAsPrefix`. The older
## build cannot be run, so its index is written with raw SQL through the
## store's own `sqlite3_binding`: `OlderBuildSchemaSql` below is a frozen
## literal of the v1 schema as such a build wrote it, deliberately NOT
## derived from the current `SchemaSql`, because it stands for a binary that
## no longer changes. Time is injected (`now` / `nowUnix`), never slept.
##
## Each eviction claim is paired with prefixes that must SURVIVE the same
## run, so a collector that deleted everything, or nothing, fails.

import std/[os, sequtils, strutils, tables, times, unittest]

from repro_core/paths import extendedPath
from repro_test_support/process_fixtures import releaseDirAtProcessExit

import repro_local_store
import repro_local_store/budget_gc
import repro_local_store/sqlite3_binding

const
  Day = 24 * 3600'i64
  KiB = 1024

  ## The index schema as a build predating the additive columns wrote it
  ## (user_version 1). A literal on purpose: see MOCK POLICY.
  OlderBuildSchemaSql = """
CREATE TABLE IF NOT EXISTS prefixes (
    prefix_id BLOB PRIMARY KEY,
    package_name TEXT NOT NULL,
    version TEXT NOT NULL,
    realized_path TEXT NOT NULL UNIQUE,
    adapter TEXT NOT NULL,
    receipt_digest BLOB NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_prefixes__package_version
    ON prefixes(package_name, version);

CREATE TABLE IF NOT EXISTS roots (
    root_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    holder_uid INTEGER,
    ttl_seconds INTEGER,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS root_holds_prefix (
    root_id TEXT NOT NULL REFERENCES roots(root_id) ON DELETE CASCADE,
    prefix_id BLOB NOT NULL REFERENCES prefixes(prefix_id) ON DELETE CASCADE,
    PRIMARY KEY (root_id, prefix_id)
);
CREATE INDEX IF NOT EXISTS idx_root_holds_prefix__prefix
    ON root_holds_prefix(prefix_id);

CREATE TABLE IF NOT EXISTS gc_audit (
    audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    action TEXT NOT NULL,
    prefix_id BLOB,
    reason TEXT
);
"""

  ## The INSERT the older build's recovery ran: only the v1 columns.
  OlderBuildPrefixInsertSql =
    "INSERT INTO prefixes(prefix_id, package_name, version, realized_path, " &
    "adapter, receipt_digest, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)"

  AdditivePrefixColumns = ["last_used_at", "size_bytes", "content_digest"]
  AdditiveTables = ["cas_use", "adapter_installs", "prefix_references"]

var fixtureSeq = 0

proc scratchRoot(tag: string): string =
  ## A directory owned by THIS process and removed when it exits, whichever
  ## cases it ran. Registered before it exists, so it is never left unowned.
  inc fixtureSeq
  result = getTempDir() / ("repro-additive-schema-" & $getCurrentProcessId() &
    "-" & tag & "-" & $fixtureSeq)
  releaseDirAtProcessExit(result)
  createDir(extendedPath(result))

proc payloadOf(name: string; size: int): string =
  result = newString(size)
  for i in 0 ..< size:
    result[i] = char((i * 31 + name.len * 7919 + int(name[0])) and 0x7f)

proc realize(s: var Store; root, name: string; size = 64 * KiB): PrefixIdBytes =
  let stage = root / "stage" / name
  createDir(extendedPath(stage / "bin"))
  writeFile(stage / "bin" / "tool", payloadOf(name, size))
  let hint = StoreReceiptHint(adapter: "path", packageName: name,
    version: "1.0", declaredExecutablePath: "bin/tool",
    lockIdentity: "additive-schema-test")
  realizeDirectoryAsPrefix(s, stage, hint).prefixId

proc ageCreation(s: Store; id: PrefixIdBytes; createdAt: int64) =
  ## Move a prefix's creation (and so its default last use) into the past.
  var u = s.db.prepare(
    "UPDATE prefixes SET created_at = ?, last_used_at = NULL WHERE prefix_id = ?")
  defer: u.finalize()
  u.bindInt(1, createdAt)
  u.bindBlob(2, id)
  discard u.step()

proc prefixColumns(db: Database): seq[string] =
  var q = db.prepare("PRAGMA table_info(prefixes)")
  defer: q.finalize()
  while q.step() == SqliteRow:
    result.add(q.columnText(1))

proc tableNames(db: Database): seq[string] =
  var q = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
  defer: q.finalize()
  while q.step() == SqliteRow:
    result.add(q.columnText(0))

proc rawUserVersion(indexPath: string): int =
  ## `user_version` as any opener (including an older build) reads it.
  var db = sqlite3_binding.open(indexPath)
  defer: db.close()
  db.userVersion()

proc rebuildIndexAsOlderBuild(storeRoot: string; rows: openArray[PrefixRow]) =
  ## What an older build's corrupt-index recovery leaves behind: the index
  ## and its WAL sidecars gone, a fresh index with the v1 tables only at
  ## `user_version` 1, and each prefix found on disk re-inserted through
  ## the v1 columns.
  let indexPath = storeRoot / "index.db"
  for suffix in ["", "-wal", "-shm"]:
    removeFile(extendedPath(indexPath & suffix))
  var db = sqlite3_binding.open(indexPath)
  defer: db.close()
  db.exec("PRAGMA journal_mode = WAL")
  db.exec("BEGIN IMMEDIATE")
  db.exec(OlderBuildSchemaSql)
  db.exec("PRAGMA user_version = 1")
  for row in rows:
    var ins = db.prepare(OlderBuildPrefixInsertSql)
    defer: ins.finalize()
    ins.bindBlob(1, row.prefixId)
    ins.bindText(2, row.packageName)
    ins.bindText(3, row.version)
    ins.bindText(4, row.realizedPath)
    ins.bindText(5, row.adapter)
    ins.bindBlob(6, row.receiptDigest)
    ins.bindInt(7, row.createdAtUnix)
    doAssert ins.step() == SqliteDone
  db.exec("COMMIT")
  # The fixture is only valid if it really lacks the additions.
  for column in AdditivePrefixColumns:
    doAssert column notin db.prefixColumns()
  for table in AdditiveTables:
    doAssert table notin db.tableNames()

proc olderBuildCanStillUse(indexPath: string): bool =
  ## An older build opening the index after a newer one has: it accepts
  ## `user_version` <= 1 and names only the v1 columns in what it runs.
  var db = sqlite3_binding.open(indexPath)
  defer: db.close()
  if db.userVersion() > 1:
    return false
  var id: PrefixIdBytes
  for i in 0 ..< id.len:
    id[i] = byte(0xA5)
  var ins = db.prepare(OlderBuildPrefixInsertSql)
  ins.bindBlob(1, id)
  ins.bindText(2, "older-build-row")
  ins.bindText(3, "0.1")
  ins.bindText(4, "prefixes/older-build-row")
  ins.bindText(5, "path")
  ins.bindBlob(6, id)
  ins.bindInt(7, 1_700_000_000)
  let inserted = ins.step() == SqliteDone
  ins.finalize()
  var sel = db.prepare(
    "SELECT package_name, version, realized_path, adapter, created_at " &
    "FROM prefixes WHERE prefix_id = ?")
  sel.bindBlob(1, id)
  let found = sel.step() == SqliteRow and
    sel.columnText(0) == "older-build-row" and sel.columnInt(4) == 1_700_000_000
  sel.finalize()
  var del = db.prepare("DELETE FROM prefixes WHERE prefix_id = ?")
  del.bindBlob(1, id)
  discard del.step()
  del.finalize()
  inserted and found

suite "store index gains the additive schema on every open":

  test "an index an older build rebuilt at the same user_version gets the additions back":
    let root = scratchRoot("older-rebuild")
    let storeRoot = root / "store"
    let indexPath = storeRoot / "index.db"

    # 1. A newer build realizes a prefix and records its use.
    var recovered: PrefixRow
    var survivor: PrefixIdBytes
    block:
      var s = openStore(storeRoot)
      defer: s.close()
      survivor = s.realize(root, "survivor")
      let created = s.prefixLastUsed(survivor)
      check s.touchPrefix(survivor, now = created + 2 * Day)
      check s.prefixLastUsed(survivor) == created + 2 * Day
      let found = s.lookupPrefix(survivor)
      check found.found
      recovered = found.row

    # 2. An older build rebuilds the index after corruption.
    rebuildIndexAsOlderBuild(storeRoot, [recovered])
    check rawUserVersion(indexPath) == 1

    # 3. The newer build opens it again.
    var s = openStore(storeRoot)
    defer: s.close()

    let version = s.db.userVersion()
    checkpoint("user_version after reopen: " & $version)
    check version == 1
    check version == StoreSchemaVersion

    let columns = s.db.prefixColumns()
    checkpoint("prefixes columns after reopen: " & columns.join(", "))
    for column in AdditivePrefixColumns:
      check column in columns
    let tables = s.db.tableNames()
    checkpoint("tables after reopen: " & tables.join(", "))
    for table in AdditiveTables:
      check table in tables

    # The recovered row reads as "last used when created" until a use is
    # recorded; `touchPrefix` drops its own errors, so the effect is checked.
    let created = recovered.createdAtUnix
    check s.prefixLastUsed(survivor) == created
    check s.touchPrefix(survivor, now = created + 3 * Day)
    check s.prefixLastUsed(survivor) == created + 3 * Day

    # A CAS use is recorded in `cas_use`.
    let digest = s.storeCasBlob("additive schema blob".toOpenArrayByte(0, 19))
    setLastModificationTime(storeRoot / casBlobRelative(digest),
      fromUnix(getTime().toUnix - 5 * Day))
    check s.touchCasBlob(digest)
    check s.casLastUseTable().getOrDefault(hexOf(digest), 0) >
      getTime().toUnix - 60

    # The install-provenance ledger records and reads back.
    s.recordAdapterInstall("scoop", root / "scoop", "tool", "1.2.3",
      "dev:1/ino:2", "bucket main")
    check s.adapterInstallIdentity("scoop", root / "scoop", "tool",
      "1.2.3") == "dev:1/ino:2"

    # An older build can still open the index and run what it ran.
    check olderBuildCanStillUse(indexPath)
    check rawUserVersion(indexPath) == 1

    # The budget collector runs over the store: the aged dead prefix goes;
    # a held one and a recently used one stay.
    let now = getTime().toUnix
    let aged = s.realize(root, "aged")
    let recent = s.realize(root, "recent")
    s.ageCreation(aged, now - 10 * Day)
    s.ageCreation(survivor, now - 20 * Day)
    s.registerRoot("profile", rkProfile)
    s.attachPrefixToRoot("profile", survivor)
    let r = budgetGc(storeRoot, BudgetGcPolicy(budgetBytes: 1, targetBytes: 1,
      keepRecentSeconds: Day, nowUnix: now, graceSeconds: 1))
    checkpoint(renderBudgetGcText(r, storeRoot))
    check r.evicted.len == 1
    check r.evicted.len == 1 and r.evicted[0].kind == bokPrefix and
      r.evicted[0].id.contains("/aged/")
    check not s.lookupPrefix(aged).found
    check s.lookupPrefix(survivor).found
    check s.lookupPrefix(recent).found
    check s.db.userVersion() == StoreSchemaVersion

  test "reopening an index that carries the additions never bumps user_version":
    let root = scratchRoot("reopen")
    let storeRoot = root / "store"
    let indexPath = storeRoot / "index.db"
    var id: PrefixIdBytes
    block:
      var s = openStore(storeRoot)
      defer: s.close()
      id = s.realize(root, "pkg")
      for column in AdditivePrefixColumns:
        check column in s.db.prefixColumns()
    for round in 1 .. 3:
      var s = openStore(storeRoot)
      defer: s.close()
      checkpoint("reopen round " & $round)
      check s.db.userVersion() == 1
      check s.db.userVersion() == StoreSchemaVersion
      let columns = s.db.prefixColumns()
      for column in AdditivePrefixColumns:
        check columns.count(column) == 1
      let tables = s.db.tableNames()
      for table in AdditiveTables:
        check table in tables
      check s.lookupPrefix(id).found
    check rawUserVersion(indexPath) == 1
    check olderBuildCanStillUse(indexPath)
