## Size-budgeted, least-recently-used garbage collection of a whole store
## root: `repro store gc --budget`.
##
## Spec: reprobuild-pm `spec/Shared-Store-Budgeted-Eviction.md` §5.
##
## `Store.gc` collects by REACHABILITY: every prefix no root holds goes. That
## is the right collector for a private store and the wrong one for a store
## that is a cache, where most of what is unreachable is exactly what the next
## job will want. A cache is bounded by SIZE, and what it gives up first is
## what was used least recently. This module is that collector. One run:
##
##   1. Expire roots whose TTL has passed (`expireRoots`), so a holder that
##      died stops holding.
##   2. Measure the store root: realized prefixes (size cached in the index),
##      action-cache entries (`<root>/action-cache`, `.rec` plus sidecars),
##      CAS blobs (`cas/blake3`, each counted as its size divided by its link
##      count, so a blob hardlinked into a prefix is not counted twice in
##      full) and trees already quarantined in `gc/pending-deletion/`.
##   3. At or under the budget: stop. Over it: evict down to the target, least
##      recently used first, over three kinds of object:
##        * a prefix no root holds — last use is the index's `last_used_at`
##          (`touchPrefix`, recorded when realize finds it present), else its
##          creation;
##        * an action-cache entry — last use is the newest of its `.rec`'s
##          write time and the recorded use of the blobs it restores, because
##          a cache hit materializes those blobs and `touchCasBlob` records
##          that;
##        * with `evictCas`, a CAS blob nothing left in the action cache
##          references — last use is `cas_use`, else its write time. A blob
##          becomes a candidate when the last entry referring to it goes.
##      Nothing used within `keepRecentSeconds` is evicted. When that window
##      stops the run short of the target, the report says so
##      (`unreachable`, `stoppedAtKeepWindow`) instead of reaching further.
##   4. Unlink quarantined trees whose grace has passed, and audit the run.
##
## CAS EVICTION IS OPT-IN (`evictCas`). In a store where the action cache is
## the only thing that refers to CAS blobs — a shared CI store, which holds
## `action-cache/` and `cas/` and nothing else — a blob no entry references is
## garbage. In a user's store it is not: home generations, launch plans and
## binary-cache manifests refer to blobs by digest, and nothing indexes those
## references. Without `evictCas` the CAS is measured and counted against the
## budget but never touched, so the report can say the budget is unreachable.
##
## Prefixes go through `gcPrefix`, which refuses one a root has started
## holding since the measurement; action-cache entries and blobs are removed
## directly. An action-cache entry or a blob that a concurrent writer is
## reusing has its use recorded first, and the blob is re-checked just before
## it is unlinked, so the window in which a build can lose a blob it is
## adopting is the few instructions between that check and the unlink.

import std/[algorithm, heapqueue, json, os, strutils, tables, times]

from repro_core/paths import extendedPath

import ../repro_local_store

type
  BudgetGcPolicy* = object
    budgetBytes*: int64
      ## Above this, a run evicts.
    targetBytes*: int64
      ## What an over-budget run evicts down to; 0 means 90% of the budget.
    keepRecentSeconds*: int64
      ## Never evict an object used more recently than this.
    graceSeconds*: int
      ## Unlink grace for quarantined prefixes (`DefaultGcGraceSeconds`).
    evictCas*: bool
      ## Assert that the action cache is the only referrer of CAS blobs in
      ## this store root, and allow unreferenced blobs to be evicted.
    nowUnix*: int64
      ## Injected clock; 0 reads the wall clock.
    dryRun*: bool
      ## Measure and plan only: no root expires, nothing is removed, no size
      ## is cached.

  BudgetObjectKind* = enum
    bokPrefix = "prefix"
    bokActionEntry = "action-cache"
    bokCasBlob = "cas"

  BudgetEviction* = object
    kind*: BudgetObjectKind
    id*: string
    bytes*: int64
    lastUsedUnix*: int64

  BudgetGcReport* = object
    ranAt*: int64
    budgetBytes*: int64
    targetBytes*: int64
    expiredRoots*: seq[string]
    prefixBytes*: int64
    actionCacheBytes*: int64
    casBytes*: int64
    pendingBytes*: int64
    bytesBefore*: int64
    bytesAfter*: int64
    freedBytes*: int64
    evicted*: seq[BudgetEviction]
    refusedPrefixes*: int
      ## Prefixes `gcPrefix` refused because a root held them by then.
    unreachable*: bool
      ## Over budget after the run: everything left is held, inside the keep
      ## window, or (without `evictCas`) CAS.
    stoppedAtKeepWindow*: bool
    reclaimed*: seq[string]
    dryRun*: bool

  CasBlob = object
    hex: string
    path: string
    share: int64
    lastUsed: int64
    refs: int

  Candidate = object
    lastUsed: int64
    order: int
    kind: BudgetObjectKind
    index: int

proc `<`(a, b: Candidate): bool =
  if a.lastUsed != b.lastUsed: a.lastUsed < b.lastUsed
  else: a.order < b.order

proc parseDigestHex(hex: string; digest: var PrefixIdBytes): bool =
  if hex.len != 64:
    return false
  for i in 0 ..< 32:
    try:
      digest[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
    except ValueError:
      return false
  true

proc treeBytes(path: string): int64 =
  ## Sum of the sizes of the regular files under `path`, links not followed.
  if not dirExists(extendedPath(path)):
    return 0
  for entry in walkDirRec(extendedPath(path), yieldFilter = {pcFile},
                          followFilter = {pcDir}):
    try:
      result += getFileInfo(entry, followSymlink = false).size
    except OSError:
      discard

proc pendingBytes(path: string): int64 =
  if not dirExists(extendedPath(path)):
    return 0
  for kind, entry in walkDir(extendedPath(path)):
    case kind
    of pcDir: result += treeBytes(entry)
    of pcFile:
      try: result += getFileInfo(entry, followSymlink = false).size
      except OSError: discard
    else: discard

proc scanCas(s: Store; uses: Table[string, int64]): seq[CasBlob] =
  let blobRoot = s.root / "cas" / "blake3"
  if not dirExists(extendedPath(blobRoot)):
    return
  for shardKind, shardPath in walkDir(extendedPath(blobRoot)):
    if shardKind != pcDir:
      continue
    let shard = extractFilename(shardPath)
    if shard.len != 2:
      continue
    for kind, path in walkDir(shardPath):
      if kind != pcFile:
        continue
      let name = extractFilename(path)
      if name.len != 64 or not name.startsWith(shard):
        continue
      var blob = CasBlob(hex: name.toLowerAscii, path: path)
      try:
        let info = getFileInfo(path, followSymlink = false)
        let links = max(1'i64, int64(info.linkCount))
        blob.share = info.size div links
        blob.lastUsed = info.lastWriteTime.toUnix
      except OSError:
        continue
      blob.lastUsed = max(blob.lastUsed, uses.getOrDefault(blob.hex, 0))
      result.add(blob)

proc casLastUsedNow(s: Store; blob: CasBlob): int64 =
  ## The blob's last use as it stands right now, for the re-check before an
  ## unlink: a writer may have adopted it since the scan.
  var digest: PrefixIdBytes
  if not parseDigestHex(blob.hex, digest):
    return high(int64)
  result = 0
  try:
    result = getLastModificationTime(extendedPath(blob.path)).toUnix
  except OSError:
    return high(int64)
  result = max(result, s.casLastUseTable().getOrDefault(blob.hex, 0))

proc budgetGc*(storeRoot: string; policy: BudgetGcPolicy): BudgetGcReport =
  ## Run one budget GC over `storeRoot`. See the module header.
  if policy.budgetBytes <= 0:
    raise newException(ValueError, "budget must be positive")
  let now = if policy.nowUnix != 0: policy.nowUnix else: getTime().toUnix
  let target =
    if policy.targetBytes > 0: policy.targetBytes
    else: policy.budgetBytes div 10 * 9
  if target > policy.budgetBytes:
    raise newException(ValueError, "target must not exceed the budget")
  result.ranAt = now
  result.budgetBytes = policy.budgetBytes
  result.targetBytes = target
  result.dryRun = policy.dryRun
  let grace =
    if policy.graceSeconds > 0: policy.graceSeconds
    else: DefaultGcGraceSeconds

  var s = openStore(storeRoot)
  defer: s.close()

  if not policy.dryRun:
    result.expiredRoots = s.expireRoots(now)

  # --- Measure -------------------------------------------------------------
  var prefixes = s.prefixUsage()
  for p in prefixes.mitems:
    if p.sizeBytes < 0:
      p.sizeBytes = treeBytes(s.absolutePrefixPath(p.row.realizedPath))
      if not policy.dryRun:
        s.setPrefixSize(p.row.prefixId, p.sizeBytes)
    result.prefixBytes += p.sizeBytes

  var entries: seq[CacheEntryRef] = @[]
  let actionRoot = storeRoot / "action-cache"
  if dirExists(extendedPath(actionRoot / "hot-records")):
    var cache = openActionCache(actionRoot, attachShm = false)
    entries = scanCacheEntries(cache, RetentionGcPolicy(nowUnix: now))
  for e in entries:
    result.actionCacheBytes += e.recordBytes

  var blobs = scanCas(s, s.casLastUseTable())
  var blobIndex = initTable[string, int]()
  for i, b in blobs:
    blobIndex[b.hex] = i
    result.casBytes += b.share
  var entryBlobs = newSeq[seq[int]](entries.len)
  var entryLastUsed = newSeq[int64](entries.len)
  for i, e in entries:
    entryLastUsed[i] = e.mtimeUnix
    var seen = initTable[int, bool]()
    for hex in e.blobDigests:
      let bi = blobIndex.getOrDefault(hex.toLowerAscii, -1)
      if bi < 0 or seen.hasKey(bi):
        continue
      seen[bi] = true
      entryBlobs[i].add(bi)
      inc blobs[bi].refs
      entryLastUsed[i] = max(entryLastUsed[i], blobs[bi].lastUsed)

  result.pendingBytes = pendingBytes(s.gcPendingRoot)
  result.bytesBefore = result.prefixBytes + result.actionCacheBytes +
    result.casBytes + result.pendingBytes
  result.bytesAfter = result.bytesBefore

  if result.bytesBefore > policy.budgetBytes:
    # --- Evict, least recently used first ---------------------------------
    let need = result.bytesBefore - target
    let cutoff = now - policy.keepRecentSeconds
    var heap = initHeapQueue[Candidate]()
    var order = 0
    for i, p in prefixes:
      if not p.held:
        heap.push(Candidate(lastUsed: p.lastUsedUnix, order: order,
          kind: bokPrefix, index: i))
        inc order
    for i in 0 ..< entries.len:
      heap.push(Candidate(lastUsed: entryLastUsed[i], order: order,
        kind: bokActionEntry, index: i))
      inc order
    if policy.evictCas:
      for i, b in blobs:
        if b.refs == 0:
          heap.push(Candidate(lastUsed: b.lastUsed, order: order,
            kind: bokCasBlob, index: i))
          inc order

    while result.freedBytes < need and heap.len > 0:
      let c = heap.pop()
      if c.lastUsed > cutoff:
        result.stoppedAtKeepWindow = true
        break
      case c.kind
      of bokPrefix:
        let p = prefixes[c.index]
        if not policy.dryRun:
          let r = s.gcPrefix(p.row.prefixId, grace)
          if r.refused or not r.found:
            inc result.refusedPrefixes
            continue
        result.freedBytes += p.sizeBytes
        result.evicted.add(BudgetEviction(kind: bokPrefix,
          id: p.row.realizedPath, bytes: p.sizeBytes, lastUsedUnix: c.lastUsed))
      of bokActionEntry:
        let e = entries[c.index]
        if not policy.dryRun and not removeCacheEntry(e):
          continue
        result.freedBytes += e.recordBytes
        result.evicted.add(BudgetEviction(kind: bokActionEntry,
          id: e.weakDirName & "/" & e.strongHex, bytes: e.recordBytes,
          lastUsedUnix: c.lastUsed))
        for bi in entryBlobs[c.index]:
          dec blobs[bi].refs
          if blobs[bi].refs == 0 and policy.evictCas:
            heap.push(Candidate(lastUsed: blobs[bi].lastUsed, order: order,
              kind: bokCasBlob, index: bi))
            inc order
      of bokCasBlob:
        let b = blobs[c.index]
        if not policy.dryRun:
          if casLastUsedNow(s, b) > cutoff:
            continue
          try:
            removeFile(extendedPath(b.path))
          except OSError:
            continue
          var digest: PrefixIdBytes
          if parseDigestHex(b.hex, digest):
            try: s.forgetCasUse(digest) except CatchableError: discard
        result.freedBytes += b.share
        result.evicted.add(BudgetEviction(kind: bokCasBlob, id: b.hex,
          bytes: b.share, lastUsedUnix: c.lastUsed))

    result.bytesAfter = result.bytesBefore - result.freedBytes
    result.unreachable = result.freedBytes < need

  if not policy.dryRun:
    result.reclaimed = s.sweepPendingDeletion(grace)
    if result.evicted.len > 0 or result.unreachable or
        result.expiredRoots.len > 0:
      var counts: array[BudgetObjectKind, int]
      for e in result.evicted:
        inc counts[e.kind]
      s.auditBudgetRun("budget " & $policy.budgetBytes & " target " &
        $target & ": " & $result.bytesBefore & " -> " & $result.bytesAfter &
        " bytes; evicted " & $counts[bokPrefix] & " prefixes, " &
        $counts[bokActionEntry] & " action-cache entries, " &
        $counts[bokCasBlob] & " CAS blobs; expired " &
        $result.expiredRoots.len & " roots" &
        (if result.unreachable: "; target unreachable" else: "") &
        (if result.stoppedAtKeepWindow: " (keep window)" else: ""))

proc renderBudgetGcText*(r: BudgetGcReport; storeRoot: string): string =
  var lines: seq[string] = @[]
  lines.add("repro store gc --budget: store-root=" & storeRoot &
    (if r.dryRun: " (dry run)" else: ""))
  lines.add("budget: " & $r.budgetBytes & " bytes, target " & $r.targetBytes)
  lines.add("measured: " & $r.bytesBefore & " bytes (prefixes " &
    $r.prefixBytes & ", action-cache " & $r.actionCacheBytes & ", cas " &
    $r.casBytes & ", pending-deletion " & $r.pendingBytes & ")")
  if r.expiredRoots.len > 0:
    lines.add("expired roots: " & r.expiredRoots.join(", "))
  var sorted = r.evicted
  sorted.sort(proc (a, b: BudgetEviction): int = cmp(a.lastUsedUnix, b.lastUsedUnix))
  for e in sorted:
    lines.add("evict " & $e.kind & " " & e.id & " " & $e.bytes &
      " bytes, last used " & $e.lastUsedUnix)
  lines.add("freed: " & $r.freedBytes & " bytes; store now " & $r.bytesAfter &
    " bytes")
  if r.refusedPrefixes > 0:
    lines.add("refused: " & $r.refusedPrefixes & " prefixes a root took hold of")
  if r.unreachable:
    lines.add("target unreachable: everything left is held by a root, " &
      (if r.stoppedAtKeepWindow: "used within the keep window" else: "not evictable") &
      ", or CAS without --evict-cas")
  lines.join("\n")

proc renderBudgetGcJson*(r: BudgetGcReport; storeRoot: string): string =
  proc esc(s: string): string = escapeJson(s)
  var ev: seq[string] = @[]
  for e in r.evicted:
    ev.add("{\"kind\":" & esc($e.kind) & ",\"id\":" & esc(e.id) &
      ",\"bytes\":" & $e.bytes & ",\"lastUsedUnix\":" & $e.lastUsedUnix & "}")
  var roots: seq[string] = @[]
  for x in r.expiredRoots: roots.add(esc(x))
  "{\"storeRoot\":" & esc(storeRoot) & ",\"dryRun\":" & $r.dryRun &
    ",\"ranAt\":" & $r.ranAt & ",\"budgetBytes\":" & $r.budgetBytes &
    ",\"targetBytes\":" & $r.targetBytes & ",\"bytesBefore\":" &
    $r.bytesBefore & ",\"bytesAfter\":" & $r.bytesAfter & ",\"freedBytes\":" &
    $r.freedBytes & ",\"prefixBytes\":" & $r.prefixBytes &
    ",\"actionCacheBytes\":" & $r.actionCacheBytes & ",\"casBytes\":" &
    $r.casBytes & ",\"pendingBytes\":" & $r.pendingBytes &
    ",\"unreachable\":" & $r.unreachable & ",\"stoppedAtKeepWindow\":" &
    $r.stoppedAtKeepWindow & ",\"refusedPrefixes\":" & $r.refusedPrefixes &
    ",\"expiredRoots\":[" & roots.join(",") & "],\"evicted\":[" &
    ev.join(",") & "]}"
