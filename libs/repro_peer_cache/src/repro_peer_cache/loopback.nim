## Loopback peer-cache spawn helper — Peer-Cache M0.
##
## Spins up N peer instances each bound to `127.0.0.1:<ephemeral>` on
## the same OS, all seeded with each other's endpoints, all using a
## CIDR allowlist of `127.0.0.0/8`. Useful for both the M0
## verification tests and ad-hoc smoke runs.

import std/[asyncdispatch, nativesockets]

import ./client
import ./registry
import ./server
import ./types

type
  LoopbackPeer* = object
    peerId*: PeerId
    server*: PeerCacheServer
    client*: PeerCacheClient
    registry*: PeerRegistry

  LoopbackPeerOptions* = object
    ## Per-peer M1 wiring: optional store reader (consulted by the
    ## peer's *server* when answering `mkFetchRequest`), optional
    ## store writer (called by the peer's *client* after a verified
    ## `mkFetchResponse`), and optional response interceptor (test
    ## seam for the corrupted-payload verification).
    localStoreReader*: LocalStoreReader
    localStoreWriter*: LocalStoreWriter
    responseInterceptor*: ResponseInterceptor
    maxBlobBytes*: uint64
      ## When non-zero, overrides the default `maxBlobBytes` (100 MB).

const LoopbackCidr* = "127.0.0.0/8"

proc makePeerId(index: int): PeerId =
  var raw: array[32, byte]
  # Deterministic-but-distinct: byte 0 marks "loopback test peer",
  # byte 1 carries the index. Production code derives peer IDs from
  # `nimcrypto.sysrand`; the loopback helper deliberately uses a
  # cheap deterministic scheme so failing tests are easy to triage.
  raw[0] = byte(ord('L'))
  raw[1] = byte(index and 0xff)
  raw[2] = byte((index shr 8) and 0xff)
  peerIdFromBytes(raw)

proc spawnLoopbackPeers*(n: int;
                         options: seq[LoopbackPeerOptions] = @[]):
                         seq[LoopbackPeer] =
  ## Spawns `n` peers on `127.0.0.1:0` (ephemeral OS-assigned ports).
  ## Each peer's server is started before the next peer is created so
  ## the ephemeral port is settled before being used as a seed for
  ## the others. After all servers are up, each peer's client is
  ## dialled with the other peers' endpoints as seeds.
  ##
  ## The optional `options` argument, when provided, must have length
  ## `n` and supplies per-peer M1 wiring (store reader / writer,
  ## response interceptor, maxBlobBytes override). When omitted, all
  ## peers run the M0 stub fetch path.
  ##
  ## Returns handles in the order they were created. Use
  ## `shutdownLoopbackPeers` for a graceful close.
  if options.len != 0 and options.len != n:
    raise newException(ValueError,
      "spawnLoopbackPeers: options.len must equal n (got " &
      $options.len & " vs " & $n & ")")
  let allowlist = @[parseCidrV4(LoopbackCidr)]
  result = newSeq[LoopbackPeer](n)
  # Phase 1: build all peers and start their servers so endpoints
  # are known before any client dials.
  for i in 0 ..< n:
    let peerId = makePeerId(i)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(peerId, endpoint)
    var reader: LocalStoreReader = nil
    var interceptor: ResponseInterceptor = nil
    var maxBytes: uint64 = DefaultMaxBlobBytes
    if options.len > 0:
      reader = options[i].localStoreReader
      interceptor = options[i].responseInterceptor
      if options[i].maxBlobBytes != 0:
        maxBytes = options[i].maxBlobBytes
    let server = newPeerCacheServer(
      selfPeerId = peerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = allowlist,
      maxBlobBytes = maxBytes,
      localStoreReader = reader,
      responseInterceptor = interceptor)
    server.start()
    result[i] = LoopbackPeer(
      peerId: peerId,
      server: server,
      client: nil,
      registry: registry)
  # Phase 2: now that every peer has a bound port, construct the
  # seed list for each one (all the others) and create the client.
  for i in 0 ..< n:
    var seeds: seq[Endpoint] = @[]
    for j in 0 ..< n:
      if j == i: continue
      seeds.add(initEndpoint("127.0.0.1", result[j].server.actualPort))
    var writer: LocalStoreWriter = nil
    if options.len > 0:
      writer = options[i].localStoreWriter
    let client = newPeerCacheClient(
      selfPeerId = result[i].peerId,
      listenPort = uint16(result[i].server.actualPort),
      registry = result[i].registry,
      seedPeers = seeds,
      cidrAllowlist = allowlist,
      localStoreWriter = writer)
    result[i].client = client

proc dialAllLoopbackClients*(peers: seq[LoopbackPeer]):
    Future[void] {.async.} =
  ## Dials every peer's client. Separate from `spawnLoopbackPeers` so
  ## tests can inspect the registry state before / after the dial.
  var futures: seq[Future[void]] = @[]
  for peer in peers:
    futures.add(peer.client.start())
  if futures.len > 0:
    await all(futures)

proc shutdownLoopbackPeers*(peers: seq[LoopbackPeer]) {.async.} =
  ## Gracefully closes each peer's client (sends Goodbye, closes
  ## sockets) and stops each server.
  for peer in peers:
    if not peer.client.isNil:
      await peer.client.stop()
  for peer in peers:
    if not peer.server.isNil:
      peer.server.stop()
