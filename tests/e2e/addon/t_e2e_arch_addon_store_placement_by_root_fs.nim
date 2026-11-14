## Gate ``e2e_arch_addon_store_placement_by_root_fs`` (spec
## ReproOS-Add-On-Mode §5.1, §6.4).
##
## On a btrfs root (the btrfs Arch guest and the Omarchy VM) ``/repro``
## is its own subvolume (inode 256 on btrfs, ``btrfs subvolume show``); a
## snapper snapshot of ``/`` taken after a generation is realised contains
## none of ``/repro/store`` (a nested subvolume appears in its parent's
## snapshot as an empty directory). On the ext4 guest ``/repro`` is a plain
## directory. The same generation sequence produces the same ledgers on the
## two plain Arch guests (compared after the store paths, which carry no
## root-filesystem identity, and the timestamps are taken out). Uninstall
## removes either form (``/repro`` absent afterwards).
##
## The snapshot is snapper's own (``snapper -c root create``), taken by the
## configuration of ``/`` the base has: on the Omarchy VM the one its
## installer set up, on the btrfs guest one the gate creates
## (``snapper -c root create-config /``) after installing ``snapper`` from
## the guest's pinned archive (the guest's pacman names nothing else,
## ``arch_testbed.requirePinnedPacman``). The gate reads the snapshot at
## ``/.snapshots/<n>/snapshot`` and deletes it (``snapper delete``) before
## uninstalling.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=repro-root-plain-dir-on-btrfs``):
## bootstrap creates ``/repro`` as a plain directory on the btrfs root, so the
## snapshot carries the store and the gate turns red. Record red, then green.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_store_placement_by_root_fs``). Bases: the btrfs
## and the ext4 guest (the ledger comparison needs both) and the Omarchy VM.
##
## *Mocking.* None.

import std/[json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./arch_gate_support

const
  SnapperInstall = "pacman -Sy --noconfirm --needed snapper"
    ## From the guest's pinned archive (the image was built from the same
    ## date, so ``-Sy`` brings the same database the image has).
  SnapperCreate = "snapper -c root create --print-number --description " &
    "'reprobuild add-on placement gate'"

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
  let btrfs = rootIsBtrfs(b)
  let account = accountFor(b)
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let guard = g.vacuityGuardRootFs(b)
    step("root filesystem (vacuity guard)", guard.ok, guard.detail)
    if not guard.ok: return fails
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if btrfs and not isOmarchyBase(b):
      let inst = g.exec(SnapperInstall & " && snapper -c root create-config /",
                        timeoutSec = 1800)
      step("snapper installed from the pinned archive and configured for /",
           inst.exitCode == 0, inst.stdout & inst.stderr)
      if inst.exitCode != 0: return fails
    if btrfs:
      let cfg = g.exec("snapper --csvout list-configs")
      record["snapperConfigs"] = %cfg.stdout
      step("snapper has the configuration root of /", cfg.exitCode == 0 and
           "root,/" in cfg.stdout.splitLines(), cfg.stdout & cfg.stderr)
    if not g.bootstrapArch(repro, step, g.firstProfileFlag(b)).ok: return fails
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
    let a1 = g.applyProfile(repro, "gen1", gen1Profile(exe, account))
    step("apply generation 1", a1.exitCode == 0, a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    if not isOmarchyBase(b):
      ledgers.add(comparableLedger(g.ledgerOf()))

    if btrfs:
      let snap = g.exec(SnapperCreate)
      let n = snap.stdout.strip()
      step("snapper takes a snapshot of /", snap.exitCode == 0 and
           n.len > 0 and n.allCharsInSet({'0'..'9'}), snap.stdout & snap.stderr)
      if snap.exitCode != 0 or n.len == 0: return fails
      let at = "/.snapshots/" & n & "/snapshot"
      record["snapshot"] = %at
      let real = g.exec("test -d " & at & "/etc/repro-addon-fixture && " &
                        "test -d " & at & "/repro")
      step("vacuity guard: the snapshot holds / as of generation 1 (the " &
           "fixture's /etc directory and the /repro mount point)",
           real.exitCode == 0, g.exec("ls -la " & at & " 2>&1").stdout)
      let inSnap = g.exec("ls -A " & at & "/repro 2>&1; " &
                          "ls -A " & at & "/repro/store 2>/dev/null | head")
      record["snapshotRepro"] = %inSnap.stdout
      step("the snapper snapshot of / contains none of /repro/store",
           inSnap.stdout.strip().len == 0 and
             g.exec("test -e " & at & "/repro/store").exitCode != 0,
           inSnap.stdout)
      let del = g.exec("snapper -c root delete " & n)
      step("the gate's snapshot is deleted", del.exitCode == 0,
           del.stdout & del.stderr)

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
      for b in [ArchBtrfs, ArchExt4, OmarchyBase]:
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
