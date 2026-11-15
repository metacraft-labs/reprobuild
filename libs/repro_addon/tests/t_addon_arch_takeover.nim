## Unit tests for the pacman collision driver's backup-file half and the
## ``backupTakeover`` class (spec ReproOS-Add-On-Mode §4.1, §4.3.1, §6.4,
## §7.4, §8.4; §13 decisions 89, 99 and 108):
##
## 1. ``%BACKUP%`` is read from the local database, a damaged line refused;
## 2. the driver reports a backup file with its packaged MD5, and the
##    ledger observation names it ``backup:<pkg>``;
## 3. the decision table on a pacman base: a backup file is refused without
##    ``collision = "takeOver"`` (naming the opt-in, never ``divert``), a
##    non-backup package file is refused with no opt-in (naming a drop-in
##    directory when there is one), a ``[missing]`` or ``[modified]`` backup
##    file is refused for ``takeOver``, and a pristine one is taken over
##    with its packaged bytes kept; ``divert`` is ``EAddOnOutOfScope``
##    naming "`divert` is unavailable on Arch", and ``takeOver`` is refused
##    by name on a dpkg base;
## 4. which bytes a removal restores (``takeover.nim``): the recorded bytes
##    while their MD5 is ``%BACKUP%``'s, else the ``.pacnew`` (installed with
##    the prior mode, then deleted), else a refusal naming the package, the
##    path and the three digests; after the package's removal the
##    ``.pacsave`` goes only when it holds the ledger's bytes and the path
##    is never re-created; altered preserved bytes and a ``.pacnew`` that is
##    a link are never used;
## 5. the base identity carries each named package's ``%FILES%`` digest on a
##    pacman base, round-trips it, and reports its change.
##
## *Mocking.* The pacman database is real files in a fixture tree under a
## temporary root, in the format pacman writes (alpm-db(7)), and the
## ``.pacnew`` / ``.pacsave`` files are what pacman leaves beside a backup
## file (pacman(8), "HANDLING CONFIG FILES"). One substitution, because the
## build host is not the guest: ``unitProvision`` answers "no such unit"
## (no decision here involves a unit). The real pacman upgrade and removal,
## and uninstall on a real host, run in the Arch VM gates
## (``tests/e2e/addon/t_e2e_arch_addon_takeover_survives_package_upgrade``).

import std/[os, posix, strutils, unittest]

import repro_infra/addon_diagnostics
import repro_addon/[base_identity, collision, fingerprint, ledger, md5_hex,
                    pacman_db, takeover]

let root = getTempDir() / ("repro-addon-takeover-" & $getCurrentProcessId())
removeDir(root)

proc put(rel, content: string) =
  createDir(parentDir(root / rel))
  writeFile(root / rel, content)

proc at(p: string): string = root & p

proc pkg(name, version: string; files: openArray[string];
         backup: openArray[(string, string)]) =
  ## A package entry as pacman writes it into the local database.
  let dir = "var/lib/pacman/local/" & name & "-" & version
  put(dir & "/desc", "%NAME%\n" & name & "\n\n%VERSION%\n" & version &
    "\n\n%ARCH%\nx86_64\n\n")
  var f = "%FILES%\n"
  for p in files: f.add(p & "\n")
  f.add("\n%BACKUP%\n")
  for (p, m) in backup: f.add(p & "\t" & m & "\n")
  f.add("\n")
  put(dir & "/files", f)

proc dropPkg(name, version: string) =
  removeDir(root / ("var/lib/pacman/local/" & name & "-" & version))

const
  Packaged1 = "use-ipv4=yes\n"
  Packaged2 = "use-ipv4=yes\nuse-ipv6=no\n"
  AddOnCopy = "allow-interfaces=eth0\n"

put("var/lib/pacman/local/ALPM_DB_VERSION", "9\n")
put("etc/os-release", "ID=arch\n")
put("etc/avahi/avahi-daemon.conf", Packaged1)
put("etc/avahi/hosts", "edited by hand\n")
put("etc/fx/plain.conf", "plain\n")
put("etc/fx/plain.conf.d/.keep", "")
pkg("avahi", "1:0.8-1", ["etc/", "etc/avahi/", "etc/avahi/avahi-daemon.conf",
    "etc/avahi/hosts", "etc/avahi/missing.conf"],
    [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged1)),
     ("etc/avahi/hosts", md5Hex("packaged hosts\n")),
     ("etc/avahi/missing.conf", md5Hex("x\n"))])
pkg("fx", "1-1", ["etc/fx/", "etc/fx/plain.conf", "etc/fx/nodigest.conf"], [])
put("etc/fx/nodigest.conf", "no digest\n")
block:
  # A %BACKUP% line with libalpm's "(null)" digest, written as pacman does.
  let f = root / "var/lib/pacman/local/fx-1-1/files"
  writeFile(f, readFile(f).replace("%BACKUP%\n", "%BACKUP%\netc/fx/nodigest.conf\t(null)\n"))

proc noUnit(unit: string): UnitProvision {.gcsafe.} =
  UnitProvision(loadState: "not-found")

proc file(path, content: string; collision = ""): DecisionInputs =
  DecisionInputs(address: "f:" & path, kind: tkFile, collision: collision,
    desiredContent: content, desiredSha256: sha256Hex(content))

proc refusedWith[T](body: proc ()): ref T =
  try:
    body()
  except T as e:
    return e
  nil

suite "%BACKUP% in the local database":
  test "paths and packaged MD5s; a damaged line is refused":
    let b = pacmanBackupFiles("%FILES%\netc/a\n\n%BACKUP%\netc/a\t" &
      md5Hex("a") & "\netc/b c\t" & md5Hex("b") & "\n\n")
    check b.len == 2
    check b[0].path == "/etc/a" and b[0].md5 == md5Hex("a")
    check b[1].path == "/etc/b c"
    check pacmanBackupFiles("%FILES%\netc/a\n\n%BACKUP%\n\n").len == 0
    # libalpm's spelling of a digest it does not have (Omarchy 4.5.0-3,
    # bash-completion 2.18.0-1): a backup file with no packaged MD5.
    let n = pacmanBackupFiles("%BACKUP%\netc/c\t(null)\n\n")
    check n.len == 1 and n[0].path == "/etc/c" and n[0].md5 == ""
    for bad in ["etc/a", "etc/a\tnot-a-digest", "/etc/a\t" & md5Hex("a"),
                "etc/a\tnull", "etc/a\t(NULL)"]:
      expect ValueError:
        discard pacmanBackupFiles("%BACKUP%\n" & bad & "\n\n")

  test "a damaged %BACKUP% section refuses the whole observation":
    let r2 = root & "-damaged"
    removeDir(r2)
    copyDir(root, r2)
    let dir = r2 / "var/lib/pacman/local/fx-1-1"
    writeFile(dir / "files", "%FILES%\netc/fx/plain.conf\n\n%BACKUP%\n" &
      "etc/fx/plain.conf\n\n")
    let d = newPacmanDriver(r2, noUnit)
    expect AddonCollisionError:
      discard d.packageOwner(r2 & "/etc/fx/plain.conf")
    removeDir(r2)

suite "the pacman driver's backup files":
  let d = newPacmanDriver(root, noUnit)

  test "a backup file carries its packaged MD5; other files do not":
    check d.supportsTakeOver and not d.supportsDiversions
    let o = d.packageOwner(at("/etc/avahi/avahi-daemon.conf"))
    check o.package == "avahi" and o.backup and o.backupMd5 == md5Hex(Packaged1)
    check not o.conffile
    let p = d.packageOwner(at("/etc/fx/plain.conf"))
    check p.package == "fx" and not p.backup and p.backupMd5 == ""
    check d.packageOwner(at("/etc/none")).package == ""

  test "the ledger observation is backup:<pkg>, and names the package":
    let o = observeTarget(d, at("/etc/avahi/avahi-daemon.conf"))
    check observationText(o, tkFile) == "backup:avahi"
    check packageOfObservation("backup:avahi") == "avahi"
    check observationText(observeTarget(d, at("/etc/fx/plain.conf")),
                          tkFile) == "package:fx"

  test "a dpkg base has no takeOver":
    let dd = newDpkgDriver(root, noUnit)
    check not dd.supportsTakeOver

suite "the decision table on a pacman base":
  let d = newPacmanDriver(root, noUnit)

  test "a backup file without the opt-in is refused, naming takeOver, never divert":
    let e = refusedWith[EAddOnPackageOwned](proc () =
      discard d.decide(file(at("/etc/avahi/avahi-daemon.conf"), AddOnCopy),
                       at("/etc/avahi/avahi-daemon.conf")))
    require not e.isNil
    check e.package == "avahi"
    check "takeOver" in e.msg and "backup file" in e.msg
    check "divert" notin e.msg

  test "a non-backup package file has no opt-in; the drop-in directory is named":
    for opt in ["", "takeOver"]:
      let e = refusedWith[EAddOnPackageOwned](proc () =
        discard d.decide(file(at("/etc/fx/plain.conf"), "y\n", opt),
                         at("/etc/fx/plain.conf")))
      require not e.isNil
      check e.package == "fx"
      check "not a backup file" in e.msg and "no opt-in" in e.msg
      check "plain.conf.d/" in e.msg
      check "divert" notin e.msg

  test "a backup file pacman records no digest for ((null)) is observed and refused for takeOver":
    let o = d.packageOwner(at("/etc/fx/nodigest.conf"))
    check o.package == "fx" and o.backup and o.backupMd5 == ""
    let e = refusedWith[EAddOnPackageOwned](proc () =
      discard d.decide(file(at("/etc/fx/nodigest.conf"), "y\n", "takeOver"),
                       at("/etc/fx/nodigest.conf")))
    require not e.isNil
    check "(null)" in e.msg and "no opt-in" in e.msg

  test "a [missing] backup file is refused for takeOver, naming the file":
    let e = refusedWith[EAddOnPackageOwned](proc () =
      discard d.decide(file(at("/etc/avahi/missing.conf"), "y\n", "takeOver"),
                       at("/etc/avahi/missing.conf")))
    require not e.isNil
    check at("/etc/avahi/missing.conf") in e.msg and "[missing]" in e.msg

  test "a [modified] backup file is refused for takeOver, naming the file":
    let e = refusedWith[EAddOnPackageOwned](proc () =
      discard d.decide(file(at("/etc/avahi/hosts"), "y\n", "takeOver"),
                       at("/etc/avahi/hosts")))
    require not e.isNil
    check at("/etc/avahi/hosts") in e.msg and "[modified]" in e.msg
    check md5Hex("packaged hosts\n") in e.msg

  test "a pristine backup file is taken over, its packaged bytes kept":
    let (dec, o) = d.decide(file(at("/etc/avahi/avahi-daemon.conf"), AddOnCopy,
      "takeOver"), at("/etc/avahi/avahi-daemon.conf"))
    check dec.verdict == cvTakeOver
    check dec.observation == "backup:avahi"
    check dec.preWriteBytes == Packaged1
    check dec.observedSha256 == sha256Hex(Packaged1)
    check o.ownership.backupMd5 == md5Hex(Packaged1)

  test "the write-time re-check sees an upgrade between the plan and the write":
    let inp = file(at("/etc/avahi/avahi-daemon.conf"), AddOnCopy, "takeOver")
    let (dec, o) = d.decide(inp, at("/etc/avahi/avahi-daemon.conf"))
    let t = plannedTarget(inp.address, inp, at("/etc/avahi/avahi-daemon.conf"),
                          dec, o)
    check preWriteRefusal(d, t) == ""
    writeFile(at("/etc/avahi/avahi-daemon.conf"), Packaged2)
    check "changed since the plan" in preWriteRefusal(d, t)
    writeFile(at("/etc/avahi/avahi-daemon.conf"), Packaged1)
    check preWriteRefusal(d, t) == ""

  test "divert is EAddOnOutOfScope, naming its unavailability on Arch":
    for path in ["/etc/avahi/avahi-daemon.conf", "/etc/fx/plain.conf",
                 "/etc/unowned.conf"]:
      let e = refusedWith[EAddOnOutOfScope](proc () =
        discard d.decide(file(at(path), "y\n", "divert"), at(path)))
      require not e.isNil
      check DivertUnavailableOnArch in e.msg
      check e.field == "fs.systemFile.collision"

  test "takeOver is EAddOnOutOfScope on a dpkg base":
    let dd = newDpkgDriver(root, noUnit)
    let e = refusedWith[EAddOnOutOfScope](proc () =
      refuseOptInForBase(dd, "f", "takeOver"))
    require not e.isNil
    check "`takeOver` is for pacman backup files" in e.msg
    refuseOptInForBase(dd, "f", "divert")       # Debian's own opt-in
    refuseOptInForBase(d, "f", "takeOver")      # Arch's own opt-in

# ---------------------------------------------------------------------------
# Restoring a taken-over file.
# ---------------------------------------------------------------------------

let stateDir = root / "state"
createDir(stateDir)

proc preserve(content: string): string =
  result = stateDir / sha256Hex(content)
  writeFile(result, content)

proc takenOver(path: string; packaged, copy: string): LedgerEntry =
  ## The ledger entry a ``takeOver`` of ``path`` records, with the add-on's
  ## copy on disk.
  writeFile(path, copy)
  LedgerEntry(class: lcEtcFile, path: path, sha256: sha256Hex(copy),
    mode: "0644", owner: $getuid() & ":" & $getgid(),
    replaced: "f 0640 " & $getuid() & ":" & $getgid() & " sha256:" &
      sha256Hex(packaged),
    resource: "fs.systemFile:" & path, observation: "backup:avahi",
    collision: TakeOverCollision, preserved: preserve(packaged), form: "copy")

proc modeOf(path: string): int =
  var st: Stat
  doAssert stat(path.cstring, st) == 0
  int(st.st_mode) and 0o7777

suite "which bytes a removal restores":
  let path = at("/etc/avahi/avahi-daemon.conf")
  let pacnew = path & PacnewSuffix
  let pacsave = path & PacsaveSuffix

  setup:
    removeFile(pacnew)
    removeFile(pacsave)
    dropPkg("avahi", "1:0.8-1")
    dropPkg("avahi", "1:0.8-2")
    pkg("avahi", "1:0.8-1", ["etc/avahi/avahi-daemon.conf"],
        [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged1))])

  test "no upgrade, or one that kept the packaged file: the recorded bytes":
    let e = takenOver(path, Packaged1, AddOnCopy)
    let d = newPacmanDriver(root, noUnit)
    let u = decideTakeOverUndo(e, d)
    check u.kind == tuRecorded and u.package == "avahi"
    check u.recordedMd5 == md5Hex(Packaged1) and u.backupMd5 == u.recordedMd5
    check "restore the packaged bytes" in applyTakeOverUndo(e, u)
    check readFile(path) == Packaged1
    check modeOf(path) == 0o640      # the mode the path had before
    check takeOverAlreadyUndone(e, d)

  test "after an upgrade that changed the file: the .pacnew, then deleted":
    let e = takenOver(path, Packaged1, AddOnCopy)
    dropPkg("avahi", "1:0.8-1")
    pkg("avahi", "1:0.8-2", ["etc/avahi/avahi-daemon.conf"],
        [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged2))])
    writeFile(pacnew, Packaged2)
    let d = newPacmanDriver(root, noUnit)
    let u = decideTakeOverUndo(e, d)
    check u.kind == tuPacnew
    check u.pacnewMd5 == md5Hex(Packaged2) and u.backupMd5 == md5Hex(Packaged2)
    check u.recordedMd5 == md5Hex(Packaged1)
    let line = applyTakeOverUndo(e, u)
    check "install " & pacnew in line and md5Hex(Packaged2) in line
    check readFile(path) == Packaged2
    check md5OfFile(path) == md5Hex(Packaged2)     # pacman -Qkk: unmodified
    check not fileExists(pacnew)
    check modeOf(path) == 0o640
    check takeOverAlreadyUndone(e, d)

  test "neither matches (an edited .pacnew): refused with the three digests":
    let e = takenOver(path, Packaged1, AddOnCopy)
    dropPkg("avahi", "1:0.8-1")
    pkg("avahi", "1:0.8-2", ["etc/avahi/avahi-daemon.conf"],
        [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged2))])
    writeFile(pacnew, Packaged2 & "# edited\n")
    let d = newPacmanDriver(root, noUnit)
    let u = decideTakeOverUndo(e, d)
    check u.kind == tuRefused
    let r = refusal(e, u)
    check "EAddOnPackageOwned" in r.msg and "avahi" in r.msg and path in r.msg
    for m in [md5Hex(Packaged1), md5Hex(Packaged2 & "# edited\n"), md5Hex(Packaged2)]:
      check m in r.msg
    expect EAddOnPackageOwned:
      discard applyTakeOverUndo(e, u)
    check readFile(path) == AddOnCopy                    # nothing changed
    check readFile(pacnew) == Packaged2 & "# edited\n"

  test "no .pacnew and a changed %BACKUP%: refused, naming it absent":
    let e = takenOver(path, Packaged1, AddOnCopy)
    dropPkg("avahi", "1:0.8-1")
    pkg("avahi", "1:0.8-2", ["etc/avahi/avahi-daemon.conf"],
        [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged2))])
    let u = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    check u.kind == tuRefused
    check ".pacnew (absent)" in refusal(e, u).msg

  test "a .pacnew that is a link is never read":
    let e = takenOver(path, Packaged1, AddOnCopy)
    dropPkg("avahi", "1:0.8-1")
    pkg("avahi", "1:0.8-2", ["etc/avahi/avahi-daemon.conf"],
        [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged2))])
    let real = root / "elsewhere"
    writeFile(real, Packaged2)
    createSymlink(real, pacnew)
    let u = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    check u.kind == tuRefused and u.pacnewMd5 == ""
    removeFile(pacnew)

  test "altered preserved bytes are never restored":
    let e = takenOver(path, Packaged1, AddOnCopy)
    writeFile(e.preserved, "swapped\n")
    expect AddonTakeOverError:
      discard decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    writeFile(e.preserved, Packaged1)

  test "the package removed: the add-on's .pacsave is deleted, the path not re-created":
    let e = takenOver(path, Packaged1, AddOnCopy)
    moveFile(path, pacsave)                       # what pacman -R does
    dropPkg("avahi", "1:0.8-1")
    let u = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    check u.kind == tuPacsaveDelete
    check "not re-created" in applyTakeOverUndo(e, u)
    check not fileExists(pacsave) and not fileExists(path)
    check takeOverAlreadyUndone(e, newPacmanDriver(root, noUnit))

  test "the package removed: a .pacsave with other bytes is left":
    let e = takenOver(path, Packaged1, AddOnCopy)
    removeFile(path)
    writeFile(pacsave, "someone else's\n")
    dropPkg("avahi", "1:0.8-1")
    let u = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    check u.kind == tuPacsaveLeave
    check "other bytes" in applyTakeOverUndo(e, u)
    check readFile(pacsave) == "someone else's\n" and not fileExists(path)

  test "no package lists the path, the copy still there: removed, nothing restored":
    let e = takenOver(path, Packaged1, AddOnCopy)
    dropPkg("avahi", "1:0.8-1")
    let u = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    check u.kind == tuOrphanCopy
    discard applyTakeOverUndo(e, u)
    check not fileExists(path)

  test "a decision whose inputs changed is not the same decision":
    let e = takenOver(path, Packaged1, AddOnCopy)
    let a = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    dropPkg("avahi", "1:0.8-1")
    pkg("avahi", "1:0.8-2", ["etc/avahi/avahi-daemon.conf"],
        [("etc/avahi/avahi-daemon.conf", md5Hex(Packaged2))])
    writeFile(pacnew, Packaged2)
    let b = decideTakeOverUndo(e, newPacmanDriver(root, noUnit))
    check sameDecision(a, a) and not sameDecision(a, b)

# ---------------------------------------------------------------------------
# The base identity's %FILES% digest.
# ---------------------------------------------------------------------------

suite "the base identity on a pacman base":
  test "package-files lines round-trip and change the digest":
    var b = BaseIdentity(id: "arch", architecture: "amd64",
      systemd: "systemd 258 (258.1-1-arch)",
      packages: @[BasePackage(name: "avahi", version: "1:0.8-1",
        architecture: "x86_64", status: "installed", filesSha256: "aa"),
        BasePackage(name: "pacman", version: "7.0.0-1",
        architecture: "x86_64", status: "installed", filesSha256: "bb")])
    b.packagesSha256 = packagesDigest(b.packages)
    let text = renderBaseIdentity(b)
    check "package-files\tavahi\taa\n" in text
    let back = parseBaseIdentity(text)
    check back == b
    var c = b
    c.packages[0].filesSha256 = "cc"
    check packagesDigest(c.packages) != b.packagesSha256
    check "package avahi: its %FILES% changed at version 1:0.8-1" in
      baseIdentityChanges(b, c)
    expect ValueError:
      discard parseBaseIdentity(text & "package-files\tnot-listed\tdd\n")

  test "a Debian record is unchanged: no package-files line":
    let b = BaseIdentity(id: "debian", packages: @[BasePackage(name: "dpkg",
      version: "1.22", architecture: "amd64", status: "installed")])
    check "package-files" notin renderBaseIdentity(b)
    check packagesDigest(b.packages) == sha256Hex("dpkg\t1.22\tamd64\tinstalled\n")

removeDir(root)
