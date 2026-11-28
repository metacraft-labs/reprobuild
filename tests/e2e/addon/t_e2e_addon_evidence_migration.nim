## Add-on VM gate: a host an earlier engine bootstrapped is migrated by an
## operator's apply with this engine (ReproOS Add-On Mode spec §13 decisions
## 181, the shipping unit's dynamic user, and 188, the egress drop
## directory, as amended by the operator's decision of 2026-11-26, "Migrate
## existing hosts"; A11 rounds 26 and 27).
##
## Two stand-ins for hosts that already exist, chosen by
## ``REPRO_A11_STANDIN`` with the artefact in ``REPRO_A11_STANDIN_ADDON``
## (``REPRO_A11_PRE_G56_ADDON`` also names the pre-181 one):
##
## * ``pre-181``: a static add-on artefact built from reprobuild
##   ``64bda75f1f``, the commit before decision 181. Its shipping unit is
##   root with AF_UNIX allowed, its outbox and receipt are in the root
##   paths of that time, and its egress check allows AF_UNIX and writes the
##   root outbox. It already holds CAP_NET_ADMIN alone.
## * ``pre-188``: one built from ``d2d8b33498``, the commit before decision
##   188. Its shipping unit is the dynamic user already; its egress check
##   holds CAP_DAC_OVERRIDE and writes the dynamic user's outbox.
##
## On each base:
##
## 1. the stand-in bootstraps the add-on with the deploy agent and a sink,
##    and the gate checks the units are what that engine renders;
## 2. the sink refuses the host (its anchor revoked), and two applies by the
##    stand-in queue records;
## 3. this engine's plan lists the units it migrates, and its operator apply
##    is not refused; afterwards the egress check holds CAP_NET_ADMIN alone
##    and has no AF_UNIX, and the shipping unit runs as its dynamic user,
##    without AF_UNIX, on this engine;
## 4. (pre-181) the harvest moves the queued records and the receipt into
##    the dynamic user's state directory; the apt hook cursor stays;
## 5. an egress check run's record goes through the drop directory: the
##    shipping unit's harvest reports moving it;
## 6. the sink accepts the host again, and every record queued in step 2
##    reaches it exactly once;
## 7. (pre-181) with the shipping timer stopped, a record written into the
##    old outbox as the bootstrap engine writes it reaches the sink through
##    the path unit: the steady state of a migrated host.
##
## Falsifying builds, red here: ``migration-skips-ship-identity`` on the
## pre-181 stand-in (the shipping unit stays root, step 3) and
## ``migration-skips-egress-check`` on the pre-188 stand-in (the egress
## check keeps CAP_DAC_OVERRIDE, step 3).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and a stand-in artefact.
##
## *Mocking.* None: the real add-on of two engines, the real sink, the
## base's own systemd.

import std/[json, os, sequtils, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_peer_cache/evidence
import repro_peer_cache/types

import ./addon_testbed
import ./agent_e2e_support
import ./evidence_e2e_support

const
  Gate = "e2e_addon_evidence_migration"
  Head = "addOn {\n  managedEtcPrefixes = []\n}\n\n"
  LegacyOutbox = "/var/lib/repro/system/addon/evidence/outbox"
  LegacyState = "/var/lib/repro/evidence"
  ShipState = "/var/lib/private/repro-addon-evidence"

proc standIn(): string = getEnv("REPRO_A11_STANDIN", "pre-181")

proc standInArtefact(): string =
  result = getEnv("REPRO_A11_STANDIN_ADDON")
  if result.len == 0 and standIn() == "pre-181":
    result = getEnv("REPRO_A11_PRE_G56_ADDON")

proc installPrevious(g: Guest; dir = "/root/addon-prev"): tuple[repro, sha: string] =
  ## The previous engine's artefact, verified in the guest against its
  ## published digest before it runs, as ``installArtefact`` does.
  let root = standInArtefact()
  if root.len == 0:
    raise newException(TestBedError, "REPRO_A11_STANDIN_ADDON must name the " &
      "stand-in engine's add-on artefact directory")
  let a = root / g.base.debArch
  let sha = readFile(a / "repro.sha256").splitWhitespace()[0]
  discard g.run("mkdir -p " & dir)
  g.copyTo(a / "repro", dir & "/repro")
  g.copyTo(a / "reprobuild-sandbox-launcher", dir & "/reprobuild-sandbox-launcher")
  discard g.run("cd " & dir & " && echo '" & sha & "  repro' | sha256sum -c - && " &
                "chmod 0755 repro reprobuild-sandbox-launcher")
  (dir & "/repro", sha)

proc marker(n: int): string =
  Head & "fs.systemFile {\n  path = \"/etc/repro/a11-migration\"\n" &
    "  content = \"" & $n & "\n\"\n}\n"

proc unitText(g: Guest; unit: string): string =
  g.exec("cat /etc/systemd/system/" & unit).stdout

proc families(g: Guest; unit: string): string =
  g.exec("systemctl show -p RestrictAddressFamilies --value " & unit).stdout.strip()

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let kind = standIn()
  record["standIn"] = %kind
  let pre181 = kind == "pre-181"
  let (prev, prevSha) = g.installPrevious()
  record["previousArtefactSha256"] = %prevSha
  # 1. The stand-in bootstraps with the agent and the sink.
  let bs = g.bootstrapShipping(prev, step, producer)
  var sink = bs.sink
  defer: sink.stop()
  if not bs.ok: return
  let shipBefore = g.unitText("repro-addon-evidence.service")
  let checkCapsBefore = g.exec("systemctl show -p CapabilityBoundingSet --value " &
                               "repro-addon-egress-check.service").stdout.strip()
  record["unitsBefore"] = %*{"ship": shipBefore, "checkCaps": checkCapsBefore,
    "shipFamilies": g.families("repro-addon-evidence.service"),
    "checkFamilies": g.families("repro-addon-egress-check.service")}
  let oldShipExe = g.exec("sed -n 's/^ExecStart=\\(.*\\) system addon evidence-ship$/\\1/p' " &
    "/etc/systemd/system/repro-addon-evidence.service").stdout.strip()
  record["previousShipExe"] = %oldShipExe
  if pre181:
    step("pre-181: the stand-in's shipping unit is root with AF_UNIX, its outbox the root one",
         "DynamicUser=yes" notin shipBefore and
         "AF_UNIX" in g.families("repro-addon-evidence.service") and
         "AF_UNIX" in g.families("repro-addon-egress-check.service") and
         g.exec("test -d " & LegacyOutbox).exitCode == 0, $record["unitsBefore"])
  else:
    step("pre-188: the stand-in's shipping unit is its dynamic user, its egress check holds CAP_DAC_OVERRIDE",
         "DynamicUser=yes" in shipBefore and "cap_dac_override" in checkCapsBefore,
         $record["unitsBefore"])
  # 2. The sink refuses the host; two applies queue records.
  sink.revoke(bs.host)
  for i in 1 .. 2:
    let r = g.applyProfile(prev, "p" & $i, marker(i))
    step("the stand-in's apply " & $i & " passes", r.exitCode == 0,
         r.stdout & r.stderr)
  discard g.exec("systemctl start repro-addon-evidence.service")
  let queueDir = if pre181: LegacyOutbox else: ShipState & "/outbox"
  let queued = g.exec("cd " & queueDir & " && ls -1 *.evr 2>/dev/null; true").stdout.
    splitLines().filterIt(it.strip().len > 0)
  record["queued"] = %queued
  step("records are queued in the stand-in's outbox while the sink refuses the host",
       queued.len >= 2, $queued)
  let snap = g.runDir / "queued"
  createDir(snap)
  var queuedBytes: seq[string]
  for n in queued:
    g.copyFrom(queueDir & "/" & n, snap / n)
    queuedBytes.add(readFile(snap / n))
  let receipt = g.exec("cat " & LegacyState & "/receipt 2>/dev/null; true").stdout
  let cursor = g.exec("sha256sum " & LegacyState & "/apt-hook.cursor 2>/dev/null; true").stdout
  if pre181:
    record["legacyReceipt"] = %receipt
    step("pre-181: the stand-in kept the sink's receipt in the root state",
         receipt.strip().len > 0, receipt)
  # 3. This engine's plan and operator apply.
  let plan = g.planProfile(repro, "u1", marker(3))
  record["plan"] = %(plan.stdout & plan.stderr)
  step("this engine's plan lists the units it migrates",
       plan.exitCode == 0 and "generation 0 migrated by this engine" in plan.stdout and
         "  repro-addon-egress-check.service\n" in plan.stdout and
         (not pre181 or "  repro-addon-evidence.service\n" in plan.stdout),
       plan.stdout & plan.stderr)
  let r = g.applyProfile(repro, "u1", marker(3))
  step("this engine's operator apply passes (the migration is not refused)",
       r.exitCode == 0, r.stdout & r.stderr)
  let caps = g.exec("systemctl show -p CapabilityBoundingSet --value " &
                    "repro-addon-egress-check.service").stdout.strip()
  step("the egress check holds CAP_NET_ADMIN alone", caps == "cap_net_admin",
       caps & "\n" & g.unitText("repro-addon-egress-check.service"))
  let fam = (ship: g.families("repro-addon-evidence.service"),
             check: g.families("repro-addon-egress-check.service"))
  record["familiesAfter"] = %*{"ship": fam.ship, "check": fam.check}
  step("neither the shipping unit nor the egress check may make an AF_UNIX socket",
       "AF_UNIX" notin fam.ship and "AF_UNIX" notin fam.check and
         "AF_INET" in fam.ship and "AF_NETLINK" in fam.check, $fam)
  let id = g.exec("systemctl show -p DynamicUser -p User " &
                  "repro-addon-evidence.service").stdout
  let shipUnit = g.unitText("repro-addon-evidence.service")
  step("the shipping unit runs as its dynamic user, on this engine",
       "DynamicUser=yes" in id and "User=repro-addon-evidence" in id and
         "evidence-harvest" in shipUnit and oldShipExe.len > 0 and
         oldShipExe notin shipUnit,
       id & "\n" & shipUnit)
  # 4. The harvest moves the state, the sink still refusing.
  discard g.exec("systemctl start repro-addon-evidence.service")
  if pre181:
    let moved = g.exec("ls -1 " & ShipState & "/outbox; echo ---; " &
      "test -e " & LegacyOutbox & " && echo legacy-outbox-present; " &
      "cat " & ShipState & "/harvest/legacy-left; true").stdout
    record["afterMove"] = %moved
    var allMoved = true
    for n in queued:
      if n notin moved: allMoved = false
    step("pre-181: the harvest moved every queued record into the dynamic user's outbox",
         allMoved and "legacy-outbox-present" notin moved, moved)
    let newReceipt = g.exec("cat " & ShipState & "/receipt 2>/dev/null; true").stdout
    step("pre-181: the receipt was carried over, and the cursor left in place",
         newReceipt == receipt and
           g.exec("test -e " & LegacyState & "/receipt").exitCode != 0 and
           g.exec("sha256sum " & LegacyState & "/apt-hook.cursor 2>/dev/null; true").stdout == cursor,
         newReceipt & " / " & receipt)
  let owner = g.exec("stat -c '%u' " & ShipState).stdout.strip()
  step("the shipping state directory is not root's", owner.len > 0 and owner != "0",
       owner)
  # 5. The egress check's records now go through the drop directory: the
  # shipping unit's harvest says so when it moves one.
  let since = g.exec("date -u '+%Y-%m-%d %H:%M:%S'").stdout.strip()
  discard g.exec("systemctl start repro-addon-egress-check.service")
  var viaDrop = ""
  for attempt in 0 ..< 30:
    discard g.exec("systemctl start repro-addon-evidence.service")
    viaDrop = g.exec("journalctl -q -o cat -u repro-addon-evidence.service " &
      "--since '" & since & " UTC' | grep -m1 'egress check entr'; true").stdout.strip()
    if viaDrop.len > 0: break
    sleep(2000)
  record["egressViaDrop"] = %viaDrop
  step("an egress check record goes through the root drop directory",
       viaDrop.len > 0, g.exec("ls -la /var/lib/repro/system/addon/evidence; " &
         "journalctl -q -o cat -u repro-addon-egress-check.service | tail -10").stdout)
  # 6. The sink accepts the host again: each queued record once.
  sink.reinstate()
  var counts: seq[int]
  for attempt in 0 ..< 60:
    discard g.exec("systemctl start repro-addon-evidence.service")
    counts = @[]
    let es = sink.entries()
    for b in queuedBytes:
      var c = 0
      for e in es:
        if e.kind == ekRecord and $e.senderHostId == bs.host and
            cast[string](e.body) == b: inc c
      counts.add(c)
    if counts.allIt(it >= 1): break
    sleep(3000)
  # One more run after they all arrived: nothing is sent twice.
  discard g.exec("systemctl start repro-addon-evidence.service")
  counts = @[]
  let es = sink.entries()
  for b in queuedBytes:
    var c = 0
    for e in es:
      if e.kind == ekRecord and $e.senderHostId == bs.host and
          cast[string](e.body) == b: inc c
    counts.add(c)
  record["shippedCounts"] = %counts
  step("every record queued before the upgrade reached the sink exactly once",
       counts.len == queued.len and counts.allIt(it == 1), $counts)
  # 7. (pre-181) The steady state (A11 round 27, measured from round 28):
  # the units that keep the bootstrap engine write into the old outbox for
  # the host's life. A record written there as that engine writes it (a
  # staged file renamed into the old outbox; here a copy of a record it
  # queued above, under a fresh name) reaches the sink with the shipping
  # timer stopped, so only the path unit's DirectoryNotEmpty= on the old
  # outbox can have started the shipping unit.
  if pre181 and queued.len > 0:
    discard g.exec("systemctl stop repro-addon-evidence.timer")
    let fresh = "09999999999999999999-1-steady-state.evr"
    discard g.exec("mkdir -p /var/lib/repro/system/addon/evidence/.outbox-staging")
    g.copyTo(snap / queued[0], "/var/lib/repro/system/addon/evidence/.outbox-staging/" & fresh)
    let t0 = epochTime()
    discard g.exec("mv /var/lib/repro/system/addon/evidence/.outbox-staging/" & fresh &
                   " " & LegacyOutbox & "/" & fresh)
    var arrivedSec = -1.0
    while epochTime() - t0 < 90:
      var c = 0
      for e in sink.entries():
        if e.kind == ekRecord and $e.senderHostId == bs.host and
            cast[string](e.body) == queuedBytes[0]: inc c
      if c >= 2:
        arrivedSec = epochTime() - t0
        break
      sleep(2000)
    let pathRuns = g.exec("journalctl -q -o cat -u repro-addon-evidence.service | " &
      "grep -c 'queued record(s)'; true").stdout.strip()
    record["steadyState"] = %*{"arrivedSec": arrivedSec, "moveLines": pathRuns}
    discard g.exec("systemctl start repro-addon-evidence.timer")
    step("pre-181: a record written into the old outbox afterwards reaches the " &
         "sink through the path unit, the timer stopped",
         arrivedSec >= 0, $arrivedSec & " s; " &
           g.exec("systemctl status repro-addon-evidence.path --no-pager | head -5; ls -la " &
             LegacyOutbox).stdout)

suite Gate:
  test "a host an earlier engine bootstrapped is migrated by an operator's apply":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif standInArtefact().len == 0:
      skip("set REPRO_A11_STANDIN (pre-181 or pre-188) and REPRO_A11_STANDIN_ADDON " &
           "to a stand-in engine's add-on artefact")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
