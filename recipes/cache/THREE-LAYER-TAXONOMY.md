# Reprobuild Cache Planes — Three-Layer Taxonomy

> **Status:** Authoritative inventory landed by A1 of the
> [ReproOS-Generations-And-Foreign-Packages campaign][campaign]. Authored
> 2026-06-14. Cross-link reference for orchestrators, sub-agents, and
> reviewers writing about reprobuild caching.

[campaign]: ../../../reprobuild-specs/ReproOS-Generations-And-Foreign-Packages.milestones.org

## Why this document exists

Three independent cache planes coexist inside Reprobuild. They each
answer a different question, are keyed by different identities, and
live in different modules. Conflating them is a recurrent error: the
R7 sub-agent and the campaign's first draft both initially treated
"peer cache" as if it were the package-level substitute plane. They
are not the same plane.

This document is the single audit-grade inventory.

| Layer | Question it answers | Identity | Implementation |
|---|---|---|---|
| 1 — Local build-action cache | "Has this exact action been executed before?" | Action fingerprint (weak + strong) over BuildXL-style declarative inputs + observed evidence; output blobs identified by BLAKE3-256 content digest | `libs/repro_build_engine/` + `libs/repro_local_store/` (implemented) |
| 2 — Peer cache | "Does a sibling node on my LAN already hold this output blob?" | Same BLAKE3-256 content digest as Layer 1; no separate identity space | `libs/repro_peer_cache/` (implemented, 18 modules) |
| 3 — Binary cache | "Has this exact solved package instance already been realized somewhere I can fetch from?" | Solved package-instance identity tuple (name, version, options, target, ABI, toolchain id, dep-closure id, provider revision) | spec only (`reprobuild-specs/Binary-Caches.md`); v1 lands in Phase A of the ReproOS-Generations-And-Foreign-Packages campaign |

The rest of the document expands each layer with definition, identity
model, where implemented, public API entry points, and the boundary
versus the other two layers.

---

## Layer 1 — Local build-action cache

### Definition

BuildXL-style memoization layer paired with a content-addressed
store. The memoization layer maps **action fingerprints** to result
metadata; the content store holds the output bytes (blobs and packed
trees) by **BLAKE3-256** content identity. Every cacheable thing
Reprobuild does — compiler invocations, generated config files, test
runs, function-level query nodes, package-definition evaluations —
goes through this plane.

Per [Caching-Architecture.md][cache-arch] §"Overview" and §"Two
Layers Of Identity", the layer is BuildXL-style precisely because:

- a **weak fingerprint** is computed from the static action
  specification (tool identity, normalized arguments, declared
  inputs, platform constraints, solved package instance identities,
  the recipe body fingerprint);
- a **strong fingerprint** incorporates observed dynamic execution
  evidence (actual reads, probes, enumerations) so the same weak key
  can map to multiple candidate path sets;
- the **content store** is intentionally separate from the
  memoization layer so two coincidentally byte-identical actions
  don't collapse into one cache entry.

This is fine-grained per-action. It is NOT package-level.

[cache-arch]: ../../../reprobuild-specs/Caching-Architecture.md

### Identity model

- **Action key**: weak fingerprint (declarative) and strong
  fingerprint (declarative + observed evidence) per
  [Caching-Architecture.md][cache-arch] §"BuildXL-Inspired
  Fingerprinting".
- **Content key**: BLAKE3-256 of the payload bytes; the same digest
  identifies a blob anywhere in the system — local, peer, or remote.
- **Non-interchangeability invariant**: two actions that are not
  interchangeable at runtime must not share an action key. Two
  byte-identical payloads from different actions DO share a content
  key (intentionally — that's deduplication).

### Where implemented

- **Memoization layer + scheduler**: `libs/repro_build_engine/`
  (~2943-line ninja-style scheduler with pool concept,
  lease-based execution, event-driven wait-loop modeled on
  `references/ninja/src/subprocess-win32.cc`).
- **Content store + realization receipts + GC roots**:
  `libs/repro_local_store/src/repro_local_store/store.nim`.
- **Schema layout (under `<store-root>/`)** per the `store.nim`
  header:
  - `cas/blake3/<aa>/<full-hash>` — sharded BLAKE3-256 blobs
  - `prefixes/<package>/<version>-<realization-hash>/` —
    human-friendly realized prefixes
  - `index.db` — SQLite store index (WAL mode)
  - `tmp/<random>/` — staging dirs for atomic materialization
  - `gc/pending-deletion/<name>/` — reaped prefixes awaiting unlink

### Public API entry points

From `libs/repro_local_store/src/repro_local_store/store.nim`:

- `openStore(root: string): Store` / `close(s: var Store)`
- `storeCasBlob(s: var Store; payload: openArray[byte]): PrefixIdBytes`
- `readCasBlob(s: Store; digest: PrefixIdBytes): seq[byte]`
- `verifyCasBlob(s: Store; digest: PrefixIdBytes)`
- `realizePrefix(s: var Store; prefixId: PrefixIdBytes; ...)` (atomic
  materialization of a realized package prefix)
- `lookupPrefix` / `insertPrefixOrIgnore` / `listPrefixes`
- `registerRoot` / `attachPrefixToRoot` / `deleteRoot` / `listRoots`
  (GC roots)
- `gc(s: var Store; graceSeconds = DefaultGcGraceSeconds): GcReport`
- `encodeReceipt` / `decodeReceipt` / `readReceiptFile` /
  `writeReceiptFile` (realization receipts)

The build-engine integration seam lives at
`libs/repro_build_engine/src/repro_build_engine.nim` (umbrella
re-exporter).

### Boundary versus the other two layers

- **Versus Layer 2 (peer cache)**: Layer 1 owns the action-cache
  *metadata* (fingerprints, evidence, memoization records). Layer 2
  is a **transport** for the *content blobs* whose identities Layer 1
  already assigned. Layer 2 never carries action-cache metadata,
  only payloads. The Peer-Cache spec is explicit: "the peer cache
  does **not** transport action-cache *metadata* (memoisation
  records, evidence, signatures). Only the content-addressed
  *output blobs* move between peers."
- **Versus Layer 3 (binary cache)**: Layer 1 is fine-grained
  per-action. A single package realization may emit hundreds of
  Layer-1 cache entries (one per compile, link, test, install
  step). Layer 3 is package-level: one cache entry per solved
  package-instance identity. Layer 3 reuses Layer 1's content store
  for its payload objects per [Binary-Caches.md][binary-caches]
  §"Interaction With The Store" — "payload blobs become store
  objects" — but the cache *key* is different (package-instance
  identity, not action fingerprint).

[binary-caches]: ../../../reprobuild-specs/Binary-Caches.md

---

## Layer 2 — Peer cache

### Definition

Distributed **transport** for Layer 1. Lets a node pull an already
realized output blob from a sibling node on the same network rather
than rebuilding from source or fetching from a central remote cache.
Same content identity as Layer 1; no separate identity space.

Per [Peer-Cache.md][peer-cache] §"Overview", the runtime stack is:

1. local action cache (fastest, no network) — Layer 1
2. peer cache (LAN, point-to-point) — Layer 2
3. central remote cache (WAN, signed payloads) — Layer 3
4. rebuild from source

A peer cache miss falls through to layer 3 automatically.

[peer-cache]: ../../../reprobuild-specs/Peer-Cache.md

### Identity model

- **Blob identity**: BLAKE3-256 content digest assigned by Layer 1.
  Identical key namespace.
- **Peer identity**: 32-byte randomly-generated peer ID; one
  network endpoint (`host:port`).
- **Trust boundary**: CIDR allowlist. Inside the CIDR, peers are
  assumed mutually trusting — the peer cache is *not* a security
  boundary, it is a LAN-fabric extension of the local store.
  Cross-trust-boundary use (internet-facing, multi-tenant) requires
  Layer 3 and its signed payloads.
- **Non-interchangeability invariant**: identical to Layer 1 because
  the identity *is* Layer 1's. A peer cache hit is exactly
  equivalent to a local hit for cache correctness.

### Where implemented

- **Library**: `libs/repro_peer_cache/` — 18 source modules:
  - `types.nim` — `PeerId`, `BlobDigest`, `Endpoint`, `MessageKind`,
    SSZ-shaped record types
  - `codec.nim` — Frame encode/decode + per-message
    encoders/decoders + `dispatch`
  - `registry.nim` — In-memory `PeerRegistry` (advertise snapshot vs
    delta, suspect, find-by-blob)
  - `cuckoo.nim` — Cuckoo-filter-backed blob-presence index
  - `server.nim` — `asyncnet` TCP server, handshake handler,
    advertisement responder, CIDR allowlist; multicast receive loop
  - `client.nim` — `asyncnet` TCP dialer, handshake initiator,
    advertisement publisher, connection pool with LRU eviction
  - `loopback.nim` — Convenience helpers for spawning N peers on
    distinct loopback ports
  - `multicast.nim` (+ `multicast.exe`) — UDP multicast discovery
  - `swim.nim` — SWIM membership / failure-detection
  - `auth.nim` + `pki.nim` + `tls.nim` — ECDSA-P256 keypair, X.509
    self-signed + CA-signed cert minting, BearSSL-backed TLS
    transport
  - `sim.nim` — workload simulator for sizing + isolation tests
  - `tier2.nim` — inter-rack / central-fallthrough integration
  - `disk_store.nim` — on-disk peer state persistence
  - `action_bundle.nim` — bundled action-cache record fetch flow
  - `metrics.nim` — Prometheus metrics
  - `engine_seam.nim` — engine integration seam (wraps `localRead`
    + `localWrite` + optional peer-cache client for the action-cache
    reader's pre-rebuild lookup)
- **Tests**: 56 tests under `libs/repro_peer_cache/tests/`
  (codec round-trip, multicast discovery, TLS handshake, partition
  recovery, SWIM convergence, action-cache reader integration, etc.).
- **Status**: M0 through Peer-Cache-BearSSL M3 landed. Loopback and
  multicast discovery work; TLS layer working; PKI directory loader
  working; 200-peer convergence and partition recovery tests pass.

### Public API entry points

From `libs/repro_peer_cache/src/repro_peer_cache/`:

- **Server** (`server.nim`):
  `newPeerCacheServer(selfPeerId, listenAddr, cidrAllowlist, ...)`,
  `start(server)`, `stop(server)`, `actualPort(server)`,
  `multicastListen(server, group)`
- **Client** (`client.nim`):
  `newPeerCacheClient(selfPeerId, peers, ...)`,
  `newPeerConnPool(maxPerPeer)`, `acquireConn` / `releaseConn` /
  `reapIdle`
- **Engine seam** (`engine_seam.nim`): the wrapper the build engine's
  action-cache reader holds — `localRead` closure, `localWrite`
  closure, optional `peerCacheClient`. The reader checks local
  first; on miss it consults the peer cache before falling through
  to a rebuild or to Layer 3. The seam tracks a `peerHits` counter
  for verification tests.
- **PKI** (`pki.nim`): self-signed X.509 v3 cert generation, CA-cert
  minting, trust-anchor directory loader. Layer-agnostic primitives
  (Layer 3's binary-cache signing will reuse them).
- **Auth** (`auth.nim`): ECDSA-P256 keypair generation, sign,
  verify. Also layer-agnostic.

### Boundary versus the other two layers

- **Versus Layer 1**: same identity space; Layer 2 is a transport
  for Layer 1's content blobs. A peer cache hit is functionally a
  local hit. The peer cache does NOT carry action-cache metadata
  (fingerprints, evidence, signatures); those stay canonical to
  Layer 1 / Layer 3.
- **Versus Layer 3**: Layer 2 is per-output-blob, Layer 3 is
  per-solved-package-instance. A Layer 2 hit retrieves ONE blob
  identified by ONE BLAKE3 digest; a Layer 3 hit retrieves a
  *manifest* that names dozens of payload object identities plus
  dep-closure references plus realization metadata plus a
  trust/signature. Layer 2 is a LAN fabric extension; Layer 3 is a
  WAN-grade signed publication plane (the Nix-substituter /
  Spack-buildcache analogue). Layer 3 falls through to Layer 1 on
  miss; Layer 2 falls through to Layer 3 on miss (per
  [Peer-Cache.md][peer-cache] §"Overview" runtime stack).
- **Reused primitives**: `pki.nim` and `auth.nim` are layer-agnostic
  (ECDSA + X.509 + trust-anchor loader); Layer 3 will reuse them
  for binary-cache entry signing per the A1 reuse survey below.

---

## Layer 3 — Binary cache

### Definition

Package-level **substitute plane**. Reuses already-realized package
instances (gcc-15.2.0 prefix, glibc-2.42 prefix, linux-6.6.142
bzImage, systemd-257.9 prefix) so clients do not rebuild or
re-extract them. Direct analogue of:

- Nix substituters (`nix-store --realise` consulting
  `cache.nixos.org` for an exact store path)
- Spack buildcaches (`spack install --use-buildcache` consulting a
  mirror for a concrete spec)

Per [Binary-Caches.md][binary-caches] §"Overview":
"This document is only about the package-level substitute plane,
not the lower memoization/content-store plane for arbitrary actions."

### Identity model

- **Cache entry key**: the solved package-instance identity tuple per
  [Binary-Caches.md][binary-caches] §"Cache Entry Identity":
  - package name
  - package version
  - selected options
  - target platform and ABI
  - compiler or toolchain identity where relevant
  - relevant dependency-closure identity
  - package-definition / provider revision identity
- **Hard invariant**: "two entries that are not interchangeable at
  runtime must not share one cache key."
- **Closure identity**: a Layer 3 entry references its dep-closure
  members by their own Layer 3 keys (each dep is a separate cache
  entry). The substitute consumption walk is closure-aware: on a
  hit for entry `K`, walk `K`'s dep references, recursively
  substituting any dep that isn't already in the local store, then
  materialize `K`.
- **Trust**: each entry is signed by the producing identity (ed25519
  per the A2 design; X.509 + ECDSA-P256 already supported via the
  reused `pki.nim` / `auth.nim` primitives). Clients verify
  signature + closure compatibility before materialization.

### Where implemented

**Spec only.** Phase A of the
[ReproOS-Generations-And-Foreign-Packages][campaign] campaign lands
v1:

- A1 (this milestone): cache-layer taxonomy + binary-cache impl-gap
  matrix. **No code lands.**
- A2: binary-cache server on the `repro-cache` WSL distro with
  rsync mirror to Windows; client library in
  `libs/repro_binary_cache_client/`.
- A2.5: highly-efficient client (single-pass streaming
  fetch+decompress+hash+materialize) wired into the existing
  build-engine scheduler.
- A3: R4-R9 toolchain build scripts publish to + substitute from the
  binary cache.
- A4: parallel toolchain builds via binary-cache substitution +
  in-flight sentinel + eviction policy.

The R4 `tools/bootstrap-cache/` (in the **specs** repo) is the
closest *existing* shape to Layer 3: it produces signed attestation
envelopes for each step of the hex0-through-tcc bootstrap chain,
with a per-step manifest, blob storage by SHA-256, and an `openssl
dgst -verify` chain walk. But it predates the formal
[Binary-Caches.md][binary-caches] design and lacks:

- closure-aware substitution
- the Binary-Caches.md manifest format (CBOR/SSZ + version-tagged
  envelopes)
- payload-object encoding (compressed prefix archives /
  content-addressed trees / launchers)
- mirror publication model
- signature verification at the substitute boundary
- HTTP-level cache-info advertisement
- in-flight sentinel for parallel substitution

A3 replaces the R4 envelope schema with the A2 manifest format
while preserving the signing identity.

### Public API entry points

**Planned for A2/A2.5.** Per the campaign:

- `apps/repro-binary-cache/repro_binary_cache.nim` — HTTPS server
  with REST surface:
  - `GET /cache-info` (advertises `StoreDir`, priority, mass-query
    support per the Nix substituter convention)
  - `GET /manifests/<entry-key>`
  - `GET /payloads/<blake3-256>`
  - `POST /publish` (signed multipart: manifest + payload)
  - `POST /sentinel/<entry-key>` (in-flight sentinel claim — A4)
- `libs/repro_binary_cache_client/src/repro_binary_cache_client/`
  modular impl (planned):
  - `http_pool.nim` — libcurl HTTP/2 multiplexing pool
  - `manifest_codec.nim` — CBOR/SSZ + version-tagged envelopes
  - `payload_sink.nim` — single-pass streaming sink chain
  - `decompress.nim` — zstd + xz streaming
  - `scheduler_executor.nim` — build-engine integration
    (`bakBinaryCacheSubstitute` action kind)
  - `closure_walk.nim` — closure-aware substitute walk
  - `compat_check.nim` — platform/ABI/store/provider compatibility
  - `index.nim` — local CAS index updates
  - `cache_key.nim` — canonical Binary-Caches.md §"Cache Entry
    Identity" tuple encoding (A3)
  - `in_process.nim` — single-user mode wrapper

### Boundary versus the other two layers

- **Versus Layer 1**: Layer 3 is package-level, Layer 1 is per-action.
  Layer 3 reuses Layer 1's content store for payload objects per
  [Binary-Caches.md][binary-caches] §"Interaction With The Store":
  "payload blobs become store objects". The cache *key* is the
  package-instance identity tuple, not the action fingerprint. On a
  Layer 3 miss, fallback is to "ordinary build/fetch/install logic"
  — which means populating Layer 1 the normal way, then optionally
  publishing the realized prefix as a new Layer 3 entry.
- **Versus Layer 2**: Layer 2 is fine-grained transport for one
  content blob at a time inside a single LAN. Layer 3 is
  coarse-grained transport for whole package realizations with WAN
  semantics, signed manifests, mirror publication, eviction policy,
  in-flight sentinel for parallel publishers. The Peer-Cache spec
  is explicit: "the peer cache complements (does not replace) the
  central remote cache described in
  [Binary-Caches.md](./Binary-Caches.md)".
- **Reuse opportunities** (per A1 survey, consumed by A2/A2.5):
  - `libs/repro_peer_cache/src/repro_peer_cache/pki.nim` and
    `auth.nim` — layer-agnostic PKI + ECDSA-P256 primitives; A2's
    binary-cache entry signing should reuse them rather than
    introducing a second signing stack.
  - `libs/repro_local_store/` — the content store Layer 3 payload
    objects ride on; no new storage backend needed, just a thin
    REST surface + per-entry SSZ index file.
  - `tools/bootstrap-cache/cache.sh` envelope + signing flow (in
    the specs repo) — the schema is roughly the same shape Layer 3
    needs; A3 promotes it to the Binary-Caches.md manifest format.

---

## Cross-link index

- [Caching-Architecture.md][cache-arch] — Layer 1 spec.
- [Peer-Cache.md][peer-cache] — Layer 2 spec.
- [Binary-Caches.md][binary-caches] — Layer 3 spec.
- [ReproOS-Generations-And-Foreign-Packages campaign][campaign] —
  Phase A lands Layer 3 v1.
- [BINARY-CACHE-IMPL-GAP-2026-06-14.md](./BINARY-CACHE-IMPL-GAP-2026-06-14.md)
  — section-by-section gap matrix of Binary-Caches.md against the
  existing reprobuild codebase, with the A2 deliverable names that
  fill each gap.

## Notes for future authors

- **Don't write "the binary cache" when you mean "the action cache"
  or "the peer cache".** The three planes are independent and the
  terms are not interchangeable. When in doubt, name the spec
  document.
- **Don't put action-cache metadata into a Layer 2 message.** The
  peer cache moves *only* content blobs.
- **Don't put package-instance identity into a Layer 1 cache key.**
  Action fingerprints are over inputs + observed evidence; package
  identity belongs to Layer 3.
- **Don't publish externally-installed prefixes through Layer 3.**
  Per [Binary-Caches.md][binary-caches] §"External Implementations
  Are Excluded From Binary Caches By Default", weak external
  installers (winget/scoop/chocolatey/brew) and strong external
  installers (nix/spack) are recorded via the separate **external
  installation receipt** mechanism, not republished into Layer 3.
