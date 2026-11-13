## Gate ``e2e_arch_addon_bootstrap_uninstall_byte_identity`` (spec
## ReproOS-Add-On-Mode §6.2, §6.4, §12.2, §12.5 condition 1).
##
## A2's ``e2e_addon_bootstrap_uninstall_byte_identity`` sequence on the Arch
## guests: fingerprint the base twice (the determinism guard), preflight,
## bootstrap with the acknowledged digest, apply a generation that adds a
## unit and an ``/etc`` file, apply one that removes the unit and changes
## the file, uninstall, fingerprint again. Every step's fingerprint diff must
## equal the delta the two ledgers account for, and the fingerprints before
## bootstrap and after uninstall must be identical (the add-on creates no
## account; the journal is not fingerprinted; no ``takeOver`` is declared, so
## §6.4's pacman exception does not arise). Each apply runs the pacman
## collision driver, generation 0's included. The fingerprint carries the
## Arch components: ``pacman-local`` and, on the btrfs guest,
## ``btrfs-subvolumes``, which sees ``/repro`` as its own subvolume.
##
## Generation 0 on Arch carries no package-manager hook (spec §6.2, §13
## decision 130): the gate also checks that nothing appeared under
## ``/etc/apt``.
##
## Vacuity guard: ``findmnt -no FSTYPE /`` must be ``btrfs`` on the btrfs
## guest and ``ext4`` on the ext4 guest.
##
## Negative control (``REPRO_ADDON_MUTATION=uninstall-keeps-repro-subvolume``):
## uninstall leaves the ``/repro`` subvolume in place, so the gate must go
## red on the btrfs guest with a diff naming it (``btrfs-subvolumes`` and
## ``addon-roots`` records of ``/repro``). The record says which.
##
## Bases: ``REPRO_ADDON_BASES`` (default ``arch-btrfs-amd64,arch-ext4-amd64``).
## The Omarchy VM joins the matrix when the Arch test bed provides it; its
## leg passes ``--profile`` with the ``omarchyAccount`` and fingerprints the
## account's hook tree (``omarchy-hooks``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_bootstrap_uninstall_byte_identity``).
##
## *Mocking.* None: the real Arch Linux image, real systemd and pacman, the
## real static add-on binary, real disks.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

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
    let guard = g.vacuityGuardRootFs(b)
    step("root filesystem (vacuity guard)", guard.ok, guard.detail)
    if not guard.ok: return fails
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha

    let f0 = g.fingerprintArch(repro)
    sleep(20_000)
    let f0b = g.fingerprintArch(repro)
    let det = identityReport(f0, f0b)
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    step("the fingerprint has pacman-local records",
         "\npacman-local\t" in f0, "no pacman-local component")

    if not g.bootstrapArch(repro, step).ok: return fails
    let l0 = g.ledgerOf()
    let f1 = g.fingerprintArch(repro)
    let d0 = deltaReport(f0, f1, "", l0)
    step("bootstrap diff == generation 0 ledger", d0.ok, d0.text)
    step("generation 0 wrote nothing under /etc/apt",
         g.exec("test -e /etc/apt").exitCode != 0,
         g.exec("ls -la /etc/apt 2>&1").stdout)
    if archVariantOf(b) == avBtrfs:
      step("/repro is a btrfs subvolume",
           g.exec("test \"$(stat -c %i /repro)\" = 256").exitCode == 0,
           g.run("stat -c '%i %F' /repro"))

    let exe = g.gen0ReproExe()
    let a1 = g.applyProfile(repro, "gen1", gen1Profile(exe))
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    let l1 = g.ledgerOf()
    let f2 = g.fingerprintArch(repro)
    let d1 = deltaReport(f1, f2, l0, l1)
    step("generation 1 diff == ledger delta", d1.ok, d1.text)
    step("the fixture unit is active",
         g.exec("systemctl is-active " & FixtureUnitName).exitCode == 0,
         g.exec("systemctl status --no-pager " & FixtureUnitName).stdout)

    let a2 = g.applyProfile(repro, "gen2", gen2Profile())
    step("apply generation 2", a2.exitCode == 0, a2.stdout & a2.stderr)
    if a2.exitCode != 0: return fails
    let l2 = g.ledgerOf()
    let f3 = g.fingerprintArch(repro)
    let d2 = deltaReport(f2, f3, l1, l2)
    step("generation 2 diff == ledger delta", d2.ok, d2.text)

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    let f4 = g.fingerprintArch(repro)
    let ident = identityReport(f0, f4)
    record["finalDiff"] = %ident.text
    step("base fingerprint after uninstall == before bootstrap", ident.ok,
         ident.text)
    if not ident.ok and archVariantOf(b) == avBtrfs:
      record["diffNamesReproSubvolume"] =
        %("btrfs-subvolumes" in ident.text and "repro" in ident.text)
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
      g.destroy()
  fails

suite "e2e_arch_addon_bootstrap_uninstall_byte_identity":
  test "bootstrap, two generations and uninstall leave each Arch base byte-identical":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_addon_bootstrap_uninstall_byte_identity)")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        let record = archGateRecord("e2e_arch_addon_bootstrap_uninstall_byte_identity")
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord(
          "e2e_arch_addon_bootstrap_uninstall_byte_identity", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
