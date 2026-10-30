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
## - **package-owned conffile**, twice: ``/etc/ssh/sshd_config`` (the spec's
##   example; on Debian 13 and Ubuntu 24.04 openssh-server manages it through
##   ``ucf``, so it is in no dpkg record and the observer's fourth record,
##   ucf's registry, is what owns it) and ``/etc/ssh/ssh_config`` (a plain
##   dpkg conffile of openssh-client): ``EAddOnPackageOwned`` naming the
##   package; ``collision = divert`` moves the package's copy to ``.distrib``
##   and records the diversion; removal puts it back.
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
## - **unowned file that differs** (``/etc/repro-fixture/h.conf``, written by
##   hand): ``EDrift``; ``repro system adopt`` claims it as it is; a second
##   such file is replaced by ``--reconcile-drift`` with its bytes
##   preserved; removal restores both.
## - **foreign local diversion** (``/etc/issue`` diverted by hand to
##   ``/etc/issue.distrib``, the very name the add-on would use): refused,
##   because a diversion the ledger does not list is someone else's whatever
##   its target is called.
## - **drop-in for a unit nothing provides**: refused.
## - **out of scope**: a path outside the declared managed prefixes is
##   ``EAddOnOutOfScope``.
## - **uninstall with a replaced and an adopted unit still in the profile**
##   (``cron.service`` replaced; ``fixture-base.service``, a
##   hand-written unit the base had enabled and active, adopted): both are
##   enabled and active afterwards, from the base's files, and the
##   fingerprint equals the base's.
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
  SshContent = "Include /etc/ssh/ssh_config.d/*.conf\nHost *\n    SendEnv LANG LC_*\n"
  SshdContent = "Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin prohibit-password\n"
  ConffileRefused = """addOn {
  managedEtcPrefixes = ["/etc/ssh/"]
}

fs.systemFile {
  path = "$1"
  content = "$2"
}
"""
  ConffileDiverted = """addOn {
  managedEtcPrefixes = ["/etc/ssh/"]
}

fs.systemFile {
  path = "$1"
  content = "$2"
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
  BaseUnit = "[Unit]\nDescription=base fixture the add-on adopts\n\n[Service]\nExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"
  FinalProfile = """systemd.systemUnit {
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

systemd.systemUnit {
  name = "fixture-base.service"
  content = "$1"
}
"""
  FilesPrefix = """addOn {
  managedEtcPrefixes = ["/etc/repro-fixture/"]
}
"""
  FileH = FilesPrefix & """
fs.systemFile {
  path = "/etc/repro-fixture/h.conf"
  content = "$1"
}
"""
  FilesHR = FilesPrefix & """
fs.systemFile {
  path = "/etc/repro-fixture/h.conf"
  content = "$1"
}

fs.systemFile {
  path = "/etc/repro-fixture/r.conf"
  content = "$2"
}
"""
  ForeignLocalDiverted = """addOn {
  managedEtcPrefixes = ["/etc/issue"]
}

fs.systemFile {
  path = "/etc/issue"
  content = "ours
"
  collision = "divert"
}
"""
  DropInNothing = """systemd.systemUnit {
  name = "repro-fixture-nothing.service"
  content = "[Service]
Nice=5
"
  collision = "dropIn"
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
    # A hand-written unit the base has enabled and active: the adoption
    # and uninstall rows below must hand it back exactly so.
    writeFile(g.runDir / "base.unit", BaseUnit)
    # Not `repro-*`: preflight refuses a pre-bootstrap `repro-*` unit as a
    # foreign occupant (spec §6.1); this one stands for an operator's own.
    g.copyTo(g.runDir / "base.unit", "/etc/systemd/system/fixture-base.service")
    discard g.run("chmod 0644 /etc/systemd/system/fixture-base.service && " &
      "systemctl daemon-reload && systemctl enable --now fixture-base.service")
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

    # --- Rows: package-owned conffiles (a dpkg conffile, a ucf-managed file). ---
    proc conffileRows(path, pkg, content, observation, guard: string) =
      let before = g.sha256InGuest(path)
      let tag = extractFilename(path)
      step("vacuity guard: " & pkg & " owns " & path & " (" & observation & ")",
           g.exec(guard).exitCode == 0, "")
      refused(tag & "-conffile", ConffileRefused % [path, content],
              "EAddOnPackageOwned", pkg)
      let planR = g.planProfile(repro, tag & "-conffile-plan", ConffileRefused % [path, content])
      step(tag & "-conffile: the plan refuses the same way and writes nothing",
           planR.exitCode == 2 and "EAddOnPackageOwned" in planR.stderr and
           identityReport(f, g.takeFingerprint(repro)).ok, planR.stdout & planR.stderr)
      discard applied(tag & "-conffile-divert", ConffileDiverted % [path, content])
      let distrib = g.sha256InGuest(path & ".distrib")
      step(tag & "-conffile-divert: the package's copy is at .distrib, untouched",
           distrib == before, "distrib " & distrib & " before " & before)
      step(tag & "-conffile-divert: the add-on's copy is at the path",
           g.run("cat " & path) == content, "")
      let dv = entriesFor(l, "dpkgDiversion:" & path)
      let fe = entriesFor(l, "systemFile:" & path)
      step(tag & "-conffile-divert: exactly its ledger entries",
           dv.len == 1 and dv[0].class == lcDiversion and fe.len == 1 and
           fe[0].class == lcEtcFile and fe[0].collision == "divert" and
           fe[0].observation == observation,
           "diversion entries " & $dv.len & ", file entries " & $fe.len &
           (if fe.len > 0: " collision=" & fe[0].collision & " observation=" &
            fe[0].observation else: ""))
      step(tag & "-conffile-divert: dpkg lists the local diversion",
           ("local diversion of " & path & " to " & path & ".distrib") in
             g.run("dpkg-divert --list " & path), "")
      discard applied(tag & "-conffile-remove", SshOnly)
      step(tag & "-conffile-remove: the package's copy is back and the diversion gone",
           g.sha256InGuest(path) == before and
           g.sha256InGuest(path & ".distrib") == "absent" and
           g.run("dpkg-divert --list " & path).strip().len == 0, "")
    conffileRows("/etc/ssh/ssh_config", "openssh-client", SshContent,
      "conffile:openssh-client",
      "grep -qx /etc/ssh/ssh_config /var/lib/dpkg/info/openssh-client.conffiles")
    conffileRows("/etc/ssh/sshd_config", "openssh-server", SshdContent,
      "ucf:openssh-server",
      "grep -Eq 'openssh-server[[:space:]]+/etc/ssh/sshd_config$' /var/lib/ucf/registry && " &
      "! grep -rqx /etc/ssh/sshd_config /var/lib/dpkg/info/openssh-server.list " &
      "/var/lib/dpkg/info/openssh-server.conffiles")

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
    discard g.exec("rm -f /etc/systemd/system/repro-fixture-hand.service " &
                   "/etc/systemd/system/repro-fixture-hand2.service; systemctl daemon-reload")
    f = g.takeFingerprint(repro)

    # --- Rows: unowned files that differ (EDrift, adopt, reconcile). ---
    discard g.run("mkdir -p /etc/repro-fixture && printf 'theirs\n' > /etc/repro-fixture/h.conf")
    f = g.takeFingerprint(repro)
    refused("file-drift", FileH % ["ours\n"], "EDrift", "/etc/repro-fixture/h.conf")
    let fa = g.adoptResource(repro, "file-adopt", FileH % ["ours\n"],
                             "systemFile:/etc/repro-fixture/h.conf")
    step("file-adopt: adopted as it is, nothing written", fa.exitCode == 0 and
         g.run("cat /etc/repro-fixture/h.conf") == "theirs\n", fa.stdout & fa.stderr)
    block:
      let after = g.takeFingerprint(repro)
      let l2 = g.ledgerOf()
      let d = deltaReport(f, after, l, l2)
      step("file-adopt: fingerprint diff == ledger delta (no change)", d.ok, d.text)
      let he = entriesFor(l2, "systemFile:/etc/repro-fixture/h.conf")
      step("file-adopt: owned with its bytes preserved", he.len == 1 and
           he[0].collision == "adopt" and he[0].preserved.len > 0, $he.len)
      f = after
      l = l2
    discard g.run("printf 'theirs2\n' > /etc/repro-fixture/r.conf")
    f = g.takeFingerprint(repro)
    refused("file-r-drift", FilesHR % ["theirs\n", "ours2\n"], "EDrift", "/etc/repro-fixture/r.conf")
    discard applied("file-reconcile", FilesHR % ["theirs\n", "ours2\n"], " --reconcile-drift")
    step("file-reconcile: replaced, old bytes preserved",
         g.run("cat /etc/repro-fixture/r.conf") == "ours2\n" and
         g.exec("test -f /var/lib/repro/system/addon/preserved/" & sha256Hex("theirs2\n")).exitCode == 0, "")
    discard applied("file-remove", FilesPrefix)
    step("file-remove: both files restored to their pre-add-on bytes",
         g.run("cat /etc/repro-fixture/h.conf") == "theirs\n" and
         g.run("cat /etc/repro-fixture/r.conf") == "theirs2\n", "")
    discard g.exec("rm -r /etc/repro-fixture")
    f = g.takeFingerprint(repro)

    # --- Row: a foreign LOCAL diversion to the name the add-on would use. ---
    discard g.run("dpkg-divert --local --rename --divert /etc/issue.distrib --add /etc/issue")
    f = g.takeFingerprint(repro)
    refused("foreign-local-diversion", ForeignLocalDiverted, "already diverted", "/etc/issue.distrib")
    # Cleanup that must not end the run when a red row left the host in
    # another state: a later row is still worth its verdict.
    discard g.exec("dpkg-divert --local --rename --remove /etc/issue")
    f = g.takeFingerprint(repro)

    # --- Row: a drop-in for a unit nothing provides. ---
    refused("dropin-nothing", DropInNothing, "provides", "repro-fixture-nothing.service")

    # --- Row: foreign diversion. ---
    discard g.run("dpkg-divert --package repro-fixture-foreign --divert /etc/issue.foreign --rename --add /etc/issue")
    f = g.takeFingerprint(repro)
    refused("foreign-diversion", ForeignDiverted % ["divert"], "already diverted", "repro-fixture-foreign")
    refused("foreign-diversion-no-optin", ForeignNotDiverted,
            "already diverted", "repro-fixture-foreign")
    discard g.exec("dpkg-divert --package repro-fixture-foreign --rename --remove /etc/issue")
    f = g.takeFingerprint(repro)

    # --- Row: out of scope. ---
    refused("out-of-scope", OutOfScope, "EAddOnOutOfScope", "/etc/motd-repro")

    # --- Row: create, then no-op. ---
    discard applied("create", Create)
    let again = applied("create-again", Create)
    step("create-again: a no-op", "no-op\t/etc/repro-fixture/x.conf" in again, again)
    discard applied("create-remove", Empty)

    # --- Uninstall with a replaced and an adopted unit in the profile. ---
    discard applied("final", FinalProfile % [BaseUnit])
    step("final: cron is replaced and the base unit adopted",
         g.run("systemctl show -p FragmentPath cron.service").strip() ==
           "FragmentPath=/etc/systemd/system/cron.service" and
         entriesFor(l, "systemUnit:fixture-base.service").len >= 1, "")
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    # `is-enabled` / `is-active` exit non-zero for "disabled" / "inactive":
    # the answer is the verdict, not a transport failure.
    let states = g.exec("systemctl is-enabled cron.service; systemctl is-active cron.service; " &
      "systemctl is-enabled fixture-base.service; systemctl is-active fixture-base.service")
    step("uninstall handed both units back enabled and active",
         states.stdout.splitLines()[0 .. 3] == @["enabled", "active", "enabled", "active"] and
         g.exec("cat /etc/systemd/system/fixture-base.service").stdout == BaseUnit,
         states.stdout)
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
