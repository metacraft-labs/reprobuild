## Peer-Cache-Scale M2 tier-2 daemon support.
##
## A `Tier2Cache` bundles the disk-backed store, the upstream
## central-cache client closure, the metrics counters, and the wired
## peer-cache server. The daemon binary
## (`apps/repro-peer-cache-tier2/`) thinly wraps construction +
## start/stop; tests use this module directly to drive the
## upstream-fallthrough and inter-rack-advertisement scenarios.
##
## On `mkFetchRequest`:
## - Check local disk store. If hit, return the blob and increment
##   `localHits`.
## - If miss and `upstreamCache` is non-nil, call it. On returned
##   `some(bytes)`, store locally, advertise via the registry's
##   self-set, increment `upstreamHits`, return the blob.
## - Otherwise reply with `truncated:true, payload:@[]`.

import std/[options]

import ./disk_store
import ./registry
import ./types

type
  UpstreamCacheClient* = proc(digest: BlobDigest): Option[seq[byte]]
    {.gcsafe, closure.}
    ## Test seam (and future M3+ integration point) for fetching a
    ## blob from the central remote cache plane
    ## (`Binary-Caches.md`). Returns `some(bytes)` on hit, `none`
    ## on miss. The proc must not raise — errors should surface
    ## as `none` plus out-of-band logging.

  Tier2Cache* = ref object
    diskStore*: DiskStore
    registry*: PeerRegistry
    upstreamCache*: UpstreamCacheClient
    localHits*: uint64
    upstreamHits*: uint64
    upstreamMisses*: uint64

proc newTier2Cache*(diskStore: DiskStore;
                    registry: PeerRegistry;
                    upstreamCache: UpstreamCacheClient = nil): Tier2Cache =
  result = Tier2Cache(
    diskStore: diskStore,
    registry: registry,
    upstreamCache: upstreamCache,
    localHits: 0'u64,
    upstreamHits: 0'u64,
    upstreamMisses: 0'u64)
  # Seed the registry's self-advertised set with everything currently
  # on disk so an immediate `snapshotFor` carries the warm store.
  for digest in diskStore.enumerateDigests():
    registry.selfAddBlob(digest)

proc currentStoreBytes*(tier: Tier2Cache): uint64 = tier.diskStore.currentBytes
proc evictionCount*(tier: Tier2Cache): uint64 = tier.diskStore.evictionCount

proc lookup*(tier: Tier2Cache; digest: BlobDigest): Option[seq[byte]] =
  ## Main fetch path. Returns the blob bytes if found locally or
  ## fetched from upstream, or `none` if both miss. Counters are
  ## updated as a side effect.
  let local = tier.diskStore.load(digest)
  if local.isSome:
    inc tier.localHits
    return local
  if tier.upstreamCache.isNil:
    return none(seq[byte])
  let upstream = tier.upstreamCache(digest)
  if upstream.isNone:
    inc tier.upstreamMisses
    return none(seq[byte])
  let bytes = upstream.get()
  discard tier.diskStore.store(digest, bytes)
  tier.registry.selfAddBlob(digest)
  inc tier.upstreamHits
  some(bytes)

proc makeTier2StoreReader*(tier: Tier2Cache): LocalStoreReader =
  ## Builds a `LocalStoreReader` suitable for wiring into a
  ## `PeerCacheServer`. The reader routes through `lookup`, so a
  ## fetch request that misses the disk store but hits upstream
  ## still succeeds, with metrics updated.
  result = proc(digest: BlobDigest): Option[seq[byte]] {.gcsafe.} =
    tier.lookup(digest)

proc makeTier2StoreWriter*(tier: Tier2Cache): LocalStoreWriter =
  ## Writer used by a tier-2 daemon's client side (when it itself
  ## fetches a blob from another peer). Writes through to disk and
  ## registers the blob in the self-advertised set.
  result = proc(digest: BlobDigest; payload: seq[byte]) {.gcsafe.} =
    discard tier.diskStore.store(digest, payload)
    tier.registry.selfAddBlob(digest)
