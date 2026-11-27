## The legacy shipping-state move never leaves shipping refused, and keeps
## the newer state (ReproOS Add-On Mode spec §13 decision 181 as amended by
## the operator's decision of 2026-11-26, "Migrate existing hosts"; A11
## round 27, M1, L2, L3). Built on the round-27 reviewer's reproduction.
##
## * A mark an unfinished move left ("1": killed after its last removal or
##   after removing the emptied legacy outbox) is cleared by the next
##   harvest, which runs the move again because of it; shipping is then not
##   refused.
## * A link or a FIFO in the legacy outbox's place (the egress check, uid 0
##   with the evidence directory writable, can plant one) is moved aside
##   unread; the move does not fail, and shipping is not refused.
## * A legacy receipt newer than the dynamic user's (the sink's chain head)
##   replaces it; an older one does not.
## * While a shipping run of the earlier engine holds its lock, the move
##   takes nothing; once it is released, it moves.
## * The path unit starts the shipping unit for the legacy outbox too, so
##   records the units that keep the bootstrap engine write there leave at
##   once.
##
## Falsifying builds: ``legacy-left-not-rerun`` (the mark after the rmdir),
## ``legacy-outbox-not-dir-raises`` (the link and the FIFO),
## ``legacy-state-newer-dropped`` (the newer receipt),
## ``legacy-move-ignores-ship-lock`` (the earlier engine's run) and
## ``path-unit-ignores-legacy-outbox`` (the path unit).
##
## *Mocking.* A crash is stood for by the move's test hook raising
## ``CrashPointKill`` at the point a kill would stop it; the earlier
## engine's shipping run by this process holding its lock file. Everything
## else is real directories, links, FIFOs and files and the module's code.

import std/[algorithm, os, posix, strutils, unittest]

import repro_addon/evidence_ship
import repro_addon/generation0
import repro_addon/record_dir
import repro_core/file_lock

let root = getTempDir() / ("addon-legacy-r27-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc site(name: string): ShipSite =
  let base = root / name
  createDir(base / "evidence")
  createDir(base / "evidence-state")
  ShipSite(stateDir: base / "private" / "s", outbox: base / "private" / "s" / "outbox",
           legacyOutbox: base / "evidence" / "outbox",
           legacyStateDir: base / "evidence-state")

proc shipErr(s: ShipSite): string =
  ## Why a shipping run did not ship ("" when it tried); the sink is
  ## unreachable, so a run that is not refused fails to connect instead.
  try:
    runEvidenceShip(s, EvidenceConf(sinkEndpoint: "127.0.0.1:1",
      sinkHost: repeat('0', 64), heartbeatSec: 300), "h").error
  except CatchableError as e: "raised: " & e.msg

proc refused(s: ShipSite): bool = "has not been moved yet" in shipErr(s)

proc names(dir: string): seq[string] =
  for kind, p in walkDir(dir):
    if p.endsWith(".evr"): result.add(extractFilename(p))
  result.sort()

const Queued = ["00000000000000000001-10-apply.evr",
                "00000000000000000002-11-store-verify.evr"]

proc plant(s: ShipSite) =
  createDir(s.legacyOutbox)
  for i, n in Queued: writeFile(s.legacyOutbox / n, "record " & $i)

proc receipt(sq: int): string =
  $sq & " " & repeat('a', 64) & " " & repeat('b', 128) & " 1000\n"

var killPoint = ""
proc killHook(p: string) {.nimcall.} =
  if p == killPoint: raise newException(CrashPointKill, "killed at " & p)

suite "the legacy move never leaves shipping refused (round 27)":
  test "a mark left after a full move is cleared by the next harvest":
    let s = site("crash")
    plant(s)
    writeFile(s.legacyStateDir / "receipt", receipt(5))
    discard moveLegacyShipState(s)
    check legacyLeft(s.stateDir) == 0
    # A kill between the rmdir and the final count: everything moved, the
    # "1" written at the start still there.
    writeDelegatedEntry(s.stateDir / "harvest", LegacyLeftName, "1\n", mode = 0o644)
    let m = moveLegacyShipState(s)
    check m.found
    check legacyLeft(s.stateDir) == 0
    check not refused(s)

  test "killed after removing its last entry: the next harvest finishes":
    let s = site("kill-removed")
    plant(s)
    killPoint = "removed:" & Queued[^1]
    crashPointHook = killHook
    expect CrashPointKill: discard moveLegacyShipState(s)
    crashPointHook = nil
    check legacyLeft(s.stateDir) == 1
    check refused(s)
    discard moveLegacyShipState(s)
    check legacyLeft(s.stateDir) == 0
    check names(s.outbox) == @Queued
    check not dirExists(s.legacyOutbox)
    check not refused(s)

  test "killed after removing the emptied legacy outbox: the next harvest clears the mark":
    let s = site("kill-rmdir")
    plant(s)
    killPoint = "legacy-rmdir"
    crashPointHook = killHook
    expect CrashPointKill: discard moveLegacyShipState(s)
    crashPointHook = nil
    check legacyLeft(s.stateDir) == 1
    check not dirExists(s.legacyOutbox)
    check not hasLegacyShipState(s)
    discard moveLegacyShipState(s)
    check legacyLeft(s.stateDir) == 0
    check names(s.outbox) == @Queued
    check not refused(s)

  test "a link in the legacy outbox's place is moved aside, not followed":
    let s = site("link")
    createDir(root / "elsewhere")
    writeFile(root / "elsewhere" / "x.evr", "not a queued record")
    check symlink((root / "elsewhere").cstring, s.legacyOutbox.cstring) == 0
    var raised = ""
    try: discard moveLegacyShipState(s)
    except CatchableError as e: raised = e.msg
    check raised == ""
    check legacyLeft(s.stateDir) == 0
    var st: Stat
    check lstat(s.legacyOutbox.cstring, st) != 0
    check fileExists(root / "elsewhere" / "x.evr")
    check names(s.outbox).len == 0
    check not refused(s)

  test "a FIFO in the legacy outbox's place is moved aside":
    let s = site("fifo")
    check mkfifo(s.legacyOutbox.cstring, 0o600) == 0
    var raised = ""
    try: discard moveLegacyShipState(s)
    except CatchableError as e: raised = e.msg
    check raised == ""
    check legacyLeft(s.stateDir) == 0
    var st: Stat
    check lstat(s.legacyOutbox.cstring, st) != 0
    check not refused(s)

  test "a newer legacy receipt replaces the dynamic user's, an older one does not":
    let s = site("receipt")
    writeDelegatedStateFile(s.stateDir, "receipt", receipt(7))
    writeFile(s.legacyStateDir / "receipt", receipt(9))
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == receipt(9)
    writeFile(s.legacyStateDir / "receipt", receipt(3))
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == receipt(9)
    check not fileExists(s.legacyStateDir / "receipt")

  test "a shipping run of the earlier engine excludes the move":
    let s = site("shiplock")
    plant(s)
    var held = acquireExclusiveLockWithin(s.legacyStateDir / "ship.lock", 1000)
    let m = moveLegacyShipState(s, lockWaitMs = 200)
    checkpoint m.skipped
    check m.skipped.len > 0
    check names(s.legacyOutbox) == @Queued
    check names(s.outbox).len == 0
    releaseExclusiveFileLock(held)
    discard moveLegacyShipState(s, lockWaitMs = 200)
    check names(s.outbox) == @Queued
    check legacyLeft(s.stateDir) == 0

  test "the path unit starts shipping for the legacy outbox too":
    check ("DirectoryNotEmpty=" & LegacyOutboxPath & "\n") in evidenceShipPathUnit()

removeDir(root)
