## An uninstall that stopped part-way, run again, still removes the shipping
## unit's state (ReproOS Add-On Mode spec §13 decision 181; A11 round 24).
##
## The shipping unit runs as a dynamic user whose state directory holds the
## outbox, the shipping cursor and the sink's last receipt. Uninstall
## removes that state late, with the add-on's own state, and decides it is
## the add-on's to remove from the ledger's entry for the shipping unit.
## The units go early. A run that fails after the units went and before the
## state did keeps a ledger of what is left (``keepStateWhenIncomplete``),
## and that ledger used to drop the shipping unit with the other removed
## units: the re-run then saw no shipping unit and left the state on disk,
## owned by a dynamic uid systemd may give to another unit. The kept ledger
## now keeps the shipping unit's entry while its state is still there.
##
## Falsifying build: ``uninstall-forgets-ship-state`` (the entry is dropped
## with the unit; the re-run leaves the state).
##
## No mocks: a real state directory with a real ledger copy, the uninstall's
## own ``keepStateWhenIncomplete``, ``readLedger`` and ``removeShipState``.
## The shipping state's paths are temporary directories instead of
## /var/lib/private/repro-addon-evidence, which only root can create; the
## VM gate e2e_addon_evidence_enrol runs the real uninstall on a real host.

import std/[os, sequtils, sets, unittest]

import repro_addon/[addon_apply, evidence_ship, generation0, ledger, uninstall]

let root = getTempDir() / ("addon-uninstall-ship-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc scene(name: string): tuple[state: string; ship: seq[string]; l: Ledger] =
  let state = root / name / "state"
  createDir(state)
  let ship = @[root / name / "private" / "repro-addon-evidence",
               root / name / "repro-addon-evidence-run"]
  createDir(ship[0] / "outbox")
  writeFile(ship[0] / "outbox" / "1.evr", "queued")
  writeFile(ship[0] / "cursor", "7")
  createDir(ship[1])
  let unitFile = root / name / "repro-addon-evidence.service"
  let l = Ledger(generation: "g0", entries: @[
    LedgerEntry(class: lcUnit, path: unitFile, unit: EvidenceShipUnit),
    LedgerEntry(class: lcUnit, path: root / name / "other.service",
                unit: "other.service")])
  writeLedger(ledgerCopyPath(state), l)
  (state, ship, l)

suite "a re-run of an incomplete uninstall removes the shipping state":
  test "the shipping unit's entry outlives the unit while its state is there":
    let s = scene("rerun")
    # First run: both units removed, then a later step failed.
    var r1: UninstallResult
    for e in s.l.entries: r1.undone.incl($e.class & " " & e.path)
    r1.errors.add("/etc/repro: Operation not permitted")
    check keepStateWhenIncomplete(r1, s.l, s.state, shipState = s.ship)
    let kept = readLedger(ledgerCopyPath(s.state))
    check kept.entries.anyIt(it.unit == EvidenceShipUnit)
    check not kept.entries.anyIt(it.unit == "other.service")
    # The re-run: the kept ledger tells it the state is the add-on's.
    var r2: UninstallResult
    removeShipState(r2, kept, s.ship)
    check r2.errors.len == 0
    check not dirExists(s.ship[0])
    check not dirExists(s.ship[1])

  test "once the state is gone, the entry goes with the unit":
    let s = scene("gone")
    removeDir(s.ship[0])
    removeDir(s.ship[1])
    var r: UninstallResult
    for e in s.l.entries: r.undone.incl($e.class & " " & e.path)
    let left = remainingLedger(s.l, r, s.ship)
    check left.entries.len == 0

  test "a ledger without the shipping unit removes nothing":
    let s = scene("foreign")
    var r: UninstallResult
    removeShipState(r, Ledger(generation: "g0"), s.ship)
    check dirExists(s.ship[0])
    check r.removed.len == 0

  test "a link in the state's place is removed, not followed":
    let s = scene("link")
    let target = root / "link" / "elsewhere"
    createDir(target)
    writeFile(target / "keep", "x")
    removeDir(s.ship[0])
    createDir(parentDir(s.ship[0]))
    createSymlink(target, s.ship[0])
    var r: UninstallResult
    removeShipState(r, s.l, s.ship)
    check not symlinkExists(s.ship[0])
    check fileExists(target / "keep")

  test "the host's paths are the dynamic user's state and the copies":
    check ShipStatePaths == @EvidenceShipStatePaths & @[ConfinedExeCopyDir]

removeDir(root)
