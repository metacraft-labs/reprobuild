## Evidence shipping cannot be stopped or spun by what the harvest cannot
## move, and the legacy move loses nothing to a writer or a shipping run
## (ReproOS Add-On Mode spec §13 decisions 181 and 188 as amended; A11 round
## 28, M-a, M-b, L3, and the egress units' floor and credential). Built on
## the round-28 reviewer's cases A-F.
##
## * A: an entry the harvest can neither move aside nor remove (a
##   directory, when the aside directory refuses it) counts as left, so the
##   shipping unit's backoff spaces the restarts the path unit makes; and a
##   file planted where ``<dir>-rejected`` belongs is renamed out of the way,
##   so moving aside still works. In the legacy outbox and the drop
##   directory alike.
## * M-b: an emptied legacy outbox is never removed, so a writer that made it
##   and is about to rename a record into it is not undone; an empty legacy
##   outbox is no legacy state.
## * L3: the move waits for this engine's shipping lock as well as the
##   earlier engine's.
## * C, D, E, F: the receipt order with a corrupt receipt on either side; a
##   kill after copying the receipt; a kill after a hand-over; a move skipped
##   for its lock keeps its mark.
## * The egress observer and its check carry MemoryDenyWriteExecute= and a
##   syscall filter, and the check cannot see the sink credential.
##
## Falsifying builds: ``aside-failure-not-left`` (A, the refused aside),
## ``aside-dir-planted-file-kept`` (A, the planted file),
## ``legacy-outbox-removed-when-empty`` (M-b),
## ``legacy-move-ignores-confined-lock`` (L3), ``egress-units-unhardened``
## and ``egress-check-sees-credential`` (the units).
##
## *Mocking.* A crash is stood for by the move's test hook raising
## ``CrashPointKill``; a shipping run by this process holding its lock; a
## writer by this test's own mkdir and write. An aside directory that
## refuses an entry is one made read-only (the test does not run as root).
## Everything else is real directories, files and the module's code.

import std/[algorithm, os, posix, sequtils, strutils, unittest]

import repro_addon/evidence_ship
import repro_addon/generation0
import repro_addon/record_dir
import repro_core/file_lock

let root = getTempDir() / ("addon-evidence-r28-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc site(name: string): ShipSite =
  let base = root / name
  createDir(base / "evidence")
  createDir(base / "evidence-state")
  ShipSite(stateDir: base / "private" / "s", outbox: base / "private" / "s" / "outbox",
           legacyOutbox: base / "evidence" / "outbox",
           legacyStateDir: base / "evidence-state",
           dropDir: base / "evidence" / "egress-drop")

proc shipErr(s: ShipSite): string =
  try:
    runEvidenceShip(s, EvidenceConf(sinkEndpoint: "127.0.0.1:1",
      sinkHost: repeat('0', 64), heartbeatSec: 300), "h").error
  except CatchableError as e: "raised: " & e.msg

proc refused(s: ShipSite): bool = "has not been moved yet" in shipErr(s)

proc entries(dir: string): seq[string] =
  for kind, p in walkDir(dir): result.add(extractFilename(p))
  result.sort()

proc receipt(sq: int): string =
  $sq & " " & repeat('a', 64) & " " & repeat('b', 128) & " 1000\n"

var killPoint = ""
proc killHook(p: string) {.nimcall.} =
  if p == killPoint: raise newException(CrashPointKill, "killed at " & p)

suite "round 28: shipping cannot be stopped or spun, nothing is lost":
  test "A: a file planted at the legacy outbox's aside directory is moved out of the way":
    let s = site("A")
    createDir(s.legacyOutbox / "d")
    writeFile(s.legacyOutbox.parentDir / "outbox-rejected", "planted")
    let m = moveLegacyShipState(s)
    checkpoint $m
    check entries(s.legacyOutbox).len == 0
    check dirExists(s.legacyOutbox.parentDir / "outbox-rejected")
    check entries(s.legacyOutbox.parentDir).anyIt(it.startsWith("outbox-rejected.displaced."))
    check legacyLeft(s.stateDir) == 0

  test "B: the same in the egress drop directory":
    let s = site("B")
    createDir(s.dropDir / "d")
    writeFile(s.dropDir & "-rejected", "planted")
    let h = harvestDropEntries(s.dropDir, s.outbox, s.stateDir)
    checkpoint $h
    check entries(s.dropDir).len == 0
    check dirExists(s.dropDir & "-rejected")

  test "A': an entry neither moved aside nor removed counts as left, and the backoff waits":
    let s = site("A2")
    createDir(s.dropDir / "d")
    createDir(s.dropDir & "-rejected")
    check chmod(cstring(s.dropDir & "-rejected"), 0o500) == 0
    let h = harvestDropEntries(s.dropDir, s.outbox, s.stateDir)
    discard chmod(cstring(s.dropDir & "-rejected"), 0o700)
    checkpoint $h
    check h.left.len == 1
    check entries(s.dropDir) == @["d"]
    check readFile(dropLeftPath(s.stateDir)).strip() == "1"
    check shipRunWait(s, 300) > 0

  test "M-b: an emptied legacy outbox stays, so a writer's rename into it lands":
    let s = site("Mb")
    # The writer: mkdir first (the earlier engine's evidence.nim) ...
    createDir(s.legacyOutbox)
    # ... a harvest runs in its window ...
    let m = moveLegacyShipState(s)
    check not m.found                        # an empty outbox is no legacy state
    discard runHarvest(s, "h")
    # ... and the writer's staged rename into it still lands.
    var wrote = true
    try: writeFile(s.legacyOutbox / "00000000000000000001-1-store-verify.evr", "r")
    except IOError: wrote = false
    check wrote
    check dirExists(s.legacyOutbox)
    discard moveLegacyShipState(s)
    check entries(s.outbox) == @["00000000000000000001-1-store-verify.evr"]
    check dirExists(s.legacyOutbox)

  test "L3: the move waits for this engine's shipping lock":
    let s = site("L3")
    createDir(s.legacyOutbox)
    writeFile(s.legacyOutbox / "1-a.evr", "x")
    createDir(s.stateDir)
    var held = acquireExclusiveLockWithin(s.stateDir / "ship.lock", 1000)
    let m = moveLegacyShipState(s, lockWaitMs = 200)
    checkpoint m.skipped
    check m.skipped.len > 0
    check entries(s.legacyOutbox) == @["1-a.evr"]
    releaseExclusiveFileLock(held)
    discard moveLegacyShipState(s, lockWaitMs = 200)
    check entries(s.outbox) == @["1-a.evr"]

  test "C: the receipt order, with a corrupt receipt on either side":
    let s = site("C")
    writeDelegatedStateFile(s.stateDir, "receipt", receipt(7))
    writeFile(s.legacyStateDir / "receipt", receipt(7).replace("1000", "2000"))
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == receipt(7)   # equal head: theirs kept
    writeFile(s.legacyStateDir / "receipt", "garbage\n")
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == receipt(7)   # corrupt legacy: theirs kept
    writeDelegatedStateFile(s.stateDir, "receipt", "garbage\n")
    writeFile(s.legacyStateDir / "receipt", receipt(2))
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == receipt(2)   # corrupt theirs: legacy wins
    check not fileExists(s.legacyStateDir / "receipt")

  test "D: killed after copying the receipt, the rerun finishes":
    let s = site("D")
    writeDelegatedStateFile(s.stateDir, "receipt", receipt(3))
    writeFile(s.legacyStateDir / "receipt", receipt(9))
    createDir(s.legacyOutbox); writeFile(s.legacyOutbox / "1-a.evr", "x")
    killPoint = "state-copied:receipt"; crashPointHook = killHook
    expect CrashPointKill: discard moveLegacyShipState(s)
    crashPointHook = nil
    check legacyLeft(s.stateDir) == 1
    check refused(s)
    discard moveLegacyShipState(s)
    check legacyLeft(s.stateDir) == 0
    check readFile(s.stateDir / "receipt") == receipt(9)
    check entries(s.outbox) == @["1-a.evr"]

  test "E: killed after a hand-over, the rerun replaces the copy, once":
    let s = site("E")
    createDir(s.legacyOutbox); writeFile(s.legacyOutbox / "1-a.evr", "x")
    writeFile(s.legacyOutbox / "2-b.evr", "y")
    killPoint = "handed-over:1-a.evr"; crashPointHook = killHook
    expect CrashPointKill: discard moveLegacyShipState(s)
    crashPointHook = nil
    check legacyLeft(s.stateDir) == 1
    check refused(s)
    discard moveLegacyShipState(s)
    check legacyLeft(s.stateDir) == 0
    check entries(s.outbox) == @["1-a.evr", "2-b.evr"]
    check not refused(s)

  test "F: a move skipped for its lock keeps its mark, and the next one clears it":
    let s = site("F")
    createDir(s.legacyOutbox); writeFile(s.legacyOutbox / "1-a.evr", "x")
    writeDelegatedEntry(s.stateDir / "harvest", LegacyLeftName, "1\n", mode = 0o644)
    var held = acquireExclusiveLockWithin(s.legacyStateDir / "legacy-move.lock", 1000)
    let m = moveLegacyShipState(s, lockWaitMs = 100)
    check m.skipped.len > 0
    releaseExclusiveFileLock(held)
    check legacyLeft(s.stateDir) == 1
    discard moveLegacyShipState(s, lockWaitMs = 100)
    check legacyLeft(s.stateDir) == 0

  test "the egress units carry MemoryDenyWriteExecute= and a syscall filter":
    for u in [egressUnit("/usr/sbin/nft"), egressCheckUnit("/repro/x/bin/repro")]:
      check "MemoryDenyWriteExecute=yes\n" in u
      check "SystemCallFilter=@system-service\n" in u
      check "SystemCallErrorNumber=EPERM\n" in u

  test "the egress check cannot see the sink credential":
    let u = egressCheckUnit("/repro/x/bin/repro")
    var hidden = ""
    for l in u.splitLines():
      if l.startsWith("InaccessiblePaths="): hidden = l
    checkpoint hidden
    check ("-" & EvidenceStateDir) in hidden.splitWhitespace()[0 .. ^1].join(" ")

removeDir(root)
