## `refreshRestoredOutputs`: after a restore from the CAS the record's output
## state is rewritten to the files the restore wrote (Incremental-Invalidation.md
## §"Minimum check set" Step 3.3), so the in-place consultation reuses the
## record on this host instead of rejecting it on the producer's inodes.
##
## The refresh stamps only what the restore wrote. A regular file whose size
## is not the recorded blob's was not: its recorded state is kept, and the
## next in-place consultation rejects the record on it (`outputStateMismatch`)
## rather than adopt a file the record does not describe.
##
## MOCK POLICY: none. A real action cache and CAS in a temp dir, real files;
## the "restore" is modelled by rewriting the output with the recorded bytes
## into a fresh inode, which is what a materialization does.

import std/[os, tempfiles, unittest]

import repro_hash
import repro_local_store

proc weakOf(name: string): ContentDigest =
  var bytes = newSeq[byte](name.len)
  for i, ch in name:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

suite "refreshRestoredOutputs":

  test "a restored output's state replaces the recorded one, same fingerprints":
    let root = createTempDir("repro-refresh-restored-", "")
    defer: removeDir(root)
    let work = root / "work"
    createDir(work)
    writeFile(work / "in.txt", "input\n")
    writeFile(work / "out.txt", "output bytes\n")
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let weak = weakOf("refresh-restored.lifecycle")
    let record = cache.recordActionResult(cas, weak, ffpChecksum,
      [work / "in.txt"], [work / "out.txt"])
    # A restore: the same bytes, a fresh inode (new ctime).
    removeFile(work / "out.txt")
    writeFile(work / "out.txt.new", "output bytes\n")
    moveFile(work / "out.txt.new", work / "out.txt")
    check outputStateMismatch(record, "").len > 0   # the producer's inodes
    let refreshed = cache.refreshRestoredOutputs(record, "")
    check refreshed.weakFingerprint == record.weakFingerprint
    check refreshed.strongFingerprint == record.strongFingerprint
    check refreshed.outputs[0].blob == record.outputs[0].blob
    check outputStateMismatch(refreshed, "").len == 0

  test "an output whose size is not the recorded blob's is not stamped":
    let root = createTempDir("repro-refresh-restored-", "")
    defer: removeDir(root)
    let work = root / "work"
    createDir(work)
    writeFile(work / "in.txt", "input\n")
    writeFile(work / "out.txt", "output bytes\n")
    var cache = openActionCache(root / "action-cache", attachShm = false)
    defer: cache.closeShmTier()
    var cas = openLocalCas(root / "cas")
    let weak = weakOf("refresh-restored.size-mismatch")
    let record = cache.recordActionResult(cas, weak, ffpChecksum,
      [work / "in.txt"], [work / "out.txt"])
    # Something other than the restore left a different file at the path.
    writeFile(work / "out.txt", "a longer, different output\n")
    let refreshed = cache.refreshRestoredOutputs(record, "")
    check refreshed.outputs[0].metadata == record.outputs[0].metadata
    check refreshed.outputs[0].changeTimeNs == record.outputs[0].changeTimeNs
    # Not adopted: the next in-place consultation rejects it.
    check outputStateMismatch(refreshed, "").len > 0
