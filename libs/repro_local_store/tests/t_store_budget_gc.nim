## `repro store gc --budget`: the per-object last-use record, root TTL expiry,
## and the size-budgeted least-recently-used collector.
##
## Spec: reprobuild-pm `spec/Shared-Store-Budgeted-Eviction.md` §5.
##
## MOCK POLICY: none. Every case runs a real `Store` on a real temporary
## directory: prefixes are realized through `realizeDirectoryAsPrefix`,
## action-cache entries are written through `recordActionResult` into the
## store's own CAS, and the collector walks the layout the engine reads.
## Time is injected (`now` / `nowUnix`) and last use is placed in the past
## through the store's own `touchPrefix` / `touchCasBlob` and file mtimes,
## never by sleeping.
##
## Each eviction claim is paired with what must SURVIVE the same run, so a
## collector that deleted everything, or nothing, fails.

import std/[os, sequtils, strutils, tables, tempfiles, times, unittest]

from repro_core/paths import extendedPath

import repro_core
import repro_hash
import repro_local_store
import repro_local_store/budget_gc

const
  Day = 24 * 3600'i64
  KiB = 1024

type Fixture = object
  root: string
  storeRoot: string
  work: string
  store: Store

proc openFixture(tag: string): Fixture =
  let root = createTempDir("repro-budget-gc-" & tag & "-", "")
  result = Fixture(root: root, storeRoot: root / "store", work: root / "work")
  createDir(result.work)
  result.store = openStore(result.storeRoot)

proc closeFixture(f: var Fixture) =
  close(f.store)
  try: removeDir(extendedPath(f.root))
  except OSError: discard

proc payloadOf(name: string; size: int): string =
  result = newString(size)
  for i in 0 ..< size:
    result[i] = char((i * 31 + name.len * 7919 + int(name[0])) and 0x7f)

proc realize(f: var Fixture; name: string; size = 64 * KiB): PrefixIdBytes =
  let stage = f.root / "stage" / name
  createDir(extendedPath(stage / "bin"))
  writeFile(stage / "bin" / "tool", payloadOf(name, size))
  let hint = StoreReceiptHint(adapter: "path", packageName: name,
    version: "1.0", declaredExecutablePath: "bin/tool",
    lockIdentity: "budget-gc-test")
  realizeDirectoryAsPrefix(f.store, stage, hint).prefixId

proc ageCreation(f: var Fixture; id: PrefixIdBytes; createdAt: int64) =
  ## Move a prefix's creation (and so its default last use) into the past.
  var u = f.store.db.prepare(
    "UPDATE prefixes SET created_at = ?, last_used_at = NULL WHERE prefix_id = ?")
  u.bindInt(1, createdAt)
  u.bindBlob(2, id)
  discard u.step()
  u.finalize()

proc indexed(f: Fixture; id: PrefixIdBytes): bool =
  f.store.lookupPrefix(id).found

proc weakOf(name: string): ContentDigest =
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

proc writeEntry(f: var Fixture; cache: var ActionCache; name: string;
                size = 64 * KiB): string =
  ## One real action-cache entry whose output blob lives in the store's CAS.
  ## Returns the output blob's hex digest.
  let input = f.work / (name & ".in")
  let output = f.work / (name & ".out")
  writeFile(input, "input-" & name)
  writeFile(output, payloadOf(name, size))
  let rec = cache.recordActionResult(f.store, weakOf("budget-gc." & name),
    ffpTimestamp, [input], [output], outputRoot = "", storeOutputBlobs = true)
  digestHex(rec.outputs[0].blob.digest)

proc blobPath(f: Fixture; hex: string): string =
  f.storeRoot / "cas" / "blake3" / hex[0 .. 1] / hex

proc ageEntry(f: Fixture; cache: ActionCache; name, blobHex: string; at: int64) =
  ## Place an entry's last use at `at`: its `.rec` write time and its blob's.
  let dir = cache.hotRecordsRoot
  for kind, edgeDir in walkDir(dir):
    if kind == pcDir and edgeDir.extractFilename.contains(
        digestHex(weakOf("budget-gc." & name))):
      for k, path in walkDir(edgeDir):
        if k == pcFile:
          setLastModificationTime(path, fromUnix(at))
  setLastModificationTime(f.blobPath(blobHex), fromUnix(at))

proc entryPresent(cache: var ActionCache; name: string): bool =
  cache.loadPerEdgeRecords(weakOf("budget-gc." & name)).len > 0

suite "store last-use record":

  test "a prefix use is recorded once per day, and only when stale":
    var f = openFixture("touch-prefix")
    defer: closeFixture(f)
    let id = f.realize("pkg")
    let created = f.store.prefixLastUsed(id)
    check created > 0
    # Within the resolution: nothing is written.
    check not f.store.touchPrefix(id, now = created + 3600)
    check f.store.prefixLastUsed(id) == created
    # A day later the use is recorded.
    check f.store.touchPrefix(id, now = created + 2 * Day)
    check f.store.prefixLastUsed(id) == created + 2 * Day
    # And not again within the next day.
    check not f.store.touchPrefix(id, now = created + 2 * Day + 60)

  test "realize finding a prefix present records the use":
    var f = openFixture("realize-touch")
    defer: closeFixture(f)
    let id = f.realize("pkg")
    let old = getTime().toUnix - 10 * Day
    f.ageCreation(id, old)
    check f.store.prefixLastUsed(id) == old
    discard f.realize("pkg")            # same declaration: already present
    check f.store.prefixLastUsed(id) > old + 9 * Day

  test "a CAS read records the use of a blob last used days ago":
    var f = openFixture("touch-cas")
    defer: closeFixture(f)
    let digest = f.store.storeCasBlob("hello budget gc".toOpenArrayByte(0, 14))
    let hex = hexOf(digest)
    # Freshly written: the write is its use, nothing to record.
    check not f.store.touchCasBlob(digest)
    check not f.store.casLastUseTable().hasKey(hex)
    setLastModificationTime(f.storeRoot / casBlobRelative(digest),
      fromUnix(getTime().toUnix - 5 * Day))
    discard f.store.readCasBlob(digest)
    let recorded = f.store.casLastUseTable().getOrDefault(hex, 0)
    check recorded > getTime().toUnix - 60

suite "root TTL expiry":

  test "an elapsed TTL releases what the root held; a renewal or no TTL keeps it":
    var f = openFixture("ttl")
    defer: closeFixture(f)
    let held = f.realize("held")
    let forever = f.realize("forever")
    f.store.registerRoot("job", rkSession, ttlSeconds = 60)
    f.store.attachPrefixToRoot("job", held)
    f.store.registerRoot("profile", rkProfile)
    f.store.attachPrefixToRoot("profile", forever)
    let t0 = f.store.listRoots().filterIt(it.rootId == "job")[0].createdAtUnix

    check f.store.expireRoots(now = t0 + 30).len == 0
    check f.store.renewRoot("job", now = t0 + 50)
    check f.store.expireRoots(now = t0 + 100).len == 0    # renewed: due at +110
    check f.store.rootsHolding(held) == @["job"]          # renewal kept the hold
    check f.store.expireRoots(now = t0 + 120) == @["job"]
    check f.store.rootsHolding(held).len == 0
    check f.store.rootsHolding(forever) == @["profile"]
    check f.store.expireRoots(now = t0 + 1000 * Day).len == 0
    check f.store.listAudit().anyIt(it.action == "expire" and "job" in it.reason)

  test "plain gc honours an elapsed TTL":
    var f = openFixture("ttl-gc")
    defer: closeFixture(f)
    let id = f.realize("pkg")
    f.store.registerRoot("job", rkSession, ttlSeconds = 60)
    f.store.attachPrefixToRoot("job", id)
    discard f.store.gc(graceSeconds = 0)
    check f.indexed(id)                                    # TTL not yet passed
    f.store.db.exec("UPDATE roots SET created_at = created_at - 3600")
    discard f.store.gc(graceSeconds = 0)
    check not f.indexed(id)

suite "budget gc":

  test "over budget, the least recently used dead prefixes go first":
    var f = openFixture("lru-prefixes")
    defer: closeFixture(f)
    let now = getTime().toUnix
    let a = f.realize("a")
    let b = f.realize("b")
    let c = f.realize("c")
    let held = f.realize("held")
    f.ageCreation(a, now - 10 * Day)
    f.ageCreation(b, now - 9 * Day)
    f.ageCreation(c, now - 8 * Day)
    f.ageCreation(held, now - 20 * Day)
    f.store.registerRoot("profile", rkProfile)
    f.store.attachPrefixToRoot("profile", held)

    let plan = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now, dryRun: true))
    let total = plan.bytesBefore
    check total >= 4 * 64 * KiB
    check plan.evicted.len == 3                           # every dead prefix
    check f.indexed(a)                                    # a dry run removes nothing

    # Free a bit more than one prefix: exactly the two oldest go.
    let r = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: total - 1,
      targetBytes: total - 64 * KiB - 1024, keepRecentSeconds: Day,
      nowUnix: now, graceSeconds: 1))
    checkpoint(renderBudgetGcText(r, f.storeRoot))
    check r.evicted.len == 2
    check r.evicted[0].kind == bokPrefix and r.evicted[0].id.contains("/a/")
    check r.evicted[1].id.contains("/b/")
    check not f.indexed(a) and not f.indexed(b)
    check f.indexed(c)
    check f.indexed(held)
    check not r.unreachable

  test "under budget nothing goes":
    var f = openFixture("under")
    defer: closeFixture(f)
    let a = f.realize("a")
    f.ageCreation(a, getTime().toUnix - 30 * Day)
    let r = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1 shl 40,
      keepRecentSeconds: Day))
    check r.evicted.len == 0
    check f.indexed(a)

  test "the keep window and roots stop eviction short; the run says so":
    var f = openFixture("keep")
    defer: closeFixture(f)
    let now = getTime().toUnix
    let old = f.realize("old")
    let recent = f.realize("recent")
    let held = f.realize("held")
    f.ageCreation(old, now - 10 * Day)
    f.ageCreation(held, now - 10 * Day)
    f.store.registerRoot("profile", rkProfile)
    f.store.attachPrefixToRoot("profile", held)
    let r = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now, graceSeconds: 1))
    checkpoint(renderBudgetGcText(r, f.storeRoot))
    check not f.indexed(old)
    check f.indexed(recent)                               # used within the window
    check f.indexed(held)                                 # held by a root
    check r.unreachable
    check r.stoppedAtKeepWindow
    check f.store.listAudit().anyIt(it.action == "budget" and
      "target unreachable" in it.reason)

  test "an expired root's prefix becomes evictable in the same run":
    var f = openFixture("ttl-budget")
    defer: closeFixture(f)
    let now = getTime().toUnix
    let id = f.realize("pkg")
    f.ageCreation(id, now - 10 * Day)
    f.store.registerRoot("dead-job", rkSession, ttlSeconds = 60)
    f.store.attachPrefixToRoot("dead-job", id)
    let r = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now + 3600,
      graceSeconds: 1))
    check r.expiredRoots == @["dead-job"]
    check not f.indexed(id)

  test "action-cache entries go LRU; CAS blobs only with evictCas and only when unreferenced":
    var f = openFixture("action-cache")
    defer: closeFixture(f)
    let now = getTime().toUnix
    var cache = openActionCache(f.storeRoot / "action-cache", attachShm = false)
    let oldBlob = f.writeEntry(cache, "old")
    let newBlob = f.writeEntry(cache, "new")
    f.ageEntry(cache, "old", oldBlob, now - 10 * Day)
    # The surviving entry's blob is OLD too: written ten days ago and
    # adopted by the entry today. Only its reference from a live entry keeps
    # it, so a collector that ignored references would take it.
    setLastModificationTime(f.blobPath(newBlob), fromUnix(now - 10 * Day))
    check fileExists(f.blobPath(oldBlob)) and fileExists(f.blobPath(newBlob))

    # Without evictCas the old entry goes but no blob is touched.
    let first = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now))
    checkpoint(renderBudgetGcText(first, f.storeRoot))
    check not cache.entryPresent("old")
    check cache.entryPresent("new")
    check fileExists(f.blobPath(oldBlob))
    check fileExists(f.blobPath(newBlob))
    check first.unreachable
    check first.evicted.allIt(it.kind != bokCasBlob)

    # With evictCas the now-unreferenced old blob goes; the blob the
    # surviving entry references stays, however tight the budget.
    let second = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now, evictCas: true))
    checkpoint(renderBudgetGcText(second, f.storeRoot))
    check not fileExists(f.blobPath(oldBlob))
    check fileExists(f.blobPath(newBlob))
    check cache.entryPresent("new")
    check second.evicted.anyIt(it.kind == bokCasBlob and it.id == oldBlob)
    check second.unreachable and second.stoppedAtKeepWindow
    cache.closeShmTier()

  test "a blob referenced by an evicted entry goes in the same run when evictCas":
    var f = openFixture("action-cache-chain")
    defer: closeFixture(f)
    let now = getTime().toUnix
    var cache = openActionCache(f.storeRoot / "action-cache", attachShm = false)
    let oldBlob = f.writeEntry(cache, "old")
    discard f.writeEntry(cache, "new")
    f.ageEntry(cache, "old", oldBlob, now - 10 * Day)
    let r = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now, evictCas: true))
    checkpoint(renderBudgetGcText(r, f.storeRoot))
    check not cache.entryPresent("old")
    check not fileExists(f.blobPath(oldBlob))
    check r.evicted.mapIt(it.kind) == @[bokActionEntry, bokCasBlob]
    cache.closeShmTier()

  test "a blob used since the entry was written keeps the entry":
    ## The action cache's last use comes through its blobs: a hit
    ## materializes them, and that records a use. An entry whose `.rec` is
    ## old but whose blob was read yesterday is not least recently used.
    var f = openFixture("action-cache-hit")
    defer: closeFixture(f)
    let now = getTime().toUnix
    var cache = openActionCache(f.storeRoot / "action-cache", attachShm = false)
    let blob = f.writeEntry(cache, "hit")
    f.ageEntry(cache, "hit", blob, now - 10 * Day)
    var digest: PrefixIdBytes
    for i in 0 ..< 32:
      digest[i] = byte(parseHexInt(blob[2 * i .. 2 * i + 1]))
    check f.store.touchCasBlob(digest, now = now - 3600)
    let r = budgetGc(f.storeRoot, BudgetGcPolicy(budgetBytes: 1,
      targetBytes: 1, keepRecentSeconds: Day, nowUnix: now, evictCas: true))
    check cache.entryPresent("hit")
    check fileExists(f.blobPath(blob))
    check r.evicted.len == 0
    cache.closeShmTier()
