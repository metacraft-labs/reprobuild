## The switch puts back an object a removed resource preserved before it
## starts the generation's units (ReproOS Add-On Mode §7.2, the restore
## before step 7; reprobuild-pm issue
## 2026-11-03-addon-switch-restores-preserved-bytes-after-it-starts-units),
## and the pieces that make that step crash-safe:
##
## - a switch interrupted after the restore and before the start is
##   replayed by recovery; the replay finds the restore already made
##   (``alreadyRestored``) and does not redo or refuse it;
## - a switch that restored and then failed keeps the restored object in
##   its ledger, so its revert recognises the bytes as its own restore and
##   writes its generation's bytes over them
##   (``revertOverwritesRestored``), instead of refusing them as drift.
##
## The order itself and a hard reset at the new step boundary
## (``step-6-restore``) are VM gates: ``e2e_addon_adopt_hand_configured_service``
## (a rollback whose unit reads a reconciled file; red under the build
## ``restore-after-start``) and ``e2e_addon_hard_reset_at_every_step``.
##
## Falsifying mutation: ``revert-refuses-restored`` turns the revert case
## red.
##
## *Mocking.* None: the ledger entries are the switch's own type, the
## files are real files under a temporary directory.

import std/[os, unittest]

from repro_test_support import testCaseScratchSlug
import repro_addon/[addon_apply, fingerprint, ledger]

var scratch = getTempDir() / ("t_addon_restore_before_start" &
                              testCaseScratchSlug())

proc entryFor(path, preservedBytes, ownBytes: string): LedgerEntry =
  ## A ledgered file the add-on reconciled: its own bytes recorded, the
  ## operator's preserved.
  let pres = preservePath(scratch / "state", preservedBytes)
  createDir(parentDir(pres))
  writeFile(pres, preservedBytes)
  LedgerEntry(class: lcEtcFile, path: path, sha256: sha256Hex(ownBytes),
    mode: "0644", owner: "0:0", resource: "systemFile:" & path,
    collision: "reconcile", preserved: pres,
    replaced: "f 0644 0:0 sha256:" & sha256Hex(preservedBytes))

suite "the restore before the start":
  test "a replay after a reset between the restore and the start skips it":
    removeDir(scratch)
    createDir(scratch)
    let path = scratch / "vaultwarden.env"
    let e = entryFor(path, "ADMIN_TOKEN=operator\n", "PORT=80\n")
    # Not restored yet: the file still holds the add-on's bytes.
    writeFile(path, "PORT=80\n")
    check not alreadyRestored(e)
    # Restored, then the reset: the replay finds the operator's bytes.
    writeFile(path, "ADMIN_TOKEN=operator\n")
    check alreadyRestored(e)

  test "a revert writes over the bytes its failed switch restored":
    removeDir(scratch)
    createDir(scratch)
    let path = scratch / "vaultwarden.env"
    let e = entryFor(path, "ADMIN_TOKEN=operator\n", "PORT=80\n")
    let restored = sha256Hex("ADMIN_TOKEN=operator\n")
    check revertOverwritesRestored("revert", true, true, restored, e.preserved)
    # Not for anything else: other bytes, an apply that is not a revert,
    # an object the ledger does not own, a link, nothing preserved.
    check not revertOverwritesRestored("revert", true, true,
      sha256Hex("someone else\n"), e.preserved)
    check not revertOverwritesRestored("apply", true, true, restored,
                                       e.preserved)
    check not revertOverwritesRestored("revert", false, true, restored,
                                       e.preserved)
    check not revertOverwritesRestored("revert", true, false, restored,
                                       e.preserved)
    check not revertOverwritesRestored("revert", true, true, restored, "")

removeDir(scratch)
