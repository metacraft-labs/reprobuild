## ReproOS-Generations-And-Foreign-Packages A2 — cache-entry-key encoding.
##
## ``Binary-Caches.md`` § "Cache Entry Identity" mandates that two
## entries that are not interchangeable at runtime MUST NOT share one
## cache key. We collapse the (package name + version + selected options
## + platform + toolchain + dep-closure digest + provider revision)
## tuple into a deterministic byte sequence and BLAKE3-256 it; the
## resulting 32-byte digest is the on-wire entry-key the
## ``/manifests/<entry-key>`` route consumes.
##
## ## Encoding rules (canonical)
##
##   * All strings are length-prefixed UTF-8: ``u32-le length || raw
##     bytes``. Empty strings encode as ``00 00 00 00`` (no payload).
##   * The selected-options list is sorted lexicographically by name
##     BEFORE encoding so insertion order doesn't perturb the key.
##   * The 32-byte ``depClosureDigest`` is inlined verbatim.
##   * Numeric and enum fields use little-endian throughout.
##
## The encoder is hand-rolled (no ``ssz-serialization`` dep) following
## the same pattern as ``libs/repro_peer_cache/src/repro_peer_cache/codec.nim``
## so reviewers can byte-trace it without macro expansion.

import std/[algorithm, strutils]

import blake3

import ./types

# ---------------------------------------------------------------------------
# Little-endian primitives (lift from peer-cache's codec).
# ---------------------------------------------------------------------------

proc writeU16LE(buf: var seq[byte]; value: uint16) =
  buf.add(byte(value and 0xff'u16))
  buf.add(byte((value shr 8) and 0xff'u16))

proc writeU32LE(buf: var seq[byte]; value: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((value shr uint32(shift)) and 0xff'u32))

proc writeString(buf: var seq[byte]; value: string) =
  writeU32LE(buf, uint32(value.len))
  for ch in value:
    buf.add(byte(ch))

proc writeDigest(buf: var seq[byte]; digest: Blake3Hash) =
  for b in digest:
    buf.add(b)

# ---------------------------------------------------------------------------
# Canonical encoder.
# ---------------------------------------------------------------------------

proc encodePlatform(buf: var seq[byte]; p: PlatformTriple) =
  writeString(buf, p.cpu)
  writeString(buf, p.os)
  writeString(buf, p.abi)
  writeString(buf, p.libcVariant)

proc encodeToolchain(buf: var seq[byte]; t: ToolchainIdentity) =
  writeString(buf, t.name)
  writeString(buf, t.version)
  writeString(buf, t.hostLdSoAbi)
  writeString(buf, t.extraFingerprint)

proc encodeOptions(buf: var seq[byte]; opts: seq[(string, string)]) =
  # Sort by option name (key) for deterministic encoding.
  var sorted = opts
  sorted.sort(proc (a, b: (string, string)): int =
    cmp(a[0], b[0]))
  writeU32LE(buf, uint32(sorted.len))
  for (k, v) in sorted:
    writeString(buf, k)
    writeString(buf, v)

proc encodeCacheEntryKey*(k: CacheEntryKey): seq[byte] =
  ## Canonical encoding of ``CacheEntryKey``. Stable across runs;
  ## tests assert byte equality.
  result = newSeqOfCap[byte](256)
  writeU16LE(result, BinaryCacheFormatVersion)
  writeString(result, k.packageName)
  writeString(result, k.packageVersion)
  encodeOptions(result, k.selectedOptions)
  encodePlatform(result, k.platform)
  encodeToolchain(result, k.toolchain)
  writeDigest(result, k.depClosureDigest)
  writeString(result, k.providerRevision)

proc cacheEntryKeyDigest*(k: CacheEntryKey): Blake3Hash =
  ## BLAKE3-256 over the canonical encoding. The 32-byte digest is the
  ## entry's address in the server-side index and the URL component
  ## the client sends on ``GET /manifests/<hex>``.
  let encoded = encodeCacheEntryKey(k)
  let raw = blake3.digest(encoded)
  for i in 0 ..< 32:
    result[i] = raw[i]

# ---------------------------------------------------------------------------
# Hex helpers — the on-the-wire URL component is the lowercase-hex
# rendition of the 32-byte digest. We compare it case-insensitively to
# protect against shells that uppercase argv.
# ---------------------------------------------------------------------------

proc digestToHex*(d: Blake3Hash): string =
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(64)
  for b in d:
    result.add(HexChars[int(b shr 4) and 0x0f])
    result.add(HexChars[int(b) and 0x0f])

proc hexToDigest*(hex: string): Blake3Hash =
  ## Parses a 64-char hex (case-insensitive). Raises ``ValueError`` on
  ## any malformed input so the HTTP handler can map it to ``Http400``.
  if hex.len != 64:
    raise newException(ValueError,
      "binary-cache entry-key hex must be 64 chars, got " & $hex.len)
  for i in 0 ..< 32:
    let hi = parseHexInt(hex[i * 2 .. i * 2 + 1])
    result[i] = byte(hi and 0xff)

proc cacheEntryKeyHex*(k: CacheEntryKey): string =
  digestToHex(cacheEntryKeyDigest(k))
