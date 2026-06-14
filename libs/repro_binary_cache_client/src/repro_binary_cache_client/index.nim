## ReproOS-Generations-And-Foreign-Packages A2.5 — client-side index.
##
## Bookkeeping that tells "is this entry-key already materialized
## locally?" without going to disk on every check. Backed by the
## same SQLite ``index.db`` ``libs/repro_local_store/`` already
## maintains; the binary-cache client adds a thin sidecar table:
##
##   binary_cache_entries (
##     entry_key_hex TEXT PRIMARY KEY,
##     manifest_hash BLOB NOT NULL,
##     payload_hash BLOB NOT NULL,
##     realized_prefix_path TEXT NOT NULL,
##     created_at_unix INTEGER NOT NULL,
##     source_endpoint TEXT NOT NULL
##   );
##
## v1 keeps it simple: a single payload per manifest (we don't yet
## need a 1:N entry->payload index because the closure walk
## materialises each payload to a CAS path that's discoverable from
## the manifest's ``realizedPrefixDigest``). The table is informational
## + accelerates the "already-have-it" fast path.
##
## ## Why not just use the store's ``lookupPrefix``?
##
## ``lookupPrefix`` keys on ``PrefixIdBytes`` (the realised-prefix
## digest). A binary-cache substitute knows the ``entry-key`` first
## and only learns the realised-prefix digest after fetching the
## manifest; the client-side index gives us an O(1) entry-key ->
## realised-prefix lookup so we can skip the manifest fetch
## entirely on hot reruns.

import std/[os, strutils, tables, times]

import ./types
import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes

type
  IndexEntry* = object
    entryKeyHex*: string
    manifestHash*: Blake3Hash
    payloadHash*: Blake3Hash
    realizedPrefixPath*: string
    createdAtUnix*: int64
    sourceEndpoint*: string

  ClientIndex* = ref object
    ## v1 in-memory cache backed by an on-disk sidecar text file under
    ## ``<storeRoot>/binary-cache-index.tsv``. The SQLite migration is
    ## deferred until we observe contention; the workload is bounded by
    ## (active toolchain closures) which is O(100) entries.
    entries*: Table[string, IndexEntry]
    path*: string
    dirty*: bool

const ClientIndexFile* = "binary-cache-index.tsv"

proc parseIndex(text: string): Table[string, IndexEntry] =
  result = initTable[string, IndexEntry]()
  for line in text.splitLines:
    if line.len == 0 or line[0] == '#':
      continue
    let fields = line.split('\t')
    if fields.len < 6:
      continue
    var entry = IndexEntry(
      entryKeyHex: fields[0],
      realizedPrefixPath: fields[3],
      sourceEndpoint: fields[5])
    # Decode hex (relaxed: skip malformed lines instead of failing the
    # whole load).
    if fields[1].len == 64:
      for i in 0 ..< 32:
        let hi = parseHexInt(fields[1][i * 2 .. i * 2 + 1])
        entry.manifestHash[i] = byte(hi and 0xff)
    if fields[2].len == 64:
      for i in 0 ..< 32:
        let hi = parseHexInt(fields[2][i * 2 .. i * 2 + 1])
        entry.payloadHash[i] = byte(hi and 0xff)
    try:
      entry.createdAtUnix = parseBiggestInt(fields[4]).int64
    except CatchableError:
      entry.createdAtUnix = 0
    result[entry.entryKeyHex] = entry

proc hexOf(d: Blake3Hash): string =
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(64)
  for b in d:
    result.add(HexChars[int(b shr 4) and 0x0f])
    result.add(HexChars[int(b) and 0x0f])

proc openClientIndex*(storeRoot: string): ClientIndex =
  result = ClientIndex(
    entries: initTable[string, IndexEntry](),
    path: storeRoot / ClientIndexFile,
    dirty: false)
  if fileExists(result.path):
    let text = readFile(result.path)
    result.entries = parseIndex(text)

proc lookup*(idx: ClientIndex; entryKeyHex: string): tuple[found: bool; entry: IndexEntry] =
  if idx.entries.hasKey(entryKeyHex):
    return (true, idx.entries[entryKeyHex])
  return (false, IndexEntry())

proc upsert*(idx: ClientIndex; entry: IndexEntry) =
  idx.entries[entry.entryKeyHex] = entry
  idx.dirty = true

proc flush*(idx: ClientIndex) =
  ## Atomic via tmp+rename so a crash mid-write doesn't truncate the
  ## sidecar. The local store's tmp dir under ``<root>/tmp`` is
  ## fast-path; we use ``<storeRoot>/binary-cache-index.tsv.tmp``
  ## for simplicity since the table is bounded.
  if not idx.dirty:
    return
  var buf = "# entry-key-hex\tmanifest-hash-hex\tpayload-hash-hex\trealized-path\tcreated-at-unix\tsource-endpoint\n"
  for entry in idx.entries.values:
    buf.add(entry.entryKeyHex)
    buf.add('\t')
    buf.add(hexOf(entry.manifestHash))
    buf.add('\t')
    buf.add(hexOf(entry.payloadHash))
    buf.add('\t')
    buf.add(entry.realizedPrefixPath)
    buf.add('\t')
    buf.add($entry.createdAtUnix)
    buf.add('\t')
    buf.add(entry.sourceEndpoint)
    buf.add('\n')
  let tmp = idx.path & ".tmp"
  writeFile(tmp, buf)
  moveFile(tmp, idx.path)
  idx.dirty = false
