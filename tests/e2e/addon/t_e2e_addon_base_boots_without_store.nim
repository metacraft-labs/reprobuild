## Gate ``e2e_addon_base_boots_without_store`` (milestone A5; spec §7.6 row
## "Store unreadable or deleted", §7.7).
##
## With the add-on bootstrapped and a generation running a fixture service,
## the store is taken away and the guest rebooted, twice:
##
## 1. ``/repro/store`` is deleted (its read-only bind mount stopped first).
##    systemd re-creates a missing mount point, so at the next boot
##    ``repro-store.mount`` binds an EMPTY ``/repro/store`` read-only and
##    succeeds (measured on Debian 13): the store is gone, its mount is not
##    failed.
## 2. The mount point cannot be re-created either (``/repro`` made
##    immutable), so ``repro-store.mount`` FAILS -- the state of a host whose
##    store filesystem is gone.
##
## Before that, the re-assert unit's other promise (threat model T27): it
## never re-applies. An out-of-band edit of a managed file survives a
## reboot untouched, and the unit reports ``drift`` naming it.
##
## After each boot without the store:
##
## - the guest reaches ``multi-user.target`` and accepts key-authenticated
##   SSH (every check below runs over it, as root with the run's key);
## - the re-assert unit ran and reported ``degraded``;
## - no BASE unit failed: every failed unit is one of the add-on's (the
##   ledger's units -- the store mount and the fixture service cannot work
##   without the store, and are allowed to fail).
##
## Falsifying mutation ``reassert-required-by-boot`` (``REPRO_ADDON_MUTATION``):
## the re-assert unit is wanted by ``multi-user.target`` and ``Requires=``
## the store mount, so when the store mount fails (pass 2) the unit fails
## as a dependency before it can run -- no ``degraded`` report. The gate
## must go red. (In pass 1 the mount succeeds, so the mutation cannot bite
## there; that is why pass 2 exists.)
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``. QEMU only: it reboots a disk.
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import repro_addon/ledger

import ./addon_testbed

const
  Service = "[Unit]\nDescription=fixture that outlives nothing\n[Service]\n" &
    "ExecStart=/bin/sleep infinity\n\n[Install]\nWantedBy=multi-user.target\n"

proc profile(): string =
  "addOn {\n  managedEtcPrefixes = [\"/etc/repro-fixture/\"]\n}\n\n" &
    "systemd.systemUnit {\n  name = \"repro-fixture-nostore.service\"\n" &
    "  content = \"" & Service & "\"\n}\n\n" &
    "fs.systemFile {\n  path = \"/etc/repro-fixture/nostore.conf\"\n" &
    "  content = \"read through the store\n\"\n}\n"

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
    let r = g.applyProfile(repro, "nostore", profile())
    step("generation applied", r.exitCode == 0, r.stdout & r.stderr)
    # The add-on's units, from the ledger: the only ones allowed to fail.
    var addonUnits: seq[string]
    for e in parseLedger(g.ledgerOf()).entries:
      if e.class == lcUnit and e.unit.len > 0: addonUnits.add(e.unit)
    record["addonUnits"] = %addonUnits
    # Vacuity guard: with the store present nothing has failed and the
    # re-assert unit reports ok (so `degraded` below is about the store).
    discard g.exec("systemctl reboot", timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    let j0 = g.waitReasserted()
    step("vacuity guard: with the store, the re-assert unit reports ok",
         "repro-addon reassert: ok" in j0, j0)
    # Never re-applied: a hand edit survives the boot and is reported.
    discard g.run("rm /etc/repro-fixture/nostore.conf && " &
                  "printf 'edited by hand\\n' > /etc/repro-fixture/nostore.conf; sync")
    discard g.exec("systemctl reboot", timeoutSec = 30)
    discard g.waitPoweredOff(300)
    g.boot()
    let jd = g.waitReasserted()
    step("drift: the re-assert unit reports drift naming the edited file",
         "repro-addon reassert: drift" in jd and
           "/etc/repro-fixture/nostore.conf" in jd, jd)
    step("drift: the hand edit was not undone",
         g.run("cat /etc/repro-fixture/nostore.conf") == "edited by hand\n", "")
    proc rebootWithoutStore(pass: string; expectMountFailed: bool) =
      discard g.exec("systemctl reboot", timeoutSec = 30)
      discard g.waitPoweredOff(300)
      let t0 = epochTime()
      g.boot()                       # waits for key-authenticated SSH
      let sshAfter = epochTime() - t0
      record[pass & ".sshSecondsAfterBoot"] = %sshAfter
      step(pass & ": SSH accepted a key-authenticated session", true,
           $sshAfter & " s after QEMU started")
      discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                     timeoutSec = 600)
      step(pass & ": multi-user.target is active",
           g.exec("systemctl is-active multi-user.target").stdout.strip() == "active",
           g.exec("systemctl list-jobs --no-pager").stdout)
      let mountState = g.exec("systemctl is-failed repro-store.mount").stdout.strip()
      step(pass & ": the store mount is " &
           (if expectMountFailed: "failed" else: "not failed") &
           " (the scenario holds)",
           (mountState == "failed") == expectMountFailed, mountState)
      let journal = g.waitReasserted()
      step(pass & ": the re-assert unit reported degraded",
           "repro-addon reassert: degraded" in journal, journal)
      let failed = g.exec("systemctl list-units --failed --plain --no-legend " &
                          "--no-pager --full").stdout
      var baseFailed: seq[string]
      for line in failed.splitLines():
        let f = line.strip().splitWhitespace()
        if f.len == 0: continue
        let u = f[0].strip(chars = {'*', ' '})
        if u.len > 0 and u notin addonUnits: baseFailed.add(u)
      step(pass & ": no base unit failed", baseFailed.len == 0,
           "failed units:\n" & failed & "\nnot the add-on's: " & $baseFailed)
    # 1. Delete the store and reboot.
    discard g.run("systemctl stop repro-store.mount; rm -rf /repro/store; sync")
    step("deleted: the store is gone", g.exec("test ! -e /repro/store").exitCode == 0, "")
    rebootWithoutStore("deleted", expectMountFailed = false)
    # 2. The mount point cannot come back either: the store mount fails.
    discard g.run("systemctl stop repro-store.mount; rmdir /repro/store; " &
                  "chattr +i /repro; sync")
    step("unmountable: /repro/store is gone and cannot be re-created",
         g.exec("test ! -e /repro/store && ! mkdir /repro/store 2>/dev/null").exitCode == 0, "")
    rebootWithoutStore("unmountable", expectMountFailed = true)
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

suite "e2e_addon_base_boots_without_store":
  test "with the store deleted the base boots, accepts SSH and the add-on reports degraded":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_base_boots_without_store)")
    elif useIncus():
      skip("a reboot without the store is of a disk image; QEMU only")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_base_boots_without_store",
          "base": b.name, "arch": b.debArch, "backend": "qemu",
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_base_boots_without_store", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
