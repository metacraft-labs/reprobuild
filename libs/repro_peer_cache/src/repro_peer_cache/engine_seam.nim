## Engine integration seam — Peer-Cache M1.
##
## The engine's action-cache reader path is the consumer of the
## peer-cache plane: on a local-store miss, the reader consults the
## peer cache before falling through to a rebuild or to the central
## remote cache. This module ships a thin wrapper that captures the
## three pieces the reader needs:
##
##   - `localRead`  — closure over the local store's blob lookup
##                    (typically `proc(d: BlobDigest): Option[seq[byte]] =
##                    cas.readBlob(blobRef(asContentDigest(d), size))`),
##   - `localWrite` — closure that writes a verified payload to the
##                    local store (typically `cas.storeBlob`),
##   - `peerCacheClient` — optional `PeerCacheClient` for the LAN-peer
##                    fetch round; `nil` keeps the reader pure-local.
##
## The reader is intentionally synchronous (`waitFor` at the seam) so
## the engine's existing sync call sites can adopt the peer cache
## without ripping their async-ness open in M1. M2/M3 may move the
## engine cache reader async; that's tracked separately.
##
## The wrapper carries a `peerHits` counter so verification tests can
## assert that a follow-up read for the same digest is satisfied
## locally (no second peer round trip).

import std/[asyncdispatch, options]

import ./client
import ./types

type
  PeerCacheActionCacheReader* = ref object
    ## Synchronous action-cache reader with optional peer-cache
    ## fallback. Production code instantiates this once per engine
    ## session and threads it into the action-cache lookup paths.
    localRead*: LocalStoreReader
    localWrite*: LocalStoreWriter
    peerCacheClient*: PeerCacheClient
      ## Optional. When `nil`, the reader behaves identically to a
      ## bare local-store lookup.
    peerHits*: int
      ## Number of times the reader satisfied a request via the peer
      ## cache (i.e. fell through to `requestFetch` and got
      ## `some(payload)`). Tests assert this is 1 after two reads of
      ## the same digest (second read hits the now-warm local store).
    peerMisses*: int
      ## Number of times the reader fell through to the peer cache
      ## and got `none` (peer cache miss; caller falls through to
      ## rebuild or central remote cache).
    localHits*: int
      ## Number of times the reader was satisfied directly by the
      ## local store. After a peer-cache hit + the writer firing,
      ## a follow-up read should bump this counter.

proc newPeerCacheActionCacheReader*(
    localRead: LocalStoreReader;
    localWrite: LocalStoreWriter;
    peerCacheClient: PeerCacheClient = nil): PeerCacheActionCacheReader =
  ## Constructs an action-cache reader. `localRead` and `localWrite`
  ## are required; `peerCacheClient` is optional. The reader does NOT
  ## own the client's lifecycle — the caller starts and stops it.
  PeerCacheActionCacheReader(
    localRead: localRead,
    localWrite: localWrite,
    peerCacheClient: peerCacheClient,
    peerHits: 0,
    peerMisses: 0,
    localHits: 0)

proc readActionOutput*(reader: PeerCacheActionCacheReader;
                       digest: BlobDigest): Option[seq[byte]] =
  ## Reads the blob at `digest`. Lookup order:
  ##   1. Local store via `localRead`. Hit → bump `localHits`,
  ##      return `some(bytes)`.
  ##   2. Peer cache via `peerCacheClient.requestFetch` (if a client
  ##      is wired). Hit → `requestFetch` has already written to the
  ##      local store via the client's injected `localStoreWriter`;
  ##      bump `peerHits`, return `some(bytes)`.
  ##   3. Miss → bump `peerMisses`, return `none`.
  ##
  ## The peer-cache call uses `waitFor` to bridge async → sync at the
  ## engine seam; future async-friendly engine paths can call
  ## `peerCacheClient.requestFetch` directly and skip this wrapper.
  let local = reader.localRead(digest)
  if local.isSome:
    inc reader.localHits
    return local
  if reader.peerCacheClient.isNil:
    inc reader.peerMisses
    return none(seq[byte])
  let peer = waitFor reader.peerCacheClient.requestFetch(digest)
  if peer.isSome:
    # `requestFetch` already wrote to the local store via its own
    # writer closure; we don't double-write here. The next call to
    # `readActionOutput` for the same digest will hit step 1.
    inc reader.peerHits
    return peer
  inc reader.peerMisses
  return none(seq[byte])
