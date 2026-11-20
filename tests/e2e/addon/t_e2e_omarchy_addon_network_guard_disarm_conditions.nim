## Gate ``e2e_omarchy_addon_network_guard_disarm_conditions`` (milestone
## AR5; spec ReproOS-Add-On-Mode §4.5 steps 3-4; §13 decision 86; threat
## model G47, T54, T55).
##
## A correct network generation (an ipvlan link on the parent) is disarmed
## and committed only when every invariant holds -- the ``keep`` address on
## the parent, the default routes observed before the switch, the
## out-of-band link ``wt0`` up with its address -- and a new
## key-authenticated SSH session from a non-loopback address arrives after
## the switch. Each negative control runs the same generation and ends in a
## revert recorded ``rolled-back`` with ``EAddOnNetworkGuard``; then the
## fingerprint and the host's links, addresses and routes are compared with
## the previous generation's:
##
## (a) no new SSH session before the timer; (b) a new SSH session from
## loopback only; (c) ``confirm`` from an SSH session opened before the
## switch; (d) the out-of-band link brought down during the window; (e)
## the default route replaced during the window; (f) the ``keep`` address
## removed during the window; (g) an "Accepted publickey" line written to
## the journal by an unprivileged ``logger -t sshd``, with no real session.
##
## In (d), (e) and (f) the harness's own change is not restored by the
## add-on (§13 decision 86): the gate asserts it is still in place after
## the revert, undoes it, and only then compares.
##
## During every window the harness talks to the guest only through the
## SSH connection it opened before the switch (``network_gate_support``),
## so it never brings a new session itself.
##
## ``wt0`` is a dummy link the harness creates before the baseline and
## deletes before the final comparison: the stand-in for NetBird's.
##
## Falsifying mutation ``guard-disarms-on-success``: the guard disarms as
## soon as the switch reports success, so (a), (b) and (c) commit, and
## their steps go red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just
## e2e_omarchy_addon_network_guard_disarm_conditions``).
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./network_gate_support

const
  Gate = "e2e_omarchy_addon_network_guard_disarm_conditions"
  Timeout = 45

proc stepOf(c: string): string =
  "control (" & c & ") ends in a revert recorded rolled-back with EAddOnNetworkGuard"

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var nb: NetBed
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    nb = newNetBed()
    nb.bootNetBed(step)
    let g = nb.om
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let account = accountFor(b)
    nb.makeWt0()
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
    # A key for root's own loopback session (control (b)), authorised for
    # the gate's run only.
    discard g.run("ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/gate_lo && " &
      "cp /root/.ssh/authorized_keys /root/.ssh/authorized_keys.gate && " &
      "cat /root/.ssh/gate_lo.pub >> /root/.ssh/authorized_keys")
    nb.startMux()
    let profile = guardStanza(account, Timeout, oob = "wt0").replace(
      "PARENT", nb.parent) & linkStanza(nb.parentMac)
    let fA = g.fingerprintArch(repro, account)
    let nA = nb.netState()
    let lease = g.run("ip -4 -o addr show dev " & nb.parent &
                      " | awk '{print $4}' | head -1").strip()
    let conn = nb.muxRun("nmcli -t -f UUID,DEVICE c show --active | grep ':" &
                         nb.parent & "$' | cut -d: -f1").strip()
    var n = 0
    proc control(c: string; during: proc(); stillThere: proc(): bool = nil;
                 undo: proc() = nil) =
      inc n
      let before = nb.guardRollbacks().len
      let unit = nb.startApply(repro, "c" & $n, profile)
      let armed = nb.waitMarkerGuard(["armed"], 600)
      # The switch has begun; wait for the watch (the link is up).
      discard nb.muxExec("for i in $(seq 1 120); do ip link show " & LinkName &
                         " >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1", 200)
      during()
      let done = nb.waitApplyDone(unit, Timeout + 600)
      let log = nb.applyLog(unit)
      let rb = nb.guardRollbacks()
      step(stepOf(c), armed == "armed" and done and
           "rolled back" in log and rb.len == before + 1 and
           nb.muxExec("test -e " & MarkerPath).exitCode != 0,
           log & "\n" & rb.join("\n"))
      if stillThere != nil:
        step("control (" & c & "): the harness's own change is still in " &
             "place after the revert (§13 decision 86)", stillThere(),
             nb.netState())
      if undo != nil: undo()
      let fpAfter = g.fingerprintArch(repro, account)
      let id = identityReport(fA, fpAfter, @[SnapperdActivation])
      step("control (" & c & "): the fingerprint equals the previous " &
           "generation's", id.ok, id.text)
      let netAfter = nb.netState()
      step("control (" & c & "): links, addresses and routes equal the " &
           "previous generation's", netAfter == nA, nA & "\n=>\n" & netAfter)
      step("control (" & c & "): no guard unit is left", nb.guardUnits().len == 0,
           nb.guardUnits())
    proc nothing() = discard
    control("a", nothing, nil, nil)
    control("b", proc() =
      discard nb.muxExec("ssh -o StrictHostKeyChecking=no -o " &
        "UserKnownHostsFile=/dev/null -i /root/.ssh/gate_lo root@127.0.0.1 true"),
      nil, nil)
    var confirmOut = ""
    control("c", proc() =
      let gen = nb.markerField("attempt")
      confirmOut = nb.muxExec(repro & " system addon confirm " & gen).stdout,
      nil, nil)
    step("control (c): confirm from a session opened before the switch is refused",
         "created before the switch began" in confirmOut or
         "refused" in confirmOut, confirmOut)
    control("d", proc() = discard nb.muxExec("ip link set wt0 down"),
      proc(): bool = "state DOWN" in nb.muxExec("ip link show wt0").stdout,
      proc() = discard nb.muxExec("ip link set wt0 up"))
    control("e", proc() =
      discard nb.muxExec("ip route del default via " & HelperLanAddr &
        " dev " & nb.parent & "; ip route add default via " & HelperLanAddr &
        " dev " & nb.parent & " metric 7"),
      proc(): bool = "metric 7" in nb.muxExec("ip -4 route show default").stdout,
      proc() = discard nb.muxExec("ip route del default via " & HelperLanAddr &
        " dev " & nb.parent & " metric 7; nmcli connection up uuid " & conn,
        120))
    control("f", proc() =
      discard nb.muxExec("ip addr del " & lease & " dev " & nb.parent),
      proc(): bool = lease notin nb.muxExec("ip -4 -o addr show dev " &
                                            nb.parent).stdout,
      proc() = discard nb.muxExec("nmcli connection up uuid " & conn, 120))
    control("g", proc() =
      discard nb.muxExec("runuser -u " & account & " -- logger -t sshd " &
        "'Accepted publickey for root from 10.9.9.9 port 4242 ssh2: ED25519 " &
        "SHA256:forged'"), nil, nil)
    # The positive run: a new SSH session after the switch.
    let unit = nb.startApply(repro, "ok", profile)
    let armed = nb.waitMarkerGuard(["armed"], 600)
    discard nb.freshSsh("true")
    let done = nb.waitApplyDone(unit, Timeout + 600)
    let log = nb.applyLog(unit)
    step("every invariant holds and a new SSH session arrives: disarmed and " &
         "committed", armed == "armed" and done and "disarmed by" in log and
         nb.muxExec("test -e " & MarkerPath).exitCode != 0 and
         nb.muxExec("ip link show " & LinkName).exitCode == 0, log)
    # Clean up: the link out, then the add-on, then the harness's own.
    let unit2 = nb.startApply(repro, "out", guardStanza(account, Timeout,
      oob = "wt0").replace("PARENT", nb.parent))
    discard nb.waitMarkerGuard(["armed"], 600)
    discard nb.freshSsh("true")
    discard nb.waitApplyDone(unit2, Timeout + 600)
    nb.stopMux()
    discard g.run("mv /root/.ssh/authorized_keys.gate /root/.ssh/authorized_keys" &
                  " && rm -f /root/.ssh/gate_lo /root/.ssh/gate_lo.pub")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let id = identityReport(f0, g.fingerprintArch(repro, account),
                            @[SnapperdActivation])
    step("base fingerprint after uninstall == before bootstrap", id.ok, id.text)
    nb.dropWt0()
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
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
  of "guard-disarms-on-success":
    var may: seq[string]
    for c in ["a", "b", "c"]:
      may.add("control (" & c & "): the fingerprint equals the previous " &
              "generation's")
      may.add("control (" & c & "): links, addresses and routes equal the " &
              "previous generation's")
    may.add("control (c): confirm from a session opened before the switch is refused")
    # Once (a) committed the link, later controls run over it.
    for c in ["d", "e", "f", "g"]:
      may.add(stepOf(c))
      may.add("control (" & c & "): the fingerprint equals the previous " &
              "generation's")
      may.add("control (" & c & "): links, addresses and routes equal the " &
              "previous generation's")
      may.add("control (" & c & "): the harness's own change is still in " &
              "place after the revert (§13 decision 86)")
    may.add("every invariant holds and a new SSH session arrives: disarmed " &
            "and committed")
    may.add("base fingerprint after uninstall == before bootstrap")
    Falsifier(required: @[stepOf("a"), stepOf("b"), stepOf("c")],
              mayBeRed: may, mustRunGreen: @["bootstrap", "uninstall"])
  else: raise unknownMutation(Gate, mut)

suite Gate:
  test "the guard disarms only on its invariants and a new SSH session":
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
