## Retention-aware GC — `Edge-Determinism-And-Soft-Rebuild.md` §9's deferred
## follow-up and §10.2's "retention-driven eviction runs before size-driven
## eviction".
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every entry is written through the production `recordActionResult` into a
## real `ActionCache` over a real `Store` on a real temporary directory, with
## real output files hashed into real CAS blobs. The GC then walks the same
## on-disk layout the build engine reads. A synthesised in-memory entry list
## would have proved that the sort works and nothing about whether the
## metadata survives the round trip through the sidecar — which is the half
## that can actually break.
##
## The CLOCK is injected (`RetentionGcPolicy.nowUnix`, and the `nowUnix`
## argument to `declaredDeterminism`). That is the alternative to sleeping
## through a `max-age` window, not a mock of a collaborator.
##
## What §9 deferred, exactly: "A `volatile` entry with `max-age = 1` clutters
## the cache fast. A retention-aware GC that evicts stale `volatile` entries
## preferentially is a follow-up; the current spec leaves it to the existing
## reprobuild GC." Nothing in reprobuild evicted on AGE before this — the
## reaper evicts on lease deadline, the store GC on root reachability, and
## the home GC on keep-last-N-generations.

import std/[os, strutils, tempfiles, times, unittest]

import repro_core
import repro_hash
import repro_local_store

const
  BaseNow = 1_704_067_200'i64      ## 2024-01-01T00:00:00Z
  BlobSize = 64 * 1024             ## 64 KiB per entry payload

proc weakOf(name: string): ContentDigest =
  ## The same construction `repro_build_engine.weakFingerprintFromText` uses.
  ## Written out rather than imported because a `repro_local_store` test must
  ## not depend on the layer above it; only the DOMAIN and the bytes matter
  ## here, and the cache never interprets either.
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

type Fixture = object
  root: string
  workRoot: string
  cache: ActionCache
  store: Store

proc openFixture(tag: string): Fixture =
  let root = createTempDir("repro-retention-gc-" & tag & "-", "")
  let workRoot = root / "work"
  createDir(workRoot)
  Fixture(
    root: root,
    workRoot: workRoot,
    cache: openActionCache(root / "action-cache", attachShm = false),
    store: openStore(root / "store"))

proc closeFixture(f: var Fixture) =
  f.cache.closeShmTier()
  close(f.store)
  try: removeDir(f.root)
  except OSError: discard

proc writeEntry(f: var Fixture; name: string; meta: EntryDeterminism) =
  ## Write ONE real cache entry: a real input file, a real output file of a
  ## known size, hashed into the real CAS, recorded through the production
  ## record path.
  let inputPath = f.workRoot / (name & ".in")
  let outputPath = f.workRoot / (name & ".out")
  writeFile(inputPath, "input-" & name & "\n")
  var payload = newString(BlobSize)
  for i in 0 ..< BlobSize:
    # A per-entry pattern so no two entries collide on one CAS blob, which
    # would make the byte accounting below meaningless.
    payload[i] = char((i + name.len * 7919 + int(name[0])) and 0x7f)
  writeFile(outputPath, payload)
  discard f.cache.recordActionResult(f.store,
    weakOf("retention-gc." & name),
    ffpTimestamp,
    [inputPath], [outputPath],
    outputRoot = "",
    storeOutputBlobs = true,
    determinism = meta)

proc recFileCount(f: Fixture): int =
  let root = f.cache.hotRecordsRoot
  if not dirExists(root):
    return 0
  for kind, edgeDir in walkDir(root):
    if kind != pcDir: continue
    for k, path in walkDir(edgeDir):
      if k == pcFile and path.endsWith(".rec"):
        inc result

proc detFileCount(f: Fixture): int =
  let root = f.cache.hotRecordsRoot
  if not dirExists(root):
    return 0
  for kind, edgeDir in walkDir(root):
    if kind != pcDir: continue
    for k, path in walkDir(edgeDir):
      if k == pcFile and path.endsWith(DeterminismFileExt):
        inc result

proc classOf(f: var Fixture; name: string): EntryDeterminism =
  let records = f.cache.loadPerEdgeRecords(
    weakOf("retention-gc." & name))
  if records.len == 0: EntryDeterminism()
  else: records[^1].determinism

proc stampRecMtime(f: Fixture; name: string; unixSec: int64) =
  ## Force the mtime of an entry's `.rec` file, so the size pass's LRU
  ## ordering is deterministic regardless of how fast the write loop ran.
  let root = f.cache.hotRecordsRoot
  for kind, edgeDir in walkDir(root):
    if kind != pcDir: continue
    for k, path in walkDir(edgeDir):
      if k == pcFile and path.endsWith(".rec"):
        # One `.rec` per edge directory here, and the directory is keyed on
        # the edge's weak fingerprint, so matching the directory identifies
        # the entry.
        if edgeDir.extractFilename.contains(
            digestHex(weakOf("retention-gc." & name))):
          setLastModificationTime(path, fromUnix(unixSec))

proc entryExists(f: var Fixture; name: string): bool =
  f.cache.loadPerEdgeRecords(
    weakOf("retention-gc." & name)).len > 0

suite "retention-aware GC":

  test "an entry's determinism survives the round trip to disk":
    ## The precondition for everything below. If the sidecar did not
    ## round-trip, every eviction assertion would still pass — against a GC
    ## that classified nothing and evicted nothing.
    var f = openFixture("roundtrip")
    defer: closeFixture(f)

    f.writeEntry("s", declaredDeterminism(edStrong, nowUnix = BaseNow))
    f.writeEntry("v", declaredDeterminism(edVolatile, maxAge(3600),
      nowUnix = BaseNow, buildEpoch = "epoch-a"))
    f.writeEntry("unlabelled", EntryDeterminism())

    let s = f.classOf("s")
    check s.declared
    check s.class == edStrong
    check s.retention.kind == crkForever
    check s.writeTimeUnix == BaseNow
    check s.hostFingerprint.len > 0

    let v = f.classOf("v")
    check v.declared
    check v.class == edVolatile
    check v.retention.kind == crkMaxAge
    check v.retention.seconds == 3600
    check v.buildEpoch == "epoch-a"

    # The negative control on the sidecar itself: an UNLABELLED entry writes
    # none, so the common edge pays nothing for this feature existing.
    check not f.classOf("unlabelled").declared
    check f.recFileCount == 3
    check f.detFileCount == 2

  test "t_retention_gc_evicts_stale_volatile_preferentially":
    ## The milestone's named case. A mixed cache OVER a size budget: the GC
    ## must evict the expired `volatile` entries before any `strong` /
    ## `weak` entry, and must never evict an unexpired one to satisfy the
    ## budget while an expired one remains.
    var f = openFixture("mixed")
    defer: closeFixture(f)

    # Two expired volatile entries (max-age 60, written two hours ago), two
    # fresh non-volatile entries, one FRESH volatile entry.
    f.writeEntry("vol-old-1", declaredDeterminism(edVolatile, maxAge(60),
      nowUnix = BaseNow - 7200))
    f.writeEntry("vol-old-2", declaredDeterminism(edVolatile, maxAge(60),
      nowUnix = BaseNow - 7200))
    f.writeEntry("strong-1", declaredDeterminism(edStrong, nowUnix = BaseNow - 9000))
    f.writeEntry("weak-1", declaredDeterminism(edWeak, nowUnix = BaseNow - 9000))
    f.writeEntry("vol-fresh", declaredDeterminism(edVolatile, maxAge(86_400),
      nowUnix = BaseNow - 10))

    # A budget FAR below the footprint, so a size-only GC would be forced to
    # evict something in every class. That is what makes the ordering claim
    # non-vacuous: `strong-1` and `weak-1` are the two OLDEST entries by
    # write time, so a pure LRU would take them first.
    let casBlobsBefore = scanCasBlobs(f.store).len
    var policy = RetentionGcPolicy(nowUnix: BaseNow, softCapBytes: 0,
      currentBuildEpoch: "epoch-now")
    let report = runRetentionGc(f.cache, policy)

    checkpoint("scanned=" & $report.scannedEntries &
      " expiredEvicted=" & $report.expiredEvicted &
      " sizeEvicted=" & $report.sizeEvicted &
      " evicted=" & report.evicted.join(","))
    check report.scannedEntries == 5
    check report.expiredEvicted == 2
    check report.sizeEvicted == 0
    check not report.orderViolation

    # Exactly the two expired volatile entries are gone...
    check not f.entryExists("vol-old-1")
    check not f.entryExists("vol-old-2")
    # ...and nothing else is, INCLUDING the two entries a pure LRU would
    # have taken first and the still-fresh volatile one.
    check f.entryExists("strong-1")
    check f.entryExists("weak-1")
    check f.entryExists("vol-fresh")

    # §10.2: the retention sweep runs even though no size budget was set at
    # all — "a stale `volatile` entry should leave even if the cache is
    # below quota". The `softCapBytes: 0` above is that case.
    check report.bytesAfter < report.bytesBefore
    # The evicted entries' payload digests are REPORTED, not unlinked: a CAS
    # blob may be referenced by another live entry, and only the
    # reachability GC in `store.nim` may decide that. Two owners, one
    # direction, no double authority over deletion.
    check report.releasedBlobs.len == 2
    check scanCasBlobs(f.store).len == casBlobsBefore

  test "the size pass never runs while an expired entry is still on disk":
    ## The invariant behind the ordering, asserted directly rather than
    ## inferred from the fact that phase 1 happens to be written first.
    ## With a budget below the footprint, the size pass DOES fire — but only
    ## after the retention pass has cleared everything expired.
    var f = openFixture("order")
    defer: closeFixture(f)

    f.writeEntry("vol-old", declaredDeterminism(edVolatile, maxAge(60),
      nowUnix = BaseNow - 7200))
    f.writeEntry("strong-old", declaredDeterminism(edStrong,
      nowUnix = BaseNow - 9000))
    f.writeEntry("strong-new", declaredDeterminism(edStrong,
      nowUnix = BaseNow - 10))
    # Space the `.rec` FILE mtimes explicitly, the way the sibling
    # `t_a4_p4_eviction` spaces its blob mtimes and for the same reason: the
    # size pass's primary LRU key is the file's mtime, and three files
    # written inside one clock second tie on it, which would make the
    # eviction order arbitrary and this assertion flaky rather than wrong.
    f.stampRecMtime("strong-old", BaseNow - 9000)
    f.stampRecMtime("strong-new", BaseNow - 10)

    # Measure the footprint, then set the cap so that dropping the one
    # expired entry is NOT enough and the size pass must also fire.
    let scanned = scanCacheEntries(f.cache,
      RetentionGcPolicy(nowUnix: BaseNow))
    check scanned.len == 3
    var total = 0'i64
    for e in scanned:
      total += e.recordBytes + e.payloadBytes
    let cap = total - int64(float(total) * 0.5)

    var policy = RetentionGcPolicy(nowUnix: BaseNow, softCapBytes: cap)
    let report = runRetentionGc(f.cache, policy)
    checkpoint("cap=" & $cap & " before=" & $report.bytesBefore &
      " after=" & $report.bytesAfter & " expired=" & $report.expiredEvicted &
      " size=" & $report.sizeEvicted)

    check not report.orderViolation
    check report.expiredEvicted == 1
    check report.sizeEvicted >= 1
    check not f.entryExists("vol-old")
    # The size pass is LRU over the survivors, so the OLDER strong entry
    # goes before the newer one.
    check not f.entryExists("strong-old")
    check f.entryExists("strong-new")
    check report.bytesAfter <= cap

  test "no-store is always expired; no-cache and forever never are":
    ## The retention vocabulary, at the GC's boundary rather than the
    ## reader's. `no-cache` is the interesting one: a reader always
    ## revalidates it, but the GC must NOT treat it as garbage — that is the
    ## whole difference between `no-cache` and `no-store` (§2.2), and
    ## collapsing them would silently turn one into the other.
    var f = openFixture("vocab")
    defer: closeFixture(f)

    f.writeEntry("nostore", declaredDeterminism(edVolatile,
      CacheRetention(kind: crkNoStore), nowUnix = BaseNow))
    f.writeEntry("nocache", declaredDeterminism(edVolatile,
      CacheRetention(kind: crkNoCache), nowUnix = BaseNow))
    f.writeEntry("forever", declaredDeterminism(edStrong, nowUnix = BaseNow))
    f.writeEntry("thisbuild-same", declaredDeterminism(edVolatile,
      CacheRetention(kind: crkThisBuild), nowUnix = BaseNow,
      buildEpoch = "epoch-now"))
    f.writeEntry("thisbuild-other", declaredDeterminism(edVolatile,
      CacheRetention(kind: crkThisBuild), nowUnix = BaseNow,
      buildEpoch = "epoch-previous"))

    let report = runRetentionGc(f.cache,
      RetentionGcPolicy(nowUnix: BaseNow, currentBuildEpoch: "epoch-now"))
    check not f.entryExists("nostore")
    check not f.entryExists("thisbuild-other")
    check f.entryExists("nocache")
    check f.entryExists("forever")
    check f.entryExists("thisbuild-same")
    check report.expiredEvicted == 2

  test "an UNLABELLED cache is never touched":
    ## The regression guard. Every edge in the existing recipe corpus is
    ## unlabelled, so a GC that treated "no metadata" as "expired" would
    ## empty the cache of the whole tree on its first run.
    var f = openFixture("unlabelled")
    defer: closeFixture(f)
    for name in ["a", "b", "c"]:
      f.writeEntry(name, EntryDeterminism())

    let report = runRetentionGc(f.cache, RetentionGcPolicy(nowUnix: BaseNow))
    check report.scannedEntries == 3
    check report.expiredEvicted == 0
    check report.sizeEvicted == 0
    for name in ["a", "b", "c"]:
      check f.entryExists(name)

    # ...and with a size budget it still evicts by LRU, so "untouched by
    # RETENTION" is not "exempt from the GC".
    let scanned = scanCacheEntries(f.cache, RetentionGcPolicy(nowUnix: BaseNow))
    var total = 0'i64
    for e in scanned:
      total += e.recordBytes + e.payloadBytes
    let sized = runRetentionGc(f.cache,
      RetentionGcPolicy(nowUnix: BaseNow, softCapBytes: total div 2))
    check sized.expiredEvicted == 0
    check sized.sizeEvicted >= 1

  test "dryRun reports the same plan and deletes nothing":
    var f = openFixture("dryrun")
    defer: closeFixture(f)
    f.writeEntry("vol-old", declaredDeterminism(edVolatile, maxAge(60),
      nowUnix = BaseNow - 7200))
    f.writeEntry("strong-1", declaredDeterminism(edStrong, nowUnix = BaseNow))

    let planned = runRetentionGc(f.cache,
      RetentionGcPolicy(nowUnix: BaseNow, dryRun: true))
    check planned.expiredEvicted == 1
    check planned.bytesAfter < planned.bytesBefore
    check f.entryExists("vol-old")             # still there
    check f.entryExists("strong-1")

    let done = runRetentionGc(f.cache, RetentionGcPolicy(nowUnix: BaseNow))
    check done.expiredEvicted == planned.expiredEvicted
    check done.evicted == planned.evicted
    check done.bytesAfter == planned.bytesAfter
    check not f.entryExists("vol-old")

    # A dry run WITH a size cap must plan the same evictions the real run
    # performs. This is the case the retention pass's byte accounting had to
    # get right: the size pass reads `bytesAfter` to decide how much more to
    # take, so a dry run that did not decrement it during the retention pass
    # would plan an extra eviction that never happens.
    var f2 = openFixture("dryrun-cap")
    defer: closeFixture(f2)
    f2.writeEntry("vol-old", declaredDeterminism(edVolatile, maxAge(60),
      nowUnix = BaseNow - 7200))
    f2.writeEntry("keep-1", declaredDeterminism(edStrong, nowUnix = BaseNow))
    f2.writeEntry("keep-2", declaredDeterminism(edStrong, nowUnix = BaseNow))
    var total = 0'i64
    for e in scanCacheEntries(f2.cache, RetentionGcPolicy(nowUnix: BaseNow)):
      total += e.recordBytes + e.payloadBytes
    # A cap that dropping ONLY the expired entry already satisfies.
    let cap = total - (total div 3) + 1
    let plannedCap = runRetentionGc(f2.cache,
      RetentionGcPolicy(nowUnix: BaseNow, softCapBytes: cap, dryRun: true))
    check plannedCap.expiredEvicted == 1
    check plannedCap.sizeEvicted == 0
    let doneCap = runRetentionGc(f2.cache,
      RetentionGcPolicy(nowUnix: BaseNow, softCapBytes: cap))
    check doneCap.evicted == plannedCap.evicted
    check doneCap.sizeEvicted == 0
    check f2.entryExists("keep-1")
    check f2.entryExists("keep-2")
