## Gate ``e2e_addon_revert_keeps_earlier_drift`` (spec §7.5, §4.3;
## reprobuild-pm issue
## 2026-10-31-addon-revert-of-a-failed-switch-refuses-drift-the-switch-did-not-cause).
##
## A switch that fails after its flip, before it writes its ledger, is
## reverted automatically, also when a file it accepted without writing
## (rpi2's caches.conf: its agent wrote the profile's bytes outside the
## switch) disagrees with the previous generation's ledger.
##
## 1. Generation 1 takes over /etc/repro/caches.conf with bytes A (§9,
##    supersede), and owns a link-form file a.conf.
## 2. caches.conf is changed by hand to B, and the next profile declares B
##    (accepted without a write), rewrites a.conf and adds new.conf.
## 3. That switch fails after its flip, in its post-write steps, before it
##    writes its ledger (a failure injected once by the
##    `switch-fails-before-ledger` build; a crash or any exception there
##    leaves the same state).
##
## The revert must succeed: no pending marker stays, new.conf goes, a.conf
## is generation 1's again, and caches.conf carries generation 1's bytes.
## Before the revert, the failed switch is replayed record-only, so the
## revert plans from a ledger that knows what it wrote. At f25f69eda0 and
## at 49370cf2f2 (with the same injection) the revert planned from the old
## ledger. It refused caches.conf (f25f69eda0) or the rewritten link-form
## a.conf (49370cf2f2) as drift, and left the host pending.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and
## ``REPRO_ADDON_MUTATION=switch-fails-before-ledger``. Without the
## mutation the failure cannot be injected, and the gate skips with that
## reason. *Mocking:* none beyond the injected failure: a real guest and
## the static add-on binary.

import std/[json, os, strutils, times, unittest]

import repro_infra
import repro_test_support/reasoned_skip

import ./addon_testbed

const
  Gate = "e2e_addon_revert_keeps_earlier_drift"
  CachesConf = "/etc/repro/caches.conf"
  Fx = "/etc/repro-revert-fixture/"
  Trigger = "/var/tmp/repro-addon-fail-before-ledger"

proc fileResource(path, content: string): string =
  "fs.systemFile {\n  path = " & quoteSystemValue(path) & "\n  content = " &
    quoteSystemValue(content) & "\n}\n\n"

proc profile(caches: string; extra = false; aConf = "a = 1\n"): string =
  "addOn {\n  managedEtcPrefixes = [\"" & Fx & "\"]\n}\n\n" &
    fileResource(Fx & "a.conf", aConf) &
    fileResource(CachesConf, caches) &
    (if extra: fileResource(Fx & "new.conf", "new = 1\n") else: "")

proc currentGeneration(g: Guest): string =
  extractFilename(g.run("readlink /var/lib/repro/system/current").strip())

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
    let caches0 = g.run("cat " & CachesConf)
    let a = caches0 & "# A: the profile's\n"
    let bBytes = caches0 & "# B: written outside the switch\n"
    var r = g.applyProfile(repro, "one", profile(a))
    let gen1 = g.currentGeneration()
    step("generation 1 takes caches.conf over with A",
         r.exitCode == 0 and g.run("cat " & CachesConf) == a,
         r.stdout & r.stderr)
    writeFile(g.runDir / "b", bBytes)
    g.copyTo(g.runDir / "b", CachesConf)
    discard g.run("touch " & Trigger)
    # The failed switch also rewrites a.conf, a file the ledger owns: its
    # own write, which the revert must undo.
    r = g.applyProfile(repro, "two", profile(bBytes, extra = true,
                                             aConf = "a = 2\n"))
    let out2 = r.stdout & r.stderr
    step("the failed switch is reverted automatically",
         r.exitCode != 0 and ("rolled back to " & gen1) in out2 and
         "could not be rolled back" notin out2 and
         g.exec("test ! -e /var/lib/repro/system/addon/pending").exitCode == 0,
         out2 & "\npending:\n" &
         g.exec("cat /var/lib/repro/system/addon/pending").stdout)
    step("the failed switch's new file is gone",
         g.exec("test ! -e " & Fx & "new.conf").exitCode == 0, "")
    step("a file the failed switch rewrote is generation 1's again",
         g.run("cat " & Fx & "a.conf") == "a = 1\n",
         g.exec("cat " & Fx & "a.conf").stdout)
    step("caches.conf carries generation 1's bytes again",
         g.run("cat " & CachesConf) == a, g.exec("cat " & CachesConf).stdout)
    r = g.exec(repro & " system addon verify")
    step("and verify finds no drift",
         r.exitCode == 0 and "drift" notin r.stdout, r.stdout & r.stderr)
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
  test "a switch that fails before its ledger is recorded, then reverted":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1")
    elif mutation() != "switch-fails-before-ledger":
      skip("needs REPRO_ADDON_MUTATION=switch-fails-before-ledger to " &
           "inject the failure")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "mutation": mutation(),
          "reprobuild": gitHead(), "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
