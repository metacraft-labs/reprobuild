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
## Falsifying builds (each turns its own case red):
## ``override-keyless-unsigned`` (1), ``override-write-error-swallowed`` (2),
## ``override-sig-write-error-swallowed`` (3).
##
## Mocks: ``ship`` is a stub answering "not acknowledged" -- the sink's
## refusal to acknowledge is held against a real sink by
## ``t_addon_review_round4`` case 2; what these cases hold is what the gate
## does after it. Nothing else.

import std/[os, sequtils, strutils, times, unittest]

import repro_addon/attestation
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
        "-discarded-unshipped.json" & DiscardRecordSigExt))
    let g = storeEvidenceGate(site, override, notAcknowledged,
                              overrideDir = logDir)
    checkpoint g.errors.join("\n")
    check g.errors.anyIt("could not be written" in it)
    check g.errors.anyIt(it == "nothing was removed")
    check g.overrideRecord.len == 0
    check dirExists(aside)
    var records = 0
    for kind, p in walkDir(logDir):
      if kind == pcFile and p.endsWith("-discarded-unshipped.json"): inc records
    check records == 0

removeDir(root)
