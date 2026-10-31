## Unit tests for the add-on base fingerprint: the parsers, the canonical
## text round trip, the diff, exceptions and exact ledger expectations.
##
## No mocks: the parsers are exercised on text captured from real Debian 13
## and Ubuntu 24.04 guests (the shapes ``systemctl`` and ``/proc`` really
## emit), and ``collectFingerprint`` runs against a real fixture directory
## tree in a temporary directory with ``live = false``, which reads only
## files. The live components (units, sysctl, mounts, listeners) are
## exercised end to end by the VM gates under ``tests/e2e/addon``.

import std/[os, strutils, unittest]

import repro_addon/fingerprint

suite "fingerprint parsers":
  test "dpkg status stanzas become name:arch records":
    let text = """Package: base-files
Status: install ok installed
Priority: required
Architecture: amd64
Version: 13.8
Description: Debian base system miscellaneous files
 This package contains the basic filesystem hierarchy.

Package: jq
Status: install ok installed
Architecture: amd64
Version: 1.7.1-6
"""
    let r = parseDpkgStatus(text)
    check r.len == 2
    check r[0] == (key: "base-files:amd64", value: "13.8 install ok installed")
    check r[1].key == "jq:amd64"

  test "a stanza without Package is refused":
    expect FingerprintError:
      discard parseDpkgStatus("Status: install ok installed\nVersion: 1\n")

  test "diversions are line triples":
    let r = parseDiversions("/etc/issue.net\n/etc/issue.net.distrib\n:\n")
    check r == @[(key: "/etc/issue.net", value: "/etc/issue.net.distrib :")]
    expect FingerprintError:
      discard parseDiversions("/a\n/b\n")

  test "passwd and group drop the password field":
    check parsePasswd("root:x:0:0:root:/root:/bin/bash\n") ==
      @[(key: "user:root", value: "0:0:root:/root:/bin/bash")]
    check parseGroup("sudo:x:27:debian\n") ==
      @[(key: "group:sudo", value: "27:debian")]

  test "mountinfo drops ids and volatile mounts, numbers stacked mounts":
    let text = """22 1 254:1 / / rw,relatime shared:1 - ext4 /dev/vda1 rw,discard,errors=remount-ro
60 22 0:52 / /run/user/1000 rw,nosuid,nodev,relatime shared:300 - tmpfs tmpfs rw,size=200k
61 22 254:1 /repro/store /repro/store ro,relatime shared:1 - ext4 /dev/vda1 rw
62 61 254:1 /repro/store /repro/store rw,relatime shared:1 - ext4 /dev/vda1 rw
70 22 0:60 / /mnt/with\040space rw - tmpfs tmpfs rw
"""
    let r = parseMountinfo(text)
    check r.len == 4
    check r[0] == (key: "/", value: "ext4 /dev/vda1 rw,relatime rw,discard,errors=remount-ro")
    check r[1].key == "/repro/store"
    check r[2].key == "/repro/store#2"
    check r[3].key == "/mnt/with space"

  test "proc net tables keep listeners only":
    let tcp = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000 100 0 0 10 0
   1: 0F02000A:0016 0202000A:C350 01 00000000:00000000 02:000A7B5E 00000000     0        0 2 4 0000000000000000 20 4 30 10 -1
   2: 3500007F:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000   991        0 3 1 0000000000000000 100 0 0 10 0
"""
    check parseProcNet(tcp, "tcp") ==
      @[(key: "tcp 0.0.0.0:22", value: "x1"), (key: "tcp 127.0.0.53:53", value: "x1")]
    let udp = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
  1: 0F02000A:0044 00000000:0000 07 00000000:00000000 00:00000000 00000000   998        0 1 2 0000000000000000 0
  2: 0F02000A:D1A3 0302000A:0035 01 00000000:00000000 00:00000000 00000000   991        0 1 2 0000000000000000 0
"""
    check parseProcNet(udp, "udp") == @[(key: "udp 10.0.2.15:68", value: "x1")]
    let tcp6 = """  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0000000000000000 100 0 0 10 0
"""
    check parseProcNet(tcp6, "tcp6") ==
      @[(key: "tcp6 [0000:0000:0000:0000:0000:0000:0000:0000]:22", value: "x1")]

  test "systemctl tables drop runtime-only units and inactive ones":
    let files = """ssh.service                    enabled  enabled
session-3.scope                transient -
repro-addon.target             enabled  enabled
"""
    check parseListUnitFiles(files) ==
      @[(key: "ssh.service", value: "enabled"),
        (key: "repro-addon.target", value: "enabled")]
    let units = """ssh.service loaded active running OpenBSD Secure Shell server
apt-daily.service loaded inactive dead Daily apt download activities
user@0.service loaded active running User Manager for UID 0
broken.service loaded failed failed A broken service
● other.service loaded failed failed Another
session-4.scope loaded active running Session 4 of User root
"""
    check parseListUnits(units) ==
      @[(key: "ssh.service", value: "active"),
        (key: "broken.service", value: "failed"),
        (key: "other.service", value: "failed")]

  test "sysctl volatile list is exact, not a pattern":
    check isVolatileSysctl("kernel.random.uuid")
    check isVolatileSysctl("fs.binfmt_misc.status")
    check not isVolatileSysctl("kernel.random.poolsize")
    check not isVolatileSysctl("net.ipv4.ip_forward")

suite "canonical text, diff and expectations":
  proc sample(): Fingerprint =
    result.add(fcEtc, "/etc/b", "f 0644 0:0 sha256:bb")
    result.add(fcEtc, "/etc/a\tweird", "f 0644 0:0 sha256:aa")
    result.add(fcDpkgStatus, "jq:amd64", "1.7 install ok installed")
    result.normalise()

  test "render is sorted and round-trips through parse":
    let fp = sample()
    let text = fp.render()
    check text.startsWith(FingerprintHeader & "\n")
    check text.splitLines()[1].startsWith("dpkg-status")
    check parseFingerprint(text).render() == text

  test "duplicate keys are refused":
    var fp: Fingerprint
    fp.add(fcEtc, "/etc/x", "1")
    fp.add(fcEtc, "/etc/x", "2")
    expect FingerprintError:
      fp.normalise()

  test "diff reports added, removed and changed records":
    let a = sample()
    var b = sample()
    b.records[0].value = "1.8 install ok installed"     # changed
    b.records.delete(1)                                  # removed /etc/a…
    b.add(fcListeners, "tcp 0.0.0.0:8080", "x1")         # added
    b.normalise()
    let d = diff(a, b)
    check d.len == 3
    check d[0].op == doChanged and d[0].component == fcDpkgStatus
    check d[1].op == doRemoved and d[1].key == "/etc/a\tweird"
    check d[2].op == doAdded and d[2].component == fcListeners
    check diff(a, a).len == 0

  test "exceptions drop only what they name":
    var a, b: Fingerprint
    a.normalise()
    b.add(fcAccounts, "user:repro-svc", "999:999::/:/usr/sbin/nologin")
    b.add(fcAccounts, "user:intruder", "0:0::/:/bin/sh")
    b.normalise()
    let rest = applyExceptions(diff(a, b), [parseExceptionRule("accounts:user:repro-*")])
    check rest.len == 1 and rest[0].key == "user:intruder"
    expect FingerprintError:
      discard parseExceptionRule("no-colon")

  test "expectations must match the diff exactly":
    var a, b: Fingerprint
    a.normalise()
    b.add(fcEtc, "/etc/repro", "d 0755 0:0")
    b.add(fcMounts, "/repro/store", "ext4 /dev/vda1 ro rw")
    b.normalise()
    let d = diff(a, b)
    let exact = parseExpectations("+ etc\t/etc/repro\td 0755 0:0\n+ mounts\t/repro/store\t*\n")
    check matchExpectations(d, exact).ok
    let missingOne = parseExpectations("+ etc\t/etc/repro\td 0755 0:0\n")
    let r1 = matchExpectations(d, missingOne)
    check not r1.ok and r1.unexpected.len == 1
    let wrongValue = parseExpectations("+ etc\t/etc/repro\td 0700 0:0\n+ mounts\t/repro/store\t*\n")
    check matchExpectations(d, wrongValue).mismatched.len == 1
    let extra = parseExpectations("+ etc\t/etc/repro\td 0755 0:0\n+ mounts\t/repro/store\t*\n+ etc\t/etc/zz\t*\n")
    check matchExpectations(d, extra).missing.len == 1

  test "glob matching":
    check globMatch("user:repro-*", "user:repro-a")
    check not globMatch("user:repro-*", "user:other")
    check globMatch("*", "")
    check globMatch("a?c", "abc")

suite "collection from a fixture tree":
  test "file-backed components, deterministic":
    let root = getTempDir() / ("t_addon_fp_" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "etc/sub")
    createDir(root / "var/lib/dpkg")
    writeFile(root / "etc/passwd", "root:x:0:0:root:/root:/bin/bash\n")
    writeFile(root / "etc/group", "root:x:0:\n")
    writeFile(root / "etc/sub/conf", "hello\n")
    createSymlink("sub/conf", root / "etc/link")
    writeFile(root / "var/lib/dpkg/status",
      "Package: a\nStatus: install ok installed\nArchitecture: all\nVersion: 1\n")
    defer: removeDir(root)
    let opts = CollectOptions(root: root, live: false)
    let one = collectFingerprint(opts).render()
    let two = collectFingerprint(opts).render()
    check one == two
    check "etc\t/etc/link\tl " in one
    check "-> sub/conf" in one
    check "sha256:5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03" in one
    check "dpkg-status\ta:all\t1 install ok installed" in one
    check "addon-roots\t/repro\tabsent" in one
    # A change is visible.
    writeFile(root / "etc/sub/conf", "changed\n")
    let three = collectFingerprint(opts)
    let d = diff(parseFingerprint(one), three)
    check d.len == 1 and d[0].key == "/etc/sub/conf" and d[0].op == doChanged
