## Peer-Cache-Scale M2 verification test: DiskStore LRU eviction.
##
## Construct a `DiskStore` with `maxBytes = 1024`; insert 4 × 600B
## blobs. The cumulative payload (2400 B) exceeds the cap by ~2.3x;
## eviction must drop the oldest entries to keep `currentBytes <=
## maxBytes`. `evictionCount > 0`. Evicted blobs are no longer
## retrievable via `load`. The most-recently-stored blob is still
## present.
##
## See `Peer-Cache-Scale.milestones.org` §M2 verification list.

import std/[options, os, sequtils, unittest]

import repro_peer_cache

proc digestN(tag: byte): BlobDigest =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(tag) * 31 + i * 13 + 7) and 0xff)
  blobDigestFromBytes(raw)

proc payloadN(tag: byte; size: int): seq[byte] =
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = byte((int(tag) * 7 + i) and 0xff)

suite "peer-cache-scale M2 DiskStore LRU eviction policy":
  test "1024-cap store evicts oldest to keep currentBytes <= maxBytes":
    let tmpDir = getTempDir() / "repro_peer_cache_m2_disk_evict"
    if dirExists(tmpDir):
      removeDir(tmpDir)
    let ds = newDiskStore(tmpDir, maxBytes = 1024'u64)

    var digests: array[4, BlobDigest]
    for i in 0 ..< 4:
      digests[i] = digestN(byte(i + 1))
      # Sleep a few ms between writes so the underlying filesystem's
      # mtime values are distinct even on coarse-resolution mounts
      # (tmpfs/btrfs nanosecond-accurate, ext4 sub-ms, NFS may round
      # to 1 s). Without this, two consecutive `store` calls could
      # share an mtime and the LRU sort would be ambiguous.
      if i > 0:
        sleep(20)
      let ok = ds.store(digests[i], payloadN(byte(i + 1), 600))
      check ok

    # After 4 × 600B inserts with a 1024B cap, at most one 600B blob
    # fits at a time; we expect 3 evictions and only the last blob
    # to survive.
    check ds.currentBytes <= ds.maxBytes
    check ds.evictionCount > 0'u64

    # The most recently stored digest survives.
    let lastLoad = ds.load(digests[3])
    check lastLoad.isSome
    check lastLoad.get().len == 600

    # The oldest blob (index 0) is gone.
    let firstLoad = ds.load(digests[0])
    check firstLoad.isNone

    # The remaining digests (other than the last) should also be
    # gone, given the cap arithmetic.
    var survivors = 0
    for i in 0 ..< 4:
      if ds.load(digests[i]).isSome:
        inc survivors
    check survivors == 1

    removeDir(tmpDir)
