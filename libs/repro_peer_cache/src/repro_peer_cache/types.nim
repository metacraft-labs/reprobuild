## Peer-cache value types — Peer-Cache M0.
##
## Implements the SSZ-shaped records described in
## `reprobuild-specs/Peer-Cache.md` §"Wire shape". Variable-length
## sequences (`Advertise.added` / `Advertise.removed`,
## `Want.digests`, `FetchResponse.payload`) carry an explicit
## length prefix in the codec; everything else is a fixed-shape
## record.
##
## The `BlobDigest` type here is a 32-byte raw BLAKE3-256 digest.
## `repro_local_store` exposes a richer `ContentDigest`
## (`algorithm + domain + bytes`) for its on-disk store; the
## peer-cache wire intentionally carries only the raw 32 bytes
## since the protocol is BLAKE3-only by spec
## (`Peer-Cache.md` §"Identity model") and the algorithm tag
## would be wasted bandwidth on every advertise.

import std/[hashes, nativesockets, net, options]

export nativesockets.Port
export net.IpAddress
export net.IpAddressFamily
export net.parseIpAddress
export options

type
  PeerId* = distinct array[32, byte]
    ## 32-byte random peer identifier. Stable across restarts when the
    ## state survives; regenerated on first run otherwise. See
    ## `Peer-Cache.md` §"Discovery model".

  BlobDigest* = distinct array[32, byte]
    ## 32-byte BLAKE3-256 content digest, matching the identity model
    ## in `Caching-Architecture.md`. The peer cache uses the same
    ## digest as its blob identity.

  Endpoint* = object
    host*: string
    port*: Port

  MessageKind* = enum
    mkHello = 0
    mkHelloOk = 1
    mkAdvertise = 2
    mkWant = 3
    mkFetchRequest = 4
    mkFetchResponse = 5
    mkPing = 6
    mkPong = 7
    mkGoodbye = 8

  AdvertiseMode* = enum
    amSnapshot = 0
    amDelta = 1

  WantKind* = enum
    wkBlobs = 0
    wkSnapshotRequest = 1

  Hello* = object
    peerId*: PeerId
    listenPort*: uint16
    capabilities*: uint32

  HelloOk* = object
    peerId*: PeerId
    protocolVersion*: uint16
    maxBlobBytes*: uint64

  Advertise* = object
    sequence*: uint64
    mode*: AdvertiseMode
    added*: seq[BlobDigest]
    removed*: seq[BlobDigest]

  Want* = object
    kind*: WantKind
    digests*: seq[BlobDigest]

  FetchRequest* = object
    digest*: BlobDigest

  FetchResponse* = object
    digest*: BlobDigest
    truncated*: bool
    payload*: seq[byte]

  Ping* = object
  Pong* = object
  Goodbye* = object

# ---------------------------------------------------------------------------
# Equality + hashing for the distinct array types. The compiler does not
# auto-derive `==` / `hash` across `distinct` boundaries, so we expose
# them explicitly — the registry uses `PeerId` as a Table key and
# `BlobDigest` as a HashSet element.
# ---------------------------------------------------------------------------

proc `==`*(a, b: PeerId): bool {.borrow.}
proc `==`*(a, b: BlobDigest): bool {.borrow.}

proc hash*(value: PeerId): Hash =
  hash(array[32, byte](value))

proc hash*(value: BlobDigest): Hash =
  hash(array[32, byte](value))

proc bytes*(value: PeerId): array[32, byte] =
  array[32, byte](value)

proc bytes*(value: BlobDigest): array[32, byte] =
  array[32, byte](value)

proc peerIdFromBytes*(buf: array[32, byte]): PeerId =
  PeerId(buf)

proc blobDigestFromBytes*(buf: array[32, byte]): BlobDigest =
  BlobDigest(buf)

proc `$`*(value: PeerId): string =
  const HexChars = "0123456789abcdef"
  let raw = array[32, byte](value)
  result = newString(64)
  for i, b in raw:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc `$`*(value: BlobDigest): string =
  const HexChars = "0123456789abcdef"
  let raw = array[32, byte](value)
  result = newString(64)
  for i, b in raw:
    result[2 * i] = HexChars[(int(b) shr 4) and 0xf]
    result[2 * i + 1] = HexChars[int(b) and 0xf]

proc `==`*(a, b: Endpoint): bool =
  a.host == b.host and a.port == b.port

proc initEndpoint*(host: string; port: Port): Endpoint =
  Endpoint(host: host, port: port)

# ---------------------------------------------------------------------------
# Local store injection seams (Peer-Cache M1).
#
# `LocalStoreReader` / `LocalStoreWriter` are intentionally small typed
# procs so the peer-cache library doesn't take a hard dependency on
# `repro_local_store`. The caller wires the actual store implementation
# via closures: production code threads `LocalCas.readBlob` /
# `LocalCas.storeBlob`; tests wrap an in-memory `Table[BlobDigest,
# seq[byte]]`. See `Peer-Cache.milestones.org` §M1.
# ---------------------------------------------------------------------------

type
  LocalStoreReader* = proc(digest: BlobDigest): Option[seq[byte]]
    {.gcsafe, closure.}
    ## Returns `some(bytes)` if the local store has a blob at
    ## `digest`, `none` otherwise. The bytes are returned by value so
    ## the codec can frame them without sharing ownership with the
    ## caller's storage. The reader MUST NOT raise — store-layer
    ## errors should surface as `none` plus an out-of-band log.

  LocalStoreWriter* = proc(digest: BlobDigest; payload: seq[byte])
    {.gcsafe, closure.}
    ## Writes a verified payload to the local store under `digest`.
    ## Called by the client after a successful `mkFetchResponse`
    ## BLAKE3-256 verification. The writer is idempotent — repeated
    ## writes for the same digest are a no-op.

  ResponseInterceptor* = proc(payload: seq[byte]): seq[byte]
    {.gcsafe, closure.}
    ## Server-side seam injected by tests. Called on the
    ## `mkFetchResponse` payload just before the codec encodes it.
    ## Production code leaves this `nil` (identity). The corrupted-
    ## payload verification test (`Peer-Cache.milestones.org` §M1)
    ## wires this to flip a byte.

# ---------------------------------------------------------------------------
# Peer-cache discovery configuration (Peer-Cache M2).
#
# `PeerCacheConfig` is the unified configuration record that the CLI
# parser produces and that callers thread through to
# `newPeerCacheServer` / `newPeerCacheClient`. It captures both the M0
# unicast-seed-list discovery shape and the M2 UDP multicast discovery
# shape so the surface stays one-step-from-the-CLI even as new
# discovery modes land.
# ---------------------------------------------------------------------------

type
  MulticastGroup* = object
    ## A UDP multicast group + the local interface to join it on. For
    ## loopback tests, `interfaceIp` is `127.0.0.1`; for LAN
    ## deployments it is typically `0.0.0.0` (INADDR_ANY) so the
    ## kernel picks any multicast-capable interface.
    address*: IpAddress
    port*: Port
    interfaceIp*: IpAddress

  PeerCacheDiscoveryMode* = enum
    pdmUnicastSeed,  ## M0 mode — explicit seed peer list.
    pdmMulticast     ## M2 mode — UDP multicast announcements.

  PeerCacheConfig* = object
    ## Unified peer-cache configuration. The CLI parser produces one of
    ## these; callers populate the `cidrAllowlist` and either the
    ## `seedPeers` (for `pdmUnicastSeed`) or the `multicastGroup` (for
    ## `pdmMulticast`).
    discoveryMode*: PeerCacheDiscoveryMode
    seedPeers*: seq[Endpoint]
    multicastGroup*: MulticastGroup
    cidrAllowlistRaw*: seq[string]
      ## CIDR strings as parsed from the CLI (e.g. `127.0.0.0/8`). The
      ## server / client construct typed `CidrV4` values at start time
      ## via `server.parseCidrV4`. The raw form is retained so the
      ## CLI report can echo back the original spec without
      ## re-decoding.
    advertiseIntervalMs*: int
    pingIntervalMs*: int
    maxBlobBytes*: uint64

const
  DefaultMulticastAddress* = "224.0.0.123"
    ## Spec default per `Peer-Cache.md` §"Configuration surface".
  DefaultMulticastPort* = 7654'u16
    ## Spec default; the M2 verification tests override this with
    ## `17654` (high port to avoid kernel filtering / system
    ## conflicts) on the admin-scope group `239.255.42.42`.
  DefaultAdvertiseIntervalMs* = 5_000
  DefaultPingIntervalMs* = 15_000

proc defaultMulticastGroup*(): MulticastGroup =
  ## Spec-default multicast group bound to INADDR_ANY (0.0.0.0).
  MulticastGroup(
    address: parseIpAddress(DefaultMulticastAddress),
    port: Port(DefaultMulticastPort),
    interfaceIp: parseIpAddress("0.0.0.0"))

proc loopbackMulticastGroup*(address: string;
                             port: Port): MulticastGroup =
  ## Convenience constructor used by the loopback multicast test
  ## helper. Binds the multicast socket to `127.0.0.1` so the kernel
  ## restricts the multicast traffic to the loopback interface — the
  ## M2 verification tests rely on this to avoid leaking announcements
  ## onto the real LAN.
  MulticastGroup(
    address: parseIpAddress(address),
    port: port,
    interfaceIp: parseIpAddress("127.0.0.1"))
