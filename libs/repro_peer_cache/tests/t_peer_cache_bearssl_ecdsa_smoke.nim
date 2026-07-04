## Peer-Cache-BearSSL M0 verification test:
## the `nim-bearssl` signing surface is wired into the workspace.
##
## PRIMITIVE: ECDSA-P256
## =====================
##
## The campaign originally targeted Ed25519, but BearSSL does not
## implement EdDSA (upstream supports RSA + ECDSA only; see the C
## BearSSL API page at https://bearssl.org/api1.html). M0 discovery
## confirmed the same on the Nim bindings — `git grep ed25519` over
## status-im/nim-bearssl @ 9a4eed05 returns no matches, and
## `bearssl/abi/bearssl_ec.nim` exports only ECDSA primitives
## (`ecdsaI31SignRaw`, `ecdsaI31VrfyRaw`, `ecdsaSignRawGetDefault`,
## `ecdsaVrfyRawGetDefault`) and Curve25519 for ECDH key exchange.
##
## The campaign now uses ECDSA-P256 throughout. Wire-shape impact:
##
##   * Raw ECDSA-P256 signatures are 64 bytes (two 32-byte scalars),
##     identical to the existing AdvertiseV2.signature slot.
##   * Uncompressed ECDSA-P256 public keys are 65 bytes
##     (`0x04 || X(32) || Y(32)`) — larger than Ed25519's 32 bytes, but
##     PeerId = BLAKE3-256(publicKey) stays 32 bytes regardless of
##     pubkey size, so the on-wire PeerId is unaffected.
##   * The TLS_ECDHE_ECDSA_* cipher suites named in the spec already
##     match the ECDSA cert signature algorithm natively — no
##     Ed25519-cert-in-ECDSA-suite trickery is needed.
##
## This smoke test exercises BearSSL's ECDSA-P256 raw sign/verify
## surface end-to-end and asserts the 64-byte signature and 65-byte
## uncompressed-pubkey wire-shape constants.

import std/unittest

import repro_peer_cache/auth

{.used.}

const
  TestMessage = "peer-cache-bearssl-m0-smoke-msg!"  # exactly 32 bytes
  P256RawSigLen = 64                                # two 32-byte scalars
  P256UncompressedPubLen = 65                       # 0x04 || X(32) || Y(32)

suite "peer-cache bearssl ecdsa-p256 signing smoke":

  test "ECDSA-P256 sign/verify round-trip":
    doAssert TestMessage.len == 32

    let kp = generateKeypair()
    check kp.privateKey.len == 32
    check kp.publicKey.len == P256UncompressedPubLen

    let sig = signMessage(kp, TestMessage.toOpenArrayByte(0, TestMessage.high))
    check sig.len == P256RawSigLen
    check verifySignature(kp.publicKey,
      TestMessage.toOpenArrayByte(0, TestMessage.high), sig)

    # Tamper one byte of the *message*, re-hash, and verify against
    # the tampered digest: must reject.
    var tamperedMsg = TestMessage
    tamperedMsg[5] = char((byte(tamperedMsg[5]) xor 0x01))
    check not verifySignature(kp.publicKey,
      tamperedMsg.toOpenArrayByte(0, tamperedMsg.high), sig)
