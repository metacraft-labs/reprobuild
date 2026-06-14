## ReproOS-Generations-And-Foreign-Packages A2 — server-side index.
##
## Thin adapter that connects ``BinaryCacheManifest`` ingestion to:
##
##   * the existing ``libs/repro_local_store/`` content store (for the
##     CAS payload bytes), and
##   * a per-entry on-disk SSZ-style file under
##     ``<server-root>/manifests/<ab>/<full-key-hex>.manifest``,
##
## so the HTTP layer can serve ``GET /manifests/<hex>`` in O(1) and
## ``GET /payloads/<hex>`` by streaming the CAS blob.
##
## This module DOES NOT introduce a second store backend — payload
## blobs ride on the local-store CAS via ``storeCasBlob`` /
## ``readCasBlob``. The on-disk manifest file is a thin sidecar; the
## payload bytes are content-addressed in the CAS shared with the
## rest of reprobuild.
##
## ## Layout under ``<server-root>/``
##
##   manifests/<ab>/<full-key-hex>.manifest        ## SSZ envelope
##   store/<cas-shards-managed-by-local-store>/    ## payload bytes
##   index/cache-info.bin                          ## CacheInfoRecord
##   trust/server-ecdsa-p256.{key,cert}            ## producer key
##
## The trust-anchor directory ``trust/anchors/`` is reserved for the
## set of accepted PRODUCER pubkeys (the cache server only signs with
## its own key in v1; the directory is forward-compat for federated
## publishing).

import std/[os, strutils]

import blake3
import repro_local_store
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import ./types
import ./key
import ./manifest_codec

const
  ManifestExt* = ".manifest"
  CacheInfoFile* = "index/cache-info.bin"
  ServerKeyFile* = "trust/server-ecdsa-p256.key"
  ServerCertFile* = "trust/server-ecdsa-p256.cert"
  TrustAnchorsDir* = "trust/anchors"
  ManifestsSubdir* = "manifests"
  PayloadCasSubdir* = "store"

type
  IndexError* = object of CatchableError
    ## Raised on filesystem or content-addressing failures the HTTP
    ## layer wants to map to a structured response.

  BinaryCacheServerState* = ref object
    ## Mutable runtime state held by the HTTP handler. The local-store
    ## handle is wrapped in a ``ref`` because the server's
    ## ``asynchttpserver`` callback closure holds a single instance
    ## across many concurrent requests.
    root*: string
      ## ``/var/lib/repro-binary-cache`` on the deployed
      ## ``repro-cache`` distro; per-instance temp dirs in tests.
    store*: Store
      ## Open handle into ``<root>/store`` — the same content store
      ## the rest of reprobuild uses. Payload bytes ride on
      ## ``storeCasBlob`` / ``readCasBlob``.
    info*: CacheInfoRecord
      ## Cached ``CacheInfoRecord`` returned from ``GET /cache-info``.
      ## Updated when the producer key rotates.
    producerKeypair*: PeerKeypair
      ## The on-disk ECDSA-P256 producer key. Re-generated on first
      ## boot if missing; loaded thereafter. The publish handler
      ## verifies the EMBEDDED ``producerPubKey`` in each manifest
      ## against this keypair OR against a trust anchor for
      ## federated publishers.

# ---------------------------------------------------------------------------
# Filesystem helpers.
# ---------------------------------------------------------------------------

proc manifestsRoot*(s: BinaryCacheServerState): string =
  s.root / ManifestsSubdir

proc payloadStoreRoot*(s: BinaryCacheServerState): string =
  s.root / PayloadCasSubdir

proc manifestPathFor*(s: BinaryCacheServerState; entryKeyHex: string): string =
  if entryKeyHex.len != 64:
    raise newException(IndexError,
      "binary-cache entry-key hex must be 64 chars, got " &
      $entryKeyHex.len)
  let lower = entryKeyHex.toLowerAscii()
  result = s.manifestsRoot / lower[0 .. 1] / (lower & ManifestExt)

proc payloadCasPathFor*(s: BinaryCacheServerState; payload: PayloadObject): string =
  ## Path the local-store CAS uses for a payload blob.
  let rel = casBlobRelative(payload.digest)
  result = s.payloadStoreRoot / rel

# ---------------------------------------------------------------------------
# Producer key bootstrap.
# ---------------------------------------------------------------------------

proc ensureProducerKey*(s: BinaryCacheServerState) =
  ## On first boot, generates a fresh ECDSA-P256 keypair via
  ## ``repro_peer_cache.auth.generateKeypair`` and persists it under
  ## ``<root>/trust/``. On subsequent boots, the on-disk key is loaded
  ## verbatim. Idempotent: calling twice does not regenerate.
  let keyPath = s.root / ServerKeyFile
  let certPath = s.root / ServerCertFile
  createDir(parentDir(keyPath))
  s.producerKeypair = peerAuth.loadOrGenerateKeypair(certPath, keyPath)
  s.info.publicSigners = @[s.producerKeypair.publicKey]

# ---------------------------------------------------------------------------
# Cache-info read/write.
# ---------------------------------------------------------------------------

proc encodeCacheInfo*(info: CacheInfoRecord): seq[byte] =
  ## Tiny hand-rolled envelope — separate from the manifest codec
  ## because cache-info is small enough that a single round-trip is
  ## easier to audit at byte granularity.
  result = newSeqOfCap[byte](256)
  # Magic: "RCI1" so a curl GET piped through xxd shows the right
  # header before any structured field.
  for ch in "RCI1":
    result.add(byte(ch))
  # Format version.
  result.add(byte(info.formatVersion and 0xff'u16))
  result.add(byte((info.formatVersion shr 8) and 0xff'u16))
  # storeDir length + bytes.
  let storeBytes = info.storeDir
  for shift in countup(0, 24, 8):
    result.add(byte((uint32(storeBytes.len) shr uint32(shift)) and 0xff'u32))
  for ch in storeBytes:
    result.add(byte(ch))
  # priority (i32).
  let p = cast[uint32](info.priority)
  for shift in countup(0, 24, 8):
    result.add(byte((p shr uint32(shift)) and 0xff'u32))
  # wantMassQuery (u8).
  result.add(if info.wantMassQuery: 1'u8 else: 0'u8)
  # publicSigners count + each.
  let n = uint32(info.publicSigners.len)
  for shift in countup(0, 24, 8):
    result.add(byte((n shr uint32(shift)) and 0xff'u32))
  for pub in info.publicSigners:
    for b in pub:
      result.add(b)

proc writeCacheInfo*(s: BinaryCacheServerState) =
  let path = s.root / CacheInfoFile
  createDir(parentDir(path))
  let bytes = encodeCacheInfo(s.info)
  writeFile(path, cast[string](bytes))

# ---------------------------------------------------------------------------
# Init.
# ---------------------------------------------------------------------------

proc openBinaryCacheServer*(root: string;
                            storeDir = ""): BinaryCacheServerState =
  ## Opens (or creates) a binary-cache server rooted at ``root``.
  ## Idempotent: rerunning against a populated ``root`` reloads the
  ## existing producer key + manifests; nothing is overwritten.
  createDir(root)
  createDir(root / ManifestsSubdir)
  createDir(root / PayloadCasSubdir)
  createDir(root / "index")
  createDir(root / "trust")
  createDir(root / TrustAnchorsDir)

  let advertisedStoreDir =
    if storeDir.len > 0: storeDir
    else: root / PayloadCasSubdir

  result = BinaryCacheServerState(
    root: root,
    store: openStore(root / PayloadCasSubdir),
    info: newCacheInfoRecord(advertisedStoreDir),
    producerKeypair: PeerKeypair())
  ensureProducerKey(result)
  writeCacheInfo(result)

proc close*(s: BinaryCacheServerState) =
  if s.isNil:
    return
  close(s.store)

# ---------------------------------------------------------------------------
# Manifest CRUD.
# ---------------------------------------------------------------------------

proc storeManifest*(s: BinaryCacheServerState;
                    m: BinaryCacheManifest): string =
  ## Writes the encoded manifest envelope under
  ## ``manifests/<ab>/<key-hex>.manifest`` and returns the resolved
  ## absolute path. Caller has already verified ``m.signature``.
  let hex = cacheEntryKeyHex(m.entryKey)
  let path = manifestPathFor(s, hex)
  createDir(parentDir(path))
  let bytes = encodeManifest(m)
  writeFile(path, cast[string](bytes))
  return path

proc loadManifest*(s: BinaryCacheServerState;
                   entryKeyHex: string): BinaryCacheManifest =
  let path = manifestPathFor(s, entryKeyHex)
  if not fileExists(path):
    raise newException(IndexError,
      "manifest not found for entry-key " & entryKeyHex)
  let content = readFile(path)
  result = decodeManifest(cast[seq[byte]](content))

proc manifestRawBytes*(s: BinaryCacheServerState;
                       entryKeyHex: string): seq[byte] =
  ## Streams the raw envelope bytes verbatim — used by the HTTP layer
  ## so the client gets the exact bytes the producer signed (no
  ## re-encode round-trip).
  let path = manifestPathFor(s, entryKeyHex)
  if not fileExists(path):
    raise newException(IndexError,
      "manifest not found for entry-key " & entryKeyHex)
  let content = readFile(path)
  result = cast[seq[byte]](content)

proc manifestExists*(s: BinaryCacheServerState;
                     entryKeyHex: string): bool =
  fileExists(manifestPathFor(s, entryKeyHex))

proc listManifestKeys*(s: BinaryCacheServerState): seq[string] =
  ## Walks the manifests subdir and returns every ``<key-hex>``
  ## without the trailing extension. Used by the integration tests
  ## and the admin CLI.
  result = @[]
  for shard in walkDir(s.manifestsRoot):
    if shard.kind != pcDir:
      continue
    for entry in walkDir(shard.path):
      if entry.kind != pcFile:
        continue
      if not entry.path.endsWith(ManifestExt):
        continue
      let leaf = extractFilename(entry.path)
      result.add(leaf[0 ..< leaf.len - ManifestExt.len])

# ---------------------------------------------------------------------------
# Payload CRUD.
# ---------------------------------------------------------------------------

proc storePayload*(s: BinaryCacheServerState;
                   payload: openArray[byte]): PrefixIdBytes =
  ## Inserts a raw payload blob into the underlying local-store CAS.
  ## Returns the BLAKE3-256 digest the caller should compare against
  ## the manifest-declared ``PayloadObject.digest``.
  result = storeCasBlob(s.store, payload)

proc readPayload*(s: BinaryCacheServerState;
                  digest: PrefixIdBytes): seq[byte] =
  result = readCasBlob(s.store, digest)

proc payloadExists*(s: BinaryCacheServerState;
                    digest: PrefixIdBytes): bool =
  ## Cheap presence check — used by ``GET /payloads/<hex>`` to map a
  ## missing payload to ``Http404``.
  result = fileExists(s.store.casPath(digest))

proc payloadDigestFromHex*(hex: string): PrefixIdBytes =
  let d = hexToDigest(hex)
  for i in 0 ..< 32:
    result[i] = d[i]
