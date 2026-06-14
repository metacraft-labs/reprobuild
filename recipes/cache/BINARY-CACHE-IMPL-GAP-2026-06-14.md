# Binary-Cache Implementation Gap Matrix — 2026-06-14

> **Status:** A1 deliverable for the
> [ReproOS-Generations-And-Foreign-Packages campaign][campaign].
> Section-by-section walk of [`Binary-Caches.md`][binary-caches] against
> the existing reprobuild codebase, with the A2/A2.5/A3/A4 deliverable
> names that fill each gap. Companion to
> [`THREE-LAYER-TAXONOMY.md`](./THREE-LAYER-TAXONOMY.md).

[campaign]: ../../../reprobuild-specs/ReproOS-Generations-And-Foreign-Packages.milestones.org
[binary-caches]: ../../../reprobuild-specs/Binary-Caches.md
[peer-cache]: ../../../reprobuild-specs/Peer-Cache.md
[cache-arch]: ../../../reprobuild-specs/Caching-Architecture.md

---

## How to read this document

For each section of [`Binary-Caches.md`][binary-caches], we record:

- **Requires** — what the spec mandates.
- **Today** — what already exists in reprobuild that's relevant. The
  closest existing shape is the R4 `tools/bootstrap-cache/cache.sh`
  envelope flow (in the **specs** repo), which produces signed
  attestation envelopes for the hex0→tcc chain. Cited as "R4" below.
- **Gap** — what's missing for the v1 Layer-3 implementation.
- **Fills it** — which Phase-A deliverable closes the gap.

---

## § Overview + Rationale + Scope

### Requires
- Reprobuild has a binary-cache plane that's the package-level
  analogue of Nix substituters and Spack buildcaches.
- Layer is distinct from build-action caches, solver-result caches,
  repository metadata caches.
- Scope covers native Reprobuild builds, native fetch/extract
  packages, and other package kinds whose realized bytes are fully
  under Reprobuild control. Excludes externally managed installs.

### Today
- **The plane does not exist as an implemented layer.** The spec is
  status "Future roadmap / draft design".
- Layer 1 (the build-action cache) is implemented in
  `libs/repro_build_engine/` + `libs/repro_local_store/`. Layer 2
  (the peer cache) is implemented in `libs/repro_peer_cache/`.
  Neither is the package-level substitute plane.
- R4 `tools/bootstrap-cache/cache.sh` produces near-binary-cache-shaped
  output (per-step signed attestations + a top-level `index.json`
  chain manifest + per-blob SHA-256 addressing), but it's
  bootstrap-chain-specific and lacks closure-aware substitute,
  manifest format conformance, payload-object encoding, mirror model.

### Gap
- The Layer-3 server doesn't exist.
- The Layer-3 client library doesn't exist.
- The build-engine integration (a `bakBinaryCacheSubstitute`
  action kind that the existing scheduler dispatches as part of
  ordinary build) doesn't exist.

### Fills it
- **A2** — `apps/repro-binary-cache/` server + `repro-cache` WSL
  distro provisioning.
- **A2.5** — `libs/repro_binary_cache_client/` modular client +
  `bakBinaryCacheSubstitute` build-engine integration.

---

## § Two Kinds Of Package Closure (native substitutable vs external imported)

### Requires
- Solved graph distinguishes **native substitutable nodes** (ordinary
  subjects of binary caches) from **external imported nodes** (still
  in the graph for lock-file reproducibility + runtime binding but
  NOT automatically Layer-3 publication candidates).
- Both kinds coexist in one solved dependency graph.
- The graph maintains exact runtime identity for all nodes.

### Today
- The solved-graph model lives in `libs/repro_core/` and adjacent
  domain-type libraries (`libs/repro_domain_types/`).
- External-installer adapters exist for Homebrew (`libs/repro_homebrew_adapter/`).
- **The native-vs-external acquisition-class tag is not present on
  graph nodes in a Layer-3-aware way** — there's no marker that
  says "this node IS a Layer-3 substitute candidate" vs "this node is
  an external imported install".

### Gap
- Domain-type tagging for the two acquisition classes so the
  closure walker can distinguish them.
- An "External Installation Receipt" subsystem (per
  [Binary-Caches.md][binary-caches] §"External Installation
  Receipts") — a local fast-idempotence record for external
  installs. **Out of scope for Phase A**; this campaign's Phase C
  (foreign packages) is the natural home for the receipts work.

### Fills it
- **A3** — adds the native-vs-external acquisition-class tag to the
  package recipes the R4–R9 chain produces (all native).
- **Out of campaign scope** — external installation receipts; see
  Phase C's foreign-package work and the
  `Linux-Third-Party-Distro-Packages.md` design.

---

## § Core Rule (Reprobuild-controlled realizations vs imported)

### Requires
- "Reprobuild binary caches are for **Reprobuild-controlled
  realizations**, not for arbitrary imported machine state."
- If Reprobuild built / fetched / materialized it from bytes it
  controls → Layer-3 publication candidate.
- If Reprobuild only delegated install → normally NOT a Layer-3
  artifact.

### Today
- The R4 bootstrap-cache flow only publishes Reprobuild-controlled
  artifacts (every entry is either a vendored stagex/alpine binary
  pinned by SHA-256 or a source-only-pin). It complies with the
  Core Rule by construction.
- For the rest of reprobuild there's no policy enforcement because
  there's no Layer-3 publisher.

### Gap
- A2's publish-side has to enforce the Core Rule: the
  `POST /publish` handler accepts only manifests for native
  realizations; external-install adapters MUST NOT publish through
  Layer 3.

### Fills it
- **A2** — server-side `POST /publish` policy gate (rejects entries
  whose recipe is from an external adapter — checked via the
  acquisition-class tag added in A3).
- **A3** — client-side publish flow only triggers for native
  realizations (the cache-aware postlude lives only in R4–R9 build
  scripts, all native).

---

## § Cache Entry Identity (package name + version + options + target + ABI + toolchain identity + closure identity + provider revision)

### Requires
- Entry key tuple:
  - package name
  - package version
  - selected options
  - target platform and ABI
  - compiler / toolchain identity where relevant
  - relevant dependency-closure identity
  - package-definition / provider revision identity
- Hard invariant: two entries that are not interchangeable at runtime
  MUST NOT share one key.

### Today
- R4 `tools/bootstrap-cache/` keys by `output_sha256` (the realized
  binary's SHA-256). That's *output identity*, NOT *cache entry
  identity* in the Binary-Caches.md sense — collapses options /
  target / toolchain / closure into the realized bytes.
- The existing local-store realization receipt
  (`computeRealizationHash` in
  `libs/repro_local_store/src/repro_local_store/store.nim` line 486)
  has a structurally similar tuple but is internal to Layer 1 and
  doesn't include all the Binary-Caches.md fields (notably
  dep-closure identity is implicit, provider revision is
  unrecorded).
- The R4 chain *does* record `stagex_commit` + `stagex_release` +
  `chain_manifest_version` (a coarse provider-revision identity),
  per-step `deps[]` (a coarse closure identity), and architecture
  via the chain filename (e.g., `chain-amd64.json` for the AMD64
  variant). These are close to the right shape but not
  Binary-Caches.md-conformant.
- The R8 commit `5c30234` caveat ("byte stability is conditional on
  host gcc 11.x") confirms the toolchain-identity / host-ABI
  component is real: a gcc-15.2.0 built under Ubuntu 22.04 (host
  gcc 11.4) and one built under Ubuntu 24.04 (host gcc 13.x) MUST
  have different cache keys.

### Gap
- Canonical encoding of the full Binary-Caches.md identity tuple.
- Field-by-field derivation rules for each R4–R9 toolchain output.
- Host-platform / host-ABI / host-toolchain identity capture for the
  toolchain-identity field (this is what R8's
  `host_gcc_version` + `host_ldso_abi` caveat made concrete).
- Two-entry coexistence: a single cache must hold a gcc-15.2.0
  built under Ubuntu 22.04 AND one built under Ubuntu 24.04 with
  distinct keys.

### Fills it
- **A3** — `libs/repro_binary_cache_client/src/repro_binary_cache_client/cache_key.nim`
  with the canonical Binary-Caches.md identity-tuple encoding.
- **A3** — `recipes/cache/CACHE-KEY-SCHEMA.md` documenting the
  derivation rules for every R4–R9 output.
- **A3** — `t_a3_compat_isolation.sh` integration test verifying
  that two host-toolchain variants get distinct keys.

---

## § Binary Cache Entry Contents (manifest record + payload objects + realization metadata + trust/signature)

### Requires
- Each entry contains at least: a manifest record, one or more
  payload objects, realization metadata, trust/signature metadata.

### Today
- R4 entries have: a JSON attestation envelope (≈ "manifest record"
  but ad-hoc shape), per-blob raw bytes under `blobs/<sha256>` (≈
  "payload objects" but only one per step + no compression / tree
  shape), realization metadata limited to `stagex_*` provenance, and
  an `openssl dgst -sign` signature in `attestations/*.json.sig`.
- The R4 envelope shape is JSON not CBOR/SSZ; the signing identity
  is the `reprobuild-team-dev-key` (single ed25519 PEM keypair).
- `libs/repro_local_store/` already stores realized prefixes
  (Layer 1) — the bytes Layer 3 payloads would carry.

### Gap
- The four-piece structure (manifest / payload objects / realization
  metadata / trust+signature) is not formalized.
- R4's manifest is JSON; Binary-Caches.md mandates CBOR/SSZ +
  version-tagged envelopes (the "binary-first" encoding policy
  shared with Layer 1's persistent records).
- Payload-object multiplicity: a Binary-Caches.md entry may carry
  multiple payload objects (prefix archive + tree fragments +
  launchers + metadata files). R4 entries carry exactly one blob.

### Fills it
- **A2** — manifest record codec in
  `libs/repro_binary_cache_client/src/repro_binary_cache_client/manifest_codec.nim`
  (CBOR/SSZ + version-tagged envelopes).
- **A2** — payload-object encoder/decoder in
  `payload_sink.nim` (compressed prefix archives + content-addressed
  tree fragments + generated launchers).
- **A3** — transcoding the existing R4 JSON envelopes to the new
  format while preserving the signing identity (so the historical
  chain stays verifiable through `tools/binary-cache/walk.sh`).

---

## § Manifest format (CBOR/SSZ + version-tagged envelopes)

### Requires
- Manifest describes: binary-cache format version, solved
  package-instance identity, payload object identities + sizes,
  realized-prefix identity, dep references, relocation policy,
  trust/signature.
- Standard reprobuild encoding policy: CBOR for dynamic metadata,
  SSZ for fixed-schema records, version-tagged envelopes around SSZ
  payloads.
- Must support: cheap metadata lookup, verified downloads,
  deterministic local materialization.

### Today
- R4 manifests are JSON (`{ "alpine_apk_repo": ..., "steps": [...] }`).
- Reprobuild has CBOR support via `libs/cbor` and
  `libs/nim-json-serialization`.
- Reprobuild has SSZ support via `libs/nim-ssz-serialization`.
- The peer-cache wire codec uses the same hand-rolled SSZ-style
  encoder pattern as `runquota_codec` (see
  `libs/repro_peer_cache/src/repro_peer_cache/codec.nim`) — a viable
  model for the Layer-3 manifest codec.
- Version-tagged envelope precedent: the local-store persistent
  records under `libs/repro_local_store/` use SSZ envelopes over
  `libs/repro_domain_types/`.

### Gap
- Manifest record SSZ schema for Layer 3 (the eight fields listed
  in [Binary-Caches.md][binary-caches] §"Manifest").
- Version-tagging envelope shape for the binary-cache format
  version (so a future v2 format can coexist with v1 entries in the
  same cache).
- CBOR dynamic-metadata blocks for the variable-length fields
  (options dict, dep references, target-platform descriptor).

### Fills it
- **A2** — `libs/repro_binary_cache_client/src/repro_binary_cache_client/manifest_codec.nim`
  implementing the fixed-schema record (SSZ) + dynamic-metadata
  blocks (CBOR) + version envelope.
- **A2** — integration test `t_a2_persistence.sh` round-trips a
  manifest through the codec.

---

## § Payload objects (compressed prefix archives / content-addressed trees / launchers)

### Requires
- Payloads may be: compressed realized-prefix archives,
  content-addressed trees or tree fragments, generated launchers,
  metadata files.
- Each payload must support cheap metadata lookup, verified
  downloads, deterministic local materialization.

### Today
- The local store (`libs/repro_local_store/`) already stores realized
  prefixes — but not compressed, not as a single archive object, and
  the "deterministic local materialization" is via hardlink/copy not
  via streaming extract.
- No zstd / xz integration at the library level (yes for
  toolchain-build vendored dependencies).
- No tree-fragment payload format.

### Gap
- Streaming decompressor wiring (zstd default, xz for back-compat
  per the A2.5 design).
- Tree-fragment encoding (for partial-realization payloads — A4 may
  need this for in-flight sentinel cooperation).
- Single-pass streaming sink chain (HTTP socket → splice → zstd
  decompress → BLAKE3 hash-as-you-go → atomic write).

### Fills it
- **A2.5** — `libs/repro_binary_cache_client/src/repro_binary_cache_client/decompress.nim`
  (libzstd + liblzma streaming wrappers).
- **A2.5** — `libs/repro_binary_cache_client/src/repro_binary_cache_client/payload_sink.nim`
  (the chained sink: socket → decompress → BLAKE3 → temp file →
  atomic rename).
- **A2.5** — performance gate
  `tests/integration/binary_cache/perf/t_a2_5_single_pass_hash.sh`
  asserts one-pass hashing via `strace -e read,write`.

---

## § Preferred Publishing Model

### Requires
- On successful native realization: realized instance already in
  local store → compute manifest + payload identities → upload to
  configured mirrors → refresh mirror indexes.
- Publication requires the stricter hermeticity policy (not just
  relaxed local-dev mode).
- Analogue: Nix copying store objects, Spack pushing built spec.

### Today
- R4 `tools/bootstrap-cache/cache.sh populate` walks
  `chain.json` and uploads (== copies into the in-tree `blobs/`
  directory) the prebuilt step outputs. Single-machine, no
  multi-mirror, no incremental index refresh.
- No publication-policy gate (nothing distinguishes "hermetic
  enough to publish" from "local dev convenience").

### Gap
- The mirror upload protocol (HTTPS multipart POST) doesn't exist.
- The publication-policy gate doesn't exist.
- Incremental index refresh on the server doesn't exist.

### Fills it
- **A2** — `POST /publish` endpoint on the server +
  `publish(manifest, payloads)` client API.
- **A3** — cache-aware postlude in every R4–R9 build script that
  publishes the realized prefix; build runs that don't pass the
  hermeticity check skip the postlude.
- **A2** — incremental SSZ index file refresh on each successful
  publish.

---

## § Preferred Consumption Model

### Requires
The order MUST be:
1. query local store first
2. query configured binary-cache indexes + mirror metadata
3. fetch manifest + payloads for an exact compatible entry
4. verify checksums + signatures
5. materialize the local realized prefix
6. continue with dependent closure members
7. fall back to ordinary build/fetch/install logic on miss

Hard rule: substitute lookup MUST be cheaper than the build it
avoids.

### Today
- Layer 1 lookup (local store) works:
  `lookupPrefix` in `libs/repro_local_store/`.
- Layer 2 lookup (peer cache) works: engine seam at
  `libs/repro_peer_cache/src/repro_peer_cache/engine_seam.nim` wires
  in between local hit and rebuild.
- Layer 3 lookup doesn't exist.

### Gap
- The closure-aware substitute walk: take a target package-instance
  identity, walk its dep references, fetch each member's manifest,
  topologically materialize.
- Integration with the existing build-engine scheduler so each
  substitution becomes a task in the pool (per the A2.5 design
  using the existing `BuildPool` + lease-based execution +
  event-driven wait-loop in
  `libs/repro_build_engine/src/repro_build_engine.nim`).
- Cache-info advertisement at the consumer (poll `/cache-info` once
  per daemon session).

### Fills it
- **A2.5** — `closure_walk.nim` (closure-aware substitute walk).
- **A2.5** — `scheduler_executor.nim` (the new
  `bakBinaryCacheSubstitute` action-kind dispatcher).
- **A2.5** — `http_pool.nim` (persistent libcurl HTTP/2 connection
  pool + cache-info caching).
- **A2.5** — performance gates
  `t_a2_5_throughput_gcc_15.sh` (≤ 1.0x Nix wall-clock),
  `t_a2_5_throughput_closure_50.sh` (≤ 1.2x Nix wall-clock),
  `t_a2_5_throughput_vs_spack.sh` (≤ 0.5x Spack wall-clock).

---

## § Compatibility Checks (platform/ABI/store layout/provider/closure/trust)

### Requires
- Before consuming: verify platform + ABI, store/realization layout,
  package-definition / provider identity, dep-closure compatibility,
  trust/signature policy.

### Today
- Layer 1 verifies BLAKE3-256 of CAS reads (`verifyCasBlob` in
  `libs/repro_local_store/src/repro_local_store/store.nim` line 729).
- Layer 2 verifies BLAKE3-256 of received blob payloads against the
  requested digest (per `Peer-Cache.md` §"Fetch semantics" step 3).
- Layer 2 has CIDR allowlist + ECDSA-P256 + TLS handshake — but
  those are Layer-2 trust mechanisms, not package-instance
  compatibility.
- No platform/ABI/store-layout/provider/closure compatibility
  checking at the Layer-3 boundary because the boundary doesn't
  exist yet.

### Gap
- Platform/ABI matcher (target triple + ABI version + libc family).
- Store-layout matcher (the realized-prefix directory shape Layer 3
  expects vs what the consumer's local store enforces).
- Provider-revision matcher (the recipe-body fingerprint per
  Caching-Architecture.md needs to match for entries to be
  interchangeable).
- Dep-closure walker that catches missing closure members before
  materialization.
- Signature/trust policy check (which signing identities are
  trusted; via `pki.nim` trust-anchor directory loader — reused
  from Layer 2).

### Fills it
- **A2.5** — `compat_check.nim` implementing all six checks.
- **A2** — trust policy file `/etc/repro-binary-cache/trust-anchors/`
  (a directory of accepted signer certs, loaded via the reused
  Layer-2 `pki.nim` trust-anchor primitive).
- **A2** — integration test `t_a2_signature_verification.sh`
  (rejects tampered manifest).
- **A2** — integration test `t_a2_closure_compat.sh` (rejects
  unsatisfied closure dep).

---

## § Interaction With The Store

### Requires
- Payload blobs become store objects.
- Realization manifests materialize or reconstruct realized prefixes.
- GC roots keep locally used realizations alive.
- The cache MUST NOT invent a second installation model separate
  from the store.

### Today
- `libs/repro_local_store/` is the store. It already implements:
  - CAS blob storage with BLAKE3-256 sharding
    (`storeCasBlob` / `readCasBlob`)
  - Realized prefixes with atomic materialization
    (`realizePrefix` via `moveFile` + `INSERT OR IGNORE INTO prefixes`)
  - GC roots (`registerRoot` / `attachPrefixToRoot` /
    `deleteRoot` / `gc`)
- This is exactly the substrate Binary-Caches.md §"Interaction With
  The Store" mandates.

### Gap
- A thin Layer-3 ingestion adapter that, on a successful payload
  fetch, dispatches: CAS blob → `storeCasBlob`; realized prefix
  archive → `realizePrefix`; manifest → SSZ index file + GC root
  attachment.
- Don't introduce a second store backend (the spec explicitly
  forbids it).

### Fills it
- **A2** — `index.nim` (the thin adapter that connects manifest
  receive to existing local-store primitives — no new store
  backend).
- **A4** — eviction policy in `libs/repro_local_store/` (LRU with
  soft + hard caps; pinned-entries list); the policy applies to
  Layer-3 manifests + payloads but rides on the existing GC-root
  infrastructure.

---

## § Mirror And Snapshot Boundary

### Requires
- When a curator publishes a snapshot containing external imported
  nodes, the snapshot preserves enough info for clients to reproduce
  the intended imported identity — but does NOT mirror the installed
  external payload as a native Layer-3 artifact.
- Preserve: package metadata, installer-adapter metadata, version /
  realized-identity constraints, expected execution-profile identity
  and checksum.

### Today
- No snapshot/curator workflow exists for Layer 3.
- R4 produces a snapshot-shaped index.json for the bootstrap chain
  but doesn't address external imported nodes (it's all native).
- Backup story exists for the cache itself: A2's design has rsync
  mirror to a Windows-side dir.

### Gap
- The native-vs-external acquisition-class tag (also called out under
  § Two Kinds Of Package Closure).
- Curator workflow for cross-distro snapshots.
- Snapshot manifest format.
- **Most of this is out of scope for Phase A.** Phase A targets
  the toolchain chain (all native); curator workflow + external
  snapshot boundary is a Phase D (foreign-package integration)
  concern.

### Fills it
- **A2** (partial) — rsync mirror + restore-from-backup path
  (`recipes/cache/restore-from-backup.ps1`); covers the
  "snapshot the native cache" axis only.
- **Out of campaign scope** for the external-snapshot axis — Phase D
  or a subsequent campaign owns that work.

---

## § Complexity Expectations

### Requires
For native Layer-3 lookup:
- local presence check: ≈ O(1)
- mirror/index lookup for one solved node: ≈ O(1 + M_lookup) with
  indexed mirrors
- closure substitution for a solved graph of size L:
  ≈ O(L + M_lookup_total + bytes_downloaded)

Target: common "already installed" path is very cheap.

### Today
- Layer 1 local presence is O(1) via the SQLite index (`lookupPrefix`
  hits an index by `prefix_id`).
- Layer 2 advertisement index is in-memory map → O(1) lookup; SWIM +
  cuckoo-filter scaling for the 200-peer convergence test.
- No Layer-3 mirror/index lookup exists.

### Gap
- Server-side index file format that supports O(1) lookup by entry
  key (the cache-info advertised mass-query path).
- Client-side `bakBinaryCacheSubstitute` action enumeration over a
  closure of size L so the scheduler can drive them in parallel up
  to the pool cap.

### Fills it
- **A2** — per-entry SSZ index file at
  `/var/lib/repro-binary-cache/index/<key-prefix>/<key>.idx` giving
  O(1) GET `/manifests/<entry-key>` lookup.
- **A2.5** — `closure_walk.nim` emits one
  `bakBinaryCacheSubstitute` action per closure member; the
  existing build-engine pool drives them topologically.
- **A2.5** — perf gate `t_a2_5_parallel_closure.sh` asserts 8
  concurrent substitution tasks at peak with pool capacity 8.

---

## § Validation Criteria

### Requires
Binary-cache support is validated when:
- Native cache entries verify payload digests, realization metadata,
  and platform/store compatibility before activation.
- Corrupt / missing payloads are rejected, can fall back to rebuild
  / reacquisition.
- External installer identities are recorded as imports, NOT
  republished as native Layer-3 payloads by default.
- Weak external installer behavior changes invalidate / reject
  dependent actions through execution-profile checksum checks.

### Today
- R4 chain walk verifies signatures + per-blob SHA-256 + dep refs
  (the M2-sim 24/24 + R4 AMD64 23/23 baseline this campaign
  preserves).
- No Layer-3 validation criteria are exercised because Layer 3
  doesn't exist.

### Gap
- Integration-test suite that exercises each Validation Criterion
  end-to-end at Layer-3 granularity.

### Fills it
- **A2** — `t_a2_persistence.sh` + `t_a2_signature_verification.sh` +
  `t_a2_closure_compat.sh` + `t_a2_backup_restore.sh` +
  `t_a2_cache_info.sh` — the publish/lookup/verify/restore loop.
- **A3** — `t_a3_substitute_hit_hex0.sh` +
  `t_a3_substitute_hit_gcc_15_2.sh` +
  `t_a3_closure_aware_substitute.sh` + `t_a3_compat_isolation.sh` +
  `t_a3_chain_walk_extended.sh` — substitution behavior end-to-end.
- **A4** — `t_a4_parallel_r5_r6.sh` + `t_a4_in_flight_sentinel.sh` +
  `t_a4_eviction_with_pins.sh` — parallel + eviction behavior.
- The "external installer identities recorded as imports" criterion
  is **out of Phase-A scope** (Phase D / Phase C owns it).

---

## Reuse survey — what A2 / A2.5 / A3 / A4 can lift, NOT reimplement

The single most important point of this matrix: most of the
*primitives* Layer 3 needs already exist in reprobuild. The new code
is mostly wiring. Use the existing modules:

### From the R4 `tools/bootstrap-cache/` flow (specs repo)

- **Envelope shape**. JSON manifest + signed `.sig` sidecar + per-blob
  SHA-256 addressing + chain-walk verifier — this is the conceptual
  template. A3 lifts the schema and re-encodes it in the
  Binary-Caches.md format (SSZ fixed records + CBOR dynamic blocks
  + version-tagged envelope) while preserving the ed25519 signing
  identity.
- **Chain walk**. `tools/bootstrap-cache/test_chain_walk.sh` is the
  conceptual model for the A3 deliverable `tools/binary-cache/walk.sh`
  — same verify-everything-recursively shape, scaled from 23/24
  entries to the full R4–R9 chain (~30+ entries).
- **Trust model**. Single-tenant developer key
  (`reprobuild-team-dev-key`) — Layer 3 reuses this exact identity
  pattern for the v1 implementation.

### From `libs/repro_peer_cache/` (Layer 2)

- **`pki.nim`** — self-signed X.509 v3 cert generation,
  trust-anchor *directory* loader, X.509 verification. Layer-agnostic.
  A2's binary-cache entry signing reuses these primitives; the
  server's trust-anchor directory format reuses the same shape.
- **`auth.nim`** — ECDSA-P256 keypair generation, sign, verify. The
  "ed25519 signature" the campaign spec mentions can be served by the
  ECDSA-P256 primitives already in this module (the campaign spec's
  reference to ed25519 is a vocabulary slip — the BearSSL constraint
  the peer-cache layer uncovered ["BearSSL does not ship EdDSA"]
  applies to Layer 3 too; ECDSA-P256 should be the actual
  asymmetric primitive — flag for A2 review).
- **SSZ-style hand-rolled codec pattern** in
  `libs/repro_peer_cache/src/repro_peer_cache/codec.nim` — the
  pattern A2's `manifest_codec.nim` should follow, matching the
  RunQuota envelope convention rather than pulling in the heavier
  `ssz-serialization` macro path.

### From `libs/repro_local_store/` (Layer 1)

- **`storeCasBlob` / `readCasBlob` / `verifyCasBlob`** — the CAS
  primitives Layer-3 payload objects ride on. NO new store backend.
- **`realizePrefix`** — atomic materialization of a realized prefix
  with the existing `moveFile` + `INSERT OR IGNORE` serialization
  point. Layer 3's "materialize" step reuses this exactly.
- **GC roots** (`registerRoot` / `attachPrefixToRoot` / `gc`) — the
  eviction policy in A4 rides on these.
- **Realization receipt encoding** (`encodeReceipt` /
  `computeRealizationHash`) — the structural template for the
  binary-cache manifest's "realized-prefix identity" + "realization
  metadata" fields.

### From `libs/repro_build_engine/` (Layer 1's scheduler)

- **`BuildPool` with capacity + lease-based execution +
  event-driven wait-loop** — the substrate A2.5 plugs the new
  `bakBinaryCacheSubstitute` action kind into. Per the campaign
  spec: "No new scheduler; just a new task kind."

### Net assessment

Of the work A2 + A2.5 + A3 + A4 lands, roughly:

- **Signing + trust**: 100% reused from peer-cache `pki.nim` +
  `auth.nim`. New code: trust-anchor directory population for the
  binary-cache server's accepted-signers list (a few lines).
- **CAS + materialization + GC**: 100% reused from
  `libs/repro_local_store/`. New code: a thin ingestion adapter
  (`index.nim`).
- **Scheduler**: 100% reused from `libs/repro_build_engine/`. New
  code: the `bakBinaryCacheSubstitute` enum variant + a dispatcher
  hook (~20 lines).
- **Codec pattern**: lift from peer-cache `codec.nim`. New code: the
  Binary-Caches.md-specific manifest record shape + CBOR dynamic
  blocks.
- **HTTP + streaming + decompression**: net new (libcurl + libzstd
  wrappers).
- **Server**: net new (`apps/repro-binary-cache/`).
- **Closure walk + compat checks**: net new.

The point of the matrix: don't build a parallel signing stack, a
parallel CAS, a parallel scheduler, or a parallel GC. All four
already exist and are layer-agnostic enough to reuse.

---

## Out-of-scope items captured here for traceability

- **External installation receipts** (Binary-Caches.md
  §"External Installation Receipts" through §"Weak External
  Installers"). The receipts subsystem is its own design — Phase C
  (foreign-package work) is the natural home. Phase A doesn't touch
  it.
- **Curator-published cross-distro snapshots** that contain external
  imported nodes (Binary-Caches.md §"Mirror And Snapshot Boundary").
  Same — Phase C / Phase D, not Phase A.
- **Open Questions** in Binary-Caches.md §"Open Questions". Phase A
  resolves the first three (manifest format, payload format,
  signing policy) by construction; the last two (repack/export for
  strong external installers; anchor-validation defaults for weak
  external installers) remain open and belong to the external-package
  campaign work.
