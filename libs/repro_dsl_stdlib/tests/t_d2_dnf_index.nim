## D2 P1: dnf primary.xml parser smoke test.
##
## Exercises ``parsePrimaryXml``, ``buildDnfIndex``, ``resolveClosure``,
## ``parseRepomdXml`` against a hand-authored Fedora-style primary.xml
## fixture. Tests the harder corners:
##
##   * version attribute parsed from a self-closing element,
##   * checksum and location-href extraction,
##   * rpm:requires + rpm:provides resolution including a virtual
##     (a shared-library soname provided by another package),
##   * rpm:requires that names an absent file path is silently dropped
##     under ``allowUnresolved = true`` (default),
##   * the missing-dep error path under ``allowUnresolved = false``.

import std/[strutils, tables, unittest]

import repro_dsl_stdlib/packages/dnf_index

const FixturePrimaryXml = """<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns="http://linux.duke.edu/metadata/common" xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="3">
  <package type="rpm">
    <name>htop</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="3.3.0" rel="1.fc39"/>
    <summary>Interactive process viewer</summary>
    <checksum type="sha256" pkgid="YES">1111111111111111111111111111111111111111111111111111111111111111</checksum>
    <location href="Packages/h/htop-3.3.0-1.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="htop" flags="EQ" epoch="0" ver="3.3.0" rel="1.fc39"/>
      </rpm:provides>
      <rpm:requires>
        <rpm:entry name="libncursesw.so.6()(64bit)"/>
        <rpm:entry name="glibc" flags="GE" epoch="0" ver="2.34"/>
        <rpm:entry name="rpmlib(FileDigests)" flags="LE" epoch="0" ver="4.6.0-1"/>
        <rpm:entry name="/bin/sh"/>
      </rpm:requires>
      <file>/usr/bin/htop</file>
    </format>
    <size package="180000" archive="200000" installed="500000"/>
  </package>
  <package type="rpm">
    <name>ncurses-libs</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="6.4" rel="3.20230114.fc39"/>
    <summary>Ncurses libraries</summary>
    <checksum type="sha256" pkgid="YES">2222222222222222222222222222222222222222222222222222222222222222</checksum>
    <location href="Packages/n/ncurses-libs-6.4-3.20230114.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="ncurses-libs" flags="EQ" epoch="0" ver="6.4" rel="3.20230114.fc39"/>
        <rpm:entry name="libncursesw.so.6()(64bit)"/>
        <rpm:entry name="libtinfo.so.6()(64bit)"/>
      </rpm:provides>
      <rpm:requires>
        <rpm:entry name="glibc" flags="GE" epoch="0" ver="2.34"/>
      </rpm:requires>
    </format>
    <size package="320000"/>
  </package>
  <package type="rpm">
    <name>glibc</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="2.38" rel="14.fc39"/>
    <summary>The GNU C Library</summary>
    <checksum type="sha256" pkgid="YES">3333333333333333333333333333333333333333333333333333333333333333</checksum>
    <location href="Packages/g/glibc-2.38-14.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="glibc" flags="EQ" epoch="0" ver="2.38" rel="14.fc39"/>
      </rpm:provides>
    </format>
    <size package="2200000"/>
  </package>
</metadata>
"""

const FixtureRepomd = """<?xml version="1.0" encoding="UTF-8"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo" xmlns:rpm="http://linux.duke.edu/metadata/rpm">
  <revision>1717200000</revision>
  <data type="primary">
    <checksum type="sha256">abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc1</checksum>
    <open-checksum type="sha256">defdefdefdefdefdefdefdefdefdefdefdefdefdefdefdefdefdefdefdefdef1</open-checksum>
    <location href="repodata/abc-primary.xml.gz"/>
    <timestamp>1717200000</timestamp>
    <size>12345</size>
    <open-size>67890</open-size>
  </data>
  <data type="filelists">
    <checksum type="sha256">bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb</checksum>
    <location href="repodata/bbb-filelists.xml.gz"/>
    <size>5678</size>
  </data>
</repomd>
"""

suite "D2 P1 dnf-index parser":
  test "parsePrimaryXml returns one record per <package>":
    let records = parsePrimaryXml(FixturePrimaryXml)
    check records.len == 3
    var names: seq[string] = @[]
    for r in records: names.add(r.name)
    check "htop" in names
    check "ncurses-libs" in names
    check "glibc" in names

  test "package fields parse from self-closing version + location":
    let records = parsePrimaryXml(FixturePrimaryXml)
    var htop: DnfPackageRecord
    for r in records:
      if r.name == "htop": htop = r
    check htop.version == "3.3.0"
    check htop.release == "1.fc39"
    check htop.epoch == "0"
    check htop.arch == "x86_64"
    check htop.location == "Packages/h/htop-3.3.0-1.fc39.x86_64.rpm"
    check htop.checksumType == "sha256"
    check htop.checksumHex ==
      "1111111111111111111111111111111111111111111111111111111111111111"
    check htop.sizePackage == 180000

  test "rpm:requires and rpm:provides extracted, rpmlib filtered":
    let records = parsePrimaryXml(FixturePrimaryXml)
    var htop: DnfPackageRecord
    for r in records:
      if r.name == "htop": htop = r
    var reqNames: seq[string] = @[]
    for a in htop.requires: reqNames.add(a.name)
    # rpmlib(...) was filtered; libncursesw soname + glibc + /bin/sh remain
    check "libncursesw.so.6()(64bit)" in reqNames
    check "glibc" in reqNames
    check "/bin/sh" in reqNames
    for n in reqNames:
      check not n.startsWith("rpmlib(")

    var ncl: DnfPackageRecord
    for r in records:
      if r.name == "ncurses-libs": ncl = r
    var provNames: seq[string] = @[]
    for a in ncl.provides: provNames.add(a.name)
    check "libncursesw.so.6()(64bit)" in provNames
    check "libtinfo.so.6()(64bit)" in provNames

  test "buildDnfIndex populates byName + virtuals":
    let records = parsePrimaryXml(FixturePrimaryXml)
    let idx = buildDnfIndex(records)
    check idx.byName.hasKey("htop")
    check idx.byName.hasKey("glibc")
    check idx.virtuals.hasKey("libncursesw.so.6()(64bit)")
    check idx.virtuals["libncursesw.so.6()(64bit)"] == @["ncurses-libs"]

  test "resolveClosure walks htop transitively via virtuals":
    let records = parsePrimaryXml(FixturePrimaryXml)
    let idx = buildDnfIndex(records)
    let closure = resolveClosure("htop", idx, allowUnresolved = true)
    var names: seq[string] = @[]
    for r in closure: names.add(r.name)
    check "htop" in names
    check "ncurses-libs" in names
    check "glibc" in names
    check closure.len == 3

  test "resolveClosure raises on missing dep when not allowUnresolved":
    let records = parsePrimaryXml(FixturePrimaryXml)
    let idx = buildDnfIndex(records)
    expect DnfClosureError:
      discard resolveClosure("htop", idx, allowUnresolved = false)

  test "parseRepomdXml extracts primary location + sha256":
    let entries = parseRepomdXml(FixtureRepomd)
    check entries.len == 2
    var pri: RepomdEntry
    for e in entries:
      if e.dataType == "primary": pri = e
    check pri.location == "repodata/abc-primary.xml.gz"
    check pri.checksumType == "sha256"
    check pri.checksumHex.startsWith("abcabcabcabc")
    check pri.openChecksumHex.startsWith("defdefdef")
    check pri.sizeBytes == 12345
