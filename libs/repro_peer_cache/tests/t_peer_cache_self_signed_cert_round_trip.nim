## Peer-Cache-BearSSL M2 verification: generate a self-signed X.509
## cert from a fresh ECDSA-P256 keypair, write it to disk, read it
## back, and verify the cert's self-signature with BearSSL's verifier.

import std/[os, strutils, unittest]

import repro_peer_cache

{.used.}

suite "peer-cache self-signed cert round trip (M2)":

  test "generate, write, load, verify self-signature":
    let kp = generateKeypair()
    let peerId = derivePeerIdFromPublicKey(kp.publicKey)
    let subjectCn = $peerId   # 64 hex chars

    let cert = generateSelfSignedCert(kp, subjectCn = subjectCn,
                                       validityDays = 365)

    # Surface invariants on the in-memory cert.
    check cert.subjectCn == subjectCn
    check cert.certPem.startsWith("-----BEGIN CERTIFICATE-----")
    check cert.certDer.len > 0
    check cert.notAfter > cert.notBefore

    # Write the cert + key to a tempdir, then read them back through
    # the M2 loader path.
    let tmp = getTempDir() / "peer_cache_m2_cert_round_trip"
    if dirExists(tmp):
      removeDir(tmp)
    createDir(tmp)
    let certPath = tmp / "peer.crt"
    let keyPath = tmp / "peer.key"
    writeCertAndKey(cert, certPath, keyPath)
    check fileExists(certPath)
    check fileExists(keyPath)

    let loaded = loadCertAndKey(certPath, keyPath)

    # Pubkey must round-trip byte-for-byte (the load path re-derives
    # the pubkey from the private scalar and compares against the SPKI
    # in the cert; we also recheck on the test side).
    check loaded.keypair.publicKey == kp.publicKey
    check loaded.subjectCn == subjectCn
    check loaded.certDer == cert.certDer

    # Verify the cert's self-signature with BearSSL.
    check verifyCertSelfSignature(loaded.certDer)

    # Also verify the freshly-generated in-memory cert (sanity).
    check verifyCertSelfSignature(cert.certDer)

    removeDir(tmp)

  test "tampered cert signature fails BearSSL verification":
    let kp = generateKeypair()
    let cn = $derivePeerIdFromPublicKey(kp.publicKey)
    let cert = generateSelfSignedCert(kp, subjectCn = cn, validityDays = 365)

    # Flip one byte of the cert near the end (inside the BIT STRING
    # signature payload). This must invalidate the signature.
    var tampered = cert.certDer
    tampered[^4] = byte(int(tampered[^4]) xor 0x01)
    check (not verifyCertSelfSignature(tampered))
