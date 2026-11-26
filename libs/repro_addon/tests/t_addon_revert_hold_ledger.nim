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
## - a revert claims only the ``<unit>.d`` directories it creates, never one
##   that exists: it makes each under an unguessable staging name and
##   renames it into place without replacing anything, recording every step
##   first (``placeRevertHold``, ``revertHoldDirsPath``). So the replay of
##   an attempt that died at any point claims exactly the directories it
##   made, and an operator's directory made in the meantime -- even at the
##   very path -- is never claimed (``claimedRevertHoldDirs``): uninstall
##   leaves no empty directory of the revert's behind and never removes an
##   operator's. The record is removed at the commit; the VM gate resets
##   the guest between the revert's ledger and its commit.
## - a passing switch removes every revert hold, and a hold's directory
##   only when a ledger or the record claims it: an operator's empty
##   ``<unit>.d`` that a revert put its hold in stays (``clearRevertHolds``).
##
## Falsifying builds: ``revert-hold-unledgered`` (the engine before the fix,
## recording no hold) is red on every test that expects an entry: the
## first, second, fourth, fifth and sixth of the first suite, and the
## two later tests whose ledger it builds;
## ``replayed-hold-dir-unclaimed`` is red on "a revert claims a directory it
## makes, never one that was there", "a replayed revert claims the
## directories its interrupted attempt recorded", "a crash before the
## rename leaves an operator's directory unclaimed" (its staging directory
## is not dropped), "a directory the revert made, once removed, is never
## claimed again" and "the record names only
## hold directories and staging names under the unit directory";
## ``revert-hold-gone-dir-reclaimed`` is red on "a directory the revert
## made, once removed, is never claimed again";
## ``revert-hold-clear-removes-any-dir`` is red on "it removes a hold's
## directory only when the add-on owns it";
## ``revert-hold-record-unreadable-as-empty`` (the engine before the fix
## for reprobuild-pm issue
## ``2026-11-15-floor-a-revert-hold-directory-record-is-rewritten-empty-
## when-it-cannot-be-read``) is red on "a record that exists and cannot be
## read is refused, never rewritten empty";
## ``uninstall-ignores-unledgered-holds`` is red on "a killed revert's hold
## and the directory it made, never an operator's" (uninstall's claim of
## the holds no ledger names, ``unledgeredRevertHolds``; spec §6.4 step 2).
## Step 0 refuses uninstall while the dead revert's pending marker exists,
## and the recovery that clears it ledgers the holds, so the VM gate
## ``e2e_addon_uninstall_removes_revert_holds`` cannot reach this claim
## through ``repro system addon uninstall``; this suite calls it directly.
##
## Mocks: none. The unreadable record is a real file of mode 0, read under
## an unprivileged uid. The holds are real files under a temporary directory that
## stands in for ``/etc/systemd/system`` (``revertHoldEntries`` takes the
## root as a parameter); nothing here needs a service manager.

import std/[os, sets, strutils, tempfiles, unittest]
import std/posix

import repro_infra/start_holds
import repro_addon/addon_apply
import repro_addon/effective_floor
import repro_addon/fingerprint
import repro_addon/ledger
import repro_addon/uninstall

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

proc stagingLeft(root: string): seq[string] =
  for kind, f in walkDir(root):
    if extractFilename(f).startsWith(RevertHoldStagingPrefix): result.add(f)

proc stagingName(root: string; c: char): string =
  root / (RevertHoldStagingPrefix & repeat(c, 32))

proc writeRecord(state: string; lines: openArray[string]) =
  createDir(state / "addon")
  writeFile(revertHoldDirsPath(state), lines.join("\n") & "\n")

suite "the directory a revert's hold is written in":
  test "a revert claims a directory it makes, never one that was there":
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    # An operator's empty directory, and one with their own drop-in.
    createDir(root / "b.service.d")
    createDir(root / "c.service.d")
    writeFile(root / "c.service.d" / "10-operator.conf", "[Unit]\n")
    let a = placeRevertHold(state, "a.service", root)
    let b = placeRevertHold(state, "b.service", root)
    let c = placeRevertHold(state, "c.service", root)
    let t = placeRevertHold(state, "t@1.service", root)
    check a.createdDir == root / "a.service.d"
    check t.createdDir == root / "t@.service.d"
    check b.createdDir == "" and c.createdDir == ""
    for h in [a.hold, b.hold, c.hold, t.hold]:
      check readFile(h) == RevertHoldText
    check stagingLeft(root).len == 0
    # The record claims exactly the two it made.
    check claimedRevertHoldDirs(state, root).toHashSet ==
      toHashSet([root / "a.service.d", root / "t@.service.d"])
    clearRevertHoldDirs(state)
    check not fileExists(revertHoldDirsPath(state))
    check claimedRevertHoldDirs(state, root).len == 0

  test "a replayed revert claims the directories its interrupted attempt recorded":
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    # The interrupted attempt placed a.service's hold and died before its
    # ledger: its record says staged, and the staging directory is gone.
    let a = placeRevertHold(state, "a.service", root)
    let es = revertHoldEntries([], initHashSet[string](), [a.hold],
                               claimedRevertHoldDirs(state, root), root)
    check classes(es, lcRevertHold) == @[a.hold]
    check classes(es, lcDir) == @[root / "a.service.d"]

  test "a crash before the rename leaves an operator's directory unclaimed":
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    # Each pair: the revert meant to make <x>.d and died; then an operator
    # made <x>.d before the replay.
    # b: died after recording `intended`, before making the staging dir.
    # c: died after recording `staged`, before the rename (staging left).
    # d: the rename found <x>.d there and the staging was dropped.
    let sb = stagingName(root, 'b')
    let sc = stagingName(root, 'c')
    let sd = stagingName(root, 'd')
    writeRecord(state, [
      root / "b.service.d" & "\t" & sb & "\tintended",
      root / "c.service.d" & "\t" & sc & "\tintended",
      root / "c.service.d" & "\t" & sc & "\tstaged",
      root / "d.service.d" & "\t" & sd & "\tintended",
      root / "d.service.d" & "\t" & sd & "\tstaged",
      root / "d.service.d" & "\t" & sd & "\tabandoned"])
    createDir(sc)
    writeFile(sc / RevertHoldName, RevertHoldText)
    for x in ["b", "c", "d"]: createDir(root / (x & ".service.d"))
    check claimedRevertHoldDirs(state, root).len == 0
    # The staging directory the revert left is gone, and recorded so.
    check not dirExists(sc)
    check claimedRevertHoldDirs(state, root).len == 0
    for x in ["b", "c", "d"]: check dirExists(root / (x & ".service.d"))

  test "a directory the revert made, once removed, is never claimed again":
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    # The revert made a.service.d and died before its commit; an uninstall
    # (or a passing switch) then removed the hold and the directory, and
    # failed before the record went. An operator makes a.service.d.
    let a = placeRevertHold(state, "a.service", root)
    check claimedRevertHoldDirs(state, root) == @[a.createdDir]
    removeFile(a.hold)
    removeDir(a.createdDir)
    check claimedRevertHoldDirs(state, root).len == 0
    createDir(a.createdDir)
    check claimedRevertHoldDirs(state, root).len == 0
    check readRevertHoldDirRecords(state, root)[0].phase == "abandoned"

  test "the record names only hold directories and staging names under the unit directory":
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    let good = stagingName(root, 'a')
    createDir(root / "a.service.d")
    writeRecord(state, [
      root / "a.service.d" & "\t" & good & "\tstaged",
      "/etc\t" & good & "\tstaged",
      root / "x" & "\t" & good & "\tstaged",
      root / "a.service.d/../../evil.d" & "\t" & good & "\tstaged",
      root / "b.service.d" & "\t" & root / "elsewhere" & "\tstaged",
      root / "b.service.d" & "\t" & stagingName(root, 'z') & "\tplanted",
      root / "a.service.d"])
    check readRevertHoldDirRecords(state, root) ==
      @[(dir: root / "a.service.d", staging: good, phase: "staged")]
    check claimedRevertHoldDirs(state, root) == @[root / "a.service.d"]

  test "a record that exists and cannot be read is refused, never rewritten empty":
    # reprobuild-pm issue 2026-11-15-floor-a-revert-hold-directory-record-
    # is-rewritten-empty-when-it-cannot-be-read: each step is appended by
    # rewriting the whole record, so a read error taken as "no record"
    # replaced every earlier step with the new one, and the directory an
    # earlier revert made was no longer claimed. A mode-0 file stands in for
    # any read error (EACCES here; EIO the same way). Root reads it anyway,
    # so as root the engine's calls run under an unprivileged effective uid
    # that owns the state directory, as the record's real owner would.
    # That uid must reach the directories, so as root they are made under
    # /tmp (world-searchable) rather than $TMPDIR, which a root shell may
    # keep private (nix develop makes it 0700).
    let asRoot = geteuid() == 0
    let base = if asRoot: "/tmp" else: ""
    let root = createTempDir("revert-hold-", "", base)
    let state = createTempDir("revert-hold-state-", "", base)
    defer:
      removeDir(root)
      removeDir(state)
    let a = placeRevertHold(state, "a.service", root)
    let rec = revertHoldDirsPath(state)
    let before = readFile(rec)
    check claimedRevertHoldDirs(state, root) == @[a.createdDir]
    if asRoot:
      for d in [root, state, state / "addon"]:
        doAssert posix.chown(d.cstring, Uid(65534), Gid(65534)) == 0
      doAssert posix.chown(rec.cstring, Uid(65534), Gid(65534)) == 0
      doAssert seteuid(Uid(65534)) == 0
    var raised = false
    try:
      doAssert posix.chmod(rec.cstring, Mode(0o000)) == 0
      # The precondition: the record is there to this uid (its directory
      # can be searched, so only the read is refused) and really cannot be
      # read. Without the first, a refusal could come from the path, and a
      # build that takes any error as "no record" would fail its rewrite
      # the same way and pass.
      doAssert fileExists(rec)
      expect IOError:
        discard readFile(rec)
      try:
        discard placeRevertHold(state, "b.service", root)
      except CatchableError as e:
        checkpoint e.msg
        raised = true
      doAssert posix.chmod(rec.cstring, Mode(0o600)) == 0
    finally:
      if asRoot: doAssert seteuid(Uid(0)) == 0
    # The hold is not placed: nothing made, and the caller keeps the unit's
    # start hold.
    check raised
    check not dirExists(root / "b.service.d")
    check stagingLeft(root).len == 0
    # The record is as it was, and still claims the earlier revert's
    # directory.
    check readFile(rec) == before
    check claimedRevertHoldDirs(state, root) == @[a.createdDir]

suite "a passing switch clears the holds":
  test "it removes a hold's directory only when the add-on owns it":
    let root = createTempDir("revert-hold-", "")
    defer: removeDir(root)
    # A directory a ledger records, one only the record names (a revert
    # that died before its commit), and an operator's empty directory that
    # was there before the revert put its hold in it.
    let a = holdAt(root, "a.service")
    let b = holdAt(root, "b.service")
    let c = holdAt(root, "c.service")
    let previous = revertHoldEntries([], initHashSet[string](), [a],
                                     [parentDir(a)], root)
    let units = toHashSet(["a.service", "b.service", "c.service", "d.service"])
    let cleared = clearRevertHolds(addonRevertHolds(units, [root]), previous,
                                   [parentDir(b)])
    check cleared.toHashSet == toHashSet([a, b, c])
    for h in [a, b, c]: check not fileExists(h)
    check not dirExists(parentDir(a))
    check not dirExists(parentDir(b))
    check dirExists(parentDir(c))
    # An owned directory with anything else in it stays.
    let d = holdAt(root, "d.service")
    writeFile(root / "d.service.d" / "10-operator.conf", "[Unit]\n")
    discard clearRevertHolds(addonRevertHolds(units, [root]), [],
                             [parentDir(d)])
    check not fileExists(d)
    check fileExists(root / "d.service.d" / "10-operator.conf")

suite "uninstall claims the revert holds no ledger names":
  test "a killed revert's hold and the directory it made, never an operator's":
    # The state a revert leaves when it dies after placing its holds and
    # before its ledger (spec §6.4 step 2): the holds and the record are on
    # the host, the ledger is the refused switch's and names neither.
    # Uninstall refuses that host while its pending marker exists (step 0),
    # so the VM gate reaches this only after a recovery has ledgered the
    # holds; here the claim is exercised directly.
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    let a = placeRevertHold(state, "a.service", root)
    # An operator's directory the revert put its hold in: the hold is
    # claimed, the directory is not.
    createDir(root / "b.service.d")
    let b = placeRevertHold(state, "b.service", root)
    # A hold-named file on a unit the ledger does not install, and one with
    # other bytes on a unit it does: neither is claimed.
    let c = holdAt(root, "c.service")
    let d = holdAt(root, "d.service", "[Unit]\nDescription=theirs\n")
    let l = Ledger(entries: @[
      LedgerEntry(class: lcUnit, path: root / "a.service", unit: "a.service"),
      LedgerEntry(class: lcUnit, path: root / "b.service", unit: "b.service"),
      LedgerEntry(class: lcUnit, path: root / "d.service", unit: "d.service")])
    let es = unledgeredRevertHolds(l, state, root)
    check classes(es, lcRevertHold).toHashSet == toHashSet([a.hold, b.hold])
    check classes(es, lcDir) == @[root / "a.service.d"]
    check c notin classes(es, lcRevertHold) and d notin classes(es, lcRevertHold)

  test "a hold and a directory the ledger already names are not claimed again":
    let root = createTempDir("revert-hold-", "")
    let state = createTempDir("revert-hold-state-", "")
    defer:
      removeDir(root)
      removeDir(state)
    let a = placeRevertHold(state, "a.service", root)
    var l = Ledger(entries: @[
      LedgerEntry(class: lcUnit, path: root / "a.service", unit: "a.service")])
    l.entries.add(revertHoldEntries([], toHashSet(["a.service"]), [a.hold],
                                    [a.createdDir], root))
    check unledgeredRevertHolds(l, state, root).len == 0

