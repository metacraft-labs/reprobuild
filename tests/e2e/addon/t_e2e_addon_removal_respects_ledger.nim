## Gate ``e2e_addon_removal_respects_ledger``.
##
## The ledger is the only answer to "may this be removed?" (spec §4.2):
##
## - an object that leaves the profile is removed only when the ledger lists
##   it with its recorded digest (``a.conf``);
## - a modified one is left in place as actionable drift -- the apply
##   reports it, exits 1, and the ledger keeps the entry -- until
##   ``--reconcile-drift`` authorises the removal, which preserves the
##   current bytes (``b.conf``);
## - a same-named file the ledger does not list is never removed: ``c.conf``
##   is declared in a generation whose fetch of it fails (the switch is
##   rolled back to the previous generation, so the ledger has no entry for
##   it), then hand-written; the next generations leave it alone, and so
##   does uninstall.
## - a copy-form object (a tmpfiles fragment) that an operator replaced
##   with a symbolic link of their own is drift, not a missing object: when
##   it leaves the profile the link is left in place (exit 1, the ledger
##   keeps the entry) and its target is untouched.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just e2e_addon_removal_respects_ledger``).
##
## *Mocking.* None.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./removal_respects_ledger_sequence

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
    let guest = g
    runRemovalSequence(g, repro, step,
      fingerprint = proc(): string = guest.takeFingerprint(repro),
      bootstrap = proc(): bool = guest.bootstrapAddon(repro, step))
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

suite "e2e_addon_removal_respects_ledger":
  test "removal deletes only what the ledger lists with a matching digest":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_removal_respects_ledger)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_removal_respects_ledger",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_removal_respects_ledger", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
