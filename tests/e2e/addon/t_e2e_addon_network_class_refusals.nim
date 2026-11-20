## Gate ``e2e_addon_network_class_refusals`` (milestone AR5; spec
## ReproOS-Add-On-Mode §4.4, §4.5, §8.5; §13 decisions 12, 101, 120;
## threat model G52).
##
## On the Omarchy VM (NetworkManager), each item §4.5 lists as not
## declarable -- a gateway, DHCP on the link, a parent setting, a global
## DNS server, a global search domain, a dependency on a foreign
## connection -- an address already on the host and a link name in use are
## each refused at plan time, by an apply, and nothing is written: no
## marker, no snapshot, the fingerprint and the host's links, addresses and
## routes unchanged. With inactive ``/etc/systemd/network/*.network`` files
## present (as on ``arch``) a link still plans; with both NetworkManager
## and systemd-networkd active it is refused, naming §13 decision 12 and
## the observed services. An ``fs.systemFile`` under
## ``/etc/NetworkManager/system-connections/`` inside a declared managed
## prefix is refused before anything is written (threat model G52).
##
## On a systemd-networkd Arch guest (``arch-ext4-amd64``), any
## ``linux.networkLink`` is refused at plan time with
## ``EAddOnOutOfScope`` naming §13 decision 12 and the active service.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_network_class_refusals``).
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./network_gate_support

const Gate = "e2e_addon_network_class_refusals"

proc refusedNothingWritten(g: Guest; repro, name, text: string;
                           want: openArray[string]): tuple[ok: bool; detail: string] =
  let r = g.applyProfile(repro, name, text)
  let output = r.stdout & r.stderr
  var ok = r.exitCode != 0
  for w in want:
    if w notin output: ok = false
  let leftover = g.exec("test -e " & MarkerPath & " || test -e " & StateDir &
    "/addon/guard-record || [ -n \"$(ls -A " & StateDir &
    "/addon/pending.d 2>/dev/null)\" ]").exitCode
  ok = ok and leftover != 0
  (ok, "exit " & $r.exitCode & "\n" & output)

proc omarchyLeg(b: BaseImage; record: JsonNode; step: StepFn) =
  var nb: NetBed
  try:
    nb = newNetBed()
    nb.bootNetBed(step)
    let g = nb.om
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let account = accountFor(b)
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    let n0 = nb.netState()
    let ownAddr = g.run("ip -4 -o addr show dev " & nb.parent &
                        " | awk '{print $4}' | head -1").strip()
    let gs = guardStanza(account, oob = nb.oob).replace("PARENT", nb.parent)
    proc link(extra = ""; name = LinkName; address = LinkAddr;
              dns = true): string =
      gs & linkStanza(nb.parentMac, name = name, address = address,
                      extra = extra, dns = dns)
    for (what, text, want) in [
        ("a gateway", link("  gateway = \"" & HelperLanAddr & "\"\n"),
         @["EAddOnOutOfScope", "linux.networkLink.gateway"]),
        ("DHCP on the link", link("  dhcp = \"true\"\n"),
         @["EAddOnOutOfScope", "linux.networkLink.dhcp"]),
        ("a parent setting (MTU)", link("  parentMtu = \"1400\"\n"),
         @["EAddOnOutOfScope", "linux.networkLink.parentMtu"]),
        ("a global DNS server", link(dns = false) .replace("  addresses",
           "  dnsServers = [\"" & HelperLanAddr & "\"]\n  addresses"),
         @["EAddOnOutOfScope", "linux.networkLink.globalDnsServers"]),
        ("a global search domain", link().replace("\"~home.arpa\"",
           "\"~home.arpa\", \"lan\""),
         @["EAddOnOutOfScope", "linux.networkLink.searchDomains"]),
        ("a dependency on a foreign connection",
         link("  dependsOnConnection = \"Wired connection 2\"\n"),
         @["EAddOnOutOfScope", "linux.networkLink.dependsOnConnection"]),
        ("an address already on the host", link(address = ownAddr),
         @["EAddOnOutOfScope", "already on the host"]),
        ("a link name in use", link(name = "lo"),
         @["EAddOnOutOfScope", "in use on the host"])]:
      let r = refusedNothingWritten(g, repro, "refuse", text, want)
      step("refused at plan time, nothing written: " & what, r.ok, r.detail)
    # Inactive networkd files do not decide the manager (spec §4.5).
    discard g.run("mkdir -p /etc/systemd/network && printf '[Match]\\n" &
      "Name=en*\\n\\n[Network]\\nDHCP=yes\\n' > /etc/systemd/network/" &
      "20-repro-gate-ethernet.network")
    let p = g.planProfile(repro, "plan-link", link())
    step("with inactive /etc/systemd/network files present, the link plans",
         p.exitCode == 0 and "network: will probe" in p.stdout,
         p.stdout & p.stderr)
    discard g.run("rm -f /etc/systemd/network/20-repro-gate-ethernet.network")
    # Both managers active: refused, naming the services.
    discard g.run("systemctl start systemd-networkd.service")
    let both = refusedNothingWritten(g, repro, "both", link(),
      @["EAddOnOutOfScope", "decision 12", "systemd-networkd.service active"])
    step("with both NetworkManager and systemd-networkd active, refused",
         both.ok, both.detail)
    discard g.run("systemctl stop systemd-networkd.service " &
      "systemd-networkd.socket systemd-networkd-varlink.socket " &
      "systemd-networkd-resolve-hook.socket 2>/dev/null; true")
    # The class directory (G52).
    let fsFile = refusedNothingWritten(g, repro, "fs-file",
      "addOn {\n  managedEtcPrefixes = [\"/etc/NetworkManager/\"]\n" &
      "  omarchyAccount = \"" & account & "\"\n}\n\nfs.systemFile {\n" &
      "  path = \"/etc/NetworkManager/system-connections/x.nmconnection\"\n" &
      "  content = \"[connection]\nid=x\n\"\n}\n",
      @["/etc/NetworkManager/system-connections/"])
    step("an fs.systemFile under the connection directory inside a declared " &
         "managed prefix is refused (G52)", fsFile.ok, fsFile.detail)
    g.settleBaseline(step)
    let id = identityReport(f0, g.fingerprintArch(repro, account),
      @[SnapperdActivation, "active-units:systemd-networkd*",
        "unit-files:systemd-networkd*"])
    step("nothing was written: the fingerprint is unchanged", id.ok, id.text)
    let n1 = nb.netState()
    step("nothing was written: links, addresses and routes unchanged",
         n1 == n0, n0 & "\n=>\n" & n1)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  finally:
    if nb != nil:
      record["guest"] = %nb.om.name
      record["log"] = %(nb.om.log & nb.helper.log)
      nb.destroy()

proc networkdLeg(b: BaseImage; record: JsonNode; step: StepFn) =
  var g: Guest
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let st = g.run("systemctl is-active NetworkManager.service " &
                   "systemd-networkd.service; true")
    step("the guest runs systemd-networkd, not NetworkManager",
         st.splitLines()[1] == "active", st)
    if not g.bootstrapArch(repro, step).ok: return
    let iface = g.run("ip -4 -o addr show | awk '/10\\.0\\.2\\./{print $2}' | " &
                      "head -1").strip()
    let mac = g.run("cat /sys/class/net/" & iface & "/address").strip()
    let text = "addOn {\n  managedEtcPrefixes = [\"" & FixturePrefix &
      "\"]\n  networkGuard {\n    keep = [\"" & iface & " 10.0.2.0/24\"]\n" &
      "  }\n}\n\n" & linkStanza(mac, address = "10.0.2.77/24", dns = false)
    let r = refusedNothingWritten(g, repro, "networkd", text,
      @["EAddOnOutOfScope", "decision 12", "systemd-networkd.service active"])
    step("any linux.networkLink is refused on a systemd-networkd host, naming " &
         "decision 12 and the active service", r.ok, r.detail)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  finally:
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()

suite Gate:
  test "what the network class may not declare, and where it may not run, is refused":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b0 in selectedArchBases():
        let b = b0
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        if mutation().len > 0:
          failures.add(b.name & ": " & Gate & " has no falsifying mutation")
          continue
        let steps = newJArray()
        var fails: seq[string]
        proc step(name: string; ok: bool; detail: string) =
          steps.add(%*{"step": name, "ok": ok, "detail": detail})
          if not ok: fails.add(b.name & ": " & name & ": " & detail)
        try:
          if isOmarchyBase(b):
            record["omarchy"] = omarchyRecordBase()
            omarchyLeg(b, record, step)
          else:
            networkdLeg(b, record, step)
        except CatchableError as e:
          fails.add(b.name & ": " & e.msg)
          steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
        record["steps"] = steps
        record["verdict"] = %(if fails.len == 0: "green" else: "red")
        echo "record: ", writeRecord(Gate, record)
        failures.add(fails)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
