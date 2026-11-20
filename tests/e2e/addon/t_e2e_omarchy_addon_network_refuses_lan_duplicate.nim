## Gate ``e2e_omarchy_addon_network_refuses_lan_duplicate`` (milestone AR5;
## spec ReproOS-Add-On-Mode §4.5, §7.2; §13 decisions 88, 100; threat model
## G49, T57).
##
## A second VM on the test LAN (the helper) holds an address. A generation
## adding it on an ``ipvlan`` link is refused before the switch with
## ``EAddOnNetworkGuard`` naming the replying MAC, and writes nothing (the
## fingerprint and the host's links, addresses and routes unchanged). With
## ``rootSnapshot: required`` the refused apply takes no snapshot either.
## The same generation with a free address applies, and its keyfile carries
## ``ipv4.dad-timeout``.
##
## Falsifying mutation ``network-skips-arping-probe``: the probe answers
## "free" without probing, so the duplicate goes through on ipvlan (whose
## children share the parent's MAC, so NetworkManager's own conflict
## detection does not see the defender: measured, ``network_link``); the
## refusal step goes red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just
## e2e_omarchy_addon_network_refuses_lan_duplicate``).
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./network_gate_support

const
  Gate = "e2e_omarchy_addon_network_refuses_lan_duplicate"
  HeldAddr = LanNet & ".50"
  FreeAddr = LanNet & ".21"
  RefusalStep = "an address the helper holds is refused before the switch, " &
    "naming its MAC"

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
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
    let helperIf = nb.helper.run("for d in /sys/class/net/*; do [ \"$(cat " &
      "$d/address)\" = " & nb.helper.lanMac() & " ] && basename $d; done; " &
      "true").strip()
    discard nb.helper.run("ip addr add " & HeldAddr & "/24 dev " & helperIf)
    step("the helper holds " & HeldAddr, true, helperIf)
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    let n0 = nb.netState()
    let snaps0 = numbersOf(g.addonRows())
    let held = g.applyProfile(repro, "held", nb.netProfile(account,
      address = HeldAddr & "/24", setting = "required"))
    let output = held.stdout & held.stderr
    record["refusal"] = %output
    step(RefusalStep, held.exitCode != 0 and "EAddOnNetworkGuard" in output and
         "address in use on the LAN" in output and nb.helper.lanMac() in output, output)
    step("the refused apply took no root snapshot",
         numbersOf(g.addonRows()) == snaps0, g.run("snapper -c root list"))
    step("the refused apply left no marker and no guard",
         g.exec("test -e " & MarkerPath).exitCode != 0 and
         g.exec("systemctl list-units --all --plain --no-legend " &
                "'repro-addon-guard-*' | grep -q .").exitCode != 0,
         g.exec("ls -la " & StateDir & "/addon").stdout)
    let id = identityReport(f0, g.fingerprintArch(repro, account),
                            @[SnapperdActivation])
    step("the refused apply wrote nothing: the fingerprint is unchanged",
         id.ok, id.text)
    let n1 = nb.netState()
    step("the refused apply wrote nothing: links, addresses, routes unchanged",
         n1 == n0, n0 & "\n=>\n" & n1)
    # The same generation with a free address.
    nb.startMux()
    let unit = nb.startApply(repro, "free", nb.netProfile(account,
      address = FreeAddr & "/24", setting = "required"))
    let armed = nb.waitArmedOrDone(unit)
    discard nb.freshSsh("true")
    let done = nb.waitApplyDone(unit, 900)
    let log = nb.applyLog(unit)
    record["applyLog"] = %log
    step("a free address applies under the guard", armed and done and
         "disarmed by" in log, log)
    let k = nb.muxRun("cat /etc/NetworkManager/system-connections/repro-" &
                      LinkName & ".nmconnection")
    step("its keyfile carries ipv4.dad-timeout", "dad-timeout=3000" in k, k)
    step("the address answers SSH from the LAN", nb.lanSshBanner(FreeAddr), "")
    nb.stopMux()
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
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
  of "network-skips-arping-probe":
    Falsifier(required: @[RefusalStep],
      mayBeRed: @["the refused apply took no root snapshot",
        "the refused apply left no marker and no guard",
        "the refused apply wrote nothing: the fingerprint is unchanged",
        "the refused apply wrote nothing: links, addresses, routes unchanged"],
      mustRunGreen: @["bootstrap", "a free address applies under the guard",
                      "uninstall"])
  else: raise unknownMutation(Gate, mut)

suite Gate:
  test "an address another LAN device holds is refused before the switch":
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
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        failures.add(judgeRun(Gate, record, f, expected, b))
        echo "record: ", writeRecord(Gate, record)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
