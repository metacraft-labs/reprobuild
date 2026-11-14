## Unit tests for the add-on on an Arch-family base (spec ReproOS-Add-On-Mode
## §4.3.1, §4.3.2, §5.1, §6.1, §6.2, §6.4 step 0, §12.2): the pacman local
## database readers, the pacman collision driver's ownership half and its
## selection by os-release, the Arch base matrix (systemd and pacman majors),
## the snapper and network-manager records of the preflight, the Omarchy
## account check, the fingerprint's Arch components, generation 0 without an
## apt hook, and uninstall's refusal over a pending switch.
##
## *Mocking.* The pacman database, os-release, the password file, snapper's
## configuration and Omarchy's hook directory are real files in a fixture
## tree under a temporary root, in the formats pacman, snapper and Omarchy
## write (alpm-db(7), snapper-configs(5)). Two substitutions, each because
## the build host is not the guest: ``unitProvision`` is a closure over what
## ``systemctl show`` reports (the build host has no guest's systemd), and
## the Omarchy check's password-database lookup is a closure returning the
## fixture home (the build host's passwd has no Omarchy account). The live
## halves -- ``systemctl``, ``getpwnam``, ``btrfs subvolume list`` -- run in
## the Arch VM gates (``tests/e2e/addon/t_e2e_arch_addon_*``).

import std/[os, posix, strutils, tables, unittest]

import repro_infra/addon_diagnostics
import repro_addon/[base_identity, collision, fingerprint, generation0,
                    ledger, omarchy, pacman_db, preflight, static_tree,
                    uninstall]

let root = getTempDir() / ("repro-addon-arch-" & $getCurrentProcessId())
removeDir(root)

proc put(rel, content: string) =
  createDir(parentDir(root / rel))
  writeFile(root / rel, content)

proc pkg(name, version: string; files: openArray[string]; arch = "x86_64") =
  ## A package entry as pacman writes it into the local database.
  let dir = "var/lib/pacman/local/" & name & "-" & version
  put(dir & "/desc", "%NAME%\n" & name & "\n\n%VERSION%\n" & version &
    "\n\n%BASE%\n" & name & "\n\n%ARCH%\n" & arch & "\n\n")
  var f = "%FILES%\n"
  for p in files: f.add(p & "\n")
  f.add("\n%BACKUP%\n")
  put(dir & "/files", f)

put("var/lib/pacman/local/ALPM_DB_VERSION", "9\n")
pkg("pacman", "7.0.0.r6.gc685ae6-6", ["etc/", "etc/pacman.conf",
    "usr/", "usr/bin/", "usr/bin/pacman"])
pkg("openssh", "10.0p1-3", ["etc/ssh/", "etc/ssh/sshd_config",
    "usr/lib/systemd/system/sshd.service"])
pkg("avahi", "1:0.8+r194-3", ["etc/avahi/avahi-daemon.conf"])
pkg("systemd-libs", "258.1-1", ["usr/lib/libsystemd.so.0"])
put("etc/os-release", "NAME=\"Arch Linux\"\nID=arch\nBUILD_ID=rolling\n")
put("etc/app/app.conf", "x\n")
put("etc/ssh/sshd_config", "Port 22\n")
put("etc/passwd", "root:x:0:0::/root:/bin/bash\n" &
  "zahary:x:1000:1000::/home/zahary:/bin/bash\n")
put("etc/group", "root:x:0:\n")

proc at(p: string): string = root & p

let units = {
  "sshd.service": UnitProvision(loadState: "loaded",
    fragmentPath: "/usr/lib/systemd/system/sshd.service",
    unitFileState: "disabled", activeState: "inactive"),
  "new.service": UnitProvision(loadState: "not-found"),
}.toTable

proc provision(unit: string): UnitProvision {.gcsafe.} =
  {.cast(gcsafe).}:
    units.getOrDefault(unit)

suite "pacman's local database":
  test "sections, %FILES% paths and the package name":
    let s = pacmanSections("%NAME%\nfoo-bar\n\n%VERSION%\n1.2-3\n\n%DEPENDS%\n\n")
    check s["NAME"] == @["foo-bar"] and s["DEPENDS"].len == 0
    check pacmanFilesPaths("%FILES%\netc/\netc/a.conf\nusr/bin/x\n\n" &
      "%BACKUP%\netc/a.conf\tabc\n") == @["/etc", "/etc/a.conf", "/usr/bin/x"]
    check parsePacmanDesc("%NAME%\nlib32-glibc\n\n%VERSION%\n2.42-1\n").name ==
      "lib32-glibc"

  test "installed packages and their versions; pacman's major":
    check pacmanDbPresent(root)
    check pacmanInstalledVersion("pacman", root) == "7.0.0.r6.gc685ae6-6"
    check pacmanInstalledVersion("absent", root) == ""
    check pacmanMajor("7.0.0.r6.gc685ae6-6") == 7
    check pacmanMajor("1:7.1.0-1") == 7
    check pacmanMajor("6.1.0-3") == 6
    check pacmanMajor("") == 0

suite "the pacman driver (ownership half)":
  let d = newPacmanDriver(root, provision)

  test "ownership from %FILES%, no diversions":
    check d.name == "pacman" and not d.supportsDiversions
    check d.packageOwner(at("/etc/ssh/sshd_config")).package == "openssh"
    check d.packageOwner(at("/etc/avahi/avahi-daemon.conf")).package == "avahi"
    check d.packageOwner(at("/etc/app/app.conf")).package == ""
    check not d.diversion(at("/etc/ssh/sshd_config")).present
    check d.diversionTarget(at("/etc/ssh/sshd_config")) == ""

  test "a package-owned file is refused with no opt-in, naming the package":
    try:
      discard d.decide(DecisionInputs(address: "f", kind: tkFile,
        desiredContent: "y\n", desiredSha256: sha256Hex("y\n")),
        at("/etc/ssh/sshd_config"))
      check false
    except EAddOnPackageOwned as e:
      check "openssh" in e.msg

  test "divert is unavailable on the pacman base":
    try:
      discard d.decide(DecisionInputs(address: "f", kind: tkFile,
        collision: "divert", desiredContent: "y\n",
        desiredSha256: sha256Hex("y\n")), at("/etc/ssh/sshd_config"))
      check false
    except AddonCollisionError as e:
      check "has no diversions" in e.msg

  test "an unowned file is created; a package unit is EAddOnUnitShadows":
    let (dec, _) = d.decide(DecisionInputs(address: "f", kind: tkFile,
      desiredContent: "z\n", desiredSha256: sha256Hex("z\n")),
      at("/etc/app/new.conf"))
    check dec.verdict == cvCreate
    expect EAddOnUnitShadows:
      discard d.decide(DecisionInputs(address: "u", kind: tkUnit,
        unit: "sshd.service", desiredContent: "[Unit]\n",
        desiredSha256: sha256Hex("[Unit]\n")),
        at("/etc/systemd/system/sshd.service"))

  test "a package installed after the index was read is seen by the next lookup":
    check d.packageOwner(at("/etc/app/app.conf")).package == ""
    pkg("app", "1-1", ["etc/app/app.conf"])
    check d.packageOwner(at("/etc/app/app.conf")).package == "app"
    removeDir(root / "var/lib/pacman/local/app-1-1")
    check d.packageOwner(at("/etc/app/app.conf")).package == ""

  test "a damaged database fails closed":
    let r2 = root & "-damaged"
    removeDir(r2)
    createDir(r2 / "var/lib/pacman/local")
    expect AddonCollisionError:     # no ALPM_DB_VERSION
      discard newPacmanDriver(r2, provision).packageOwner(r2 / "etc/x")
    writeFile(r2 / "var/lib/pacman/local/ALPM_DB_VERSION", "9\n")
    expect AddonCollisionError:     # no package at all
      discard newPacmanDriver(r2, provision).packageOwner(r2 / "etc/x")
    createDir(r2 / "var/lib/pacman/local/x-1-1")
    writeFile(r2 / "var/lib/pacman/local/x-1-1/desc", "%VERSION%\n1-1\n")
    expect AddonCollisionError:     # an entry without %NAME%
      discard newPacmanDriver(r2, provision).packageOwner(r2 / "etc/x")
    removeDir(r2)

  test "the guard sees what the plan decided, and a package that appears after it":
    let inp = DecisionInputs(address: "f", kind: tkFile,
      desiredContent: "z\n", desiredSha256: sha256Hex("z\n"))
    let (dec, o) = d.decide(inp, at("/etc/app/late.conf"))
    let t = plannedTarget("f", inp, at("/etc/app/late.conf"), dec, o)
    check preWriteRefusal(d, t) == ""
    pkg("late", "1-1", ["etc/app/late.conf"])
    check "ownership observation changed" in preWriteRefusal(d, t)
    removeDir(root / "var/lib/pacman/local/late-1-1")

suite "choosing the driver":
  test "an Arch-family os-release selects pacman, even with a dpkg database":
    put("var/lib/dpkg/status", "Package: x\n")
    createDir(root / "var/lib/dpkg/info")
    check detectCollisionDriver(root).name == "pacman"
    put("etc/os-release", "ID=omarchy\nID_LIKE=arch\n")
    check detectCollisionDriver(root).name == "pacman"
    removeDir(root / "var/lib/dpkg")
    put("etc/os-release", "NAME=\"Arch Linux\"\nID=arch\nBUILD_ID=rolling\n")

  test "an Arch base without a pacman database is refused, never read as unowned":
    let r2 = root & "-nodb"
    removeDir(r2)
    createDir(r2 / "etc")
    writeFile(r2 / "etc/os-release", "ID=arch\n")
    expect AddonCollisionError:
      discard detectCollisionDriver(r2)
    removeDir(r2)

  test "a Debian base still gets dpkg":
    let r2 = root & "-deb"
    removeDir(r2)
    createDir(r2 / "var/lib/dpkg/info")
    writeFile(r2 / "var/lib/dpkg/status", "Package: x\n")
    createDir(r2 / "etc")
    writeFile(r2 / "etc/os-release", "ID=debian\nVERSION_ID=\"13\"\n")
    check detectCollisionDriver(r2).name == "dpkg"
    removeDir(r2)

suite "the Arch base matrix":
  test "the preflight's distribution verdict":
    check baseMatrixVerdict("arch", "", "", 258, "7.0.0-6").ok
    check baseMatrixVerdict("omarchy", "4.0.6", "arch", 258, "7.0.0-6").ok
    let old = baseMatrixVerdict("arch", "", "", 257, "7.0.0-6")
    check not old.ok and "below the Arch matrix's 258" in old.detail
    check not baseMatrixVerdict("arch", "", "", 258, "6.1.0-3").ok
    check not baseMatrixVerdict("arch", "", "", 258, "").ok
    check not baseMatrixVerdict("omarchy", "4.0.6", "", 258, "7.0.0").ok
    # The Debian rows are unchanged.
    check baseMatrixVerdict("debian", "13", "", 257, "").detail ==
      "debian 13 (supported)"
    check not baseMatrixVerdict("debian", "11", "", 257, "").ok

  test "the apply's gate reads the same row from the base identity":
    var b = BaseIdentity(id: "arch", architecture: "amd64",
      systemd: "systemd 258 (258.1-1-arch)",
      packages: @[BasePackage(name: "pacman", version: "7.0.0-6",
                              status: "installed")])
    check matrixRefusal(b) == ""
    b.systemd = "systemd 257 (257.9-1-arch)"
    check "below the Arch matrix" in matrixRefusal(b)
    b.systemd = "systemd 258 (258.1-1-arch)"
    b.packages = @[]
    check "pacman (not installed)" in matrixRefusal(b)
    expect EAddOnUnsupportedBase:
      checkSupportedBase(b)

suite "preflight records on Arch":
  test "snapper configurations for /":
    check snapperConfigSubvolume("# c\nSUBVOLUME=\"/\"\nFSTYPE=\"btrfs\"\n") == "/"
    check snapperConfigSubvolume("SUBVOLUME='/home'\n") == "/home"
    put("etc/snapper/configs/root", "SUBVOLUME=\"/\"\n")
    put("etc/snapper/configs/home", "SUBVOLUME=\"/home\"\n")
    check snapperRootConfigs(root) == @["root"]
    check snapperRootConfigs(root & "-none") == newSeq[string]()

  test "the active network manager, from is-active":
    check networkManagerFromIsActive("active\ninactive\n") == "NetworkManager"
    check networkManagerFromIsActive("inactive\nactive\n") == "systemd-networkd"
    check networkManagerFromIsActive("active\nactive\n") == "both"
    check networkManagerFromIsActive("inactive\ninactive\n") == "none"

suite "the Omarchy account":
  let home = root / "home/zahary"
  proc lookup(name: string): tuple[found: bool; home: string] =
    if name == "zahary": (true, home) else: (false, "")

  test "required on Omarchy, with its hook directory":
    let none = omarchyAccountProblem("omarchy", "", lookup)
    check none.diagnostic == adBaseLayerOwned and "names no" in none.detail
    check omarchyAccountProblem("omarchy", "nobody", lookup).diagnostic ==
      adBaseLayerOwned
    let missing = omarchyAccountProblem("omarchy", "zahary", lookup)
    check missing.diagnostic == adBaseLayerOwned
    check (home / ".config/omarchy/hooks") in missing.detail
    createDir(home / ".config/omarchy/hooks")
    check omarchyAccountProblem("omarchy", "zahary", lookup).detail == ""
    check omarchyAccountRefusal("omarchy", "zahary", lookup) == ""

  test "a link in place of the hook directory is not one":
    let h2 = root / "home/linked"
    createDir(h2 / ".config/omarchy")
    createSymlink(home / ".config/omarchy/hooks", h2 / ".config/omarchy/hooks")
    proc l2(name: string): tuple[found: bool; home: string] = (true, h2)
    check omarchyAccountProblem("omarchy", "linked", l2).detail.len > 0

  test "refused on a base that is not Omarchy, and not needed there":
    let p = omarchyAccountProblem("arch", "zahary", lookup)
    check p.diagnostic == adOutOfScope
    check omarchyAccountRefusal("arch", "zahary", lookup).startsWith(
      "EAddOnOutOfScope: ")
    check omarchyAccountProblem("arch", "", lookup).detail == ""
    check omarchyAccountProblem("debian", "", lookup).detail == ""

  test "the account is checked on an operator profile's apply only":
    check omarchyAccountChecked("apply", false, true)
    check not omarchyAccountChecked("apply", false, false)   # generation 0
    check not omarchyAccountChecked("replay", false, true)
    check not omarchyAccountChecked("revert", false, true)
    check not omarchyAccountChecked("apply", true, true)     # record-only

  test "Omarchy's version is os-release's and the package's":
    pkg("omarchy", "4.0.6-1", ["usr/share/omarchy/"])
    let f = omarchyFacts({"VERSION_ID": "4.0.6", "BUILD_ID": "4.0.6-2"}.toTable,
                         root)
    check f.versionId == "4.0.6" and f.buildId == "4.0.6-2"
    check f.packageVersion == "4.0.6-1"
    check isOmarchyBase("omarchy") and not isOmarchyBase("arch")

suite "the fingerprint on Arch":
  test "pacman-local records each package's version and files digest":
    let fp = collectFingerprint(CollectOptions(root: root, live: false))
    var seen = initTable[string, string]()
    for r in fp.records:
      check r.component notin {fcDpkgStatus, fcDiversions}
      if r.component == fcPacmanLocal: seen[r.key] = r.value
    check seen["pacman"] == "7.0.0.r6.gc685ae6-6 files-sha256:" &
      sha256OfFile(root / "var/lib/pacman/local/pacman-7.0.0.r6.gc685ae6-6/files")
    check "openssh" in seen
    # The text round-trips, so a gate can diff two saved fingerprints.
    check parseFingerprint(fp.render()).render() == fp.render()

  test "an upgrade shows as a changed pacman-local record":
    let before = collectFingerprint(CollectOptions(root: root, live: false))
    removeDir(root / "var/lib/pacman/local/avahi-1:0.8+r194-3")
    pkg("avahi", "1:0.8+r194-4", ["etc/avahi/avahi-daemon.conf"])
    let d = diff(before, collectFingerprint(CollectOptions(root: root,
                                                           live: false)))
    check d.len == 1 and d[0].component == fcPacmanLocal and
      d[0].key == "avahi" and d[0].op == doChanged

  test "omarchy-hooks records the account's hook tree":
    let opts = CollectOptions(root: root, live: false,
                              omarchyAccount: "zahary")
    let hooks = root / "home/zahary/.config/omarchy/hooks"
    createDir(hooks / "post-update.d")
    writeFile(hooks / "post-update.sample", "#!/bin/bash\n")
    let before = collectFingerprint(opts)
    var keys: seq[string]
    for r in before.records:
      if r.component == fcOmarchyHooks: keys.add(r.key)
    let rel = "/home/zahary/.config/omarchy/hooks"   # under its passwd home
    check keys.len == 3
    check rel & "/post-update.d" in keys
    writeFile(hooks / "post-update.d/90-repro-addon", "x\n")
    let d = diff(before, collectFingerprint(opts))
    check d.len == 1 and d[0].op == doAdded and
      d[0].key == rel & "/post-update.d/90-repro-addon"
    removeFile(hooks / "post-update.d/90-repro-addon")
    expect FingerprintError:
      discard collectFingerprint(CollectOptions(root: root, live: false,
                                                omarchyAccount: "nobody"))

  test "btrfs subvolume list and snapper userdata":
    let l = parseBtrfsSubvolumeList(
      "ID 256 gen 120 top level 5 path <FS_TREE>/@\n" &
      "ID 257 gen 99 top level 5 path <FS_TREE>/@home\n" &
      "ID 270 gen 130 top level 256 path <FS_TREE>/@/repro\n" &
      "ID 271 gen 131 top level 260 path @snapshots/1/snapshot\n")
    check l.len == 4
    check l[2] == (id: "270", parent: "256", path: "@/repro")
    check l[3].path == "@snapshots/1/snapshot"
    expect FingerprintError:
      discard parseBtrfsSubvolumeList("ID 256 gen 1 top level\n")
    check snapperUserdataHasAddonKey("<snapshot><userdata>\n  <key>repro-addon" &
      "</key>\n  <value>gen-3</value>\n</userdata></snapshot>")
    check not snapperUserdataHasAddonKey("<snapshot><userdata><key>important" &
      "</key><value>yes</value></userdata><description>repro-addon" &
      "</description></snapshot>")
    check not snapperUserdataHasAddonKey("<snapshot></snapshot>")

suite "the ledger's delta on a btrfs root":
  test "/repro as a subvolume accounts for one btrfs-subvolumes record":
    let sub = Ledger(entries: @[LedgerEntry(class: lcRoot, path: "/repro",
      kindHint: "btrfs-subvolume", mode: "0755", owner: "0:0")])
    let plain = Ledger(entries: @[LedgerEntry(class: lcRoot, path: "/repro",
      kindHint: "dir", mode: "0755", owner: "0:0")])
    let added = DiffEntry(op: doAdded, component: fcBtrfsSubvolumes,
      key: "repro", after: "id 259 parent 5")
    let roots = DiffEntry(op: doChanged, component: fcAddonRoots,
      key: "/repro", before: "absent", after: "btrfs-subvolume 0755 0:0")
    check matchExpectations(@[roots, added], expectedDelta(Ledger(), sub)).ok
    let undercover = DiffEntry(op: doAdded, component: fcBtrfsSubvolumes,
      key: "@/repro", after: "id 270 parent 256")
    check matchExpectations(@[roots, undercover],
                            expectedDelta(Ledger(), sub)).ok
    # A plain /repro accounts for no subvolume: one appearing is unexpected.
    let rootsPlain = DiffEntry(op: doChanged, component: fcAddonRoots,
      key: "/repro", before: "absent", after: "dir 0755 0:0")
    check not matchExpectations(@[rootsPlain, added],
                                expectedDelta(Ledger(), plain)).ok
    # Its removal by uninstall is accounted for the same way.
    let removed = DiffEntry(op: doRemoved, component: fcBtrfsSubvolumes,
      key: "repro", before: "id 259 parent 5")
    let rootsGone = DiffEntry(op: doChanged, component: fcAddonRoots,
      key: "/repro", before: "btrfs-subvolume 0755 0:0", after: "absent")
    check matchExpectations(@[rootsGone, removed],
                            expectedDelta(sub, Ledger())).ok

suite "generation 0 on Arch":
  test "no apt hook and nothing under /etc/apt; Debian keeps its hook":
    let exe = "/repro/store/prefixes/repro-addon/1-0123456789abcdef/bin/repro"
    var arch, deb: seq[string]
    for o in generation0Objects(Gen0Inputs(reproExe: exe,
                                           packageManagerHook: pmhNone)):
      arch.add(o.path)
    for o in generation0Objects(Gen0Inputs(reproExe: exe)):
      deb.add(o.path)
    check AptHookPath in deb
    for p in arch:
      check not p.startsWith("/etc/apt")
    check deb.len == arch.len + 1

suite "uninstall step 0":
  test "a pending marker in any place an apply looks refuses, naming it":
    let st = root / "state"
    let other = root / "addon-state"
    createDir(st)
    createDir(other)
    let pointerFile = root / "pointer"
    let me = int(getuid())
    check pendingSwitchRefusal(st, pointerFile, me) == ""
    # The add-on's own state directory, recorded by bootstrap, is looked in
    # even when uninstall was given another one.
    writeAddonStateDirPointer(other, pointerFile)
    writePendingMarker(other, PendingMarker(fromGeneration: "g1",
      attempt: "a-7", purpose: "apply"))
    let why = pendingSwitchRefusal(st, pointerFile, me)
    check pendingMarkerPath(other) in why
    check "attempt a-7" in why and "recover" in why
    clearPendingMarker(other)
    check pendingSwitchRefusal(st, pointerFile, me) == ""
    createDir(parentDir(pendingMarkerPath(st)))
    writeFile(pendingMarkerPath(st), "not a marker\n")
    check "unreadable" in pendingSwitchRefusal(st, pointerFile, me)

removeDir(root)
