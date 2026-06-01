## Minimal `sqlite3` binding for the Reprobuild content-addressed local
## store (M56). Only the procs the store actually uses are bound.
##
## Windows and macOS load the system SQLite shared library at runtime via
## Nim's `dynlib` machinery. Linux links against `libsqlite3`, allowing
## Nix-style rpaths from `config.nims` to make CLI binaries runnable without
## ambient `LD_LIBRARY_PATH`.
##
## This file deliberately keeps the surface tiny so the rest of
## `repro_local_store` operates through a small, well-typed Nim wrapper
## (`Database`, `Statement`) instead of raw FFI pointers.

import std/strutils

# Note about library names: on Windows the Nim distribution ships
# `sqlite3_64.dll` (and on 32-bit hosts `sqlite3_32.dll`) but the Python
# distribution and most "vanilla" Windows tools call it `sqlite3.dll`.
# Nim's `dynlib` pragma supports a `|` alternation, so we list every
# plausible name and the loader takes the first one it finds.
when defined(windows):
  const SqliteLibName = "(sqlite3_64|sqlite3|sqlite3_32).dll"
elif defined(macosx):
  const SqliteLibName = "libsqlite3(|.0).dylib"

const
  SqliteOk* = 0
  SqliteRow* = 100
  SqliteDone* = 101
  SqliteConstraint* = 19
  SqliteBusy* = 5
  SqliteLocked* = 6

  SqliteOpenReadwrite* = 0x00000002
  SqliteOpenCreate* = 0x00000004
  SqliteOpenNoMutex* = 0x00008000
  SqliteOpenUri* = 0x00000040

  SqliteInteger* = 1
  SqliteFloat* = 2
  SqliteText* = 3
  SqliteBlob* = 4
  SqliteNull* = 5

type
  Sqlite3* = pointer
  Sqlite3Stmt* = pointer

  SqliteError* = object of CatchableError
    ## Raised whenever a SQLite primitive returns a non-success error code.
    ## The string message embeds the SQLite-reported reason via
    ## `sqlite3_errmsg`.
    code*: cint

  SqliteDestructor = proc (a: pointer) {.cdecl, gcsafe.}

# ---------------------------------------------------------------------------
# Raw FFI surface. Names match the upstream C API exactly so search engines
# and grep finds across libraries hit consistent terms.
# ---------------------------------------------------------------------------

when defined(windows) or defined(macosx):
  {.push cdecl, dynlib: SqliteLibName, importc.}
else:
  {.passL: "-lsqlite3".}
  {.push cdecl, importc.}

proc sqlite3_open_v2(filename: cstring; ppDb: ptr Sqlite3; flags: cint;
                     zVfs: cstring): cint
proc sqlite3_close_v2(db: Sqlite3): cint
proc sqlite3_errmsg(db: Sqlite3): cstring
proc sqlite3_exec(db: Sqlite3; sql: cstring; callback: pointer; arg: pointer;
                  errmsg: ptr cstring): cint
proc sqlite3_busy_timeout(db: Sqlite3; ms: cint): cint
proc sqlite3_prepare_v2(db: Sqlite3; zSql: cstring; nByte: cint;
                        ppStmt: ptr Sqlite3Stmt; pzTail: ptr cstring): cint
proc sqlite3_step(stmt: Sqlite3Stmt): cint
proc sqlite3_reset(stmt: Sqlite3Stmt): cint
proc sqlite3_finalize(stmt: Sqlite3Stmt): cint
proc sqlite3_clear_bindings(stmt: Sqlite3Stmt): cint
proc sqlite3_bind_int64(stmt: Sqlite3Stmt; idx: cint; v: int64): cint
proc sqlite3_bind_null(stmt: Sqlite3Stmt; idx: cint): cint
proc sqlite3_bind_text(stmt: Sqlite3Stmt; idx: cint; text: cstring;
                       nByte: cint; dtor: SqliteDestructor): cint
proc sqlite3_bind_blob(stmt: Sqlite3Stmt; idx: cint; data: pointer;
                       nByte: cint; dtor: SqliteDestructor): cint
proc sqlite3_column_count(stmt: Sqlite3Stmt): cint
proc sqlite3_column_type(stmt: Sqlite3Stmt; iCol: cint): cint
proc sqlite3_column_int64(stmt: Sqlite3Stmt; iCol: cint): int64
proc sqlite3_column_text(stmt: Sqlite3Stmt; iCol: cint): cstring
proc sqlite3_column_bytes(stmt: Sqlite3Stmt; iCol: cint): cint
proc sqlite3_column_blob(stmt: Sqlite3Stmt; iCol: cint): pointer
proc sqlite3_libversion(): cstring
proc sqlite3_changes(db: Sqlite3): cint
proc sqlite3_last_insert_rowid(db: Sqlite3): int64
proc sqlite3_file_control(db: Sqlite3; zDbName: cstring; op: cint;
                          pArg: pointer): cint

{.pop.}

# Sentinel pointers documented by the SQLite C API. `SQLITE_TRANSIENT`
# tells SQLite to copy the bound buffer before returning (we don't keep
# it alive across calls); `SQLITE_STATIC` would leak the Nim sequence
# data because Nim seq buffers can be moved by the GC.
let SqliteTransient*: SqliteDestructor = cast[SqliteDestructor](-1)

# ---------------------------------------------------------------------------
# Higher-level wrapper
# ---------------------------------------------------------------------------

type
  Database* = object
    handle*: Sqlite3
    path*: string

  Statement* = object
    handle*: Sqlite3Stmt
    db*: Sqlite3

proc raiseSqlite(db: Sqlite3; code: cint; sql: string = "") =
  var detail = $sqlite3_errmsg(db)
  if sql.len > 0:
    detail.add(" (SQL: ")
    detail.add(sql)
    detail.add(")")
  var err = newException(SqliteError,
    "sqlite3 error code " & $code & ": " & detail)
  err.code = code
  raise err

proc libVersion*(): string = $sqlite3_libversion()

proc open*(path: string;
           flags: cint = SqliteOpenReadwrite or SqliteOpenCreate or
             SqliteOpenNoMutex or SqliteOpenUri;
           busyTimeoutMs = 30_000): Database =
  result.path = path
  var handle: Sqlite3
  let rc = sqlite3_open_v2(path.cstring, addr handle, flags, nil)
  if rc != SqliteOk:
    if handle != nil:
      discard sqlite3_close_v2(handle)
    raise newException(SqliteError,
      "sqlite3_open_v2(" & path & ") failed with code " & $rc)
  result.handle = handle
  let bc = sqlite3_busy_timeout(handle, cint(busyTimeoutMs))
  if bc != SqliteOk:
    raiseSqlite(handle, bc, "PRAGMA busy_timeout")

const SqliteFcntlPersistWal* = cint(10)
  ## Op code for sqlite3_file_control's SQLITE_FCNTL_PERSIST_WAL.
  ## Stable across SQLite versions per the C API contract.

proc enablePersistentWal*(db: Database) =
  ## Tell SQLite to keep the auxiliary WAL and shared-memory files
  ## around when the last connection closes. The default behaviour
  ## checkpoints and unlinks both sidecars on close, which means a
  ## daemon that opens-closes-the-store per request leaves behind only
  ## ``index.db``. The local-store spec (``Local-Content-Addressed-
  ## Store.md``) and the M66/M67 daemon-realize tests both expect
  ## ``index.db-wal`` / ``index.db-shm`` to remain on disk between
  ## requests as the "store is in WAL mode" evidence.
  var one: cint = 1
  discard sqlite3_file_control(db.handle, nil, SqliteFcntlPersistWal,
    addr one)

proc close*(db: var Database) =
  if db.handle != nil:
    discard sqlite3_close_v2(db.handle)
    db.handle = nil

proc exec*(db: Database; sql: string) =
  ## Run one or more SQL statements without bindings or row results.
  var errmsg: cstring
  let rc = sqlite3_exec(db.handle, sql.cstring, nil, nil, addr errmsg)
  if rc != SqliteOk:
    var detail = ""
    if errmsg != nil:
      detail = $errmsg
    raise newException(SqliteError,
      "sqlite3_exec failed (" & $rc & "): " & detail & " (SQL: " & sql & ")")

proc prepare*(db: Database; sql: string): Statement =
  ## Compile `sql` and return a reusable statement object.
  var stmt: Sqlite3Stmt
  let rc = sqlite3_prepare_v2(db.handle, sql.cstring, cint(-1), addr stmt, nil)
  if rc != SqliteOk:
    raiseSqlite(db.handle, rc, sql)
  result.handle = stmt
  result.db = db.handle

proc finalize*(s: var Statement) =
  if s.handle != nil:
    discard sqlite3_finalize(s.handle)
    s.handle = nil

proc reset*(s: var Statement) =
  if s.handle != nil:
    discard sqlite3_reset(s.handle)
    discard sqlite3_clear_bindings(s.handle)

proc bindNull*(s: Statement; idx: int) =
  let rc = sqlite3_bind_null(s.handle, cint(idx))
  if rc != SqliteOk:
    raiseSqlite(s.db, rc, "bind_null")

proc bindInt*(s: Statement; idx: int; v: int64) =
  let rc = sqlite3_bind_int64(s.handle, cint(idx), v)
  if rc != SqliteOk:
    raiseSqlite(s.db, rc, "bind_int")

proc bindText*(s: Statement; idx: int; text: string) =
  let rc = sqlite3_bind_text(s.handle, cint(idx), text.cstring,
    cint(text.len), SqliteTransient)
  if rc != SqliteOk:
    raiseSqlite(s.db, rc, "bind_text")

proc bindBlob*(s: Statement; idx: int; data: openArray[byte]) =
  let ptrArg: pointer =
    if data.len == 0: nil
    else: cast[pointer](unsafeAddr data[0])
  let rc = sqlite3_bind_blob(s.handle, cint(idx), ptrArg, cint(data.len),
    SqliteTransient)
  if rc != SqliteOk:
    raiseSqlite(s.db, rc, "bind_blob")

proc step*(s: Statement): cint =
  let rc = sqlite3_step(s.handle)
  if rc != SqliteRow and rc != SqliteDone and rc != SqliteConstraint:
    raiseSqlite(s.db, rc, "step")
  rc

proc columnCount*(s: Statement): int =
  int(sqlite3_column_count(s.handle))

proc columnInt*(s: Statement; idx: int): int64 =
  sqlite3_column_int64(s.handle, cint(idx))

proc columnText*(s: Statement; idx: int): string =
  let raw = sqlite3_column_text(s.handle, cint(idx))
  if raw == nil: "" else: $raw

proc columnBlob*(s: Statement; idx: int): seq[byte] =
  let n = int(sqlite3_column_bytes(s.handle, cint(idx)))
  if n <= 0:
    return @[]
  let p = sqlite3_column_blob(s.handle, cint(idx))
  result = newSeq[byte](n)
  copyMem(addr result[0], p, n)

proc columnIsNull*(s: Statement; idx: int): bool =
  int(sqlite3_column_type(s.handle, cint(idx))) == SqliteNull

proc changes*(db: Database): int =
  int(sqlite3_changes(db.handle))

proc lastInsertRowid*(db: Database): int64 =
  sqlite3_last_insert_rowid(db.handle)

# ---------------------------------------------------------------------------
# Tiny convenience helpers used by callers that only need a single query.
# ---------------------------------------------------------------------------

proc userVersion*(db: Database): int =
  ## Returns `PRAGMA user_version`.
  var stmt = db.prepare("PRAGMA user_version")
  defer: stmt.finalize()
  if stmt.step() == SqliteRow:
    result = int(stmt.columnInt(0))
  else:
    result = 0

proc setUserVersion*(db: Database; v: int) =
  ## `PRAGMA user_version` does not accept bound parameters; build the
  ## statement by string interpolation. The value is trusted (always
  ## generated by the store itself).
  db.exec("PRAGMA user_version = " & $v)

proc quickCheck*(db: Database): string =
  ## Returns the first line of `PRAGMA quick_check`. The SQLite contract
  ## states that a healthy database returns the single text `ok`.
  var stmt = db.prepare("PRAGMA quick_check")
  defer: stmt.finalize()
  if stmt.step() == SqliteRow:
    result = stmt.columnText(0).strip()
  else:
    result = ""
