## Gate ``e2e_omarchy_addon_network_link_adds_only`` (milestone AR5; spec
## ReproOS-Add-On-Mode §4.5, §8.5).
##
## On the Omarchy VM (NetworkManager), on the test LAN of
## ``network_gate_support``:
##
## 1. Generation 1 adds an ``ipvlan`` link on the parent (matched by its
##    MAC) with a static address, ``never-default`` and a routing-only
##    ``~home.arpa`` DNS server, under the network guard. The harness
##    opens a new SSH session after the switch, and the guard disarms.
##    Then: the address answers SSH from the test LAN (the helper); the
##    parent's connection UUID, address, lease and the default routes are
##    those observed before the apply; ``resolvectl`` lists the link's
##    server for ``~home.arpa`` only and the link is not a DNS default
##    route; the keyfile is the class's (0600 root, ``ipv4.dad-timeout``).
## 2. Generation 2 removes the object, under the guard again. The host's
##    links, IPv4 addresses and routes and the base fingerprint are then
##    what they were before generation 1.
## 3. Uninstall restores the fingerprint taken before bootstrap.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just
## e2e_omarchy_addon_network_link_adds_only``).
##
## *Mocking.* None: two real VMs, real NetworkManager and the real static
## add-on binary.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./network_gate_support

const Gate = "e2e_omarchy_addon_network_link_adds_only"

proc parentConnection(nb: NetBed): string =
  ## The parent's active connection, its address, its lease and the
  ## default routes.
  nb.muxRun("nmcli -t -f UUID,DEVICE c show --active | grep ':" & nb.parent &
    "$'; nmcli -g IP4.ADDRESS device show " & nb.parent & "; nmcli -g " &
    "DHCP4.OPTION device show " & nb.parent & " | tr '|' '\\n' | " &
    "grep -E '^ *(ip_address|dhcp_server_identifier|routers) ' ; " &
    "ip -4 route show default | sort")

proc applyUnderGuard(nb: NetBed; repro, name, text: string;
                     step: StepFn): string =
  ## Apply ``text`` detached; once the guard is armed, open a new SSH
  ## session (what disarms it); wait for the apply. Returns its log.
  let unit = nb.startApply(repro, name, text)
  let armed = nb.waitArmedOrDone(unit)
  step(name & ": the switch arms the network guard", armed,
       nb.applyLog(unit))
  let s = nb.freshSsh("true")
  step(name & ": a new SSH session from the harness", s.exitCode == 0, s.stdout)
  let done = nb.waitApplyDone(unit, 900)
  result = nb.applyLog(unit)
  step(name & ": the apply disarms and commits", done and
       "network guard: disarmed by Accepted publickey" in result and
       nb.muxExec("test -e " & MarkerPath).exitCode != 0, result)

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
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    let net0 = nb.netState()
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
    nb.startMux()
    let conn0 = nb.parentConnection()
    let netA = nb.netState()
    let fA = g.fingerprintArch(repro, account)
    step("bootstrap leaves the network as it was", netA == net0,
         net0 & "\n=> \n" & netA)
    # --- 1. Add the link.
    let log1 = nb.applyUnderGuard(repro, "g1", nb.netProfile(account), step)
    record["applyLog1"] = %log1
    step("the address answers SSH from the test LAN",
         nb.lanSshBanner(LinkAddr.split('/')[0]), nb.helper.exec(
           "ip -br addr; ip neigh").stdout)
    let conn1 = nb.parentConnection()
    step("the parent's connection, address, lease and default routes are unchanged",
         conn1 == conn0, conn0 & "\n=>\n" & conn1)
    let rs = nb.muxRun("resolvectl status " & LinkName & " --no-pager")
    step("resolvectl: only ~home.arpa goes to the link's server; not a DNS default route",
         "DNS Domain: ~home.arpa" in rs and ("Default Route: no" in rs) and
         HelperLanAddr in rs, rs)
    let kf = "/etc/NetworkManager/system-connections/repro-" & LinkName &
             ".nmconnection"
    let k = nb.muxRun("stat -c '%a %U %G %F' " & kf & "; cat " & kf)
    step("the keyfile is a root-owned 0600 copy with ipv4.dad-timeout and never-default",
         k.startsWith("600 root root regular file") and
         "dad-timeout=3000" in k and "never-default=true" in k and
         "mac-address=" & nb.parentMac in k, k)
    let l = nb.muxRun("cat " & StateDir & "/addon-ledger")
    step("the ledger records the connection (class network) and the guard binary",
         "\nnetwork\t" & kf in l and "\nguardBinary\t/var/lib/repro/bin/repro" in l,
         l)
    step("no guard unit is left once disarmed", nb.guardUnits().len == 0,
         nb.guardUnits())
    # --- 2. Remove it.
    let log2 = nb.applyUnderGuard(repro, "g2", nb.netProfile(account,
                                                             link = false), step)
    record["applyLog2"] = %log2
    let netC = nb.netState()
    step("removing the object restores the links, addresses and routes",
         netC == netA, netA & "\n=>\n" & netC)
    step("removing the object restores the parent's connection",
         nb.parentConnection() == conn0, nb.parentConnection())
    let fC = g.fingerprintArch(repro, account)
    let idC = identityReport(fA, fC, @[SnapperdActivation])
    step("removing the object restores the fingerprint", idC.ok, idC.text)
    # --- 3. Uninstall.
    nb.stopMux()
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let id = identityReport(f0, g.fingerprintArch(repro, account),
                            @[SnapperdActivation])
    step("base fingerprint after uninstall == before bootstrap", id.ok, id.text)
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

suite Gate:
  test "a network link adds an address and changes nothing of the parent":
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
        if mutation().len > 0:
          failures.add(b.name & ": " & Gate & " has no falsifying mutation")
          continue
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
