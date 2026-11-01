## Fixture `.deb` files and one-member closure locks for the add-on gates:
## a ustar stream inside an ar container, as `dpkg-deb` writes one, with
## whatever entries a gate needs (a well-formed package, a hostile one, an
## operator tool), and a lock pinning it by size and SHA-256. A gate seeds
## the add-on's deb cache with the file (``AddOnAptDebCacheDir``), so the
## realiser verifies it against the lock and never contacts the archive.

import std/[os, strutils]

import repro_dsl_stdlib/packages/apt_closure
import repro_dsl_stdlib/packages/apt_jammy

# ---------------------------------------------------------------------------
# Fixture .deb files: a ustar stream inside an ar container.
# ---------------------------------------------------------------------------

type TarEntry* = tuple[name: string; typeflag: char; mode: int;
                      content, linkName: string]

proc octal*(v: int64; width: int): string = toOct(v, width - 1) & "\0"

proc tarBytes*(entries: seq[TarEntry]): string =
  ## A ustar stream (owners 0:0, two zero blocks at the end), as
  ## ``dpkg-deb`` writes one, but with whatever entries are given.
  for e in entries:
    var h = "\0".repeat(512)
    h[0 ..< e.name.len] = e.name
    h[100 ..< 108] = octal(e.mode, 8)
    h[108 ..< 116] = octal(0, 8)
    h[116 ..< 124] = octal(0, 8)
    let size = if e.typeflag == '0': e.content.len else: 0
    h[124 ..< 136] = octal(size, 12)
    h[136 ..< 148] = octal(0, 12)
    h[156] = e.typeflag
    if e.linkName.len > 0: h[157 ..< 157 + e.linkName.len] = e.linkName
    h[257 ..< 263] = "ustar\0"
    h[263 ..< 265] = "00"
    for i in 148 ..< 156: h[i] = ' '
    var sum = 0
    for c in h: sum += ord(c)
    h[148 ..< 155] = toOct(sum, 6) & "\0"
    h[155] = ' '
    result.add(h)
    if size > 0:
      result.add(e.content)
      result.add("\0".repeat((512 - size mod 512) mod 512))
  result.add("\0".repeat(1024))

proc arMember*(name, payload: string): string =
  var header = name & "/"
  header.add(" ".repeat(16 - header.len))
  header.add("0".alignLeft(12) & "0".alignLeft(6) & "0".alignLeft(6) &
    "100644".alignLeft(8) & ($payload.len).alignLeft(10) & "`\n")
  result = header & payload
  if (payload.len and 1) == 1: result.add('\n')

proc writeDeb*(path: string; entries: seq[TarEntry]) =
  writeFile(path, "!<arch>\n" & arMember("debian-binary", "2.0\n") &
    arMember("data.tar", tarBytes(entries)))

proc dir*(name: string): TarEntry = (name, '5', 0o755, "", "")

proc fixtureLock*(name, debPath: string): AptClosureLock =
  ## A one-member closure lock pinning ``debPath`` by size and SHA-256.
  AptClosureLock(
    archive: "http://fixture.invalid/debian", suite: "fixture",
    components: @["main"], architecture: "amd64", snapshot: "",
    inReleaseSha256: "c".repeat(64),
    indexes: @[AptIndexDigest(path: "main/binary-amd64/Packages.xz",
                              sha256: "d".repeat(64))],
    roots: @[name],
    debs: @[AptLockedDeb(name: name, version: "1.0-1", architecture: "amd64",
      filename: "pool/main/" & name & "_1.0-1_amd64.deb",
      size: getFileSize(debPath), sha256: sha256OfFile(debPath))])
