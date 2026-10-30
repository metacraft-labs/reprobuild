## Gate ``e2e_addon_collision_matrix``.
##
## One fixture per row of the add-on's collision decision table, on each
## base of the matrix (Debian 13 and Ubuntu 24.04 by default). For every
## default refusal the apply exits 2 with the typed diagnostic, and the base
## fingerprint afterwards equals the one before: nothing was written. For
## every opt-in the apply succeeds and the fingerprint diff equals exactly
## the delta the two ledgers account for.
##
## Rows:
##
## - **package-owned conffile** (``/etc/ssh/ssh_config``, a dpkg conffile of
##   openssh-client on both bases -- ``/etc/ssh/sshd_config``, the spec's
##   example, is managed by ``ucf`` there and is in no dpkg record):
##   ``EAddOnPackageOwned`` naming the package; ``collision = divert`` moves
##   the package's copy to ``.distrib`` and records the diversion; removal
##   puts it back.
## - **package unit** (``cron.service``; the ``cron`` package is installed
##   before the baseline, Debian 13's cloud image ships none): ``EAddOnUnitShadows`` naming the
##   package's fragment; ``collision = dropIn`` writes a drop-in systemd
##   reports in ``DropInPaths``; ``collision = replace`` makes the /etc
##   unit the one systemd loads (``FragmentPath``), with the package's own
##   enablement link left out of the ledger, ``verify`` reporting the
##   shadowing, and removal handing the unit back to the package with cron
##   still active.
## - **hand-written unit**: an unowned unit whose content differs is
##   ``EDrift``; ``repro system adopt`` claims it as it is, writing nothing;
##   an identical unowned unit is adopted silently; ``--reconcile-drift``
##   replaces the differing one and keeps its bytes; removal restores both.
## - **foreign diversion** (``/etc/issue`` diverted by another package):
##   refused with or without the opt-in.
## - **out of scope**: a path outside the declared managed prefixes is
##   ``EAddOnOutOfScope``.
## - **create / no-op**: an absent unowned path is created, and re-applying
##   is a no-op.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=observer-never-package-owned``):
## an observer that reports no package provenance. The conffile row then
## refuses for the wrong reason (``EDrift``, red), and the package-unit row
## is let through: the apply writes ``/etc/systemd/system/cron.service`` and
## the gate goes red on the refusal and on the fingerprint.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_collision_matrix``).
## Bases: ``REPRO_ADDON_BASES`` (default here: debian-13-amd64,ubuntu-24.04-amd64).
##
## *Mocking.* None: real images, dpkg, systemd and the static add-on binary.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger]

import ./addon_testbed

const
  SshdContent = "Include /etc/ssh/ssh_config.d/*.conf\nHost *\n    SendEnv LANG LC_*\n"
  ConffileRefused = """addOn {
  managedEtcPrefixes = ["/etc/ssh/"]
}

fs.systemFile {
  path = "/etc/ssh/ssh_config"
  content = "$1"
}
"""
  ConffileDiverted = """addOn {
  managedEtcPrefixes = ["/etc/ssh/"]
}

fs.systemFile {
  path = "/etc/ssh/ssh_config"
  content = "$1"
  collision = "divert"
}
"""
  SshOnly = """addOn {
  managedEtcPrefixes = ["/etc/ssh/"]
}
"""
  Empty = """addOn {
  managedEtcPrefixes = []
}
"""
  UnitRefused = """systemd.systemUnit {
  name = "cron.service"
  content = "[Service]
Nice=5
"
}
"""
  UnitDropIn = """systemd.systemUnit {
  name = "cron.service"
  content = "[Service]
Nice=5
"
  collision = "dropIn"
}
"""
  UnitReplace = """systemd.systemUnit {
  name = "cron.service"
  content = "[Unit]
Description=Regular background program processing daemon (Reprobuild add-on replace fixture)

[Service]
ExecStart=/usr/sbin/cron -f
KillMode=process

[Install]
WantedBy=multi-user.target
"
  collision = "replace"
}
"""
  HandUnitV1 = "[Unit]\nDescription=hand-written fixture one\n\n[Service]\nExecStart=/bin/sleep infinity\n"
  HandUnitV2 = "[Unit]\nDescription=hand-written fixture two\n\n[Service]\nExecStart=/bin/sleep infinity\n"
  HandProfile = """systemd.systemUnit {
  name = "repro-fixture-hand.service"
  content = "$1"
  enabled = false
}
"""
  TwoHandProfile = """systemd.systemUnit {
  name = "repro-fixture-hand.service"
  content = "$1"
  enabled = false
}

systemd.systemUnit {
  name = "repro-fixture-hand2.service"
  content = "$2"
  enabled = false
}
"""
  ForeignDiverted = """addOn {
  managedEtcPrefixes = ["/etc/issue"]
}

fs.systemFile {
  path = "/etc/issue"
  content = "ours
"
  collision = "$1"
}
"""
  ForeignNotDiverted = """addOn {
  managedEtcPrefixes = ["/etc/issue"]
}

fs.systemFile {
  path = "/etc/issue"
  content = "ours
"
}
"""
  OutOfScope = """fs.systemFile {
  path = "/etc/motd-repro"
  content = "x
"
}
"""
  Create = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/"]
}

fs.systemFile {
  path = "/etc/repro-fixture/x.conf"
  content = "x
"
}
"""

proc entriesFor(ledgerText, resource: string): seq[LedgerEntry] =
  for e in parseLedger(ledgerText).entries:
    if e.resource == resource: result.add(e)

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
    # The package-unit row needs a package unit: cron (Ubuntu ships it,
    # Debian 13's cloud image does not). Part of the base, before the
    # baseline fingerprint.
    discard g.run("export DEBIAN_FRONTEND=noninteractive; " &
      "apt-get install -y -qq cron >/dev/null", timeoutSec = 1200)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let fBase = g.takeFingerprint(repro)
    sleep(20_000)
    let det = identityReport(fBase, g.takeFingerprint(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if not g.bootstrapAddon(repro, step): return fails
    var f = g.takeFingerprint(repro)
    var l = g.ledgerOf()

    proc refused(name, profile, diagnostic, mustName: string; flags = "") =
      ## A default refusal: exit 2, the diagnostic, nothing written.
      let r = g.applyProfile(repro, name, profile, flags)
      step(name & ": refused with " & diagnostic,
           r.exitCode == 2 and diagnostic in r.stderr and mustName in r.stderr,
           "exit " & $r.exitCode & "\n" & r.stdout & r.stderr)
      let after = g.takeFingerprint(repro)
      let same = identityReport(f, after)
      step(name & ": the refused apply wrote nothing", same.ok and
           g.ledgerOf() == l, same.text)

    proc applied(name, profile: string; flags = ""): string =
      ## An apply that must succeed with a fingerprint diff equal to the
      ## ledger delta. Returns the apply's stdout.
      let r = g.applyProfile(repro, name, profile, flags)
      step(name & ": applied", r.exitCode == 0, r.stdout & r.stderr)
      let after = g.takeFingerprint(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step(name & ": fingerprint diff == ledger delta", d.ok, d.text)
      f = after
      l = l2
      r.stdout

    # --- Row: package-owned conffile. ---
    let sshdBefore = g.sha256InGuest("/etc/ssh/ssh_config")
    step("vacuity guard: openssh-client owns /etc/ssh/ssh_config",
         g.exec("grep -qx /etc/ssh/ssh_config /var/lib/dpkg/info/openssh-client.conffiles").exitCode == 0, "")
    refused("conffile", ConffileRefused % [SshdContent],
            "EAddOnPackageOwned", "openssh-client")
    let planR = g.planProfile(repro, "conffile-plan", ConffileRefused % [SshdContent])
    step("conffile: the plan refuses the same way and writes nothing",
         planR.exitCode == 2 and "EAddOnPackageOwned" in planR.stderr and
         identityReport(f, g.takeFingerprint(repro)).ok, planR.stdout & planR.stderr)
    discard applied("conffile-divert", ConffileDiverted % [SshdContent])
    let distrib = g.sha256InGuest("/etc/ssh/ssh_config.distrib")
    step("conffile-divert: the package's copy is at .distrib, untouched",
         distrib == sshdBefore, "distrib " & distrib & " before " & sshdBefore)
    step("conffile-divert: the add-on's copy is at the path",
         g.run("cat /etc/ssh/ssh_config") == SshdContent, "")
    let dv = entriesFor(l, "dpkgDiversion:/etc/ssh/ssh_config")
    let fe = entriesFor(l, "systemFile:/etc/ssh/ssh_config")
    step("conffile-divert: exactly its ledger entries",
         dv.len == 1 and dv[0].class == lcDiversion and fe.len == 1 and
         fe[0].class == lcEtcFile and fe[0].collision == "divert" and
         fe[0].observation == "conffile:openssh-client",
         "diversion entries " & $dv.len & ", file entries " & $fe.len &
         (if fe.len > 0: " collision=" & fe[0].collision & " observation=" &
          fe[0].observation else: ""))
    step("conffile-divert: dpkg lists the local diversion",
         "local diversion of /etc/ssh/ssh_config to /etc/ssh/ssh_config.distrib" in
           g.run("dpkg-divert --list /etc/ssh/ssh_config"), "")
    discard applied("conffile-remove", SshOnly)
    step("conffile-remove: the package's copy is back and the diversion gone",
         g.sha256InGuest("/etc/ssh/ssh_config") == sshdBefore and
         g.sha256InGuest("/etc/ssh/ssh_config.distrib") == "absent" and
         g.run("dpkg-divert --list /etc/ssh/ssh_config").strip().len == 0, "")

    # --- Row: package unit. ---
    step("vacuity guard: a package provides cron.service",
         "systemd/system/cron.service" in g.run("systemctl show -p FragmentPath cron.service"), "")
    refused("unit", UnitRefused, "EAddOnUnitShadows", "systemd/system/cron.service")
    discard applied("unit-dropin", UnitDropIn)
    let dropIn = "/etc/systemd/system/cron.service.d/50-repro-addon.conf"
    step("unit-dropin: systemd reports the drop-in",
         dropIn in g.run("systemctl show -p DropInPaths cron.service") and
         g.run("cat " & dropIn) == "[Service]\nNice=5\n", "")
    let de = entriesFor(l, "systemUnit:cron.service")
    var hasDropIn = false
    for e in de:
      if e.class == lcDropIn and e.path == dropIn and e.unit == "cron.service":
        hasDropIn = true
    step("unit-dropin: the ledger records the drop-in class", hasDropIn,
         $de.len & " entries")
    discard applied("unit-dropin-remove", Empty)
    step("unit-dropin-remove: the drop-in and its directory are gone, cron active",
         g.exec("test ! -e " & dropIn & " && test ! -e /etc/systemd/system/cron.service.d").exitCode == 0 and
         dropIn notin g.run("systemctl show -p DropInPaths cron.service") and
         g.run("systemctl is-active cron.service").strip() == "active", "")
    discard applied("unit-replace", UnitReplace)
    step("unit-replace: systemd loads the /etc unit, cron stays active",
         g.run("systemctl show -p FragmentPath cron.service").strip() ==
           "FragmentPath=/etc/systemd/system/cron.service" and
         g.run("systemctl is-active cron.service").strip() == "active", "")
    let re = entriesFor(l, "systemUnit:cron.service")
    var replaceOk = false
    var linkLedgered = false
    for e in re:
      if e.class == lcUnit and e.collision == "replace" and
          e.observation.startsWith("unit:"): replaceOk = true
      if e.class == lcInstallLink: linkLedgered = true
    step("unit-replace: ledgered as a replace; the package's own link is not the ledger's",
         replaceOk and not linkLedgered, "")
    let ver = g.exec(repro & " system addon verify")
    step("unit-replace: verify reports the shadowing", "shadows" in ver.stdout,
         ver.stdout & ver.stderr)
    discard applied("unit-replace-remove", Empty)
    step("unit-replace-remove: the package's unit is loaded again, cron active and enabled",
         g.run("systemctl show -p FragmentPath cron.service").strip() !=
           "FragmentPath=/etc/systemd/system/cron.service" and
         g.run("systemctl is-active cron.service").strip() == "active" and
         g.run("systemctl is-enabled cron.service").strip() == "enabled", "")

    # --- Row: hand-written unit. ---
    discard g.putProfile("hand-v1", HandUnitV1)
    discard g.putProfile("hand-v2", HandUnitV2)
    discard g.run("cp /root/addon/hand-v1.profile /etc/systemd/system/repro-fixture-hand.service && " &
                  "cp /root/addon/hand-v1.profile /etc/systemd/system/repro-fixture-hand2.service && " &
                  "systemctl daemon-reload")
    f = g.takeFingerprint(repro)
    refused("hand-drift", HandProfile % [HandUnitV2], "EDrift", "repro-fixture-hand.service")
    let ad = g.adoptResource(repro, "hand-adopt", HandProfile % [HandUnitV2],
                             "systemUnit:repro-fixture-hand.service")
    step("hand-adopt: adopted, nothing written", ad.exitCode == 0 and
         g.run("cat /etc/systemd/system/repro-fixture-hand.service") == HandUnitV1,
         ad.stdout & ad.stderr)
    block:
      let after = g.takeFingerprint(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step("hand-adopt: fingerprint diff == ledger delta (no change)", d.ok, d.text)
      let he = entriesFor(l2, "systemUnit:repro-fixture-hand.service")
      step("hand-adopt: the ledger owns it with its bytes preserved",
           he.len == 1 and he[0].collision == "adopt" and he[0].preserved.len > 0 and
           he[0].sha256 == sha256Hex(HandUnitV1), $he.len)
      f = after
      l = l2
    let pl = g.planProfile(repro, "hand-two", TwoHandProfile % [HandUnitV1, HandUnitV1])
    step("hand-two: the plan adopts the identical unowned unit silently",
         pl.exitCode == 0 and "adopt\t/etc/systemd/system/repro-fixture-hand2.service" in pl.stdout and
         identityReport(f, g.takeFingerprint(repro)).ok, pl.stdout & pl.stderr)
    discard applied("hand-two", TwoHandProfile % [HandUnitV1, HandUnitV1])
    # Owned now: a changed profile is an update, not drift...
    discard applied("hand-update", TwoHandProfile % [HandUnitV2, HandUnitV1])
    step("hand-update: the owned unit was updated",
         g.run("cat /etc/systemd/system/repro-fixture-hand.service") == HandUnitV2, "")
    # ...and an out-of-band edit of an owned object is drift.
    let fOwned = f
    discard g.run("cp /root/addon/hand-v1.profile /etc/systemd/system/repro-fixture-hand.service")
    f = g.takeFingerprint(repro)
    refused("hand-two-drift", TwoHandProfile % [HandUnitV2, HandUnitV1], "EDrift",
            "repro-fixture-hand.service")
    # Reconciling puts the host back where the ledger describes it; the
    # ledger-derived delta cannot know about the out-of-band edit, so the
    # comparison is with the fingerprint from when the add-on last owned
    # the object as written.
    let rc = g.applyProfile(repro, "hand-reconcile",
                            TwoHandProfile % [HandUnitV2, HandUnitV1], " --reconcile-drift")
    step("hand-reconcile: applied", rc.exitCode == 0, rc.stdout & rc.stderr)
    f = g.takeFingerprint(repro)
    l = g.ledgerOf()
    let back = identityReport(fOwned, f)
    step("hand-reconcile: the host is back in the ledger's state", back.ok, back.text)
    step("hand-reconcile: replaced, the out-of-band bytes preserved",
         g.run("cat /etc/systemd/system/repro-fixture-hand.service") == HandUnitV2 and
         g.exec("test -f /var/lib/repro/system/addon/preserved/" & sha256Hex(HandUnitV1)).exitCode == 0, "")
    discard applied("hand-remove", Empty)
    step("hand-remove: both units restored to their pre-add-on bytes",
         g.run("cat /etc/systemd/system/repro-fixture-hand.service") == HandUnitV1 and
         g.run("cat /etc/systemd/system/repro-fixture-hand2.service") == HandUnitV1, "")
    discard g.run("rm /etc/systemd/system/repro-fixture-hand.service " &
                  "/etc/systemd/system/repro-fixture-hand2.service && systemctl daemon-reload")
    f = g.takeFingerprint(repro)

    # --- Row: foreign diversion. ---
    discard g.run("dpkg-divert --package repro-fixture-foreign --divert /etc/issue.foreign --rename --add /etc/issue")
    f = g.takeFingerprint(repro)
    refused("foreign-diversion", ForeignDiverted % ["divert"], "already diverted", "repro-fixture-foreign")
    refused("foreign-diversion-no-optin", ForeignNotDiverted,
            "already diverted", "repro-fixture-foreign")
    discard g.run("dpkg-divert --package repro-fixture-foreign --rename --remove /etc/issue")
    f = g.takeFingerprint(repro)

    # --- Row: out of scope. ---
    refused("out-of-scope", OutOfScope, "EAddOnOutOfScope", "/etc/motd-repro")

    # --- Row: create, then no-op. ---
    discard applied("create", Create)
    let again = applied("create-again", Create)
    step("create-again: a no-op", "no-op\t/etc/repro-fixture/x.conf" in again, again)
    discard applied("create-remove", Empty)

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let ident = identityReport(fBase, g.takeFingerprint(repro))
    step("base fingerprint after uninstall == before bootstrap", ident.ok, ident.text)
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

suite "e2e_addon_collision_matrix":
  test "every row of the decision table refuses or opts in as specified":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_collision_matrix)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_collision_matrix",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_collision_matrix", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
