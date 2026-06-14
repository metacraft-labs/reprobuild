## ReproOS-Generations-And-Foreign-Packages A2 — binary-cache types.
##
## Implements the four typed surfaces ``Binary-Caches.md`` mandates for
## the Layer-3 substitute plane:
##
##   * ``CacheEntryKey``      — the solved package-instance identity
##                              tuple per § "Cache Entry Identity".
##   * ``BinaryCacheManifest``— the manifest record per § "Manifest"
##                              (binary-cache format version, identity,
##                              payload object identities + sizes,
##                              realized-prefix identity, dep refs,
##                              relocation policy, trust/signature).
##   * ``PayloadObject``     — the payload descriptor per § "Payload
##                              objects" (compressed prefix archive,
##                              content-addressed tree fragment, or
##                              generated launcher; each carrying a
##                              BLAKE3-256 content digest, declared size,
##                              and compression kind).
##   * ``CacheInfoRecord``   — the ``/cache-info`` advertised record per
##                              § "Lessons From Nix" (StoreDir, priority,
##                              mass-query capability + the public-key
##                              fingerprints clients should expect).
##
## The codec lives in ``manifest_codec.nim`` and writes a
## **version-tagged envelope** around an SSZ-style fixed-shape encoding;
## the on-disk + on-wire byte order is little-endian throughout
## (matching the existing peer-cache / runquota / local-store envelopes).

import std/[tables]

import blake3
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

export peerAuth.PublicKeyBytes
export peerAuth.SignatureBytes
export peerAuth.PeerKeypair

const
  BinaryCacheFormatVersion* = 1'u16
    ## Hard-coded version stamped on every manifest envelope.
    ## ``manifest_codec.nim`` REJECTS any other version on decode so a
    ## future v2 format coexists explicitly via a parallel decoder path.

  BinaryCacheEnvelopeMagic* = "RBC1"
    ## Four-byte ASCII magic prepended to every encoded manifest. Lets
    ## a hex-dumper recognise the envelope at a glance and lets the
    ## decoder hard-fail on a misaligned read before consuming the
    ## rest of the buffer.

  DefaultPriority* = 30'i32
    ## Default ``/cache-info`` priority. Lower wins per the Nix
    ## substituter convention; the v1 single-tenant cache sits below
    ## ``cache.nixos.org`` (priority 40) by default so a Nix client
    ## that has BOTH configured queries this server first.

  DefaultListenAddr* = "0.0.0.0:7878"

type
  Blake3Hash* = array[32, byte]
    ## 32-byte raw BLAKE3-256 digest — identical to
    ## ``repro_local_store.PrefixIdBytes`` and
    ## ``repro_peer_cache.BlobDigest`` by representation. Re-aliased
    ## here so the binary-cache types compile without pulling either
    ## consumer library transitively.

  PlatformTriple* = object
    ## Target platform descriptor per ``Binary-Caches.md``
    ## § "Cache Entry Identity" — target platform + ABI. Holds the
    ## conventional GNU triple plus the libc family for ABI
    ## compatibility resolution.
    cpu*: string                ## ``x86_64`` | ``aarch64`` | ``riscv64``
    os*: string                 ## ``linux`` | ``darwin`` | ``windows``
    abi*: string                ## ``gnu`` | ``musl`` | ``msvc`` | ``""``
    libcVariant*: string        ## ``glibc-2.42`` | ``musl-1.2.5`` | ``""``

  ToolchainIdentity* = object
    ## ``Binary-Caches.md`` § "Cache Entry Identity": compiler or
    ## toolchain identity *where relevant*. For the R4-R9 chain the
    ## host gcc version + host ld.so ABI are part of this tuple
    ## (per R8 commit ``5c30234`` — byte stability is conditional on
    ## host gcc 11.x).
    name*: string               ## ``gcc`` | ``clang`` | ``tcc`` | ``""``
    version*: string            ## ``11.4.0``
    hostLdSoAbi*: string        ## ``ld-linux-x86-64.so.2``
    extraFingerprint*: string   ## Hex of recipe-specific fingerprint
                                ## bytes. Empty when irrelevant.

  CacheEntryKey* = object
    ## Solved package-instance identity per ``Binary-Caches.md``
    ## § "Cache Entry Identity". The hard invariant ``two entries
    ## that are not interchangeable at runtime must not share one
    ## cache key`` is enforced by including every field below in the
    ## canonical encoding used to derive the entry-key bytes
    ## (see ``key.nim``).
    packageName*: string
    packageVersion*: string
    selectedOptions*: seq[(string, string)]
      ## Ordered list of ``(option-name, option-value)`` pairs. Sorted
      ## lexicographically by name in the canonical encoding to keep
      ## the derived key independent of insertion order.
    platform*: PlatformTriple
    toolchain*: ToolchainIdentity
    depClosureDigest*: Blake3Hash
      ## BLAKE3-256 over the canonically-encoded list of dep
      ## ``CacheEntryKey`` digests. A single field collapses an
      ## arbitrary closure into 32 bytes.
    providerRevision*: string
      ## The package-definition / provider revision identity. For the
      ## R4 bootstrap chain this is the ``chain_manifest_version`` +
      ## ``stagex_commit`` shape; for native reprobuild realizations
      ## it's the recipe-body fingerprint.

  RelocationPolicy* = enum
    rpRequired = 0'u8           ## consumer MUST relocate before use
    rpOptional = 1'u8
    rpForbidden = 2'u8          ## payload encodes absolute paths;
                                ## consumer MUST match the producer's
                                ## store layout exactly

  PayloadKind* = enum
    pkPrefixArchive = 0'u8      ## tar.zst of the realized prefix
    pkContentTree = 1'u8        ## CAS-tree manifest blob
    pkLauncher = 2'u8           ## generated launcher binary
    pkMetadata = 3'u8           ## arbitrary metadata file

  CompressionKind* = enum
    ckNone = 0'u8
    ckZstd = 1'u8
    ckXz = 2'u8

  PayloadObject* = object
    ## ``Binary-Caches.md`` § "Payload objects". Each payload is a
    ## thin descriptor (kind + size + digest + compression) so the
    ## manifest stays small and lookup costs remain O(1). The actual
    ## payload bytes ride on the existing
    ## ``libs/repro_local_store/`` CAS via ``storeCasBlob`` /
    ## ``readCasBlob``.
    kind*: PayloadKind
    compression*: CompressionKind
    declaredSize*: uint64        ## bytes on the wire after compression
    uncompressedSize*: uint64    ## hint for the consumer's reservation
    digest*: Blake3Hash        ## BLAKE3-256 of the *compressed* bytes
                                 ## (the bytes the client receives over
                                 ## the wire and re-hashes)
    name*: string                ## logical name within the entry
                                 ## (``"prefix.tar.zst"`` /
                                 ## ``"launcher-bin"``); informational.

  BinaryCacheManifest* = object
    ## ``Binary-Caches.md`` § "Manifest". Carries every field the spec
    ## mandates plus the canonical entry-key for redundancy (clients
    ## that received this manifest over a tampered transport can
    ## re-derive the key from the listed identity and compare).
    formatVersion*: uint16       ## == BinaryCacheFormatVersion
    entryKey*: CacheEntryKey
    payloads*: seq[PayloadObject]
    realizedPrefixDigest*: Blake3Hash
      ## BLAKE3-256 of the canonically-encoded realized-prefix tree
      ## manifest. Identifies the materialised bytes; equal to the
      ## existing ``computeRealizationHash`` for v1 publications.
    depReferences*: seq[Blake3Hash]
      ## Each entry is the BLAKE3-256 of a dep's
      ## ``CacheEntryKey``-canonical encoding (see ``key.nim``).
      ## Closure-aware substitute walk consults these directly.
    relocationPolicy*: RelocationPolicy
    createdAtUnix*: int64
    producerPubKey*: peerAuth.PublicKeyBytes
      ## 65-byte uncompressed ECDSA-P256 public key of the producer
      ## (the workstation's binary-cache server key generated on
      ## first boot per the A2 design).
    signature*: peerAuth.SignatureBytes
      ## 64-byte raw ECDSA-P256 ``r || s`` over the canonical
      ## envelope minus the signature field itself. See
      ## ``manifest_codec.signManifest`` /
      ## ``manifest_codec.verifyManifest``.

  CacheInfoRecord* = object
    ## ``GET /cache-info`` response body per ``Binary-Caches.md``
    ## § "Lessons From Nix":
    ##
    ##   * ``StoreDir`` matches the producer's local-store root
    ##     (``/var/lib/repro-binary-cache/store`` on the server).
    ##   * ``priority`` is the client-side preference signal — lower
    ##     wins; ``DefaultPriority`` puts us above Spack mirrors but
    ##     below first-tier Nix caches by convention.
    ##   * ``wantMassQuery`` advertises that the server's index
    ##     supports cheap bulk lookups; the consumer's closure walk
    ##     uses this to batch ``GET /manifests/<k>`` calls.
    ##   * ``publicSigners`` is the list of accepted producer pubkeys
    ##     a substitute client should pre-load into its trust anchor
    ##     set before consuming any manifest from this server.
    storeDir*: string
    priority*: int32
    wantMassQuery*: bool
    formatVersion*: uint16
    publicSigners*: seq[peerAuth.PublicKeyBytes]

# ---------------------------------------------------------------------------
# Lightweight convenience constructors keep test setup and the integration
# scripts terse without hard-coding magic-number defaults.
# ---------------------------------------------------------------------------

proc newCacheInfoRecord*(storeDir: string;
                         publicSigners: seq[peerAuth.PublicKeyBytes] = @[];
                         priority = DefaultPriority): CacheInfoRecord =
  CacheInfoRecord(
    storeDir: storeDir,
    priority: priority,
    wantMassQuery: true,
    formatVersion: BinaryCacheFormatVersion,
    publicSigners: publicSigners)

proc payloadDigestHex*(p: PayloadObject): string =
  ## Lowercase hex of the payload's BLAKE3-256 digest. Cheap helper
  ## used by the HTTP layer to format ``/payloads/<hex>`` URLs.
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(64)
  for b in p.digest:
    result.add(HexChars[int(b shr 4) and 0x0f])
    result.add(HexChars[int(b) and 0x0f])
