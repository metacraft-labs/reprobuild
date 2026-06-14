## ReproOS-Generations-And-Foreign-Packages A4 — in-flight sentinel.
##
## Implements the in-flight sentinel protocol described in the campaign
## spec § "Fix scope" of milestone A4: producers claim an entry-key
## (typically before kicking off a long substitutable build), other
## clients querying the same entry can choose to wait, race, or error
## out instead of duplicating the work.
##
## ## On-disk layout
##
## Sentinels live under ``<server-root>/sentinels/<ab>/<entry-key>.json``
## where ``<ab>`` is the first two hex characters of the entry-key. The
## json sidecar carries the minimal record:
##
##   {
##     "producer": "<opaque-id>",
##     "claimed_at_unix": <i64>,
##     "ttl_seconds": <u32>
##   }
##
## We hand-roll the JSON to avoid pulling Nim's std/json — the schema
## is fixed-shape and we want predictable byte output for the
## integration tests (the bash gates eyeball ``cat`` output to confirm
## state without a JSON parser dep). Files are written via
## ``writeFile`` + ``moveFile`` for atomicity (the producer write must
## not race with a sweeper read).
##
## ## Lifecycle
##
##  1. ``POST /sentinel/<key>``  — producer claims. 201 on first-claim;
##     409 if another producer's sentinel is still live (TTL not yet
##     expired). If the on-disk record exists but has expired, the
##     claim succeeds and overwrites the stale record.
##  2. ``GET  /sentinel/<key>``  — clients query. 200 with remaining
##     TTL in seconds when claimed; 404 when not claimed (including
##     "claim expired" — the lazy sweep on read deletes the stale
##     file so the next ``POST`` sees a clean slate).
##  3. ``DELETE /sentinel/<key>``— producer releases. 200 even when no
##     sentinel exists (idempotent).
##  4. Publish auto-release: the publish handler in ``server.nim``
##     consults this module's ``releaseSentinelIfHeldBy`` after a
##     successful manifest store so the producer doesn't have to issue
##     two HTTP requests.
##
## A periodic sweep (every 60s in the HTTP server's lifecycle) deletes
## any sentinel whose TTL has elapsed. The lazy-check on read provides
## a second line of defence for tests that move time forward without
## waiting for the sweep tick.

import std/[os, strutils, times]

import ./index

const
  SentinelExt* = ".json"
  SentinelSubdir* = "sentinels"
  DefaultSentinelTtlSeconds* = 300'u32
    ## 5 minute default; covers the slowest single-package builds in
    ## the R5-R9 chain (R5 gcc-15.2.0 is ~90 min wall-clock today and
    ## the producer rolls a longer TTL when it claims).
  SweepIntervalMs* = 60_000
    ## How often the lifecycle's background sweep wakes up to evict
    ## expired sentinel files. The lazy ``GET`` path also evicts on
    ## demand; this background tick keeps the on-disk count bounded
    ## even when no client is querying.

type
  SentinelError* = object of CatchableError
    ## Raised on filesystem corruption or malformed sentinel records.

  SentinelRecord* = object
    producer*: string
      ## Opaque producer identity supplied by the claim request. Tests
      ## set this to "producer-a" / "producer-b"; production clients
      ## use ``<hostname>:<pid>``.
    claimedAtUnix*: int64
    ttlSeconds*: uint32

  SentinelClaimOutcome* = enum
    scClaimed         ## First-claim or overwrote an expired record.
    scAlreadyClaimed  ## Sentinel held by ANOTHER live producer.
    scRefreshed       ## SAME producer re-claimed; TTL reset.

# ---------------------------------------------------------------------------
# Filesystem helpers.
# ---------------------------------------------------------------------------

proc sentinelsRoot*(s: BinaryCacheServerState): string =
  s.root / SentinelSubdir

proc sentinelPathFor*(s: BinaryCacheServerState; entryKeyHex: string): string =
  if entryKeyHex.len != 64:
    raise newException(SentinelError,
      "binary-cache entry-key hex must be 64 chars, got " &
      $entryKeyHex.len)
  let lower = entryKeyHex.toLowerAscii()
  result = s.sentinelsRoot / lower[0 .. 1] / (lower & SentinelExt)

# ---------------------------------------------------------------------------
# Tiny JSON codec — fixed shape only.
# ---------------------------------------------------------------------------

proc encodeSentinel*(rec: SentinelRecord): string =
  ## Encodes a record into the canonical JSON shape. Keys are quoted
  ## with no whitespace beyond the documented two-space indent so the
  ## bash integration tests can diff against a fixed expected output.
  result = "{\n"
  result.add("  \"producer\": \"")
  for ch in rec.producer:
    # Conservative escaping — sentinel producer ids in the field are
    # ASCII identifier-like (hostname:pid). Anything outside the safe
    # set is hex-escaped to keep the JSON parseable by any third-party
    # tool that wanders past the sentinel directory.
    case ch
    of '"', '\\':
      result.add('\\')
      result.add(ch)
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    elif ord(ch) < 0x20:
      const Hex = "0123456789abcdef"
      result.add("\\u00")
      result.add(Hex[(ord(ch) shr 4) and 0xf])
      result.add(Hex[ord(ch) and 0xf])
    else:
      result.add(ch)
  result.add("\",\n")
  result.add("  \"claimed_at_unix\": ")
  result.add($rec.claimedAtUnix)
  result.add(",\n")
  result.add("  \"ttl_seconds\": ")
  result.add($rec.ttlSeconds)
  result.add("\n}\n")

proc skipWs(s: string; i: var int) =
  while i < s.len and s[i] in {' ', '\t', '\r', '\n'}:
    inc i

proc decodeJsonString(s: string; i: var int): string =
  if i >= s.len or s[i] != '"':
    raise newException(SentinelError, "expected '\"' at offset " & $i)
  inc i
  result = ""
  while i < s.len and s[i] != '"':
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of '"': result.add('"')
      of '\\': result.add('\\')
      of 'n': result.add('\n')
      of 'r': result.add('\r')
      of 't': result.add('\t')
      of 'b': result.add('\b')
      of 'f': result.add('\f')
      of 'u':
        if i + 5 >= s.len:
          raise newException(SentinelError, "truncated \\u escape")
        var v = 0
        for k in 0 ..< 4:
          let c = s[i + 2 + k]
          let nib =
            if c >= '0' and c <= '9': ord(c) - ord('0')
            elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
            elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
            else: -1
          if nib < 0:
            raise newException(SentinelError, "bad hex in \\u escape")
          v = (v shl 4) or nib
        result.add(char(v and 0xff))
        i += 4
      else:
        raise newException(SentinelError,
          "unknown escape \\" & s[i + 1])
      i += 2
    else:
      result.add(s[i])
      inc i
  if i >= s.len:
    raise newException(SentinelError, "unterminated string")
  inc i  # closing quote

proc decodeJsonInt(s: string; i: var int): int64 =
  let start = i
  if i < s.len and (s[i] == '-' or s[i] == '+'):
    inc i
  while i < s.len and s[i] in {'0' .. '9'}:
    inc i
  if i == start:
    raise newException(SentinelError, "expected integer at offset " & $start)
  try:
    result = parseBiggestInt(s[start ..< i])
  except ValueError:
    raise newException(SentinelError, "malformed integer at offset " & $start)

proc decodeSentinel*(blob: string): SentinelRecord =
  ## Inverse of ``encodeSentinel``. Accepts the canonical shape we
  ## emit plus modest whitespace variations (so a hand-edited file
  ## still parses). Order of keys is fixed by the writer; the parser
  ## also tolerates reordering for forward-compat with any future
  ## auxiliary fields.
  var i = 0
  skipWs(blob, i)
  if i >= blob.len or blob[i] != '{':
    raise newException(SentinelError, "expected '{' at start of sentinel")
  inc i
  var sawProducer = false
  var sawClaimed = false
  var sawTtl = false
  while true:
    skipWs(blob, i)
    if i < blob.len and blob[i] == '}':
      inc i
      break
    let name = decodeJsonString(blob, i)
    skipWs(blob, i)
    if i >= blob.len or blob[i] != ':':
      raise newException(SentinelError, "expected ':' after key")
    inc i
    skipWs(blob, i)
    case name
    of "producer":
      result.producer = decodeJsonString(blob, i)
      sawProducer = true
    of "claimed_at_unix":
      result.claimedAtUnix = decodeJsonInt(blob, i)
      sawClaimed = true
    of "ttl_seconds":
      let v = decodeJsonInt(blob, i)
      if v < 0 or v > int64(uint32.high):
        raise newException(SentinelError, "ttl_seconds out of range")
      result.ttlSeconds = uint32(v)
      sawTtl = true
    else:
      # Unknown future field — skip its value (string or int).
      if i < blob.len and blob[i] == '"':
        discard decodeJsonString(blob, i)
      else:
        discard decodeJsonInt(blob, i)
    skipWs(blob, i)
    if i < blob.len and blob[i] == ',':
      inc i
      continue
    if i < blob.len and blob[i] == '}':
      inc i
      break
    raise newException(SentinelError, "expected ',' or '}' at offset " & $i)
  if not (sawProducer and sawClaimed and sawTtl):
    raise newException(SentinelError, "sentinel record missing required field")

# ---------------------------------------------------------------------------
# Expiry helpers.
# ---------------------------------------------------------------------------

proc nowUnix*(): int64 =
  toUnix(getTime())

proc remainingSeconds*(rec: SentinelRecord; nowSec: int64): int64 =
  ## Returns the number of whole seconds until the record expires.
  ## Negative when the record is past its TTL.
  let deadline = rec.claimedAtUnix + int64(rec.ttlSeconds)
  result = deadline - nowSec

proc isExpired*(rec: SentinelRecord; nowSec: int64): bool =
  remainingSeconds(rec, nowSec) <= 0

# ---------------------------------------------------------------------------
# Atomic write + load + delete.
# ---------------------------------------------------------------------------

proc writeSentinelAtomic(path, body: string) =
  ## Writes the json body to ``<path>.tmp`` then renames over the final
  ## name. Same shape as the manifest-store atomic write — ensures the
  ## sweeper or a concurrent GET never observes a torn write.
  createDir(parentDir(path))
  let tmp = path & ".tmp"
  writeFile(tmp, body)
  moveFile(tmp, path)

proc loadSentinelIfExists*(s: BinaryCacheServerState;
                           entryKeyHex: string):
                             tuple[ok: bool; rec: SentinelRecord] =
  ## Reads the sentinel record if present. Does NOT delete expired
  ## records; the caller decides whether the lazy-sweep or the
  ## background-tick semantics apply.
  let path = sentinelPathFor(s, entryKeyHex)
  if not fileExists(path):
    return (false, SentinelRecord())
  let body =
    try: readFile(path)
    except IOError: return (false, SentinelRecord())
  try:
    let rec = decodeSentinel(body)
    return (true, rec)
  except SentinelError:
    # Corrupt sentinel record — treat as absent. The sweeper drops it
    # on the next tick; correctness is preserved (next claim wins).
    return (false, SentinelRecord())

proc removeSentinel*(s: BinaryCacheServerState; entryKeyHex: string) =
  ## Idempotently deletes the on-disk sentinel file. Used by the
  ## release endpoint, the publish auto-release, and the sweeper.
  let path = sentinelPathFor(s, entryKeyHex)
  if fileExists(path):
    try: removeFile(path) except OSError: discard

# ---------------------------------------------------------------------------
# Claim / release.
# ---------------------------------------------------------------------------

proc claimSentinel*(s: BinaryCacheServerState;
                    entryKeyHex, producer: string;
                    ttlSeconds: uint32 = DefaultSentinelTtlSeconds;
                    nowSec: int64 = nowUnix()):
                      SentinelClaimOutcome =
  ## Implements the POST /sentinel/<key> semantics.
  ##
  ##   * Returns ``scClaimed`` on first claim AND on overwrite of an
  ##     expired claim from any producer.
  ##   * Returns ``scAlreadyClaimed`` when a DIFFERENT producer's
  ##     non-expired claim is on disk.
  ##   * Returns ``scRefreshed`` when the SAME producer re-claims; the
  ##     TTL is reset. Useful for long-running builds that want to
  ##     bump the deadline periodically.
  let path = sentinelPathFor(s, entryKeyHex)
  let prior = loadSentinelIfExists(s, entryKeyHex)
  if prior.ok and not isExpired(prior.rec, nowSec):
    if prior.rec.producer == producer:
      let newRec = SentinelRecord(
        producer: producer,
        claimedAtUnix: nowSec,
        ttlSeconds: ttlSeconds)
      writeSentinelAtomic(path, encodeSentinel(newRec))
      return scRefreshed
    else:
      return scAlreadyClaimed
  # Either no prior record OR expired prior record — claim wins.
  let newRec = SentinelRecord(
    producer: producer,
    claimedAtUnix: nowSec,
    ttlSeconds: ttlSeconds)
  writeSentinelAtomic(path, encodeSentinel(newRec))
  return scClaimed

proc releaseSentinel*(s: BinaryCacheServerState; entryKeyHex: string) =
  ## DELETE /sentinel/<key> — unconditional release. The publish path
  ## uses the by-producer variant below; ad-hoc deletions go through
  ## this one. Idempotent: deleting a missing sentinel is a no-op.
  removeSentinel(s, entryKeyHex)

proc releaseSentinelIfHeldBy*(s: BinaryCacheServerState;
                              entryKeyHex, producer: string): bool =
  ## Auto-release invoked by ``POST /publish``. Only deletes the
  ## sentinel when the publishing producer's id matches the on-disk
  ## record's producer. Returns true when a release happened.
  let prior = loadSentinelIfExists(s, entryKeyHex)
  if prior.ok and prior.rec.producer == producer:
    removeSentinel(s, entryKeyHex)
    return true
  return false

# ---------------------------------------------------------------------------
# Sweep — periodic + lazy.
# ---------------------------------------------------------------------------

proc sweepExpiredSentinels*(s: BinaryCacheServerState;
                            nowSec: int64 = nowUnix()): int =
  ## Walks the sentinels subdirectory and deletes every expired record.
  ## Returns the count evicted. Called every ``SweepIntervalMs`` from
  ## the HTTP server lifecycle AND once at startup so a stale claim
  ## from a crashed producer doesn't survive across reboots.
  result = 0
  let root = s.sentinelsRoot
  if not dirExists(root):
    return 0
  for shard in walkDir(root):
    if shard.kind != pcDir:
      continue
    for entry in walkDir(shard.path):
      if entry.kind != pcFile:
        continue
      if not entry.path.endsWith(SentinelExt):
        continue
      let body =
        try: readFile(entry.path)
        except IOError: continue
      let rec =
        try: decodeSentinel(body)
        except SentinelError:
          # Drop corrupt records too — they shouldn't survive into the
          # next sweep window.
          try: removeFile(entry.path) except OSError: discard
          inc result
          continue
      if isExpired(rec, nowSec):
        try: removeFile(entry.path) except OSError: discard
        inc result
