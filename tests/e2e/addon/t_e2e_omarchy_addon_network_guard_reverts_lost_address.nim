## Gate ``e2e_omarchy_addon_network_guard_reverts_lost_address`` (milestone
## AR5, the MS-2 run; spec ReproOS-Add-On-Mode §4.5 steps 1-4 and the
## state table, §5.3, §6.4, §7.2 step 9, §7.7; §13 decisions 86, 87,
## 102-110, 116-129; threat model G47, G48, T54, T56, T59, T62).
##
## **The MS-2 run** (§13 decision 86). The gate's own test program -- the
## seam build, never the published binary -- hands the switch a generation
## whose ``repro-`` connection binds the parent (the planner refuses such a
## connection; the seam replaces the rendered keyfile below the planner).
## The parent loses its DHCP address. With no operator action the host is
## back at the previous generation within ``networkGuard.timeout`` plus the
## revert time: the parent's address and default route are back, the
## injected connection is gone, and ``rolled-back`` is recorded with
## ``EAddOnNetworkGuard``. The same run with the apply killed right after
## the switch reverts by the timer, and so does a hard reset of the guest
## while the guard is armed (recovery at boot reverts without replaying;
## ``current`` never named the bad generation). A second run, with a
## correct generation, has the harness pull the parent's cable from
## outside the guest (QMP ``set_link``, not the guest's network): the guard
## reverts the add-on's objects, the record names the missing ``keep``
## address, and the address stays lost (§4.5 "What a revert restores");
## the gate asserts that, plugs the cable back, and only then compares.
##
## **The guard's states**: negative controls (a)-(cc) of the milestone,
## each named by its letter in the record, and (dd): an SSH session while
## the switch is paused before its network writes is not evidence, and the
## timer reverts (spec §4.5 step 3, amended 2026-11-22). After every control that ends
## in a revert, the attempt's root snapshot is gone and the fingerprint and
## the host's links, addresses and routes equal the previous generation's
## (§13 decision 105). The record states the successor's re-arm interval as
## measured in controls (e) and (i) (§13 decision 109).
##
## Falsifying mutations: ``guard-skips-arm`` (no transient revert unit:
## the killed-apply MS-2 run leaves the parent without its address at the
## timeout) and ``recovery-replays-armed`` (recovery replays an ``armed``
## marker: the hard-reset MS-2 run re-applies the bad generation).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just
## e2e_omarchy_addon_network_guard_reverts_lost_address``; the seam build).
##
## *Mocking.* None: the real Omarchy VM, NetworkManager, systemd timers,
## snapper and the seam build of the static add-on binary. The only
## stand-in is the injected keyfile, which is the gate's purpose.

import std/[algorithm, json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./network_gate_support

const
  Gate = "e2e_omarchy_addon_network_guard_reverts_lost_address"
  Timeout = 30
  Ctl = StateDir & "/addon"

type Bed = ref object
  nb: NetBed
  repro, account: string
  profileG, link, twoLinks: string     ## the previous generation; attempts
  fA, nA: string                       ## its fingerprint and network
  snapsA: seq[int]                     ## its add-on snapshots
  rbA: int                             ## guard rollbacks so far
  rbSeen: seq[string]                  ## their records
  record: JsonNode
  step: StepFn
  n: int

proc g(b: Bed): Guest = b.nb.om
proc mux(b: Bed; s: string; t = 600): ExecOut = b.nb.muxExec(s, t)

proc pause(b: Bed; point: string; synced = false) =
  ## Ask the next process that reaches ``point`` to pause there. Every
  ## paused-at and resume file a killed process left behind goes first, so
  ## ``waitPaused`` sees only the new pause.
  discard b.mux("rm -f " & Ctl & "/test-paused-at* " & Ctl & "/test-resume*; " &
                "printf '%s\\n' " & point & " > " & Ctl & "/test-pause-at" &
                (if synced: "; sync" else: ""))

proc waitPaused(b: Bed; point: string; timeoutSec = 600): bool =
  b.mux("for i in $(seq 1 " & $timeoutSec & "); do test -e " & Ctl &
        "/test-paused-at-" & point & " && exit 0; sleep 1; done; exit 1",
        timeoutSec + 30).exitCode == 0

proc resume(b: Bed; point: string) =
  discard b.mux("touch " & Ctl & "/test-resume-" & point)

proc attempt(b: Bed): string = b.nb.markerField("guard-attempt")

proc guardJournal(b: Bed; att: string): string =
  b.mux("journalctl --no-pager -o short-unix -u 'repro-addon-guard-" & att &
        "-*'").stdout

proc start(b: Bed; text: string): string =
  inc b.n
  b.nb.startApply(b.repro, "a" & $b.n, text)

proc runDetached(b: Bed; name, cmd: string): string =
  ## A root command in a transient unit, its output in /root/<name>.log.
  discard b.mux("systemd-run --quiet --collect --unit=" & name &
    " --property=StandardOutput=file:/root/" & name & ".log " &
    "--property=StandardError=file:/root/" & name & ".log " & cmd)
  name

proc waitArmed(b: Bed): bool =
  b.nb.waitMarkerGuard(["armed"], 600) == "armed"

proc waitNoMarker(b: Bed; timeoutSec: int): bool =
  b.mux("for i in $(seq 1 " & $timeoutSec & "); do test -e " & MarkerPath &
        " || exit 0; sleep 1; done; exit 1", timeoutSec + 30).exitCode == 0

proc snapshotA(b: Bed) =
  ## The previous generation as it is now: what every revert must return to.
  b.g.settleBaseline(b.step)
  b.fA = b.g.fingerprintArch(b.repro, b.account)
  b.nA = b.nb.netState()
  b.snapsA = numbersOf(b.g.addonRows())
  b.rbSeen = b.nb.guardRollbacks()
  b.rbA = b.rbSeen.len

proc reverted(b: Bed; c, reasonHas: string; undo: proc() = nil) =
  ## The checks after every control that ends in a revert.
  let rb = b.nb.guardRollbacks()
  # The new record, by set difference (the logs' order is not the records').
  var fresh: seq[string]
  for r in rb:
    if r notin b.rbSeen: fresh.add(r)
  b.step("(" & c & ") recorded rolled-back with EAddOnNetworkGuard" &
         (if reasonHas.len > 0: " (" & reasonHas & ")" else: ""),
         rb.len == b.rbA + 1 and fresh.len == 1 and
         (reasonHas.len == 0 or reasonHas in fresh[0]),
         "new: " & fresh.join("\n") & "\nall:\n" & rb.join("\n"))
  # The actor finishing the revert may still be at it (its last steps take
  # longer on a loaded host: a check made at once found the marker at
  # `9-commit`, measured 2026-11-24): wait for the marker, bounded, before
  # the checks below.
  discard b.waitNoMarker(300)
  # The actor that completes a revert stops the attempt's timers last,
  # after the marker is gone: a moment later.
  discard b.mux("for i in $(seq 1 30); do systemctl list-units --all --plain " &
    "--no-legend 'repro-addon-guard-*' | grep -q . || exit 0; sleep 1; done", 60)
  b.step("(" & c & ") the marker is gone and no guard unit is left",
         b.mux("test -e " & MarkerPath).exitCode != 0 and
         b.nb.guardUnits().len == 0, b.nb.guardUnits() &
         b.mux("cat " & MarkerPath & " 2>/dev/null").stdout)
  if undo != nil: undo()
  b.step("(" & c & ") the attempt's root snapshot is gone",
         numbersOf(b.g.addonRows()) == b.snapsA, b.g.run("snapper -c root list"))
  let n = b.nb.netState()
  b.step("(" & c & ") links, addresses and routes equal the previous " &
         "generation's", n == b.nA, b.nA & "\n=>\n" & n)
  let f = b.g.fingerprintArch(b.repro, b.account)
  let id = identityReport(b.fA, f, @RebootVariance)
  b.step("(" & c & ") the fingerprint equals the previous generation's",
         id.ok, id.text)
  b.rbA = rb.len
  b.rbSeen = rb

proc killedOwner(b: Bed; unit: string) =
  b.nb.killApply(unit)
  discard b.mux("rm -f " & Ctl & "/test-paused-at*")
  discard b.mux("for i in $(seq 1 30); do systemctl is-active --quiet " &
                unit & ".service || exit 0; sleep 1; done")

proc rebootGuest(b: Bed; hard = false) =
  b.nb.stopMux()
  if hard:
    b.g.hardReset()
  else:
    discard b.g.exec(RebootCommand, timeoutSec = 30)
    discard b.g.waitPoweredOff(300)
  b.g.boot()
  discard b.g.waitReasserted()
  b.nb.startMux()

proc reassertReport(b: Bed): string =
  b.mux("cat " & Ctl & "/reassert-report 2>/dev/null; journalctl -b -o cat " &
        "--no-pager -u repro-addon-reassert.service").stdout

proc successorInterval(journal: string): float =
  ## The median gap between "armed the successor" lines (seconds).
  var ts: seq[float]
  for l in journal.splitLines():
    if "armed the successor" in l:
      try: ts.add(parseFloat(l.splitWhitespace()[0]))
      except ValueError: discard
  var gaps: seq[float]
  for i in 1 ..< ts.len: gaps.add(ts[i] - ts[i - 1])
  if gaps.len == 0: return -1
  gaps.sort()
  gaps[gaps.len div 2]

proc badKeyfile(parent: string): string =
  "[connection]\nid=repro-" & LinkName & "\nuuid=0b8c7c4e-0000-4000-8000-" &
    "0000000000bb\ntype=ethernet\ninterface-name=" & parent &
    "\nautoconnect=true\n\n[ipv4]\nmethod=manual\naddress1=10.9.9.9/24\n\n" &
    "[ipv6]\nmethod=disabled\n"

proc runBase(base: BaseImage; record: JsonNode): seq[string] =
  var nb: NetBed
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(base.name & ": " & name & ": " & detail)
  try:
    nb = newNetBed()
    nb.bootNetBed(step)
    let g = nb.om
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let account = accountFor(base)
    # The baseline after a reboot of its own, so the first boot's one-shot
    # units are behind it, as they are behind every later boot (as the
    # root-snapshot gate does).
    discard g.exec(RebootCommand, timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    discard g.exec("for i in $(seq 1 90); do ip -4 -o addr show dev " &
      nb.parent & " | grep -q " & LanNet & ". && exit 0; sleep 2; done", 240)
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(base)).ok: return fails
    let b = Bed(nb: nb, repro: repro, account: account, record: record,
                step: step)
    nb.startMux()
    # The previous generation: the guard stanza and a fixture file, with
    # the add-on's own root snapshot; no network object.
    let gs = guardStanza(account, Timeout, oob = nb.oob,
                         setting = "required").replace("PARENT", nb.parent)
    b.profileG = gs & fixtureFile("generation = A\n")
    b.link = gs & fixtureFile("generation = A\n") & linkStanza(nb.parentMac)
    b.twoLinks = b.link & linkStanza(nb.parentMac, name = LinkName & "2",
      address = LanNet & ".22/24", dns = false)
    let ga = g.applyProfile(repro, "gA", b.profileG)
    step("the previous generation (no network object) applies", ga.exitCode == 0,
         ga.stdout & ga.stderr)
    let genA = currentGeneration(g)
    b.snapshotA()
    # ---- MS-2: the injected connection binds the parent.
    discard b.mux("printf '%s\\n%s' " & LinkName & " " &
                  quoteShell(badKeyfile(nb.parent)) & " > " & Ctl &
                  "/test-network-inject")
    block:
      let t0 = epochTime()
      let unit = b.start(b.link)
      let armed = b.waitArmed()
      let lost = b.mux("for i in $(seq 1 120); do ip -4 -o addr show dev " &
        nb.parent & " | grep -q " & LanNet & ". || exit 0; sleep 1; done; exit 1").exitCode == 0
      step("MS-2: the injected connection takes the parent's DHCP address",
           armed and lost, b.mux("ip -br addr; nmcli -t c show --active").stdout)
      let back = b.nb.waitApplyDone(unit, Timeout + 600) and b.waitNoMarker(60)
      let el = epochTime() - t0
      record["ms2RevertSeconds"] = %el
      step("MS-2: with no operator action the host is back within the " &
           "timeout plus the revert time", back and nb.parentHolds() and
           el < float(Timeout + 600), $el & " s\n" & b.nb.applyLog(unit))
      step("MS-2: the injected connection is gone",
           b.mux("ls /etc/NetworkManager/system-connections/repro-* " &
                 "2>/dev/null").stdout.strip().len == 0, "")
      step("MS-2: current never named the bad generation",
           currentGeneration(g) != "" and b.nb.markerField("attempt") == "", "")
      b.reverted("MS-2", "")
    # A falsifier run stops after the control its mutation is for: every
    # later control rests on the timers or the recovery it breaks.
    let mut = mutation()
    # MS-2 with the apply killed right after the switch: the timer reverts.
    if mut != "recovery-replays-armed":
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      step("MS-2 (killed): the switch reaches its watch", b.waitPaused("step-8"), "")
      let att = b.attempt()
      b.killedOwner(unit)
      # (c): recovery with the timer pending defers and changes nothing.
      # (Not in the guard-skips-arm run: with no timer loaded, recovery
      # would revert by itself, and the run asks what the timer does.)
      if mut != "guard-skips-arm":
        let mBefore = b.mux("cat " & MarkerPath).stdout
        let rec = b.mux(repro & " system addon recover").stdout
        step("(c) recover while armed with the timer pending reports it and " &
             "changes nothing", "timer is the actor" in rec and
             b.mux("cat " & MarkerPath).stdout == mBefore, rec)
      let back = b.waitNoMarker(Timeout + 300)
      step("(a)/MS-2 (killed): the timer reverts the bad generation",
           back and nb.parentHolds(), b.guardJournal(att))
      b.reverted("a", GuardTimerReason)
    if mut == "guard-skips-arm": return fails
    # MS-2 with a hard reset while armed: recovery at boot reverts.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      discard unit
      b.rebootGuest(hard = true)
      let rep = b.reassertReport()
      step("MS-2 (reset): recovery at boot reverts without replaying",
           "reverted the network switch" in rep and ArmedAcrossRebootReason in rep and
           nb.parentHolds() and currentGeneration(g) != "", rep)
      b.reverted("MS-2 reset", ArmedAcrossRebootReason)
    if mut == "recovery-replays-armed": return fails
    discard b.mux("rm -f " & Ctl & "/test-network-inject")
    # ---- The outside break: a correct generation, the cable pulled.
    block:
      let seenBefore = b.nb.guardRollbacks()
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.mux("for i in $(seq 1 120); do ip link show " & LinkName &
                    " >/dev/null 2>&1 && exit 0; sleep 1; done")
      nb.om.setLink("lan0", false)
      let done = b.nb.waitApplyDone(unit, Timeout + 600)
      let rb = b.nb.guardRollbacks()
      var freshOb: seq[string]
      for r in rb:
        if r notin seenBefore: freshOb.add(r)
      step("outside break: the guard reverts, naming the missing keep address",
           done and freshOb.len == 1 and ("keep: " & nb.parent) in freshOb[0],
           rb.join("\n"))
      step("outside break: the address stays lost (the add-on owns no " &
           "parent setting)", not nb.parentHolds(), b.nb.netState())
      nb.om.setLink("lan0", true)
      discard b.mux("for i in $(seq 1 90); do ip -4 -o addr show dev " &
        nb.parent & " | grep -q " & LanNet & ". && ip -4 route show default |" &
        " grep -q " & HelperLanAddr & " && exit 0; sleep 2; done")
      # This revert is counted by `reverted` below, against the records
      # before it.
      b.rbSeen = seenBefore
      b.rbA = seenBefore.len
      b.reverted("outside break", "keep: " & nb.parent)
    # ---- (b): the timer fires while the apply watches.
    block:
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.nb.waitApplyDone(unit, Timeout + 600)
      step("(b) the timer fires while the apply watches; the apply completes " &
           "the revert", "rolled back" in b.nb.applyLog(unit), b.nb.applyLog(unit))
      b.reverted("b", GuardTimerReason)
    # ---- (dd): a session before the network writes is no evidence.
    block:
      b.pause("step-3")
      let unit = b.start(b.link)
      discard b.waitArmed()
      let paused = b.waitPaused("step-3")
      let early = nb.freshSsh("true", afterWrites = false)
      let noWrites = b.mux("grep -c '^guard-written-mono' " & MarkerPath &
                           "; ls /etc/NetworkManager/system-connections/repro-" &
                           LinkName & ".nmconnection 2>&1").stdout
      step("(dd) a new SSH session while the switch is paused before its " &
           "network writes", paused and early.exitCode == 0 and
           noWrites.startsWith("0") and "No such file" in noWrites, noWrites)
      b.resume("step-3")
      discard b.nb.waitApplyDone(unit, Timeout + 600)
      let log = b.nb.applyLog(unit)
      step("(dd) it does not disarm: the timer reverts", "disarmed by" notin log and
           "rolled back" in log, log)
      b.reverted("dd", GuardTimerReason)
    # ---- (d): killed after disarmed, before the timer is stopped.
    var committedAttempt = ""
    block:
      b.pause("guard-after-disarm")
      let unit = b.start(b.link)
      discard b.waitArmed()
      let att = b.attempt()
      committedAttempt = att
      discard nb.freshSsh("true")
      step("(d) the owner disarms", b.waitPaused("guard-after-disarm"), "")
      b.killedOwner(unit)
      # The original timer fires: it arms a successor, finds `disarmed`,
      # stops the successor and exits.
      discard b.mux("sleep " & $(Timeout + 15), Timeout + 60)
      let j = b.guardJournal(att)
      step("(d) the timer finds disarmed, stops its successor and changes " &
           "nothing", "is disarmed; stopped the successor" in j and
           b.nb.markerField("guard") == "disarmed", j)
      let rec = b.mux(repro & " system addon recover").stdout
      step("(d) recovery commits without a replay or a re-confirmation",
           "committed the disarmed network generation" in rec and
           "replayed" notin rec and b.mux("test -e " & MarkerPath).exitCode != 0 and
           b.mux("ip link show " & LinkName).exitCode == 0 and
           b.nb.guardUnits().len == 0, rec)
      # Back to the previous generation's network for the next control.
      let u2 = b.start(b.profileG)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.nb.waitApplyDone(u2, Timeout + 600)
      b.snapshotA()
    # ---- (e): the store unreadable when the timer fires.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      b.nb.hideStore()
      let gone = b.mux("for i in $(seq 1 " & $(Timeout + 60) & "); do " &
        "ip link show " & LinkName & " >/dev/null 2>&1 || exit 0; sleep 1; " &
        "done; exit 1", Timeout + 90).exitCode == 0
      discard b.mux("sleep 35", 60)
      let j = b.guardJournal(att)
      let iv = successorInterval(j)
      record["successorIntervalE"] = %iv
      step("(e) with the store unreadable the network objects come back, the " &
           "marker stays fired and the successor re-arms every 10 s",
           gone and b.nb.markerField("guard") == "fired" and iv >= 9 and iv <= 15,
           $iv & "\n" & j)
      b.nb.showStore()
      let back = b.waitNoMarker(120)
      step("(e) once the store is back the revert completes", back,
           b.guardJournal(att))
      b.reverted("e", GuardTimerReason)
    # ---- (f): the timer fires mid-switch, between two network objects.
    block:
      b.pause("network-between-objects")
      let unit = b.start(b.twoLinks)
      discard b.waitArmed()
      discard b.waitPaused("network-between-objects")
      discard b.mux("for i in $(seq 1 " & $(Timeout + 60) & "); do grep -q " &
        "'^guard\tfired' " & MarkerPath & " && exit 0; sleep 1; done", Timeout + 90)
      b.resume("network-between-objects")
      discard b.nb.waitApplyDone(unit, 600)
      let log = b.nb.applyLog(unit)
      step("(f) the switch writes no further network object once fired",
           "no further network object was written" in log and
           b.mux("ls /etc/NetworkManager/system-connections/repro-" & LinkName &
                 "2.nmconnection").exitCode != 0, log)
      b.reverted("f", GuardTimerReason)
    # ---- (g): a failing step, and a failing confirmation.
    for (kind, setup, teardown, text) in [
        ("a failed step", "touch " & Ctl & "/test-network-step-fails",
         "rm -f " & Ctl & "/test-network-step-fails", b.link),
        ("a failed confirmation", "true", "true",
         b.link.replace("  networkGuard", "  confirmTimeout = 5\n  networkGuard") &
           fixtureUnit(gen0ReproExe(g)).replace("  enabled = true",
             "  enabled = true\n  healthCheck = \"tcp:127.0.0.1:1\""))]:
      discard b.mux(setup)
      b.pause("revert:step-1")
      let unit = b.start(text)
      discard b.waitArmed()
      let att = b.attempt()
      let p = b.waitPaused("revert:step-1")
      let m = b.mux("cat " & MarkerPath).stdout
      let loaded = b.mux("systemctl list-units --plain --no-legend " &
        "'repro-addon-guard-" & att & "-*.timer' | grep -c ' active '").stdout.strip()
      step("(g) " & kind & ": the marker shows reverting and the timer is " &
           "still loaded during the revert", p and "guard\treverting" in m and
           loaded != "0", m & "\n" & loaded)
      b.resume("revert:step-1")
      discard b.nb.waitApplyDone(unit, 600)
      discard b.mux(teardown)
      b.reverted("g " & kind, "")
    # ---- (h): a stale timer of an attempt whose marker was never written.
    block:
      b.pause("guard-after-arm")
      let unit = b.start(b.link)
      step("(h) the apply has armed its timer and not yet written its marker",
           b.waitPaused("guard-after-arm") and
           b.mux("test -e " & MarkerPath).exitCode != 0, "")
      let units = b.nb.guardUnits()
      b.killedOwner(unit)
      discard b.mux("sleep " & $(Timeout + 20), Timeout + 60)
      step("(h) the stale timer fires, stops its successor and changes nothing",
           "no pending marker names attempt" in b.mux("journalctl --no-pager " &
             "-o cat -u 'repro-addon-guard-*' --since '-2min'").stdout and
           b.nb.guardUnits().len == 0, units)
      let orphan = numbersOf(g.addonRows()).len > b.snapsA.len
      let rec = b.mux(repro & " system addon recover").stdout
      step("(h) the attempt's snapshot is an orphan, and recovery's sweep " &
           "deletes it", orphan and numbersOf(g.addonRows()) == b.snapsA, rec)
      discard b.mux("rm -f " & Ctl & "/pending.d/* 2>/dev/null; true")
      let n = b.nb.netState()
      let id = identityReport(b.fA, g.fingerprintArch(repro, account),
                              @[SnapperdActivation])
      step("(h) the fingerprint is unchanged", id.ok and n == b.nA, id.text)
      # Second run: the reboot's recovery sweeps it.
      b.pause("guard-after-arm")
      let unit2 = b.start(b.link)
      discard b.waitPaused("guard-after-arm")
      b.killedOwner(unit2)
      b.rebootGuest()
      step("(h) after a reboot the re-assert unit's recovery sweeps the orphan",
           numbersOf(g.addonRows()) == b.snapsA, b.reassertReport())
      b.snapshotA()
    # ---- (h') a stale timer still loaded after its attempt committed:
    # the attempt (d) committed, armed again as the guard arms its own
    # (network_guard.armGuardTimer).
    block:
      let att = committedAttempt
      discard b.mux("systemd-run --quiet --collect --unit=repro-addon-guard-" &
        att & "-stale --on-active=3s --timer-property=AccuracySec=1s " &
        "--timer-property=RemainAfterElapse=no --property=Type=oneshot " &
        "-- /var/lib/repro/bin/repro system addon revert-network " & genA &
        " --attempt " & att & " --state-dir " & StateDir)
      discard b.mux("sleep 25", 60)
      let n = b.nb.netState()
      # Its own journal only: (d)'s timers of the same attempt logged too.
      let j = b.mux("journalctl --no-pager -o short-unix -u " &
        "repro-addon-guard-" & att & "-stale.service").stdout
      step("(h) a stale timer of a committed attempt arms and stops a " &
           "successor and changes nothing", att.len == 32 and
           b.nb.guardUnits().len == 0 and n == b.nA and
           "armed the successor" in j and
           ("no pending marker names attempt " & att) in j,
           j & "\nunits: " & b.nb.guardUnits())
    # ---- (i): revert-network killed mid-revert; the reverting apply killed.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      b.pause("revert-network-mid-revert")
      step("(i) revert-network pauses mid-revert",
           b.waitPaused("revert-network-mid-revert", Timeout + 120), "")
      let firing = b.mux("systemctl list-units --plain --no-legend " &
        "'repro-addon-guard-" & att & "-*.service' | awk '/ active /{print $1}'").stdout.strip()
      discard b.mux("systemctl kill --signal=SIGKILL " & firing)
      discard b.mux("rm -f " & Ctl & "/test-paused-at*")
      let back = b.waitNoMarker(120)
      let iv = successorInterval(b.guardJournal(att))
      record["successorIntervalI"] = %iv
      step("(i) the successor finishes the revert in the same boot", back,
           b.guardJournal(att))
      b.reverted("i revert-network", GuardTimerReason)
      # The reverting apply killed mid-revert.
      discard b.mux("touch " & Ctl & "/test-network-step-fails")
      b.pause("revert:step-4")
      let u2 = b.start(b.link)
      discard b.waitArmed()
      let att2 = b.attempt()
      discard b.waitPaused("revert:step-4")
      b.killedOwner(u2)
      discard b.mux("rm -f " & Ctl & "/test-network-step-fails " & Ctl &
                    "/test-paused-at*")
      let back2 = b.waitNoMarker(Timeout + 180)
      step("(i) with the reverting apply killed, the attempt's timer finishes " &
           "the revert in the same boot", back2, b.guardJournal(att2))
      b.reverted("i apply", "")
    # ---- (j): the guard lock, and a root process holding it.
    block:
      let st = b.mux("stat -c '%U %a' /run/repro-addon-guard.lock").stdout.strip()
      let unpriv = b.mux("runuser -u " & account & " -- flock -n " &
                         "/run/repro-addon-guard.lock true").exitCode
      step("(j) the guard lock is root 0600 and an unprivileged flock cannot " &
           "open it", st == "root 600" and unpriv != 0, st)
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      discard b.runDetached("gate-lockholder", "flock /run/repro-addon-guard.lock " &
                            "sleep " & $(Timeout + 30))
      let back = b.waitNoMarker(Timeout + 240)
      let j = b.guardJournal(att)
      var successors = 0
      for l in j.splitLines():
        if "armed the successor" in l: inc successors
      step("(j) a root holder delays the revert; successors queue every 10 s " &
           "and the revert completes once it releases", back and successors >= 3,
           j)
      b.reverted("j", GuardTimerReason)
    # ---- (k), (n), (w), (r): the timer gone.
    block:
      # (k) recover, owner dead, its timer stopped by hand.
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      discard b.mux("systemctl stop 'repro-addon-guard-" & att & "-*'")
      let rec = b.mux(repro & " system addon recover").stdout
      step("(k) recover arms a fresh timer, writes reverting (armed, its " &
           "timer gone) and reverts", "armed a fresh guard timer" in rec and
           "reverted the network switch" in rec, rec)
      b.reverted("k", TimerGoneReason)
      # (n) the owner watching, its timer stopped by hand.
      let u2 = b.start(b.link)
      discard b.waitArmed()
      let att2 = b.attempt()
      discard b.mux("sleep 3; systemctl stop 'repro-addon-guard-" & att2 & "-*'")
      discard b.nb.waitApplyDone(u2, Timeout + 300)
      step("(n) at the deadline the owner reverts itself (armed, its timer " &
           "gone)", TimerGoneReason in b.nb.applyLog(u2), b.nb.applyLog(u2))
      b.reverted("n", TimerGoneReason)
      # (r) = (k)+(i): recovery killed mid-revert; its fresh timer finishes.
      b.pause("step-8")
      let u3 = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att3 = b.attempt()
      b.killedOwner(u3)
      discard b.mux("systemctl stop 'repro-addon-guard-" & att3 & "-*'")
      b.pause("revert:step-4")
      discard b.runDetached("gate-recover", repro & " system addon recover")
      discard b.waitPaused("revert:step-4")
      discard b.mux("systemctl kill --signal=SIGKILL gate-recover.service; rm -f " &
                    Ctl & "/test-paused-at*")
      step("(r) recovery killed mid-revert: its fresh timer finishes the revert",
           b.waitNoMarker(180), b.guardJournal(att3))
      b.reverted("r k+i", TimerGoneReason)
      # (r) = (n)+(i): the owner at its deadline, killed mid-revert.
      let u4 = b.start(b.link)
      discard b.waitArmed()
      let att4 = b.attempt()
      discard b.mux("sleep 3; systemctl stop 'repro-addon-guard-" & att4 & "-*'")
      b.pause("revert:step-4")
      discard b.waitPaused("revert:step-4", Timeout + 120)
      b.killedOwner(u4)
      discard b.mux("rm -f " & Ctl & "/test-paused-at*")
      step("(r) the owner killed mid-revert at its deadline: its fresh timer " &
           "finishes", b.waitNoMarker(180), b.guardJournal(att4))
      b.reverted("r n+i", TimerGoneReason)
      # (w) recover on `fired` with every timer stopped, owner dead.
      b.pause("step-8")
      let u5 = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att5 = b.attempt()
      b.killedOwner(u5)
      b.pause("revert-network-mid-revert")
      discard b.waitPaused("revert-network-mid-revert", Timeout + 120)
      discard b.mux("systemctl kill --signal=SIGKILL 'repro-addon-guard-" & att5 &
                    "-*.service'; systemctl stop 'repro-addon-guard-" & att5 &
                    "-*'; rm -f " & Ctl & "/test-paused-at*")
      b.pause("revert:step-4")
      discard b.runDetached("gate-recover2", repro & " system addon recover")
      discard b.waitPaused("revert:step-4")
      discard b.mux("systemctl kill --signal=SIGKILL gate-recover2.service; rm -f " &
                    Ctl & "/test-paused-at*")
      step("(w) recover on fired with no timer arms a fresh one first; killed " &
           "mid-revert, that timer finishes", b.waitNoMarker(180),
           b.guardJournal(att5) & b.mux("cat /root/gate-recover2.log").stdout)
      b.reverted("w", GuardTimerReason)
    # ---- (l): a reboot with the marker fired, and reverting.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      b.killedOwner(unit)
      b.pause("revert-network-mid-revert")
      discard b.waitPaused("revert-network-mid-revert", Timeout + 120)
      b.rebootGuest()
      step("(l) fired + reboot: boot recovery completes the revert",
           "reverted the network switch" in b.reassertReport(), b.reassertReport())
      b.reverted("l fired", GuardTimerReason & InterruptedByRebootSuffix)
      discard b.mux("touch " & Ctl & "/test-network-step-fails; sync")
      b.pause("revert:step-1", synced = true)
      discard b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("revert:step-1")
      discard b.mux("rm -f " & Ctl & "/test-network-step-fails; sync")
      b.rebootGuest()
      let rep = b.reassertReport()
      step("(l) reverting + reboot: boot recovery completes the revert",
           "finished the network guard's revert" in rep, rep)
      b.reverted("l reverting", InterruptedByRebootSuffix)
    # ---- (m): recover on fired, owner dead, before the successor fires.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      b.killedOwner(unit)
      b.pause("revert-network-mid-revert")
      discard b.waitPaused("revert-network-mid-revert", Timeout + 120)
      let rec = b.mux(repro & " system addon recover").stdout
      b.resume("revert-network-mid-revert")
      step("(m) recover completes the revert; the successor then exits",
           "reverted the network switch" in rec and b.waitNoMarker(60), rec)
      discard b.mux("sleep 15", 30)
      b.reverted("m", GuardTimerReason)
    # ---- (o): the snapshot undeletable during the revert.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      # Through the channel opened before the switch: a fresh SSH session
      # here (``g.addonRows``) would disarm the guard.
      let key = b.nb.markerField("root-snapshot")
      let newNum = b.mux("grep -l '" & key & "' /.snapshots/*/info.xml" &
        " | head -1 | xargs dirname | xargs basename").stdout.strip()
      discard b.mux("chattr +i /.snapshots/" & newNum)
      b.resume("step-8")
      discard b.nb.waitApplyDone(unit, Timeout + 300)
      let log = b.nb.applyLog(unit)
      step("(o) the revert records rolled-back, names the snapshot with " &
           "EAddOnSnapshotLeft and removes the marker",
           "EAddOnSnapshotLeft" in log and b.mux("test -e " & MarkerPath).exitCode != 0,
           log)
      discard b.mux("chattr -i /.snapshots/" & newNum)
      let rec = b.mux(repro & " system addon recover").stdout
      b.reverted("o", GuardTimerReason)
      discard rec
    # ---- (p): the commit after disarmed fails.
    block:
      discard b.mux("touch " & Ctl & "/test-commit-fails")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.nb.waitApplyDone(unit, Timeout + 300)
      let log = b.nb.applyLog(unit)
      step("(p) a failed commit after disarm leaves the marker disarmed and " &
           "reverts nothing", "stays `disarmed`" in log and
           b.nb.markerField("guard") == "disarmed" and
           b.mux("ip link show " & LinkName).exitCode == 0, log)
      discard b.mux("rm -f " & Ctl & "/test-commit-fails")
      let rec = b.mux(repro & " system addon recover").stdout
      step("(p) the next recovery commits", "committed the disarmed network " &
           "generation" in rec and b.mux("test -e " & MarkerPath).exitCode != 0, rec)
      let u2 = b.start(b.profileG)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.nb.waitApplyDone(u2, Timeout + 600)
      b.snapshotA()
    # ---- (t): a reboot with the marker disarmed.
    block:
      b.pause("guard-after-disarm", synced = true)
      discard b.start(b.link)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.waitPaused("guard-after-disarm")
      b.rebootGuest()
      let rep = b.reassertReport()
      step("(t) disarmed + reboot: boot recovery commits without a replay",
           "committed the disarmed network generation" in rep and
           b.mux("ip link show " & LinkName).exitCode == 0, rep)
      let u2 = b.start(b.profileG)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.nb.waitApplyDone(u2, Timeout + 600)
      b.snapshotA()
    # ---- (u): armed + reboot, the re-assert unit killed mid-revert.
    block:
      b.pause("step-8")
      discard b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      b.pause("revert:step-4", synced = true)
      b.nb.stopMux()
      discard b.g.exec(RebootCommand, timeoutSec = 30)
      discard b.g.waitPoweredOff(300)
      b.g.boot()
      b.nb.startMux()
      discard b.waitPaused("revert:step-4")
      let lockMade = b.mux("stat -c '%U %a' /run/repro-addon-guard.lock").stdout.strip()
      discard b.mux("systemctl kill --signal=SIGKILL repro-addon-reassert.service; " &
                    "rm -f " & Ctl & "/test-paused-at*")
      step("(u) boot recovery created the guard lock and armed a fresh timer; " &
           "killed mid-revert, that timer finishes it", lockMade == "root 600" and
           b.waitNoMarker(180), lockMade)
      b.reverted("u", ArmedAcrossRebootReason)
    # ---- (v): the owner disarming as the timer fires, both orders.
    block:
      b.pause("guard-before-disarm")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.waitPaused("guard-before-disarm")
      discard b.mux("for i in $(seq 1 " & $(Timeout + 60) & "); do grep -q " &
        "'^guard\tfired' " & MarkerPath & " && exit 0; sleep 1; done", Timeout + 90)
      b.resume("guard-before-disarm")
      discard b.nb.waitApplyDone(unit, 600)
      step("(v) fired first: a revert, not a commit", "rolled back" in
           b.nb.applyLog(unit), b.nb.applyLog(unit))
      b.reverted("v fired first", GuardTimerReason)
      b.pause("revert-network-before-lock")
      let u2 = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("revert-network-before-lock", Timeout + 120)
      discard nb.freshSsh("true")
      discard b.nb.waitApplyDone(u2, 600)
      b.resume("revert-network-before-lock")
      step("(v) disarmed first: a commit, never both", "disarmed by" in
           b.nb.applyLog(u2) and b.mux("ip link show " & LinkName).exitCode == 0 and
           b.mux("test -e " & MarkerPath).exitCode != 0, b.nb.applyLog(u2))
      let u3 = b.start(b.profileG)
      discard b.waitArmed()
      discard nb.freshSsh("true")
      discard b.nb.waitApplyDone(u3, Timeout + 600)
      b.snapshotA()
    # ---- (x): systemd-run fails.
    block:
      discard b.mux("touch " & Ctl & "/test-guard-arm-fails")
      let r = g.applyProfile(repro, "x", b.link)
      step("(x) before a switch: EAddOnGuardTimer, the snapshot deleted, no " &
           "marker, no write-ahead plan", r.exitCode != 0 and
           "EAddOnGuardTimer" in r.stdout & r.stderr and
           numbersOf(g.addonRows()) == b.snapsA and
           b.mux("test -e " & MarkerPath).exitCode != 0 and
           b.mux("ls -A " & Ctl & "/pending.d 2>/dev/null").stdout.strip().len == 0,
           r.stdout & r.stderr)
      discard b.mux("rm -f " & Ctl & "/test-guard-arm-fails")
      let n = b.nb.netState()
      let id = identityReport(b.fA, g.fingerprintArch(repro, account),
                              @[SnapperdActivation])
      step("(x) before a switch: the fingerprint is unchanged", id.ok and n == b.nA,
           id.text)
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      discard b.mux("systemctl stop 'repro-addon-guard-" & att & "-*'; touch " &
                    Ctl & "/test-guard-arm-fails")
      let rec = b.mux(repro & " system addon recover").stdout
      discard b.mux("rm -f " & Ctl & "/test-guard-arm-fails")
      step("(x) during a recovery's revert: EAddOnGuardTimer is reported and " &
           "the revert completes", "EAddOnGuardTimer" in rec and
           "reverted the network switch" in rec, rec)
      b.reverted("x", TimerGoneReason)
    # ---- (y): the timer stopped by hand, then an invariant fails.
    block:
      let unit = b.start(b.link)
      discard b.waitArmed()
      let att = b.attempt()
      discard b.mux("for i in $(seq 1 120); do ip link show " & LinkName &
                    " >/dev/null 2>&1 && exit 0; sleep 1; done")
      discard b.mux("systemctl stop 'repro-addon-guard-" & att & "-*'")
      b.pause("revert:step-4")
      # The owner must see the outage and start its failure-path revert: a
      # single flap of a few seconds was sampled or missed by the owner's
      # watch depending on the host's load, and a missed one left the owner
      # to revert at its deadline ("armed, its timer gone") instead
      # (measured twice in the AR6 regression runs, 2026-11-23). Holding the
      # link down instead let NetworkManager deactivate its connection and
      # re-activate it with another route metric (100 -> 102), a residue of
      # the harness's own change that every later comparison then saw
      # (measured 2026-11-24). So the guest flaps the link -- three seconds
      # down, shorter than the outage NetworkManager rides through, one up --
      # until the owner has paused at its revert, at most 40 times. The
      # link is also the one the harness's SSH rides on, so the guest runs
      # the loop itself, detached from the session that started it.
      discard b.mux("nohup setsid sh -c 'sleep 1; for i in $(seq 1 40); do " &
        "ip link set " & nb.oob & " down; sleep 3; ip link set " & nb.oob &
        " up; test -e " & Ctl & "/test-paused-at-revert:step-4 && break; " &
        "sleep 1; done; ip link set " & nb.oob & " up' </dev/null " &
        ">/dev/null 2>&1 &", 60)
      discard b.waitPaused("revert:step-4", 240)
      let loaded = b.mux("systemctl list-units --plain --no-legend " &
        "'repro-addon-guard-" & att & "-*.timer'").stdout.strip()
      b.killedOwner(unit)
      discard b.mux("rm -f " & Ctl & "/test-paused-at*")
      step("(y) the owner armed a fresh timer before its failure-path revert; " &
           "killed mid-revert, that timer finishes it", loaded.len > 0 and
           b.waitNoMarker(180), loaded & "\n" & b.guardJournal(att))
      b.reverted("y", "outOfBand")
    # ---- (z): recover while the owner reverts.
    block:
      discard b.mux("touch " & Ctl & "/test-network-step-fails")
      b.pause("revert:step-4")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("revert:step-4")
      discard b.runDetached("gate-recover3", "env REPRO_HOST_APPLY_LOCK_WAIT_SECONDS=2 " &
                            repro & " system addon recover")
      discard b.mux("sleep 8", 30)
      let short = b.mux("cat /root/gate-recover3.log").stdout
      discard b.runDetached("gate-recover4", repro & " system addon recover")
      discard b.mux("sleep 3", 30)
      b.resume("revert:step-4")
      discard b.mux("rm -f " & Ctl & "/test-network-step-fails")
      discard b.nb.waitApplyDone(unit, 600)
      discard b.mux("for i in $(seq 1 120); do systemctl is-active --quiet " &
                    "gate-recover4.service || exit 0; sleep 1; done", 150)
      let long = b.mux("cat /root/gate-recover4.log").stdout
      step("(z) recover waits for the owner, then finds the marker gone and " &
           "changes nothing", "marker is gone" in long, long)
      step("(z) with a shorter wait bound it fails ELockTimeout having changed " &
           "nothing", "ELockTimeout" in short or "lock" in short.toLowerAscii(),
           short)
      b.reverted("z", "")
    # ---- (aa): a deploy-agent apply with a network marker pending.
    block:
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      let units0 = b.nb.guardUnits()
      discard b.mux("cp /root/addon/a" & $b.n & ".profile /root/addon/agent.profile")
      let tick = b.mux(repro & " system addon test-agent-apply --profile " &
                       "/root/addon/agent.profile 2>&1; true").stdout
      step("(aa) a deploy-agent apply reports the network marker, arms no " &
           "timer and applies nothing", "leaves it to the re-assert unit" in tick and
           b.nb.guardUnits() == units0, tick)
      discard b.mux(repro & " system addon recover; true")
      discard b.waitNoMarker(Timeout + 120)
      b.reverted("aa", "")
      discard att
    # ---- (bb): the guard binary replaced, deleted; the store unmounted.
    block:
      for (what, act) in [("replaced", "printf x > /var/lib/repro/bin/repro"),
                          ("deleted", "rm -f /var/lib/repro/bin/repro")]:
        discard b.mux(act)
        let unit = b.start(b.link)
        discard b.waitArmed()
        discard nb.freshSsh("true")
        discard b.nb.waitApplyDone(unit, Timeout + 600)
        let log = b.nb.applyLog(unit)
        step("(bb) the copy " & what & ": the apply repairs it (never EDrift), " &
             "arms and switches", "rewritten from" in log and "EDrift" notin log and
             "disarmed by" in log, log)
        let u2 = b.start(b.profileG)
        discard b.waitArmed()
        discard nb.freshSsh("true")
        discard b.nb.waitApplyDone(u2, Timeout + 600)
      b.snapshotA()
      # After a refresh of the add-on binary, a recovery compares the copy
      # with the store's CURRENT binary, never with the older ledger's
      # digest (§13 decision 128). The refresh is stood for by its effect:
      # the copy holds other bytes and the current ledger's `guardBinary`
      # digest is THEIRS (what an older add-on binary recorded), so only a
      # comparison with the store's binary finds the copy stale.
      b.pause("step-8")
      let unit = b.start(b.link)
      discard b.waitArmed()
      discard b.waitPaused("step-8")
      let att = b.attempt()
      b.killedOwner(unit)
      let ledgerFile = StateDir & "/addon-ledger"
      let stale = b.mux("systemctl stop 'repro-addon-guard-" & att & "-*'; " &
        "old=$(sha256sum " & gen0ReproExe(g) & " | cut -d' ' -f1); " &
        "new=$(sha256sum /usr/bin/true | cut -d' ' -f1); " &
        "sed -i \"/^guardBinary\t/s/$old/$new/\" " & ledgerFile & "; " &
        "cp /usr/bin/true /var/lib/repro/bin/repro; " &
        "grep '^guardBinary' " & ledgerFile & " | grep -c \"$new\"").stdout.strip()
      let rec = b.mux(repro & " system addon recover").stdout
      step("(bb) after a refresh a recovery compares the copy with the new " &
           "binary, not the ledger's older digest, repairs it and completes",
           stale == "1" and "differed from the store's add-on binary" in rec and
           # Repaired BEFORE the fresh timer that runs it is armed.
           rec.find("differed from the store's add-on binary") <
             rec.find("armed a fresh guard timer") and
           "reverted the network switch" in rec and
           b.mux("cmp -s /var/lib/repro/bin/repro " & gen0ReproExe(g)).exitCode == 0,
           "ledger digest replaced: " & stale & "\n" & rec)
      b.reverted("bb", TimerGoneReason)
      # The store unreadable for the guard: its add-on binary's prefix
      # hidden (an object the arm needs, spec §13 decision 127), the
      # static tree the fixture's link reads left as it is.
      let binPrefix = parentDir(parentDir(gen0ReproExe(g)))
      discard b.mux("rm -f /var/lib/repro/bin/repro; mount -t tmpfs -o " &
                    "size=1m,mode=0700 repro-gate-hide " & binPrefix)
      let r = b.mux("/root/addon/repro infra apply --profile /root/addon/a" &
                    $b.n & ".profile 2>&1", 600)
      discard b.mux("umount " & binPrefix)
      step("(bb) with the store unmounted too: EAddOnGuardTimer, nothing left",
           r.exitCode != 0 and "EAddOnGuardTimer" in r.stdout & r.stderr and
           b.mux("test -e " & MarkerPath).exitCode != 0, r.stdout & r.stderr)
      # ... and a revert in that state reports EAddOnGuardTimer and goes
      # on: no good copy can be made, so no fresh timer is armed, and the
      # revert is never refused for it (§13 decisions 125, 126, 128).
      block:
        b.pause("step-8")
        let u2 = b.start(b.link)
        discard b.waitArmed()
        discard b.waitPaused("step-8")
        let att2 = b.attempt()
        b.killedOwner(u2)
        discard b.mux("systemctl stop 'repro-addon-guard-" & att2 & "-*'; " &
                      "rm -f /var/lib/repro/bin/repro; mount -t tmpfs -o " &
                      "size=1m,mode=0700 repro-gate-hide " & binPrefix)
        let rec2 = b.mux(repro & " system addon recover 2>&1").stdout
        let linkGone = b.mux("ip link show " & LinkName).exitCode != 0
        discard b.mux("umount " & binPrefix)
        step("(bb) with the store unmounted and the copy missing, a revert " &
             "reports EAddOnGuardTimer and goes on", "EAddOnGuardTimer" in rec2 and
             "the revert goes on" in rec2 and linkGone, rec2)
        # Whatever waited for the store completes once it is back.
        let rec3 = b.mux(repro & " system addon recover 2>&1").stdout
        discard b.waitNoMarker(120)
        b.reverted("bb store", TimerGoneReason)
        discard rec3
    # ---- (cc): a generation 0 that predates the copy.
    block:
      discard b.mux("rm -f /var/lib/repro/bin/repro; sed -i '/^guardBinary\t/d' " &
                    StateDir & "/addon-ledger")
      let r = g.applyProfile(repro, "cc", b.profileG)
      let l = b.mux("cat " & StateDir & "/addon-ledger").stdout
      let logs = b.mux("cat " & StateDir & "/generations/*/log/apply.log | " &
                       "tr -c '[:print:]' ' ' | grep -a -o 'added as a " &
                       "guardBinary ledger object[^)]*'").stdout
      step("(cc) the first apply adds the copy as a guardBinary ledger object " &
           "and records the addition", r.exitCode == 0 and
           "\nguardBinary\t/var/lib/repro/bin/repro" in l and "added" in logs,
           logs & l)
    # ---- (q): a network switch refused at step 1, and at step 2.
    block:
      b.snapshotA()
      # Step 1 (the seam build's stand-in for a record that became
      # unreadable after the plan): before the snapshot and the arm.
      discard b.mux("touch " & Ctl & "/test-step-1-refuses")
      let r1 = g.applyProfile(repro, "q-step-1", b.link)
      discard b.mux("rm -f " & Ctl & "/test-step-1-refuses")
      step("(q) a network switch refused at step 1 takes no snapshot, arms " &
           "no timer and leaves no marker", r1.exitCode != 0 and
           "refusing the switch: step 1" in r1.stdout & r1.stderr and
           numbersOf(g.addonRows()) == b.snapsA and b.nb.guardUnits().len == 0 and
           b.mux("test -e " & MarkerPath).exitCode != 0, r1.stdout & r1.stderr)
      # Step 2: an exclusive unit whose instance ignores SIGTERM while a
      # flag file exists and may not be killed, changed by a network
      # switch: its stop is never confirmed and the switch is refused
      # with EAddOnExclusiveOverlap after its marker and timer were written.
      const Stubborn = "/usr/local/bin/repro-gate-stubborn"
      const Flag = "/run/repro-gate-stubborn"
      const QUnit = "repro-gate-stubborn.service"
      discard b.mux("printf '%s\\n' '#!/bin/sh' \"trap 'if [ -e " & Flag &
        " ]; then :; else exit 0; fi' TERM\" 'while :; do sleep 0.2; done' > " &
        Stubborn & " && chmod 0755 " & Stubborn)
      proc stubbornUnit(id: string): string =
        "systemd.systemUnit {\n" & FixtureFloorWaiver & "  name = \"" & QUnit &
          "\"\n  content = \"[Unit]\nDescription=AR5 gate exclusive fixture " &
          id & "\nX-Repro-Exclusive=true\n\n[Service]\nExecStart=" & Stubborn &
          " " & id & "\nTimeoutStopSec=3\nSendSIGKILL=no\n\n[Install]\n" &
          "WantedBy=multi-user.target\n\"\n  enabled = true\n}\n"
      let q0 = b.profileG & stubbornUnit("q1")
      let a0 = g.applyProfile(repro, "q0", q0)
      step("(q) the previous generation with the exclusive fixture applies",
           a0.exitCode == 0 and g.exec("systemctl is-active --quiet " & QUnit).exitCode == 0,
           a0.stdout & a0.stderr)
      b.snapshotA()
      let pidBefore = b.mux("systemctl show -p MainPID --value " & QUnit).stdout.strip()
      discard b.mux("touch " & Flag)
      b.pause("guard-refused-step-2")
      let unit = b.start(b.profileG & stubbornUnit("q2") & linkStanza(nb.parentMac))
      # Armed only until step 2 refuses, a few seconds: the pause after the
      # refused switch wrote `reverting` is what the gate waits for.
      let p = b.waitPaused("guard-refused-step-2")
      let att = b.attempt()
      let m = b.mux("cat " & MarkerPath).stdout
      let loaded = b.mux("systemctl list-units --plain --no-legend " &
        "'repro-addon-guard-" & att & "-*.timer' | grep -c ' active '").stdout.strip()
      step("(q) refused at step 2: the marker shows reverting with the " &
           "refusal, and the timer is still loaded", p and
           "guard\treverting" in m and "EAddOnExclusiveOverlap" in m and
           loaded != "0", m & "\n" & loaded)
      b.resume("guard-refused-step-2")
      discard b.nb.waitApplyDone(unit, 600)
      let log = b.nb.applyLog(unit)
      step("(q) the refusal is EAddOnExclusiveOverlap, recorded rolled-back " &
           "with EAddOnNetworkGuard; the old instance is the only one",
           "EAddOnExclusiveOverlap" in log and "recorded rolled-back with " &
           "EAddOnNetworkGuard" in log and
           b.mux("pgrep -f '^/bin/sh " & Stubborn & " q1$'").stdout.strip() == pidBefore and
           b.mux("pgrep -f '^/bin/sh " & Stubborn & " q2$'").exitCode != 0, log)
      b.reverted("q", "EAddOnExclusiveOverlap", proc() =
        # The harness's own fixture, put back as it was. After the stop
        # that timed out the unit is `failed` with the old instance still
        # in its control group, which `systemctl stop` does not signal: it
        # is killed outright, the group waited empty, and the unit started
        # again.
        discard b.mux("rm -f " & Flag & "; systemctl kill --signal=SIGKILL " &
          QUnit & " 2>/dev/null; for i in $(seq 1 30); do pgrep -f '^/bin/sh " &
          Stubborn & " ' >/dev/null || break; sleep 1; done; systemctl " &
          "reset-failed " & QUnit & " 2>/dev/null; systemctl start " & QUnit &
          "; for i in $(seq 1 30); do systemctl is-active --quiet " & QUnit &
          " && exit 0; sleep 1; done; exit 1", 120))
      let a1 = g.applyProfile(repro, "q-back", b.profileG)
      discard b.mux("rm -f " & Stubborn)
      step("(q) the fixture goes with the previous generation", a1.exitCode == 0,
           a1.stdout & a1.stderr)
      b.snapshotA()
    # ---- (s): uninstall over a pending marker, the unit loop, the lock.
    block:
      for state in ["armed", "disarmed"]:
        b.pause(if state == "armed": "step-8" else: "guard-after-disarm")
        let unit = b.start(b.link)
        discard b.waitArmed()
        if state == "disarmed": discard nb.freshSsh("true")
        discard b.waitPaused(if state == "armed": "step-8"
                             else: "guard-after-disarm")
        b.killedOwner(unit)
        # The marker stays pending for this check: its timers are stopped
        # so none reverts it in the middle of the comparison.
        discard b.mux("systemctl stop 'repro-addon-guard-*'; true")
        let fBefore = g.fingerprintArch(repro, account)
        let un = b.mux(repro & " system addon uninstall").stdout
        let id = identityReport(fBefore, g.fingerprintArch(repro, account),
                                @[SnapperdActivation])
        step("(s) uninstall with a pending " & state & " marker refuses with " &
             "EAddOnSwitchPending and changes nothing", "EAddOnSwitchPending" in un and
             id.ok, un & id.text)
        discard b.mux(repro & " system addon recover")
        discard b.waitNoMarker(Timeout + 120)
        discard b.mux("systemctl stop 'repro-addon-guard-*'; true")
      # A stale guard timer firing every 10 s: the real revert-network of
      # an attempt no marker names, so each firing arms a successor (and
      # stops it) between uninstall's passes.
      discard b.mux("systemd-run --quiet --collect --unit=repro-addon-guard-" &
        "e".repeat(32) & "-loop --on-active=1s --on-unit-active=10s " &
        "-- /var/lib/repro/bin/repro system addon revert-network " & genA &
        " --attempt " & "e".repeat(32) & " --state-dir " & StateDir)
      discard b.mux("sleep 25", 60)
      let firing = b.guardJournal("e".repeat(32))
      step("(s) the stale timer fires and arms a successor between passes",
           "armed the successor" in firing, firing & "\n" & b.mux(
             "ls -l /var/lib/repro/bin/repro; systemctl status --no-pager " &
             "'repro-addon-guard-*' 2>&1 | head -40").stdout)
      for nn in numbersOf(g.addonRows()):
        discard b.mux("chattr +i /.snapshots/" & $nn)
      let un = b.mux(repro & " system addon uninstall").stdout
      step("(s) uninstall with a snapshot undeletable ends incomplete with " &
           "EAddOnSnapshotLeft; its loop stopped every guard unit and the lock " &
           "is gone", "EAddOnSnapshotLeft" in un and "network guard units: pass" in un and
           b.nb.guardUnits().len == 0 and
           b.mux("test -e /run/repro-addon-guard.lock").exitCode != 0, un)
      for nn in numbersOf(g.addonRows()):
        discard b.mux("chattr -i /.snapshots/" & $nn)
      nb.stopMux()
      let un2 = g.exec(repro & " system addon uninstall")
      step("(s) uninstall with the lock already absent succeeds; (j) the lock " &
           "is gone after uninstall", un2.exitCode == 0 and
           g.exec("test -e /run/repro-addon-guard.lock").exitCode != 0,
           un2.stdout & un2.stderr)
      let id = identityReport(f0, g.fingerprintArch(repro, account),
                              @RebootVariance)
      step("base fingerprint after uninstall == before bootstrap", id.ok, id.text)
    record["successorIntervalSecStated"] = %10
  except CatchableError as e:
    fails.add(base.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if nb != nil:
      record["guest"] = %nb.om.name
      record["log"] = %(nb.om.log & nb.helper.log)
      nb.stopMux()
      nb.destroy()
  fails

proc expected(mut: string; b: BaseImage): Falsifier =
  case mut
  of "guard-skips-arm":
    Falsifier(required: @["(a)/MS-2 (killed): the timer reverts the bad generation"],
      mayBeRed: @["(a) recorded rolled-back with EAddOnNetworkGuard (guard timer fired)",
        "(a) the marker is gone and no guard unit is left",
        "(a) the attempt's root snapshot is gone",
        "(a) links, addresses and routes equal the previous generation's",
        "(a) the fingerprint equals the previous generation's"],
      mustRunGreen: @["bootstrap",
        "MS-2: with no operator action the host is back within the timeout " &
        "plus the revert time", "MS-2 (killed): the switch reaches its watch"])
  of "recovery-replays-armed":
    Falsifier(required: @["MS-2 (reset): recovery at boot reverts without replaying"],
      mayBeRed: @["(MS-2 reset) recorded rolled-back with EAddOnNetworkGuard " &
          "(armed across a reboot)",
        "(MS-2 reset) the marker is gone and no guard unit is left",
        "(MS-2 reset) the attempt's root snapshot is gone",
        "(MS-2 reset) links, addresses and routes equal the previous generation's",
        "(MS-2 reset) the fingerprint equals the previous generation's"],
      mustRunGreen: @["bootstrap",
        "MS-2: with no operator action the host is back within the timeout " &
        "plus the revert time"])
  else: raise unknownMutation(Gate, mut)

suite Gate:
  test "the network guard returns the host to the previous generation in every state":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if not isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the Omarchy VM")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        record["omarchy"] = omarchyRecordBase()
        record["guardTimeoutSec"] = %Timeout
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        failures.add(judgeRun(Gate, record, f, expected, b))
        echo "record: ", writeRecord(Gate, record)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
