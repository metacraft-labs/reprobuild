## Gate ``e2e_arch_addon_removal_respects_ledger`` (spec ReproOS-Add-On-Mode
## §4.2, §12.5 condition 1).
##
## The Debian gate ``e2e_addon_removal_respects_ledger`` unchanged on the
## Arch guests: the same sequence (``removal_respects_ledger_sequence``),
## the same steps and assertions -- an object leaving the profile is removed
## only when the ledger lists it with its recorded digest, a modified one is
## kept as drift until ``--reconcile-drift``, a same-named file the ledger
## never listed is left by every generation and by uninstall, and an
## operator's link over a copy-form object is drift -- with the pacman
## collision driver deciding every apply. What differs is only the guest:
## the Arch test bed's (``newArchGuest``, ``prepareArchGuest``), whose
## fingerprint carries ``pacman-local`` (and ``btrfs-subvolumes`` on the
## btrfs root), the baseline step before the first fingerprint
## (``settleBaseline``; §12.2, §13 decision 134), and the Arch preflight
## and bootstrap (``bootstrapArch``).
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_removal_respects_ledger``).
##
## *Mocking.* None: real Arch guests, real systemd and pacman, the real
## static add-on binary.

import std/[json, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support
import ./removal_respects_ledger_sequence

const Gate = "e2e_arch_addon_removal_respects_ledger"

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
    g.settleBaseline(step)
    let guest = g
    runRemovalSequence(g, repro, step,
      fingerprint = proc(): string = guest.fingerprintArch(repro),
      bootstrap = proc(): bool = guest.bootstrapArch(repro, step).ok)
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
  test "removal deletes only what the ledger lists with a matching digest, on Arch":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif mutation().len > 0:
      # The Debian gate has no falsifier of its own, and this one runs it
      # unchanged, so it has none either.
      echo "FAIL ", Gate, " has no falsifier named ", mutation()
      check false
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the plain Arch " &
            "guests only (an Omarchy profile must name its account)")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
