## Store verification against the realisation digest (spec §13 decision 46;
## threat model DET-AO-5, G41).
##
## A prefix realised through the real local store carries its canonical
## tree digest in its receipt (v4 ``contentDigest``). Verification finds it
## intact; after one byte of it changes, it reports the mismatch, writes the
## DET-AO-5 record and quarantines the path. A prefix whose receipt has no
## digest (realised before receipts carried one) is reported unverifiable,
## never trusted, until an operator adopts its current digest. A run stops
## at its time budget and the next one resumes where it stopped.
##
## Falsifying build: ``reassert-skips-digest-check`` -- the digests are
## computed and never compared; the mismatch step goes red.
##
## Mocks: none. A real store under a scratch directory, real receipts.

import std/[os, strutils, unittest]

import repro_local_store/store

import repro_addon/addon_apply
import repro_addon/evidence as addonEvidence
import repro_addon/ledger
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
  writeLedger(ledgerCopyPath(stateDir), Ledger(generation: "g1", entries: @[
    LedgerEntry(class: lcStorePrefix, path: good),
    LedgerEntry(class: lcStorePrefix, path: old)]))
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
    let r = verifyStore(site, currentStorePaths(stateDir))
    check r.verified == @[good]
    check r.unverifiable == @[old]
    check r.mismatched.len == 0
    recordStoreVerify(r, site)
    check evidenceRecords("store-unverifiable", site.evidence.dir).len == 1

  test "one byte changed after the switch: DET-AO-5 and quarantine":
    setFilePermissions(good / "bin", {fpUserRead, fpUserWrite, fpUserExec})
    setFilePermissions(good / "bin" / "tool", {fpUserRead, fpUserWrite})
    writeFile(good / "bin" / "tool", "intacT\n")
    let r = verifyStore(site, currentStorePaths(stateDir))
    check r.mismatched.len == 1
    check r.mismatched[0].path == good
    check good in readStoreQuarantine(site.quarantinePath)
    recordStoreVerify(r, site)
    check evidenceRecords("store-digest-mismatch", site.evidence.dir).len == 1

  test "an operator adopts the digest of an unverifiable path":
    check adoptUnverified(site, @[old]) == @[old]
    let r = verifyStore(site, @[old])
    check r.verified == @[old]
    check r.unverifiable.len == 0

  test "a run within its budget leaves the rest for the next":
    let r = verifyStore(site, @[old, good], budgetSec = -1)
    check r.notReached.len == 2
    check r.verified.len == 0

removeDir(root)
