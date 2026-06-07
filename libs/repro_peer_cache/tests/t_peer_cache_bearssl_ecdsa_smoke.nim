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

import bearssl/[rand, ec, hash]

{.used.}

const
  TestMessage = "peer-cache-bearssl-m0-smoke-msg!"  # exactly 32 bytes
  P256RawSigLen = 64                                # two 32-byte scalars
  P256UncompressedPubLen = 65                       # 0x04 || X(32) || Y(32)

suite "peer-cache bearssl ecdsa-p256 signing smoke":

  test "ECDSA-P256 sign/verify round-trip":
    doAssert TestMessage.len == 32

    let rng = HmacDrbgContext.new()
    let ecImpl = ecGetDefault()

    # Generate the keypair into a private-key buffer sized for any
    # supported curve.
    var skBuf: array[EC_KBUF_PRIV_MAX_SIZE, byte]
    var sk: EcPrivateKey
    let skLen = ecKeygen(PrngClassPointerConst(addr rng.vtable), ecImpl,
                         addr sk, addr skBuf[0], cint(EC_secp256r1))
    check skLen != 0

    # Derive the matching public key.
    var pkBuf: array[EC_KBUF_PUB_MAX_SIZE, byte]
    var pk: EcPublicKey
    let pkLen = ecComputePub(ecImpl, addr pk, addr pkBuf[0], addr sk)
    check pkLen != 0

    # ECDSA-P256 uncompressed pubkey wire shape: 65 bytes
    # (0x04 || X || Y). PeerId = BLAKE3-256(publicKey) keeps the
    # on-wire PeerId at 32 bytes regardless of this size.
    check int(pk.qlen) == P256UncompressedPubLen

    # Hash the 32-byte test message with SHA-256. Bind the const to a
    # mutable buffer so `addr` is legal.
    var msg = TestMessage
    var hctx = Sha256Context()
    var hashOut: array[sha256SIZE, byte]
    sha256Init(hctx)
    sha256Update(hctx, addr msg[0], uint(msg.len))
    sha256Out(hctx, addr hashOut[0])

    # Sign in raw (fixed-length) encoding so we get a 64-byte signature
    # that matches the existing AdvertiseV2.signature wire slot.
    var sig: array[P256RawSigLen, byte]
    let signer = ecdsaSignRawGetDefault()
    let sigLen = signer(ecImpl, addr sha256Vtable, addr hashOut[0],
                        addr sk, addr sig[0])
    check sigLen == uint(P256RawSigLen)

    # Verify the good signature: must accept.
    let verifier = ecdsaVrfyRawGetDefault()
    let okGood = verifier(ecImpl, addr hashOut[0], csize_t(hashOut.len),
                          addr pk, addr sig[0], csize_t(sigLen))
    check okGood == 1'u32

    # Tamper one byte of the *message*, re-hash, and verify against
    # the tampered digest: must reject.
    var tamperedMsg = TestMessage
    tamperedMsg[5] = char((byte(tamperedMsg[5]) xor 0x01))
    var hctx2 = Sha256Context()
    var tamperedHash: array[sha256SIZE, byte]
    sha256Init(hctx2)
    sha256Update(hctx2, addr tamperedMsg[0], uint(tamperedMsg.len))
    sha256Out(hctx2, addr tamperedHash[0])
    let okTampered = verifier(ecImpl, addr tamperedHash[0],
                              csize_t(tamperedHash.len), addr pk,
                              addr sig[0], csize_t(sigLen))
    check okTampered == 0'u32
