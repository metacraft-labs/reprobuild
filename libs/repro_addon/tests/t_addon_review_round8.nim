## The A11 code review's eighth round (reprobuild-pm ``issues/2026-11-08-*``
## at ``25ce1d02``) and §13 decision 81, held at unit level through the real
## uninstall gate (``storeEvidenceGate``), the real completion step
## (``finishDiscard``) and the operator's command
## (``repro system addon verify-discard-record``).
##
## Decision 81: an uninstall that discards store evidence unshipped writes a
## signed INTENT record before it removes anything, and a signed COMPLETION
## record after the removal succeeded; both durable. ``verify-discard-record``
## reports "completed" (exit 0) or "authorised, not completed" (exit 3), and
## never claims a discard that did not finish.
##
## 1. A clean run: the intent, the removal, the completion. The completion
##    names the intent by its sha256 and is signed with the key read before
##    the removal (the key file itself goes with ``/var/lib/repro``): exit
##    0, through the intent record's name or the completion's.
## 2. A crash after the intent record, before anything is removed: exit 3.
## 3. A crash after the removal, before the completion is written: exit 3.
## 4. A crash between the completion's signature and its record (the
##    signature alone on disk): exit 3.
## 5. The completion record's directory sync fails: the record reached its
##    name, so it is true and stays (exit 0), and the failure is reported.
## 6. A completion record of another intent, put beside this one: it does
##    not verify (exit 1).
## 7. A pending object still in place at the end of an otherwise clean run:
##    no completion (exit 3).
##
## 8. A discard under ``--keep-store``: the completion records the object as
##    kept; the verdict names it kept and not discarded (exit 0).
## 9. A completion whose removed + kept lists do not cover the intent's
##    objects: invalid (exit 1).
## 10. A completion whose signature does not hold: one byte of the record
##    changed after signing, an empty ``.sig``, and a record signed by
##     another key but naming the enrolled key as its ``attestationKey``:
##    each invalid (exit 1).
##
## (Drift or an error after the intent record, and the intent record's own
## failed directory sync, are ``t_addon_review_round5`` cases 4 and 5.)
##
## Falsifying builds (each turns its own case red):
## ``discard-completion-key-read-late`` (1),
## ``discard-verify-ignores-completion`` (2, 3; and every other case that
## checks a status before or without a valid completion: 1, 4, 6, 7),
## ``discard-verify-completion-sig-alone`` (4),
## ``discard-completion-sync-error-swallowed`` (5),
## ``discard-verify-skips-intent-digest`` (6),
## ``discard-verify-skips-completion-signature`` (10),
## ``discard-completed-objects-present`` (7),
## ``discard-verify-reports-intent-objects`` (8, 9).
##
## Mocks: ``ship`` is a stub answering "not acknowledged" -- the sink's
## refusal is held against a real sink by ``t_addon_review_round4`` case 2;
## what these cases hold is what happens after it. A crash is the process
## stopping between two writes, so it is modelled by stopping there: the
## steps after it are not run (2, 3), or the writer raises between the
## completion's signature and its record and nothing cleans up after it
## (4, which calls ``writeDiscardCompletion`` directly). Case 5's writer
## writes the file as the real one does and then raises, as the real one
## does when the directory's fsync fails after the rename (a failure of the
## file system cannot be produced on demand). Nothing else.

import std/[json, os, strutils, unittest]

import repro_addon/attestation
import repro_addon/cli
import repro_addon/evidence as addonEvidence
import repro_addon/store_custody
import repro_addon/uninstall

let root = getTempDir() / ("a11-round8-" & $getCurrentProcessId())
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

type Scene = object
  site: CustodySite
  key, pub, aside: string
  gate: tuple[pending, errors: seq[string]; overrideRecord,
              overrideRecordText: string]

proc scene(name: string): Scene =
  ## A host with its attestation key, one altered object left aside, and an
  ## uninstall gate that wrote the intent record.
  result.key = root / name / "agent" / "attestation.key"
  createDir(parentDir(result.key))
  result.pub = ensureAttestationKey(result.key).publicKeyHex
  result.site = scratchSite(name, result.key)
  result.aside = leaveAside(result.site, "1-a")
  result.gate = storeEvidenceGate(result.site, override, notAcknowledged,
                                  overrideDir = root / name / "log")
  doAssert result.gate.errors.len == 0, result.gate.errors.join("\n")
  doAssert fileExists(result.gate.overrideRecord)

proc resultOf(s: Scene): UninstallResult =
  UninstallResult(overrideRecord: s.gate.overrideRecord,
                  overrideRecordText: s.gate.overrideRecordText)

proc verifyExit(s: Scene; path = ""): int =
  runAddonCli(@["verify-discard-record",
                (if path.len > 0: path else: s.gate.overrideRecord),
                "--key", s.pub])

suite "the A11 code review's eighth round: §13 decision 81":
  test "1: a clean run is completed, signed with the key read before the removal":
    let s = scene("clean")
    check verifyExit(s) == 3                 # the intent alone
    var signer = loadTextSigner(s.key)
    # The removal takes the key file with /var/lib/repro.
    removeFile(s.key)
    removeDir(s.aside)
    var r = resultOf(s)
    finishDiscard(r, s.site, signer, s.gate.pending)
    signer.wipe()
    checkpoint r.errors.join("\n")
    check r.errors.len == 0
    check r.completionRecord == completionPathOf(s.gate.overrideRecord)
    check fileExists(r.completionRecord & DiscardRecordSigExt)
    let done = parseJson(readFile(r.completionRecord))
    check done["intent"].getStr() == extractFilename(s.gate.overrideRecord)
    check done["removed"].getElems().len == 1
    let v = verifyDiscardRecord(s.gate.overrideRecord, s.pub)
    checkpoint v.why
    check v.status == dsCompleted
    check verifyExit(s) == 0
    check verifyExit(s, r.completionRecord) == 0

  test "2: a crash after the intent record, before any removal, is not a discard":
    let s = scene("crash-intent")
    check dirExists(s.aside)
    let v = verifyDiscardRecord(s.gate.overrideRecord, s.pub)
    checkpoint v.why
    check v.status == dsAuthorised
    check "not known to have completed" in v.why
    check verifyExit(s) == 3

  test "3: a crash after the removal, before the completion, is not claimed":
    let s = scene("crash-removed")
    removeDir(s.aside)
    check verifyDiscardRecord(s.gate.overrideRecord, s.pub).status == dsAuthorised
    check verifyExit(s) == 3

  test "4: a crash between the completion's signature and its record":
    let s = scene("crash-completion")
    removeDir(s.aside)
    var signer = loadTextSigner(s.key)
    let crashAfterSig = proc (path, text: string) =
      if path.endsWith(DiscardRecordSigExt):
        atomicRecordWriter(path, text)
      else:
        raise newException(IOError, "the process stopped here")
    expect IOError:
      discard writeDiscardCompletion(s.site, signer, s.gate.overrideRecord,
        s.gate.overrideRecordText, @[s.aside], @[], crashAfterSig)
    signer.wipe()
    let cpath = completionPathOf(s.gate.overrideRecord)
    check fileExists(cpath & DiscardRecordSigExt)
    check not fileExists(cpath)
    check verifyDiscardRecord(s.gate.overrideRecord, s.pub).status == dsAuthorised
    check verifyExit(s) == 3

  test "5: a completion whose directory sync fails stays, and the failure is reported":
    let s = scene("completion-sync")
    removeDir(s.aside)
    var signer = loadTextSigner(s.key)
    let failAfterRename = proc (path, text: string) =
      atomicRecordWriter(path, text)
      if not path.endsWith(DiscardRecordSigExt):
        raise newException(OSError, "fsync of the record's directory failed")
    var r = resultOf(s)
    finishDiscard(r, s.site, signer, s.gate.pending, failAfterRename)
    signer.wipe()
    checkpoint r.errors.join("\n")
    check r.errors.len == 1 and r.errors.len > 0 and
      "making it durable failed" in r.errors[0]
    check r.completionRecord == completionPathOf(s.gate.overrideRecord)
    check verifyExit(s) == 0

  test "6: the completion of another intent record does not complete this one":
    let a = scene("digest-a")
    let b = scene("digest-b")
    # Both on one key, so only the intent digest tells them apart.
    var signer = loadTextSigner(a.key)
    removeDir(b.aside)
    let other = writeDiscardCompletion(a.site, signer, b.gate.overrideRecord,
      b.gate.overrideRecordText, @[b.aside], @[])
    signer.wipe()
    let cpath = completionPathOf(a.gate.overrideRecord)
    copyFile(other.path, cpath)
    copyFile(other.path & DiscardRecordSigExt, cpath & DiscardRecordSigExt)
    let v = verifyDiscardRecord(a.gate.overrideRecord, a.pub)
    checkpoint v.why
    check v.status == dsInvalid
    check verifyExit(a) == 1

  test "7: an object still in place at the end is not completed":
    let s = scene("present")
    var signer = loadTextSigner(s.key)
    var r = resultOf(s)                      # no drift, no error
    finishDiscard(r, s.site, signer, s.gate.pending)
    signer.wipe()
    check dirExists(s.aside)
    check r.completionRecord.len == 0
    check not fileExists(completionPathOf(s.gate.overrideRecord))
    check verifyExit(s) == 3

  test "8: objects kept with the store (--keep-store) are not reported discarded":
    let s = scene("kept")
    var signer = loadTextSigner(s.key)
    var r = resultOf(s)
    r.keptEvidence = @[s.aside]              # as runAddonUninstall sets it
    finishDiscard(r, s.site, signer, s.gate.pending)
    signer.wipe()
    check dirExists(s.aside)                 # still on the host
    check r.completionRecord.len > 0
    let v = verifyDiscardRecord(s.gate.overrideRecord, s.pub)
    checkpoint v.why
    check v.status == dsCompleted
    check v.removed.len == 0
    check v.kept == @[s.aside]
    let text = renderCompletedDiscard(v.keyHex, v.removed, v.kept)
    check "0 object(s) discarded unshipped" in text
    check "1 object(s) kept with the store" in text
    check verifyExit(s) == 0

  test "9: a completion that does not account for the intent's objects is invalid":
    let s = scene("unaccounted")
    removeDir(s.aside)
    var signer = loadTextSigner(s.key)
    discard writeDiscardCompletion(s.site, signer, s.gate.overrideRecord,
      s.gate.overrideRecordText, @[], @[])   # names neither removed nor kept
    signer.wipe()
    check verifyDiscardRecord(s.gate.overrideRecord, s.pub).status == dsInvalid
    check verifyExit(s) == 1

  test "10: a completion whose signature does not hold is invalid":
    let s = scene("completion-sig")
    removeDir(s.aside)
    var signer = loadTextSigner(s.key)
    let genuine = writeDiscardCompletion(s.site, signer, s.gate.overrideRecord,
      s.gate.overrideRecordText, @[s.aside], @[])
    signer.wipe()
    let cpath = completionPathOf(s.gate.overrideRecord)
    let sigPath = cpath & DiscardRecordSigExt
    let text = readFile(cpath)
    let sig = readFile(sigPath)
    check cpath == genuine.path
    check verifyExit(s) == 0                 # the genuine pair, as the control

    # One byte changed after signing (the host name; still valid JSON).
    let at = text.find("\"host\": \"h\"")
    check at >= 0
    writeFile(cpath, text[0 ..< at + 9] & "x" & text[at + 10 .. ^1])
    var v = verifyDiscardRecord(s.gate.overrideRecord, s.pub)
    checkpoint v.why
    check v.status == dsInvalid
    check verifyExit(s) == 1
    writeFile(cpath, text)
    check verifyExit(s) == 0

    # An empty signature.
    writeFile(sigPath, "")
    v = verifyDiscardRecord(s.gate.overrideRecord, s.pub)
    checkpoint v.why
    check v.status == dsInvalid
    check verifyExit(s) == 1

    # Signed by another key, while the record names the enrolled one.
    let otherKey = root / "completion-sig" / "other" / "attestation.key"
    createDir(parentDir(otherKey))
    discard ensureAttestationKey(otherKey)
    var other = loadTextSigner(otherKey)
    writeFile(sigPath, signWith(other, text) & "\n")
    other.wipe()
    v = verifyDiscardRecord(s.gate.overrideRecord, s.pub)
    checkpoint v.why
    check v.status == dsInvalid
    check verifyExit(s) == 1
    writeFile(sigPath, sig)
    check verifyExit(s) == 0

removeDir(root)
