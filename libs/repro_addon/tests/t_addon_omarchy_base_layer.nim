## Unit tests for Omarchy as a third owner (spec ReproOS-Add-On-Mode §4.3.2,
## §8.4): the ``/etc`` tokens of a script, the Omarchy path set read from the
## installed ``omarchy`` package with each path's scripts and package owners,
## the intersections of a managed prefix, a file and a unit with the set, the
## plan-time check of an operator profile with its ``collision =
## "overrideBaseLayer"`` acknowledgements, and the refusal of that opt-in on a
## base with no configuration layer.
##
## *Mocking.* None of the add-on's code is replaced. The pacman database and
## the ``omarchy`` package's scripts are real files in a fixture tree under a
## temporary root, in the format pacman writes (alpm-db(7)); the profile is
## parsed from its text form by the parser the apply uses. The live halves --
## preflight reading the guest's installed package, a plan refused on the
## Omarchy VM -- run in the VM gate ``e2e_omarchy_addon_base_layer_refusal``.
##
## *Falsifying mutation.* Compiled with
## ``-d:reproAddonMutation=omarchy-path-set-empty`` the reader returns no
## path, and the cases that read the fixture's set go red.

import std/[os, strutils, unittest]

import repro_infra/addon_diagnostics
import repro_infra/profile
import repro_addon/[collision, omarchy, pacman_db]

let root = getTempDir() / ("repro-addon-omarchy-" & $getCurrentProcessId())
removeDir(root)

proc put(rel, content: string) =
  createDir(parentDir(root / rel))
  writeFile(root / rel, content)

proc pkg(name, version: string; files: openArray[string]) =
  ## A package entry as pacman writes it into the local database.
  let dir = "var/lib/pacman/local/" & name & "-" & version
  put(dir & "/desc", "%NAME%\n" & name & "\n\n%VERSION%\n" & version &
    "\n\n%ARCH%\nany\n\n")
  var f = "%FILES%\n"
  for p in files: f.add(p & "\n")
  f.add("\n")
  put(dir & "/files", f)

const
  Install = "usr/share/omarchy/install/"
  Migrations = "usr/share/omarchy/migrations/"
  SshScript = "/usr/share/omarchy/install/config/ssh.sh"
  SudoScript = "/usr/share/omarchy/install/config/sudo.sh"
  Migration = "/usr/share/omarchy/migrations/1780000000.sh"

proc fixtureBase() =
  removeDir(root)
  put("var/lib/pacman/local/ALPM_DB_VERSION", "9\n")
  pkg("omarchy", "4.5.0-3", ["usr/", "usr/share/", "usr/share/omarchy/",
    Install, Install & "config/", Install & "config/ssh.sh",
    Install & "config/sudo.sh", Install & "omarchy-base.packages",
    Migrations, Migrations & "1780000000.sh",
    "usr/share/omarchy/bin/omarchy-update"])
  pkg("omarchy-settings", "4.5.0-1", ["etc/", "etc/ssh/",
    "etc/ssh/sshd_config.d/", "etc/ssh/sshd_config.d/10-omarchy-hardening.conf"])
  pkg("sudo", "1.9.17-1", ["etc/", "etc/sudoers.d/", "etc/sudoers"])
  put(Install & "config/ssh.sh",
    "sudo mkdir -p /etc/ssh/sshd_config.d\n" &
    "sudo cp x /etc/ssh/sshd_config.d/10-omarchy-hardening.conf\n" &
    "echo 'ServerAliveInterval 30' | sudo tee " &
      "/etc/ssh/ssh_config.d/20-omarchy-keepalive.conf\n")
  put(Install & "config/sudo.sh",
    "echo 'x ALL=(ALL) NOPASSWD: /usr/bin/reboot' | sudo tee " &
      "/etc/sudoers.d/99-omarchy-installer-reboot\n" &
    "sudo chmod 440 /etc/sudoers.d/*\n" &
    "sudo cp f.service /etc/systemd/system/omarchy-nvme-suspend-fix.service\n" &
    "sudo mkdir -p /etc/systemd/system/fprintd.service.d\n" &
    "sudo ln -s x /etc/systemd/system/multi-user.target.wants/" &
      "omarchy-thunderbolt-authorization.service\n" &
    "sudo mkdir -p /etc/systemd/system/v4l2-relayd@camlink.service.d\n" &
    "ls /etc/systemd/system/\n")
  put(Install & "omarchy-base.packages", "hyprland\nsddm\n")
  put(Migrations & "1780000000.sh",
    "sudo sed -i 's/x/y/' /etc/ssh/sshd_config.d/10-omarchy-hardening.conf\n" &
    "sudo cp a $target_root/etc/omarchy/language\n")
  # Not the package's: a file it does not list is not read.
  put(Install & "stray.sh", "sudo tee /etc/stray.conf\n")
  put("usr/share/omarchy/bin/omarchy-update", "cat /etc/not-a-script-path\n")

proc pathsOf(s: OmarchyPathSet): seq[string] =
  for e in s.paths: result.add(e.path)

proc entry(s: OmarchyPathSet; path: string): OmarchyPath =
  for e in s.paths:
    if e.path == path: return e
  raise newException(KeyError, path & " is not in the set")

proc profileOf(text: string): SystemProfile = parseSystemProfile(text)

suite "the /etc tokens of a script":
  test "every /etc/ occurrence starts a token, whatever precedes it":
    check etcPathTokens("cp a /etc/foo.conf; cp b $root/etc/bar/baz\n") ==
      @["/etc/foo.conf", "/etc/bar/baz"]

  test "a variable or a glob ends the token, which then names the directory":
    check etcPathTokens("tee /etc/limine-entry-tool.d/$name.conf") ==
      @["/etc/limine-entry-tool.d"]
    check etcPathTokens("chmod 440 /etc/sudoers.d/*") == @["/etc/sudoers.d"]
    check etcPathTokens("\"/etc/systemd/network/x-${n}\"") ==
      @["/etc/systemd/network/x-"]

  test "repeated and trailing slashes, and a sentence's full stop":
    check etcPathTokens("see /etc//pam.d/ and /etc/ufw/ufw.conf.") ==
      @["/etc/pam.d", "/etc/ufw/ufw.conf"]

  test "/etc itself and a . or .. segment are not paths of the set":
    check etcPathTokens("ls /etc/ ; cd /etc/./x; cat /etc/../y") == newSeq[string]()

  test "each path once, in order of first appearance":
    check etcPathTokens("/etc/b /etc/a /etc/b") == @["/etc/b", "/etc/a"]

  test "a colon, a quote or white space ends it":
    check etcPathTokens("PATH=/etc/a:/etc/b 'x/etc/c' /etc/d\t") ==
      @["/etc/a", "/etc/b", "/etc/c", "/etc/d"]

suite "the Omarchy path set from the installed omarchy package":
  test "every listed file under install/ and migrations/, nothing else":
    fixtureBase()
    let s = readOmarchyPathSet(root)
    check s.problem == ""
    check s.packageVersion == "4.5.0-3"
    check s.scriptCount == 4
    check pathsOf(s) == @["/etc/omarchy/language",
      "/etc/ssh/ssh_config.d/20-omarchy-keepalive.conf",
      "/etc/ssh/sshd_config.d", "/etc/ssh/sshd_config.d/10-omarchy-hardening.conf",
      "/etc/sudoers.d", "/etc/sudoers.d/99-omarchy-installer-reboot",
      "/etc/systemd/system",
      "/etc/systemd/system/fprintd.service.d",
      "/etc/systemd/system/multi-user.target.wants/omarchy-thunderbolt-authorization.service",
      "/etc/systemd/system/omarchy-nvme-suspend-fix.service",
      "/etc/systemd/system/v4l2-relayd@camlink.service.d"]
    check "/etc/stray.conf" notin pathsOf(s)
    check "/etc/not-a-script-path" notin pathsOf(s)

  test "each path names every script, and every package that also owns it":
    fixtureBase()
    let s = readOmarchyPathSet(root)
    let hard = entry(s, "/etc/ssh/sshd_config.d/10-omarchy-hardening.conf")
    check hard.scripts == @[SshScript, Migration]
    check hard.owners == @["omarchy-settings"]
    check entry(s, "/etc/sudoers.d").owners == @["sudo"]
    check entry(s, "/etc/ssh/sshd_config.d").owners == @["omarchy-settings"]
    check entry(s, "/etc/sudoers.d/99-omarchy-installer-reboot").owners.len == 0
    check describe(hard) == "/etc/ssh/sshd_config.d/10-omarchy-hardening.conf " &
      "(named by " & SshScript & ", " & Migration &
      "; also owned by package omarchy-settings)"

  test "fails closed: the omarchy package not installed":
    fixtureBase()
    removeDir(root / "var/lib/pacman/local/omarchy-4.5.0-3")
    let s = readOmarchyPathSet(root)
    check s.paths.len == 0 and "not installed" in s.problem

  test "fails closed: a listed script missing, or a link":
    fixtureBase()
    removeFile(root / Install & "config/sudo.sh")
    check "missing" in readOmarchyPathSet(root).problem
    createSymlink(root / Install & "config/ssh.sh", root / Install & "config/sudo.sh")
    let s = readOmarchyPathSet(root)
    check s.paths.len == 0 and "not a regular file" in s.problem

  test "fails closed: no file listed under install/ or migrations/":
    fixtureBase()
    removeDir(root / "var/lib/pacman/local/omarchy-4.5.0-3")
    pkg("omarchy", "4.5.0-3", ["usr/share/omarchy/bin/omarchy-update"])
    check "lists no file" in readOmarchyPathSet(root).problem

  test "fails closed: a damaged package database entry":
    fixtureBase()
    removeFile(root / "var/lib/pacman/local/sudo-1.9.17-1/files")
    let s = readOmarchyPathSet(root)
    check s.paths.len == 0 and "owners" in s.problem

suite "intersections with the set":
  setup:
    fixtureBase()
    let s = readOmarchyPathSet(root)

  test "a file: the path itself, or inside a directory of the set":
    check fileIntersections(s, "/etc/sudoers.d/repro-fx").len == 1
    check fileIntersections(s, "/etc/ssh/sshd_config.d/10-omarchy-hardening.conf").len == 2
    check fileIntersections(s, "/etc/ssh/sshd_config").len == 0
    check fileIntersections(s, "/etc/sudoers.dx").len == 0

  test "a prefix: every path of the set at or below it, with or without /":
    check prefixIntersections(s, "/etc/ssh/").len == 3
    check prefixIntersections(s, "/etc/ssh").len == 3
    check prefixIntersections(s, "/etc/sudoers.d/").len == 2
    # A prefix inside a directory of the set covers no path of it; a file
    # declared under it meets the file rule.
    check prefixIntersections(s, "/etc/sudoers.d/repro-fx").len == 0
    check prefixIntersections(s, "/etc/sshx/").len == 0

  test "a unit by name: its file, its drop-in directory, a dependency link":
    check unitsNamedBy("/etc/systemd/system/omarchy-nvme-suspend-fix.service") ==
      @["omarchy-nvme-suspend-fix.service"]
    check unitsNamedBy("/etc/systemd/system/fprintd.service.d/10-x.conf") ==
      @["fprintd.service"]
    check unitsNamedBy("/etc/systemd/system/multi-user.target.wants/a.service") ==
      @["a.service"]
    check unitsNamedBy("/etc/systemd/system").len == 0
    check unitsNamedBy("/etc/systemd/network/x.network").len == 0
    check unitIntersections(s, "omarchy-nvme-suspend-fix.service").len == 1
    check unitIntersections(s, "fprintd.service").len == 1
    check unitIntersections(s, "omarchy-thunderbolt-authorization.service").len == 1
    check unitIntersections(s, "sshd.service").len == 0

  test "a unit's file path alone never intersects (every unit is under /etc/systemd/system)":
    check unitIntersections(s, "repro-fx.service").len == 0

  test "a template and its instances":
    check unitIntersections(s, "v4l2-relayd@camlink.service").len == 1
    check unitIntersections(s, "v4l2-relayd@.service").len == 1
    check unitIntersections(s, "v4l2-relayd@other.service").len == 0

suite "the plan-time check of an operator profile":
  setup:
    fixtureBase()
    let s = readOmarchyPathSet(root)

  test "a prefix, a file and a unit are each refused, naming the scripts":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/ssh/\", \"/etc/sudoers.d/repro-fx\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/sudoers.d/repro-fx\"\n  content = \"# x\n\"\n}\n" &
      "systemd.systemUnit {\n  name = \"omarchy-nvme-suspend-fix.service\"\n" &
        "  content = \"[Service]\nExecStart=/bin/true\n\"\n}\n"))
    check c.refusals.len == 3
    check c.overrides.len == 0
    let why = baseLayerRefusal(s, c)
    check why.startsWith("EAddOnBaseLayerOwned: Omarchy 4.5.0-3")
    check "managed prefix /etc/ssh/ covers" in why
    check SshScript in why and SudoScript in why
    check "also owned by package omarchy-settings" in why
    check "/etc/sudoers.d/repro-fx is written by the base layer" in why
    check "omarchy-nvme-suspend-fix.service is a unit" in why
    check "a prefix carries no `collision`" in why
    check "overrideBaseLayer" in why

  test "overrideBaseLayer acknowledges a file or a unit, and the plan lists it":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/sudoers.d/repro-fx\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/sudoers.d/repro-fx\"\n  content = \"# x\n\"\n" &
        "  collision = \"overrideBaseLayer\"\n}\n" &
      "systemd.systemUnit {\n  name = \"omarchy-nvme-suspend-fix.service\"\n" &
        "  content = \"[Service]\nExecStart=/bin/true\n\"\n" &
        "  collision = \"overrideBaseLayer\"\n}\n"))
    check c.refusals.len == 0
    check baseLayerRefusal(s, c) == ""
    check c.overrides.len == 2
    check c.overrides[0].startsWith("systemFile:/etc/sudoers.d/repro-fx\t")
    check "\t/etc/sudoers.d/repro-fx\t/etc/sudoers.d (named by " & SudoScript in
      c.overrides[0]
    check "\tomarchy-nvme-suspend-fix.service\t" in c.overrides[1]

  test "an acknowledgement of a path no script names is listed as acknowledging nothing":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/app/\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/app/a.conf\"\n  content = \"x\n\"\n" &
        "  collision = \"overrideBaseLayer\"\n}\n"))
    check c.refusals.len == 0
    check c.overrides.len == 1 and "acknowledges nothing" in c.overrides[0]

  test "a path with a package owner too: one opt-in cannot acknowledge both":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/ssh/sshd_config.d/10-omarchy-hardening.conf\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/ssh/sshd_config.d/10-omarchy-hardening.conf\"\n" &
        "  content = \"x\n\"\n  collision = \"takeOver\"\n}\n"))
    # The prefix covers the file, and the file is not acknowledged.
    check c.refusals.len == 2
    check "also owned by package omarchy-settings" in c.refusals[1]
    check "no opt-in covers both" in c.refusals[1]

  test "a prefix narrowed to an acknowledged file of the set is not refused":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/ssh/sshd_config.d/10-omarchy-hardening.conf\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/ssh/sshd_config.d/10-omarchy-hardening.conf\"\n" &
        "  content = \"x\n\"\n  collision = \"overrideBaseLayer\"\n}\n"))
    check c.refusals.len == 0 and c.overrides.len == 1

  test "a wider prefix stays refused for the set paths no file acknowledges":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/sudoers.d/\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/sudoers.d/repro-fx\"\n" &
        "  content = \"# x\n\"\n  collision = \"overrideBaseLayer\"\n}\n"))
    check c.refusals.len == 1
    check "/etc/sudoers.d/99-omarchy-installer-reboot" in c.refusals[0]
    check "covers /etc/sudoers.d (" notin c.refusals[0]

  test "a drop-in, a unit state and a timer of a unit the set names have no acknowledgement":
    let c = baseLayerCheck(s, profileOf(
      "systemd.systemDropIn {\n  unit = \"fprintd.service\"\n  name = \"x\"\n" &
        "  content = \"[Service]\nX=1\n\"\n}\n" &
      "systemd.unitState {\n  name = \"omarchy-thunderbolt-authorization.service\"\n" &
        "  enabled = false\n}\n"))
    check c.refusals.len == 2
    for r in c.refusals: check "has no acknowledgement" in r

  test "a unit with collision = dropIn on a unit the set names is refused":
    let c = baseLayerCheck(s, profileOf(
      "systemd.systemUnit {\n  name = \"fprintd.service\"\n" &
        "  content = \"[Service]\nX=1\n\"\n  collision = \"dropIn\"\n}\n"))
    check c.refusals.len == 1 and "no opt-in covers both" in c.refusals[0]

  test "a profile that intersects nothing passes":
    let c = baseLayerCheck(s, profileOf(
      "addOn {\n  managedEtcPrefixes = [\"/etc/app/\"]\n}\n" &
      "fs.systemFile {\n  path = \"/etc/app/a.conf\"\n  content = \"x\n\"\n}\n" &
      "systemd.systemUnit {\n  name = \"app.service\"\n" &
        "  content = \"[Service]\nExecStart=/bin/true\n\"\n}\n"))
    check c.refusals.len == 0 and c.overrides.len == 0

  test "a set that cannot be read refuses every plan":
    var broken = s
    broken.paths = @[]
    broken.problem = "the omarchy package is not installed"
    let why = baseLayerRefusal(broken, baseLayerCheck(broken, profileOf("")))
    check why.startsWith("EAddOnBaseLayerOwned: the omarchy package is not installed")

suite "overrideBaseLayer on a base with no configuration layer":
  test "the profile parser accepts it on a file and on a unit":
    let p = profileOf(
      "fs.systemFile {\n  path = \"/etc/a\"\n  content = \"x\n\"\n" &
        "  collision = \"overrideBaseLayer\"\n}\n" &
      "systemd.systemUnit {\n  name = \"a.service\"\n  content = \"[Service]\n\"\n" &
        "  collision = \"overrideBaseLayer\"\n}\n")
    check p.resources[0].sfCollision == OverrideBaseLayer
    check p.resources[1].suCollision == OverrideBaseLayer

  test "refused by name on a dpkg base; accepted on a pacman base":
    let dpkg = newDpkgDriver(root)
    expect EAddOnOutOfScope:
      refuseOptInForBase(dpkg, "fs.systemFile[a]", OverrideBaseLayer)
    try:
      refuseOptInForBase(dpkg, "systemd.systemUnit[a]", OverrideBaseLayer,
                         "systemd.systemUnit.collision")
      check false
    except EAddOnOutOfScope as e:
      check "systemd.systemUnit.collision" in e.msg
      check "the dpkg base has none to override" in e.msg
    refuseOptInForBase(newPacmanDriver(root), "fs.systemFile[a]", OverrideBaseLayer)

removeDir(root)
