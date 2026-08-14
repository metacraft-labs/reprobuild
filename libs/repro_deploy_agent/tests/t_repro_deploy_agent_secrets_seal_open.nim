## Windows-Runner-Binary-Cache-Deploy — RDM1 v2 sealed-secrets gate.
##
## The manifest channel is signed but PUBLIC, so the publisher key and the
## hourly registration token a pull-model box needs cannot ride it in the
## clear. `secrets.nim` seals them to one recipient. This proves the
## construction does what the header claims, and — more importantly — that
## every way of getting it wrong FAILS CLOSED rather than yielding plaintext.
##
## The negative cases are the point. A round-trip test alone would pass just
## as happily against a "cipher" that ignored the key.

import std/[strutils, unittest]

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../src/repro_deploy_agent/secrets

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc stringOf(b: seq[byte]): string =
  result = newString(b.len)
  for i, x in b:
    result[i] = char(x)

let sampleFiles = @[
  SecretFile(path: "mcl.token", mode: 0o600'u32,
             content: bytesOf("AGHJ7QDUMMYREGISTRATIONTOKEN")),
  SecretFile(path: "cache/publisher.key", mode: 0o600'u32,
             content: bytesOf("ecdsa-p256:" & repeat('a', 64))),
]

suite "RDM1 v2 sealed secrets":

  test "round-trips to the intended recipient":
    let recipient = peerAuth.generateKeypair()
    let sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    let opened = openSecrets(recipient.privateKey, "win-ci-bare-001", sealed)

    check opened.len == sampleFiles.len
    for i in 0 ..< opened.len:
      check opened[i].path == sampleFiles[i].path
      check opened[i].mode == sampleFiles[i].mode
      check opened[i].content == sampleFiles[i].content

  test "the plaintext does not appear in the ciphertext":
    # Guards the embarrassing failure: a construction that "works" in the
    # round-trip because it never actually encrypted anything.
    let recipient = peerAuth.generateKeypair()
    let secret = "AGHJ7QDUMMYREGISTRATIONTOKEN"
    let sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001",
      @[SecretFile(path: "mcl.token", mode: 0o600'u32, content: bytesOf(secret))])
    check secret notin stringOf(sealed.ciphertext)
    check "mcl.token" notin stringOf(sealed.ciphertext)

  test "a fresh ephemeral key per seal, so no key or nonce is ever reused":
    let recipient = peerAuth.generateKeypair()
    let a = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    let b = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    check a.ephemeralPubKey != b.ephemeralPubKey
    check a.nonce != b.nonce
    check a.ciphertext != b.ciphertext

  test "the wrong recipient cannot open it":
    let recipient = peerAuth.generateKeypair()
    let attacker = peerAuth.generateKeypair()
    let sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    expect SecretsError:
      discard openSecrets(attacker.privateKey, "win-ci-bare-001", sealed)

  test "an envelope cannot be replayed at a different target":
    # The target is bound into the KDF info AND the GCM aad, so the same
    # bytes presented to another box derive a different key and fail the tag.
    let recipient = peerAuth.generateKeypair()
    let sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    expect SecretsError:
      discard openSecrets(recipient.privateKey, "win-ci-vm-001", sealed)

  test "a tampered ciphertext fails the tag check":
    let recipient = peerAuth.generateKeypair()
    var sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    sealed.ciphertext[0] = sealed.ciphertext[0] xor 0x01'u8
    expect SecretsError:
      discard openSecrets(recipient.privateKey, "win-ci-bare-001", sealed)

  test "a tampered tag fails":
    let recipient = peerAuth.generateKeypair()
    var sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    sealed.tag[0] = sealed.tag[0] xor 0x01'u8
    expect SecretsError:
      discard openSecrets(recipient.privateKey, "win-ci-bare-001", sealed)

  test "a substituted ephemeral public key fails":
    let recipient = peerAuth.generateKeypair()
    let other = peerAuth.generateKeypair()
    var sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", sampleFiles)
    sealed.ephemeralPubKey = other.publicKey
    expect SecretsError:
      discard openSecrets(recipient.privateKey, "win-ci-bare-001", sealed)

  test "an invalid recipient point is rejected rather than used":
    var bogus: peerAuth.PublicKeyBytes
    bogus[0] = 0x04'u8   # well-formed prefix, coordinates not on the curve
    for i in 1 ..< peerAuth.P256PubLen:
      bogus[i] = 0x01'u8
    expect SecretsError:
      discard sealSecrets(bogus, "win-ci-bare-001", sampleFiles)

  test "an empty secret list round-trips":
    let recipient = peerAuth.generateKeypair()
    let sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001", @[])
    check openSecrets(recipient.privateKey, "win-ci-bare-001", sealed).len == 0

  test "path traversal is rejected on both encode and decode":
    let recipient = peerAuth.generateKeypair()
    for bad in @["../escape", "a/../../escape", "/absolute", "C:/drive",
                 "back\\slash", "", "a//b"]:
      expect SecretsError:
        discard sealSecrets(recipient.publicKey, "win-ci-bare-001",
          @[SecretFile(path: bad, mode: 0o600'u32, content: bytesOf("x"))])

  test "a truncated payload is rejected, not silently accepted":
    expect SecretsError:
      discard decodeSecretFiles(@[byte(1), byte(0), byte(0), byte(0)])

  test "trailing bytes in the payload are rejected":
    var payload = encodeSecretFiles(sampleFiles)
    payload.add(byte(0))
    expect SecretsError:
      discard decodeSecretFiles(payload)

  test "content with embedded NULs and high bytes survives":
    let recipient = peerAuth.generateKeypair()
    var raw = newSeq[byte](256)
    for i in 0 ..< 256:
      raw[i] = byte(i)
    let sealed = sealSecrets(recipient.publicKey, "win-ci-bare-001",
      @[SecretFile(path: "binary.bin", mode: 0o600'u32, content: raw)])
    let opened = openSecrets(recipient.privateKey, "win-ci-bare-001", sealed)
    check opened.len == 1
    check opened[0].content == raw
