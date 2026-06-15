## D2 P1: Build a deterministic Fedora-style snapshot fixture under a
## supplied directory:
##
##   <root>/
##     cache/
##       kojipkgs.fedoraproject.org/
##         compose/39/20260601/compose/Everything/x86_64/os/
##           repodata/
##             repomd.xml
##             primary.xml
##     keys/
##       MANIFEST.txt    (fingerprint allowlist for the repomd bytes)
##
## The fixture covers the D2 P1 ``t_d2_harvest_dnf_*.sh`` integration
## tests without requiring live network access. The harvester runs with:
##
##   --source dnf:htop@fedora/39:20260601
##   --output-dir <out>
##   --cache-dir <root>/cache
##   --gpg-keys <root>/keys
##   --offline
##   --signature-backend fingerprint-allowlist
##
## The Packages cover a real (but trimmed) htop + neovim closure plus
## their shared deps (glibc, ncurses-libs, libgcc, libstdc++).

import std/[os, strutils]

import blake3
import nimcrypto/sha2 as nc_sha2

const FixturePrimary* = """<?xml version="1.0" encoding="UTF-8"?>
<metadata xmlns="http://linux.duke.edu/metadata/common" xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="6">
  <package type="rpm">
    <name>htop</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="3.3.0" rel="1.fc39"/>
    <summary>Interactive process viewer</summary>
    <checksum type="sha256" pkgid="YES">aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11</checksum>
    <location href="Packages/h/htop-3.3.0-1.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="htop" flags="EQ" epoch="0" ver="3.3.0" rel="1.fc39"/>
      </rpm:provides>
      <rpm:requires>
        <rpm:entry name="libncursesw.so.6()(64bit)"/>
        <rpm:entry name="libtinfo.so.6()(64bit)"/>
        <rpm:entry name="glibc" flags="GE" epoch="0" ver="2.34"/>
      </rpm:requires>
    </format>
    <size package="180000"/>
  </package>
  <package type="rpm">
    <name>neovim</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="0.10.2" rel="1.fc39"/>
    <summary>Vim-fork focused on extensibility and usability</summary>
    <checksum type="sha256" pkgid="YES">bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22</checksum>
    <location href="Packages/n/neovim-0.10.2-1.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="neovim" flags="EQ" epoch="0" ver="0.10.2" rel="1.fc39"/>
      </rpm:provides>
      <rpm:requires>
        <rpm:entry name="libncursesw.so.6()(64bit)"/>
        <rpm:entry name="glibc" flags="GE" epoch="0" ver="2.34"/>
        <rpm:entry name="libgcc" flags="GE" epoch="0" ver="13.0.1"/>
        <rpm:entry name="libstdc++.so.6()(64bit)"/>
      </rpm:requires>
    </format>
    <size package="2400000"/>
  </package>
  <package type="rpm">
    <name>ncurses-libs</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="6.4" rel="3.20230114.fc39"/>
    <summary>Ncurses libraries</summary>
    <checksum type="sha256" pkgid="YES">cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33</checksum>
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
    <checksum type="sha256" pkgid="YES">dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44</checksum>
    <location href="Packages/g/glibc-2.38-14.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="glibc" flags="EQ" epoch="0" ver="2.38" rel="14.fc39"/>
      </rpm:provides>
    </format>
    <size package="2200000"/>
  </package>
  <package type="rpm">
    <name>libgcc</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="13.2.1" rel="6.fc39"/>
    <summary>GCC version 13 shared support library</summary>
    <checksum type="sha256" pkgid="YES">ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55</checksum>
    <location href="Packages/l/libgcc-13.2.1-6.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="libgcc" flags="EQ" epoch="0" ver="13.2.1" rel="6.fc39"/>
      </rpm:provides>
      <rpm:requires>
        <rpm:entry name="glibc" flags="GE" epoch="0" ver="2.34"/>
      </rpm:requires>
    </format>
    <size package="110000"/>
  </package>
  <package type="rpm">
    <name>libstdc++</name>
    <arch>x86_64</arch>
    <version epoch="0" ver="13.2.1" rel="6.fc39"/>
    <summary>GNU Standard C++ Library</summary>
    <checksum type="sha256" pkgid="YES">ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66</checksum>
    <location href="Packages/l/libstdc++-13.2.1-6.fc39.x86_64.rpm"/>
    <format>
      <rpm:provides>
        <rpm:entry name="libstdc++" flags="EQ" epoch="0" ver="13.2.1" rel="6.fc39"/>
        <rpm:entry name="libstdc++.so.6()(64bit)"/>
      </rpm:provides>
      <rpm:requires>
        <rpm:entry name="glibc" flags="GE" epoch="0" ver="2.34"/>
        <rpm:entry name="libgcc" flags="GE" epoch="0" ver="13.0.1"/>
      </rpm:requires>
    </format>
    <size package="780000"/>
  </package>
</metadata>
"""

proc sha256HexBytes(bytes: string): string =
  var ctx: nc_sha2.sha256
  ctx.init()
  ctx.update(bytes)
  let digest = ctx.finish()
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = digest.data[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc blake3HexBytes(bytes: string): string =
  let raw = blake3.digest(bytes)
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = raw[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc buildDnfFixture*(root: string;
                     snapshot = "20260601";
                     release = "39") =
  ## Create a deterministic Fedora compose-style fixture under ``root``.
  let baseRoot = root / "cache" / "kojipkgs.fedoraproject.org" /
    "compose" / release / snapshot / "compose" / "Everything" /
    "x86_64" / "os"
  let repoDir = baseRoot / "repodata"
  createDir(repoDir)
  let priBytes = FixturePrimary
  writeFile(repoDir / "primary.xml", priBytes)
  let priSha = sha256HexBytes(priBytes)
  let priSize = priBytes.len

  let repomd =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<repomd xmlns=\"http://linux.duke.edu/metadata/repo\" " &
    "xmlns:rpm=\"http://linux.duke.edu/metadata/rpm\">\n" &
    "  <revision>1717200000</revision>\n" &
    "  <data type=\"primary\">\n" &
    "    <checksum type=\"sha256\">" & priSha & "</checksum>\n" &
    "    <open-checksum type=\"sha256\">" & priSha & "</open-checksum>\n" &
    "    <location href=\"repodata/primary.xml\"/>\n" &
    "    <timestamp>1717200000</timestamp>\n" &
    "    <size>" & $priSize & "</size>\n" &
    "    <open-size>" & $priSize & "</open-size>\n" &
    "  </data>\n" &
    "</repomd>\n"
  writeFile(repoDir / "repomd.xml", repomd)

  let keysDir = root / "keys"
  createDir(keysDir)
  writeFile(keysDir / "MANIFEST.txt",
    "# D2 P1 dnf fixture allowlist\n" &
    "fixture-fedora-39 " & blake3HexBytes(repomd) & "\n")

when isMainModule:
  if paramCount() < 1:
    quit("usage: dnf_fixture_build <root>")
  buildDnfFixture(paramStr(1))
  echo "dnf fixture built under ", paramStr(1)
