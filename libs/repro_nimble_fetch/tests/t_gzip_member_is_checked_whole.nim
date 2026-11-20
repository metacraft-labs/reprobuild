## The forge-archive transport gunzips in process (`repro_core/zlib_inflate`,
## `gzipDecompress`, RFC 1952). What it accepts is exactly one gzip member,
## checked whole:
##
## * the optional header fields (FEXTRA, FNAME, FCOMMENT) are skipped, and a
##   header CRC (FHCRC) is verified when present;
## * the trailer's CRC-32 and ISIZE are verified;
## * the DEFLATE data must end exactly where the 8-byte trailer starts, so a
##   member followed by a copy of its own trailer, or by a second member, is
##   refused (`gzip-malformed`) instead of being read as its first member;
## * the output is bounded while it is decoded (`gzip-too-large`), and a
##   truncated stream is refused (`gzip-truncated`).
##
## The members come from the host's `gzip -n`; the header variants are built
## around the same DEFLATE data.

import std/[strutils, tempfiles, unittest]

import repro_core/zlib_inflate

import ./fetch_fixtures

proc reasonOf(data: string; maxBytes = 1 shl 20): string =
  try:
    discard gzipDecompress(data, maxBytes)
    "accepted"
  except InflateError as e:
    e.reason

proc text(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc le16(v: int): string = $char(v and 0xFF) & $char((v shr 8) and 0xFF)

proc crcBytes(s: string): seq[byte] =
  for c in s: result.add byte(ord(c))

suite "a gzip member is checked whole":
  let work = createTempDir("npc-m5-gzip-", "")
  let payload = "proc f*(): int = 1\n".repeat(200)
  let member = gzipOf(work, payload)
  let deflate = member[10 ..< member.len - 8]
  let trailer = member[member.len - 8 .. ^1]

  test "a plain member and every optional header field are read":
    check text(gzipDecompress(member, 1 shl 20)) == payload
    # FEXTRA (one subfield), FNAME and FCOMMENT around the same data.
    var header = member[0 ..< 10]
    header[3] = char(4 or 8 or 16)
    let extra = "AB" & le16(3) & "xyz"
    let withFields = header & le16(extra.len) & extra & "pkg.tar\0" &
      "a comment\0" & deflate & trailer
    check text(gzipDecompress(withFields, 1 shl 20)) == payload
    # FHCRC: the low 16 bits of the CRC-32 of the header before it.
    var h2 = member[0 ..< 10]
    h2[3] = char(2)
    let hcrc = int(crc32(crcBytes(h2)) and 0xFFFF'u32)
    check text(gzipDecompress(h2 & le16(hcrc) & deflate & trailer,
      1 shl 20)) == payload
    check reasonOf(h2 & le16(hcrc xor 1) & deflate & trailer) ==
      "gzip-checksum-mismatch"

  test "trailing data and a second member are refused":
    # The member, then a copy of its own trailer: the last 8 bytes are a
    # valid trailer for the first member's data.
    check reasonOf(member & trailer) == "gzip-malformed"
    check reasonOf(member & member) == "gzip-malformed"
    check reasonOf(member & "\0") != "accepted"

  test "checksums, sizes, bounds and truncation":
    var badCrc = member
    badCrc[badCrc.len - 8] = char(ord(badCrc[badCrc.len - 8]) xor 1)
    check reasonOf(badCrc) == "gzip-checksum-mismatch"
    var badSize = member
    badSize[badSize.len - 4] = char(ord(badSize[badSize.len - 4]) xor 1)
    check reasonOf(badSize) == "gzip-checksum-mismatch"
    check reasonOf(member, maxBytes = payload.len - 1) == "gzip-too-large"
    check reasonOf(member, maxBytes = payload.len) == "accepted"
    let bomb = gzipOf(work, repeat('\0', 4 shl 20))
    check bomb.len < 64 * 1024
    check reasonOf(bomb, maxBytes = 1 shl 20) == "gzip-too-large"
    check reasonOf(member[0 ..< member.len div 2]) in
      ["gzip-truncated", "gzip-malformed"]
    check reasonOf(member[0 ..< 12]) == "gzip-truncated"
