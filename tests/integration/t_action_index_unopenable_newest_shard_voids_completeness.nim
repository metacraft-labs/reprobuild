## Action-Cache-Per-Edge-Store.md §6.4, §6.7, §8 step 2, §10 "Growth failure":
## an insert that cannot reach the newest shard is a growth failure, and a
## growth failure voids every completeness claim in the chain.
##
## Regression test for reprobuild-pm
## `issues/2026-11-18-gset-insert-saturates-without-signalling-when-the-newest-shard-will-not-open.md`.
##
## THE FAILURE. A file that is not a shard of this chain can hold the next
## shard's name (`index.shard1`): a grown shard from another boot, another
## layout, a file too short to hold a header. Growth finds the name taken and
## treats the file as a racer's shard, the chain count moves past it, and from
## then on every insert
## finds a newest shard it cannot map. nim-shm-gset `7bc81ad` returned
## `isSaturated` there WITHOUT bumping `growthFailed`, and the store discards
## the insert result, so an `edge-complete` claim written before that point was
## still honoured while new records never reached the index: a false
## completeness claim, i.e. a lookup that answers "no record" with zero
## filesystem operations for an edge that has one.
##
## Falsifiable: against nim-shm-gset `7bc81ad` the claim below stays complete
## and `growthFailed` stays 0.
##
## NO MOCKS. A real chain over real `mmap(MAP_SHARED)` shard files under a real
## temp cache root; the planted file is real bytes on disk.

import std/[os, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.unopenable-shard.weak." & name),
    hdActionFingerprint)

proc strongFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.unopenable-shard.strong." & name),
    hdActionFingerprint)

when defined(linux) or defined(macosx):
  suite "action index: an unopenable newest shard voids completeness":
    test "a foreign file at the growth name is signalled and voids the claim":
      let root = createTempDir("repro-unopenable-shard-", "")
      defer: removeDir(root)
      let idx = openActionIndex(root)
      require idx.attached

      # A complete edge, written before anything goes wrong.
      let claimed = weakFor("claimed-edge")
      check idx.insertRecord(claimed, strongFor("claimed-0")) == isInserted
      check idx.insertEdgeComplete(claimed) == isInserted
      check idx.enumerateEdge(claimed).complete
      check idx.growthFailed() == 0

      # A file that is not a shard sits at the name growth will link to.
      # Larger than a shard header, so it fails on the header, not on size.
      let shard1 = root / "action-index" / "index.shard1"
      writeFile(shard1, repeat('X', 64 * 1024))

      # Fill shard0 past its load threshold. Growth loses its exclusive link
      # to the planted file, and every later insert finds a newest shard it
      # cannot map.
      var saturated = 0
      var i = 0
      while saturated == 0 and i < 2_000_000:
        let w = weakFor("filler-" & $i)
        if idx.insertRecord(w, strongFor("filler-" & $i)) == isSaturated:
          inc saturated
        inc i
      check saturated > 0          # the planted file did block growth

      # §10: signalled, never silent. §8 step 2: the claim is now void.
      check idx.growthFailed() > 0
      check not idx.enumerateEdge(claimed).complete
      closeActionIndex(idx)
