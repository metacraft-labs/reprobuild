## The A11 code review's fifth round (reprobuild-pm ``issues/2026-11-08-*``
## at ``48cd2b89``) and §13 decisions 63 and 64, held at unit level through
## the real uninstall gate (``storeEvidenceGate``).
##
## 1. Decision 63: with ``--discard-unacknowledged-store-evidence`` and the
##    host's attestation key missing, uninstall refuses, names the missing
##    key, writes no record and discards nothing.
## 2. Decision 62's fail-closed write: when the override record cannot be
##    written (a file stands where its directory goes), uninstall refuses
##    and discards nothing.
##
## (The record's signature, checked through ``repro system addon
## verify-discard-record``, is ``t_addon_review_round4`` case 3.)
##
## 3. (round 6) When only the signature's write fails, uninstall refuses,
##    discards nothing, and leaves no record of the discard: the signature
##    is written first and the record last.
##
## 4. (§13 decision 81) When the intent record's write fails AFTER the
##    record reached its name (the directory sync), the error is reported,
##    nothing is discarded, and the record stays WITH its signature: it
##    states an authorisation, which is true, and ``verify-discard-record``
##    reports it as "authorised, not completed" (exit 3), never as a
##    discard.
##
## 5. (§13 decision 81) An uninstall that ends incomplete (drift or an
##    error) after the intent record writes no completion record, whether
##    or not an object is already gone: the record verifies as "authorised,
##    not completed".
##
## Falsifying builds (each turns its own case red):
## ``override-keyless-unsigned`` (1), ``override-write-error-swallowed`` (2),
## ``override-sig-write-error-swallowed`` (3),
## ``override-rollback-removes-sig`` (4),
## ``discard-completed-despite-errors`` (5).
##
## Mocks: case 4's record writer writes the file as the real one does and
## then raises, as the real one does when the directory's fsync fails
## after the rename (a failure of the file system cannot be produced on
## demand). ``ship`` is a stub answering "not acknowledged" -- the sink's
## refusal to acknowledge is held against a real sink by
## ``t_addon_review_round4`` case 2; what these cases hold is what the gate
## does after it. Nothing else.

import std/[os, sequtils, strutils, times, unittest]

import repro_addon/attestation
import repro_addon/cli
import repro_addon/evidence as addonEvidence
import repro_addon/store_custody
import repro_addon/uninstall

let root = getTempDir() / ("a11-round5-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc scratchSite(name, keyPath: string): CustodySite =
  let st = root / name / "state"
  createDir(st / "addon")
  writeFile(root / name / "evidence.conf", "sink = 127.0.0.1:1\n")
  createDir(root / name / "store")
  custodySite(st, root / name / "store").withEvidence(EvidenceSite(
    stateDir: st, dir: root / name / "ev", outbox: root / name / "ev" / "outbox",
    confPath: root / name / "evidence.conf", attestationKey: keyPath,
    host: "h", journal: false))

proc leaveAside(site: CustodySite; name: string): string =
  let obj = site.storeRoot / "prefixes" / "x" / name
  createDir(obj)
  writeFile(obj / "f", "altered\n")
  moveAside(site, obj)

proc notAcknowledged(): tuple[ok: bool; why: string] =
  (false, "1 record(s) still queued: the sink did not acknowledge")

let override = UninstallOptions(discardUnacknowledgedStoreEvidence: true)

suite "the A11 code review's fifth round":
  test "1: without the attestation key the override refuses and names it":
    let missing = root / "keyless" / "agent" / "attestation.key"
    let site = scratchSite("keyless", missing)
    let aside = leaveAside(site, "1-a")
    let logDir = root / "keyless" / "log"
    let g = storeEvidenceGate(site, override, notAcknowledged,
                              overrideDir = logDir)
    checkpoint g.errors.join("\n")
    check g.errors.anyIt(missing in it and "is missing" in it)
    check g.errors.anyIt(it == "nothing was removed")
    check g.overrideRecord.len == 0
    check not dirExists(logDir)
    check dirExists(aside)

  test "2: an override record that cannot be written stops the discard":
    let key = root / "unwritable" / "agent" / "attestation.key"
    createDir(parentDir(key))
    discard ensureAttestationKey(key)
    let site = scratchSite("unwritable", key)
    let aside = leaveAside(site, "1-a")
    let logDir = root / "unwritable" / "log"
    writeFile(logDir, "a file where the record's directory goes\n")
    let g = storeEvidenceGate(site, override, notAcknowledged,
                              overrideDir = logDir)
    checkpoint g.errors.join("\n")
    check g.errors.anyIt("could not be written" in it)
    check g.errors.anyIt(it == "nothing was removed")
    check g.overrideRecord.len == 0
    check fileExists(logDir)
    check dirExists(aside)

  test "3: a failed signature write stops the discard and leaves no record":
    let key = root / "sigfail" / "agent" / "attestation.key"
    createDir(parentDir(key))
    discard ensureAttestationKey(key)
    let site = scratchSite("sigfail", key)
    let aside = leaveAside(site, "1-a")
    let logDir = root / "sigfail" / "log"
    createDir(logDir)
    # A directory where the signature of each record the next seconds could
    # write goes: only that write fails.
    let t0 = getTime()
    for s in 0 .. 20:
      createDir(logDir / ("uninstall-" &
        (t0 + initDuration(seconds = s)).utc.format("yyyyMMdd'T'HHmmss'Z'") &
        DiscardIntentSuffix & DiscardRecordSigExt))
    let g = storeEvidenceGate(site, override, notAcknowledged,
                              overrideDir = logDir)
    checkpoint g.errors.join("\n")
    check g.errors.anyIt("could not be written" in it)
    check g.errors.anyIt(it == "nothing was removed")
    check g.overrideRecord.len == 0
    check dirExists(aside)
    var records = 0
    for kind, p in walkDir(logDir):
      if kind == pcFile and p.endsWith(DiscardIntentSuffix): inc records
    check records == 0

  test "4: an intent record whose directory sync fails stays signed, as authorised":
    let key = root / "syncfail" / "agent" / "attestation.key"
    createDir(parentDir(key))
    let pub = ensureAttestationKey(key).publicKeyHex
    let site = scratchSite("syncfail", key)
    let aside = leaveAside(site, "1-a")
    let logDir = root / "syncfail" / "log"
    let failAfterRename = proc (path, text: string) =
      atomicRecordWriter(path, text)
      if not path.endsWith(DiscardRecordSigExt):
        raise newException(OSError, "fsync of the record's directory failed")
    let g = storeEvidenceGate(site, override, notAcknowledged,
                              overrideDir = logDir, recordWriter = failAfterRename)
    checkpoint g.errors.join("\n")
    check g.errors.anyIt("making them durable failed" in it)
    check g.overrideRecord.len == 0
    check g.errors.anyIt(it == "nothing was removed")
    check dirExists(aside)
    var records: seq[string]
    for kind, p in walkDir(logDir):
      if kind == pcFile and p.endsWith(DiscardIntentSuffix): records.add(p)
    check records.len == 1
    if records.len == 1:
      check fileExists(records[0] & DiscardRecordSigExt)
      let v = verifyDiscardRecord(records[0], pub)
      checkpoint v.why
      check v.status == dsAuthorised
      check runAddonCli(@["verify-discard-record", records[0], "--key", pub]) == 3

  test "5: an uninstall that drifts or fails after the intent record does not complete it":
    let key = root / "drift" / "agent" / "attestation.key"
    createDir(parentDir(key))
    let pub = ensureAttestationKey(key).publicKeyHex
    let site = scratchSite("drift", key)
    let aside = leaveAside(site, "1-a")
    let logDir = root / "drift" / "log"
    let g = storeEvidenceGate(site, override, notAcknowledged,
                              overrideDir = logDir)
    check g.errors.len == 0
    check fileExists(g.overrideRecord)
    var signer = loadTextSigner(key)
    var r = UninstallResult(overrideRecord: g.overrideRecord,
                            overrideRecordText: g.overrideRecordText)
    r.drift.add("/etc/x: drifted")
    removeDir(aside)                      # the object itself is gone
    finishDiscard(r, site, signer, g.pending)
    check r.completionRecord.len == 0
    check not fileExists(completionPathOf(g.overrideRecord))
    check verifyDiscardRecord(g.overrideRecord, pub).status == dsAuthorised

    # An error, no drift: the same.
    let aside2 = leaveAside(site, "2-a")
    let g2 = storeEvidenceGate(site, override, notAcknowledged,
                               overrideDir = logDir / "2")
    var r2 = UninstallResult(overrideRecord: g2.overrideRecord,
                             overrideRecordText: g2.overrideRecordText)
    r2.errors.add("some later step failed")
    removeDir(aside2)
    finishDiscard(r2, site, signer, g2.pending)
    signer.wipe()
    check r2.completionRecord.len == 0
    check verifyDiscardRecord(g2.overrideRecord, pub).status == dsAuthorised

removeDir(root)
