## Gate ``e2e_addon_bootstrap_uninstall_byte_identity``.
##
## On each base of the matrix, in a disposable guest: fingerprint the base,
## preflight, bootstrap with the acknowledged plan digest, apply a
## generation that adds a unit, an ``/etc`` file and a diversion of a
## package-owned file, apply one that removes the unit and the ``/etc``
## file, uninstall, and fingerprint again. The two base fingerprints must be
## equal, with no exception needed (the add-on creates no account; the
## journal is not part of the fingerprint). Between the steps, every
## fingerprint diff must equal the delta the ledgers account for -- which is
## what makes this a test of the ledger as well as of uninstall.
##
## Before the comparison means anything, the base must fingerprint the same
## twice in a row (the determinism guard): a volatile record the
## fingerprint failed to exclude would otherwise show up as an add-on
## difference.
##
## Two more steps before the uninstall: an apply declaring a kind the add-on
## does not manage (``linux.sysctl``) must be refused with nothing written,
## no generation committed; and an uninstall that meets drift (a tampered
## ledger file) must fail, keep the object and the ledger copy, and
## complete once the object is restored.
##
## Negative control: with ``REPRO_ADDON_MUTATION=uninstall-skips-diversion-removal``
## the run uses the add-on binary built with that mutation; this gate must
## then FAIL, with a diff naming the diversion of ``/etc/issue.net``. Two
## more mutations: ``apply-skips-kind-check`` (the sysctl is applied and
## left behind) and ``uninstall-discards-state-on-drift`` (the ledger is
## gone after the failed uninstall, so the second one cannot run).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_bootstrap_uninstall_byte_identity``).
## Bases: ``REPRO_ADDON_BASES`` (default: the amd64 matrix). Backend:
## ``REPRO_ADDON_BACKEND=incus`` for the inner loop.
##
## *Mocking.* None: real distribution images, real systemd, dpkg and apt,
## the real static add-on binary, real disks.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed

const Gen1Profile = """addOn {
  managedEtcPrefixes = ["/etc/repro-addon-fixture/", "/etc/issue.net"]
}

systemd.systemUnit {
  name = "repro-addon-fixture.service"
  content = "[Unit]
Description=Reprobuild add-on test fixture service

[Service]
ExecStart=/bin/sleep infinity

[Install]
WantedBy=repro-addon.target
"
  enabled = true
}

fs.systemFile {
  path = "/etc/repro-addon-fixture/fixture.conf"
  content = "fixture = 1
"
}

linux.dpkgDiversion {
  path = "/etc/issue.net"
}

fs.systemFile {
  path = "/etc/issue.net"
  content = "Managed by the Reprobuild add-on test fixture.
"
  depends_on = ["linux.dpkgDiversion:/etc/issue.net"]
}
"""

const UnmanagedKindProfile = """linux.sysctl {
  key = "net.ipv4.ip_forward"
  value = "1"
}
"""

const Gen2Profile = """addOn {
  managedEtcPrefixes = ["/etc/repro-addon-fixture/", "/etc/issue.net"]
}

linux.dpkgDiversion {
  path = "/etc/issue.net"
}

fs.systemFile {
  path = "/etc/issue.net"
  content = "Managed by the Reprobuild add-on test fixture.
"
  depends_on = ["linux.dpkgDiversion:/etc/issue.net"]
}
"""

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  ## Run the whole sequence on one base. Returns the failures (empty when
  ## the gate is green for this base).
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

    let f0 = g.takeFingerprint(repro)
    sleep(20_000)
    let f0b = g.takeFingerprint(repro)
    let det = identityReport(f0, f0b)
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails

    let anchors = g.installAnchors()
    let pre = g.exec(repro & " system addon preflight" & anchors.flags)
    step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
    if pre.exitCode != 0: return fails
    let digest = planDigestOf(pre.stdout)
    let boot = g.exec(repro & " system addon bootstrap --plan " & digest & anchors.flags)
    step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
    if boot.exitCode != 0: return fails
    let l0 = g.ledgerOf()
    let f1 = g.takeFingerprint(repro)
    let d0 = deltaReport(f0, f1, "", l0)
    step("bootstrap diff == generation 0 ledger", d0.ok, d0.text)

    writeFile(g.runDir / "gen1.profile", Gen1Profile)
    g.copyTo(g.runDir / "gen1.profile", "/root/addon/gen1.profile")
    let a1 = g.exec(repro & " infra apply --profile /root/addon/gen1.profile")
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    let l1 = g.ledgerOf()
    let f2 = g.takeFingerprint(repro)
    let d1 = deltaReport(f1, f2, l0, l1)
    step("generation 1 diff == ledger delta", d1.ok, d1.text)

    writeFile(g.runDir / "gen2.profile", Gen2Profile)
    g.copyTo(g.runDir / "gen2.profile", "/root/addon/gen2.profile")
    let a2 = g.exec(repro & " infra apply --profile /root/addon/gen2.profile")
    step("apply generation 2", a2.exitCode == 0, a2.stdout & a2.stderr)
    if a2.exitCode != 0: return fails
    let l2 = g.ledgerOf()
    let f3 = g.takeFingerprint(repro)
    let d2 = deltaReport(f2, f3, l1, l2)
    step("generation 2 diff == ledger delta", d2.ok, d2.text)

    # A kind the add-on does not manage is refused before anything is
    # written: the fingerprint, the ledger and `current` are unchanged.
    writeFile(g.runDir / "gen3.profile", UnmanagedKindProfile)
    g.copyTo(g.runDir / "gen3.profile", "/root/addon/gen3.profile")
    let cur2 = g.run("cat /var/lib/repro/system/current 2>/dev/null || readlink /var/lib/repro/system/current").strip()
    let a3 = g.exec(repro & " infra apply --profile /root/addon/gen3.profile")
    # (incus exec merges the guest's stderr into stdout; ssh keeps them apart.)
    let a3Out = a3.stdout & a3.stderr
    step("an unmanaged kind is refused", a3.exitCode != 0 and
         "linux.sysctl" in a3Out and "nothing was applied" in a3Out,
         "exit " & $a3.exitCode & "\n" & a3.stdout & a3.stderr)
    let f3b = g.takeFingerprint(repro)
    let unchanged = identityReport(f3, f3b)
    step("the refused apply wrote nothing", unchanged.ok, unchanged.text)
    let cur3 = g.run("cat /var/lib/repro/system/current 2>/dev/null || readlink /var/lib/repro/system/current").strip()
    step("the refused apply committed no generation", cur2 == cur3 and
         g.ledgerOf() == l2, "current " & cur2 & " -> " & cur3)

    # An uninstall that meets drift leaves the object AND the ledger, and
    # fails; once the object is restored a second uninstall completes.
    discard g.run("cp -p /etc/profile.d/repro-addon.sh /root/addon/profile.d.orig && " &
                  "echo '# tampered' >> /etc/profile.d/repro-addon.sh")
    let unDrift = g.exec(repro & " system addon uninstall")
    let ledgerKept = g.exec("test -f /var/lib/repro/system/addon-ledger").exitCode == 0
    let fileKept = g.exec("grep -q tampered /etc/profile.d/repro-addon.sh").exitCode == 0
    step("uninstall with drift fails, keeps the object and the ledger",
         unDrift.exitCode == 1 and ledgerKept and fileKept and
         "repro-addon.sh" in unDrift.stdout,
         unDrift.stdout & unDrift.stderr & "\nledger kept: " & $ledgerKept &
         " file kept: " & $fileKept)
    # The kept ledger describes what is still owned: the objects the first
    # uninstall did undo (the diversion, the units) are no longer in it.
    let kept = g.exec("cat /var/lib/repro/system/addon-ledger").stdout
    step("the kept ledger lists only what is still owned",
         "\ndiversion\t" notin kept and "repro-addon.target" notin kept and
         "repro-addon.sh" in kept, kept)
    discard g.run("cp -p /root/addon/profile.d.orig /etc/profile.d/repro-addon.sh")

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let f4 = g.takeFingerprint(repro)
    let ident = identityReport(f0, f4)
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)
    for (n, t) in [("f0", f0), ("f1", f1), ("f2", f2), ("f3", f3), ("f4", f4),
                   ("l0", l0), ("l1", l1), ("l2", l2)]:
      writeFile(g.runDir / (n & ".txt"), t)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      let keep = getEnv("REPRO_ADDON_KEEP_ARTIFACTS")
      if keep.len > 0 and dirExists(g.runDir):
        let dest = keep / g.name
        createDir(keep)
        for f in walkFiles(g.runDir / "*.txt"):
          createDir(dest)
          copyFile(f, dest / extractFilename(f))
        if fileExists(g.serialLog):
          createDir(dest)
          copyFile(g.serialLog, dest / "serial.log")
      g.destroy()
  fails

suite "e2e_addon_bootstrap_uninstall_byte_identity":
  test "bootstrap, two generations and uninstall leave the base byte-identical":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_addon_bootstrap_uninstall_byte_identity)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{
          "gate": "e2e_addon_bootstrap_uninstall_byte_identity",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_bootstrap_uninstall_byte_identity",
                                     record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
