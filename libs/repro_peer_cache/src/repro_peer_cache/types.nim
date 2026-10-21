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
    # Peer-Cache-BearSSL M3: the M3-era `tmMtls` synthetic handshake
    # message kinds (`mkAuthChallenge` / `mkAuthResponse`, tags 17 / 18)
    # were deleted in this milestone alongside the rest of the
    # stand-in. `tmTls` runs a real BearSSL TLS 1.2 mutual-auth
    # handshake under the framing layer; no in-protocol auth frames are
    # carried any more.
    #
    #
    # Distributed-Execution M0: the two-phase MEMOIZATION messages
    # (BuildXL `Public/Src/Cache/README.md`: WeakFingerprint -> Selector
    # -> StrongFingerprint -> ContentHashList). The tags reuse 17..20 so
    # the enum stays contiguous (`decodeFrame` range-checks the raw tag
    # against `high(MessageKind)`; a holey enum would let 17/18 decode to
    # an invalid value). The deleted auth frames existed only under the
    # removed `tmMtls` trust mode, which no current peer negotiates.
    mkGetSelectorsRequest = 17     ## "Which (PathSet, StrongFingerprint)
                                   ## selectors do you hold for this
                                   ## WeakFingerprint?"
    mkGetSelectorsResponse = 18    ## Selector list (possibly empty).
    mkGetActionRecordRequest = 19  ## "Send the memo entry for this
                                   ## (WeakFingerprint, StrongFingerprint)."
    mkGetActionRecordResponse = 20 ## Memo entry bytes, or `found = false`.
    # Distributed-Execution M7: the Boundary vocabulary
    # (`boundary.nim`, `spec/Distributed-Execution.md` §"Worker Boundary
    # Vocabulary"). Contiguous with the memo tags for the same reason.
    mkIdentityProof = 21           ## The sender's short-lived leaf
                                   ## certificate DER (`identity.nim`).
    mkRefused = 22                 ## Receiver -> sender: a frame was refused
                                   ## (refusal class + reason).
    mkReachGoalRequest = 23        ## Orchestrator -> worker: reach a node of
                                   ## a hydrated graph descriptor.
    mkReachGoalResponse = 24       ## Worker -> orchestrator: the outcome.
    mkAttach = 25                  ## Reserved (M4): BuildXL Attach.
    mkGraphDescriptorFetch = 26    ## Reserved (M4).
    mkExecutePips = 27             ## Reserved (M4).
    mkNotifyPipResults = 28        ## Reserved (M4).
    mkShardDispatch = 29           ## Reserved (M3).

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
    ## Peer-Cache-BearSSL M1: the optional `signature` field carries a
    ## detached 64-byte ECDSA-P256 signature over the canonical
    ## advertisement bytes (`auth.canonicaliseAdvertiseForSigning`).
    ## Empty for `tmCidr` senders; non-empty for `tmTls` senders.
    ## Decoders treat missing-trailing-bytes as `signature = @[]` so
    ## v2 frames from earlier milestones stay codec-compatible.
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

  # ---------------------------------------------------------------------------
  # Distributed-Execution M0: two-phase memoization records.
  #
  # The peer cache has two planes and they are deliberately kept apart:
  #
  #   * the CONTENT plane — `mkFetchRequest` / `mkFetchResponse` — is
  #     strictly content-addressed: the requester names `BLAKE3-256(payload)`
  #     and rejects (and marks the peer suspect on) any payload that does not
  #     hash to it. Output blobs and PathSet blobs travel here.
  #   * the MEMOIZATION plane — the four messages below — answers "which
  #     executions of this action do you know about?". Its keys are NOT
  #     content digests of the reply (a selector list or a memo entry is
  #     looked up by fingerprint), so these replies are never checked with
  #     the content rule and can never trip it. Overloading the content
  #     plane with a fingerprint key is precisely what made every bundle
  #     fetch fail verification and mark an honest peer suspect.
  #
  # Lookup follows BuildXL's two-phase cache lookup
  # (`Documentation/Wiki/Advanced-Features/Two-Phase-Cache-Lookup.md`):
  # WeakFingerprint -> selectors {PathSet digest, StrongFingerprint} ->
  # memo entry (the action result record) -> output blobs by digest.
  # ---------------------------------------------------------------------------

  MemoSelector* = object
    ## One candidate execution of an action: the content digest of the
    ## PathSet it observed (fetchable over the content plane) and the
    ## StrongFingerprint `H(WeakFingerprint || PathSetDigest ||
    ## ObservedInputDigests)` that execution produced.
    pathSetDigest*: BlobDigest
    strongFingerprint*: BlobDigest

  GetSelectorsRequest* = object
    weakFingerprint*: BlobDigest

  GetSelectorsResponse* = object
    weakFingerprint*: BlobDigest
      ## Echoes the request so the requester can correlate the reply.
    selectors*: seq[MemoSelector]

  GetActionRecordRequest* = object
    weakFingerprint*: BlobDigest
    strongFingerprint*: BlobDigest

  GetActionRecordResponse* = object
    weakFingerprint*: BlobDigest
    strongFingerprint*: BlobDigest
    found*: bool
    entry*: seq[byte]
      ## The encoded memo entry (`memo_store.encodeMemoEntry`); empty when
      ## `found` is false. The requester re-derives the entry's identity
      ## (weak, PathSet digest, strong) from the decoded bytes and drops a
      ## reply that does not describe what it asked for.

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

  # Peer-Cache-BearSSL M3: the M3-era `AuthChallenge` / `AuthResponse`
  # records (synthetic-handshake stand-ins for real mTLS) were deleted in
  # this milestone. `tmTls` wraps the TCP socket with a BearSSL TLS 1.2
  # mutual-auth context (see `tls.nim`); peer identity is bound to the
  # X.509 SubjectPublicKeyInfo presented during the TLS handshake, not
  # to in-protocol auth frames.

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

  MemoSelectorReader* = proc(weakFingerprint: BlobDigest): seq[MemoSelector]
    {.gcsafe, closure.}
    ## Distributed-Execution M0: server-side seam answering
    ## `mkGetSelectorsRequest`. Returns every selector the local memo
    ## store holds for `weakFingerprint` (empty on miss). MUST NOT raise;
    ## store errors surface as an empty list.

  MemoEntryReader* = proc(weakFingerprint, strongFingerprint: BlobDigest):
    Option[seq[byte]] {.gcsafe, closure.}
    ## Distributed-Execution M0: server-side seam answering
    ## `mkGetActionRecordRequest` with the encoded memo entry for one
    ## selector, or `none`. MUST NOT raise.

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
    ## Peer-Cache-BearSSL M3: how the peer authenticates inbound +
    ## outbound peers.
    ##
    ## `tmCidr` drops the trust check to the CIDR allowlist. Since
    ## Distributed-Execution M7 (deviation D3 closed) it is an IN-PROCESS
    ## HARNESS mode only: no shipped entry point constructs it — the CLI
    ## and daemon wiring (`peer_cache_wiring.validateListenerPolicy`) and
    ## the tier-2 daemon refuse it — and `server.start` refuses it on any
    ## address but loopback. A source address is not an identity: even on
    ## loopback it admits every local user, not the node's owner.
    ##
    ## `tmTls` wraps every accept/dial with a BearSSL TLS 1.2 mutual-
    ## auth context (see `tls.nim`) backed by the M2 self-signed
    ## ECDSA-P256 cert primitives in `pki.nim`. The trust anchor is a
    ## directory of allowed-peer certificates; both sides of the
    ## handshake validate the remote leaf against that directory before
    ## any `mkHello` frame crosses the tunnel.
    ##
    ## The M3-era `tmMtls` variant (a synthetic in-protocol auth-
    ## handshake stand-in) was deleted in this milestone alongside the
    ## stand-in primitives — see `Peer-Cache-BearSSL.milestones.org`
    ## §M3 "Hard cutover".
    tmCidr = 0
    tmTls  = 1

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

  TrustProfile* = enum
    ## Distributed-Execution M7, trust profiles (operator decision
    ## 2026-10-20; `spec/Distributed-Execution-Threat-Model.md` §3a).
    ## `tpTrusted` is the DEFAULT (the first value, so a zero-initialized
    ## config is trusted): a single-owner fleet where every enrolled host
    ## and requester is trusted, the sandbox serves correctness, identities
    ## are pinned long-lived host keys, and detections go to the
    ## content-addressed execution record and the local log. `tpHardened`
    ## is opt-in (`lan://…?profile=hardened`, `--trust-profile=hardened`):
    ## one-hour host-CA leaves, the off-host evidence sink, the off-worker
    ## certificate signer, and no macOS or Windows worker until a VM-grade
    ## boundary exists for them.
    tpTrusted = "trusted"
    tpHardened = "hardened"

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
      ## Peer-Cache-BearSSL M3: trust gating. Defaults to `tmCidr` so
      ## the M0-M2 behaviour is preserved when callers don't initialise
      ## this field. `tmTls` activates the BearSSL TLS 1.2 mutual-auth
      ## wrap (see `tls.nim`).
    tlsCertPath*: string
      ## Peer-Cache-BearSSL M3: path to this peer's own PEM-encoded
      ## X.509 cert. Generated on first start under `tmTls` if missing.
    tlsKeyPath*: string
      ## Peer-Cache-BearSSL M3: path to this peer's own ECDSA-P256
      ## private-key file (M1 `ecdsa-p256:<hex>` format). Generated on
      ## first start under `tmTls` if missing.
    tlsTrustAnchorsPath*: string
      ## Peer-Cache-BearSSL M3: directory of PEM-encoded allowed-peer
      ## certificates. Each `.crt` file in the directory is one trust
      ## anchor; the parsed `TrustAnchorSet` gates inbound + outbound
      ## TLS handshakes.
    tlsCertValidityDays*: int
      ## Peer-Cache-BearSSL M3: validity window stamped on a self-
      ## signed cert generated on first start. Defaults to 365 days
      ## when zero.
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
    listenPort*: uint16
      ## Distributed-Execution M0: TCP port the peer-cache server binds
      ## (`peer_cache.listen_addr`'s port). 0 asks the OS for an ephemeral
      ## port, which is what every transient CLI runtime uses; a daemon a
      ## fleet seeds against wants a stable one.
    multicastDisabled*: bool
      ## Distributed-Execution M0: `true` keeps a `pdmMulticast` node off the
      ## multicast group (no join, no broadcast) so it discovers peers only
      ## through `seedPeers`. Negative-sense so every existing config keeps
      ## multicast on. Set by `lan://...?multicast=0`.
      ## Distributed-Execution M7: `parsePeerCache` now sets it for every
      ## `lan://` spec unless `multicast=1` is given — discovery broadcasts
      ## on a shared LAN are opt-in, and discovery is never authorization.
    bindSpec*: string
      ## Distributed-Execution M7 (FLOW-6): the interface name or address
      ## the listener binds (`lan://...?bind=wt0`). Empty = loopback only.
      ## Wildcards are refused (`netif.resolveBindSpec`).
    trustProfile*: TrustProfile
      ## Distributed-Execution M7: `trusted` (default) or `hardened`
      ## (`lan://…?profile=`; `--trust-profile=`). See `TrustProfile`.
    evidenceSinkSpec*: string
      ## Distributed-Execution M7 (FLOW-2, DET-6): `host:port` of the
      ## off-host evidence sink every audit record and detection is sent
      ## to (`lan://...?evidence=host:port`). Required for any listener
      ## that is not loopback-only.
    grantsPath*: string
      ## Distributed-Execution M7 (FLOW-4): per-host role grants
      ## (`boundary.loadGrantsFile`). Empty = the TLS directory's `grants`
      ## file when present, else every authenticated host is a cache peer.
    heartbeatIntervalMs*: int
      ## Distributed-Execution M7 (DET-5): detector heartbeat interval.
      ## 0 = 60 s.
    workerEnabled*: bool
      ## Distributed-Execution M7: this node holds the worker role and
      ## answers `mkReachGoalRequest` (`lan://...?worker=1`).
    workerReposPath*: string
      ## Distributed-Execution M7: a file of `<repoId> <local repository
      ## cache path>` lines naming the base-commit caches the worker
      ## materializes snapshots from (`repos=<path>`).
    workerEgress*: seq[string]
      ## Distributed-Execution M7 (FLOW-3): the execution-lease egress
      ## allow-list, `name@ipv4:port` each (`egress=a@1.2.3.4:80,...`).
      ## Nothing else — not even this node's own listener (threat model
      ## G26: a lease holds no credential to talk to it, so reaching it was
      ## only attack surface). A lease that needs a peer cache is given one
      ## here (`egress=peer-cache@<cache node>:<port>`).
    signerSpec*: string
      ## Distributed-Execution M7 (EDGE-5, threat model D5): `host:port` of
      ## the certificate signer (`lan://...?signer=host:port`). A worker
      ## holds no signing credential; it asks the signer, which holds the
      ## per-worker signing CA, once per certificate. Without it the worker
      ## issues no certificates.
    evidenceQueueMax*: int
      ## Records the evidence appender queues while the sink is slow or
      ## unreachable (`evidence-queue=N`); 0 = the default (100 000).
    leaseMemoryMax*: int64
      ## Bytes of memory one execution lease may use when the worker can
      ## place leases in their own cgroup (`lease-memory=N`); 0 = the
      ## default (threat model G31).

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
