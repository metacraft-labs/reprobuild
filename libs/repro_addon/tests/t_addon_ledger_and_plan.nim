## Unit tests for the add-on ledger (text round trip, ledger-to-fingerprint
## expectations and deltas), generation 0's rendering, and the preflight's
## pure fact parsers.
##
## No mocks: pure functions over real value types and captured file
## contents. The end-to-end behaviour -- a real bootstrap's fingerprint
## diff equalling its ledger's delta -- is the VM gates' job
## (``tests/e2e/addon``).

import std/[json, strutils, tables, unittest]

import repro_infra
import repro_profile
import repro_addon/[addon_apply, fingerprint, generation0, ledger, preflight, store_root]
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
        check "|| true" in o.content
        check "if [ -x " in o.content

  test "the re-assert unit is off the base's boot path and has no network":
    for o in objs:
      if o.unit == ReassertUnit:
        check "WantedBy=repro-addon.target" in o.content
        check "multi-user.target" notin o.content
        check "PrivateNetwork=yes" in o.content

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
