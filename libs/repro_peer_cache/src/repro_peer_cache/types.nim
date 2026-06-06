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

import std/[hashes, nativesockets]

export nativesockets.Port

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
