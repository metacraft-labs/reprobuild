## Gate ``e2e_arch_addon_store_placement_by_root_fs`` (spec
## ReproOS-Add-On-Mode §5.1, §6.4).
##
## On the btrfs guest ``/repro`` is its own subvolume (inode 256 on btrfs,
## listed by ``btrfs subvolume list``); a snapshot of ``/`` taken after a
## generation is realised contains none of ``/repro/store`` (a nested
## subvolume appears in its parent's snapshot as an empty directory). On the
## ext4 guest ``/repro`` is a plain directory. The same generation sequence
## produces the same ledgers on both (compared after the store paths, which
## carry no root-filesystem identity, and the timestamps are taken out).
## Uninstall removes either form (``/repro`` absent afterwards).
##
## The snapshot is a read-only btrfs snapshot of ``/`` made with
## ``btrfs subvolume snapshot -r`` -- what snapper makes for a configuration
## of ``/`` (the plain Arch guests have no snapper configured) -- and the
## gate deletes it again before uninstalling.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=repro-root-plain-dir-on-btrfs``):
## bootstrap creates ``/repro`` as a plain directory on the btrfs root, so the
## snapshot carries the store and the gate turns red. Record red, then green.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_store_placement_by_root_fs``). Bases: the btrfs and
## the ext4 guest (the ledger comparison needs both).
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const Snapshot = "/.repro-addon-gate-snapshot"

proc comparableLedger*(ledger: string): string =
  ## What "the same generation sequence produces the same ledgers" compares
  ## (spec §5.1): every entry's class, path, mode and owner, in order, and
  ## the content digest of the objects the profile itself declares (the
  ## fixture file and unit). Left out, because they differ between two
  ## hosts by design: the generation id; the content of host-specific
  ## objects (the recipient key the host generated, the anchors the test
  ## bed drew for each guest, the files prefix holding them); and a root's
  ## kind word, which is the property under test (``btrfs-subvolume`` /
  ## ``btrfs-dir`` on btrfs, ``dir`` on ext4) and is checked by the steps.
  for line in ledger.splitLines():
    let f = line.split('\t')
    if f.len < 6 or f[0] in ["generation", "#"] or line.startsWith("#"):
      continue
    if f[0] == "storePrefix" and "repro-addon-files" in f[1]:
      result.add("storePrefix\trepro-addon-files\n")
      continue
    let declared = f[1].startsWith(FixturePrefix) or FixtureUnitName in f[1]
    result.add(f[0] & "\t" & f[1] & "\t" & f[4] & "\t" & f[5] &
      (if declared: "\t" & f[3] else: "") & "\n")

proc runBase(b: BaseImage; record: JsonNode;
             ledgers: var seq[string]): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  let btrfs = archVariantOf(b) == avBtrfs
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let guard = g.vacuityGuardRootFs(b)
    step("root filesystem (vacuity guard)", guard.ok, guard.detail)
    if not guard.ok: return fails
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapArch(repro, step).ok: return fails
    let inode = g.run("stat -c %i /repro").strip()
    record["reproInode"] = %inode
    if btrfs:
      step("/repro is a btrfs subvolume", inode == "256" and
           g.exec("btrfs subvolume show /repro").exitCode == 0,
           "inode " & inode & "\n" & g.exec("btrfs subvolume show /repro 2>&1").stdout)
    else:
      step("/repro is a plain directory", inode != "256" and
           g.exec("test -d /repro -a ! -L /repro").exitCode == 0,
           "inode " & inode)

    let exe = g.gen0ReproExe()
    let a1 = g.applyProfile(repro, "gen1", gen1Profile(exe))
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    ledgers.add(comparableLedger(g.ledgerOf()))

    if btrfs:
      let snap = g.exec("btrfs subvolume snapshot -r / " & Snapshot)
      step("a snapshot of / is taken", snap.exitCode == 0,
           snap.stdout & snap.stderr)
      let inSnap = g.exec("ls -A " & Snapshot & "/repro 2>&1; " &
                          "ls -A " & Snapshot & "/repro/store 2>/dev/null | head")
      record["snapshotRepro"] = %inSnap.stdout
      step("the snapshot of / contains none of /repro/store",
           inSnap.stdout.strip().len == 0 and
             g.exec("test -e " & Snapshot & "/repro/store").exitCode != 0,
           inSnap.stdout)
      discard g.exec("btrfs subvolume delete " & Snapshot)

    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
    step("uninstall removed /repro", g.exec("test -e /repro").exitCode != 0,
         g.exec("ls -la /repro 2>&1").stdout)
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

suite "e2e_arch_addon_store_placement_by_root_fs":
  test "/repro is a subvolume on btrfs and a directory on ext4":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_addon_store_placement_by_root_fs)")
    else:
      var failures: seq[string]
      var ledgers: seq[string]
      for b in [ArchBtrfs, ArchExt4]:
        let record = archGateRecord("e2e_arch_addon_store_placement_by_root_fs")
        record["base"] = %b.name
        let f = runBase(b, record, ledgers)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord("e2e_arch_addon_store_placement_by_root_fs",
                                     record)
        failures.add(f)
      if ledgers.len == 2 and ledgers[0] != ledgers[1]:
        failures.add("the generation-1 ledgers differ between the btrfs and " &
          "the ext4 guest:\n" & ledgers[0] & "\n---\n" & ledgers[1])
      for f in failures: echo "FAIL ", f
      check failures.len == 0
