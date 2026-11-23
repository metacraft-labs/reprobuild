## Library-local tests for the evidence store (`evidence.nim`) —
## Distributed-Execution M7, threat model G28.
##
##   * the checkpoint key lives apart from the data: a store whose key
##     directory is inside (or contains) the store directory is refused, and
##     verification takes the public key from a certificate the operator
##     pinned, never from the store;
##   * RECEIPTS make the head tamper-evident: every acknowledged batch ends
##     with a signed checkpoint returned as a receipt, so there is no
##     unanchored tail; an attacker on the sink host who truncates the store
##     back to an earlier checkpoint, or rewrites acknowledged entries and
##     re-chains them consistently (without the key), is caught by any
##     receipt an appender kept — invisible from the store alone, which is
##     exactly the gap the review found; a changed byte breaks the chain;
##   * a store left with an unanchored tail fails verification unless asked
##     to inspect it live, and reopening it signs a recovery checkpoint;
##   * a receipt not signed by the checkpoint key is refused.
##
## MOCK POLICY — none: the production store on a real directory; the
## "attacker" edits the segment files directly, as a sink-host attacker can.

import std/[os, strutils, tempfiles, unittest]

import repro_peer_cache

proc rec(i: int): EvidenceRecord =
  newEvidenceRecord(ecAudit, "boundary-gate", "blob-fetch",
    [("peer", "p" & $i), ("size", $i)], nowMs = 1_000 + i)

proc appendBatch(store: EvidenceStore; first, n: int): SinkReceipt =
  for i in first ..< first + n:
    discard store.appendRecord(default(PeerId), lrDaemon, rec(i))
  store.appendCheckpointReceipt()

suite "the evidence store: receipts and the separated checkpoint key (G28)":

  test "the checkpoint key is never beside the data":
    let base = createTempDir("m7-g28-keys-", "")
    defer: removeDir(base)
    expect EvidenceStoreError:
      discard openEvidenceStore(base / "store", base / "store" / "key")
    expect EvidenceStoreError:
      discard openEvidenceStore(base / "store", base / "store")
    expect EvidenceStoreError:
      discard openEvidenceStore(base / "k" / "store", base / "k")
    let store = openEvidenceStore(base / "store", base / "key")
    check fileExists(base / "key" / "sink-checkpoint.key")
    check not fileExists(base / "store" / "sink-checkpoint.key")
    check not fileExists(base / "store" / "sink-checkpoint.crt")
    discard store.appendBatch(0, 3)
    let key = checkpointPublicKeyFromCert(sinkCheckpointCertPath(base / "key"))
    check verifyEvidenceStore(base / "store", key).ok

  test "receipts catch a truncated store; a changed byte breaks the chain":
    let base = createTempDir("m7-g28-receipts-", "")
    defer: removeDir(base)
    let store = openEvidenceStore(base / "store", base / "key", segmentMaxEntries = 1000)
    let key = checkpointPublicKeyFromCert(sinkCheckpointCertPath(base / "key"))
    let r1 = store.appendBatch(0, 5)
    let r2 = store.appendBatch(5, 5)
    check verifyReceipt(r1, key)
    check verifyReceipt(r2, key)
    # Positive control: the intact store verifies with both receipts, and
    # has no unanchored tail.
    let ok = verifyEvidenceStore(base / "store", key, [r1, r2])
    check ok.ok
    check ok.unanchoredTail == 0
    check ok.receiptsChecked == 2
    # Truncation back to the first checkpoint: from the store alone it still
    # verifies (that was the gap) — the second receipt says otherwise.
    let seg = listSegments(base / "store")[0]
    let original = readFile(seg)
    let entries = readEvidenceStore(base / "store")
    var cut = 0
    for e in entries:
      if e.seq > r1.headSeq + 1: break   # keep through r1's checkpoint entry
      inc cut
    # The truncation offset: the start of the (cut+1)-th entry.
    var offsets: seq[int] = @[]
    var pos = original.find("EVE1")
    while pos >= 0:
      offsets.add(pos)
      pos = original.find("EVE1", pos + 4)
    check offsets.len == entries.len
    writeFile(seg, original[0 ..< offsets[cut]])
    check verifyEvidenceStore(base / "store", key).ok          # store alone
    let truncated = verifyEvidenceStore(base / "store", key, [r1, r2])
    checkpoint("truncated: " & truncated.reason)
    check not truncated.ok
    check "truncated" in truncated.reason
    # A changed byte in an acknowledged entry breaks the chain (and, re-
    # chained without the key, the checkpoint signature and the receipt's
    # head hash).
    writeFile(seg, original)
    var forged = original
    let target = forged.find("p7")
    check target > 0
    forged[target + 1] = '8'
    writeFile(seg, forged)
    let broken = verifyEvidenceStore(base / "store", key, [r2])
    check not broken.ok
    writeFile(seg, original)
    check verifyEvidenceStore(base / "store", key, [r1, r2]).ok
    # A receipt not signed by the checkpoint key is refused.
    var fake = r2
    fake.signature[0] = fake.signature[0] xor 1
    check not verifyReceipt(fake, key)
    check not verifyEvidenceStore(base / "store", key, [fake]).ok

  test "an unanchored tail fails, and reopening signs a recovery checkpoint":
    let base = createTempDir("m7-g28-tail-", "")
    defer: removeDir(base)
    let key0 = block:
      let store = openEvidenceStore(base / "store", base / "key")
      discard store.appendBatch(0, 3)
      discard store.appendRecord(default(PeerId), lrDaemon, rec(99))
      checkpointPublicKeyFromCert(sinkCheckpointCertPath(base / "key"))
    let live = verifyEvidenceStore(base / "store", key0)
    check not live.ok
    check live.unanchoredTail == 1
    check verifyEvidenceStore(base / "store", key0,
      allowUnanchoredTail = true).ok
    discard openEvidenceStore(base / "store", base / "key")
    let reopened = verifyEvidenceStore(base / "store", key0)
    check reopened.ok
    check reopened.unanchoredTail == 0
