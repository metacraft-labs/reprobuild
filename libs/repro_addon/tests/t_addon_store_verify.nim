## Store verification against the realisation digest (spec §13 decision 46;
## threat model DET-AO-5, G41).
##
## A prefix realised through the real local store carries its canonical
## tree digest in its receipt (v4 ``contentDigest``), and the realising
## process records the same digest, computed from the bytes it staged, in
## the ledger (``storePrefix`` ``value``). Verification expects the
## LEDGER's digest: it finds the prefix intact; after one byte of it
## changes it reports the mismatch, writes the DET-AO-5 record and
## quarantines the path -- and it does so just the same when the receipt
## was deleted with the alteration, or rewritten to name the altered
## digest (A11 audit session 2, G2). A prefix with no recorded digest is
## reported unverifiable with the digest it has now, never trusted, until
## an operator adopts it; a path whose receipt names another digest than
## it has now is never adopted. A run stops at its time budget and the
## next one resumes where it stopped.
##
## The re-assert's store findings are recorded under the trigger that names
## what happened: a quarantined object in use (present, its bytes altered)
## is ``store-digest-mismatch``, an absent one ``store-object-missing``
## (session 2, low).
##
## Falsifying builds: ``reassert-store-trigger-missing`` -- one trigger for
## both; the trigger step goes red. ``reassert-skips-digest-check`` -- the digests are
## computed and never compared; the mismatch step goes red.
## ``store-verify-trusts-receipt`` -- the expectation read from the
## verified path's own receipt; the deleted- and forged-receipt steps go
## red.
##
## Mocks: none. A real store under a scratch directory, real receipts.

import std/[os, strutils, unittest]

import repro_local_store/store

import repro_addon/addon_apply
import repro_addon/evidence as addonEvidence
import repro_addon/ledger
import repro_addon/reassert
import repro_addon/store_root
import repro_addon/store_verify

let root = getTempDir() / ("addon-store-verify-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc realise(s: var Store; name, content: string): string =
  let src = root / ("src-" & name)
  createDir(src / "bin")
  writeFile(src / "bin" / "tool", content)
  s.realizeDirectoryAsPrefix(src, StoreReceiptHint(adapter: "test",
    packageName: name, version: "1", provenanceChecksum: "sha256:" & name)).absolutePath

suite "store verification against the realisation digest":
  var s = openStore(root / "store")
  let good = s.realise("good", "intact\n")
  let old = s.realise("old", "pre-v4\n")
  let forged = s.realise("forged", "forged\n")
  let gone = s.realise("gone", "gone\n")
  let claimed = s.realise("claimed", "claimed\n")
  s.close()
  # A receipt written before v4: the same receipt without its digest.
  block:
    var r = readReceiptFile(old / ReceiptFileName)
    r.contentDigest = ""
    let p = old / ReceiptFileName
    setFilePermissions(old, {fpUserRead, fpUserWrite, fpUserExec})
    try: setFilePermissions(p, {fpUserRead, fpUserWrite}) except OSError: discard
    writeReceiptFile(p, r)
  let stateDir = root / "state"
  createDir(stateDir)
  # The ledger records each realisation digest (the realiser's value; the
  # test takes it as realised, before anything is altered). ``old`` and
  # ``claimed`` were realised before the ledger carried one.
  writeLedger(ledgerCopyPath(stateDir), Ledger(generation: "g1", entries: @[
    LedgerEntry(class: lcStorePrefix, path: good, value: storeTreeDigest(good)),
    LedgerEntry(class: lcStorePrefix, path: old),
    LedgerEntry(class: lcStorePrefix, path: forged,
                value: storeTreeDigest(forged)),
    LedgerEntry(class: lcStorePrefix, path: claimed)]))
  # ``gone`` is recorded only by a retained generation's ledger.
  createDir(stateDir / "generations" / "g0")
  writeLedger(stateDir / "generations" / "g0" / "addon-ledger",
    Ledger(generation: "g0", entries: @[LedgerEntry(class: lcStorePrefix,
      path: gone, value: storeTreeDigest(gone))]))

  proc alter(path, content: string) =
    setFilePermissions(path / "bin", {fpUserRead, fpUserWrite, fpUserExec})
    setFilePermissions(path / "bin" / "tool", {fpUserRead, fpUserWrite})
    writeFile(path / "bin" / "tool", content)
  proc rewriteReceipt(path: string; digest: string; remove = false) =
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    let p = path / ReceiptFileName
    try: setFilePermissions(p, {fpUserRead, fpUserWrite}) except OSError: discard
    if remove:
      removeFile(p)
    else:
      var r = readReceiptFile(p)
      r.contentDigest = digest
      writeReceiptFile(p, r)
  writeFile(root / "evidence.conf", "sink = 127.0.0.1:1\n")
  let site = StoreVerifySite(stateDir: stateDir,
    quarantinePath: root / "store-quarantine",
    adoptedPath: root / "store-digests", cursorPath: root / "cursor",
    evidence: EvidenceSite(stateDir: stateDir, dir: root / "ev",
      outbox: root / "ev" / "outbox", confPath: root / "evidence.conf",
      attestationKey: root / "none", host: "h", journal: false))

  test "a realised prefix carries its tree digest in its receipt":
    check readReceiptFile(good / ReceiptFileName).contentDigest ==
      storeTreeDigest(good)
    check storeTreeDigest(good).startsWith(StoreTreeDigestPrefix)

  test "intact: verified; without a digest: unverifiable, never trusted":
    let r = verifyStore(site, @[good, old, forged])
    check r.verified == @[good, forged]
    check r.unverifiable == @[old]
    check r.mismatched.len == 0
    # The record names the digest the path has now.
    check r.unverifiableDigests == @[(storeTreeDigest(old), "")]
    recordStoreVerify(r, site)
    let recs = evidenceRecords("store-unverifiable", site.evidence.dir)
    check recs.len == 1
    check storeTreeDigest(old) in readFile(recs[0])

  test "altered and its receipt deleted: still a mismatch (G2)":
    # A retained generation's ledger is an expectation too.
    alter(gone, "gonE\n")
    rewriteReceipt(gone, "", remove = true)
    let r = verifyStore(site, @[gone])
    check r.unverifiable.len == 0
    check r.mismatched.len == 1
    check gone in readStoreQuarantine(site.quarantinePath)

  test "altered and its receipt rewritten to match: still a mismatch (G2)":
    alter(forged, "forgeD\n")
    rewriteReceipt(forged, storeTreeDigest(forged))
    let r = verifyStore(site, @[forged])
    check r.verified.len == 0
    check r.mismatched.len == 1
    check forged in readStoreQuarantine(site.quarantinePath)
    # And no adopt re-blesses it: the ledger records its digest.
    check adoptUnverified(site, @[forged]).adopted.len == 0
    check verifyStore(site, @[forged]).mismatched.len == 1

  test "a path whose receipt names another digest is never adopted":
    alter(claimed, "claimeD\n")
    let a = adoptUnverified(site, @[claimed])
    check a.adopted.len == 0
    check a.refused == @[claimed]
    check verifyStore(site, @[claimed]).unverifiable == @[claimed]

  test "one byte changed after the switch: DET-AO-5 and quarantine":
    alter(good, "intacT\n")
    let before = evidenceRecords("store-digest-mismatch", site.evidence.dir).len
    let r = verifyStore(site, @[good])
    check r.mismatched.len == 1
    check r.mismatched[0].path == good
    check good in readStoreQuarantine(site.quarantinePath)
    recordStoreVerify(r, site)
    check evidenceRecords("store-digest-mismatch", site.evidence.dir).len ==
      before + 1

  test "an operator adopts the digest of an unverifiable path":
    check adoptUnverified(site, @[old]).adopted == @[old]
    let r = verifyStore(site, @[old])
    check r.verified == @[old]
    check r.unverifiable.len == 0

  test "the re-assert's store trigger names what happened":
    let g = storeFindings([
      "degraded: store object /repro/store/prefixes/a/1 is missing",
      "degraded: store object /repro/store/prefixes/b/1 is quarantined " &
        "(its bytes differed from its realisation digest)",
      "drift: etcFile /etc/x: content differs"])
    check g.len == 2
    check g[0].trigger == "store-object-missing"
    check g[0].found.len == 1
    check "prefixes/a/1" in g[0].found[0]
    check g[1].trigger == "store-digest-mismatch"
    check "prefixes/b/1" in g[1].found[0]

  test "a run within its budget leaves the rest for the next":
    let r = verifyStore(site, @[old, good], budgetSec = -1)
    check r.notReached.len == 2
    check r.verified.len == 0

removeDir(root)
