## The body the two release-upgrade gates share (milestone A10; spec §7.6,
## §7.9): a guest with the add-on and two store-closure services goes
## through its distribution's documented upgrade -- the gate supplies that
## part -- and must come out with the services active from unchanged store
## paths, downtime bounded by the reboot, and a next plan that reflects the
## new base identity and is accepted by the matrix.
##
## Also a negative control of the matrix, run before the upgrade: with
## ``os-release`` claiming a release the matrix does not list (a bind mount
## over ``/usr/lib/os-release``, removed straight after), ``repro infra
## plan`` must refuse with ``EAddOnUnsupportedBase``. Under the falsifying
## mutation ``base-matrix-unchecked`` that step goes red.
##
## *Mocking.* The negative control's ``os-release`` is a stand-in (a base
## outside the matrix cannot be installed on demand); everything else is
## real (see ``snapshot_mirror.nim``).

import std/[json, os, strutils, times]

import ./addon_testbed
import ./snapshot_mirror
import ./upgrade_support

type
  UpgradeProc* = proc(g: Guest; m: SnapshotMirror;
                      step: proc(name: string; ok: bool; detail: string)): bool
    ## Runs the distribution's upgrade up to (not including) the final
    ## reboot; false when it failed (already recorded as a red step).

proc reportFor(g: Guest; unit: string): string =
  g.run("sha256sum /etc/systemd/system/" & unit & " | cut -d' ' -f1").strip()

proc rebootAndWait*(g: Guest): float =
  ## Reboot the guest (QEMU exits under ``-no-reboot``) and boot the same
  ## disk again; seconds from the reboot to SSH.
  let t0 = epochTime()
  discard g.exec("systemctl reboot", timeoutSec = 30)
  if not g.waitPoweredOff(600):
    raise newException(TestBedError, "the guest did not go down for the reboot")
  g.boot()
  epochTime() - t0

proc runReleaseUpgrade*(m: SnapshotMirror; b: BaseImage; stamp: string;
                        toVersion: string; upgrade: UpgradeProc;
                        record: JsonNode;
                        prepare: proc(g: Guest; m: SnapshotMirror) = nil):
                        seq[string] =
  ## ``prepare`` runs on the base before the add-on is installed (Ubuntu's
  ## upgrader insists on an up-to-date, freshly rebooted release first).
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    m.setTimestamp(stamp)
    record["snapshot"] = %stamp
    let closure = busyboxClosure(m, b)
    g = newMirroredGuest(b, m, diskGiB = 20)
    g.boot()
    g.prepareMirroredBase(m)
    if prepare != nil: prepare(g, m)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    g.seedClosureCache(closure)
    let profile = fixtureProfile(closure)
    let a = g.applyProfile(repro, "fixture", profile)
    step("fixture applied", a.exitCode == 0, a.stdout & a.stderr)
    if a.exitCode != 0: return fails
    step("both services serve", g.serves(WebPort) and g.serves(DocsPort), "")
    let binding = g.closureBinding(FixtureUnits[0])
    let marker = g.run("sha256sum " & binding.parentDir() &
                       "/.repro-apt-closure | cut -d' ' -f1").strip()
    var unitSha: seq[string]
    for u in FixtureUnits: unitSha.add(g.reportFor(u))
    step("the services run from a store closure",
         binding.startsWith("/repro/store/") and marker.len == 64, binding)
    record["closure"] = %binding

    # The plan's release-upgrade checklist (spec §7.9).
    let p0 = g.planProfile(repro, "fixture", profile)
    step("plan: the base is named and the checklist lists the base-coupled " &
         "units only (the re-assert unit's /bin/sh; not the closure services)",
         p0.exitCode == 0 and ("base: " & b.osId & " " & b.versionId) in p0.stdout and
         "base-coupled\trepro-addon-reassert.service" in p0.stdout and
         ("base-coupled\t" & FixtureUnits[0]) notin p0.stdout,
         p0.stdout & p0.stderr)

    # Negative control: a base outside the matrix is refused.
    discard g.run("sed 's/^VERSION_ID=.*/VERSION_ID=\"99\"/' /usr/lib/os-release " &
      "> /root/os-release-99 && mount --bind /root/os-release-99 /usr/lib/os-release")
    let neg = g.planProfile(repro, "fixture", profile)
    discard g.exec("umount /usr/lib/os-release")
    step("negative control: a base outside the matrix is refused " &
         "(EAddOnUnsupportedBase, exit 2)",
         neg.exitCode == 2 and "EAddOnUnsupportedBase" in neg.stderr,
         "exit " & $neg.exitCode & "\n" & neg.stdout & neg.stderr)

    var inv: seq[string]
    for u in FixtureUnits: inv.add(g.serviceState(u).invocation)
    let ok = upgrade(g, m, step)
    if not ok: return fails
    for i, u in FixtureUnits:
      let s = g.serviceState(u)
      step("before the reboot: " & u & " was never stopped by the upgrade",
           s.active == "active" and s.invocation == inv[i],
           s.active & " " & s.invocation & " (before " & inv[i] & ")")
    let rebootSecs = g.rebootAndWait()
    record["rebootToSshSeconds"] = %rebootSecs
    let osr = g.run(". /etc/os-release; echo $ID $VERSION_ID").strip()
    record["after"] = %osr
    step("the guest runs " & toVersion & " after the reboot",
         osr == toVersion, osr)
    # Downtime bounded by the reboot: wanted by multi-user.target, the
    # services are up by the time the guest answers, give or take its
    # start-up.
    let w = g.exec("for i in $(seq 1 60); do systemctl is-active -q " &
      FixtureUnits.join(" ") & " && exit 0; sleep 1; done; exit 1")
    step("both services are active again after the reboot (within 60 s of SSH)",
         w.exitCode == 0, g.exec("systemctl status --no-pager " &
                                 FixtureUnits.join(" ")).stdout)
    step("and serve", g.serves(WebPort) and g.serves(DocsPort), "")
    var unchanged = g.closureBinding(FixtureUnits[0]) == binding and
      g.run("sha256sum " & binding.parentDir() & "/.repro-apt-closure | " &
            "cut -d' ' -f1").strip() == marker
    for i, u in FixtureUnits:
      unchanged = unchanged and g.reportFor(u) == unitSha[i]
    step("from unchanged store paths (unit files, closure binding and its " &
         "marker as before)", unchanged, "")
    let re = g.exec("cat /var/lib/repro/system/addon/reassert-report")
    step("the boot's re-assertion reports ok", "ok" in re.stdout, re.stdout)

    # The next plan: the new base, accepted by the matrix.
    g.setGuestClock(stamp)
    let p1 = g.planProfile(repro, "fixture", profile)
    step("the next plan reflects the new base identity and is accepted",
         p1.exitCode == 0 and ("base: " & toVersion) in p1.stdout and
         "base changed since generation" in p1.stdout and
         "distribution: " in p1.stdout, p1.stdout & p1.stderr)
    let a1 = g.applyProfile(repro, "fixture", profile)
    step("the next apply is accepted", a1.exitCode == 0, a1.stdout & a1.stderr)
    let cur = g.run("readlink /var/lib/repro/system/current").strip()
    let base = g.exec("cat /var/lib/repro/system/generations/" &
                      cur.extractFilename & "/addon-base").stdout
    step("the new generation records the new base",
         ("id\t" & toVersion.split(' ')[0]) in base and
         ("version-id\t" & toVersion.split(' ')[1]) in base, base)
    record["hookEvents"] = %g.hookLogLines()

    # Owner decision (2026-10-31): on a base outside the matrix a rollback
    # is refused like any apply -- it re-plans the saved profile against the
    # current base -- and only a switch's own replay and revert, and
    # uninstall, bypass the matrix.
    discard g.run("sed 's/^VERSION_ID=.*/VERSION_ID=\"99\"/' /usr/lib/os-release " &
      "> /root/os-release-99 && mount --bind /root/os-release-99 /usr/lib/os-release")
    let rb = g.exec(repro & " system rollback", timeoutSec = 1200)
    step("on an unsupported base, rollback is refused (EAddOnUnsupportedBase)",
         rb.exitCode != 0 and "EAddOnUnsupportedBase" in rb.stdout & rb.stderr,
         "exit " & $rb.exitCode & "\n" & rb.stdout & rb.stderr)
    let un = g.exec(repro & " system addon uninstall", timeoutSec = 1800)
    discard g.exec("umount /usr/lib/os-release")
    step("on an unsupported base, uninstall still runs to the end",
         un.exitCode == 0 and g.exec("test -e /var/lib/repro/system/addon-ledger").exitCode != 0,
         "exit " & $un.exitCode & "\n" & un.stdout & un.stderr)
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
