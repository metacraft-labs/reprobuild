## Peer-Cache-Scale M2 verification test: inter-rack tier-2
## advertisement + cross-rack fetch routing.
##
## Two simulated racks, each with two ordinary peers + 1 tier-2 node:
##   rack A: { peer A1, peer A2, tier-2 TA }
##   rack B: { peer B1, peer B2, tier-2 TB }
##
## TA's disk store holds blob `D`. TA and TB are joined in an
## "inter-rack SWIM group" — modelled as an `InterRackBridge` that
## propagates each tier-2's cuckoo filter into the other rack's
## registry on `advertiseRound()`. The test then exercises the
## end-to-end fetch path:
##   B's peer requests D → its registry sorts TB (tier-2) first →
##   TB disk-misses → TB falls through via the inter-rack bridge to
##   TA's disk store → blob bytes return.
##
## See `Peer-Cache-Scale.milestones.org` §M2 verification list and
## `Peer-Cache-Scale.md` §"Tier-2 cache hierarchy" §"Inter-rack
## topology".

import std/[options, os, tables, unittest]

import blake3

import repro_peer_cache

proc digestFor(payload: openArray[byte]): BlobDigest =
  blobDigestFromBytes(blake3.digest(payload))

proc peerIdN(tag: byte; rack: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(tag) * 31 + int(rack) * 7 + i * 11 + 3) and 0xff)
  peerIdFromBytes(raw)

type
  Rack = ref object
    racKid: byte
    peers: seq[PeerId]            ## Ordinary rack-local peer ids.
    tier2Id: PeerId               ## This rack's tier-2 peer id.
    registry: PeerRegistry        ## Rack-local registry (peer A1's view).
    tier2: Tier2Cache             ## The rack's tier-2 cache state.

  InterRackBridge = ref object
    ## Models the "inter-rack SWIM group" called out in
    ## `Peer-Cache-Scale.md` §"Tier-2 cache hierarchy": tier-2 nodes
    ## from multiple racks share advertisements at a slower cadence.
    ## In M2 this is a thin propagation layer that:
    ## - propagates each tier-2's cuckoo filter into the other rack's
    ##   rack-local registry as if it were a peer entry, and
    ## - exposes a `fetch(digest)` proc that routes through the
    ##   sibling tier-2's disk store for a cross-rack lookup.
    members: seq[Rack]

proc newInterRackBridge(racks: openArray[Rack]): InterRackBridge =
  InterRackBridge(members: @racks)

proc advertiseRound(bridge: InterRackBridge) =
  ## Each tier-2 publishes its current cuckoo-filter snapshot into
  ## every other rack's rack-local registry under its tier-2 peer id.
  ## The cuckoo filter capacity is sized off the publishing tier-2's
  ## disk-store size.
  for src in bridge.members:
    let snapshot = src.tier2.registry.snapshotV2For(src.tier2Id)
    for dst in bridge.members:
      if dst.racKid == src.racKid: continue
      # Ensure the destination rack's registry knows about the source
      # tier-2 as a peer (synthetic endpoint).
      dst.registry.addPeer(src.tier2Id,
                           initEndpoint("127.0.0.1",
                                        Port(40000 + int(src.racKid))))
      dst.registry.setPeerTier2(src.tier2Id, true)
      dst.registry.applyAdvertiseV2(src.tier2Id, snapshot)

proc makeBridgeUpstream(bridge: InterRackBridge;
                       selfRackId: byte): UpstreamCacheClient =
  ## Returns a closure that, on disk miss, walks the other tier-2
  ## caches in the bridge and pulls the blob from the first one that
  ## has it. Used to wire a tier-2's `lookup` upstream fallthrough
  ## across racks.
  result = proc(d: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    for member in bridge.members:
      if member.racKid == selfRackId: continue
      let local = member.tier2.diskStore.load(d)
      if local.isSome:
        return local
    none(seq[byte])

suite "peer-cache-scale M2 inter-rack tier-2 advertisement":
  test "blob in rack A's tier-2 store routes through inter-rack bridge to rack B":
    let tmpRoot = getTempDir() / "repro_peer_cache_m2_inter_rack"
    if dirExists(tmpRoot):
      removeDir(tmpRoot)

    let payload: seq[byte] = @[byte 0x01, 0x02, 0x03, 0x04,
                               0xAA, 0xBB, 0xCC, 0xDD,
                               0xEE, 0xFF]
    let digest = digestFor(payload)

    # Rack A setup.
    let registryA = newPeerRegistry(peerIdN(0x10, 0xA),
                                    initEndpoint("127.0.0.1", Port(1)))
    let dsA = newDiskStore(tmpRoot / "rackA",
                           maxBytes = 1024 * 1024'u64)
    discard dsA.store(digest, payload)
    let tier2A = newTier2Cache(dsA, registryA, nil)
    let peerA1 = peerIdN(0x20, 0xA)
    let peerA2 = peerIdN(0x21, 0xA)
    let tier2IdA = peerIdN(0x80, 0xA)
    for p in [peerA1, peerA2]:
      registryA.addPeer(p, initEndpoint("127.0.0.1", Port(40110)))

    let rackA = Rack(
      racKid: 0xA,
      peers: @[peerA1, peerA2],
      tier2Id: tier2IdA,
      registry: registryA,
      tier2: tier2A)

    # Rack B setup. TB's disk store is empty; B's peers don't have D.
    let registryB = newPeerRegistry(peerIdN(0x10, 0xB),
                                    initEndpoint("127.0.0.1", Port(2)))
    let dsB = newDiskStore(tmpRoot / "rackB",
                           maxBytes = 1024 * 1024'u64)
    let peerB1 = peerIdN(0x20, 0xB)
    let peerB2 = peerIdN(0x21, 0xB)
    let tier2IdB = peerIdN(0x80, 0xB)
    for p in [peerB1, peerB2]:
      registryB.addPeer(p, initEndpoint("127.0.0.1", Port(40210)))
    # Register TB locally as a peer in registryB so we can sort it
    # ahead of the ordinary peers when B1 looks for D.
    registryB.addPeer(tier2IdB, initEndpoint("127.0.0.1", Port(40220)))
    registryB.setPeerTier2(tier2IdB, true)

    let rackB = Rack(
      racKid: 0xB,
      peers: @[peerB1, peerB2],
      tier2Id: tier2IdB,
      registry: registryB,
      tier2: nil)  # constructed below after the bridge so we can wire upstream

    let bridge = newInterRackBridge([rackA, rackB])
    # TB's upstream falls through to TA via the bridge.
    let tbUpstream = makeBridgeUpstream(bridge, selfRackId = 0xB)
    let tier2B = newTier2Cache(dsB, registryB, tbUpstream)
    rackB.tier2 = tier2B

    # Pre-bridge: rack B doesn't know D exists anywhere.
    let preCandidates = registryB.findPeersWithBlob(digest)
    check tier2IdA notin preCandidates

    # Inter-rack advertise round: TA's filter is propagated into rackB.
    bridge.advertiseRound()

    # Post-bridge: TB (and rack B's registry view via the synthetic
    # tier-2-A peer entry) sees TA as a candidate for D.
    let postCandidates = registryB.findPeersWithBlob(digest)
    check tier2IdA in postCandidates
    # Tier-2 sort moves TA to the front.
    let sortedCandidates = sortTier2First(registryB, postCandidates)
    check sortedCandidates.len >= 1
    check registryB.isPeerTier2(sortedCandidates[0])

    # End-to-end fetch: a peer in rack B requests D. The peer first
    # consults its tier-2 (TB); TB disk-misses, falls through to TA
    # via the bridge upstream, returns the bytes.
    let fetched = tier2B.lookup(digest)
    check fetched.isSome
    check fetched.get() == payload
    check tier2B.upstreamHits == 1'u64
    # After the cross-rack fetch, TB has cached D locally and
    # advertises it.
    check dsB.has(digest)
    check tier2B.localHits == 0'u64
    let secondFetch = tier2B.lookup(digest)
    check secondFetch.isSome
    check tier2B.localHits == 1'u64

    removeDir(tmpRoot)
