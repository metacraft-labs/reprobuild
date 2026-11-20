## The lockfile-keyed closure index (NPC-AREQ14).
##
## For a lock, a mirror serves one object that lists every source object of
## the lock's Nimble closure: the digest, the size and the mirror URLs that
## hold it, so a client learns in one round trip what to download from where
## and can start every download at once. Its shape follows
## Federation-And-Mirroring's closure index entry, for the lockfile keying:
##
## ```text
## reprobuild.nimble-closure-index.v1
## key <lock closure key>
## generated <unix seconds>
## row <name> <tree> <size> <url> [<url>...]
## ```
##
## one `row` per object, sorted by name, every field percent-encoded as the
## generator's edge objects are (`repro_nimble_generator/edge_objects`).
##
## **Trust.** The index is a performance cache, never a trust root. It is
## anchored by the lock itself, the first of that spec's two anchors: an entry
## is accepted only when its key is the lock's closure key and its rows are
## exactly the lock's rows, each with the lock's tree digest. A row that
## differs, a row the lock does not name or a lock row the entry omits
## rejects the whole entry, and the client resolves each source from the
## lock's own rows. A mirror URL in a row is used only when it lies under a
## mirror the client's configuration names, so an index cannot send the
## client anywhere it would not have gone.

import std/[algorithm, sets, strutils, tables]

import repro_nimble_generator/edge_objects

import ./lock_rows
import ./mirror

const
  ClosureIndexHeader* = "reprobuild.nimble-closure-index.v1"
  MaxClosureIndexBytes* = 16 * 1024 * 1024
  MaxClosureRows* = 65536

type
  ClosureRow* = object
    name*: string
    tree*: string
    size*: int64
    urls*: seq[string]

  ClosureIndex* = object
    key*: string
    generatedAt*: uint64
    rows*: seq[ClosureRow]  ## sorted by name

  ClosureIndexError* = object of ValueError

  AnchorVerdict* = enum
    avAnchored = "anchored"
    avRejected = "rejected"

proc ciError(msg: string) {.noreturn.} =
  raise newException(ClosureIndexError, msg)

proc buildClosureIndex*(rows: seq[NimbleLockRow]; sizes: Table[string, int64];
                        mirrors: seq[Mirror]; generatedAt: uint64):
                          ClosureIndex =
  ## The entry a mirror publishes for a lock: every row, with the URL of the
  ## object on each mirror. ``sizes`` maps a tree digest to its archive size.
  ## Deterministic in its inputs, so two mirrors derive the same bytes.
  result.key = lockClosureKey(rows)
  result.generatedAt = generatedAt
  for r in rows:
    var cr = ClosureRow(name: r.name, tree: r.tree,
      size: sizes.getOrDefault(r.tree, -1))
    for m in mirrors:
      cr.urls.add m.urlOf(sourceObjectPath(r.tree))
    result.rows.add cr
  result.rows.sort(proc (a, b: ClosureRow): int = cmp(a.name, b.name))

proc encodeClosureIndex*(ci: ClosureIndex): string =
  result = ClosureIndexHeader & "\n"
  result.add "key " & enc(ci.key) & "\n"
  result.add "generated " & $ci.generatedAt & "\n"
  for r in ci.rows:
    var fields = @["row", enc(r.name), enc(r.tree), $r.size]
    for u in r.urls: fields.add enc(u)
    result.add fields.join(" ") & "\n"

proc decodeClosureIndex*(text: string): ClosureIndex =
  ## The closed vocabulary above, bounded; anything else is a refusal.
  if text.len > MaxClosureIndexBytes:
    ciError("closure index larger than " & $MaxClosureIndexBytes & " bytes")
  let lines = text.split('\n')
  if lines.len < 4 or lines[0] != ClosureIndexHeader or lines[^1] != "":
    ciError("not a " & ClosureIndexHeader & " object")
  var sawKey, sawGenerated = false
  var seen = initHashSet[string]()
  for line in lines[1 ..< lines.high]:
    let f = line.split(' ')
    try:
      case f[0]
      of "key":
        if f.len != 2 or sawKey: ciError("bad key line")
        result.key = dec(f[1])
        sawKey = true
      of "generated":
        if f.len != 2 or sawGenerated: ciError("bad generated line")
        result.generatedAt = parseBiggestUInt(f[1])
        sawGenerated = true
      of "row":
        if f.len < 5: ciError("a row names no URL")
        var r = ClosureRow(name: dec(f[1]), tree: dec(f[2]),
          size: parseBiggestInt(f[3]))
        if not isTreeHex(r.tree): ciError("a row's tree is not a digest")
        if r.name in seen: ciError("row " & r.name.escape() & " twice")
        seen.incl r.name
        for u in f[4 .. ^1]: r.urls.add dec(u)
        result.rows.add r
        if result.rows.len > MaxClosureRows: ciError("too many rows")
      else:
        ciError("unknown record " & f[0].escape())
    except ValueError as e:
      if e of ClosureIndexError: raise
      ciError("malformed number: " & e.msg)
  if not (sawKey and sawGenerated): ciError("key or generated missing")
  for i in 1 ..< result.rows.len:
    if result.rows[i - 1].name >= result.rows[i].name:
      ciError("rows are not sorted by name")

proc anchor*(ci: ClosureIndex; rows: seq[NimbleLockRow]):
    tuple[verdict: AnchorVerdict; reason: string] =
  ## Accept the entry only as the lock vouches for it (see the module
  ## docstring).
  if ci.key != lockClosureKey(rows):
    return (avRejected, "the entry is keyed " & ci.key & ", not by this " &
      "lock's closure key " & lockClosureKey(rows))
  var want = initTable[string, string]()
  for r in rows: want[r.name] = r.tree
  if ci.rows.len != want.len:
    return (avRejected, "the entry has " & $ci.rows.len & " rows, the lock " &
      $want.len)
  for r in ci.rows:
    if r.name notin want:
      return (avRejected, "the entry names " & r.name.escape() &
        ", which the lock does not")
    if want[r.name] != r.tree:
      return (avRejected, "the entry's digest for " & r.name.escape() &
        " is " & r.tree & ", the lock's is " & want[r.name])
  (avAnchored, "")

proc usableUrls*(r: ClosureRow; mirrors: seq[Mirror]): seq[Mirror] =
  ## The configured mirrors a row's URLs point into, in the row's order:
  ## a URL is used only when it is exactly where that mirror keeps the
  ## object, so an index cannot add a location.
  for u in r.urls:
    for m in mirrors:
      if m.urlOf(sourceObjectPath(r.tree)) == u:
        var dup = false
        for x in result:
          if x.location == m.location: dup = true
        if not dup: result.add m
