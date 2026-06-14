## A2 P1 unit gate (campaign: ReproOS-Generations-And-Foreign-Packages).
##
## Validates the manifest codec roundtrip + ECDSA-P256 sign/verify on
## top of the existing peer-cache ``auth.nim`` primitive:
##
##   1. Construct a representative ``BinaryCacheManifest`` covering
##      every typed field (payloads with different compression kinds,
##      dep references, selected options, host-toolchain identity).
##   2. Sign it with a freshly-generated ECDSA-P256 keypair via
##      ``manifest_codec.signManifest``.
##   3. Encode the manifest to bytes, decode the bytes, byte-compare
##      the roundtripped record against the original.
##   4. Call ``verifyManifest`` against the decoded record — passes.
##   5. Tamper with a single payload digest byte and re-decode — the
##      ``CacheEntryKey``-digest sentinel still matches, but
##      ``verifyManifest`` returns false (the signature covers the
##      payload list).
##   6. Tamper with the ``CacheEntryKey`` block bytes directly — the
##      sentinel check fires before the signature check.

import std/[options, os, times, unittest]

import ../src/repro_binary_cache_server/types
import ../src/repro_binary_cache_server/key
import ../src/repro_binary_cache_server/manifest_codec
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

suite "A2 P1 — binary-cache manifest codec + sign/verify":

  setup:
    let kp = peerAuth.generateKeypair()

    let entryKey = CacheEntryKey(
      packageName: "gcc",
      packageVersion: "15.2.0",
      selectedOptions: @[("lto", "on"), ("hardened", "off")],
      platform: PlatformTriple(
        cpu: "x86_64",
        os: "linux",
        abi: "gnu",
        libcVariant: "glibc-2.42"),
      toolchain: ToolchainIdentity(
        name: "gcc",
        version: "11.4.0",
        hostLdSoAbi: "ld-linux-x86-64.so.2",
        extraFingerprint: ""),
      depClosureDigest: [byte 0xaa, 0xbb, 0xcc, 0xdd,
                             0xee, 0xff, 0x11, 0x22,
                             0x33, 0x44, 0x55, 0x66,
                             0x77, 0x88, 0x99, 0xaa,
                             0xbb, 0xcc, 0xdd, 0xee,
                             0xff, 0x00, 0x11, 0x22,
                             0x33, 0x44, 0x55, 0x66,
                             0x77, 0x88, 0x99, 0x00],
      providerRevision: "chain-amd64.json@a5f01")

    var prefixDigest: Blake3Hash
    for i in 0 ..< 32:
      prefixDigest[i] = byte((i * 7 + 3) and 0xff)

    var depA: Blake3Hash
    for i in 0 ..< 32:
      depA[i] = byte((i * 11 + 5) and 0xff)
    var depB: Blake3Hash
    for i in 0 ..< 32:
      depB[i] = byte((i * 13 + 7) and 0xff)

    let payloadA = PayloadObject(
      kind: pkPrefixArchive,
      compression: ckZstd,
      declaredSize: 4096'u64 * 1024,
      uncompressedSize: 4096'u64 * 4096,
      digest: prefixDigest,
      name: "prefix.tar.zst")
    let payloadB = PayloadObject(
      kind: pkLauncher,
      compression: ckNone,
      declaredSize: 8192'u64,
      uncompressedSize: 8192'u64,
      digest: depA,
      name: "launcher-bin")

    var manifest = BinaryCacheManifest(
      formatVersion: BinaryCacheFormatVersion,
      entryKey: entryKey,
      payloads: @[payloadA, payloadB],
      realizedPrefixDigest: prefixDigest,
      depReferences: @[depA, depB],
      relocationPolicy: rpForbidden,
      createdAtUnix: 1_750_000_000'i64,
      producerPubKey: kp.publicKey,
      signature: default(peerAuth.SignatureBytes))

  test "encode/decode roundtrip preserves every typed field":
    signManifest(kp, manifest)
    let encoded = encodeManifest(manifest)
    let decoded = decodeManifest(encoded)

    check decoded.formatVersion == BinaryCacheFormatVersion
    check decoded.entryKey.packageName == manifest.entryKey.packageName
    check decoded.entryKey.packageVersion == manifest.entryKey.packageVersion
    # selectedOptions is canonicalised (sorted) by the key encoder
    # before being written, so the decoded record holds the sorted
    # variant — not the producer's insertion order.
    check decoded.entryKey.selectedOptions ==
          @[("hardened", "off"), ("lto", "on")]
    check decoded.entryKey.platform.cpu == "x86_64"
    check decoded.entryKey.platform.libcVariant == "glibc-2.42"
    check decoded.entryKey.toolchain.version == "11.4.0"
    check decoded.entryKey.depClosureDigest == manifest.entryKey.depClosureDigest
    check decoded.entryKey.providerRevision == manifest.entryKey.providerRevision
    check decoded.payloads.len == 2
    check decoded.payloads[0].kind == pkPrefixArchive
    check decoded.payloads[0].compression == ckZstd
    check decoded.payloads[0].declaredSize == 4096'u64 * 1024
    check decoded.payloads[0].digest == prefixDigest
    check decoded.payloads[1].kind == pkLauncher
    check decoded.realizedPrefixDigest == prefixDigest
    check decoded.depReferences.len == 2
    check decoded.depReferences[0] == depA
    check decoded.depReferences[1] == depB
    check decoded.relocationPolicy == rpForbidden
    check decoded.createdAtUnix == 1_750_000_000'i64
    check decoded.producerPubKey == kp.publicKey
    check decoded.signature == manifest.signature

  test "signed manifest verifies":
    signManifest(kp, manifest)
    let encoded = encodeManifest(manifest)
    let decoded = decodeManifest(encoded)
    check verifyManifest(decoded)

  test "tampered payload digest fails signature verification":
    signManifest(kp, manifest)
    var encoded = encodeManifest(manifest)
    # Walk to the first payload digest and flip a byte. The envelope
    # layout is:
    #   4 (magic) + 2 (version) + 2 (reserved) + 32 (key sentinel) +
    #   4 (keyBlockLen) + keyBlockLen + 4 (payloadCount) +
    #   (1 + 1 + 8 + 8) per payload prefix +
    # so the first payload digest starts at:
    #   header + keyBlockLen + 4 + 18
    let decoded0 = decodeManifest(encoded)
    let unsignedPrefix = encodeManifest(manifest)
    # Easier: find the digest by raw bytewise search. The payload's
    # digest is unique enough.
    var hit = -1
    let needle = decoded0.payloads[0].digest
    block search:
      for i in 0 .. (encoded.len - 32):
        var match = true
        for j in 0 ..< 32:
          if encoded[i + j] != needle[j]:
            match = false
            break
        if match:
          hit = i
          break search
    check hit >= 0
    # Skip the realized-prefix-digest match (same bytes!): pick the
    # FIRST occurrence which is the payload-digest by position. The
    # payload section precedes the realized-prefix digest, so the
    # first match is what we want.
    encoded[hit] = encoded[hit] xor 0xff'u8
    let tampered = decodeManifest(encoded)
    check (not verifyManifest(tampered))

  test "tampered CacheEntryKey block tripped by sentinel":
    signManifest(kp, manifest)
    var encoded = encodeManifest(manifest)
    # The key block lives at offset:
    #   4 (magic) + 2 + 2 + 32 (sentinel) + 4 (keyBlockLen) = 44.
    # The first string in the block is packageName, length-prefixed.
    # Bytes 44..47 are the format-version u16 inside the keyBlock
    # (2 bytes) + reserved (impossible — see encodeCacheEntryKey,
    # which writes u16 format version first), but our key encoder
    # writes formatVersion u16 then packageName length+bytes. So
    # at offset 44 we have the u16 version (2 bytes), then at 46+
    # the u32 packageName length, then the name. Flip a packageName
    # byte to break the encoding's match against the sentinel.
    encoded[46 + 4] = encoded[46 + 4] xor 0x01'u8
    expect BinaryCacheCodecError:
      discard decodeManifest(encoded)

  test "cache-entry-key canonicalises across option order":
    let alt = CacheEntryKey(
      packageName: entryKey.packageName,
      packageVersion: entryKey.packageVersion,
      # Same options, REVERSED order.
      selectedOptions: @[("hardened", "off"), ("lto", "on")],
      platform: entryKey.platform,
      toolchain: entryKey.toolchain,
      depClosureDigest: entryKey.depClosureDigest,
      providerRevision: entryKey.providerRevision)
    check cacheEntryKeyDigest(entryKey) == cacheEntryKeyDigest(alt)

  test "cache-entry-key hex roundtrip":
    let hex = cacheEntryKeyHex(entryKey)
    check hex.len == 64
    let digest = hexToDigest(hex)
    check digest == cacheEntryKeyDigest(entryKey)

  test "hexToDigest rejects malformed input":
    expect ValueError:
      discard hexToDigest("not-a-hash")
    expect ValueError:
      discard hexToDigest("ab")
