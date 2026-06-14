## A4 P4 — LRU eviction policy gate.
##
## Drives the ``libs/repro_local_store`` LRU eviction primitive
## against a freshly-provisioned store:
##
##   1. Soft-cap eviction: push 50 distinct 1 MiB blobs (50 MiB total)
##      into a store with a 30 MiB soft cap. After ``evictToSoftCap``
##      the footprint must be <= 30 MiB AND the EVICTED entries must
##      be the OLDEST (by mtime).
##   2. Pin protection: pin the oldest blob (which would otherwise
##      be evicted first); push more blobs; assert that pin is still
##      on disk after eviction.
##   3. Pin-list parsing: comments, blanks, inline ``#`` trailing
##      comments tolerated; bad hex tolerated; lowercased on parse.
##   4. Hard-cap projection: ``willExceedHardCap`` returns true when
##      currentBytes + incomingBytes > hardCap.
##
## Notes:
##   * We use 1 MiB synthetic blobs (not the 60 GB spec scale) so the
##     test runs in a few seconds. The eviction policy is size-driven;
##     the scale invariants hold at any size.
##   * Blob timestamps are spaced via explicit ``os.setLastModificationTime``
##     so the LRU ordering is deterministic regardless of how fast the
##     storeCasBlob loop runs.

import std/[algorithm, os, random, sequtils, sets, strutils,
            tempfiles, times, unittest]

import repro_local_store

proc setMtime(path: string; unixSec: int64) =
  ## Force a specific mtime so the LRU policy's deterministic
  ## ordering is independent of how fast the test loop runs.
  let t = fromUnix(unixSec)
  setLastModificationTime(path, t)

suite "A4 P4 — LRU eviction policy":
  test "evictToSoftCap drops oldest unpinned blobs":
    randomize()
    let root = createTempDir("a4p4-evict-", "")
    defer:
      try: removeDir(root) except OSError: discard
    var store = openStore(root)
    defer: close(store)

    const blobCount = 50
    const blobSize = 1024 * 1024     # 1 MiB
    var digests: seq[PrefixIdBytes] = @[]

    # Push 50 distinct blobs. Each gets a unique pattern so digests
    # don't collide.
    for i in 0 ..< blobCount:
      var blob = newSeq[byte](blobSize)
      for j in 0 ..< blobSize:
        blob[j] = byte((j + i * 7919) and 0xff)
      let d = storeCasBlob(store, blob)
      digests.add(d)

    # Stamp mtimes ascending: blob 0 is oldest, blob (N-1) is newest.
    let nowSec = toUnix(getTime())
    for i in 0 ..< blobCount:
      let path = store.casPath(digests[i])
      setMtime(path, nowSec - int64(blobCount - i) * 60)

    let policy = newLruEvictionPolicy(
      softCapBytes = 30 * 1024 * 1024,           # 30 MiB
      hardCapBytes = 100 * 1024 * 1024)          # not exercised here
    let before = currentFootprintBytes(store)
    check before >= int64(blobCount) * int64(blobSize) - 1024  ## slack

    let report = evictToSoftCap(policy, store)
    check report.evictedCount > 0
    check report.bytesAfter <= policy.softCapBytes

    # The oldest blobs (lowest indices) must be the ones evicted.
    let evictedSet = toHashSet(report.evictedKeys)
    var maxEvictedIdx = -1
    var minSurvivorIdx = blobCount
    const HexChars = "0123456789abcdef"
    proc digestHex(d: PrefixIdBytes): string =
      result = newStringOfCap(64)
      for b in d:
        result.add(HexChars[int(b shr 4) and 0xf])
        result.add(HexChars[int(b) and 0xf])
    for i in 0 ..< blobCount:
      let hex = digestHex(digests[i])
      if hex in evictedSet:
        if i > maxEvictedIdx: maxEvictedIdx = i
      else:
        if i < minSurvivorIdx: minSurvivorIdx = i
    check maxEvictedIdx < minSurvivorIdx
    # The footprint after eviction matches the running tally.
    let footAfter = currentFootprintBytes(store)
    check footAfter == report.bytesAfter

  test "pinned blob survives eviction":
    randomize()
    let root = createTempDir("a4p4-pin-", "")
    defer:
      try: removeDir(root) except OSError: discard
    var store = openStore(root)
    defer: close(store)

    const blobCount = 20
    const blobSize = 1024 * 1024
    var digests: seq[PrefixIdBytes] = @[]
    for i in 0 ..< blobCount:
      var blob = newSeq[byte](blobSize)
      for j in 0 ..< blobSize:
        blob[j] = byte((j + i * 8009) and 0xff)
      digests.add(storeCasBlob(store, blob))

    let nowSec = toUnix(getTime())
    for i in 0 ..< blobCount:
      setMtime(store.casPath(digests[i]),
               nowSec - int64(blobCount - i) * 60)

    # Pin the oldest blob — it would otherwise be evicted first.
    const HexChars = "0123456789abcdef"
    proc digestHex(d: PrefixIdBytes): string =
      result = newStringOfCap(64)
      for b in d:
        result.add(HexChars[int(b shr 4) and 0xf])
        result.add(HexChars[int(b) and 0xf])
    let pinHex = digestHex(digests[0])
    let policy = newLruEvictionPolicy(
      softCapBytes = 5 * 1024 * 1024,
      hardCapBytes = 100 * 1024 * 1024,
      pins = toHashSet(@[pinHex]))
    let report = evictToSoftCap(policy, store)
    check report.evictedCount > 0
    check report.skippedPinned >= 1
    check fileExists(store.casPath(digests[0]))     ## pin survives

  test "pin list parses comments + blanks + inline comments":
    let text = """
# leading comment
# another comment

0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789  # trailing inline
   fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
"""
    let pins = parsePinList(text)
    check pins.len == 3
    check "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" in pins
    check "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" in pins
    check "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" in pins

  test "hard-cap projection":
    let policy = newLruEvictionPolicy(
      softCapBytes = 50_000,
      hardCapBytes = 100_000)
    check willExceedHardCap(policy, currentBytes = 50_000, incomingBytes = 49_999) == false
    check willExceedHardCap(policy, currentBytes = 50_000, incomingBytes = 50_001) == true
    check willExceedHardCap(policy, currentBytes = 100_000, incomingBytes = 1) == true
