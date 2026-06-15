## D2 P2: pacman index parser smoke test.
##
## Exercises ``parseDescFile``, ``readUstarTar``, ``parseRepoDb``,
## ``buildPacmanIndex``, ``resolveClosure``.

import std/[strutils, tables, unittest]

import repro_dsl_stdlib/packages/pacman_index

const SampleHtopDesc = """%FILENAME%
htop-3.3.0-1-x86_64.pkg.tar.zst

%NAME%
htop

%BASE%
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
abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd

%ARCH%
x86_64

%DEPENDS%
glibc>=2.34
ncurses

%PROVIDES%
htop=3.3.0-1
"""

const SampleNcursesDesc = """%FILENAME%
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
1111111111111111111111111111111111111111111111111111111111111111

%ARCH%
x86_64

%DEPENDS%
glibc

%PROVIDES%
libncursesw.so=6-64
"""

const SampleGlibcDesc = """%FILENAME%
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
2222222222222222222222222222222222222222222222222222222222222222

%ARCH%
x86_64

%PROVIDES%
glibc=2.38-1
"""

proc oct(n: int; width: int): string =
  result = ""
  var v = n
  for _ in 0 ..< width:
    result.add(char('0'.uint8 + uint8(v and 7)))
    v = v shr 3
  # reverse
  var out2 = ""
  for i in countdown(result.len - 1, 0):
    out2.add(result[i])
  result = out2

proc tarHeader(name: string; size: int; typeFlag: char): string =
  ## Build one 512-byte USTAR header.
  result = newString(512)
  for i in 0 ..< 512: result[i] = '\0'
  var n = name
  if n.len > 100:
    n = n[0 ..< 100]
  for i in 0 ..< n.len: result[i] = n[i]
  # mode
  let mode = "0000644"
  for i in 0 ..< mode.len: result[100 + i] = mode[i]
  # uid + gid
  for i in 0 ..< 7: result[108 + i] = '0'
  for i in 0 ..< 7: result[116 + i] = '0'
  # size: 11 octal digits + null
  let szOct = oct(size, 11)
  for i in 0 ..< szOct.len: result[124 + i] = szOct[i]
  # mtime: 11 octal digits + null
  for i in 0 ..< 11: result[136 + i] = '0'
  # initial chksum field: 8 spaces while we compute
  for i in 0 ..< 8: result[148 + i] = ' '
  # typeflag
  result[156] = typeFlag
  # magic + version "ustar\0" + "00"
  let magic = "ustar"
  for i in 0 ..< magic.len: result[257 + i] = magic[i]
  result[262] = '\0'
  result[263] = '0'
  result[264] = '0'
  # checksum
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
  # Two empty blocks terminate the archive.
  result.add(repeat('\0', 1024))

suite "D2 P2 pacman-index parser":

  test "parseDependencyAtom handles bare name, version op, soname":
    let a1 = parseDependencyAtom("ncurses")
    check a1.name == "ncurses"
    check a1.op == pdoAny
    let a2 = parseDependencyAtom("glibc>=2.34")
    check a2.name == "glibc"
    check a2.op == pdoGe
    check a2.version == "2.34"
    let a3 = parseDependencyAtom("libcurl.so=4-64")
    check a3.name == "libcurl.so"
    check a3.op == pdoEq
    check a3.version == "4-64"

  test "parseDescFile extracts name + version + sha256 + depends":
    let rec = parseDescFile(SampleHtopDesc)
    check rec.name == "htop"
    check rec.version == "3.3.0-1"
    check rec.filename == "htop-3.3.0-1-x86_64.pkg.tar.zst"
    check rec.sha256 ==
      "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"
    check rec.arch == "x86_64"
    check rec.csize == 180000
    check rec.isize == 500000
    check rec.depends.len == 2
    check rec.depends[0].name == "glibc"
    check rec.depends[0].op == pdoGe
    check rec.depends[0].version == "2.34"
    check rec.depends[1].name == "ncurses"
    check rec.provides.len == 1
    check rec.provides[0].name == "htop"

  test "readUstarTar parses a built tarball":
    let body = buildTar(@[
      ("htop-3.3.0-1/desc", SampleHtopDesc),
      ("ncurses-6.4-1/desc", SampleNcursesDesc),
      ("glibc-2.38-1/desc", SampleGlibcDesc),
    ])
    let entries = readUstarTar(body)
    check entries.len == 3
    var found = 0
    for e in entries:
      if e.name.endsWith("/desc"): inc found
    check found == 3

  test "parseRepoDb extracts records from desc tarball":
    let body = buildTar(@[
      ("htop-3.3.0-1/desc", SampleHtopDesc),
      ("ncurses-6.4-1/desc", SampleNcursesDesc),
      ("glibc-2.38-1/desc", SampleGlibcDesc),
    ])
    let records = parseRepoDb(body)
    check records.len == 3
    var names: seq[string] = @[]
    for r in records: names.add(r.name)
    check "htop" in names
    check "ncurses" in names
    check "glibc" in names

  test "buildPacmanIndex + resolveClosure walks htop transitively":
    let body = buildTar(@[
      ("htop-3.3.0-1/desc", SampleHtopDesc),
      ("ncurses-6.4-1/desc", SampleNcursesDesc),
      ("glibc-2.38-1/desc", SampleGlibcDesc),
    ])
    let records = parseRepoDb(body)
    let idx = buildPacmanIndex(records)
    let closure = resolveClosure("htop", idx)
    var names: seq[string] = @[]
    for r in closure: names.add(r.name)
    check "htop" in names
    check "ncurses" in names
    check "glibc" in names
    check closure.len == 3

  test "resolveClosure raises on missing dep":
    let onlyHtop = parseDescFile(SampleHtopDesc)
    let idx = buildPacmanIndex(@[onlyHtop])
    expect PacmanClosureError:
      discard resolveClosure("htop", idx)

  test "resolveClosure tolerates missing dep with allowUnresolved":
    let onlyHtop = parseDescFile(SampleHtopDesc)
    let idx = buildPacmanIndex(@[onlyHtop])
    let closure = resolveClosure("htop", idx, allowUnresolved = true)
    check closure.len == 1
    check closure[0].name == "htop"
