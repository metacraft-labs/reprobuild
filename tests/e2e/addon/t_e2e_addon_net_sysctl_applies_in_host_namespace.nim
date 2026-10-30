## Gate ``e2e_addon_net_sysctl_applies_in_host_namespace``.
##
## A generation setting ``net.ipv4.ip_forward`` and ``net.core.somaxconn``
## is applied from inside a transient unit with ``PrivateNetwork=yes``
## (what the agent's apply unit will be, spec §9.1; here ``systemd-run``
## stands in for it). ``net.*`` keys are per network namespace, so a
## ``sysctl -w`` from there would set a throwaway namespace's copy; the
## switch applies the fragments by restarting the host's own
## ``systemd-sysctl.service`` and observes the values by a transient unit
## in the host's namespaces (spec §7.2 step 6, threat model G35). The gate
## reads the host's values over SSH afterwards: they changed, and the
## values the apply reports as observed equal them. Removing the resources
## restores the base values.
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
