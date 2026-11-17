## Gate ``e2e_omarchy_addon_root_snapshot_rollback`` (milestone AR4; spec
## ReproOS-Add-On-Mode §5.1, §7.2, §7.7, §8.5; §13 decision 90).
##
## On the Omarchy VM, with ``addOn { rootSnapshot = "required" }``:
##
## 1. Generations 1 and 2 are applied. Each apply takes its own snapper
##    snapshot of ``/`` before its first write; the one generation 2's
##    apply took is read from generation 2's generation log
##    (``addon.root-snapshot`` ... ``snapper:root#<n>`` ...
##    ``repro-addon=<key>``) and checked against snapper's own list.
## 2. **The snapshot boots generation 1.** The next boot is pointed at that
##    snapshot the way Omarchy's boot menu offers it -- the entry
##    limine-snapper-sync generated for it, made the default
##    (``arch_gate_support.bootSnapshotNext``) -- and the guest is rebooted.
##    After the boot: the kernel was given the snapshot as its root;
##    ``/etc`` and ``/var/lib/repro`` are at generation 1 together (the
##    fixture file reads generation 1's bytes, ``current`` names generation
##    1 and ``/etc/repro/static`` its tree); ``/repro/store`` is not rolled
##    back (generation 2's tree is in it: the store is its own subvolume,
##    which ``repro.mount`` mounts by path, spec §5.1); generation 1's unit
##    is active; and the re-assert unit reports ``ok``. The boot loader is
##    then put back and the guest rebooted into its own root.
## 3. **A GC that collects generation 1's closures.** Generation 3 is
##    applied with ``--keep-generations 0 --keep-days 0`` (retention keeps
##    the current and the previous generation, 3 and 2, and drops 1), and
##    ``repro store gc`` collects generation 1's static tree. Generation 2's
##    snapshot is still there (generation 2 is retained).
## 4. **The same snapshot now boots degraded.** Booted again, the re-assert
##    unit reports ``degraded``, naming the missing store object, and the
##    base still reaches ``multi-user.target`` and answers over SSH.
##
## Then the boot loader is put back, the guest booted into its own root,
## and the add-on uninstalled: no ``repro-addon`` snapshot is left and the
## base fingerprint equals the baseline's -- taken after a reboot of its own
## -- but for what two boots differ in (``arch_gate_support.RebootVariance``)
## and whether snapper's D-Bus service is up (``SnapperdActivation``).
##
## Every boot of a snapshot is Omarchy's own: the snapshot is read-only and
## ``omarchy-snapshot-overlay`` mounts a tmpfs overlay over it, so nothing
## the snapshot boot writes survives it.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is ``omarchy-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_omarchy_addon_root_snapshot_rollback``).
##
## *Mocking.* None: the real Omarchy VM, its snapper, snapperd,
## limine-snapper-sync and Limine, real reboots, and the real static add-on
## binary.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const Gate = "e2e_omarchy_addon_root_snapshot_rollback"

proc reassertReport(g: Guest): string =
  ## The re-assert unit's report of this boot (it writes its rendering to
  ## the state directory and the journal).
  discard g.waitReasserted()
  g.exec("cat /var/lib/repro/system/addon/reassert-report 2>/dev/null; " &
         "journalctl -b -o cat --no-pager -u repro-addon-reassert.service " &
         "| grep 'repro-addon reassert:'").stdout

proc reboot(g: Guest) =
  discard g.exec("systemctl reboot", timeoutSec = 30)
  discard g.waitPoweredOff(300)
  g.boot()

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let account = accountFor(b)
    # The baseline after a reboot of its own, so the first boot's one-shot
    # units are behind it, as they are behind every later boot.
    g.reboot()
    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro, account)
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
    let exe = g.gen0ReproExe()
    proc profile(n: int): string =
      rootSnapshotStanza("required", account) & fixtureUnit(exe) & "\n" &
        fixtureFile("fixture = " & $n & "\n")
    # --- 1. Generations 1 and 2, each with its snapshot.
    var gens, trees: seq[string]
    for n in 1 .. 2:
      let r = g.applyProfile(repro, "g" & $n, profile(n))
      step("generation " & $n & ": applied, taking its root snapshot",
           r.exitCode == 0 and "root snapshot taken: root#" in r.stdout,
           r.stdout & r.stderr)
      gens.add(g.currentGeneration())
      trees.add(g.run("readlink /etc/repro/static").strip())
    let s2 = g.loggedSnapshot(gens[1])
    record["generations"] = %gens
    record["snapshotOfGeneration2"] = %*{"number": s2.number, "key": s2.key}
    var listed = false
    for r in g.addonRows():
      if r.number == s2.number and r.userdata == "repro-addon=" & s2.key and
          r.cleanup == "":
        listed = true
    step("generation 2's log names its snapshot, which snapper lists with " &
         "the add-on's userdata and no cleanup algorithm",
         s2.number > 0 and s2.key.len == 32 and listed,
         $s2 & "\n" & g.run("snapper -c root list"))
    let s2ownedBy = g.run(repro & " system addon root-snapshots")
    step("generation 2 owns it", ("root#" & $s2.number & " repro-addon=" &
         s2.key & " owner=generation " & gens[1]) in s2ownedBy, s2ownedBy)
    # --- 2. Boot it: generation 1, the store whole, ok.
    let bl = g.bootSnapshotNext(s2.number)
    step("the next boot is the snapshot's own boot entry", bl.ok, bl.detail)
    g.reboot()
    step("booted the snapshot", g.bootedSubvol() ==
         "/@/.snapshots/" & $s2.number & "/snapshot", g.run("cat /proc/cmdline"))
    let rep1 = g.reassertReport()
    step("snapshot boot: /etc is at generation 1",
         g.run("cat " & FixtureFile) == "fixture = 1\n",
         g.exec("cat " & FixtureFile).stdout)
    step("snapshot boot: /var/lib/repro is at generation 1, /etc/repro/static too",
         g.currentGeneration() == gens[0] and
           g.run("readlink /etc/repro/static").strip() == trees[0],
         g.currentGeneration() & " " & g.run("readlink /etc/repro/static"))
    step("snapshot boot: /repro/store is not rolled back (generation 2's tree is there)",
         g.exec("test -d " & trees[1] & " && test -d " & trees[0]).exitCode == 0,
         g.exec("findmnt /repro; findmnt /repro/store; ls -d " & trees[1]).stdout)
    step("snapshot boot: generation 1's unit is active",
         g.exec("systemctl is-active " & FixtureUnitName).exitCode == 0,
         g.exec("systemctl status --no-pager " & FixtureUnitName).stdout)
    step("snapshot boot: the re-assert unit reports ok",
         "repro-addon reassert: ok" in rep1, rep1)
    g.restoreBootLoader()
    g.reboot()
    step("booted the host's own root again", g.bootedSubvol() in ["@", "/@"] and
         g.currentGeneration() == gens[1], g.run("cat /proc/cmdline"))
    # --- 3. A GC that collects generation 1's closures.
    let r3 = g.applyProfile(repro, "g3", profile(3),
                            " --keep-generations 0 --keep-days 0")
    step("generation 3 (retention keeps 3 and 2 only): applied", r3.exitCode == 0,
         r3.stdout & r3.stderr)
    let gc = g.run(repro & " store gc --grace-seconds 0")
    step("gc collected generation 1's tree, generation 2's is kept",
         g.exec("test ! -e " & trees[0] & " && test -d " & trees[1]).exitCode == 0,
         gc)
    step("generation 2's snapshot is still there",
         s2.number in numbersOf(g.addonRows()), g.run("snapper -c root list"))
    # --- 4. The same snapshot, degraded; the base still boots.
    let bl2 = g.bootSnapshotNext(s2.number)
    step("the next boot is the snapshot again", bl2.ok, bl2.detail)
    g.reboot()
    step("booted the snapshot again", g.bootedSubvol() ==
         "/@/.snapshots/" & $s2.number & "/snapshot", g.run("cat /proc/cmdline"))
    let rep2 = g.reassertReport()
    step("after the GC: the re-assert unit reports degraded, naming the missing store object",
         "repro-addon reassert: degraded" in rep2 and trees[0] in rep2, rep2)
    step("after the GC: the base reaches multi-user.target and answers over SSH",
         g.exec("systemctl is-active multi-user.target").stdout.strip() == "active",
         g.exec("systemctl list-units --failed --no-pager").stdout)
    g.restoreBootLoader()
    g.reboot()
    step("booted the host's own root at the end", g.bootedSubvol() in ["@", "/@"],
         g.run("cat /proc/cmdline"))
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    step("uninstall left no repro-addon snapshot", g.addonRows().len == 0,
         g.run("snapper -c root list"))
    let ident = identityReport(f0, g.fingerprintArch(repro, account),
                               @RebootVariance & @[SnapperdActivation])
    step("base fingerprint after uninstall == before bootstrap (but what " &
         "two boots differ in)", ident.ok, ident.text)
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

suite Gate:
  test "a root snapshot boots its generation with the store whole, and degraded after a GC":
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
