## Peer-Cache-BearSSL M1 verification: real ECDSA-P256 sign / verify
## over the canonical `AdvertiseV2` byte sequence.
##
## Two fresh keypairs A and B. Each signs the canonicalised bytes of a
## fixed `AdvertiseV2` fixture. The other side verifies against the
## sender's pubkey. PASS.
##
## Tampering one byte of the canonicalised message flips verify to
## false. Tampering one byte of the signature flips verify to false.
## Verifying A's signature against B's pubkey returns false (wrong
## pubkey).
##
## The same wire shapes hold byte-for-byte against the M3 HMAC stand-in
## (sig 64 B; canonical-message shape unchanged), but the primitive is
## now real ECDSA-P256 via `nim-bearssl`.

import std/unittest

import repro_peer_cache

{.used.}

proc fixturePeerId(seed: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte(int(seed) + i)
  peerIdFromBytes(raw)

proc fixtureAdvertise(seqNo: uint64): AdvertiseV2 =
  # A deterministic filter payload — content is opaque to the signer.
  var filter = newSeq[byte](48)
  for i in 0 ..< filter.len:
    filter[i] = byte((i * 7 + 13) and 0xff)
  AdvertiseV2(
    sequence: seqNo,
    mode: amSnapshot,
    filterCapacity: 64'u32,
    filterCount: uint32(filter.len),
    filterBytes: filter,
    signature: @[])

suite "peer-cache ECDSA-P256 sign / verify round trip":
  test "two fresh keypairs sign + verify each other's advertisement":
    let kpA = generateKeypair()
    let kpB = generateKeypair()

    # Pubkey sanity: two fresh keypairs should not collide; both have
    # the 0x04 uncompressed-point marker.
    check kpA.publicKey != kpB.publicKey
    check kpA.publicKey[0] == 0x04'u8
    check kpB.publicKey[0] == 0x04'u8

    let peerIdA = fixturePeerId(0x10)
    let peerIdB = fixturePeerId(0x20)
    let adA = fixtureAdvertise(1'u64)
    let adB = fixtureAdvertise(2'u64)

    let msgA = canonicaliseAdvertiseForSigning(peerIdA, adA)
    let msgB = canonicaliseAdvertiseForSigning(peerIdB, adB)
    let sigA = signMessage(kpA, msgA)
    let sigB = signMessage(kpB, msgB)

    # 1) Each side verifies the other's signature against the correct
    # pubkey — both must accept.
    check verifySignature(kpA.publicKey, msgA, sigA)
    check verifySignature(kpB.publicKey, msgB, sigB)

  test "tampered message bytes flip verify to false":
    let kp = generateKeypair()
    let peerId = fixturePeerId(0x30)
    let ad = fixtureAdvertise(7'u64)
    var msg = canonicaliseAdvertiseForSigning(peerId, ad)
    let sig = signMessage(kp, msg)
    check verifySignature(kp.publicKey, msg, sig)

    # Flip one byte (deep inside the canonical buffer, not at the
    # length prefix) and re-verify against the original signature.
    msg[msg.len div 2] = byte(int(msg[msg.len div 2]) xor 0x01)
    check (not verifySignature(kp.publicKey, msg, sig))

  test "tampered signature byte flips verify to false":
    let kp = generateKeypair()
    let peerId = fixturePeerId(0x40)
    let ad = fixtureAdvertise(9'u64)
    let msg = canonicaliseAdvertiseForSigning(peerId, ad)
    var sig = signMessage(kp, msg)
    check verifySignature(kp.publicKey, msg, sig)

    sig[5] = byte(int(sig[5]) xor 0x01)
    check (not verifySignature(kp.publicKey, msg, sig))

  test "wrong-pubkey verify rejects":
    let kpA = generateKeypair()
    let kpB = generateKeypair()
    let peerId = fixturePeerId(0x50)
    let ad = fixtureAdvertise(11'u64)
    let msg = canonicaliseAdvertiseForSigning(peerId, ad)
    let sigA = signMessage(kpA, msg)
    # A signed it; verifying against B's pubkey must reject.
    check (not verifySignature(kpB.publicKey, msg, sigA))
    # Sanity: the right pubkey does accept.
    check verifySignature(kpA.publicKey, msg, sigA)
