## D2 P2: Build a deterministic Arch-style snapshot fixture.
##
##   <root>/
##     cache/
##       archive.archlinux.org/
##         repos/2026/06/01/core/os/x86_64/
##           core.db                 (USTAR tarball, uncompressed)
##     keys/
##       MANIFEST.txt
##
## The fixture covers ``t_d2_harvest_pacman.sh`` without live network.
## Six packages: htop + fzf (roots) + ncurses + glibc + gcc-libs +
## sh (a stand-in for the bash dep fzf carries).

import std/[os, strutils]

import blake3

const HtopDesc* = """%FILENAME%
htop-3.3.0-1-x86_64.pkg.tar.zst

%NAME%
htop

%VERSION%
3.3.0-1

%DESC%
Interactive process viewer

%CSIZE%
180000

%ISIZE%
500000

%SHA256SUM%
aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11

%ARCH%
x86_64

%DEPENDS%
glibc>=2.34
ncurses

%PROVIDES%
htop=3.3.0-1
"""

const FzfDesc* = """%FILENAME%
fzf-0.55.0-1-x86_64.pkg.tar.zst

%NAME%
fzf

%VERSION%
0.55.0-1

%DESC%
Command-line fuzzy finder

%CSIZE%
1700000

%ISIZE%
4200000

%SHA256SUM%
bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22

%ARCH%
x86_64

%DEPENDS%
glibc>=2.34
ncurses
sh

%PROVIDES%
fzf=0.55.0-1
"""

const NcursesDesc* = """%FILENAME%
ncurses-6.4-1-x86_64.pkg.tar.zst

%NAME%
ncurses

%VERSION%
6.4-1

%DESC%
System V Release 4.0 curses emulation library

%CSIZE%
320000

%SHA256SUM%
cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33cc33

%ARCH%
x86_64

%DEPENDS%
glibc>=2.34
gcc-libs

%PROVIDES%
libncursesw.so=6-64
libtinfo.so=6-64
"""

const GlibcDesc* = """%FILENAME%
glibc-2.38-1-x86_64.pkg.tar.zst

%NAME%
glibc

%VERSION%
2.38-1

%DESC%
GNU C Library

%CSIZE%
2200000

%SHA256SUM%
dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44dd44

%ARCH%
x86_64

%PROVIDES%
glibc=2.38-1
"""

const GccLibsDesc* = """%FILENAME%
gcc-libs-13.2.1-1-x86_64.pkg.tar.zst

%NAME%
gcc-libs

%VERSION%
13.2.1-1

%DESC%
Runtime libraries shipped by GCC

%CSIZE%
120000

%SHA256SUM%
ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55ee55

%ARCH%
x86_64

%DEPENDS%
glibc>=2.34

%PROVIDES%
gcc-libs=13.2.1-1
"""

const ShDesc* = """%FILENAME%
sh-1.0-1-x86_64.pkg.tar.zst

%NAME%
sh

%VERSION%
1.0-1

%DESC%
Pacman virtual for /bin/sh

%CSIZE%
4000

%SHA256SUM%
ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66ff66

%ARCH%
x86_64

%DEPENDS%
glibc>=2.34

%PROVIDES%
sh=1.0-1
"""

# ---------------------------------------------------------------------------
# Minimal USTAR tar writer (same approach as the unit test fixture).
# ---------------------------------------------------------------------------

proc oct(n: int; width: int): string =
  result = ""
  var v = n
  for _ in 0 ..< width:
    result.add(char('0'.uint8 + uint8(v and 7)))
    v = v shr 3
  var out2 = ""
  for i in countdown(result.len - 1, 0):
    out2.add(result[i])
  result = out2

proc tarHeader(name: string; size: int; typeFlag: char): string =
  result = newString(512)
  for i in 0 ..< 512: result[i] = '\0'
  var n = name
  if n.len > 100:
    n = n[0 ..< 100]
  for i in 0 ..< n.len: result[i] = n[i]
  let mode = "0000644"
  for i in 0 ..< mode.len: result[100 + i] = mode[i]
  for i in 0 ..< 7: result[108 + i] = '0'
  for i in 0 ..< 7: result[116 + i] = '0'
  let szOct = oct(size, 11)
  for i in 0 ..< szOct.len: result[124 + i] = szOct[i]
  for i in 0 ..< 11: result[136 + i] = '0'
  for i in 0 ..< 8: result[148 + i] = ' '
  result[156] = typeFlag
  let magic = "ustar"
  for i in 0 ..< magic.len: result[257 + i] = magic[i]
  result[262] = '\0'
  result[263] = '0'
  result[264] = '0'
  var sum = 0
  for c in result: sum += int(c.uint8)
  let csumStr = oct(sum, 6)
  for i in 0 ..< csumStr.len: result[148 + i] = csumStr[i]
  result[148 + 6] = '\0'
  result[148 + 7] = ' '

proc padTo512(s: string): string =
  let pad = (512 - (s.len mod 512)) mod 512
  result = s
  if pad > 0:
    result.add(repeat('\0', pad))

proc buildTar(entries: seq[(string, string)]): string =
  result = ""
  for (name, body) in entries:
    result.add(tarHeader(name, body.len, '0'))
    result.add(padTo512(body))
  result.add(repeat('\0', 1024))

proc blake3HexBytes(bytes: string): string =
  let raw = blake3.digest(bytes)
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = raw[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc buildPacmanFixture*(root: string;
                        snapshot = "20260601";
                        repoName = "core") =
  ## Build the fixture.
  var dayPath = snapshot
  if dayPath.len == 8 and not dayPath.contains('/'):
    dayPath = dayPath[0 ..< 4] & "/" & dayPath[4 ..< 6] & "/" &
      dayPath[6 ..< 8]
  let baseRoot = root / "cache" / "archive.archlinux.org" /
    "repos" / dayPath / repoName / "os" / "x86_64"
  createDir(baseRoot)
  let entries = @[
    ("htop-3.3.0-1/desc", HtopDesc),
    ("fzf-0.55.0-1/desc", FzfDesc),
    ("ncurses-6.4-1/desc", NcursesDesc),
    ("glibc-2.38-1/desc", GlibcDesc),
    ("gcc-libs-13.2.1-1/desc", GccLibsDesc),
    ("sh-1.0-1/desc", ShDesc),
  ]
  let tarBytes = buildTar(entries)
  writeFile(baseRoot / (repoName & ".db"), tarBytes)

  let keysDir = root / "keys"
  createDir(keysDir)
  writeFile(keysDir / "MANIFEST.txt",
    "# D2 P2 pacman fixture allowlist\n" &
    "fixture-archlinux " & blake3HexBytes(tarBytes) & "\n")

when isMainModule:
  if paramCount() < 1:
    quit("usage: pacman_fixture_build <root>")
  buildPacmanFixture(paramStr(1))
  echo "pacman fixture built under ", paramStr(1)
