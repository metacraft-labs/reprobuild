## Reprobuild content-addressed local store (M56 — Local-Content-Addressed-Store.md).
##
## Layout under `<store-root>/`:
##
##   cas/blake3/<aa>/<full-hash>   sharded BLAKE3-256 blobs
##   prefixes/<package>/<version>-<realization-hash>/
##                                  human-friendly realized prefixes
##   index.db                       SQLite store index (WAL mode)
##   tmp/<random>/                  staging dirs for atomic materialization
##   gc/pending-deletion/<name>/    reaped prefixes awaiting unlink
##
## Schema is exactly the four tables in the spec: `prefixes`, `roots`,
## `root_holds_prefix`, `gc_audit`. Schema version is tracked via
## `PRAGMA user_version`.
##
## The store deliberately does NOT use per-prefix lockfiles: the atomic
## `moveFile` of the staging directory plus the `INSERT OR IGNORE INTO
## prefixes(...)` row insert are the on-disk serialization points.
##
## All `cas/` reads verify the BLAKE3-256 digest of the bytes against the
## requested key before returning to the caller — the hash-on-read
## contract from the spec is enforced by `readCasBlob` / `materializeBlob`.

import std/[os, random, strutils, times]

import blake3
import repro_core

import ./sqlite3_binding
# We use the binding's public symbols unqualified throughout. They are
# all `sqlite3_*` named or prefixed (`SqliteOk`, `Database`, ...) so
# there is no name conflict with the rest of `repro_local_store`.

# ---------------------------------------------------------------------------
# Public types and errors
# ---------------------------------------------------------------------------

type
  StoreError* = object of CatchableError
    ## Base type for every error the store may raise to its callers.

  EStoreSchemaTooNew* = object of StoreError
    ## The on-disk `index.db` has a `PRAGMA user_version` higher than the
    ## one this build of Reprobuild understands. Refuses to write.

  EStoreIndexCorrupt* = object of StoreError
    ## `PRAGMA quick_check` returned anything other than `ok` at open.

  ECasMissing* = object of StoreError
    ## A blob the caller asked for is not present in `cas/`.

  ECasDigestMismatch* = object of StoreError
    ## A blob's bytes did not hash to the requested BLAKE3-256 key.

  EReceiptMissing* = object of StoreError
  EReceiptCorrupt* = object of StoreError
  EReceiptMismatch* = object of StoreError
    ## The realization-hash recorded in a prefix's `.repro-receipt` does
    ## not match the prefix's directory name. Quarantined to
    ## `gc/pending-deletion/`.

  PrefixIdBytes* = array[32, byte]
    ## A BLAKE3-256 realization hash, the canonical primary key for the
    ## `prefixes` table.

  AdapterName* = enum
    ## The on-disk `adapter` column is a free-form text so future
    ## adapters add themselves by name without a schema change, but the
    ## three v1 adapters are enumerated here for type-safe dispatch.
    anUnknown = "unknown"
    anPath = "path"
    anNix = "nix"
    anTarball = "tarball"
    anScoop = "scoop"

  RealizationReceipt* = object
    ## The typed payload sealed into every realized prefix as
    ## `.repro-receipt`. The on-disk encoding is the canonical binary
    ## envelope below; the JSON form is for `repro store dump`.
    schemaVersion*: uint16
    adapter*: string
    packageName*: string
    version*: string
    realizationHash*: PrefixIdBytes
    realizedPath*: string
    declaredExecutablePath*: string
    exportedExecutables*: seq[string]
    lockIdentity*: string
    provenanceUrl*: string
    provenanceChecksum*: string
    materializationMechanism*: string  ## "hardlink" | "reflink" | "copy" |
                                       ## "directory" (debug hint only)
    createdAtUnix*: int64
    writerProcessId*: int64
    writerMode*: string                ## "direct" | "daemon"

  PrefixRow* = object
    ## One row in the `prefixes` table.
    prefixId*: PrefixIdBytes
    packageName*: string
    version*: string
    realizedPath*: string              ## relative to store-root, forward
                                       ## slashes
    adapter*: string
    receiptDigest*: PrefixIdBytes
    createdAtUnix*: int64

  RootKind* = enum
    rkUnknown = "unknown"
    rkProfile = "profile"
    rkWorkspace = "workspace"
    rkSession = "session"
    rkPin = "pin"

  RootRow* = object
    rootId*: string
    kind*: string
    holderUid*: int64
    hasHolderUid*: bool
    ttlSeconds*: int64
    hasTtl*: bool
    createdAtUnix*: int64

  GcAction* = enum
    gaQuarantine = "quarantine"
    gaReclaim = "reclaim"
    gaRestore = "restore"

  GcAuditRow* = object
    auditId*: int64
    timestampUnix*: int64
    action*: string
    prefixId*: PrefixIdBytes
    hasPrefixId*: bool
    reason*: string

  GcReport* = object
    ## Returned by `gc` so callers (the CLI command, tests) can inspect
    ## which prefixes moved and which were unlinked.
    quarantined*: seq[PrefixRow]
    quarantinedPaths*: seq[string]
    reclaimed*: seq[string]
    graceSeconds*: int

  StoreReceiptHint* = object
    ## Hint passed to `realizePrefix` so the adapter does not have to
    ## know about receipt envelope details. The store fills in
    ## realization-hash, paths, and timestamps.
    adapter*: string
    packageName*: string
    version*: string
    declaredExecutablePath*: string
    exportedExecutables*: seq[string]
    lockIdentity*: string
    provenanceUrl*: string
    provenanceChecksum*: string
    materializationMechanism*: string

  Store* = object
    root*: string
    casRoot*: string
    prefixesRoot*: string
    tmpRoot*: string
    gcPendingRoot*: string
    indexPath*: string
    db*: Database
    rng*: Rand

  RecoverReport* = object
    sweptStagingDirs*: seq[string]
    reinsertedPrefixes*: seq[string]
    quarantinedPrefixes*: seq[string]
    quickCheck*: string

const
  StoreSchemaVersion* = 1
  ReceiptFileName* = ".repro-receipt"
  ReceiptMagic* = "RPRC"                ## envelope magic
  ReceiptFormatVersion* = 1'u16
  DefaultGcGraceSeconds* = 5 * 60       ## five minutes per the spec
  StoreRootEnvVar* = "REPRO_STORE_ROOT"

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

proc defaultUserStoreRoot*(): string =
  ## OS-XDG style per-user store root.
  let explicit = getEnv(StoreRootEnvVar)
  if explicit.len > 0:
    return explicit
  when defined(windows):
    let local = getEnv("LOCALAPPDATA")
    if local.len > 0:
      return local / "repro" / "store"
    let home = getEnv("USERPROFILE")
    if home.len > 0:
      return home / "AppData" / "Local" / "repro" / "store"
    raise newException(StoreError,
      "neither LOCALAPPDATA nor USERPROFILE is set; cannot resolve a " &
      "per-user store root on Windows")
  elif defined(macosx):
    let home = getEnv("HOME")
    if home.len == 0:
      raise newException(StoreError,
        "HOME is not set; cannot resolve a per-user store root on macOS")
    home / "Library" / "Caches" / "repro" / "store"
  else:
    let xdg = getEnv("XDG_CACHE_HOME")
    let base =
      if xdg.len > 0: xdg
      else:
        let home = getEnv("HOME")
        if home.len == 0:
          raise newException(StoreError,
            "neither XDG_CACHE_HOME nor HOME is set; cannot resolve a " &
            "per-user store root")
        home / ".cache"
    base / "repro" / "store"

proc resolveStoreRoot*(explicit = ""): string =
  ## Returns the store root with the documented precedence:
  ## explicit CLI override > `$REPRO_STORE_ROOT` > OS default.
  if explicit.len > 0:
    return explicit
  defaultUserStoreRoot()

proc toForwardSlash(value: string): string =
  result = value
  for i in 0 ..< result.len:
    if result[i] == '\\':
      result[i] = '/'

proc safePathSegment*(value, fallback: string): string =
  ## Restricts an arbitrary string to a portable filesystem segment. We
  ## allow alphanumerics, `-`, `_`, `.` and pass everything else through
  ## an underscore. Empty input falls back to `fallback`.
  for ch in value:
    if ch in {'a' .. 'z'} or ch in {'A' .. 'Z'} or ch in {'0' .. '9'} or
        ch in {'-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = fallback

proc hexOf*(bytes: openArray[byte]): string =
  ## Lower-case hex of the supplied byte sequence.
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc prefixIdHex*(p: PrefixIdBytes): string = hexOf(p)

proc realizationDirName*(version: string; prefixId: PrefixIdBytes): string =
  ## Directory name `<version>-<hash-prefix>`. We use the first 16 hex
  ## chars (64 bits) of the realization hash — enough to be collision
  ## resistant in a personal store while remaining human readable.
  let cleanVersion = safePathSegment(version, "v0")
  cleanVersion & "-" & hexOf(prefixId)[0 ..< 16]

proc prefixRelativePath*(packageName, version: string;
                        prefixId: PrefixIdBytes): string =
  ## Returns the canonical relative path under `prefixes/` for the
  ## supplied identity. Always forward-slashed so the SQLite column is
  ## portable across hosts.
  "prefixes/" & safePathSegment(packageName, "pkg") & "/" &
    realizationDirName(version, prefixId)

proc casBlobRelative*(digest: PrefixIdBytes): string =
  let hex = hexOf(digest)
  "cas/blake3/" & hex[0 ..< 2] & "/" & hex

# ---------------------------------------------------------------------------
# Receipt envelope (binary)
# ---------------------------------------------------------------------------

proc writePrefixId(buf: var seq[byte]; id: PrefixIdBytes) =
  for b in id: buf.add(b)

proc readPrefixId(buf: openArray[byte]; pos: var int): PrefixIdBytes =
  if pos + 32 > buf.len:
    raise newException(EReceiptCorrupt, "truncated prefix id")
  for i in 0 ..< 32:
    result[i] = buf[pos + i]
  pos += 32

proc encodeReceipt*(rec: RealizationReceipt): seq[byte] =
  ## Canonical binary envelope: 4-byte magic, u16 LE version, fields in
  ## a fixed order, followed by a trailing BLAKE3 checksum.
  var body: seq[byte] = @[]
  body.writeU16Le(rec.schemaVersion)
  body.writeString(rec.adapter)
  body.writeString(rec.packageName)
  body.writeString(rec.version)
  body.writePrefixId(rec.realizationHash)
  body.writeString(rec.realizedPath)
  body.writeString(rec.declaredExecutablePath)
  body.writeU32Le(uint32(rec.exportedExecutables.len))
  for exported in rec.exportedExecutables:
    body.writeString(exported)
  body.writeString(rec.lockIdentity)
  body.writeString(rec.provenanceUrl)
  body.writeString(rec.provenanceChecksum)
  body.writeString(rec.materializationMechanism)
  body.writeU64Le(uint64(rec.createdAtUnix))
  body.writeU64Le(uint64(rec.writerProcessId))
  body.writeString(rec.writerMode)

  result.add(byte(ord(ReceiptMagic[0])))
  result.add(byte(ord(ReceiptMagic[1])))
  result.add(byte(ord(ReceiptMagic[2])))
  result.add(byte(ord(ReceiptMagic[3])))
  result.writeU16Le(ReceiptFormatVersion)
  result.writeU32Le(uint32(body.len))
  result.add(body)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

proc decodeReceipt*(buf: openArray[byte]): RealizationReceipt =
  if buf.len < 10 + 32:
    raise newException(EReceiptCorrupt, "receipt too short")
  for i in 0 ..< 4:
    if buf[i] != byte(ord(ReceiptMagic[i])):
      raise newException(EReceiptCorrupt, "unknown receipt magic")
  var pos = 4
  let version = readU16Le(buf, pos)
  if version != ReceiptFormatVersion:
    raise newException(EReceiptCorrupt,
      "unsupported receipt format version: " & $version)
  let bodyLen = int(readU32Le(buf, pos))
  if pos + bodyLen + 32 != buf.len:
    raise newException(EReceiptCorrupt,
      "receipt size mismatch (declared body " & $bodyLen & " bytes)")
  let bodyStart = pos
  let bodyEnd = bodyStart + bodyLen
  # Verify trailing BLAKE3 checksum over header + body.
  var prefixForChecksum: seq[byte] = @[]
  for i in 0 ..< bodyEnd:
    prefixForChecksum.add(buf[i])
  let expected = blake3.digest(prefixForChecksum)
  for i in 0 ..< 32:
    if buf[bodyEnd + i] != expected[i]:
      raise newException(EReceiptCorrupt, "receipt checksum mismatch")
  result.schemaVersion = readU16Le(buf, pos)
  result.adapter = readString(buf, pos)
  result.packageName = readString(buf, pos)
  result.version = readString(buf, pos)
  result.realizationHash = readPrefixId(buf, pos)
  result.realizedPath = readString(buf, pos)
  result.declaredExecutablePath = readString(buf, pos)
  let exportedCount = int(readU32Le(buf, pos))
  result.exportedExecutables = newSeq[string](exportedCount)
  for i in 0 ..< exportedCount:
    result.exportedExecutables[i] = readString(buf, pos)
  result.lockIdentity = readString(buf, pos)
  result.provenanceUrl = readString(buf, pos)
  result.provenanceChecksum = readString(buf, pos)
  result.materializationMechanism = readString(buf, pos)
  result.createdAtUnix = int64(readU64Le(buf, pos))
  result.writerProcessId = int64(readU64Le(buf, pos))
  result.writerMode = readString(buf, pos)
  if pos != bodyEnd:
    raise newException(EReceiptCorrupt, "trailing receipt bytes")

proc receiptDigest*(rec: RealizationReceipt): PrefixIdBytes =
  ## BLAKE3-256 of the canonical encoded receipt.
  blake3.digest(encodeReceipt(rec))

proc readReceiptFile*(path: string): RealizationReceipt =
  if not fileExists(path):
    raise newException(EReceiptMissing, "no receipt at " & path)
  let raw = readFile(path)
  var buf = newSeq[byte](raw.len)
  for i, ch in raw:
    buf[i] = byte(ord(ch))
  decodeReceipt(buf)

proc writeReceiptFile*(path: string; rec: RealizationReceipt) =
  let bytes = encodeReceipt(rec)
  var text = newString(bytes.len)
  for i, b in bytes:
    text[i] = char(b)
  createDir(parentDir(path))
  writeFile(path, text)

# ---------------------------------------------------------------------------
# Realization-hash computation
# ---------------------------------------------------------------------------

proc computeRealizationHash*(packageName, version, adapter,
                            lockIdentity, declaredExecutablePath: string;
                            provenanceUrl = ""; provenanceChecksum = "";
                            extra: openArray[string] = []): PrefixIdBytes =
  ## Deterministic identity for a realized prefix. Adapters compose the
  ## inputs that fully determine the bytes of the prefix; the store then
  ## treats this hash as opaque.
  var buf: seq[byte] = @[]
  buf.writeString("reprobuild.realization.v1")
  buf.writeString(adapter)
  buf.writeString(packageName)
  buf.writeString(version)
  buf.writeString(lockIdentity)
  buf.writeString(declaredExecutablePath)
  buf.writeString(provenanceUrl)
  buf.writeString(provenanceChecksum)
  buf.writeU32Le(uint32(extra.len))
  for value in extra:
    buf.writeString(value)
  blake3.digest(buf)

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

const SchemaSql = """
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

proc initSchema(db: Database) =
  db.exec("PRAGMA foreign_keys = ON")
  db.exec("PRAGMA journal_mode = WAL")
  db.exec("PRAGMA synchronous = NORMAL")
  db.exec("BEGIN IMMEDIATE")
  try:
    db.exec(SchemaSql)
    setUserVersion(db, StoreSchemaVersion)
    db.exec("COMMIT")
  except CatchableError:
    try: db.exec("ROLLBACK") except CatchableError: discard
    raise

# ---------------------------------------------------------------------------
# Store lifecycle
# ---------------------------------------------------------------------------

proc openStore*(root: string): Store =
  ## Open or create the store rooted at `root`. Sub-directories are
  ## created on demand. The SQLite index is opened in WAL mode and
  ## passes `PRAGMA quick_check` (or raises `EStoreIndexCorrupt`).
  result.root = root
  createDir(root)
  result.casRoot = root / "cas" / "blake3"
  result.prefixesRoot = root / "prefixes"
  result.tmpRoot = root / "tmp"
  result.gcPendingRoot = root / "gc" / "pending-deletion"
  result.indexPath = root / "index.db"
  createDir(result.casRoot)
  createDir(result.prefixesRoot)
  createDir(result.tmpRoot)
  createDir(result.gcPendingRoot)
  result.db = sqlite3_binding.open(result.indexPath)
  let onDiskVersion = result.db.userVersion()
  if onDiskVersion == 0:
    result.db.initSchema()
  elif onDiskVersion > StoreSchemaVersion:
    var e = newException(EStoreSchemaTooNew,
      "store index.db schema version " & $onDiskVersion &
      " is newer than this Reprobuild build understands (" &
      $StoreSchemaVersion & ")")
    raise e
  else:
    result.db.exec("PRAGMA foreign_keys = ON")
    result.db.exec("PRAGMA journal_mode = WAL")
    result.db.exec("PRAGMA synchronous = NORMAL")
  let check = result.db.quickCheck()
  if check.len > 0 and check != "ok":
    var e = newException(EStoreIndexCorrupt,
      "PRAGMA quick_check returned: " & check)
    raise e
  result.rng = initRand(int64(getTime().toUnix * 1_000_000_000 +
    int64(getTime().nanosecond)) xor int64(getCurrentProcessId()))

proc close*(s: var Store) =
  s.db.close()

# ---------------------------------------------------------------------------
# CAS layer
# ---------------------------------------------------------------------------

proc casPath*(s: Store; digest: PrefixIdBytes): string =
  s.root / casBlobRelative(digest)

proc casStageDir(s: var Store): string =
  let token = $getCurrentProcessId() & "-" & $getTime().toUnixFloat() & "-" &
    $s.rng.rand(int64(1 shl 30))
  s.tmpRoot / ("cas." & token)

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc textOf(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc storeCasBlob*(s: var Store; payload: openArray[byte]): PrefixIdBytes =
  ## Inserts `payload` into the content-addressed blob store. Returns
  ## the BLAKE3-256 key the caller uses to read it back. Idempotent.
  result = blake3.digest(payload)
  let finalPath = s.casPath(result)
  if fileExists(finalPath):
    return
  createDir(parentDir(finalPath))
  let stagePath = s.casStageDir() & ".blob"
  createDir(parentDir(stagePath))
  writeFile(stagePath, textOf(payload))
  try:
    moveFile(stagePath, finalPath)
  except OSError:
    if fileExists(stagePath): removeFile(stagePath)
    if not fileExists(finalPath):
      raise

proc readCasBlob*(s: Store; digest: PrefixIdBytes): seq[byte] =
  ## Reads a CAS blob and verifies its BLAKE3-256 digest BEFORE the
  ## bytes are returned to the caller (mandatory per spec).
  let path = s.casPath(digest)
  if not fileExists(path):
    var e = newException(ECasMissing, "missing CAS blob " & hexOf(digest))
    raise e
  let raw = readFile(path)
  result = bytesOf(raw)
  let actual = blake3.digest(result)
  if actual != digest:
    var e = newException(ECasDigestMismatch,
      "CAS digest mismatch for " & hexOf(digest) &
      " (bytes hash to " & hexOf(actual) & ")")
    raise e

proc verifyCasBlob*(s: Store; digest: PrefixIdBytes) =
  discard s.readCasBlob(digest)

# ---------------------------------------------------------------------------
# Index helpers
# ---------------------------------------------------------------------------

proc lookupPrefix*(s: Store; prefixId: PrefixIdBytes):
    tuple[found: bool; row: PrefixRow] =
  var stmt = s.db.prepare(
    "SELECT prefix_id, package_name, version, realized_path, adapter, " &
    "receipt_digest, created_at FROM prefixes WHERE prefix_id = ?")
  defer: stmt.finalize()
  stmt.bindBlob(1, prefixId)
  if stmt.step() == SqliteRow:
    var row: PrefixRow
    let pid = stmt.columnBlob(0)
    for i in 0 ..< 32: row.prefixId[i] = pid[i]
    row.packageName = stmt.columnText(1)
    row.version = stmt.columnText(2)
    row.realizedPath = stmt.columnText(3)
    row.adapter = stmt.columnText(4)
    let rd = stmt.columnBlob(5)
    for i in 0 ..< 32: row.receiptDigest[i] = rd[i]
    row.createdAtUnix = stmt.columnInt(6)
    return (true, row)
  return (false, PrefixRow())

proc listPrefixes*(s: Store): seq[PrefixRow] =
  var stmt = s.db.prepare(
    "SELECT prefix_id, package_name, version, realized_path, adapter, " &
    "receipt_digest, created_at FROM prefixes ORDER BY realized_path")
  defer: stmt.finalize()
  while stmt.step() == SqliteRow:
    var row: PrefixRow
    let pid = stmt.columnBlob(0)
    for i in 0 ..< 32: row.prefixId[i] = pid[i]
    row.packageName = stmt.columnText(1)
    row.version = stmt.columnText(2)
    row.realizedPath = stmt.columnText(3)
    row.adapter = stmt.columnText(4)
    let rd = stmt.columnBlob(5)
    for i in 0 ..< 32: row.receiptDigest[i] = rd[i]
    row.createdAtUnix = stmt.columnInt(6)
    result.add(row)

proc insertPrefixOrIgnore*(s: Store; row: PrefixRow): bool =
  ## Returns true if this caller actually inserted a row, false if the
  ## row was already present (the loser of the rename race).
  var stmt = s.db.prepare(
    "INSERT OR IGNORE INTO prefixes(prefix_id, package_name, version, " &
    "realized_path, adapter, receipt_digest, created_at) " &
    "VALUES (?, ?, ?, ?, ?, ?, ?)")
  defer: stmt.finalize()
  stmt.bindBlob(1, row.prefixId)
  stmt.bindText(2, row.packageName)
  stmt.bindText(3, row.version)
  stmt.bindText(4, row.realizedPath)
  stmt.bindText(5, row.adapter)
  stmt.bindBlob(6, row.receiptDigest)
  stmt.bindInt(7, row.createdAtUnix)
  discard stmt.step()
  s.db.changes() > 0

# ---------------------------------------------------------------------------
# Realization
# ---------------------------------------------------------------------------

proc allocateStagingDir*(s: var Store): string =
  let token = $getCurrentProcessId() & "-" & $getTime().toUnixFloat() & "-" &
    $s.rng.rand(int64(1 shl 30))
  result = s.tmpRoot / ("stage." & token)
  createDir(result)

proc absolutePrefixPath*(s: Store; relative: string): string =
  s.root / relative.replace('/', DirSep)

type
  RealizeOutcome* = enum
    roPublished
    roLoserOfRace
    roAlreadyPresent

  RealizeResult* = object
    outcome*: RealizeOutcome
    prefixId*: PrefixIdBytes
    relativePath*: string
    absolutePath*: string
    row*: PrefixRow

proc materializeViaHardlinkOrCopy*(srcDir, dstDir: string;
                                  mechanism: var string) =
  ## Walks `srcDir` and reproduces its file tree under `dstDir`,
  ## preferring hardlinks where the OS supports them and falling back to
  ## a regular file copy. The chosen mechanism string is written back so
  ## the caller can record it as a debugging hint.
  mechanism = "copy"
  if not dirExists(srcDir):
    raise newException(StoreError, "materialize source missing: " & srcDir)
  createDir(dstDir)
  var anyHardlink = false
  var anyCopy = false
  for entry in walkDirRec(srcDir, yieldFilter = {pcFile, pcLinkToFile},
      relative = true):
    let src = srcDir / entry
    let dst = dstDir / entry
    createDir(parentDir(dst))
    var hardlinked = false
    when defined(windows) or defined(posix):
      try:
        createHardlink(src, dst)
        hardlinked = true
        anyHardlink = true
      except OSError, IOError:
        hardlinked = false
    if not hardlinked:
      copyFile(src, dst)
      anyCopy = true
  if anyHardlink and not anyCopy:
    mechanism = "hardlink"
  elif anyHardlink and anyCopy:
    mechanism = "mixed"
  else:
    mechanism = "copy"

proc realizePrefix*(s: var Store; prefixId: PrefixIdBytes;
                    hint: StoreReceiptHint;
                    populate: proc (stagingDir: string;
                                    mechanism: var string)): RealizeResult =
  ## Materializes a prefix using the spec's stage → rename → INSERT OR
  ## IGNORE protocol.
  ##
  ## `populate` is invoked exactly once inside the staging directory.
  ## It MUST write the realized contents (typically by linking blobs out
  ## of `cas/` via `materializeViaHardlinkOrCopy`) and MUST NOT write
  ## `.repro-receipt` — the store seals that itself so the on-disk
  ## directory name and the receipt-recorded realization-hash are
  ## guaranteed to match.
  result.prefixId = prefixId
  result.relativePath = prefixRelativePath(hint.packageName,
    hint.version, prefixId)
  result.absolutePath = s.absolutePrefixPath(result.relativePath)

  let lookup = s.lookupPrefix(prefixId)
  if lookup.found:
    result.outcome = roAlreadyPresent
    result.row = lookup.row
    if dirExists(result.absolutePath):
      return result
    # Index says we have it but the directory was wiped externally; fall
    # through and re-materialize.
  # Stage:
  let stage = s.allocateStagingDir()
  var mechanism = "copy"
  try:
    populate(stage, mechanism)
    # Build receipt
    var receipt = RealizationReceipt(
      schemaVersion: 1'u16,
      adapter: hint.adapter,
      packageName: hint.packageName,
      version: hint.version,
      realizationHash: prefixId,
      realizedPath: result.relativePath,
      declaredExecutablePath: hint.declaredExecutablePath,
      exportedExecutables: hint.exportedExecutables,
      lockIdentity: hint.lockIdentity,
      provenanceUrl: hint.provenanceUrl,
      provenanceChecksum: hint.provenanceChecksum,
      materializationMechanism:
        if hint.materializationMechanism.len > 0:
          hint.materializationMechanism
        else: mechanism,
      createdAtUnix: getTime().toUnix,
      writerProcessId: int64(getCurrentProcessId()),
      writerMode: "direct")
    writeReceiptFile(stage / ReceiptFileName, receipt)
    let digest = receiptDigest(receipt)
    # Publish (atomic rename):
    createDir(parentDir(result.absolutePath))
    var publishedSelf = true
    try:
      moveDir(stage, result.absolutePath)
    except OSError:
      publishedSelf = false
    if not publishedSelf:
      if dirExists(stage):
        try: removeDir(stage) except OSError: discard
      if not dirExists(result.absolutePath):
        raise
      result.outcome = roLoserOfRace
      let row = s.lookupPrefix(prefixId)
      if row.found:
        result.row = row.row
      return result
    # Index (winner of rename):
    var row = PrefixRow(
      prefixId: prefixId,
      packageName: hint.packageName,
      version: hint.version,
      realizedPath: toForwardSlash(result.relativePath),
      adapter: hint.adapter,
      receiptDigest: digest,
      createdAtUnix: receipt.createdAtUnix)
    s.db.exec("BEGIN IMMEDIATE")
    var committed = false
    try:
      let inserted = s.insertPrefixOrIgnore(row)
      s.db.exec("COMMIT")
      committed = true
      if inserted:
        result.outcome = roPublished
      else:
        result.outcome = roLoserOfRace
      result.row = row
    finally:
      if not committed:
        try: s.db.exec("ROLLBACK") except CatchableError: discard
    return result
  except CatchableError:
    if dirExists(stage):
      try: removeDir(stage) except OSError: discard
    raise

# ---------------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------------

proc registerRoot*(s: var Store; rootId: string; kind: RootKind;
                  holderUid: int64 = -1; ttlSeconds: int64 = -1) =
  var stmt = s.db.prepare(
    "INSERT OR REPLACE INTO roots(root_id, kind, holder_uid, " &
    "ttl_seconds, created_at) VALUES (?, ?, ?, ?, ?)")
  defer: stmt.finalize()
  stmt.bindText(1, rootId)
  stmt.bindText(2, $kind)
  if holderUid < 0: stmt.bindNull(3) else: stmt.bindInt(3, holderUid)
  if ttlSeconds < 0: stmt.bindNull(4) else: stmt.bindInt(4, ttlSeconds)
  stmt.bindInt(5, getTime().toUnix)
  discard stmt.step()

proc attachPrefixToRoot*(s: var Store; rootId: string;
                         prefixId: PrefixIdBytes) =
  var stmt = s.db.prepare(
    "INSERT OR IGNORE INTO root_holds_prefix(root_id, prefix_id) " &
    "VALUES (?, ?)")
  defer: stmt.finalize()
  stmt.bindText(1, rootId)
  stmt.bindBlob(2, prefixId)
  discard stmt.step()

proc deleteRoot*(s: var Store; rootId: string) =
  var stmt = s.db.prepare("DELETE FROM roots WHERE root_id = ?")
  defer: stmt.finalize()
  stmt.bindText(1, rootId)
  discard stmt.step()

proc listRoots*(s: Store): seq[RootRow] =
  var stmt = s.db.prepare(
    "SELECT root_id, kind, holder_uid, ttl_seconds, created_at FROM roots")
  defer: stmt.finalize()
  while stmt.step() == SqliteRow:
    var row = RootRow(
      rootId: stmt.columnText(0),
      kind: stmt.columnText(1),
      createdAtUnix: stmt.columnInt(4))
    if not stmt.columnIsNull(2):
      row.holderUid = stmt.columnInt(2)
      row.hasHolderUid = true
    if not stmt.columnIsNull(3):
      row.ttlSeconds = stmt.columnInt(3)
      row.hasTtl = true
    result.add(row)

# ---------------------------------------------------------------------------
# Garbage collection
# ---------------------------------------------------------------------------

proc deadSet*(s: Store): seq[PrefixRow] =
  ## Prefixes not currently held by any root.
  var stmt = s.db.prepare(
    "SELECT prefix_id, package_name, version, realized_path, adapter, " &
    "receipt_digest, created_at FROM prefixes WHERE prefix_id NOT IN " &
    "(SELECT prefix_id FROM root_holds_prefix)")
  defer: stmt.finalize()
  while stmt.step() == SqliteRow:
    var row: PrefixRow
    let pid = stmt.columnBlob(0)
    for i in 0 ..< 32: row.prefixId[i] = pid[i]
    row.packageName = stmt.columnText(1)
    row.version = stmt.columnText(2)
    row.realizedPath = stmt.columnText(3)
    row.adapter = stmt.columnText(4)
    let rd = stmt.columnBlob(5)
    for i in 0 ..< 32: row.receiptDigest[i] = rd[i]
    row.createdAtUnix = stmt.columnInt(6)
    result.add(row)

proc appendAudit(s: var Store; action: GcAction; prefixId: PrefixIdBytes;
                 reason: string) =
  var stmt = s.db.prepare(
    "INSERT INTO gc_audit(timestamp, action, prefix_id, reason) " &
    "VALUES (?, ?, ?, ?)")
  defer: stmt.finalize()
  stmt.bindInt(1, getTime().toUnix)
  stmt.bindText(2, $action)
  stmt.bindBlob(3, prefixId)
  stmt.bindText(4, reason)
  discard stmt.step()

proc appendAuditNoPrefix(s: var Store; action: GcAction; reason: string) =
  var stmt = s.db.prepare(
    "INSERT INTO gc_audit(timestamp, action, prefix_id, reason) " &
    "VALUES (?, ?, NULL, ?)")
  defer: stmt.finalize()
  stmt.bindInt(1, getTime().toUnix)
  stmt.bindText(2, $action)
  stmt.bindText(3, reason)
  discard stmt.step()

proc listAudit*(s: Store): seq[GcAuditRow] =
  var stmt = s.db.prepare(
    "SELECT audit_id, timestamp, action, prefix_id, reason FROM gc_audit " &
    "ORDER BY audit_id")
  defer: stmt.finalize()
  while stmt.step() == SqliteRow:
    var row: GcAuditRow
    row.auditId = stmt.columnInt(0)
    row.timestampUnix = stmt.columnInt(1)
    row.action = stmt.columnText(2)
    if not stmt.columnIsNull(3):
      let pid = stmt.columnBlob(3)
      for i in 0 ..< 32: row.prefixId[i] = pid[i]
      row.hasPrefixId = true
    row.reason = stmt.columnText(4)
    result.add(row)

proc quarantineUnique(s: var Store; absolutePath: string): string =
  ## Renames `absolutePath` into `gc/pending-deletion/` with a unique
  ## name so two GC passes never collide and so we can defer the final
  ## unlink for the grace period.
  let leaf = absolutePath.extractFilename
  let token = $getTime().toUnix & "-" & $s.rng.rand(int64(1 shl 30))
  result = s.gcPendingRoot / (leaf & "." & token)
  createDir(s.gcPendingRoot)
  moveDir(absolutePath, result)

proc gc*(s: var Store; graceSeconds = DefaultGcGraceSeconds): GcReport =
  ## Runs the spec's eager GC: dead-set query, move to
  ## `gc/pending-deletion/`, audit row, plus a sweep of the
  ## pending-deletion area for entries older than `graceSeconds`.
  result.graceSeconds = graceSeconds
  let dead = s.deadSet()
  for row in dead:
    let absPath = s.absolutePrefixPath(row.realizedPath)
    var movedTo = ""
    if dirExists(absPath):
      try:
        movedTo = s.quarantineUnique(absPath)
      except OSError as err:
        # The directory exists but cannot be renamed (busy reader, etc).
        # Defer; the next GC pass will retry.
        s.appendAudit(gaQuarantine, row.prefixId,
          "quarantine deferred: " & err.msg)
        continue
    # Delete the prefix row (cascades through root_holds_prefix).
    s.db.exec("BEGIN IMMEDIATE")
    var committed = false
    try:
      var del = s.db.prepare("DELETE FROM prefixes WHERE prefix_id = ?")
      del.bindBlob(1, row.prefixId)
      discard del.step()
      del.finalize()
      s.appendAudit(gaQuarantine, row.prefixId,
        "moved to " & movedTo)
      s.db.exec("COMMIT")
      committed = true
    finally:
      if not committed:
        try: s.db.exec("ROLLBACK") except CatchableError: discard
    result.quarantined.add(row)
    if movedTo.len > 0:
      result.quarantinedPaths.add(movedTo)

  # Sweep pending-deletion entries past grace.
  if dirExists(s.gcPendingRoot):
    let now = getTime().toUnix
    for kind, entry in walkDir(s.gcPendingRoot, relative = false):
      if kind notin {pcDir, pcLinkToDir, pcFile, pcLinkToFile}:
        continue
      var age: int64 = 0
      try:
        let info = getFileInfo(entry, followSymlink = false)
        let lastMtime = info.lastWriteTime.toUnix
        age = now - lastMtime
      except OSError:
        age = int64.high
      if age < graceSeconds.int64:
        continue
      try:
        if kind in {pcDir, pcLinkToDir}:
          removeDir(entry)
        else:
          removeFile(entry)
        s.appendAuditNoPrefix(gaReclaim, "unlinked " & entry &
          " (age " & $age & "s >= grace " & $graceSeconds & "s)")
        result.reclaimed.add(entry)
      except OSError:
        discard

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

proc sweepStaging*(s: var Store): seq[string] =
  ## Unconditionally remove every directory under `tmp/`. Concurrent
  ## writers should be quiesced before calling this (the recover code
  ## path is for startup / explicit `repro store recover`).
  if not dirExists(s.tmpRoot):
    return
  for kind, entry in walkDir(s.tmpRoot, relative = false):
    case kind
    of pcDir, pcLinkToDir:
      try:
        removeDir(entry)
        result.add(entry)
      except OSError: discard
    of pcFile, pcLinkToFile:
      try:
        removeFile(entry)
        result.add(entry)
      except OSError: discard

proc relativeFromRoot(s: Store; absolutePath: string): string =
  result = absolutePath
  let prefix = s.root & DirSep
  if result.startsWith(prefix):
    result = result[prefix.len .. ^1]
  result = toForwardSlash(result)

proc reconcileUnindexedPrefixes(s: var Store; report: var RecoverReport) =
  ## For each `prefixes/<pkg>/<dir>/` not present in the index, re-read
  ## its receipt and either re-insert the row or quarantine the prefix.
  if not dirExists(s.prefixesRoot):
    return
  for pkgKind, pkgDir in walkDir(s.prefixesRoot, relative = false):
    if pkgKind notin {pcDir, pcLinkToDir}:
      continue
    for kind, dir in walkDir(pkgDir, relative = false):
      if kind notin {pcDir, pcLinkToDir}:
        continue
      let receiptPath = dir / ReceiptFileName
      if not fileExists(receiptPath):
        # No receipt — quarantine. A directory under prefixes/ without
        # a sealed receipt was either a crashed writer (rename-before-
        # seal is not possible, but an external tool may have created
        # the directory) or a leftover from a previous schema. Move it
        # to pending-deletion either way.
        try:
          discard s.quarantineUnique(dir)
          s.appendAuditNoPrefix(gaQuarantine,
            "no receipt under prefix " & dir)
          report.quarantinedPrefixes.add(dir)
        except OSError: discard
        continue
      var receipt: RealizationReceipt
      try:
        receipt = readReceiptFile(receiptPath)
      except EReceiptCorrupt, EReceiptMissing:
        try:
          discard s.quarantineUnique(dir)
          s.appendAuditNoPrefix(gaQuarantine,
            "corrupt receipt under prefix " & dir)
          report.quarantinedPrefixes.add(dir)
        except OSError: discard
        continue
      # Verify the directory leaf name matches the realization-hash.
      let expectedLeaf = realizationDirName(receipt.version,
        receipt.realizationHash)
      if dir.extractFilename != expectedLeaf:
        try:
          discard s.quarantineUnique(dir)
          s.appendAudit(gaQuarantine, receipt.realizationHash,
            "EReceiptMismatch: dir leaf " & dir.extractFilename &
            " vs receipt-derived " & expectedLeaf)
          report.quarantinedPrefixes.add(dir)
        except OSError: discard
        continue
      let row = s.lookupPrefix(receipt.realizationHash)
      if row.found:
        # Already indexed; this is the common case after a successful
        # publish — nothing to do.
        continue
      # Re-insert.
      let digest = receiptDigest(receipt)
      var prow = PrefixRow(
        prefixId: receipt.realizationHash,
        packageName: receipt.packageName,
        version: receipt.version,
        realizedPath: toForwardSlash(s.relativeFromRoot(dir)),
        adapter: receipt.adapter,
        receiptDigest: digest,
        createdAtUnix: receipt.createdAtUnix)
      s.db.exec("BEGIN IMMEDIATE")
      var committed = false
      try:
        discard s.insertPrefixOrIgnore(prow)
        s.appendAudit(gaRestore, receipt.realizationHash,
          "recovered from disk: " & dir)
        s.db.exec("COMMIT")
        committed = true
      finally:
        if not committed:
          try: s.db.exec("ROLLBACK") except CatchableError: discard
      report.reinsertedPrefixes.add(dir)

proc recover*(s: var Store): RecoverReport =
  ## Implements the spec's "repro store recover" command:
  ## 1. `PRAGMA quick_check`
  ## 2. Sweep `tmp/` unconditionally.
  ## 3. Reconcile on-disk prefix directories against `prefixes` table.
  result.quickCheck = s.db.quickCheck()
  result.sweptStagingDirs = s.sweepStaging()
  s.reconcileUnindexedPrefixes(result)

# ---------------------------------------------------------------------------
# Convenience: realize a prefix directly from on-disk source content
# ---------------------------------------------------------------------------

proc realizeDirectoryAsPrefix*(s: var Store; sourceDir: string;
                              hint: StoreReceiptHint;
                              extra: openArray[string] = []): RealizeResult =
  ## Helper for adapters that already have the realized contents laid
  ## out in `sourceDir` (M53 Nix and M54 tarball both produce this
  ## shape).  Computes the realization hash, hardlinks or copies the
  ## tree into a staging dir, and runs the standard publish path.
  let prefixId = computeRealizationHash(hint.packageName, hint.version,
    hint.adapter, hint.lockIdentity, hint.declaredExecutablePath,
    hint.provenanceUrl, hint.provenanceChecksum, extra)
  result = s.realizePrefix(prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      materializeViaHardlinkOrCopy(sourceDir, stagingDir, mechanism))

# ---------------------------------------------------------------------------
# Tests-facing helpers: hex-conversion of receipt digests, etc.
# ---------------------------------------------------------------------------

proc receiptDigestHex*(rec: RealizationReceipt): string =
  hexOf(receiptDigest(rec))
