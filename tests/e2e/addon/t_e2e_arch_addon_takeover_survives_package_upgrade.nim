## Gate ``e2e_arch_addon_takeover_survives_package_upgrade`` (spec
## ReproOS-Add-On-Mode §4.3.1, §6.4, §12.5 condition 1; §13 decision 89).
##
## A ``collision = "takeOver"`` of a pacman backup file lives under pacman's
## own rules for locally changed backup files, and its removal puts back the
## version pacman's database names. Five ``makepkg`` fixture packages
## (``arch_fixture_packages``), each owning one backup file under
## ``/etc/repro-fx/``, keep the cases apart, so one case's failure cannot
## leak into another:
##
## - ``keep`` is upgraded to a release whose packaged file did not change
##   (``1-1`` -> ``1-2``): the add-on's copy stays and no ``.pacnew``
##   appears; removing the resource restores the bytes recorded at
##   take-over, whose MD5 is the database's ``%BACKUP%`` entry.
## - ``change`` is upgraded to a version whose packaged file changed: the
##   copy stays and pacman installs ``<path>.pacnew``; removing the resource
##   installs the ``.pacnew`` (its MD5 equal to ``%BACKUP%``), deletes it
##   and reports the restore.
## - ``edited`` is upgraded likewise and its ``.pacnew`` edited by hand:
##   removing the resource is refused with ``EAddOnPackageOwned`` naming the
##   package, the path and the three digests, and nothing changes (the
##   fingerprint is identical); once the ``.pacnew`` holds the packaged
##   version again the removal installs it.
## - ``pacsave`` is removed with ``pacman -R``: pacman keeps the add-on's
##   copy as ``<path>.pacsave``; removing the resource deletes the
##   ``.pacsave`` (its digest equals the ledger's) and does not re-create the
##   path.
## - ``moved`` is taken over by another package (``repro-fx-mover`` ships
##   the same backup file after ``repro-fx-moved`` leaves the database):
##   pacman keeps the copy and writes the new owner's version as a
##   ``.pacnew``; removing the resource installs that ``.pacnew`` by the new
##   owner's ``%BACKUP%`` -- the path is never simply handed back with the
##   add-on's bytes in it.
## - ``pacsave2`` is removed with ``pacman -R`` and its ``.pacsave`` then
##   holds other bytes: removing the resource leaves the ``.pacsave``,
##   reports it, and does not re-create the path.
## - ``uninst`` gets a content update while taken over (it stays a copy and
##   the ledger keeps the first packaged bytes), is upgraded with a changed
##   file while the resource is still declared, and the add-on is
##   uninstalled: uninstall installs the ``.pacnew`` by the same rule.
## - ``refuse`` is upgraded likewise and its ``.pacnew`` edited by hand: the
##   first uninstall refuses that path with ``EAddOnPackageOwned`` (the
##   three digests), keeps it and the state and exits non-zero; once the
##   ``.pacnew`` holds the packaged version again a second uninstall
##   completes.
##
## After every restore ``pacman -Qkk`` reports the package's files
## unmodified: no ``checksum mismatch`` line for the backup file (pacman
## reports a backup file's changed content only as such a line, under "0
## altered files", so ``qkkProblems`` reads the lines, not the summary). At the end the fingerprint equals the baseline but for what
## the pacman database accounts for (spec §6.4's Arch exception, derived
## rather than allowed by name): the ``pacman-local`` record of each package
## the gate upgraded or removed, and the backup files of those packages,
## each of which must hold the version ``%BACKUP%`` names.
##
## Baseline: the fixture packages (and ``fakeroot`` from the pinned
## archive, which ``makepkg`` needs) are installed, then the baseline step
## (``settleBaseline``) runs, then the first fingerprint is taken.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=takeover-restores-recorded-bytes``):
## removal and uninstall always restore the recorded bytes. After the
## changing upgrade the path then keeps a version whose MD5 differs from
## ``%BACKUP%`` (``pacman -Qkk`` reports it modified), and the edited
## ``.pacnew`` no longer refuses the removal: the gate must go red at
## exactly those steps (``expectedFalsifier``), with bootstrap, the
## take-over, the upgrades and the unaffected cases green.
##
## Bases: ``REPRO_ADDON_BASES`` (the recipe's default is
## ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``
## (``just e2e_arch_addon_takeover_survives_package_upgrade``).
##
## *Mocking.* None: real Arch guests, real makepkg, pacman and systemd, the
## real static add-on binary.

import std/[json, os, strutils, tables, unittest]

import repro_test_support/reasoned_skip
import repro_addon/[fingerprint, ledger, md5_hex]

import ./arch_fixture_packages
import ./arch_gate_support

const
  Gate = "e2e_arch_addon_takeover_survives_package_upgrade"
  Dir = "/etc/repro-fx"
  Cases = ["keep", "change", "edited", "pacsave", "uninst", "moved",
           "pacsave2", "refuse"]
  Mover = "repro-fx-mover"
    ## A package that takes ``moved.conf`` over from ``repro-fx-moved``
    ## (another package owning a taken-over path: the restore rule reads the
    ## new owner's ``%BACKUP%``, never a hand-back).

proc pathOf(c: string): string = Dir & "/" & c & ".conf"
proc pkgOf(c: string): string = "repro-fx-" & c
var addOnVersion = initTable[string, int]()
  ## The version of the add-on's bytes each case's profile declares.
proc addOnBytes(c: string): string =
  "# the add-on's " & c & "\nmanaged = yes\n" &
    (if addOnVersion.getOrDefault(c) > 1: "revision = " & $addOnVersion[c] & "\n"
     else: "")

proc fixture(c, pkgver, pkgrel, content: string): ArchFixturePackage =
  ArchFixturePackage(name: pkgOf(c), pkgver: pkgver, pkgrel: pkgrel,
    files: @[fxFile(pathOf(c), content, backup = true)])

proc packaged(c: string; v: int): string =
  "# " & c & " as packaged, version " & $v & "\nsetting = " & $v & "\n"

proc profile(cases: openArray[string]): string =
  result = "addOn {\n  managedEtcPrefixes = [\"" & Dir & "/\"]\n}\n"
  for c in cases:
    result.add("\nfs.systemFile {\n  path = \"" & pathOf(c) & "\"\n" &
      "  content = \"" & addOnBytes(c) & "\"\n" &
      "  collision = \"takeOver\"\n}\n")

proc entriesAt(ledgerText, path: string): seq[LedgerEntry] =
  for e in parseLedger(ledgerText).entries:
    if e.path == path: result.add(e)

proc isAddOnCopy(g: Guest; c: string): bool =
  ## The path holds the add-on's bytes as a regular file (never a link).
  g.sha256InGuest(pathOf(c)) == sha256Hex(addOnBytes(c))

proc restoredFromDb(g: Guest; c: string): tuple[ok: bool; detail: string] =
  ## The path holds the version the database's ``%BACKUP%`` names, no
  ## ``.pacnew`` is left beside it, and ``pacman -Qkk`` is clean.
  let want = g.backupMd5InDb(pkgOf(c), pathOf(c))
  let have = g.md5InGuest(pathOf(c))
  let pacnew = g.exec("test -e " & pathOf(c) & ".pacnew").exitCode == 0
  let qkk = g.pacmanQkkClean(pkgOf(c))
  (want.len == 32 and have == want and not pacnew and qkk.ok,
   "%BACKUP% " & want & ", file " & have & ", .pacnew " &
     (if pacnew: "present" else: "absent") & "\n" & qkk.output)

proc restoredFromDbOf(g: Guest; pkg, path: string): tuple[ok: bool; detail: string] =
  ## ``restoredFromDb`` for a path owned by ``pkg``.
  let want = g.backupMd5InDb(pkg, path)
  let have = g.md5InGuest(path)
  let pacnew = g.exec("test -e " & path & ".pacnew").exitCode == 0
  let qkk = g.pacmanQkkClean(pkg)
  (want.len == 32 and have == want and not pacnew and qkk.ok,
   "%BACKUP% " & want & ", file " & have & ", .pacnew " &
     (if pacnew: "present" else: "absent") & "\n" & qkk.output)

proc fixtureVersions(g: Guest): Table[string, string] =
  ## ``pacman -Q`` of the fixture packages: name -> version.
  for line in g.run("pacman -Q 2>/dev/null | grep '^repro-fx-' || true").splitLines():
    let f = line.splitWhitespace()
    if f.len == 2: result[f[0]] = f[1]

proc expectedFalsifier(mut: string; b: BaseImage): Falsifier =
  case mut
  of "takeover-restores-recorded-bytes":
    Falsifier(
      required: @[
        "change: removal installs the .pacnew (MD5 == %BACKUP%), deletes it, pacman -Qkk clean",
        "moved: removal installs the new owner's .pacnew (MD5 == its %BACKUP%), pacman -Qkk clean",
        "edited: removal over an edited .pacnew is refused, EAddOnPackageOwned with the three digests",
        "uninst: uninstall installs the .pacnew (MD5 == %BACKUP%), deletes it, pacman -Qkk clean",
        "refuse: the first uninstall refuses refuse.conf (EAddOnPackageOwned, three digests), keeps it and stays incomplete"],
      mayBeRed: @[
        "gen2: the apply reports each restore",
        "edited: the refused removal changed nothing",
        "edited: with the .pacnew put right, removal installs it, pacman -Qkk clean",
        "refuse: with the .pacnew put right, the second uninstall completes and installs it",
        "final fingerprint == baseline but for what the pacman database accounts for"],
      mustRunGreen: @[
        "baseline: udevadm settle and systemctl daemon-reload",
        "fingerprint is deterministic", "preflight is compatible", "bootstrap",
        "gen1: every backup file is taken over",
        "gen1: each path holds the add-on's copy, a regular file",
        "gen1: the ledger records each take-over with its packaged bytes",
        "gen1: fingerprint diff == ledger delta",
        "keep: an upgrade that kept the packaged file leaves the copy and no .pacnew",
        "change: an upgrade that changed the packaged file leaves the copy and installs .pacnew",
        "edited: the upgrade installs .pacnew",
        "pacsave: pacman -R keeps the add-on's copy as .pacsave",
        "gen2: keep, change and pacsave leave the profile",
        "keep: removal restores the recorded bytes (MD5 == %BACKUP%), pacman -Qkk clean",
        "pacsave: removal deletes the add-on's .pacsave and does not re-create the path",
        "gen2: the ledger no longer lists the removed paths",
        "uninst: the upgrade installs .pacnew",
        "uninst: a content update of a taken-over file stays a copy, its packaged bytes kept",
        "moved: another package takes the path over; pacman keeps the copy and installs .pacnew",
        "pacsave2: pacman -R keeps the add-on's copy as .pacsave, then it is overwritten",
        "pacsave2: a .pacsave holding other bytes is left, the path not re-created, and reported",
        "refuse: the upgrade installs .pacnew, then it is edited by hand"])
  else: raise unknownMutation(Gate, mut)

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  # Every base starts from the add-on's first bytes: the table outlives a
  # base, and a second base that inherited revision 2 would make its
  # content-update case update nothing.
  addOnVersion.clear()
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha

    # Fixture packages, built and installed before the baseline.
    g.installMakepkgPrerequisites()
    var files = initTable[string, string]()   # "<case>-<pkgver>-<pkgrel>" -> file
    proc build(c, pkgver, pkgrel: string; v: int) =
      files[c & "-" & pkgver & "-" & pkgrel] =
        g.buildArchFixture(fixture(c, pkgver, pkgrel, packaged(c, v)))
    for c in Cases: build(c, "1", "1", 1)
    build("keep", "1", "2", 1)          # same packaged file, new release
    build("change", "2", "1", 2)
    build("edited", "2", "1", 2)
    build("uninst", "2", "1", 2)
    build("refuse", "2", "1", 2)
    files["mover-1-1"] = g.buildArchFixture(ArchFixturePackage(name: Mover,
      pkgver: "1", pkgrel: "1",
      files: @[fxFile(pathOf("moved"), packaged("mover", 1), backup = true)]))
    var first: seq[string]
    for c in Cases: first.add(files[c & "-1-1"])
    let inst = g.exec("pacman -U --noconfirm " & first.join(" ") & " 2>&1",
                      timeoutSec = 900)
    if inst.exitCode != 0:
      raise newException(TestBedError, "installing the fixture packages " &
        "failed: " & inst.stdout & inst.stderr)
    let versionsBefore = g.fixtureVersions()
    record["fixtureVersionsBefore"] = %versionsBefore

    g.settleBaseline(step)
    let f0 = g.fingerprintArch(repro)
    sleep(20_000)
    let det = identityReport(f0, g.fingerprintArch(repro))
    step("fingerprint is deterministic", det.ok, det.text)
    if not det.ok: return fails
    if not g.bootstrapArch(repro, step).ok: return fails
    let l0 = g.ledgerOf()
    let f1 = g.fingerprintArch(repro)

    # gen1: every backup file is taken over.
    let a1 = g.applyProfile(repro, "gen1", profile(Cases))
    step("gen1: every backup file is taken over", a1.exitCode == 0,
         a1.stdout & a1.stderr)
    if a1.exitCode != 0: return fails
    var copies = true
    var copyDetail = ""
    for c in Cases:
      let ok = g.isAddOnCopy(c)
      copies = copies and ok
      copyDetail.add(c & ": " & g.sha256InGuest(pathOf(c)) & "\n")
    step("gen1: each path holds the add-on's copy, a regular file", copies,
         copyDetail)
    let l1 = g.ledgerOf()
    var recorded = true
    var recDetail = ""
    for c in Cases:
      let es = entriesAt(l1, pathOf(c))
      let ok = es.len == 1 and es[0].collision == "takeOver" and
        es[0].observation == "backup:" & pkgOf(c) and not es[0].isLink and
        es[0].sha256 == sha256Hex(addOnBytes(c)) and
        extractFilename(es[0].preserved) == sha256Hex(packaged(c, 1)) and
        g.exec("test -f " & es[0].preserved).exitCode == 0
      recorded = recorded and ok
      recDetail.add(c & ": " & $es.len & " entries" &
        (if es.len > 0: " collision=" & es[0].collision & " observation=" &
           es[0].observation & " form=" & es[0].form & " preserved=" &
           es[0].preserved else: "") & "\n")
    step("gen1: the ledger records each take-over with its packaged bytes",
         recorded, recDetail)
    let f2 = g.fingerprintArch(repro)
    let d1 = deltaReport(f1, f2, l0, l1)
    step("gen1: fingerprint diff == ledger delta", d1.ok, d1.text)

    # A content update of a taken-over file: still a copy, never a link
    # into the store, and the packaged bytes the ledger keeps do not move.
    block:
      addOnVersion["uninst"] = 2
      let a = g.applyProfile(repro, "gen1b", profile(Cases))
      let es = entriesAt(g.ledgerOf(), pathOf("uninst"))
      step("uninst: a content update of a taken-over file stays a copy, its packaged bytes kept",
           a.exitCode == 0 and "update\t" & pathOf("uninst") in (a.stdout & a.stderr) and
             g.isAddOnCopy("uninst") and es.len == 1 and
             not es[0].isLink and es[0].form == "copy" and
             es[0].collision == "takeOver" and
             extractFilename(es[0].preserved) == sha256Hex(packaged("uninst", 1)),
           "exit " & $a.exitCode & "\n" & a.stdout & a.stderr & "\n" &
             g.run("ls -la " & pathOf("uninst")) &
             (if es.len > 0: "form " & es[0].form & ", preserved " & es[0].preserved else: ""))

    # The package operations.
    block:
      let up = g.pacmanInstall(files["keep-1-2"])
      step("keep: an upgrade that kept the packaged file leaves the copy and no .pacnew",
           up.exitCode == 0 and g.isAddOnCopy("keep") and
             g.exec("test -e " & pathOf("keep") & ".pacnew").exitCode != 0,
           up.stdout & up.stderr)
    for (c, name) in [("change", "change: an upgrade that changed the packaged " &
                        "file leaves the copy and installs .pacnew"),
                      ("edited", "edited: the upgrade installs .pacnew")]:
      let up = g.pacmanInstall(files[c & "-2-1"])
      step(name, up.exitCode == 0 and g.isAddOnCopy(c) and
             g.sha256InGuest(pathOf(c) & ".pacnew") == sha256Hex(packaged(c, 2)) and
             g.backupMd5InDb(pkgOf(c), pathOf(c)) ==
               g.md5InGuest(pathOf(c) & ".pacnew"),
           up.stdout & up.stderr)
    discard g.run("printf '# edited by hand\\n' >> " & pathOf("edited") & ".pacnew")
    block:
      # Another package takes the path over: the old one leaves the
      # database (its file stays on disk), the new one ships the same
      # backup file; pacman keeps the add-on's copy and writes its version
      # beside it.
      let r = g.exec("pacman -Rdd --dbonly --noconfirm " & pkgOf("moved") &
        " 2>&1 && pacman -U --noconfirm --overwrite " & pathOf("moved") & " " &
        files["mover-1-1"] & " 2>&1")
      step("moved: another package takes the path over; pacman keeps the copy and installs .pacnew",
           r.exitCode == 0 and g.isAddOnCopy("moved") and
             g.sha256InGuest(pathOf("moved") & ".pacnew") == sha256Hex(packaged("mover", 1)) and
             g.backupMd5InDb(Mover, pathOf("moved")) == md5Hex(packaged("mover", 1)),
           r.stdout & r.stderr)
    block:
      let rm = g.pacmanRemove(pkgOf("pacsave2"))
      discard g.run("printf 'someone else\\n' > " & pathOf("pacsave2") & ".pacsave")
      step("pacsave2: pacman -R keeps the add-on's copy as .pacsave, then it is overwritten",
           rm.exitCode == 0 and g.sha256InGuest(pathOf("pacsave2")) == "absent" and
             g.sha256InGuest(pathOf("pacsave2") & ".pacsave") == sha256Hex("someone else\n"),
           rm.stdout & rm.stderr)
    block:
      let rm = g.pacmanRemove(pkgOf("pacsave"))
      step("pacsave: pacman -R keeps the add-on's copy as .pacsave",
           rm.exitCode == 0 and g.sha256InGuest(pathOf("pacsave")) == "absent" and
             g.sha256InGuest(pathOf("pacsave") & ".pacsave") ==
               sha256Hex(addOnBytes("pacsave")),
           rm.stdout & rm.stderr)

    # gen2: keep, change, pacsave, moved and pacsave2 leave the profile.
    let a2 = g.applyProfile(repro, "gen2", profile(["edited", "uninst", "refuse"]))
    let said2 = a2.stdout & a2.stderr
    step("gen2: keep, change and pacsave leave the profile", a2.exitCode == 0, said2)
    step("gen2: the apply reports each restore",
         "take-over-restore\t" & pathOf("keep") in said2 and
         "take-over-restore\t" & pathOf("change") in said2 and
         "install " & pathOf("change") & ".pacnew" in said2 and
         "take-over-restore\t" & pathOf("pacsave") in said2 and
         "take-over-restore\t" & pathOf("moved") in said2 and
         "take-over-restore\t" & pathOf("pacsave2") in said2, said2)
    block:
      let r = g.restoredFromDb("keep")
      step("keep: removal restores the recorded bytes (MD5 == %BACKUP%), pacman -Qkk clean",
           r.ok and g.sha256InGuest(pathOf("keep")) == sha256Hex(packaged("keep", 1)),
           r.detail)
    block:
      let r = g.restoredFromDb("change")
      step("change: removal installs the .pacnew (MD5 == %BACKUP%), deletes it, pacman -Qkk clean",
           r.ok and g.sha256InGuest(pathOf("change")) == sha256Hex(packaged("change", 2)),
           r.detail)
    step("pacsave: removal deletes the add-on's .pacsave and does not re-create the path",
         g.sha256InGuest(pathOf("pacsave")) == "absent" and
           g.sha256InGuest(pathOf("pacsave") & ".pacsave") == "absent",
         g.run("ls -la " & Dir))
    block:
      let r = g.restoredFromDbOf(Mover, pathOf("moved"))
      step("moved: removal installs the new owner's .pacnew (MD5 == its %BACKUP%), pacman -Qkk clean",
           r.ok and g.sha256InGuest(pathOf("moved")) == sha256Hex(packaged("mover", 1)) and
             "hand-back" notin said2,
           r.detail)
    step("pacsave2: a .pacsave holding other bytes is left, the path not re-created, and reported",
         g.sha256InGuest(pathOf("pacsave2")) == "absent" and
           g.sha256InGuest(pathOf("pacsave2") & ".pacsave") == sha256Hex("someone else\n") and
           "holds other bytes" in said2,
         g.run("ls -la " & Dir))
    # The foreign .pacsave is the operator's to deal with; it goes, so the
    # final comparison stays exact.
    discard g.run("rm -f " & pathOf("pacsave2") & ".pacsave")
    let l2 = g.ledgerOf()
    step("gen2: the ledger no longer lists the removed paths",
         entriesAt(l2, pathOf("keep")).len == 0 and
           entriesAt(l2, pathOf("change")).len == 0 and
           entriesAt(l2, pathOf("pacsave")).len == 0 and
           entriesAt(l2, pathOf("moved")).len == 0 and
           entriesAt(l2, pathOf("pacsave2")).len == 0 and
           entriesAt(l2, pathOf("edited")).len == 1, l2)

    # gen3: removing `edited` over an edited .pacnew is refused.
    let fBefore3 = g.fingerprintArch(repro)
    let a3 = g.applyProfile(repro, "gen3", profile(["uninst", "refuse"]))
    let said3 = a3.stdout & a3.stderr
    record["editedRefusal"] = %said3
    step("edited: removal over an edited .pacnew is refused, EAddOnPackageOwned with the three digests",
         a3.exitCode == 2 and "EAddOnPackageOwned" in said3 and
           pkgOf("edited") in said3 and pathOf("edited") in said3 and
           g.backupMd5InDb(pkgOf("edited"), pathOf("edited")) in said3 and
           g.md5InGuest(pathOf("edited") & ".pacnew") in said3 and
           md5Hex(packaged("edited", 1)) in said3,
         "exit " & $a3.exitCode & "\n" & said3)
    block:
      let same = identityReport(fBefore3, g.fingerprintArch(repro))
      step("edited: the refused removal changed nothing",
           same.ok and g.isAddOnCopy("edited") and
             entriesAt(g.ledgerOf(), pathOf("edited")).len == 1, same.text)
    discard g.run("cp " & files["edited-2-1"].quoteShell & " /tmp/edited.pkg && " &
      "bsdtar -xOf /tmp/edited.pkg " & pathOf("edited")[1 .. ^1] & " > " &
      pathOf("edited") & ".pacnew && rm -f /tmp/edited.pkg")
    block:
      let a3b = g.applyProfile(repro, "gen3b", profile(["uninst", "refuse"]))
      let r = g.restoredFromDb("edited")
      step("edited: with the .pacnew put right, removal installs it, pacman -Qkk clean",
           a3b.exitCode == 0 and r.ok and
             g.sha256InGuest(pathOf("edited")) == sha256Hex(packaged("edited", 2)),
           "exit " & $a3b.exitCode & "\n" & a3b.stdout & a3b.stderr & "\n" & r.detail)

    # `uninst`: a changing upgrade while still declared, then uninstall.
    block:
      let up = g.pacmanInstall(files["uninst-2-1"])
      step("uninst: the upgrade installs .pacnew",
           up.exitCode == 0 and g.isAddOnCopy("uninst") and
             g.sha256InGuest(pathOf("uninst") & ".pacnew") ==
               sha256Hex(packaged("uninst", 2)), up.stdout & up.stderr)
    block:
      let up = g.pacmanInstall(files["refuse-2-1"])
      discard g.run("printf '# edited by hand\\n' >> " & pathOf("refuse") & ".pacnew")
      step("refuse: the upgrade installs .pacnew, then it is edited by hand",
           up.exitCode == 0 and g.isAddOnCopy("refuse") and
             g.exec("test -f " & pathOf("refuse") & ".pacnew").exitCode == 0,
           up.stdout & up.stderr)
    # The first uninstall restores `uninst` and refuses `refuse`: it stays
    # incomplete, keeps that path and the state, and a second one finishes
    # once the operator puts the packaged version back at the .pacnew.
    let un = g.exec(repro & " system addon uninstall")
    let saidUn = un.stdout & un.stderr
    record["firstUninstall"] = %saidUn
    block:
      let r = g.restoredFromDb("uninst")
      step("uninst: uninstall installs the .pacnew (MD5 == %BACKUP%), deletes it, pacman -Qkk clean",
           r.ok and g.sha256InGuest(pathOf("uninst")) == sha256Hex(packaged("uninst", 2)),
           r.detail)
    step("refuse: the first uninstall refuses refuse.conf (EAddOnPackageOwned, three digests), keeps it and stays incomplete",
         un.exitCode != 0 and "EAddOnPackageOwned" in saidUn and
           pathOf("refuse") in saidUn and
           g.backupMd5InDb(pkgOf("refuse"), pathOf("refuse")) in saidUn and
           md5Hex(packaged("refuse", 1)) in saidUn and
           g.isAddOnCopy("refuse") and
           g.exec("test -d /var/lib/repro/system/addon").exitCode == 0,
         "exit " & $un.exitCode & "\n" & saidUn)
    discard g.run("bsdtar -xOf " & files["refuse-2-1"].quoteShell & " " &
      pathOf("refuse")[1 .. ^1] & " > " & pathOf("refuse") & ".pacnew")
    block:
      let un2 = g.exec(repro & " system addon uninstall")
      let r = g.restoredFromDb("refuse")
      step("refuse: with the .pacnew put right, the second uninstall completes and installs it",
           un2.exitCode == 0 and r.ok and
             g.sha256InGuest(pathOf("refuse")) == sha256Hex(packaged("refuse", 2)),
           "exit " & $un2.exitCode & "\n" & un2.stdout & un2.stderr & "\n" & r.detail)

    # The final comparison, its exceptions derived from the database.
    let versionsAfter = g.fixtureVersions()
    record["fixtureVersionsAfter"] = %versionsAfter
    var exceptions: seq[string]
    var derived = ""
    var backupsHold = true
    var owners: seq[(string, string)]    # package -> the case path it owns
    for c in Cases: owners.add((pkgOf(c), pathOf(c)))
    owners.add((Mover, pathOf("moved")))
    for (p, path) in owners:
      if versionsAfter.getOrDefault(p) == versionsBefore.getOrDefault(p): continue
      exceptions.add("pacman-local:" & p)
      if ("etc:" & path) notin exceptions: exceptions.add("etc:" & path)
      if p in versionsAfter:
        let want = g.backupMd5InDb(p, path)
        let have = g.md5InGuest(path)
        backupsHold = backupsHold and want.len == 32 and have == want
        derived.add(p & " " & versionsBefore.getOrDefault(p, "(absent)") &
          " -> " & versionsAfter[p] & ": " & path & " MD5 " & have &
          ", %BACKUP% " & want & "\n")
      else:
        derived.add(p & " removed: " & path & " " & g.sha256InGuest(path) & "\n")
    record["derivedExceptions"] = %exceptions
    let f9 = g.fingerprintArch(repro)
    let ident = identityReport(f0, f9, exceptions)
    step("final fingerprint == baseline but for what the pacman database accounts for",
         ident.ok and backupsHold, derived & ident.text)
    for (n, t) in [("f0", f0), ("f1", f1), ("f2", f2), ("f9", f9), ("l0", l0),
                   ("l1", l1), ("l2", l2)]:
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

suite Gate:
  test "a taken-over backup file survives upgrades and goes back to the version pacman names":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var failures: seq[string]
      for b in selectedArchBases():
        if isOmarchyBase(b):
          failures.add(b.name & ": " & Gate & " runs on the plain Arch guests")
          continue
        let record = archGateRecord(Gate)
        record["base"] = %b.name
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        let judged = judgeRun(Gate, record, f, expectedFalsifier, b)
        echo "record: ", writeRecord(Gate, record)
        failures.add(judged)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
