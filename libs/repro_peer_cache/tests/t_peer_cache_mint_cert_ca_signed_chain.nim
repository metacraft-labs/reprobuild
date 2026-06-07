## Peer-Cache-BearSSL M4 verification: `mint-cert --import-ca` followed
## by `mint-cert --ca-cert --ca-key` produces a peer cert whose chain
## validates against the CA: the peer cert's issuer DN matches the CA's
## subject DN, and the peer cert's outer signature verifies under the
## CA's public key.
##
## The CA cert is loaded via `loadTrustAnchorDir` and checked for
## `isCa == true`; the peer cert is loaded via `loadCertAndKey` and
## checked for `isCa == false`.

import std/[os, strutils, tables, times, unittest]

import repro_peer_cache

import "../../../apps/repro-peer-cache-mint-cert/repro_peer_cache_mint_cert"

{.used.}

suite "peer-cache mint-cert CA-signed chain (M4)":
  test "CA-signed peer cert chain validates against the mini-CA":
    let tmp = getTempDir() / "peer_cache_m4_mint_ca_" & $epochTime()
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    try:
      let caDir = tmp / "ca"
      let anchorDir = tmp / "anchors"
      let peerDir = tmp / "peer"
      createDir(anchorDir)

      # Step 1: mint a mini-CA.
      check 0 == mintCertMain(@["--import-ca", "--out=" & caDir])
      check fileExists(caDir / "ca.crt")
      check fileExists(caDir / "ca.key")

      # Put the CA cert in the anchor directory and reload it.
      copyFile(caDir / "ca.crt", anchorDir / "ca.crt")
      let anchors = loadTrustAnchorDir(anchorDir)
      check anchors.byPeerId.len == 1
      var anchorEntry: TrustAnchorEntry
      for _, entry in anchors.byPeerId.pairs:
        anchorEntry = entry
      check anchorEntry.isCa

      # Step 2: mint a CA-signed peer cert.
      check 0 == mintCertMain(@[
        "--ca-cert=" & (caDir / "ca.crt"),
        "--ca-key=" & (caDir / "ca.key"),
        "--out=" & peerDir,
      ])
      check fileExists(peerDir / "peer.crt")
      check fileExists(peerDir / "peer.key")

      let peerCert = loadCertAndKey(peerDir / "peer.crt",
                                    peerDir / "peer.key")
      check (not findIsCa(peerCert.certDer))

      # The peer cert's issuer DN must match the CA's subject DN.
      let issuerDn = findIssuerDn(peerCert.certDer)
      check issuerDn == anchorEntry.subjectDn

      # The peer cert's signature must verify under the CA's pubkey.
      check verifyCertSignatureWith(peerCert.certDer, anchorEntry.publicKey)

      # The peer cert must NOT self-verify (signed by a different key).
      check (not verifyCertSelfSignature(peerCert.certDer))
    finally:
      removeDir(tmp)
