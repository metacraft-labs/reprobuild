## Windows-Runner-Binary-Cache-Deploy — RDM1 v2 envelope gate.
##
## `secrets.nim` is proven separately (seal/open, and every way of getting it
## wrong). This proves the ENVELOPE integration:
##
##   * a manifest with no secrets still encodes as v1, so the manifest served
##     to `win-ci-vm-001` today stays readable by agents that predate this
##     change;
##   * a manifest with secrets encodes as v2, so an agent that predates this
##     change REJECTS it on the version check rather than applying the desired
##     state while silently dropping the secrets it depends on;
##   * the producer signature covers the sealed section, so the ciphertext,
##     ephemeral key and nonce cannot be swapped by anyone who cannot sign.
##
## That last one is the property that makes placing the section inside the
## signed prefix worth the format churn, so it is tested by tampering rather
## than asserted in a comment.

import std/unittest

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../src/repro_deploy_agent/manifest
import ../src/repro_deploy_agent/secrets

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

proc baseManifest(target: string): DeployManifest =
  result.target = target
  result.sequence = 42'u64
  result.deploymentId = "deployment-abc"
  result.profileText = "profile \"x\":\n  resources:\n    discard\n"

suite "RDM1 v2 envelope":

  test "no secrets encodes as v1 and round-trips":
    let producer = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-vm-001")
    signManifest(producer, m)
    check m.formatVersion == DeployManifestFormatVersionV1

    let wire = encodeManifest(m)
    let back = decodeManifest(wire)
    check back.formatVersion == DeployManifestFormatVersionV1
    check back.hasSecrets == false
    check back.target == m.target
    check back.profileText == m.profileText
    check verifySignature(back)

  test "secrets encode as v2 and round-trip, and the payload opens":
    let producer = peerAuth.generateKeypair()
    let recipient = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-bare-001")
    m.hasSecrets = true
    m.secrets = sealSecrets(recipient.publicKey, m.target,
      @[SecretFile(path: "mcl.token", mode: 0o600'u32,
                   content: bytesOf("REGISTRATION-TOKEN"))])
    signManifest(producer, m)
    check m.formatVersion == DeployManifestFormatVersionV2

    let back = decodeManifest(encodeManifest(m))
    check back.formatVersion == DeployManifestFormatVersionV2
    check back.hasSecrets
    check verifySignature(back)

    let opened = openSecrets(recipient.privateKey, back.target, back.secrets)
    check opened.len == 1
    check opened[0].path == "mcl.token"
    check opened[0].content == bytesOf("REGISTRATION-TOKEN")

  test "the signature covers the sealed ciphertext":
    let producer = peerAuth.generateKeypair()
    let recipient = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-bare-001")
    m.hasSecrets = true
    m.secrets = sealSecrets(recipient.publicKey, m.target,
      @[SecretFile(path: "mcl.token", mode: 0o600'u32, content: bytesOf("t"))])
    signManifest(producer, m)
    check verifySignature(m)

    var tampered = m
    tampered.secrets.ciphertext[0] = tampered.secrets.ciphertext[0] xor 0x01'u8
    check not verifySignature(tampered)

  test "the signature covers the ephemeral key and the nonce":
    let producer = peerAuth.generateKeypair()
    let recipient = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-bare-001")
    m.hasSecrets = true
    m.secrets = sealSecrets(recipient.publicKey, m.target,
      @[SecretFile(path: "mcl.token", mode: 0o600'u32, content: bytesOf("t"))])
    signManifest(producer, m)

    var swappedKey = m
    swappedKey.secrets.ephemeralPubKey = peerAuth.generateKeypair().publicKey
    check not verifySignature(swappedKey)

    var swappedNonce = m
    swappedNonce.secrets.nonce[0] = swappedNonce.secrets.nonce[0] xor 0x01'u8
    check not verifySignature(swappedNonce)

  test "an unknown format version is rejected":
    let producer = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-bare-001")
    signManifest(producer, m)
    var wire = encodeManifest(m)
    # formatVersion is the u16 immediately after the 4-byte magic.
    wire[4] = 99'u8
    expect DeployManifestCodecError:
      discard decodeManifest(wire)

  test "trailing bytes are still rejected on a v2 envelope":
    let producer = peerAuth.generateKeypair()
    let recipient = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-bare-001")
    m.hasSecrets = true
    m.secrets = sealSecrets(recipient.publicKey, m.target,
      @[SecretFile(path: "mcl.token", mode: 0o600'u32, content: bytesOf("t"))])
    signManifest(producer, m)
    var wire = encodeManifest(m)
    wire.add(0'u8)
    expect DeployManifestCodecError:
      discard decodeManifest(wire)

  test "an empty sealed section still forces v2":
    # `hasSecrets` with an empty file list is still a sealed envelope: the
    # recipient must be able to tell "the producer sent me nothing" from "the
    # producer sent me nothing I could read".
    let producer = peerAuth.generateKeypair()
    let recipient = peerAuth.generateKeypair()
    var m = baseManifest("win-ci-bare-001")
    m.hasSecrets = true
    m.secrets = sealSecrets(recipient.publicKey, m.target, @[])
    signManifest(producer, m)
    check m.formatVersion == DeployManifestFormatVersionV2
    let back = decodeManifest(encodeManifest(m))
    check back.hasSecrets
    check openSecrets(recipient.privateKey, back.target, back.secrets).len == 0
