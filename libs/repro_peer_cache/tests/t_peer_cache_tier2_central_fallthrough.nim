## Peer-Cache-Scale M2 verification test: tier-2 fall-through to the
## central upstream cache on local miss.
##
## A `Tier2Cache` is constructed with an empty disk store and a stub
## `UpstreamCacheClient`. The first `lookup(D)` misses the disk
## store, hits the upstream stub, populates the disk store, returns
## the blob, and bumps `upstreamHits`. The second `lookup(D)` hits
## the disk store directly and bumps `localHits`. The upstream stub
## records how many times it was invoked so the test can verify the
## fall-through happened exactly once.
##
## See `Peer-Cache-Scale.milestones.org` §M2 verification list.

import std/[options, os, tables, unittest]

import blake3

import repro_peer_cache

proc digestFor(payload: openArray[byte]): BlobDigest =
  blobDigestFromBytes(blake3.digest(payload))

proc peerIdN(tag: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(tag) + 11 * i + 3) and 0xff)
  peerIdFromBytes(raw)

proc makeUpstreamStub(store: TableRef[BlobDigest, seq[byte]];
                     counter: ref int): UpstreamCacheClient =
  ## Closure built at top level so the captured `store` / `counter`
  ## refs are proc parameters rather than globals — Nim's gc-safety
  ## analysis would otherwise reject the lifted environment.
  result = proc(d: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    inc counter[]
    if store[].hasKey(d):
      some(store[][d])
    else:
      none(seq[byte])

suite "peer-cache-scale M2 tier-2 central fall-through":
  test "missing blob is fetched from upstream, cached, served from disk next time":
    let tmpDir = getTempDir() / "repro_peer_cache_m2_tier2_fallthrough"
    if dirExists(tmpDir):
      removeDir(tmpDir)
    let ds = newDiskStore(tmpDir, maxBytes = 1024 * 1024'u64)
    let selfPeerId = peerIdN(0x77)
    let registry = newPeerRegistry(selfPeerId,
                                   initEndpoint("127.0.0.1", Port(0)))

    let payload: seq[byte] = @[byte 0xCA, 0xFE, 0xBA, 0xBE,
                               0x10, 0x20, 0x30, 0x40]
    let digest = digestFor(payload)

    # The upstream stub reads from a heap-allocated `TableRef` so the
    # closure captures a `ref` rather than a stack-local `seq` — the
    # `gcsafe` annotation on `UpstreamCacheClient` requires references
    # to GC'd data to be reached through a `ref`/`ptr` form.
    let upstreamStore = newTable[BlobDigest, seq[byte]]()
    upstreamStore[digest] = payload
    let callCounter = new(int)
    callCounter[] = 0
    let upstream = makeUpstreamStub(upstreamStore, callCounter)

    let tier = newTier2Cache(ds, registry, upstream)
    check tier.localHits == 0'u64
    check tier.upstreamHits == 0'u64

    # First lookup: disk miss → upstream hit → cached → returned.
    let first = tier.lookup(digest)
    check first.isSome
    check first.get() == payload
    check tier.upstreamHits == 1'u64
    check tier.localHits == 0'u64
    check callCounter[] == 1
    check ds.has(digest)
    # Registry self-advertised set carries the digest now.
    let snapshot = registry.snapshotFor(peerIdN(0x99))
    var foundInSnapshot = false
    for d in snapshot.added:
      if d == digest:
        foundInSnapshot = true
        break
    check foundInSnapshot

    # Second lookup: disk hit. Upstream stub is NOT invoked again.
    let second = tier.lookup(digest)
    check second.isSome
    check second.get() == payload
    check tier.localHits == 1'u64
    check tier.upstreamHits == 1'u64
    check callCounter[] == 1

    removeDir(tmpDir)
