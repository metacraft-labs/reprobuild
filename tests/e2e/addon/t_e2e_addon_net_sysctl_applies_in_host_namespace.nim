## Gate ``e2e_addon_net_sysctl_applies_in_host_namespace``.
##
## A generation setting ``net.ipv4.ip_forward`` and ``net.core.somaxconn``
## is applied from inside a transient unit with ``PrivateNetwork=yes``
## (what the agent's apply unit will be, spec §9.1; here ``systemd-run``
## stands in for it). ``net.*`` keys are per network namespace, so a
## ``sysctl -w`` from there would set a throwaway namespace's copy; the
## switch applies each changed fragment by the host's own
## ``systemd-sysctl <fragment>``, run as a transient unit in the host's
## namespaces, and observes the values the same way (spec §7.2 step 6,
## threat model G35). The gate reads the host's values over SSH
## afterwards: they changed, and the values the apply reports as observed
## equal them. Removing the resources restores the base values.
##
## Boot-time precedence (spec §4.3, §7.2 step 6): a base fragment that
## sorts after the add-on's ``90-repro-*`` (here ``99-zz-repro-fixture.conf``)
## or ``/etc/sysctl.conf`` assigning one of the keys another value would
## put that value back at every boot; the plan refuses the resource
## (exit 2), naming the file, and nothing is written. So is a forwarding
## key while systemd-networkd is in use and configured (here globally, in
## ``networkd.conf.d``) to write forwarding itself with another value
## (the same value is not refused), and so is a per-link key of a link
## networkd manages; the record notes whether the base runs networkd and
## which link it manages.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=sysctl-in-apply-namespace``):
## the switch runs ``systemd-sysctl`` on the fragments in the apply's own
## namespaces; the host's values stay as they were: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_net_sysctl_applies_in_host_namespace``).
## Bases: ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: a real kernel, systemd and the static add-on binary.

import std/[json, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Profile = """addOn {
  managedEtcPrefixes = []
}

linux.sysctl {
  key = "net.ipv4.ip_forward"
  value = "1"
}

linux.sysctl {
  key = "net.core.somaxconn"
  value = "8192"
}
"""
  Empty = "addOn {\n  managedEtcPrefixes = []\n}\n"

proc observedLines(output: string): seq[(string, string)] =
  ## The `sysctl observed (host namespaces):` section of an apply.
  var inSection = false
  for line in output.splitLines():
    if line.startsWith("sysctl observed"):
      inSection = true
      continue
    if not inSection: continue
    if not line.startsWith("  "):
      inSection = false
      continue
    let f = line[2 .. ^1].split('\t')
    if f.len == 2: result.add((f[0], f[1]))

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    let fwdBefore = g.run("cat /proc/sys/net/ipv4/ip_forward").strip()
    let somaxBefore = g.run("cat /proc/sys/net/core/somaxconn").strip()
    step("vacuity guard: the base values differ from the generation's",
         fwdBefore != "1" and somaxBefore != "8192",
         "ip_forward " & fwdBefore & " somaxconn " & somaxBefore)
    let f0 = g.takeFingerprint(repro)
    let l0 = g.ledgerOf()
    let p = g.putProfile("sysctl", Profile)
    # The apply, confined like the agent's apply unit will be.
    let ap = g.exec("systemd-run --quiet --wait --pipe --collect " &
      "-p PrivateNetwork=yes " & repro & " infra apply --profile " & p,
      timeoutSec = 1200)
    step("apply inside PrivateNetwork=yes", ap.exitCode == 0, ap.stdout & ap.stderr)
    let fwd = g.run("cat /proc/sys/net/ipv4/ip_forward").strip()
    let somax = g.run("cat /proc/sys/net/core/somaxconn").strip()
    step("the host's values changed (read over SSH)",
         fwd == "1" and somax == "8192", "ip_forward " & fwd & " somaxconn " & somax)
    let obs = observedLines(ap.stdout)
    step("the apply's observed values equal the host's",
         obs.len == 2 and ("net.ipv4.ip_forward", fwd) in obs and
         ("net.core.somaxconn", somax) in obs, $obs & "\n" & ap.stdout)
    step("the fragments are links into the static tree under 90-repro-",
         g.run("readlink /etc/sysctl.d/90-repro-net-ipv4-ip_forward.conf").strip() ==
           "/etc/repro/static/sysctl.d/90-repro-net-ipv4-ip_forward.conf", "")
    let f1 = g.takeFingerprint(repro)
    let l1 = g.ledgerOf()
    let d1 = deltaReport(f0, f1, l0, l1)
    step("fingerprint diff == ledger delta (the sysctl values included)", d1.ok, d1.text)
    # Removal restores the base values, through the same confined apply.
    let pe = g.putProfile("empty", Empty)
    let rm = g.exec("systemd-run --quiet --wait --pipe --collect " &
      "-p PrivateNetwork=yes " & repro & " infra apply --profile " & pe,
      timeoutSec = 1200)
    step("removal applied inside PrivateNetwork=yes", rm.exitCode == 0, rm.stdout & rm.stderr)
    step("the host's values are back to the base's",
         g.run("cat /proc/sys/net/ipv4/ip_forward").strip() == fwdBefore and
         g.run("cat /proc/sys/net/core/somaxconn").strip() == somaxBefore, "")
    let d2 = deltaReport(f1, g.takeFingerprint(repro), l1, g.ledgerOf())
    step("fingerprint diff == ledger delta after removal", d2.ok, d2.text)
    # A base assignment applied after the add-on's fragment: refused.
    let fb = g.takeFingerprint(repro)
    discard g.run("printf 'net.core.somaxconn = 1234\\n' > /etc/sysctl.d/99-zz-repro-fixture.conf")
    let late = g.applyProfile(repro, "sysctl-late", Profile)
    step("a later base fragment assigning the key refuses the plan (exit 2), naming it",
         late.exitCode == 2 and "99-zz-repro-fixture.conf" in late.stderr and
         "net.core.somaxconn" in late.stderr, "exit " & $late.exitCode & "\n" & late.stdout & late.stderr)
    discard g.run("rm -f /etc/sysctl.d/99-zz-repro-fixture.conf")
    discard g.run("if [ -e /etc/sysctl.conf ]; then cp -a /etc/sysctl.conf /root/sysctl.conf.repro-bak; fi; " &
      "printf 'net.ipv4.ip_forward = 0\\n' >> /etc/sysctl.conf")
    let conf = g.applyProfile(repro, "sysctl-conf", Profile)
    step("an /etc/sysctl.conf assignment of the key refuses the plan (exit 2), naming it",
         conf.exitCode == 2 and "/etc/sysctl.conf" in conf.stderr and
         "net.ipv4.ip_forward" in conf.stderr, "exit " & $conf.exitCode & "\n" & conf.stdout & conf.stderr)
    discard g.run("if [ -e /root/sysctl.conf.repro-bak ]; then mv /root/sysctl.conf.repro-bak /etc/sysctl.conf; " &
      "else rm -f /etc/sysctl.conf; fi")
    # A runtime writer: networkd configured (globally, networkd.conf.d) to
    # set forwarding itself. Refused while networkd is enabled or running;
    # on a base without networkd the setting configures nothing and the
    # plan is not refused (the record says which).
    let networkdInUse = g.exec("systemctl is-active --quiet systemd-networkd.service || " &
      "systemctl is-enabled --quiet systemd-networkd.service").exitCode == 0
    record["networkdInUse"] = %networkdInUse
    discard g.run("mkdir -p /etc/systemd/networkd.conf.d && printf '[Network]\\nIPv4Forwarding=no\\n' " &
      "> /etc/systemd/networkd.conf.d/99-repro-fixture.conf")
    let nwd = g.planProfile(repro, "sysctl-networkd", Profile)
    if networkdInUse:
      step("networkd configured to write forwarding refuses the forwarding key (exit 2), naming the setting",
           nwd.exitCode == 2 and "IPv4Forwarding=no" in nwd.stderr and
           "net.ipv4.ip_forward" in nwd.stderr, "exit " & $nwd.exitCode & "\n" & nwd.stdout & nwd.stderr)
    else:
      step("without networkd in use its configuration refuses nothing",
           nwd.exitCode == 0, "exit " & $nwd.exitCode & "\n" & nwd.stdout & nwd.stderr)
    # The same family with the add-on's value is no conflict.
    discard g.run("printf '[Network]\\nIPv4Forwarding=yes\\n' " &
      "> /etc/systemd/networkd.conf.d/99-repro-fixture.conf")
    let same = g.planProfile(repro, "sysctl-networkd-same", Profile)
    step("networkd setting the same forwarding value refuses nothing",
         same.exitCode == 0, "exit " & $same.exitCode & "\n" & same.stdout & same.stderr)
    # A per-link key of a link networkd manages: networkd rewrites it.
    let managedLink = g.run("networkctl list --no-legend 2>/dev/null | " &
      "awk '$5==\"configured\" && $2!=\"lo\" {print $2; exit}'; true").strip()
    record["networkdManagedLink"] = %managedLink
    if networkdInUse and managedLink.len > 0:
      let perLink = "addOn {\n  managedEtcPrefixes = []\n}\n\nlinux.sysctl {\n" &
        "  key = \"net.ipv6.conf." & managedLink & ".accept_ra\"\n  value = \"0\"\n}\n"
      let pl = g.planProfile(repro, "sysctl-networkd-link", perLink)
      step("a per-link key of a link networkd manages is refused (exit 2), naming the link",
           pl.exitCode == 2 and ("manages " & managedLink) in pl.stderr,
           "exit " & $pl.exitCode & "\n" & pl.stdout & pl.stderr)
    discard g.run("rm -rf /etc/systemd/networkd.conf.d/99-repro-fixture.conf; " &
      "rmdir /etc/systemd/networkd.conf.d 2>/dev/null; true")
    let ib = identityReport(fb, g.takeFingerprint(repro))
    step("the refused plans wrote nothing", ib.ok, ib.text)
    step("the host's values are still the base's",
         g.run("cat /proc/sys/net/ipv4/ip_forward").strip() == fwdBefore and
         g.run("cat /proc/sys/net/core/somaxconn").strip() == somaxBefore, "")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_addon_net_sysctl_applies_in_host_namespace":
  test "net.* sysctls applied from a private network namespace reach the host":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_net_sysctl_applies_in_host_namespace)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_net_sysctl_applies_in_host_namespace",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_net_sysctl_applies_in_host_namespace", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
