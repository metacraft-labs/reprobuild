## Action-Cache-Per-Edge-Store.md §6.3, §6.7 "Retirement", §8 step 2, §10
## "Growth failure": a reader that cannot map a shard whose file is still
## present has not seen that shard's elements, so no completeness claim may be
## honoured on the strength of its walk.
##
## Regression test for reprobuild-pm
## `issues/2026-11-18-gset-readers-skip-a-shard-they-cannot-map-without-signalling.md`.
##
## THE FAILURE. The reader walk skips a shard it cannot open. That is right for
## a shard a flatten retired: the file is gone and its live elements were
## copied forward first. It is wrong for a shard whose file is still there and
## that this process could not map (a descriptor limit, address-space
## pressure): the elements exist and the walk does not see them. nim-shm-gset
## `7bc81ad` could not tell the two apart and reported neither, so
## `enumerateEdge` answered "complete" from a walk that had missed
##
## - a record for the edge, so the lookup resolves a candidate set without the
##   newest candidate (or answers "no record" for an edge that has one); and
## - a tombstone withdrawing the claim, so a withdrawn claim is honoured again.
##
## Falsifiable: against nim-shm-gset `7bc81ad` both views below are `complete`
## and `growthFailed` stays 0.
##
## NO MOCKS. A real chain over real `mmap(MAP_SHARED)` shard files under a real
## temp cache root, a real second attach of it, and a real `EMFILE` from `open`
## produced by taking every descriptor the process may still open. The test
## covers that one cause; a map that fails for another reason takes the same
## path in the set and is covered by nim-shm-gset's own tests only as far as
## they go.

import std/[os, tempfiles, unittest]

import repro_hash
import repro_local_store

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.unmappable-shard.weak." & name),
    hdActionFingerprint)

proc strongFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.unmappable-shard.strong." & name),
    hdActionFingerprint)

when defined(linux) or defined(macosx):
  import std/posix

  template withNoDescriptorLeft(exhausted: untyped; body: untyped) =
    ## Run `body` while this process cannot open another descriptor, so an
    ## `open` in it fails with EMFILE. `exhausted` is set to whether that state
    ## was really reached. The soft limit is lowered first so the loop is
    ## short whatever limit the test inherited, and both the descriptors and
    ## the limit are given back even if `body` raises.
    var lim, saved: RLimit
    doAssert getrlimit(RLIMIT_NOFILE, lim) == 0
    saved = lim
    if lim.rlim_cur > 1024:
      lim.rlim_cur = 1024
      doAssert setrlimit(RLIMIT_NOFILE, lim) == 0
    var held: seq[cint] = @[]
    try:
      while true:
        let fd = posix.open("/dev/null", O_RDONLY)
        if fd < 0:
          exhausted = errno == EMFILE
          break
        held.add fd
      body
    finally:
      for fd in held: discard posix.close(fd)
      discard setrlimit(RLIMIT_NOFILE, saved)

  suite "action index: a shard a reader cannot map voids completeness":
    test "a walk that skipped a present shard is signalled and honours no claim":
      let root = createTempDir("repro-unmappable-shard-", "")
      defer: removeDir(root)
      let writer = openActionIndex(root)
      require writer.attached

      # Two complete edges, both written into shard0.
      let grew = weakFor("edge-that-gains-a-record")
      let withdrawn = weakFor("edge-whose-claim-is-withdrawn")
      check writer.insertRecord(grew, strongFor("grew-0")) == isInserted
      check writer.insertEdgeComplete(grew) == isInserted
      check writer.insertRecord(withdrawn, strongFor("withdrawn-0")) == isInserted
      check writer.insertEdgeComplete(withdrawn) == isInserted

      # Grow the chain, so the newest shard is no longer shard0.
      var i = 0
      while writer.shardCount() < 2 and i < 2_000_000:
        check writer.insertRecord(weakFor("filler-" & $i),
          strongFor("filler-" & $i)) == isInserted
        inc i
      require writer.shardCount() >= 2

      # Both of these land in the newest shard: a second key for the first
      # edge, and the tombstone that withdraws the second edge's claim.
      check writer.insertRecord(grew, strongFor("grew-1")) == isInserted
      check writer.evictEdgeComplete(withdrawn) == isInserted

      # What a reader that maps every shard sees.
      let whole = writer.enumerateEdge(grew)
      check whole.complete
      check whole.liveStrong.len == 2
      check not writer.enumerateEdge(withdrawn).complete
      check writer.growthFailed() == 0

      # A second attach maps shard0 and every other shard lazily. With no
      # descriptor left it cannot map the grown shards, whose files exist.
      let reader = openActionIndex(root)
      require reader.attached
      var exhausted = false
      var partial, revived: EdgeView
      var signalled: uint64
      withNoDescriptorLeft(exhausted):
        partial = reader.enumerateEdge(grew)
        revived = reader.enumerateEdge(withdrawn)
        signalled = reader.growthFailed()

      require exhausted                   # else the checks below prove nothing
      check partial.liveStrong.len == 1   # the walk really did miss the key
      # §8 step 2: neither claim is honoured on a walk that missed a shard.
      check not partial.complete
      check not revived.complete
      # §10: signalled, never silent, and chain-wide.
      check signalled > 0
      check writer.growthFailed() > 0
      check not writer.enumerateEdge(grew).complete
      closeActionIndex(reader)
      closeActionIndex(writer)
