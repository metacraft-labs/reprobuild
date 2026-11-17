## Action-Cache-Per-Edge-Store.md §6.1 "Recreating a stale chain" — two
## engines that both judged a grown chain stale end up mapping ONE fresh chain.
##
## THE DEFECT THIS GUARDS. `openActionIndex` used to unlink every
## `index.shard*` file, with no lock, on any attach failure, then publish a
## fresh `shard0`. Engine A removed the stale chain and published a fresh one;
## engine B, still acting on its earlier stale judgement, then deleted A's fresh
## files and published its own. A and B mapped different inodes, and every
## claim written through A sat in an orphaned file: a split index.
##
## HOW THE INTERLEAVINGS ARE DRIVEN. `action_index` exposes a test-only
## schedule point, `actionIndexStaleChainHook` (nil in production), called at
## each window of the removal: after the stale judgement, after the anchor is
## opened, and after the locked file is re-judged stale. Engine B's hook runs
## engine A's WHOLE open at that point, then B continues. Both engines are in
## this one process, which is sound for this purpose: `flock(2)` locks belong
## to the open file description, so B's descriptor and A's separate `open` of
## the anchor contend exactly as two processes would
## (https://man7.org/linux/man-pages/man2/flock.2.html).
##
## A STALE CHAIN IS MADE BY REWRITING THE CREATOR BOOT ID. A real chain is
## grown past shard0 and every shard header's creator boot id is then changed
## to a value that is not this boot's — byte-for-byte what a chain left by the
## previous boot looks like to `headerCheck`. A growth temporary is dropped
## beside it, because §6.1 step 4 removes those too.
##
## NO MOCKS. Real chain files, real `mmap`, real `flock` and `link`.

import std/[algorithm, os, posix, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store/action_index
import shm_gset

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.stale-chain." & name),
    hdActionFingerprint)

proc strongFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.stale-chain.strong." & name),
    hdActionFingerprint)

proc write(idx: ActionIndex; name: string) =
  check idx.insertRecord(weakFor(name), strongFor(name)) != isUnavailable

proc sees(idx: ActionIndex; name: string): bool =
  idx.enumerateEdge(weakFor(name)).liveStrong.len > 0

const
  GrowthEdges = 3_000
    ## shard0 has 4,096 slots and grows at a load factor of 0.5, so this many
    ## distinct edges forces at least one grown shard: the stale chain has a
    ## `shard1` that must not survive its anchor.

proc shardFiles(cacheRoot: string): seq[string] =
  for kind, path in walkDir(cacheRoot / ActionIndexDirName):
    let name = path.extractFilename
    if kind == pcFile and name.startsWith("index.shard"):
      result.add name
  result.sort()

proc patchU64(path: string; off: int; mutate: proc (v: uint64): uint64) =
  var data = readFile(path)
  var v: uint64
  copyMem(addr v, addr data[off], 8)
  v = mutate(v)
  copyMem(addr data[off], addr v, 8)
  writeFile(path, data)

proc patchU32(path: string; off: int; mutate: proc (v: uint32): uint32) =
  var data = readFile(path)
  var v: uint32
  copyMem(addr v, addr data[off], 4)
  v = mutate(v)
  copyMem(addr data[off], addr v, 4)
  writeFile(path, data)

proc makeGrownChain(cacheRoot: string) =
  let idx = openActionIndex(cacheRoot)
  doAssert idx.attached, "the fixture chain must attach"
  for e in 0 ..< GrowthEdges:
    discard idx.insertRecord(weakFor("old-" & $e), strongFor("old-" & $e))
  doAssert idx.shardCount() >= 2, "the fixture chain must have grown"
  closeActionIndex(idx)

proc makeStaleChain(cacheRoot: string) =
  ## A grown chain whose every shard says it was created on another boot, plus
  ## a growth temporary left by a crash.
  makeGrownChain(cacheRoot)
  let dir = cacheRoot / ActionIndexDirName
  for name in shardFiles(cacheRoot):
    patchU64(dir / name, ShOffCreatorBootId,
      proc (v: uint64): uint64 = v xor 0x5eed_0f0d_b007_0001'u64)
  writeFile(dir / "index.shardtmp.1.1", "left by a crash")
  let probe = attachSetT(dir / ActionIndexAnchorName, AcIndexKey)
  doAssert not probe.available and probe.attachFailure() == afWrongBoot,
    "the fixture chain must be judged stale"

proc checkFreshChain(cacheRoot: string) =
  ## Nothing of the stale chain survives: exactly one anchor, no grown shard
  ## and no growth temporary.
  check shardFiles(cacheRoot) == @[ActionIndexAnchorName]

# --- the schedule point -----------------------------------------------------
#
# B's hook fires once, at `armedPoint`, and runs A's whole open there. It
# disarms itself first so A's own open (which calls the same hook) runs
# straight through.

var
  armedPoint: StaleChainPoint
  armed = false
  fired = false
  hookRoot = ""
  engineA: ActionIndex = nil
  hookError = ""

proc runEngineAAtPoint(point: StaleChainPoint)
    {.nimcall, gcsafe, raises: [].} =
  # The hook's type promises the engine neither a GC-unsafe access nor an
  # exception; this test is single-threaded and records any failure in
  # `hookError` for the test body to report.
  {.cast(gcsafe).}:
    if not armed or point != armedPoint: return
    armed = false
    fired = true
    try:
      engineA = openActionIndex(hookRoot)
      if engineA.attached:
        if engineA.insertRecord(weakFor("written-by-a"),
            strongFor("written-by-a")) == isUnavailable:
          hookError = "engine A could not write"
    except Exception as e:
      # `Exception`, not `CatchableError`: the open's raises are inferred
      # through unannotated library calls as `Exception`.
      hookError = e.msg

proc raceAt(cacheRoot: string; point: StaleChainPoint): ActionIndex =
  ## Open engine B on a stale chain, stopping it at `point` while engine A runs
  ## its whole open and writes. Returns engine B; engine A is in `engineA`.
  hookRoot = cacheRoot
  armedPoint = point
  armed = true
  fired = false
  engineA = nil
  hookError = ""
  actionIndexStaleChainHook = runEngineAAtPoint
  try:
    result = openActionIndex(cacheRoot)
  finally:
    actionIndexStaleChainHook = nil
    armed = false
  doAssert fired, "the schedule point " & $point & " was never reached"
  doAssert hookError == "", "engine A failed: " & hookError

suite "stale action-index chain recreation converges (§6.1)":
  test "a lone engine replaces a stale grown chain with one fresh shard":
    let root = createTempDir("repro-stale-chain-", "")
    defer: removeDir(root)
    makeStaleChain(root)
    let idx = openActionIndex(root)
    defer: closeActionIndex(idx)
    check idx.attached
    check idx.shardCount() == 1
    check not idx.sees("old-0")
    checkFreshChain(root)

  for point in [scpJudgedStale, scpOpened]:
    test "an engine stopped at " & $point & " converges on the other's chain":
      let root = createTempDir("repro-stale-chain-", "")
      defer: removeDir(root)
      makeStaleChain(root)
      let engineB = raceAt(root, point)
      defer:
        closeActionIndex(engineB)
        closeActionIndex(engineA)
      check engineA != nil and engineA.attached
      check engineB.attached
      if engineA != nil and engineA.attached and engineB.attached:
        engineB.write("written-by-b")
        # One chain: each engine sees the other's claim.
        check engineB.sees("written-by-a")
        check engineA.sees("written-by-b")
        # And a third engine opening afterwards sees both.
        let engineC = openActionIndex(root)
        defer: closeActionIndex(engineC)
        check engineC.attached
        check engineC.sees("written-by-a")
        check engineC.sees("written-by-b")
      checkFreshChain(root)

  test "an engine that meets the lock held declines and leaves the chain alone":
    # B holds the anchor's lock and has re-judged it stale; A runs its whole
    # open inside that window. A cannot take the lock within its bound, finds
    # the chain still stale, and declines (Tier 1 only) rather than remove
    # files under B. B then completes and owns the one fresh chain.
    let root = createTempDir("repro-stale-chain-", "")
    defer: removeDir(root)
    makeStaleChain(root)
    let engineB = raceAt(root, scpLockedStale)
    defer:
      closeActionIndex(engineB)
      closeActionIndex(engineA)
    check engineA != nil and not engineA.attached
    check engineA != nil and engineA.failure == afWrongBoot
    check engineB.attached
    engineB.write("written-by-b")
    let engineC = openActionIndex(root)
    defer: closeActionIndex(engineC)
    check engineC.attached
    check engineC.sees("written-by-b")
    checkFreshChain(root)

  test "a chain that fails to attach for another reason is left in place":
    # §6.1 "Only a stale chain is removed": a key-format skew may be a chain
    # that is live for every engine of the other version.
    let root = createTempDir("repro-stale-chain-", "")
    defer: removeDir(root)
    makeGrownChain(root)
    let dir = root / ActionIndexDirName
    patchU32(dir / ActionIndexAnchorName, ShOffFormatVersion,
      proc (v: uint32): uint32 = v xor 0xFF'u32)
    let before = shardFiles(root)
    var anchorStat: Stat
    doAssert stat((dir / ActionIndexAnchorName).cstring, anchorStat) == 0
    let anchorBytes = readFile(dir / ActionIndexAnchorName)
    let idx = openActionIndex(root)
    defer: closeActionIndex(idx)
    check not idx.attached
    check idx.failure == afKeyDisciplineSkew
    check shardFiles(root) == before
    check before.len >= 2
    var after: Stat
    check stat((dir / ActionIndexAnchorName).cstring, after) == 0
    check after.st_ino == anchorStat.st_ino
    check readFile(dir / ActionIndexAnchorName) == anchorBytes
