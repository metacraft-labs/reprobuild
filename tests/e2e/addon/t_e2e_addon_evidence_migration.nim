## Add-on VM gate: a host an engine before §13 decision 181 bootstrapped is
## migrated by an operator's apply with this engine (ReproOS Add-On Mode
## spec §13 decisions 181 and 188, as amended by the owner's decision of
## 2026-11-26, "migrate existing hosts"; A11 round 26, Medium 2).
##
## On each base:
##
## 1. the PREVIOUS engine (``REPRO_A11_PRE_G56_ADDON``, a static add-on
##    artefact built at reprobuild ``64bda75f1f``, the commit before decision
##    181 landed) bootstraps the add-on with the deploy agent and a sink;
##    its shipping unit runs as root and its outbox and receipt are in the
##    root paths of that time;
## 2. the sink refuses the host (its anchor revoked), and two applies by the
##    previous engine queue records in that outbox;
## 3. this engine's plan names the shipping and egress check units, and its
##    operator apply is not refused; afterwards the egress check holds
##    ``CAP_NET_ADMIN`` alone and the shipping unit runs as its dynamic user,
##    both on this engine;
## 4. the shipping unit's harvest moves the queued records and the receipt
##    into the dynamic user's state directory (the sink still refusing, so
##    the receipt read there is the one carried over); the apt hook cursor
##    stays where it was;
## 5. the sink accepts the host again, and every record queued in step 2
##    reaches it exactly once.
##
## Falsifying builds, red here: ``migration-skips-ship-identity`` (the
## shipping unit stays root, step 3), ``migration-skips-egress-check`` (the
## egress check keeps ``CAP_DAC_OVERRIDE``, step 3).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_A11_PRE_G56_ADDON``.
##
## *Mocking.* None: the real add-on of two engines, the real sink, the
## base's own systemd.

import std/[json, os, sequtils, strutils, unittest]

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

proc installPrevious(g: Guest; dir = "/root/addon-prev"): tuple[repro, sha: string] =
  ## The previous engine's artefact, verified in the guest against its
  ## published digest before it runs, as ``installArtefact`` does.
  let root = getEnv("REPRO_A11_PRE_G56_ADDON")
  if root.len == 0:
    raise newException(TestBedError, "REPRO_A11_PRE_G56_ADDON must name the " &
      "pre-decision-181 engine's add-on artefact directory")
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

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let (prev, prevSha) = g.installPrevious()
  record["previousArtefactSha256"] = %prevSha
  # 1. The previous engine bootstraps with the agent and the sink.
  let bs = g.bootstrapShipping(prev, step, producer)
  var sink = bs.sink
  defer: sink.stop()
  if not bs.ok: return
  let before = g.exec("systemctl show -p DynamicUser -p User --value " &
    "repro-addon-evidence.service; grep -h CapabilityBoundingSet " &
    "/etc/systemd/system/repro-addon-egress-check.service; true").stdout
  record["unitsBefore"] = %before
  let oldShipExe = g.exec("sed -n 's/^ExecStart=\\(.*\\) system addon evidence-ship$/\\1/p' " &
    "/etc/systemd/system/repro-addon-evidence.service").stdout.strip()
  record["previousShipExe"] = %oldShipExe
  step("the previous engine's shipping unit is root, its outbox the root one",
       "DynamicUser=yes" notin g.exec("cat /etc/systemd/system/" &
         "repro-addon-evidence.service").stdout and
       g.exec("test -d " & LegacyOutbox).exitCode == 0, before)
  # 2. The sink refuses the host; two applies queue records.
  sink.revoke(bs.host)
  for i in 1 .. 2:
    let r = g.applyProfile(prev, "p" & $i, marker(i))
    step("the previous engine's apply " & $i & " passes", r.exitCode == 0,
         r.stdout & r.stderr)
  discard g.exec("systemctl start repro-addon-evidence.service")
  let queued = g.exec("cd " & LegacyOutbox & " && ls -1 *.evr 2>/dev/null; true").stdout.
    splitLines().filterIt(it.strip().len > 0)
  record["queuedLegacy"] = %queued
  step("records are queued in the root outbox while the sink refuses the host",
       queued.len >= 2, $queued)
  let snap = g.runDir / "legacy-outbox"
  createDir(snap)
  var queuedBytes: seq[string]
  for n in queued:
    g.copyFrom(LegacyOutbox & "/" & n, snap / n)
    queuedBytes.add(readFile(snap / n))
  let receipt = g.exec("cat " & LegacyState & "/receipt 2>/dev/null; true").stdout
  let cursor = g.exec("sha256sum " & LegacyState & "/apt-hook.cursor 2>/dev/null; true").stdout
  record["legacyReceipt"] = %receipt
  step("the previous engine kept the sink's receipt in the root state",
       receipt.strip().len > 0, receipt)
  # 3. This engine's plan and operator apply.
  let plan = g.planProfile(repro, "u1", marker(3))
  record["plan"] = %(plan.stdout & plan.stderr)
  step("this engine's plan lists the shipping and egress check units as migrated",
       plan.exitCode == 0 and "generation 0 migrated by this engine" in plan.stdout and
         "  repro-addon-evidence.service\n" in plan.stdout and
         "  repro-addon-egress-check.service\n" in plan.stdout,
       plan.stdout & plan.stderr)
  let r = g.applyProfile(repro, "u1", marker(3))
  step("this engine's operator apply passes (the migration is not refused)",
       r.exitCode == 0, r.stdout & r.stderr)
  let caps = g.exec("systemctl show -p CapabilityBoundingSet --value " &
                    "repro-addon-egress-check.service").stdout.strip()
  step("the egress check holds CAP_NET_ADMIN alone", caps == "cap_net_admin",
       caps & "\n" & g.exec("cat /etc/systemd/system/" &
         "repro-addon-egress-check.service").stdout)
  let id = g.exec("systemctl show -p DynamicUser -p User " &
                  "repro-addon-evidence.service").stdout
  let shipUnit = g.exec("cat /etc/systemd/system/repro-addon-evidence.service").stdout
  let newExe = g.exec("readlink -f " & repro).stdout.strip()
  step("the shipping unit runs as its dynamic user, on this engine",
       "DynamicUser=yes" in id and "User=repro-addon-evidence" in id and
         "evidence-harvest" in shipUnit and oldShipExe.len > 0 and
         oldShipExe notin shipUnit,
       id & "\n" & shipUnit & "\n" & newExe)
  # 4. The harvest moves the state, the sink still refusing.
  discard g.exec("systemctl start repro-addon-evidence.service")
  let moved = g.exec("ls -1 " & ShipState & "/outbox; echo ---; " &
    "test -e " & LegacyOutbox & " && echo legacy-outbox-present; " &
    "cat " & ShipState & "/receipt; echo ---; stat -c '%u' " & ShipState &
    "; cat " & ShipState & "/harvest/legacy-left; true").stdout
  record["afterMove"] = %moved
  var allMoved = true
  for n in queued:
    if n notin moved: allMoved = false
  step("the harvest moved every queued record into the dynamic user's outbox",
       allMoved and "legacy-outbox-present" notin moved, moved)
  let newReceipt = g.exec("cat " & ShipState & "/receipt 2>/dev/null; true").stdout
  step("the receipt was carried over, and the cursor left in place",
       newReceipt == receipt and
         g.exec("test -e " & LegacyState & "/receipt").exitCode != 0 and
         g.exec("sha256sum " & LegacyState & "/apt-hook.cursor 2>/dev/null; true").stdout == cursor,
       newReceipt & " / " & receipt)
  let owner = g.exec("stat -c '%u' " & ShipState).stdout.strip()
  step("the shipping state directory is not root's", owner.len > 0 and owner != "0",
       owner)
  # 5. The sink accepts the host again: each queued record once.
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

suite Gate:
  test "a host bootstrapped before decision 181 is migrated by an operator's apply":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif getEnv("REPRO_A11_PRE_G56_ADDON").len == 0:
      skip("set REPRO_A11_PRE_G56_ADDON to the pre-decision-181 engine's add-on artefact")
    else:
      check gateMain(Gate, body, bootstrap = false).len == 0
