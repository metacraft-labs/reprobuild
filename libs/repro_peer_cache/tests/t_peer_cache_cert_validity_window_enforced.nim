## Peer-Cache-BearSSL M2 verification: validity-window enforcement.
##
## Two certs go into one trust-anchor directory: one expired yesterday,
## one valid for another day. `loadTrustAnchorDir` accepts both into
## the set; `validateCertNotExpired` rejects the expired entry and
## accepts the valid one.

import std/[os, tables, times, unittest]

import repro_peer_cache

{.used.}

suite "peer-cache cert validity window (M2)":

  test "expired cert is rejected; valid cert is accepted":
    let now = getTime().toUnix
    let oneDay: int64 = 86_400

    let kpExpired = generateKeypair()
    let kpValid = generateKeypair()
    let cnExpired = $derivePeerIdFromPublicKey(kpExpired.publicKey)
    let cnValid = $derivePeerIdFromPublicKey(kpValid.publicKey)

    # Expired: notAfter = now - 1 day. Window must still be non-empty,
    # so notBefore is well before notAfter.
    let expiredCert = generateSelfSignedCertWithWindow(
      kpExpired, subjectCn = cnExpired,
      notBefore = now - 7 * oneDay,
      notAfter = now - oneDay)

    # Valid: notBefore <= now < notAfter.
    let validCert = generateSelfSignedCertWithWindow(
      kpValid, subjectCn = cnValid,
      notBefore = now - oneDay,
      notAfter = now + oneDay)

    # Both certs go into one trust-anchor directory.
    let anchorDir = getTempDir() / "peer_cache_m2_validity"
    if dirExists(anchorDir):
      removeDir(anchorDir)
    createDir(anchorDir)
    writeFile(anchorDir / "expired.crt", expiredCert.certPem)
    writeFile(anchorDir / "valid.crt", validCert.certPem)

    let anchors = loadTrustAnchorDir(anchorDir)
    # Both made it into the set.
    check anchors.byPeerId.len == 2

    let expiredPeerId = derivePeerIdFromPublicKey(kpExpired.publicKey)
    let validPeerId = derivePeerIdFromPublicKey(kpValid.publicKey)

    check expiredPeerId in anchors.byPeerId
    check validPeerId in anchors.byPeerId

    let expiredEntry = anchors.byPeerId[expiredPeerId]
    let validEntry = anchors.byPeerId[validPeerId]

    # Validity window survives the parse + load.
    check expiredEntry.notAfter < now
    check validEntry.notAfter > now
    check validEntry.notBefore <= now

    # The enforcement function: expired path returns false, valid path
    # returns true.
    check (not validateCertNotExpired(expiredEntry, now))
    check validateCertNotExpired(validEntry, now)

    # The subject CN survived too (derived from the peer-id hex).
    check expiredEntry.subjectCn == cnExpired
    check validEntry.subjectCn == cnValid

    removeDir(anchorDir)
