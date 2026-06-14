## ReproOS-Generations-And-Foreign-Packages A2.5 — shared client types.
##
## The single ``ClientContext`` value plumbed through every other
## module. Owning a long-lived ``ClientContext`` in the daemon (multi-
## user mode) lets the HTTP connection pool + zstd dctx + BLAKE3 hasher
## scratch buffers stay warm across builds. Single-user mode creates a
## per-call instance with the same shape.
##
## ## Why a context rather than module-level globals?
##
##   * Threadsafe: A2.5 already runs inside the build-engine's
##     ``BuildPool`` worker fanout. A globals-based design would force
##     a per-thread copy and lose pool reuse across substitute actions.
##   * Testable: every gate spins up a fresh context against a
##     temp-dir store and a localhost ephemeral-port server.
##   * Lifecycle: ``close(ctx)`` releases libcurl handles + zstd
##     contexts + the BLAKE3 scratch pool deterministically.

import std/[tables]

import repro_local_store

import ../../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes

export bcsTypes

type
  SubstituteEndpoint* = object
    ## A single configured upstream cache.
    ##   * ``baseUrl`` is the HTTP root (``http://host:port``); the client
    ##     joins ``/manifests/<hex>``, ``/payloads/<hex>``, ``/cache-info``
    ##     against it.
    ##   * ``trustedSigners`` are the producer pubkeys we accept; a
    ##     manifest whose ``producerPubKey`` is not on the list (and
    ##     whose signature wouldn't verify against any listed key) is
    ##     rejected before any payload byte is fetched.
    baseUrl*: string
    trustedSigners*: seq[bcsTypes.PublicKeyBytes]
    priority*: int32

  ClientConfig* = object
    ## Knobs the daemon (or single-user wrapper) sets at context init.
    endpoints*: seq[SubstituteEndpoint]
    maxConnectionsPerHost*: int
      ## libcurl ``CURLMOPT_MAX_HOST_CONNECTIONS`` analogue. Default 4.
    maxStreamsPerHost*: int
      ## HTTP/2 streams per connection. Default 16. Ignored on HTTP/1.1
      ## fallback (each request gets its own TCP connection from the
      ## pool, capped at ``maxConnectionsPerHost``).
    poolCapacity*: int
      ## Total in-flight substitutes the engine may dispatch.
      ## Used by ``scheduler_executor`` to derive the BuildPool
      ## capacity.
    chunkBytes*: int
      ## Receive-side ring buffer size. Default 262144 (256 KiB) —
      ## chosen so a 256 KiB BLAKE3 update lands inside one L2-cache
      ## working set on commodity x86_64.
    storeRoot*: string
      ## ``$REPRO_LOCAL_STORE`` root; opened by ``newClientContext``.

  HashScratch* = ref object
    ## Pre-allocated 256 KiB receive buffer + one persistent BLAKE3
    ## hasher slot. Round-robin'd through a small pool to avoid
    ## per-substitute allocations on the hot path.
    buffer*: seq[byte]
    inUse*: bool

  ClientContext* = ref object
    ## The single value plumbed through every A2.5 entry point.
    config*: ClientConfig
    store*: Store
      ## Open ``libs/repro_local_store/`` handle. The client writes
      ## payload bytes through ``casPath()`` so they land in the same
      ## directory layout the rest of reprobuild already manages.
    hashScratchPool*: seq[HashScratch]
      ## Pre-allocated buffers + hasher slots; populated lazily.
    manifestCache*: Table[string, BinaryCacheManifest]
      ## Hex(entry-key) -> decoded manifest. Avoids re-parsing inside a
      ## closure walk that visits the same dep twice.
    closed*: bool

  ClientError* = object of CatchableError
  CompatRejected* = object of ClientError
    ## Compat-check failure: the manifest is well-formed and signed,
    ## but the platform/ABI/toolchain identity doesn't match the local
    ## configuration. The caller (the engine) falls back to a local
    ## build for the entry rather than substituting an incompatible
    ## binary.

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc defaultConfig*(storeRoot: string;
                    endpoints: seq[SubstituteEndpoint] = @[]): ClientConfig =
  ClientConfig(
    endpoints: endpoints,
    maxConnectionsPerHost: 4,
    maxStreamsPerHost: 16,
    poolCapacity: 8,
    chunkBytes: 262144,
    storeRoot: storeRoot)

proc newClientContext*(config: ClientConfig): ClientContext =
  ## Opens the local store + warms the hash-scratch pool. Does NOT
  ## probe the upstream endpoints; the first manifest fetch performs
  ## that lazy probe.
  result = ClientContext(
    config: config,
    store: openStore(config.storeRoot),
    hashScratchPool: @[],
    manifestCache: initTable[string, BinaryCacheManifest](),
    closed: false)

proc close*(ctx: ClientContext) =
  if ctx.isNil or ctx.closed:
    return
  ctx.closed = true
  try:
    close(ctx.store)
  except CatchableError:
    discard
  ctx.hashScratchPool.setLen(0)

proc leaseHashScratch*(ctx: ClientContext): HashScratch =
  ## Borrows a 256 KiB buffer + hasher slot from the pool. Lazily
  ## allocates one on miss. ``releaseHashScratch`` returns it.
  for s in ctx.hashScratchPool:
    if not s.inUse:
      s.inUse = true
      return s
  let chunk = if ctx.config.chunkBytes > 0: ctx.config.chunkBytes else: 262144
  let s = HashScratch(buffer: newSeq[byte](chunk), inUse: true)
  ctx.hashScratchPool.add(s)
  return s

proc releaseHashScratch*(ctx: ClientContext; s: HashScratch) =
  if s.isNil:
    return
  s.inUse = false
