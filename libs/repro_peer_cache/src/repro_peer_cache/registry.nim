## In-memory peer registry — Peer-Cache M0.
##
## Maintains `peerId → endpoint + advertised blobs + lastSeen` for
## every peer this node has handshaken with. See
## `Peer-Cache.md` §"Advertisement index".

import std/[algorithm, monotimes, sets, tables]

import ./types

type
  PeerEntry* = object
    endpoint*: Endpoint
    advertised*: HashSet[BlobDigest]
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
  ## `lastSeen` but preserves the advertised set.
  if reg.entries.hasKey(peerId):
    var entry = reg.entries[peerId]
    entry.endpoint = endpoint
    entry.lastSeen = getMonoTime()
    reg.entries[peerId] = entry
  else:
    let now = getMonoTime()
    reg.entries[peerId] = PeerEntry(
      endpoint: endpoint,
      advertised: initHashSet[BlobDigest](),
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

proc applyAdvertise*(reg: PeerRegistry; peerId: PeerId; ad: Advertise) =
  ## Applies a snapshot or delta advertisement from `peerId`. Snapshot
  ## replaces the peer's known set; delta applies `removed` then
  ## `added` (the spec lists the operations as "remove then add" so a
  ## peer rotating a blob — drop old, advertise new in the same
  ## delta — collapses to the post-rotation set). Sequence-gap
  ## detection records the gap on the entry; `needsSnapshot` returns
  ## `true` until a fresh snapshot arrives.
  if not reg.entries.hasKey(peerId):
    # Drop advertisements from peers we haven't handshaken with —
    # the handshake is the authority on whether a peer is in the
    # registry at all.
    return
  var entry = reg.entries[peerId]
  entry.lastSeen = getMonoTime()
  case ad.mode
  of amSnapshot:
    entry.advertised.clear()
    for d in ad.added:
      entry.advertised.incl(d)
    for d in ad.removed:
      entry.advertised.excl(d)
    entry.lastAdvertiseSequence = ad.sequence
    entry.hasAdvertiseSequence = true
    entry.suspect = false
  of amDelta:
    let expected =
      if entry.hasAdvertiseSequence: entry.lastAdvertiseSequence + 1
      else: ad.sequence
    if entry.hasAdvertiseSequence and ad.sequence != expected:
      # Gap detected — keep the current set as-is and flag the entry as
      # needing a snapshot. The receiver issues
      # `mkWant{ kind: wkSnapshotRequest }` on the next round.
      entry.suspect = true
      reg.entries[peerId] = entry
      return
    for d in ad.removed:
      entry.advertised.excl(d)
    for d in ad.added:
      entry.advertised.incl(d)
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
  ## Returns every known peer that has advertised `digest`. Order is
  ## lexicographic-by-peerId-bytes — stable across runs so callers
  ## (and tests) can rely on deterministic candidate ordering. The
  ## spec's "sorted by recency + observed latency" lands in M2; M1
  ## ships the stable lexicographic order as a sensible default that
  ## avoids `std/tables` hash-bucket nondeterminism leaking into test
  ## results.
  result = @[]
  for peerId, entry in reg.entries.pairs:
    if entry.suspect:
      continue
    if digest in entry.advertised:
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
