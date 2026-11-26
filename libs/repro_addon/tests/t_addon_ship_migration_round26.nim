## Existing hosts are migrated to the shipping unit's own user and to the
## egress check without ``CAP_DAC_OVERRIDE`` (ReproOS Add-On Mode spec §13
## decisions 181 and 188, as amended by the owner's decision of 2026-11-26,
## "migrate existing hosts"; A11 round 26, Medium 2).
##
## * The own-profile migration renders the shipping unit whole (its dynamic
##   user, confinement and harvest step), and the egress check unit whole
##   (``CAP_NET_ADMIN`` alone), from what the installed text names.
## * The re-point accepts the units an earlier engine installed and puts the
##   migrated ones on the applying engine; an apply that cannot re-point
##   keeps them as installed (``keepUnitsFrom``).
## * The shipping state from before decision 181 -- the root outbox under
##   the evidence directory, and the receipt and shipping times in
##   ``EvidenceStateDir`` -- moves into the dynamic user's state directory:
##   every queued record once, the receipt kept, the apt hook cursor left
##   where root reads it.
## * A move stopped in the middle (a crash) loses nothing and queues nothing
##   twice once it runs again, and no shipping run ships while it is
##   unfinished.
##
## Falsifying builds: ``migration-skips-ship-identity``,
## ``migration-skips-egress-check``, ``legacy-move-skips-outbox``,
## ``legacy-move-unlinks-first`` (the crash case) and
## ``legacy-ship-ungated``.
##
## *Mocking.* The re-point's file-system probe and the ledger's digests are
## closures over the own profile "on disk", as in the A9 round-19 test (the
## VM step ``e2e_addon_evidence_migration`` drives the same code on a host
## an earlier engine bootstrapped). A crash is stood for by the move's test
## hook raising at the point a kill would stop it; everything else is real
## directories and files and the module's own code.

import std/[algorithm, os, strutils, unittest]

import repro_addon/evidence_ship
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/record_dir

const
  E1 = "/repro/store/prefixes/repro-addon/0.2.20-aaaaaaaaaaaaaaaa/bin/repro"
  E2 = "/repro/store/prefixes/repro-addon/0.2.38-bbbbbbbbbbbbbbbb/bin/repro"
  Sink = "192.0.2.9"

proc currentOwn(exe: string): string =
  ## Generation 0 with the deploy agent, the egress observer and a sink, as
  ## this build renders it.
  let agent = AgentUnitsInputs(target: "https://deploy.example/h",
    sources: @["https://deploy.example/m"], allowedAddresses: @["192.0.2.1"])
  renderOwnProfile(generation0Objects(Gen0Inputs(reproExe: exe, agent: agent,
    egress: EgressObserverInputs(nft: "/usr/sbin/nft",
                                 allowedAddresses: agent.allowedAddresses),
    evidence: EvidenceUnitsInputs(sinkAddress: Sink, sinkPort: 7443))), "/f")

proc earlierOwn(exe: string): string =
  ## The same generation 0 as an engine before decision 181 installed its
  ## shipping unit (root, no harvest step, the legacy state writable) and
  ## one before decision 188 its egress check (CAP_DAC_OVERRIDE, the dynamic
  ## user's state writable).
  let cur = currentOwn(exe)
  var ship = unitContentOf(cur, EvidenceShipUnit)
  var lines: seq[string]
  for l in ship.splitLines():
    if l.startsWith("DynamicUser=") or l.startsWith("User=") or
        l.startsWith("ExecStartPre=") or l.startsWith("StateDirectory") or
        l.startsWith("LoadCredential=") or l.startsWith("Environment="):
      continue
    lines.add(l)
    if l.startsWith("ProtectSystem="):
      lines.add("ReadWritePaths=" & EvidenceStateDir & " " & LegacyOutboxPath)
  ship = lines.join("\n")
  let check = unitContentOf(cur, EgressCheckUnit).replace(
      "CapabilityBoundingSet=CAP_NET_ADMIN\n",
      "CapabilityBoundingSet=CAP_NET_ADMIN CAP_DAC_OVERRIDE\n").replace(
      "ReadWritePaths=" & EvidenceDirPath & "\n",
      "ReadWritePaths=" & EvidenceDirPath & " -" & EvidenceShipStateDir & "\n")
  replaceUnitContent(replaceUnitContent(cur, EvidenceShipUnit, ship),
                     EgressCheckUnit, check)

proc hostWith(onDisk: string): tuple[probe: PathProbe; rec: RecordedDigest] =
  let probe = proc (p: string): tuple[present: bool; sha256: string] =
    for u in RepointedUnits:
      if p == unitPath(u):
        let c = unitContentOf(onDisk, u)
        if c.len > 0: return (true, sha256Hex(c))
    (false, "")
  (probe, proc (p: string): string = probe(p).sha256)

let root = getTempDir() / ("addon-ship-migration-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc legacySite(name: string): ShipSite =
  let base = root / name
  createDir(base / "evidence" / "outbox")
  createDir(base / "evidence-state")
  ShipSite(stateDir: base / "private" / "repro-addon-evidence",
           outbox: base / "private" / "repro-addon-evidence" / "outbox",
           legacyOutbox: base / "evidence" / "outbox",
           legacyStateDir: base / "evidence-state")

proc names(dir: string): seq[string] =
  for kind, p in walkDir(dir):
    if p.endsWith(".evr"): result.add(extractFilename(p))
  result.sort()

const Queued = ["00000000000000000001-10-apply.evr",
                "00000000000000000002-11-reassert.evr",
                "00000000000000000003-12-egress.evr"]

proc plant(s: ShipSite) =
  for i, n in Queued: writeFile(s.legacyOutbox / n, "record " & $i)
  writeFile(s.legacyStateDir / "receipt", "R1\n")
  writeFile(s.legacyStateDir / "last-ship", "100\n")
  writeFile(s.legacyStateDir / "apt-hook.cursor", "C\n")

proc exactlyOnce(s: ShipSite): bool =
  ## Every planted record is in the outbox once, with its bytes, and none is
  ## left in the legacy outbox.
  let got = names(s.outbox)
  if got != @Queued: return false
  for i, n in Queued:
    if readFile(s.outbox / n) != "record " & $i: return false
  not dirExists(s.legacyOutbox) or names(s.legacyOutbox).len == 0

type Killed = object of CatchableError

suite "existing hosts are migrated (owner decision 2026-11-26)":
  test "the migration renders the shipping unit whole: its own user":
    let m = migrateOwnProfile(earlierOwn(E1))
    let ship = unitContentOf(m, EvidenceShipUnit)
    checkpoint ship
    check ship == evidenceShipUnit(E1, EvidenceUnitsInputs(sinkAddress: Sink))
    check "DynamicUser=yes\n" in ship
    check ("ExecStartPre=+" & E1 & " system addon evidence-harvest\n") in ship

  test "the migration renders the egress check whole: CAP_NET_ADMIN alone":
    let m = migrateOwnProfile(earlierOwn(E1))
    let c = unitContentOf(m, EgressCheckUnit)
    checkpoint c
    check c == egressCheckUnit(E1)
    check "CAP_DAC_OVERRIDE" notin c
    check ("ReadWritePaths=" & EvidenceDirPath & "\n") in c

  test "the re-point accepts the earlier units and runs the migrated ones on the new engine":
    let onHost = earlierOwn(E1)
    let h = hostWith(onHost)
    let rp = repointEngine(migrateOwnProfile(onHost), E2, [E1], h.probe, h.rec,
                           stored = repointStoredTexts(onHost, onHost))
    check rp.exe == E2
    check unitContentOf(rp.own, EvidenceShipUnit) ==
      evidenceShipUnit(E2, EvidenceUnitsInputs(sinkAddress: Sink))
    check unitContentOf(rp.own, EgressCheckUnit) == egressCheckUnit(E2)
    # An apply that cannot re-point keeps both as installed.
    let kept = keepUnitsFrom(migrateOwnProfile(onHost), onHost, ShapeMigratedUnits)
    check unitContentOf(kept, EvidenceShipUnit) == unitContentOf(onHost, EvidenceShipUnit)
    check unitContentOf(kept, EgressCheckUnit) == unitContentOf(onHost, EgressCheckUnit)

  test "this build's own profile is left as it is":
    let own = currentOwn(E2)
    check migrateOwnProfile(own) == own

  test "the legacy state moves: every record once, the receipt kept, the cursor left":
    let s = legacySite("move")
    plant(s)
    let m = moveLegacyShipState(s)
    checkpoint $m
    check m.found
    check exactlyOnce(s)
    check not dirExists(s.legacyOutbox)
    check readFile(s.stateDir / "receipt") == "R1\n"
    check readFile(s.stateDir / "last-ship") == "100\n"
    check not fileExists(s.legacyStateDir / "receipt")
    check readFile(s.legacyStateDir / "apt-hook.cursor") == "C\n"
    check legacyLeft(s.stateDir) == 0
    # Nothing left: a second run finds nothing and writes nothing.
    check not moveLegacyShipState(s).found

  test "a newer receipt in the dynamic user's state is kept":
    let s = legacySite("newer")
    plant(s)
    writeDelegatedStateFile(s.stateDir, "receipt", "R2\n")
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == "R2\n"
    check not fileExists(s.legacyStateDir / "receipt")

  test "a move killed after handing a record over: once, nothing lost, nothing ships meanwhile":
    let s = legacySite("crash-entry")
    plant(s)
    crashPointHook = proc (point: string) =
      if point.startsWith("handed-over:"):
        raise newException(Killed, "killed at " & point)
    var killed = false
    try: discard moveLegacyShipState(s)
    except Killed: killed = true
    crashPointHook = nil
    check killed
    # The move is unfinished: the backoff counts it and a shipping run
    # ships nothing.
    check legacyLeft(s.stateDir) > 0
    check shipRunWait(s, 300) > 0
    var why = ""
    try:
      why = runEvidenceShip(s, EvidenceConf(sinkEndpoint: "127.0.0.1:1",
        sinkHost: repeat('0', 64), heartbeatSec: 300), "h").error
    except CatchableError as e:
      why = e.msg
    checkpoint why
    check "has not been moved yet" in why
    # Run again, as the next harvest does.
    discard moveLegacyShipState(s)
    check exactlyOnce(s)
    check legacyLeft(s.stateDir) == 0

  test "a move killed after copying the receipt: kept once":
    let s = legacySite("crash-state")
    plant(s)
    crashPointHook = proc (point: string) =
      if point == "state-copied:receipt":
        raise newException(Killed, "killed at " & point)
    var killed = false
    try: discard moveLegacyShipState(s)
    except Killed: killed = true
    crashPointHook = nil
    check killed
    check fileExists(s.legacyStateDir / "receipt")
    discard moveLegacyShipState(s)
    check readFile(s.stateDir / "receipt") == "R1\n"
    check not fileExists(s.legacyStateDir / "receipt")
    check exactlyOnce(s)

removeDir(root)
