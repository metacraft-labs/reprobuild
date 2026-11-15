## Hermetic ``.deb`` fixture builder shared by the apt-jammy adapter suites
## (``t_nde0a_apt_jammy.nim``, ``t_apt_install_store_identity_is_byte_keyed.nim``).
##
## NOT named ``t_*`` / ``test_*`` on purpose: ``scripts/generate_test_edges.nim``
## discovers tests by file-name stem, so a helper carrying either prefix
## would be compiled and run as its own (empty) test binary.
##
## Every archive is assembled byte-for-byte here instead of fetched from a
## mutable Ubuntu pool URL, so the bytes are a function of the arguments
## alone: the same call produces the same sha256 on every host. The payloads
## are authored by the callers under the repository's Apache-2.0 license and
## contain no Ubuntu package bytes.
##
## Formats followed:
##   * ``ar`` container: the System V / GNU ``ar`` layout Debian packages use,
##     https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html
##   * ustar members: POSIX.1-1988 ``ustar`` header,
##     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html#tag_20_92_13_06
##   * Zstandard raw-block frame: RFC 8878 §3.1.1,
##     https://www.rfc-editor.org/rfc/rfc8878#section-3.1.1

import std/strutils

type
  DebDataCompression* = enum
    ## How the ``data.tar`` member is stored inside the ``.deb``.
    ddcPlain   ## ``data.tar``: needs only a host ``tar`` to extract.
    ddcZstdRaw ## ``data.tar.zst``: a raw-block zstd frame, so extraction also
               ## exercises the adapter's ``zstd`` decompression path.

const DefaultFixtureControl* = """Package: reprobuild-apt-fixture
Version: 1.0
Architecture: all
Maintainer: Reprobuild test suite
Description: deterministic apt adapter fixture
"""
  ## The control file every fixture ships unless a caller supplies its own.
  ## The adapter never reads ``control.tar``; it is present only so the
  ## archive has the member set ``dpkg-deb`` writes.

proc putField(buf: var string; offset, width: int; value: string) =
  doAssert value.len <= width
  for i in 0 ..< value.len:
    buf[offset + i] = value[i]

proc octalField(value, width: int): string =
  doAssert width >= 2
  value.toOct(width - 1) & '\0'

proc tarMember*(path, payload: string): string =
  ## Emit one deterministic POSIX ustar regular-file member (mode 0644,
  ## owner 0:0, mtime 0).
  doAssert path.len <= 100
  var header = newString(512)
  header.putField(0, 100, path)
  header.putField(100, 8, octalField(0o644, 8))
  header.putField(108, 8, octalField(0, 8))
  header.putField(116, 8, octalField(0, 8))
  header.putField(124, 12, octalField(payload.len, 12))
  header.putField(136, 12, octalField(0, 12))
  for i in 148 ..< 156:
    header[i] = ' '
  header[156] = '0'
  header.putField(257, 6, "ustar\0")
  header.putField(263, 2, "00")
  var checksum = 0
  for ch in header:
    checksum += ord(ch)
  header.putField(148, 8, checksum.toOct(6) & "\0 ")

  result = header & payload
  let padding = (512 - (payload.len mod 512)) mod 512
  result.add(newString(padding))

proc tarArchive*(path, payload: string): string =
  ## A one-member ustar stream followed by the two zero end-of-archive blocks.
  tarMember(path, payload) & newString(1024)

proc zstdRawFrame*(payload: string): string =
  ## Encode one deterministic Zstandard frame containing a single raw
  ## (uncompressed) block. This keeps the fixture builder pure Nim while
  ## exercising the adapter's real ``data.tar.zst`` decompression path.
  ##
  ## Descriptor 0x60 means: two-byte Frame_Content_Size, single segment,
  ## no dictionary, no checksum. In that encoding the stored content size
  ## is the real size minus 256. A Zstandard block header is a 24-bit
  ## little-endian value: size in bits 3..23, raw type 0 in bits 1..2,
  ## and Last_Block=1 in bit 0.
  doAssert payload.len >= 256
  doAssert payload.len <= 65791
  result = "\x28\xb5\x2f\xfd\x60"
  let encodedSize = payload.len - 256
  result.add(char(encodedSize and 0xff))
  result.add(char((encodedSize shr 8) and 0xff))
  let blockHeader = (payload.len shl 3) or 1
  result.add(char(blockHeader and 0xff))
  result.add(char((blockHeader shr 8) and 0xff))
  result.add(char((blockHeader shr 16) and 0xff))
  result.add(payload)

proc arMember*(name, payload: string): string =
  ## Emit one deterministic System V ar member. Debian packages require
  ## even-byte alignment; newline is the conventional pad byte.
  doAssert name.len + 1 <= 16
  result =
    (name & "/").alignLeft(16) &
    "0".alignLeft(12) &
    "0".alignLeft(6) &
    "0".alignLeft(6) &
    "100644".alignLeft(8) &
    ($payload.len).alignLeft(10) &
    "`\n" &
    payload
  if (payload.len and 1) == 1:
    result.add('\n')

proc debArchiveBytes*(dataPath, dataBytes: string;
                      compression = ddcZstdRaw;
                      control = DefaultFixtureControl): string =
  ## The bytes of a ``.deb`` whose data member holds exactly one regular file,
  ## ``dataPath`` (archive-relative, no leading ``./``), with content
  ## ``dataBytes``. Member order is the one ``dpkg-deb`` writes:
  ## ``debian-binary``, ``control.tar``, ``data.tar[.zst]``.
  result = "!<arch>\n"
  result.add(arMember("debian-binary", "2.0\n"))
  result.add(arMember("control.tar", tarArchive("control", control)))
  let data = tarArchive(dataPath, dataBytes)
  case compression
  of ddcPlain:
    result.add(arMember("data.tar", data))
  of ddcZstdRaw:
    result.add(arMember("data.tar.zst", zstdRawFrame(data)))
