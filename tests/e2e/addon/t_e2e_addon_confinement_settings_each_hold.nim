## Add-on VM gate: every confinement setting of the add-on's units holds on
## its own, and the gate can see it go (ReproOS Add-On Mode spec §10.1,
## CONF-4; threat model G55 and C75; the owner's decision of 2026-11-18).
##
## On each base, with the add-on bootstrapped with the deploy agent: for
## every unit in ``Units`` and every row of ``confinement_rows.ProbeRows``
## that applies to it (the unit sets the row's key; a root-only probe needs
## a root unit), the gate runs the behavioural probe
## (``fixtures/confinement_probe``) twice in a copy of the installed unit
## (``probeUnitCopy``: the unit's own ``[Service]`` lines but its command):
##
## - HELD: the other layers that would block the same probe disabled, the
##   setting as installed -- the probe must be blocked;
## - REMOVED: the setting removed too -- the probe must get through.
##
## A HELD that gets through is a setting that does not hold (a defect in the
## unit); a REMOVED that is still blocked is a probe that cannot see the
## setting (a defect in the row). Every pair is recorded, red then green,
## with each row that does not apply and why.
##
## Every unit sets every key the table tries but those
## ``confinement_rows.UnsetByDesign`` gives it a reason not to (A9 review
## round 21, M1): a unit that drops one fails here, whatever the unit.
## The copy is made from ``systemctl cat``, so a drop-in on the installed
## unit is copied with it, after the unit's own lines, as systemd reads it;
## the drop-ins found are recorded.
##
## Falsifying builds, red here: ``apply-unit-without-protect-system`` (the
## apply unit no longer sets ProtectSystem=) and ``fetch-unit-without-mdwe``
## (the fetch unit no longer sets MemoryDenyWriteExecute=).
##
## *The probe never ships.* It is compiled here, copied into the guest at
## ``ProbePath`` and run only by the copies, which this gate writes under
## ``/run/systemd/system`` and removes; no unit the add-on renders names it
## (``t_addon_confinement_probe_never_ships``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None: the add-on's installed unit files, the base's own systemd
## and kernel. The copies leave out each unit's command and ordering, which
## confine nothing; that is what lets every setting be tried without
## starting the add-on's own work.

import std/[json, os, osproc, sets, strutils, tables, tempfiles, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support
import ./confinement_rows
import ./evidence_e2e_support

const
  Gate = "e2e_addon_confinement_settings_each_hold"
  Units = ["repro-agent-apply.service", "repro-addon-reassert.service",
           "repro-addon-boot-confirm.service", "repro-addon-secrets.service",
           "repro-addon-store-verify.service", "repro-addon-boot-hold.service",
           "repro-agent-fetch.service", "repro-addon-evidence.service"]
  PrivilegedUnits = ["repro-agent-apply.service", "repro-addon-reassert.service",
           "repro-addon-boot-confirm.service", "repro-addon-secrets.service",
           "repro-addon-store-verify.service"]
    ## The units ``generation0.privilegedConfinement`` confines.

proc buildProbe(dest, debArch: string) =
  let src = reproRoot() / "tests" / "e2e" / "addon" / "fixtures" /
            "confinement_probe" / "a9_confinement_probe.c"
  let (o, c) = execCmdEx(quoteShellCommand([staticCc(debArch), "-static",
    "-O2", "-o", dest, src]))
  doAssert c == 0, "compiling the probe failed: " & o

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  let tmp = createTempDir("a9-confinement-", "")
  defer: removeDir(tmp)
  buildProbe(tmp / "probe", g.base.debArch)
  discard g.run("mkdir -p " & parentDir(ProbePath) & " /var/lib/a9probe " & ProbeOutDir)
  g.copyTo(tmp / "probe", ProbePath)
  discard g.run("chmod 0755 " & ProbePath & "; touch /root/a9probe-marker " &
                "/tmp/a9probe-marker; chmod 0644 /tmp/a9probe-marker")
  # The store-verify unit comes with the evidence units: enrol the host.
  var sink = startGateSink(g)
  defer: sink.stop()
  g.provideSinkCa(sink)
  let e = g.exec(repro & " system addon evidence-enrol --evidence-sink " &
    HostFromGuest & ":" & $sink.port & " --evidence-sink-ca " & GuestSinkCa &
    " --heartbeat-interval " & $GateHeartbeatSec, timeoutSec = 1800)
  step("the host is enrolled for evidence (the store-verify unit)", e.exitCode == 0,
       e.stdout & e.stderr)
  # A closed port of the guest's own address: the kernel refuses it at once
  # when nothing confines the probe.
  let gw = g.run("ip -4 -o addr show scope global | awk '{print $4; exit}' | cut -d/ -f1").strip()
  let disk = g.run("lsblk -dpno NAME,TYPE | awk '$2==\"disk\"{print $1; exit}'").strip()
  record["address"] = %gw
  record["disk"] = %disk
  step("the probe is installed and the guest's address and disk are known",
       gw.len > 0 and disk.len > 0 and
       g.exec("test -x " & ProbePath).exitCode == 0, gw & " " & disk)
  let amd64 = g.base.debArch == "amd64"
  # Every copy, written at once, then run one by one in the guest.
  let dir = tmp / "units"
  createDir(dir)
  var runs: seq[tuple[unit, row, phase, name: string]]
  let notRun = newJArray()
  var i = 0
  let dropIns = newJObject()
  for u in Units:
    # The unit as systemd loads it: its file, then each drop-in in order
    # (systemctl(1) "cat"); serviceLines drops the "# <path>" headers.
    let text = g.exec("systemctl cat --no-pager " & u).stdout
    if text.len == 0:
      step(u & " is installed", false, "no unit file")
      continue
    dropIns[u] = %g.run("systemctl show -p DropInPaths --value " & u).strip()
    let missing = missingSettings(u, text)
    step(u & " sets every setting the table tries but those it has a " &
         "reason not to", missing.len == 0, "does not set: " & missing.join(", "))
    for row in ProbeRows:
      let (ok, why) = rowApplies(row, text, amd64)
      if not ok:
        notRun.add(%*{"unit": u, "row": row.name, "why": why})
        continue
      let args = row.probe & (if row.arg.len > 0: " " & row.arg.replace("$IP", gw).replace("$DISK", disk) else: "")
      for (phase, extra) in [("held", row.held),
                             ("removed", row.held & removedLines(row, text))]:
        inc i
        let name = "a9p-" & $i & ".service"
        writeFile(dir / name, probeUnitCopy(text, args, ProbeOutDir / (name & ".out"), extra))
        runs.add((u, row.name, phase, name))
  record["notRun"] = notRun
  record["dropIns"] = dropIns
  let notObs = newJArray()
  for (k, why) in NotObservable: notObs.add(%*{"setting": k, "why": why})
  record["notObservable"] = notObs
  var unset = newJArray()
  for (u, k, why) in UnsetByDesign: unset.add(%*{"unit": u, "setting": k, "why": why})
  record["unsetByDesign"] = unset
  # The root units confined by ``privilegedConfinement`` set every setting
  # the table tries: a row that does not apply there is a setting the unit
  # lost (``apply-unit-without-protect-system``), not a row to skip.
  for n in notRun:
    let u = n["unit"].getStr()
    if u in PrivilegedUnits and not n["why"].getStr().contains("amd64") and
        not n["why"].getStr().startsWith("not observable") and
        not n["why"].getStr().startsWith("the probe is for a unit that runs unprivileged"):
      step(u & " sets " & n["row"].getStr() & "'s setting, as privilegedConfinement " &
           "renders it", false, n["why"].getStr())
  var list = ""
  for r in runs: list.add(r.name & "\n")
  writeFile(dir / "list", list)
  discard execCmdEx("tar -C " & quoteShell(dir) & " -cf " & quoteShell(tmp / "units.tar") & " .")
  g.copyTo(tmp / "units.tar", "/root/a9probe-units.tar")
  let res = g.run("set -e; mkdir -p /root/a9probe-units; tar -C /root/a9probe-units -xf /root/a9probe-units.tar; " &
    "cp /root/a9probe-units/a9p-*.service /run/systemd/system/; systemctl daemon-reload; " &
    "while read -r u; do systemctl start $u >/dev/null 2>&1 || true; " &
    "r=$(systemctl show -p Result --value $u); " &
    "s=$(systemctl show -p ExecMainStatus --value $u); " &
    "l=$(grep -h '^A9PROBE' " & ProbeOutDir & "/$u.out 2>/dev/null | tail -1); " &
    "echo \"$u|$r|$s|$l\"; done < /root/a9probe-units/list; " &
    "rm -f /run/systemd/system/a9p-*.service; systemctl daemon-reload; " &
    "systemctl reset-failed 'a9p-*' 2>/dev/null || true", timeoutSec = 3600)
  var got = initTable[string, tuple[result, status, line: string]]()
  for l in res.splitLines():
    let p = l.split('|')
    if p.len == 4: got[p[0]] = (p[1], p[2], p[3])
  # Pairs, in the table's order.
  let pairs = newJArray()
  var byKey = initTable[string, (Outcome, Outcome, string, string)]()
  for r in runs:
    let g0 = got.getOrDefault(r.name, ("", "", ""))
    let o = parseOutcome(g0.line, g0.result, g0.status)
    let k = r.unit & " " & r.row
    let shown = g0.line & " (" & g0.result & ", status " & g0.status & ")"
    var cur = byKey.getOrDefault(k)
    if r.phase == "held": cur[0] = o; cur[2] = shown
    else: cur[1] = o; cur[3] = shown
    byKey[k] = cur
  var rowsSeen = initHashSet[string]()
  for u in Units:
    for row in ProbeRows:
      let k = u & " " & row.name
      if k notin byKey: continue
      rowsSeen.incl(row.name)
      let (h, rm, hs, rs) = byKey[k]
      let hok = heldOk(row.expect, h)
      let rok = removedOk(row.expect, rm)
      pairs.add(%*{"unit": u, "row": row.name, "setting": row.setting,
        "held": hs, "removed": rs, "heldBlocks": hok, "removedGetsThrough": rok})
      step(u & ": " & row.setting & " (" & row.name & ") holds on its own, and " &
           "removing it lets the probe through", hok and rok,
           "held: " & hs & "; removed: " & rs)
  record["pairs"] = pairs
  # Every row ran somewhere: a row that applies to no unit tests nothing.
  for row in ProbeRows:
    if row.amd64Only and not amd64: continue
    step("the row " & row.name & " ran in at least one unit", row.name in rowsSeen, "")

suite Gate:
  test "each confinement setting of the add-on's units holds on its own":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      check gateMain(Gate, body).len == 0
