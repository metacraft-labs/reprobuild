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
    mkSwimProbe = 9            ## Peer-Cache-Scale M0: direct probe.
    mkSwimAck = 10             ## Reply to a direct probe.
    mkSwimProbeReq = 11        ## Indirect-probe request to a peer.
    mkSwimProbeAckIndirect = 12  ## Indirect-probe ack forwarded by intermediary.
    mkSwimSuspect = 13         ## Dissemination: peer X is suspected.
    mkSwimConfirm = 14         ## Dissemination: peer X is confirmed dead.
    mkSwimRefute = 15          ## Refutation with bumped incarnation.
    mkAdvertiseV2 = 16         ## Peer-Cache-Scale M1: cuckoo-filter advertisement.
    mkAuthChallenge = 17       ## Peer-Cache-Scale M3: mTLS handshake — random challenge + own pubkey.
    mkAuthResponse = 18        ## Peer-Cache-Scale M3: mTLS handshake — signature over peer's challenge.

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
    capTier2*: bool
      ## Peer-Cache-Scale M2: tier-2 capability bit. Set when the
      ## sending peer is a long-lived "fat peer" cache node (see
      ## `Peer-Cache-Scale.md` §"Tier-2 cache hierarchy"). Receivers
      ## record the value in `PeerEntry.isTier2` so `requestFetch`
      ## can prefer tier-2 candidates.

  HelloOk* = object
    peerId*: PeerId
    protocolVersion*: uint16
    maxBlobBytes*: uint64
    capTier2*: bool
      ## Peer-Cache-Scale M2: same tier-2 capability bit echoed on the
      ## acceptor side of the handshake.

  Advertise* = object
    sequence*: uint64
    mode*: AdvertiseMode
    added*: seq[BlobDigest]
    removed*: seq[BlobDigest]

  AdvertiseV2* = object
    ## Peer-Cache-Scale M1 cuckoo-filter advertisement. The
    ## `filterBytes` field carries the serialised cuckoo filter from
    ## `cuckoo.nim`; the `filterCapacity` and `filterCount` mirror the
    ## constructor parameter + the current insertion count so that
    ## receivers can validate the filter before deserialising. The
    ## `sequence` and `mode` semantics are unchanged from `Advertise`
    ## v1 (the wire-protocol version bump from 1 to 2 indicates the
    ## payload shape change, not a semantic change).
    ##
    ## Peer-Cache-Scale M3: the optional `signature` field carries a
    ## detached MAC over the canonical advertisement bytes
    ## (`auth.canonicaliseAdvertiseForSigning`). Empty for `tmCidr`
    ## senders; non-empty for `tmMtls` senders. Decoders treat
    ## missing-trailing-bytes as `signature = @[]` so v2 and v2+M3
    ## peers stay codec-compatible.
    sequence*: uint64
    mode*: AdvertiseMode
    filterCapacity*: uint32
    filterCount*: uint32
    filterBytes*: seq[byte]
    signature*: seq[byte]

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
  # Peer-Cache-Scale M0: SWIM membership + failure detection.
  #
  # The record shapes here mirror the SWIM paper (Das et al. 2002), with one
  # adaptation: the peer table tracks an explicit `Endpoint` per member so that
  # piggybacked dissemination teaches receivers about previously-unknown peers'
  # network addresses without a separate "join" round.
  # ---------------------------------------------------------------------------

  SwimMemberStatus* = enum
    smsAlive = 0
    smsSuspected = 1
    smsConfirmed = 2

  SwimMember* = object
    ## Piggybacked dissemination payload — one entry per known peer the
    ## sender wants the receiver to learn about. The `endpoint` field
    ## carries the peer's TCP endpoint so a receiver that does not yet
    ## know about `peerId` can populate its registry.
    peerId*: PeerId
    endpoint*: Endpoint
    status*: SwimMemberStatus
    incarnation*: uint64

  SwimProbe* = object
    sourcePeerId*: PeerId
    sourceEndpoint*: Endpoint
    targetPeerId*: PeerId
    sourceIncarnation*: uint64
    gossip*: seq[SwimMember]

  SwimAck* = object
    responderPeerId*: PeerId
    responderEndpoint*: Endpoint
    responderIncarnation*: uint64
    gossip*: seq[SwimMember]

  SwimProbeReq* = object
    initiatorPeerId*: PeerId
    initiatorEndpoint*: Endpoint
    targetPeerId*: PeerId
    targetEndpoint*: Endpoint
    gossip*: seq[SwimMember]

  SwimProbeAckIndirect* = object
    initiatorPeerId*: PeerId
    targetPeerId*: PeerId
    intermediaryPeerId*: PeerId
    targetIncarnation*: uint64
    gossip*: seq[SwimMember]

  # ---------------------------------------------------------------------------
  # Peer-Cache-Scale M3: mTLS-equivalent in-protocol auth handshake.
  #
  # M3 ships a simplified handshake instead of full X.509 + OpenSSL. After TCP
  # accept/dial, each side sends `mkAuthChallenge` (own pubkey + 32 random
  # bytes), then `mkAuthResponse` (a detached signature over the peer's 32B
  # challenge). Receivers verify against the trust-anchor list before any
  # `mkHello` flow. The MAC-based "signature" primitive is implemented in
  # `auth.nim`; the wire shape is asymmetric-crypto-compatible (a future
  # follow-up can swap in Ed25519 without touching the framing).
  # ---------------------------------------------------------------------------

  AuthChallenge* = object
    challengeBytes*: array[32, byte]
    senderPubKey*: array[32, byte]

  AuthResponse* = object
    challengeBytes*: array[32, byte]
    signature*: array[64, byte]

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
    pdmMulticast,    ## M2 mode — UDP multicast announcements.
    pdmSwim          ## Peer-Cache-Scale M0 — SWIM gossip protocol.

  TrustMode* = enum
    ## Peer-Cache-Scale M3: how the peer authenticates inbound + outbound
    ## peers. `tmCidr` is the M0–M2 default (CIDR allowlist only);
    ## `tmMtls` enables the in-protocol mTLS-equivalent auth handshake
    ## + signed advertisements described in `Peer-Cache-Scale.md`
    ## §"mTLS + signed advertisements".
    tmCidr = 0
    tmMtls = 1

  SwimConfig* = object
    ## Per-peer SWIM tuning. Defaults match the SWIM paper §6.3:
    ## one second protocol period, half-second direct-probe timeout,
    ## three indirect probers, five second suspect timeout, thirty
    ## seconds before a confirmed peer is forgotten. The dissemination
    ## cap and max-forwards mirror Hashicorp's `memberlist`.
    swimProbePeriodMs*: int
    swimProbeTimeoutMs*: int
    swimIndirectProbeCount*: int
    swimSuspectTimeoutMs*: int
    swimConfirmTimeoutMs*: int
    swimGossipMessageCap*: int
    swimGossipMaxForwards*: int

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
    swimConfig*: SwimConfig
      ## Peer-Cache-Scale M0: SWIM tuning carried in the unified config.
      ## Populated by callers (test fixtures + production CLI) when
      ## `discoveryMode == pdmSwim`. Other modes ignore the field.
    trustMode*: TrustMode
      ## Peer-Cache-Scale M3: trust gating. Defaults to `tmCidr` so the
      ## M0–M2 behaviour is preserved when callers don't initialise this
      ## field. `tmMtls` activates the in-protocol auth handshake +
      ## signed advertisement enforcement.
    trustAnchorPath*: string
      ## Peer-Cache-Scale M3: path to the trust-anchor file for
      ## `tmMtls`. The file format is one entry per line:
      ##   `<pubkey_hex_64>:<privkey_hex_64>`
      ## See `auth.loadTrustAnchors` for the canonical parser. Empty
      ## for `tmCidr`.
    peerCertPath*: string
      ## Peer-Cache-Scale M3: path to this peer's own public-key file.
      ## Hex-encoded 32 bytes per line (typically one line). Created on
      ## first start when missing.
    peerKeyPath*: string
      ## Peer-Cache-Scale M3: path to this peer's own private-key file.
      ## Hex-encoded 32 bytes per line (typically one line). Created on
      ## first start when missing.
    poolMaxPerPeer*: int
      ## Peer-Cache-Scale M4: maximum number of pooled outbound
      ## connections per remote peer. Default 4 when zero. Used by the
      ## `PeerConnPool` in `client.nim`. See `Peer-Cache-Scale.md`
      ## §"Connection lifecycle + observability".
    poolIdleTimeoutMs*: int
      ## Peer-Cache-Scale M4: idle-eviction window (ms). Pooled
      ## connections older than this with `inUse == false` are closed
      ## by `reapIdle`. Default 30_000 when zero.
    metricsListenAddr*: string
      ## Peer-Cache-Scale M4: bind spec for the Prometheus metrics
      ## scrape endpoint (e.g. `127.0.0.1:9456`). Empty string disables
      ## the metrics HTTP server.

const
  DefaultMulticastAddress* = "224.0.0.123"
    ## Spec default per `Peer-Cache.md` §"Configuration surface".
  DefaultMulticastPort* = 7654'u16
    ## Spec default; the M2 verification tests override this with
    ## `17654` (high port to avoid kernel filtering / system
    ## conflicts) on the admin-scope group `239.255.42.42`.
  DefaultAdvertiseIntervalMs* = 5_000
  DefaultPingIntervalMs* = 15_000

  # SWIM defaults — Peer-Cache-Scale milestone M0.
  DefaultSwimProbePeriodMs* = 1_000
  DefaultSwimProbeTimeoutMs* = 500
  DefaultSwimIndirectProbeCount* = 3
  DefaultSwimSuspectTimeoutMs* = 5_000
  DefaultSwimConfirmTimeoutMs* = 30_000
  DefaultSwimGossipMessageCap* = 32
  DefaultSwimGossipMaxForwards* = 6
    ## ≈ `3 * log2(N)` for `N` up to a few hundred; the engine recomputes a
    ## membership-size-aware cap at runtime in `nextGossipBatch` but this
    ## static default suffices when the configured value is left at zero.

  # Peer-Cache-Scale M4 connection-pool + metrics defaults.
  DefaultPoolMaxPerPeer* = 4
    ## Default cap on simultaneous pooled connections per remote peer.
  DefaultPoolIdleTimeoutMs* = 30_000
    ## Default idle-eviction window for `PeerConnPool.reapIdle`.

proc defaultSwimConfig*(): SwimConfig =
  ## Spec defaults for SWIM. Tests typically clone this and tighten the
  ## period (e.g. 100 ms) to bound wall-clock time.
  SwimConfig(
    swimProbePeriodMs: DefaultSwimProbePeriodMs,
    swimProbeTimeoutMs: DefaultSwimProbeTimeoutMs,
    swimIndirectProbeCount: DefaultSwimIndirectProbeCount,
    swimSuspectTimeoutMs: DefaultSwimSuspectTimeoutMs,
    swimConfirmTimeoutMs: DefaultSwimConfirmTimeoutMs,
    swimGossipMessageCap: DefaultSwimGossipMessageCap,
    swimGossipMaxForwards: DefaultSwimGossipMaxForwards)

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
