## Peer-Cache-BearSSL M4 verification: `mint-cert --self-signed`
## produces a loadable self-signed cert whose subject CN matches the
## derived peer-id hex and whose self-signature verifies under BearSSL.
##
## Calls the CLI via its in-process library entry point
## (`mintCertMain`) rather than spawning the binary, so the test
## doesn't depend on a built artifact under `apps/`.

import std/[os, strutils, times, unittest]

import repro_peer_cache

# The mint-cert CLI lives under `apps/` next to the other peer-cache
# entry points. We pull it in via a direct path here so the test
# doesn't depend on a separately-installed binary.
import "../../../apps/repro-peer-cache-mint-cert/repro_peer_cache_mint_cert"

{.used.}

suite "peer-cache mint-cert --self-signed round trip (M4)":
  test "writes peer.crt+peer.key; cert self-verifies; CN matches peer-id":
    let tmp = getTempDir() / "peer_cache_m4_mint_self_" & $epochTime()
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    try:
      let outDir = tmp / "peer"
      let argv = @[
        "--self-signed",
        "--out=" & outDir,
      ]
      let rc = mintCertMain(argv)
      check rc == 0
      check fileExists(outDir / "peer.crt")
      check fileExists(outDir / "peer.key")

      # Load the cert and verify the self-signature.
      let loaded = loadCertAndKey(outDir / "peer.crt", outDir / "peer.key")
      check verifyCertSelfSignature(loaded.certDer)

      # The cert's subject CN must equal the derived peer-id hex.
      let derivedPeerId = derivePeerIdFromPublicKey(loaded.keypair.publicKey)
      check loaded.subjectCn == $derivedPeerId

      # The cert must NOT be flagged as a CA.
      check (not findIsCa(loaded.certDer))
    finally:
      removeDir(tmp)
