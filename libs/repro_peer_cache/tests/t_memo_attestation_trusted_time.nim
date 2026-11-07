## Distributed-Execution M7, threat model G15: a memo attestation is judged
## at the CONSUMER's clock (a trusted time), never at the `issuedAt` the
## issuer wrote.
##
## Before the fix the leaf was verified at `entry.issuedAtUnix`, so a key
## stolen inside its hour signed entries backdated into that hour that
## verified forever. Now:
##
##   * an attestation whose leaf is valid now is accepted (positive control);
##   * once the consumer's clock passes the issuer leaf's expiry (by more
##     than the clock-skew allowance), the same entry is refused — and the
##     verdict says `expired`, so an honest serving peer is reported but NOT
##     marked suspect (a stale entry is not a forgery);
##   * an attestation dated outside its own leaf's window is refused;
##   * `reattestIfStale` lets the ISSUER refresh its own entry with a
##     current leaf so it is accepted again, and never touches an entry
##     another host issued;
##   * `attestationFresh` is false once the leaf has expired, so a node does
##     not serve what a consumer would refuse.
##
## The reddening neuter (judge at `issuedAt`) is in the milestone's
## Verification log.
##
## MOCK POLICY — none: real host CAs, leaves and ECDSA signatures.

import std/[options, os, sets, tables, tempfiles, times, unittest]

import repro_peer_cache

proc node(base, name: string): HostIdentity =
  let dir = base / name
  loadOrCreateHostIdentity(dir / "host-ca.crt", dir / "host-ca.key")

proc anchorsOf(base: string; ids: openArray[HostIdentity]): TrustAnchorSet =
  let dir = base / "anchors"
  createDir(dir)
  for id in ids:
    writeFile(dir / ($id.hostId & ".crt"), id.ca.certPem)
  loadTrustAnchorDir(dir)

proc entryFor(issuer: HostIdentity; weak: int; leaf: LeafCredential;
              now = 0'i64): MemoEntry =
  var d: BlobDigest
  var raw: array[32, byte]
  raw[0] = byte(weak)
  d = blobDigestFromBytes(raw)
  result = MemoEntry(weakFingerprint: d, pathSetDigest: d,
    strongFingerprint: d, recordBytes: @[byte 1, 2, 3], outputDigests: @[])
  attest(result, leaf, now)

suite "Distributed-Execution M7: memo attestations are judged at the consumer's clock (G15)":

  test "an attestation verifies only while its leaf does":
    let base = createTempDir("m7-g15-memo-", "")
    defer: removeDir(base)
    let a = node(base, "a")
    let b = node(base, "b")
    let anchors = anchorsOf(base, [a, b])
    let noRevoked = initHashSet[PeerId]()
    let t0 = getTime().toUnix
    let leaf = mintLeaf(a, lrDaemon, now = t0)
    let entry = entryFor(a, 1, leaf, now = t0)

    # Positive control: now, it verifies as A's.
    let good = verifyAttestation(entry, anchors, noRevoked, t0 + 60)
    check good.ok
    check good.issuer == a.hostId
    check not good.expired

    # Past the leaf's hour (plus skew): refused, and marked EXPIRED — not a
    # forgery, so a serving peer is not to be suspected.
    let late = t0 + MaxLeafTtlSeconds + LeafClockSkewSeconds + 60
    let stale = verifyAttestation(entry, anchors, noRevoked, late)
    check not stale.ok
    check stale.expired
    check not attestationFresh(entry, late)
    check attestationFresh(entry, t0 + 60)

    # A record whose `issuedAt` lies outside its leaf's window is refused
    # outright (a leaf minted now cannot vouch for a year-old attestation).
    var backdated = entry
    backdated.issuedAtUnix = t0 - MaxLeafTtlSeconds - 10_000
    let bad = verifyAttestation(backdated, anchors, noRevoked, t0 + 60)
    check not bad.ok
    check not bad.expired                       # the signature/window is wrong

    # The issuer re-attests its own stale entry with a current leaf.
    var refreshable = entry
    let freshLeaf = mintLeaf(a, lrDaemon, now = late)
    check reattestIfStale(refreshable, freshLeaf, now = late)
    check verifyAttestation(refreshable, anchors, noRevoked, late).ok
    # …but never an entry another host issued.
    var foreign = entry
    let bLeaf = mintLeaf(b, lrDaemon, now = late)
    check not reattestIfStale(foreign, bLeaf, now = late)
