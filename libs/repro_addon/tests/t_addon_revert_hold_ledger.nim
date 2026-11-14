## A revert's persistent hold is an add-on object (ReproOS Add-On Mode spec
## §10.1, "A revert does not refuse on its own floor check", and §13
## decision 133; §4.2 and §6.4 step 2 as amended for reprobuild-pm issue
## ``2026-11-14-floor-a-revert-hold-is-in-no-ledger-so-uninstall-leaves-it``):
##
## - every ledger written while a hold is on the host records it
##   (``revertHoldEntries``, class ``revertHold``), and the ``<unit>.d``
##   directory a revert created for it;
## - only a regular file holding exactly the revert's hold text that the
##   add-on wrote is claimed -- written by this switch, recorded by the
##   previous ledger, or on a unit the generation installs -- so uninstall
##   never removes an operator's file of that name;
## - the entry survives the ledger's text form, is checked for drift like
##   any file the add-on wrote, and is accounted for by the fingerprint
##   expectations (a passing apply that removes the hold expects its
##   removal).
##
## The VM gate ``e2e_addon_uninstall_removes_revert_holds`` shows the
## uninstall removing it on a real guest, and an operator's own unit of the
## same name starting afterwards.
##
## - a replayed revert claims the ``<unit>.d`` directory its interrupted
##   attempt created and holds nothing but the hold, so uninstall does not
##   leave it behind empty; a directory with anything else is never claimed
##   (``revertHoldDirsToClaim``).
##
## Falsifying builds: ``revert-hold-unledgered`` (the engine before the fix,
## recording no hold) is red on every test that expects an entry: the
## first, second, fourth, fifth and sixth of the first suite;
## ``replayed-hold-dir-unclaimed`` is red on "a replayed revert claims the
## directory its interrupted attempt made".
##
## Mocks: none. The holds are real files under a temporary directory that
## stands in for ``/etc/systemd/system`` (``revertHoldEntries`` takes the
## root as a parameter); nothing here needs a service manager.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_infra/start_holds
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/fingerprint
import repro_addon/ledger

proc holdAt(root, unit: string; text = RevertHoldText): string =
  result = root / (unit & ".d") / RevertHoldName
  createDir(parentDir(result))
  writeFile(result, text)

proc classes(es: seq[LedgerEntry]; c: LedgerClass): seq[string] =
  for e in es:
    if e.class == c: result.add(e.path)

suite "a revert hold is in the ledger":
  test "the switch that wrote it records the hold and the directory it made":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    let dir = root / "a.service.d"
    let h = holdAt(root, "a.service")
    let es = revertHoldEntries([], initHashSet[string](), [h], [dir], root)
    check classes(es, lcRevertHold) == @[h]
    check classes(es, lcDir) == @[dir]
    for e in es:
      check e.resource == RevertHoldResource
      if e.class == lcRevertHold:
        check e.unit == "a.service"
        check e.sha256.len == 64
        check observeDrift(e) == ""

  test "a later ledger keeps a hold the previous one recorded, or one on a unit it installs":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    let a = holdAt(root, "a.service")
    let t = holdAt(root, "t@.service")
    let dir = root / "a.service.d"
    let first = revertHoldEntries([], initHashSet[string](), [a], [dir], root)
    # A refused switch after the revert: it wrote nothing, and its
    # generation no longer installs a.service.
    let next = revertHoldEntries(first, toHashSet(["t@.service"]), [], [], root)
    check classes(next, lcRevertHold).toHashSet == toHashSet([a, t])
    check classes(next, lcDir) == @[dir]

  test "an operator's file of that name, a planted link or other bytes are not claimed":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    # Exactly the hold text, on a unit the add-on never installed or held.
    discard holdAt(root, "theirs.service")
    # Other bytes on a unit the generation installs.
    discard holdAt(root, "b.service", "[Unit]\nDescription=operator's\n")
    # A link to the hold text on a unit the generation installs.
    let real = holdAt(root, "real.service")
    createDir(root / "c.service.d")
    createSymlink(real, root / "c.service.d" / RevertHoldName)
    let es = revertHoldEntries([], toHashSet(["b.service", "c.service"]), [], [], root)
    check es.len == 0

  test "a hold that is gone is recorded no longer; a directory still there is":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    let a = holdAt(root, "a.service")
    let dir = parentDir(a)
    let first = revertHoldEntries([], initHashSet[string](), [a], [dir], root)
    removeFile(a)                       # an operator removed it by hand
    let next = revertHoldEntries(first, toHashSet(["a.service"]), [], [], root)
    check classes(next, lcRevertHold).len == 0
    check classes(next, lcDir) == @[dir]
    removeDir(dir)
    check revertHoldEntries(next, toHashSet(["a.service"]), [], [], root).len == 0

  test "the entry survives the ledger's text, and a changed hold is drift":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    let a = holdAt(root, "a.service")
    let l = Ledger(generation: "g1",
      entries: revertHoldEntries([], initHashSet[string](), [a], [], root))
    let back = parseLedger(l.render())
    check back.entries.len == 1
    check back.entries[0].class == lcRevertHold
    check back.entries[0].path == a
    check back.entries[0].sha256 == l.entries[0].sha256
    check back.entries[0].resource == RevertHoldResource
    writeFile(a, RevertHoldText & "# edited\n")
    check observeDrift(back.entries[0]).startsWith("content changed")
    removeFile(a)
    check observeDrift(back.entries[0]) == "missing"

  test "the fingerprint expects the hold while it is recorded and its removal after":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    let a = holdAt(root, "a.service")
    let held = Ledger(generation: "g1",
      entries: revertHoldEntries([], initHashSet[string](), [a], [], root))
    var found = false
    for r in expectedRecords(held):
      if r.component == fcEtc and r.key == a:
        found = true
        check r.value.startsWith("f ") and r.value.endsWith(held.entries[0].sha256)
        check r.baseValue == ""
    check found
    # The passing switch removed it: its ledger lists it no longer.
    let cleared = Ledger(generation: "g2")
    var removed = false
    for x in expectedDelta(held, cleared):
      if x.component == fcEtc and x.key == a:
        removed = x.op == doRemoved
    check removed

suite "the directory a revert's hold is written in":
  test "a revert claims a directory it makes, never one that was there":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    createDir(root / "b.service.d")
    writeFile(root / "b.service.d" / "10-operator.conf", "[Unit]\n")
    let claimed = revertHoldDirsToClaim(["a.service", "b.service", "t@1.service"],
                                        false, root)
    check claimed == @[root / "a.service.d", root / "t@.service.d"]
    # Not replaying: an existing directory holding only a hold is not
    # claimed either (an earlier, recorded revert's).
    discard holdAt(root, "c.service")
    check revertHoldDirsToClaim(["c.service"], false, root).len == 0

  test "a replayed revert claims the directory its interrupted attempt made":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    # The interrupted attempt wrote the hold, then died before its ledger.
    let h = holdAt(root, "a.service")
    check revertHoldDirsToClaim(["a.service"], true, root) == @[parentDir(h)]
    # Recorded, it is removed with the hold at uninstall (``lcDir``).
    let es = revertHoldEntries([], initHashSet[string](), [h],
                               revertHoldDirsToClaim(["a.service"], true, root), root)
    check classes(es, lcRevertHold) == @[h]
    check classes(es, lcDir) == @[parentDir(h)]
    # Something else in it, or other bytes: someone else's directory.
    writeFile(root / "a.service.d" / "10-operator.conf", "[Unit]\n")
    check revertHoldDirsToClaim(["a.service"], true, root).len == 0
    discard holdAt(root, "b.service", "[Unit]\nDescription=operator's\n")
    check revertHoldDirsToClaim(["b.service"], true, root).len == 0
