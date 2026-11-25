## The egress observer's round-25 rules (ReproOS Add-On Mode spec §10.4
## *The egress observer*; §13 decisions 186, 187 and 188; threat model T65,
## C86, C104).
##
## * Decision 186: the egress check's heartbeat carries a reset of the
##   table's counts (``counterReset``), and every check holds an exclusive
##   lock on its state for the whole read-compare-write.
## * Decision 187: an apply and the boot re-assertion reload the observer
##   unit when its table is gone and the unit is active; plan, verify and
##   the check only report it.
## * Decision 188: the egress check holds ``CAP_NET_ADMIN`` alone and writes
##   its sink-form entries into a root drop directory; the shipping unit's
##   privileged first step moves them into the outbox, following no link,
##   regular files only, each under a size cap.
##
## Falsifying builds: ``egress-reset-not-in-heartbeat`` (the heartbeat
## case), ``egress-check-unlocked`` (the lock case),
## ``read-only-commands-reload-egress`` (the read-only case),
## ``egress-check-dac-override`` (the unit and site case) and
## ``egress-drop-follows-links`` (the planted-link case).
## ``apply-skips-egress-reload`` and ``reassert-skips-egress-reload`` are
## held by the VM gate ``e2e_addon_egress_observer``, whose apply and
## re-assertion steps drive the real ``runAddonApply`` and
## ``runAddonReassert``.
##
## Mocks: ``convergeEgressTable`` takes the unit's state, the reload and the
## table probe as procedures; the cases pass recording stand-ins, because a
## unit test has no PID 1 to reload a unit through and no host table. The
## VM gate runs the real ones. The drop directory, the outbox, the records
## and the check's lock are real files.

import std/[os, posix, sequtils, strutils, unittest]

import repro_core/file_lock
import repro_peer_cache/evidence_record

import repro_addon/egress_converge
import repro_addon/egress_observer
import repro_addon/evidence
import repro_addon/evidence_ship
import repro_addon/generation0
import repro_addon/ledger
import repro_addon/nft_tables
import repro_addon/record_dir

let root = getTempDir() / ("addon-egress-r25-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc site(name: string): EvidenceSite =
  let d = root / name
  createDir(d)
  writeFile(d / "evidence.conf", "")
  EvidenceSite(stateDir: d, dir: d / "records", outbox: d / "state" / "outbox",
               confPath: d / "evidence.conf", host: "h", journal: false)

proc heartbeatOf(s: EvidenceSite): EvidenceRecord =
  for kind, p in walkDir(s.outbox):
    if p.endsWith(".evr"):
      let r = decodeEvidenceRecord(cast[seq[byte]](readFile(p)))
      if r.field("intervalMs").len > 0: return r
  raise newException(ValueError, "no egress-check heartbeat in " & s.outbox)

suite "a counter reset is a heartbeat field, and the state is locked (§13 decision 186)":
  test "the heartbeat carries what went down":
    let s = site("hb")
    recordEgressCheck(EgressCheck(present: true, control: "idle",
      counterReset: "the counter of refused packets fell from 29 to 0"),
      s, 300_000)
    let hb = heartbeatOf(s)
    check hb.field("counterReset") ==
      "the counter of refused packets fell from 29 to 0"

  test "a check without a reset carries no such field":
    let s = site("hb0")
    recordEgressCheck(EgressCheck(present: true, control: "idle"), s, 300_000)
    check heartbeatOf(s).field("counterReset") == ""

  test "a check waits for another check's lock, and judges nothing without it":
    let state = root / "lock" / "egress-refused.state"
    createDir(parentDir(state))
    var held: ReproFileLock
    check tryAcquireExclusiveFileLock(egressStateLockPath(state), held)
    let c = checkEgress(findExe("false"), state, lockWaitMs = 300)
    releaseExclusiveFileLock(held)
    checkpoint c.error
    check "another egress check holds" in c.error
    # Once the lock is free, the check runs (and fails on an nft that answers nothing).
    let c2 = checkEgress(findExe("false"), state, lockWaitMs = 300)
    check "another egress check holds" notin c2.error

suite "apply and re-assert reload a missing table; plan, verify and the check do not (§13 decision 187)":
  let l = Ledger(generation: "g", entries: @[
    LedgerEntry(class: lcNftTable, path: EgressTableKey)])
  test "a missing table under an active observer is reloaded":
    var reloads: seq[string]
    let notes = convergeEgressTable(l,
      unitState = proc (u: string): string = "active",
      reload = proc (u: string): tuple[ok: bool; output: string] =
        reloads.add(u)
        (true, ""),
      missing = proc (e: LedgerEntry): bool = true)
    check reloads == @[EgressUnit]
    check notes.len == 1 and "reloaded" in notes[0]

  test "a present table, or an observer that is not active, is not reloaded":
    var reloads = 0
    let r = proc (u: string): tuple[ok: bool; output: string] =
      inc reloads
      (true, "")
    discard convergeEgressTable(l, proc (u: string): string = "active", r,
                                proc (e: LedgerEntry): bool = false)
    let n = convergeEgressTable(l, proc (u: string): string = "inactive", r,
                                proc (e: LedgerEntry): bool = true)
    check reloads == 0
    check "next start loads it" in n[0]

  test "plan, verify and the egress check never reload it":
    var reloads = 0
    let notes = readOnlyMustNotReload(l,
      unitState = proc (u: string): string = "active",
      reload = proc (u: string): tuple[ok: bool; output: string] =
        inc reloads
        (true, ""),
      missing = proc (e: LedgerEntry): bool = true)
    check reloads == 0
    check notes.len == 0

suite "the egress check writes a root drop directory, without CAP_DAC_OVERRIDE (§13 decision 188)":
  test "the check's unit holds CAP_NET_ADMIN alone and writes no outbox":
    let u = egressCheckUnit("/repro/store/prefixes/repro-addon/x/bin/repro")
    check "CapabilityBoundingSet=CAP_NET_ADMIN\n" in u
    check "CAP_DAC_OVERRIDE" notin u
    check EvidenceShipStateDir notin u
    check egressCheckSite().outbox == EgressDropDir
    check EgressDropDir.startsWith(EvidenceDirPath & "/")
    check ("DirectoryNotEmpty=" & EgressDropDir & "\n") in evidenceShipPathUnit()

  test "the harvest moves regular entries and reads no planted link":
    let drop = root / "drop" / "egress-drop"
    let outbox = root / "drop" / "state" / "outbox"
    createDir(drop)
    writeFile(drop / "0001-egress.evr", "an entry")
    let secret = root / "drop" / "root-secret"
    writeFile(secret, "ROOT'S SECRET")
    createSymlink(secret, drop / "0002-link.evr")
    writeFile(drop / "0003-big.evr", repeat('x', DropEntryMaxBytes + 1))
    writeFile(drop / "notes.txt", "not an entry")
    check harvestDropEntries(drop, outbox) == 1
    check readFile(outbox / "0001-egress.evr") == "an entry"
    check not fileExists(outbox / "0002-link.evr")
    check not fileExists(outbox / "0003-big.evr")
    check readFile(secret) == "ROOT'S SECRET"
    var left: seq[string]
    for kind, p in walkDir(drop): left.add(extractFilename(p))
    checkpoint $left
    check left.len == 0

  test "a drop directory replaced with a link is refused":
    let base = root / "drop2"
    createDir(base / "elsewhere")
    writeFile(base / "elsewhere" / "x.evr", "not the drop directory's")
    createSymlink(base / "elsewhere", base / "egress-drop")
    expect OSError:
      discard harvestDropEntries(base / "egress-drop", base / "state" / "outbox")
    check fileExists(base / "elsewhere" / "x.evr")

removeDir(root)
