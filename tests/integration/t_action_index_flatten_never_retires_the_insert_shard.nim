## Action-Cache-Per-Edge-Store.md §6.7 "Flattening", "Retirement": a flatten
## never drains or retires the shard that inserts still target.
##
## Regression test for reprobuild-pm
## `issues/2026-11-18-action-index-flatten-can-retire-the-live-newest-shard.md`.
##
## THE FAILURE. Inserts target the shard the chain COUNT names (count - 1).
## `shardCount` scans the directory as well, because a grower links its new
## shard before it bumps the count, so the directory can hold one more shard
## than the count says: a grower stopped between its `link` and its bump, or a
## file left at the next name. `flattenChain` took its range from the directory view
## (`1 ..< shardCount() - 1`), so in that state the range included the shard
## inserts still target. It "copied" that shard into itself (every copy
## returned `isExists`), marked it drained and unlinked it. Readers skip a
## drained or missing shard, so every element in it vanished from every lookup
## while an `edge-complete` claim held in an older shard stayed honoured: a
## lookup that answers "no record" with zero filesystem operations for an edge
## that has one. Later inserts went into the drained shard, returned
## `isInserted`, and were never seen again.
##
## THE PROPERTY. After a flatten, in that state, the edge still enumerates
## every record written for it, both the ones written before the flatten and
## the ones written after it, its completeness claim is still honoured, and
## nothing was counted as a growth failure. The last two are asserted so that
## the test cannot pass by the claim having been voided instead.
##
## Falsifiable: with `flattenChain` ranging over `shardCount()` (and a
## nim-shm-gset whose `markShardDrained` accepts the insert target) every
## `Held` check below fails, with the claim honoured and the record absent.
##
## NO MOCKS. Real chains over real `mmap(MAP_SHARED)` shard files under real
## temp cache roots. The stranded shard is a real, fully initialised, empty
## shard of the right index: it is produced by growing a twin chain one shard
## further and copying that file, which is byte-for-byte what a grower leaves
## behind when it stops between its `link` and its count bump.

import std/[os, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.flatten-insert-shard.weak." & name),
    hdActionFingerprint)

proc strongFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.flatten-insert-shard.strong." & name),
    hdActionFingerprint)

when actionIndexSupported:
  const WantedShards = 3

  proc shardPath(root: string; k: int): string =
    root / "action-index" / ("index.shard" & $k)

  proc growTo(idx: ActionIndex; shards: int; tag: string) =
    ## Insert distinct filler records until the chain has exactly `shards`
    ## shards. Growth is triggered by the insert that crosses the load factor
    ## and the new shard is created empty, so on return the newest shard holds
    ## nothing yet.
    var i = 0
    while idx.shardCount() < shards and i < 2_000_000:
      discard idx.insertRecord(weakFor(tag & "-filler-" & $i),
        strongFor(tag & "-filler-" & $i))
      inc i
    doAssert idx.shardCount() == shards, "the chain did not grow to " & $shards

  proc has(view: EdgeView; strong: ContentDigest): bool =
    for s in view.liveStrong:
      if s == strong: return true
    false

  proc holds(idx: ActionIndex; weak, strong: ContentDigest): bool =
    ## The record is enumerated for an edge whose completeness claim is
    ## honoured. On failure, say which of the two a lookup would have seen.
    let view = idx.enumerateEdge(weak)
    result = view.has(strong) and view.complete
    if not result:
      checkpoint("complete=" & $view.complete & ", record enumerated=" &
        $view.has(strong) & ", live keys=" & $view.liveStrong.len &
        (if view.complete and not view.has(strong):
          ": the claim is honoured and the record is gone, a false \"no record\""
         else: ""))

  type Outcome = object
    ## What one run of the scenario observed. The scenario is a proc so both
    ## cases share it; it returns facts and each case asserts on them, because
    ## a `check` inside a proc does not fail the test that called it.
    staged: bool              ## the chain reached the state under test
    flattened: bool           ## the flatten ran (it took the lock)
    lateHeld: bool            ## the record written before the flatten
    lateHeldFresh: bool       ## ... as a freshly attached process sees it
    afterInserted: bool       ## the insert after the flatten reported success
    afterHeld: bool           ## the record written after the flatten
    afterHeldFresh: bool
    heldAfterSecondFlatten: bool
    growthFailed: uint64      ## must stay 0: nothing was voided to get here

  proc holdsInFreshAttach(root: string; weak, strong: ContentDigest): bool =
    ## A process that maps the chain afresh cannot be reading a retired shard
    ## through an old mapping.
    let fresh = openActionIndex(root)
    if not fresh.attached: return false
    result = fresh.holds(weak, strong)
    closeActionIndex(fresh)

  proc runScenario(plant: proc (root: string)): Outcome =
    let root = createTempDir("repro-flatten-insert-shard-", "")
    defer: removeDir(root)
    let idx = openActionIndex(root)
    if not idx.attached: return
    defer: closeActionIndex(idx)

    # A complete edge. Its claim lands in shard0, which is never retired.
    let claimed = weakFor("claimed-edge")
    if idx.insertRecord(claimed, strongFor("claimed-0")) != isInserted: return
    if idx.insertEdgeComplete(claimed) != isInserted: return
    if not idx.enumerateEdge(claimed).complete: return

    # Grow, so that there are older shards to drain and a newest shard that
    # inserts target.
    idx.growTo(WantedShards, "main")

    # One more shard file appears at the next name, and the chain count is not
    # bumped: the directory now holds one shard more than the count that
    # inserts follow.
    plant(root)
    if idx.shardCount() != WantedShards + 1: return

    # A record for the claimed edge. It goes to the shard the count names,
    # which is now the second-highest index on disk.
    let late = strongFor("claimed-late")
    if idx.insertRecord(claimed, late) != isInserted: return
    if not idx.holds(claimed, late): return
    if idx.growthFailed() != 0: return
    result.staged = true

    result.flattened = idx.flattenChain()
    result.lateHeld = idx.holds(claimed, late)
    result.lateHeldFresh = holdsInFreshAttach(root, claimed, late)

    # A record written AFTER the flatten must be seen too: the shard inserts
    # target was not left drained.
    let after = strongFor("claimed-after-flatten")
    result.afterInserted = idx.insertRecord(claimed, after) == isInserted
    result.afterHeld = idx.holds(claimed, after)
    result.afterHeldFresh = holdsInFreshAttach(root, claimed, after)

    # A second flatten changes none of it.
    discard idx.flattenChain()
    result.heldAfterSecondFlatten = idx.holds(claimed, late) and
      idx.holds(claimed, after)
    result.growthFailed = idx.growthFailed()

  suite "action index: a flatten never retires the shard inserts target":

    test "a grower stopped between its link and its count bump":
      let seen = runScenario(proc (root: string) =
        # A twin chain grown one shard further. Its newest shard is a valid,
        # empty shard of index `WantedShards`: exactly what a grower has
        # linked when it stops before bumping the count.
        let twinRoot = createTempDir("repro-flatten-insert-shard-twin-", "")
        defer: removeDir(twinRoot)
        let twin = openActionIndex(twinRoot)
        doAssert twin.attached
        twin.growTo(WantedShards + 1, "twin")
        closeActionIndex(twin)
        copyFile(shardPath(twinRoot, WantedShards),
          shardPath(root, WantedShards)))
      require seen.staged
      check seen.flattened
      check seen.lateHeld
      check seen.lateHeldFresh
      check seen.afterInserted
      check seen.afterHeld
      check seen.afterHeldFresh
      check seen.heldAfterSecondFlatten
      check seen.growthFailed == 0

    test "a file that is not a shard, left at the next name":
      let seen = runScenario(proc (root: string) =
        writeFile(shardPath(root, WantedShards), repeat('X', 64 * 1024)))
      require seen.staged
      check seen.flattened
      check seen.lateHeld
      check seen.lateHeldFresh
      check seen.afterInserted
      check seen.afterHeld
      check seen.afterHeldFresh
      check seen.heldAfterSecondFlatten
      check seen.growthFailed == 0
