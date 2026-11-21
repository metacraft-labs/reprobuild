## Unit tests for the add-on ledger (text round trip, ledger-to-fingerprint
## expectations and deltas), generation 0's rendering, and the preflight's
## pure fact parsers.
##
## No mocks: pure functions over real value types and captured file
## contents. One substitution: the unlisted-removal test plans against a
## fixture dpkg database and answers ``systemctl show`` with "not-found"
## (the build host has no guest systemd); it runs the real plan path. The end-to-end behaviour -- a real bootstrap's fingerprint
## diff equalling its ledger's delta -- is the VM gates' job
## (``tests/e2e/addon``).

import std/[json, options, os, posix, strutils, tables, unittest]

import repro_infra
import repro_infra/addon_diagnostics
import repro_profile
import repro_addon/[addon_apply, base_identity, collision, fingerprint, generation0, ledger, preflight, store_root]
import repro_elevation/posix_system_parse
import repro_elevation/nofollow_write
import repro_core/host_apply_lock
import repro_binary_cache_client/caches_config

proc sampleLedger(): Ledger =
  Ledger(generation: "g0", entries: @[
    LedgerEntry(class: lcRoot, path: "/repro", mode: "0755", owner: "0:0",
                kindHint: "dir"),
    LedgerEntry(class: lcRoot, path: "/etc/repro", mode: "0755", owner: "0:0",
                kindHint: "dir"),
    LedgerEntry(class: lcUnit, path: "/etc/systemd/system/repro-addon.target",
                unit: "repro-addon.target", sha256: "aa", mode: "0644",
                owner: "0:0", enabled: true, started: true, hasInstall: true,
                resource: "systemUnit:repro-addon.target"),
    LedgerEntry(class: lcInstallLink,
                path: "/etc/systemd/system/multi-user.target.wants/repro-addon.target",
                unit: "repro-addon.target",
                linkTarget: "/etc/systemd/system/repro-addon.target",
                resource: "systemUnit:repro-addon.target"),
    LedgerEntry(class: lcMount, path: "/repro/store", unit: "repro-store.mount"),
  ])

suite "ledger text":
  test "render and parse round-trip, including awkward characters":
    var l = sampleLedger()
    l.entries.add(LedgerEntry(class: lcEtcFile, path: "/etc/a\tb", sha256: "x"))
    let text = l.render()
    check text.startsWith(LedgerHeader)
    check parseLedger(text).render() == text

  test "a foreign file is refused":
    expect LedgerError:
      discard parseLedger("hello\n")

suite "ledger expectations":
  test "bootstrap from nothing: every record is an addition":
    let d = expectedDelta(Ledger(), sampleLedger())
    var lines: seq[string]
    for e in d: lines.add(renderExpectation(e))
    check "+ etc\t/etc/repro\td 0755 0:0" in lines
    check "+ etc\t/etc/systemd/system/repro-addon.target\tf 0644 0:0 sha256:aa" in lines
    check "+ unit-files\trepro-addon.target\tenabled" in lines
    check "+ active-units\trepro-addon.target\tactive" in lines
    check "+ mounts\t/repro/store\t*" in lines
    check "~ addon-roots\t/repro\tdir 0755 0:0" in lines

  test "a taken-over root expects no change when its value is unchanged":
    # A pre-bootstrap input (spec §6.1) carries the value it had before;
    # the bootstrap delta is then exact: nothing for an unchanged root,
    # a change for one whose mode bootstrap set.
    var l = Ledger(generation: "g0", entries: @[
      LedgerEntry(class: lcRoot, path: "/repro", mode: "0755", owner: "0:0",
                  kindHint: "dir", replaced: "dir 0755 0:0", collision: "adopt"),
      LedgerEntry(class: lcRoot, path: "/var/lib/repro", mode: "0755",
                  owner: "0:0", kindHint: "dir", replaced: "dir 0700 0:0",
                  collision: "adopt"),
      LedgerEntry(class: lcRoot, path: "/etc/repro", mode: "0755",
                  owner: "0:0", kindHint: "dir", replaced: "d 0755 0:0",
                  collision: "adopt")])
    check l.entries[0].isPreBootstrapInput
    var lines: seq[string]
    for e in expectedDelta(Ledger(), l): lines.add(renderExpectation(e))
    check lines == @["~ addon-roots\t/var/lib/repro\tdir 0755 0:0"]

  test "a kept agent record is never drift and never fingerprinted":
    let kept = LedgerEntry(class: lcKept,
      path: "/var/lib/repro/agent/state/deploy-agent/rpi2.seq",
      mode: "0600", owner: "0:0", collision: "adopt")
    check kept.isPreBootstrapInput
    check observeDrift(kept) == ""          # the path does not even exist
    check expectedRecords(Ledger(entries: @[kept])).len == 0

  test "uninstall back to nothing reverses each record":
    let d = expectedDelta(sampleLedger(), Ledger())
    var lines: seq[string]
    for e in d: lines.add(renderExpectation(e))
    check "- etc\t/etc/repro\td 0755 0:0" in lines
    check "~ addon-roots\t/repro\tabsent" in lines
    check "- mounts\t/repro/store\t*" in lines

  test "an unchanged ledger expects no difference":
    check expectedDelta(sampleLedger(), sampleLedger()).len == 0

  test "a replaced file is a change, and a diversion moves the original":
    let base = "f 0644 0:0 sha256:orig"
    let l = Ledger(generation: "g1", entries: @[
      LedgerEntry(class: lcDiversion, path: "/etc/issue.net", replaced: base,
                  resource: "dpkgDiversion:/etc/issue.net"),
      LedgerEntry(class: lcEtcFile, path: "/etc/issue.net", sha256: "new",
                  mode: "0644", owner: "0:0", replaced: base,
                  resource: "systemFile:/etc/issue.net")])
    var lines: seq[string]
    for e in expectedDelta(Ledger(), l): lines.add(renderExpectation(e))
    check "~ etc\t/etc/issue.net\tf 0644 0:0 sha256:new" in lines
    check "+ etc\t/etc/issue.net.distrib\t" & base in lines
    check "+ diversions\t/etc/issue.net\t/etc/issue.net.distrib :" in lines
    var back: seq[string]
    for e in expectedDelta(l, Ledger()): back.add(renderExpectation(e))
    check "~ etc\t/etc/issue.net\t" & base in back
    check "- etc\t/etc/issue.net.distrib\t" & base in back
    check "- diversions\t/etc/issue.net\t/etc/issue.net.distrib :" in back

suite "generation 0":
  let objs = generation0Objects(Gen0Inputs(
    reproExe: "/repro/store/prefixes/repro-addon/0.2.18-0123456789abcdef/bin/repro",
    deploySigners: @[], cachePublishers: @[]))

  test "the add-on's own objects, at their fixed paths":
    let paths = ownObjectPaths(objs)
    check "/etc/systemd/system/repro-addon.target" in paths
    check "/etc/systemd/system/repro-store.mount" in paths
    check "/etc/systemd/system/repro-addon-reassert.service" in paths
    check AptHookPath in paths
    check ProfileDPath in paths

  test "addOnToolPath() and generation 0 never write the same profile.d file":
    # One file, one writer (spec §4.1, §13 decision 18): the profile DSL's
    # hook for /etc/repro/bin is not generation 0's hook for the store
    # repro, so a profile cannot rewrite generation 0's object.
    check AddOnToolPathFile != ProfileDPath
    check AddOnToolPathFile notin ownObjectPaths(objs)
    check AddOnToolPathFile.startsWith("/etc/profile.d/")
    check "/etc/repro/bin" in AddOnToolPathScript

  test "the apt hook can never fail dpkg":
    for o in objs:
      if o.path == AptHookPath:
        # Bounded, never executing a missing binary, always exit 0
        # (the hook's behaviour is run in t_addon_apt_hook_and_base_identity).
        check "/usr/bin/setsid -w /bin/sh -c 'echo $$ > $2; [ -x $1 ]" in o.content
        check "repro-addon-hook-watchdog 60 " in o.content
        check o.content.strip().endsWith("exit 0\"; };")

  test "the re-assert unit is off the base's boot path and has no network":
    for o in objs:
      if o.unit == ReassertUnit:
        check "WantedBy=repro-addon.target" in o.content
        check "multi-user.target" notin o.content
        check "PrivateNetwork=yes" in o.content
        # Ordered after the store, never requiring it: a missing store
        # must still let it run and report `degraded` (§7.6, §7.7).
        check "After=local-fs.target repro-store.mount" in o.content
        check "Requires=" notin o.content
        check "system addon reassert --boot" in o.content
        check "if [ -x " in o.content and "degraded" in o.content
        assertInlineSafe("unit " & o.unit, o.content)

  test "the rendered profile parses, and refuses what it cannot carry":
    let text = renderOwnProfile(objs, "/repro/store/prefixes/repro-addon-files/x")
    let p = parseSystemProfile(text)
    check p.resources.len == objs.len
    expect ValueError:
      assertInlineSafe("unit", "ExecStart=/bin/sh -c \"x\"")

  test "a repro outside the store is refused":
    expect ValueError:
      discard generation0Objects(Gen0Inputs(reproExe: "/usr/bin/repro"))

  test "install targets and mount points are read from the unit text":
    check installTargets("[Unit]\n[Install]\nWantedBy=a.target b.target\nAlias=x.service\n") ==
      @[(kind: "WantedBy", target: "a.target"), (kind: "WantedBy", target: "b.target"),
        (kind: "Alias", target: "x.service")]
    check mountWhere("[Mount]\nWhat=/a\nWhere=/repro/store\n") == "/repro/store"

  test "every [Install] directive is read, and the links enable creates are derived":
    let u = "[Install]\nWantedBy=a.target\nRequiredBy=b.target\nUpheldBy=c.target\n" &
      "Alias=y.service\nAlso=z.service\nDefaultInstance=i\n"
    check installTargets(u).len == 6
    let links = installLinkPaths("x.service", u)
    var paths: seq[string]
    for l in links: paths.add(l.link)
    check paths == @["/etc/systemd/system/a.target.wants/x.service",
                     "/etc/systemd/system/b.target.requires/x.service",
                     "/etc/systemd/system/c.target.upholds/x.service",
                     "/etc/systemd/system/y.service"]

suite "preflight facts":
  test "os-release values are unquoted":
    let r = parseOsRelease("ID=debian\nVERSION_ID=\"13\"\nID_LIKE='debian'\n# x\n")
    check r["ID"] == "debian" and r["VERSION_ID"] == "13" and r["ID_LIKE"] == "debian"

  test "ELF headers name the userspace architecture":
    var x86 = "\x7fELF\x02" & repeat('\0', 13) & "\x3e\x00" & repeat('\0', 32)
    check elfArchitecture(x86) == "amd64"
    var a64 = "\x7fELF\x02" & repeat('\0', 13) & "\xb7\x00" & repeat('\0', 32)
    check elfArchitecture(a64) == "arm64"
    var arm = "\x7fELF\x01" & repeat('\0', 13) & "\x28\x00" & repeat('\0', 16) &
              "\x00\x04\x00\x05" & repeat('\0', 12)
    check elfArchitecture(arm) == "armhf"
    check elfArchitecture("not an elf") == ""

  test "systemd version and the fstab root entry":
    check systemdMajor("systemd 257 (257.8-1~deb13u2)\n+PAM +AUDIT") == 257
    check systemdMajor("garbage") == 0
    check fstabRootOptions("# c\nUUID=x / ext4 rw,discard,errors=remount-ro 0 1\n") ==
      "rw,discard,errors=remount-ro"

  test "canonical JSON sorts keys and is compact":
    check canonical(%*{"b": 1, "a": [true, "x"]}) == """{"a":[true,"x"],"b":1}"""

suite "store paths":
  test "the binary prefix is a function of its digest":
    let a = binaryPrefixPath(repeat('a', 64))
    check a.startsWith("/repro/store/prefixes/repro-addon/")
    check a == binaryPrefixPath(repeat('a', 64))
    check a != binaryPrefixPath(repeat('b', 64))
    check reproExeFor(repeat('a', 64)) == a & "/bin/repro"

suite "trust anchors and cache configuration":
  const k1 = "04" & repeat("a", 128)
  const k2 = "04" & repeat("B", 128)

  test "anchor keys are validated, lower-cased, de-duplicated and sorted":
    check parseAnchorKeys("# c\n" & k2 & "\n" & k1 & "\n" & k1 & "\n", "x") ==
      @[k1, toLowerAscii(k2)]
    expect ValueError:
      discard parseAnchorKeys("04abc\n", "x")

  test "caches.conf round-trips through the binary-cache client's parser":
    let text = renderCachesConf("https://cache.example:7878", @[k1])
    let entries = parseCachesText(text, "caches.conf")
    check entries.len == 1
    check entries[0].url == "https://cache.example:7878"
    check entries[0].trustedKeys.len == 1

  test "no cache configures none, and half a configuration is refused":
    check parseCachesText(renderCachesConf("", @[]), "caches.conf").len == 0
    expect ValueError:
      discard renderCachesConf("https://cache.example", @[])
    expect ValueError:
      discard renderCachesConf("", @[k1])
    expect ValueError:
      discard renderCachesConf("ftp://x", @[k1])

suite "undoing a reconciled object":
  test "a file the add-on created is deleted on undo even after a reconcile preserved bytes":
    let dir = getTempDir() / ("repro-addon-undo-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "x.conf", "x\n")
    writeFile(dir / "preserved", "x-mod\n")
    let created = LedgerEntry(class: lcEtcFile, path: dir / "x.conf",
      preserved: dir / "preserved", replaced: "", collision: "reconcile")
    check restorePreserved(created)
    check not fileExists(dir / "x.conf")
    check fileExists(dir / "preserved")
    # Nothing preserved: the caller deletes.
    check not restorePreserved(LedgerEntry(class: lcEtcFile, path: dir / "y"))

  test "a created link-form object is deleted on undo too":
    # Since the switch (§7.2) a managed file is a link into the static
    # tree; the undo of its creation removes the link, not what it names.
    let dir = getTempDir() / ("repro-addon-undo-link-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "tree-x.conf", "x\n")
    createSymlink(dir / "tree-x.conf", dir / "x.conf")
    writeFile(dir / "preserved", "x-mod\n")
    let created = LedgerEntry(class: lcEtcFile, path: dir / "x.conf",
      preserved: dir / "preserved", replaced: "", collision: "reconcile")
    check restorePreserved(created)
    check not symlinkExists(dir / "x.conf")
    check fileExists(dir / "tree-x.conf")

  test "a reconciled link-form object is restored as the file it replaced":
    # The flip left the add-on's link dangling (the new tree does not
    # carry the object); the pre-add-on bytes come back as a regular file.
    let dir = getTempDir() / ("repro-addon-undo-restore-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    createSymlink(dir / "gone-tree" / "r.conf", dir / "r.conf")
    writeFile(dir / "preserved", "theirs\n")
    let e = LedgerEntry(class: lcEtcFile, path: dir / "r.conf", form: "link",
      linkTarget: dir / "gone-tree" / "r.conf", preserved: dir / "preserved",
      replaced: "f 0644 " & $getuid() & ":" & $getgid() & " sha256:x",
      collision: "reconcile")
    check restorePreserved(e)
    check not symlinkExists(dir / "r.conf")
    check readFile(dir / "r.conf") == "theirs\n"

suite "drift on a link-form object":
  test "a regular file where the add-on's link was is drift, not a missing object":
    # An operator cannot write through the link into the read-only tree,
    # so a hand edit replaces it with a file. That file is theirs: the
    # removal must leave it in place (spec §4.2), which it does only when
    # the observation is a difference rather than "missing".
    let dir = getTempDir() / ("repro-addon-drift-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "tree-b.conf", "b\n")
    createSymlink(dir / "tree-b.conf", dir / "b.conf")
    let e = LedgerEntry(class: lcEtcFile, path: dir / "b.conf", form: "link",
      linkTarget: dir / "tree-b.conf", sha256: sha256Hex("b\n"))
    check observeDrift(e) == ""
    removeFile(dir / "b.conf")
    writeFile(dir / "b.conf", "b-modified\n")
    let d = observeDrift(e)
    check d.len > 0 and not d.startsWith("missing")
    check "regular file" in d
    removeFile(dir / "b.conf")
    check observeDrift(e).startsWith("missing")

suite "base matrix, managed kinds and ephemeral sockets":
  test "Raspberry Pi OS 13 is in the base matrix by its own ID":
    check baseMatrixNote("raspbian", "13") == "supported"
    let osr = parseOsRelease("ID=raspbian\nID_LIKE=debian\nVERSION_ID=\"13\"\n")
    check baseMatrixNote(osr["ID"], osr["VERSION_ID"]) == "supported"
    check baseMatrixNote("debian", "12") == "release-upgrade source"
    check baseMatrixNote("debian", "11") == ""
    check baseMatrixNote("ubuntu", "22.04") == ""

  test "a kind the add-on does not manage is refused by name":
    let p = parseSystemProfile("linux.udevRule {\n  name = \"x.rules\"\n  content = \"\"\n}\n")
    let why = unmanagedKindReason(p.resources[0])
    check "linux.udevRule" in why and "nothing was applied" in why
    let ok = parseSystemProfile("fs.systemFile {\n  path = \"/etc/x\"\n  content = \"y\"\n}\n")
    check unmanagedKindReason(ok.resources[0]) == ""

  test "unconnected UDP sockets on ephemeral ports are clients, not listeners":
    let udp = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
  1: 0F02000A:0044 00000000:0000 07 00000000:00000000 00:00000000 00000000   998        0 1 2 0000000000000000 0
  2: 0F02000A:985D 00000000:0000 07 00000000:00000000 00:00000000 00000000   991        0 1 2 0000000000000000 0
"""
    # 0x985D = 39005, inside the default range 32768..60999: a client.
    check parseProcNet(udp, "udp", 32768, 60999) == @[(key: "udp 10.0.2.15:68", value: "x1")]
    # Without a range every bound unconnected socket is recorded.
    check parseProcNet(udp, "udp").len == 2

suite "drift on a copy":
  test "a link where the add-on's copy was is drift, never a missing object":
    # Removal deletes a "missing" object's leftovers; an operator's link
    # put where the add-on's copy was is theirs and must be left.
    let dir = getTempDir() / ("repro-addon-copy-drift-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "c.conf", "c\n")
    let e = LedgerEntry(class: lcEtcFile, path: dir / "c.conf", form: "copy",
      sha256: sha256Hex("c\n"))
    check observeDrift(e) == ""
    removeFile(dir / "c.conf")
    writeFile(dir / "elsewhere", "c\n")
    createSymlink(dir / "elsewhere", dir / "c.conf")
    let d = observeDrift(e)
    check d.len > 0 and not d.startsWith("missing")
    check "symbolic link" in d and (dir / "elsewhere") in d
    removeFile(dir / "c.conf")
    createDir(dir / "c.conf")
    check observeDrift(e).startsWith("replaced by a directory")
    removeDir(dir / "c.conf")
    check observeDrift(e).startsWith("missing")

suite "ledger versions":
  test "a v1 ledger (A2's bootstrap, thirteen fields) is read":
    let v1 = "# repro-addon-ledger v1\n" &
      "generation\tg0\n" &
      "root\t/repro\t\t\t0755\t0:0\t\tdir\t0\t0\t0\t\t\n" &
      "unit\t/etc/systemd/system/repro-addon.target\trepro-addon.target\taa\t" &
        "0644\t0:0\t\t\t1\t1\t1\t\tsystemUnit:repro-addon.target\n" &
      "key\t/var/lib/repro/keys/x\t\tbb\t0600\t0:0\t\t\t0\t0\t0\t\t\n"
    let l = parseLedger(v1)
    check l.generation == "g0" and l.entries.len == 3
    check l.entries[0].class == lcRoot and l.entries[0].kindHint == "dir"
    check l.entries[1].enabled and l.entries[1].started and l.entries[1].hasInstall
    check l.entries[1].resource == "systemUnit:repro-addon.target"
    check l.entries[1].observation == "" and l.entries[1].form == ""
    check not l.entries[1].isLink
    check l.entries[2].class == lcKey and l.entries[2].sha256 == "bb"
    # The upgrade writes the current version, and that reads back the same.
    let again = parseLedger(render(l))
    check again.entries.len == 3 and again.entries[1] == l.entries[1]
    # A v1 line with the wrong field count is malformed, not guessed at.
    expect LedgerError:
      discard parseLedger("# repro-addon-ledger v1\ngeneration\tg0\nroot\t/repro\n")

suite "canonical target paths and prefixes (threat model G8)":
  test "a non-canonical fs.systemFile path is refused when the profile is parsed":
    for bad in ["/etc/ssh//sshd_config", "/etc/./ssh/sshd_config",
                "/etc/ssh/sshd_config/", "/etc/ssh/./sshd_config"]:
      try:
        discard parseSystemProfile("fs.systemFile {\n  path = \"" & bad &
          "\"\n  content = \"x\"\n}\n")
        check false
      except ESystemProfileInvalid as e:
        check "fs.systemFile path" in e.msg and bad in e.msg

  test "a non-canonical managed prefix is refused when the profile is parsed":
    for bad in ["/etc/./systemd/system/", "/etc//ssh/", "/etc/ssh//",
                "/etc/app/./"]:
      try:
        discard parseSystemProfile("addOn {\n  managedEtcPrefixes = [\"" &
          bad & "\"]\n}\n")
        check false
      except ESystemProfileInvalid as e:
        check "managed prefix" in e.msg and bad in e.msg
    # The canonical spellings still parse.
    let ok = parseSystemProfile("addOn {\n  managedEtcPrefixes = " &
      "[\"/etc/ssh/\", \"/etc/issue.net\"]\n}\n")
    check ok.addOn.managedEtcPrefixes == @["/etc/ssh/", "/etc/issue.net"]

  test "a non-canonical diversion path is refused when the profile is parsed":
    expect ESystemProfileInvalid:
      discard parseSystemProfile("linux.dpkgDiversion {\n  path = " &
        "\"/etc/ssh//sshd_config\"\n}\n")

  test "the scope check refuses a non-canonical path in a profile built in memory":
    # The parser is not the only producer of a profile: the scope check
    # repeats the canonical-form refusal on whatever reaches the apply.
    let p = SystemProfile(addOn: AddOnSettings(declared: true,
      managedEtcPrefixes: @["/etc/ssh/"]),
      resources: @[SystemResource(kind: srkFsSystemFile,
        address: "systemFile:/etc/ssh//sshd_config",
        sfPath: "/etc/ssh//sshd_config", sfContent: "x")])
    try:
      checkScope(p)
      check false
    except EAddOnOutOfScope as e:
      check "/etc/ssh//sshd_config" in e.msg and "empty segment" in e.msg
    # A class directory written without its trailing slash is still one.
    let q = SystemProfile(addOn: AddOnSettings(declared: true,
      managedEtcPrefixes: @["/etc/app/"]),
      resources: @[SystemResource(kind: srkFsSystemFile,
        address: "systemFile:/etc/systemd/system",
        sfPath: "/etc/systemd/system", sfContent: "x")])
    expect EAddOnOutOfScope:
      checkScope(q)

suite "names are valid exactly as written (no stripping)":
  test "a unit name with whitespace or outside systemd's rules is refused at parse":
    for bad in [" cron.service", "cron.service ", "cron service.service",
                "cron", ".service", "a@b@c.service", "cr\ton.service"]:
      try:
        discard parseSystemProfile("systemd.systemUnit {\n  name = \"" &
          bad & "\"\n  content = \"[Unit]\n\"\n}\n")
        check false
      except ESystemProfileInvalid as e:
        check "systemd.systemUnit name" in e.msg
    check systemdUnitNameError("u", "getty@tty1.service") == ""
    check systemdUnitNameError("u", "getty@.service") == ""
    check systemdUnitNameError("u", "sys-kernel-debug.mount") == ""

  test "drop-in, fragment, sysctl and account names are not stripped either":
    for text in [
        "systemd.systemDropIn {\n  unit = \" cron.service\"\n  name = \"x\"\n  content = \"\"\n}\n",
        "linux.tmpfilesRule {\n  name = \" repro-x.conf\"\n  content = \"\"\n}\n",
        "linux.sysctl {\n  key = \" vm.swappiness\"\n  value = \"1\"\n}\n",
        "linux.sysctl {\n  key = \"vm.swappiness\"\n  value = \"1\"\n  filename = \"90-repro-x.conf \"\n}\n",
        "linux.sysusersEntry {\n  name = \" fx\"\n  kind = \"group\"\n}\n"]:
      expect ESystemProfileInvalid:
        discard parseSystemProfile(text)

  test "the scope check refuses a non-canonical name in a profile built in memory":
    let p = SystemProfile(resources: @[SystemResource(kind: srkSystemdSystemUnit,
      address: "systemUnit: cron.service", suName: " cron.service",
      suContent: "[Unit]\n")])
    try:
      checkScope(p)
      check false
    except EAddOnOutOfScope as e:
      check "systemd.systemUnit name" in e.msg
    # The path the add-on observes is the driver's, character for character.
    check unitPath("cron.service") == "/etc/systemd/system/cron.service"
    check unitPath(" cron.service") == systemUnitPath(" cron.service")

  test "a managed prefix over a systemd unit, generator or preset directory is refused":
    for bad in ["/etc/systemd/system.control/", "/etc/systemd/system.attached/",
                "/etc/systemd/user/", "/etc/xdg/systemd/user/", "/etc/xdg/",
                "/etc/systemd/system-generators/", "/etc/systemd/",
                "/etc/systemd/system-preset/x.preset"]:
      check managedPrefixError(bad).len > 0
    check managedPrefixError("/etc/systemd/journald.conf.d/") == ""

suite "repro system adopt is scoped to the addressed resource":
  test "only the addressed resource is taken from the given profile":
    let current = "addOn {\n  managedEtcPrefixes = [\"/etc/app/\"]\n}\n\n" &
      "fs.systemFile {\n  path = \"/etc/app/a.conf\"\n  content = \"a1\"\n}\n"
    let given = parseSystemProfile("addOn {\n  managedEtcPrefixes = " &
      "[\"/etc/hand/\", \"/etc/hand/sub/\", \"/etc/other/\"]\n}\n\n" &
      "fs.systemFile {\n  path = \"/etc/app/a.conf\"\n  content = \"a2\"\n}\n\n" &
      "fs.systemFile {\n  path = \"/etc/app/b.conf\"\n  content = \"b\"\n}\n\n" &
      "fs.systemFile {\n  path = \"/etc/hand/h.conf\"\n  content = \"h\"\n}\n\n" &
      "fs.systemFile {\n  path = \"/etc/hand/sub/s.conf\"\n  content = \"s\"\n}\n")
    let p = scopedAdoptProfile(given, current, ["systemFile:/etc/hand/h.conf"])
    var byAddress = initTable[string, string]()
    for r in p.resources: byAddress[r.address] = r.sfContent
    # a.conf keeps the current generation's content (a2 is a pending
    # change the adopt must not apply); b.conf is not added.
    check byAddress.len == 2
    check byAddress["systemFile:/etc/app/a.conf"] == "a1"
    check byAddress["systemFile:/etc/hand/h.conf"] == "h"
    # Only the prefix the adopted path needs, not the given profile's others.
    check p.addOn.managedEtcPrefixes == @["/etc/app/", "/etc/hand/"]
    # The narrowest declared prefix covering the target wins.
    let q = scopedAdoptProfile(given, current, ["systemFile:/etc/hand/sub/s.conf"])
    check q.addOn.managedEtcPrefixes == @["/etc/app/", "/etc/hand/sub/"]
    # A path the current prefixes already cover adds none.
    let r2 = scopedAdoptProfile(given, current, ["systemFile:/etc/app/b.conf"])
    check r2.addOn.managedEtcPrefixes == @["/etc/app/"]
    expect AddonApplyError:
      discard scopedAdoptProfile(given, current, ["systemFile:/etc/nowhere"])

suite "a target accepted as changed out of band is reported once":
  test "one line per path, whichever passes decided it":
    # The apply collects these from its own-object pass and from the
    # operator's pass (adopt-scoped or not) and reports them through this
    # one helper (spec §4.3). A path both passes decided -- generation 0's
    # caches.conf and a profile declaring it -- is one line, the first
    # decider's; distinct paths keep their order. The fields are TABs.
    let lines = acceptedOutOfBandDiff(@[
      (path: "/etc/repro/caches.conf", address: "systemFile:/etc/repro/caches.conf"),
      (path: "/etc/app/a.conf", address: "systemFile:/etc/app/a.conf"),
      (path: "/etc/repro/caches.conf", address: "systemFile:/etc/repro/caches.conf")])
    check lines == @[
      "accepted-out-of-band\t/etc/repro/caches.conf\tsystemFile:/etc/repro/caches.conf",
      "accepted-out-of-band\t/etc/app/a.conf\tsystemFile:/etc/app/a.conf"]
    check acceptedOutOfBandDiff(@[]).len == 0

suite "removal by ledger: a resource with no ledger entry is never removed":
  test "the unlisted branch: listed as unlisted, neither destroyed nor restored":
    # A committed profile can name a resource the ledger holds nothing of
    # (an older release's partial apply, or a ledger an operator repaired).
    # Seeded directly: the previous operator profile declares c.conf, the
    # ledger has no entry for it, a same-named file exists. A plan that
    # drops the resource must report it unlisted and decide no removal --
    # the file is not the add-on's. (Plan only: no root, nothing written.)
    let state = getTempDir() / ("repro-addon-unlisted-" & $getCurrentProcessId())
    let etc = getTempDir() / ("repro-addon-unlisted-etc-" & $getCurrentProcessId())
    removeDir(state); removeDir(etc)
    createDir(state / "addon")
    defer:
      removeDir(state)
      removeDir(etc)
    writeFile(state / "addon" / "own.profile", "")
    writeFile(state / "addon" / "user.profile",
      "addOn {\n  managedEtcPrefixes = [\"/etc/repro-unlisted-fixture/\"]\n}\n\n" &
      "fs.systemFile {\n  path = \"/etc/repro-unlisted-fixture/c.conf\"\n" &
      "  content = \"c\"\n}\n")
    writeLedger(state / "addon-ledger", Ledger(generation: "g1"))
    createDir(etc / "var/lib/dpkg/info")
    writeFile(etc / "var/lib/dpkg/status", "")
    let d = newDpkgDriver(etc, proc(u: string): UnitProvision {.gcsafe.} =
      UnitProvision(loadState: "not-found"))
    let r = runAddonApply(AddonApplyOptions(stateDir: state,
      userProfileText: "addOn {\n  managedEtcPrefixes = " &
        "[\"/etc/repro-unlisted-fixture/\"]\n}\n",
      planOnly: true, driver: d,
      # The build host is not a matrix base; the plan is over a fixture.
      baseIdentity: some(BaseIdentity(id: "debian", versionId: "13",
                                      architecture: "amd64"))))
    check r.unlisted == @["systemFile:/etc/repro-unlisted-fixture/c.conf"]
    check r.removed.len == 0
    check "unlisted\tsystemFile:/etc/repro-unlisted-fixture/c.conf\t" &
          "systemFile:/etc/repro-unlisted-fixture/c.conf" in r.ledgerDiff

suite "install links are removed only while they are the add-on's":
  test "removeLinkIfTarget leaves a file, a directory or a re-pointed link":
    let dir = getTempDir() / ("repro-addon-linkrm-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    createSymlink("/etc/systemd/system/x.service", dir / "a.service")
    check removeLinkIfTarget(dir / "a.service", "/elsewhere") == lrDifferent
    check symlinkExists(dir / "a.service")
    check removeLinkIfTarget(dir / "a.service", "/etc/systemd/system/x.service") == lrRemoved
    check not symlinkExists(dir / "a.service")
    check removeLinkIfTarget(dir / "a.service", "/etc/systemd/system/x.service") == lrAbsent
    writeFile(dir / "a.service", "[Service]\n")
    check removeLinkIfTarget(dir / "a.service", "/etc/systemd/system/x.service") == lrDifferent
    check readFile(dir / "a.service") == "[Service]\n"
    let e = LedgerEntry(class: lcInstallLink, path: dir / "a.service",
                        linkTarget: "/etc/systemd/system/x.service")
    check observeDrift(e).startsWith("replaced by a regular file")
    removeFile(dir / "a.service")
    check observeDrift(e).startsWith("missing")

suite "the host-wide apply lock and the add-on's roots":
  test "bootstrap's own lock never changes the preflight plan it re-checks":
    # Bootstrap takes the host-wide apply lock, then re-runs the preflight
    # and refuses unless the plan digest equals the acknowledged one. The
    # preflight requires every add-on root to be absent and the fingerprint
    # records them, so a lock file inside one (it once lived at
    # /run/repro/apply.lock) made every bootstrap refuse itself.
    let lockPath = hostApplyLockPathFor(true, "")
    for root in @AddonOwnedRoots & @AddonRootPaths:
      check not (lockPath == root or lockPath.startsWith(root & "/"))
