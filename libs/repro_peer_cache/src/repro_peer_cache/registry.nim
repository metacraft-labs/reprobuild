## In-memory peer registry — Peer-Cache M0 + Peer-Cache-Scale M1.
##
## Maintains `peerId → endpoint + advertised blobs + lastSeen` for
## every peer this node has handshaken with. See
## `Peer-Cache.md` §"Advertisement index".
##
## Peer-Cache-Scale M1 changes the `advertised` representation from an
## exact `HashSet[BlobDigest]` to a probabilistic `CuckooFilter`. The
## filter is lazily allocated when the first advertisement arrives.
## `applyAdvertise` (v1) and `applyAdvertiseV2` (v2) both route through
## the same in-memory shape: v1 builds a filter from the digest list,
## v2 deserialises the wire bytes. `findPeersWithBlob` becomes
## probabilistic — false positives are bounded by the filter's
## configured FPR (default 1%), false negatives are impossible.

import std/[algorithm, monotimes, sets, tables]

import ./types
import ./cuckoo

export cuckoo

const
  DefaultPeerFilterCapacity* = 1024'u32
    ## Default cuckoo-filter capacity used when a peer's first
    ## advertisement is a v1 raw-digest list (we don't know the peer's
    ## intended capacity from a v1 frame, so we size for a comfortable
    ## working set and grow lazily if necessary). v2 frames carry an
    ## explicit `filterCapacity`.

type
  PeerEntry* = object
    endpoint*: Endpoint
    advertised*: CuckooFilter
      ## Peer-Cache-Scale M1: cuckoo-filter representation of the
      ## peer's advertised blob set. Lazily allocated when the first
      ## advertisement arrives. `nil` while the peer has only
      ## handshaken.
    lastSeen*: MonoTime
    lastAdvertiseSequence*: uint64
    hasAdvertiseSequence*: bool
      ## False until the peer has sent at least one snapshot or delta
      ## advertisement; the sequence-gap check is skipped while this
      ## is false (the very first advertise from a fresh peer has no
      ## predecessor to compare against).
    suspect*: bool
      ## Set when a peer has returned a corrupt fetch response, an
      ## unexpected sequence gap that we couldn't recover from, or
      ## any other protocol-level inconsistency. M0 only flips this
      ## via `markSuspect`; M1 wires the BLAKE3-verification failure
      ## path into the same flag.
    swimStatus*: SwimMemberStatus
      ## Peer-Cache-Scale M0: SWIM lifecycle status. Distinct from the
      ## advertise-layer `suspect` flag above — SWIM's `Suspected`
      ## means "no probe ack in the last suspect window", whereas
      ## `suspect` means "this peer is mis-advertising blobs".
    swimIncarnation*: uint64
      ## Peer-Cache-Scale M0: incarnation number for SWIM refutation.
      ## Bumped by the peer itself on self-refute; mirrored locally as
      ## dissemination updates arrive.
    swimStatusSince*: MonoTime
      ## Peer-Cache-Scale M0: timestamp of the last `swimStatus`
      ## transition. The SWIM scheduler scans this to age
      ## `Suspected` → `Confirmed` and `Confirmed` → removed.

  PeerRegistry* = ref object
    entries*: Table[PeerId, PeerEntry]
    selfPeerId*: PeerId
    selfEndpoint*: Endpoint
    selfAdvertised*: HashSet[BlobDigest]
      ## Self-side stays as a `HashSet` — the local node knows its
      ## own digests exactly and only converts to a `CuckooFilter`
      ## when emitting an `AdvertiseV2` snapshot.
    selfSequence*: uint64

proc newPeerRegistry*(selfPeerId: PeerId; selfEndpoint: Endpoint):
    PeerRegistry =
  result = PeerRegistry(
    entries: initTable[PeerId, PeerEntry](),
    selfPeerId: selfPeerId,
    selfEndpoint: selfEndpoint,
    selfAdvertised: initHashSet[BlobDigest](),
    selfSequence: 0'u64)

proc addPeer*(reg: PeerRegistry; peerId: PeerId; endpoint: Endpoint) =
  ## Registers a peer with no advertised blobs yet. Idempotent: a
  ## second call with the same peer ID refreshes the endpoint and
  ## `lastSeen` but preserves the advertised filter.
  if reg.entries.hasKey(peerId):
    var entry = reg.entries[peerId]
    entry.endpoint = endpoint
    entry.lastSeen = getMonoTime()
    reg.entries[peerId] = entry
  else:
    let now = getMonoTime()
    reg.entries[peerId] = PeerEntry(
      endpoint: endpoint,
      advertised: nil,
      lastSeen: now,
      lastAdvertiseSequence: 0'u64,
      hasAdvertiseSequence: false,
      suspect: false,
      swimStatus: smsAlive,
      swimIncarnation: 0'u64,
      swimStatusSince: now)

proc removePeer*(reg: PeerRegistry; peerId: PeerId) =
  reg.entries.del(peerId)

proc hasPeer*(reg: PeerRegistry; peerId: PeerId): bool =
  reg.entries.hasKey(peerId)

proc digestBytes(d: BlobDigest): array[32, byte] = bytes(d)

proc buildFilterFromDigests(digests: openArray[BlobDigest];
                            capacity: uint32): CuckooFilter =
  ## Helper: builds a fresh cuckoo filter sized for `capacity` and
  ## inserts every digest. Used for v1 → in-memory routing and as the
  ## reset path inside `applyAdvertise(...amSnapshot)`.
  let sized =
    if capacity < uint32(digests.len): uint32(digests.len)
    else: capacity
  result = newCuckooFilter(max(sized, 1'u32))
  for d in digests:
    let raw = digestBytes(d)
    discard result.insert(raw)

proc applyAdvertiseV2*(reg: PeerRegistry; peerId: PeerId; ad: AdvertiseV2) =
  ## Peer-Cache-Scale M1: applies a v2 cuckoo-filter advertisement.
  ## Snapshot deserialises and replaces the peer's filter; delta is
  ## not defined for v2 (the wire shape carries the full filter on
  ## every snapshot; deltas would need a separate "insert this
  ## fingerprint" payload, which is deferred to a follow-up). For the
  ## v2-snapshot path we ignore the `filterCount` field after
  ## deserialisation — the deserialised filter already carries the
  ## same count.
  if not reg.entries.hasKey(peerId):
    return
  var entry = reg.entries[peerId]
  entry.lastSeen = getMonoTime()
  case ad.mode
  of amSnapshot:
    entry.advertised = deserialize(ad.filterBytes)
    entry.lastAdvertiseSequence = ad.sequence
    entry.hasAdvertiseSequence = true
    entry.suspect = false
  of amDelta:
    # Sequence-gap detection mirrors the v1 path.
    let expected =
      if entry.hasAdvertiseSequence: entry.lastAdvertiseSequence + 1
      else: ad.sequence
    if entry.hasAdvertiseSequence and ad.sequence != expected:
      entry.suspect = true
      reg.entries[peerId] = entry
      return
    # v2 delta carries a replacement filter; merge by deserialising
    # into a temporary and unioning into the existing one. The wire
    # shape currently only ships full-replacement filters, so deltas
    # arrive as either an empty filter (no-op) or a new filter (treat
    # as a snapshot at the v2 layer). We deserialise + replace; a
    # future M1.x can wire a richer "add these fingerprints" payload.
    entry.advertised = deserialize(ad.filterBytes)
    entry.lastAdvertiseSequence = ad.sequence
    entry.hasAdvertiseSequence = true
  reg.entries[peerId] = entry

proc applyAdvertise*(reg: PeerRegistry; peerId: PeerId; ad: Advertise) =
  ## Applies a v1 snapshot or delta advertisement from `peerId`. The
  ## v1 wire shape (raw digest lists) is converted to the v2 in-memory
  ## shape (cuckoo filter) before storage so `findPeersWithBlob` only
  ## needs to query the filter. Snapshot rebuilds the filter from the
  ## `added` list; delta inserts/deletes against the existing filter.
  ## Sequence-gap detection mirrors the v1 semantics — the suspect
  ## flag is set on a detected gap and the gap-causing delta is
  ## dropped so the receiver can request a fresh snapshot.
  if not reg.entries.hasKey(peerId):
    return
  var entry = reg.entries[peerId]
  entry.lastSeen = getMonoTime()
  case ad.mode
  of amSnapshot:
    # Build a fresh filter from the snapshot. The `removed` list is
    # honoured for symmetry with the v1 semantics — a snapshot with
    # an explicit removal list collapses to (added minus removed).
    var live = newSeq[BlobDigest]()
    var removedSet = initHashSet[BlobDigest]()
    for d in ad.removed:
      removedSet.incl(d)
    for d in ad.added:
      if d notin removedSet:
        live.add(d)
    entry.advertised = buildFilterFromDigests(live, DefaultPeerFilterCapacity)
    entry.lastAdvertiseSequence = ad.sequence
    entry.hasAdvertiseSequence = true
    entry.suspect = false
  of amDelta:
    let expected =
      if entry.hasAdvertiseSequence: entry.lastAdvertiseSequence + 1
      else: ad.sequence
    if entry.hasAdvertiseSequence and ad.sequence != expected:
      entry.suspect = true
      reg.entries[peerId] = entry
      return
    if entry.advertised.isNil:
      entry.advertised = newCuckooFilter(DefaultPeerFilterCapacity)
    for d in ad.removed:
      discard entry.advertised.delete(digestBytes(d))
    for d in ad.added:
      discard entry.advertised.insert(digestBytes(d))
    entry.lastAdvertiseSequence = ad.sequence
    entry.hasAdvertiseSequence = true
  reg.entries[peerId] = entry

proc needsSnapshot*(reg: PeerRegistry; peerId: PeerId): bool =
  ## Returns `true` if the registry believes this peer's advertised
  ## set is stale because of a detected sequence-number gap.
  if not reg.entries.hasKey(peerId):
    return false
  reg.entries[peerId].suspect

proc findPeersWithBlob*(reg: PeerRegistry; digest: BlobDigest): seq[PeerId] =
  ## Returns every known peer whose cuckoo filter answers `query` true
  ## for `digest`. Order is lexicographic-by-peerId-bytes — stable
  ## across runs so callers (and tests) can rely on deterministic
  ## candidate ordering.
  ##
  ## Peer-Cache-Scale M1: the result is probabilistic. False positives
  ## are bounded by the per-peer filter FPR (default 1%); false
  ## negatives are impossible. The fetch path is expected to handle a
  ## false-positive "this peer doesn't actually have the blob"
  ## response gracefully — see `client.nim` §"`fetchBlob`".
  result = @[]
  let raw = digestBytes(digest)
  for peerId, entry in reg.entries.pairs:
    if entry.suspect:
      continue
    if entry.advertised.isNil:
      continue
    if entry.advertised.query(raw):
      result.add(peerId)
  result.sort do (a, b: PeerId) -> int:
    let
      aa = bytes(a)
      bb = bytes(b)
    var i = 0
    while i < aa.len:
      if aa[i] < bb[i]: return -1
      if aa[i] > bb[i]: return 1
      inc i
    0

proc markSuspect*(reg: PeerRegistry; peerId: PeerId) =
  ## Flags the peer as suspect (corrupt response, protocol violation).
  ## Suspect peers are skipped by `findPeersWithBlob` until they
  ## return clean.
  if reg.entries.hasKey(peerId):
    var entry = reg.entries[peerId]
    entry.suspect = true
    reg.entries[peerId] = entry

proc clearSuspect*(reg: PeerRegistry; peerId: PeerId) =
  if reg.entries.hasKey(peerId):
    var entry = reg.entries[peerId]
    entry.suspect = false
    reg.entries[peerId] = entry

proc updateLastSeen*(reg: PeerRegistry; peerId: PeerId) =
  if reg.entries.hasKey(peerId):
    var entry = reg.entries[peerId]
    entry.lastSeen = getMonoTime()
    reg.entries[peerId] = entry

proc endpointOf*(reg: PeerRegistry; peerId: PeerId): Endpoint =
  reg.entries[peerId].endpoint

proc peerCount*(reg: PeerRegistry): int =
  reg.entries.len

# ---------------------------------------------------------------------------
# Self advertisement.
# ---------------------------------------------------------------------------

proc setSelfAdvertised*(reg: PeerRegistry; digests: openArray[BlobDigest]) =
  ## Replaces this node's own advertised set. Used by clients/servers
  ## that maintain a local content inventory; M0 ships a stub usage
  ## (empty set) since the local-store wiring lands in M1.
  reg.selfAdvertised.clear()
  for d in digests:
    reg.selfAdvertised.incl(d)
  inc reg.selfSequence

proc selfAddBlob*(reg: PeerRegistry; digest: BlobDigest) =
  reg.selfAdvertised.incl(digest)
  inc reg.selfSequence

proc selfRemoveBlob*(reg: PeerRegistry; digest: BlobDigest) =
  reg.selfAdvertised.excl(digest)
  inc reg.selfSequence

proc snapshotFor*(reg: PeerRegistry; peerId: PeerId): Advertise =
  ## Builds an `Advertise{ mode: amSnapshot }` carrying this node's
  ## current self-advertised set, addressed at `peerId`. The peer ID
  ## isn't carried on the wire (it's implicit in the connection's
  ## handshake), but we accept it here so the snapshot generator can
  ## be specialised per-peer in M2 (e.g., to filter blobs the peer
  ## has already advertised back to us).
  discard peerId  # unused in M0
  result = Advertise(
    sequence: reg.selfSequence,
    mode: amSnapshot,
    added: newSeq[BlobDigest](reg.selfAdvertised.len),
    removed: @[])
  var i = 0
  for d in reg.selfAdvertised:
    result.added[i] = d
    inc i

proc snapshotV2For*(reg: PeerRegistry; peerId: PeerId;
                    capacity: uint32 = DefaultPeerFilterCapacity): AdvertiseV2 =
  ## Peer-Cache-Scale M1: builds an `AdvertiseV2{ mode: amSnapshot }`
  ## carrying this node's self-advertised set serialised as a cuckoo
  ## filter. Used by v2 senders; v1 callers continue to use
  ## `snapshotFor` until the unicast paths are upgraded in a
  ## follow-up.
  discard peerId
  let cap =
    if capacity < uint32(reg.selfAdvertised.len): uint32(reg.selfAdvertised.len)
    else: capacity
  let cf = newCuckooFilter(max(cap, 1'u32))
  for d in reg.selfAdvertised:
    discard cf.insert(digestBytes(d))
  result = AdvertiseV2(
    sequence: reg.selfSequence,
    mode: amSnapshot,
    filterCapacity: cap,
    filterCount: cf.count,
    filterBytes: cf.serialize())
