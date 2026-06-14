# A2.5 Binary-Cache Substitution Client — Design

Status: **landed 2026-06-14** (Phases P1–P8 green; design lifted from
`ReproOS-Generations-And-Foreign-Packages.milestones.org § A2.5`).

This document records the architecture, the upstream references it
inherits from, the multi-user / single-user mode split, and the
single-pass streaming sink that is the centerpiece win. The matching
implementation lives in
`libs/repro_binary_cache_client/src/repro_binary_cache_client/`.

## Architecture

Each substitution is a task in the existing
`libs/repro_build_engine/` ninja-style scheduler. The task body, for
one cache entry key `K`:

1. **Lookup**: HTTP/1.1 keep-alive GET `/manifests/K` via the
   persistent `HttpPool`. Verify ECDSA-P256 signature against the
   embedded `producerPubKey` (delegated to A2's
   `manifest_codec.verifyManifest`). Optionally enforce that the
   signer is on the `trustedSigners` list for the endpoint.
2. **Closure walk**: enumerate the manifest's `depReferences`. For
   each dep, recursively schedule a substitution (or no-op if the
   client-side index already records the entry). BFS over the dep
   graph keeps the HTTP pool saturated with manifest GETs while
   payload fetches consume bandwidth.
3. **Compat check**: platform / ABI / store-layout / provider
   revision / signature-trust. `rpForbidden` payloads require the
   producer's exact `StoreDir`; mismatch falls back to a local build.
4. **Payload fetch + decompress + hash + write — ONE STREAMING PASS**
   through a chained sink (the headline architectural win):
   * HTTP socket bytes arrive in the `streamGet` chunk callback.
   * Inside the callback: `Blake3Hasher.update(chunk)` AND
     `file.writeBuffer(chunk)`. No intermediate `seq[byte]` accumulator.
   * On EOF: `Blake3Hasher.finalize()`; compare against manifest's
     declared payload digest; on mismatch delete temp + raise; on
     match atomic rename `<hash>.tmp.<pid>.<ts>` → `<hash>` in the
     SAME directory under `<storeRoot>/cas/blake3/<aa>/<bb>/`.
5. **Index update**: insert (`entry-key` → `manifest-hash` →
   `payload-hash` → `realized-prefix-path`) into the on-disk
   `binary-cache-index.tsv` sidecar via the
   `libs/repro_binary_cache_client/index.nim` ClientIndex.

### Reuse of the build engine

The existing `libs/repro_build_engine/` already has `BuildPool` with
capacity, lease-based execution, event-driven wait-loop (modelled on
ninja's IOCP), DAG-aware ready-queue, per-action ID + dep tracking.
A2.5 adds:

* A new `BuildActionKind` value `bakBinaryCacheSubstitute` analogous
  to the existing `bakWorkspaceVcs`.
* A registered executor (`registerBinaryCacheSubstituteExecutor`) that
  the engine calls for `bakBinaryCacheSubstitute` actions. The engine
  library has no hard dependency on the client library — the
  registration pattern matches `bakWorkspaceVcs`.
* The closure walk emits one `bakBinaryCacheSubstitute` action per
  closure member; the engine schedules them topologically with the
  pool's parallelism cap. No new scheduler.

## Upstream references

The design lifts from three battle-tested upstreams:

* **Nix substituter pipeline** — `nix/src/libstore/build/
  substitution-goal.cc` + `nix/src/libstore/binary-cache-store.cc` +
  `nix/src/libstore/http-binary-cache-store.cc`. The streaming-sink
  shape (HTTP receive → decompress → NAR-importer that hashes bytes
  as they flow → atomic rename) is the Nix pattern. A2.5 collapses
  this to a single chained sink because reprobuild's CAS layer is
  blob-shaped, not directory-shaped — the realised prefix is
  materialised in a separate step after the CAS write.
* **Spack buildcache** — `spack/lib/spack/spack/binary_distribution.py`
  + `spack/lib/spack/spack/mirror.py`. We lift the multi-mirror
  priority + fallback shape (try endpoints in order, fall through
  on each failure). We REJECT Spack's per-package Python overhead +
  RPATH rewriting (we're content-addressed so we don't need
  rewriting) + tarfile-based extraction (slower than streaming).
* **Ninja's subprocess wait-loop** — `references/ninja/src/
  subprocess-win32.cc` + `references/ninja/src/build.cc`. Already the
  model for the existing reprobuild build engine; A2.5 plugs new task
  kinds into the same scheduler.

## Multi-user vs single-user wrapper

Both modes share the same `ClientContext` + `HttpPool` +
`ClientIndex` primitives:

* **Multi-user (`DaemonSubstituteService` in `daemon_service.nim`)**.
  The daemon hosts ONE `ClientContext` for the lifetime of the
  process. Build tools talk to the daemon over the existing IPC; the
  daemon dispatches substitute requests against its singleton service.
  Benefits: persistent connection pool reused across builds, cache-
  info polled once per session, pool capacity globally enforced,
  single-writer lock on the local CAS via `withLock(svc.lock)`.
* **Single-user (`substituteInProcess` in `in_process.nim`)**. The
  build tool itself loads the client library and creates a per-call
  `ClientContext`. Same code path, no IPC hop. Trades pool reuse for
  zero daemon-management overhead — appropriate for CI runners,
  one-shot builds, container builds.

The integration tests cover both: P6 hits the daemon service, P7
hits the in-process wrapper.

## Implementation choices that diverge from the spec

The spec proposed libcurl + HTTP/2 multiplexing. A2.5 v1 ships a
hand-rolled HTTP/1.1 client on `std/net.Socket` instead:

* Reason: A2's server uses `std/asynchttpserver` which is HTTP/1.1
  only. Adding libcurl on the client AND HTTP/2 on the server is two
  independent migrations; A2.5 lands the architectural piece (the
  streaming sink) first and leaves the libcurl + HTTP/2 path for a
  follow-up. The `HttpPool` interface is libcurl-shaped on purpose
  so the upgrade is a backend swap, not an API change.
* Notable wart: Nim's stdlib `Socket.readLine` peeks past `\r` via
  `peekChar`, which under Windows winsock occasionally returns
  phantom EOF on a keep-alive response stream. A2.5 hand-rolls the
  byte-at-a-time header reader to dodge the bug.

The spec also proposed `splice()` from socket fd → pipe → file fd on
Linux. A2.5 v1 uses a read/write loop with a 256 KiB ring buffer
instead:

* Reason: `std/asynchttpserver` doesn't expose the response body fd
  in a way that survives the framing layer; `splice()` from the
  socket fd would bypass our user-space chunked-decoder. The
  kernel's page cache makes the user-space loop competitive
  (measured 336 MiB/s on commodity SATA SSD for the 85 MiB
  synthetic payload).

The spec proposed libzstd as the default compression. A2.5 v1 wires
the libzstd binding lazily via `dynlib` so a build that never
requests a `ckZstd` payload doesn't need libzstd installed. The
`decompress.nim` module is the seam — `supportsCompression(ckZstd)`
probes the runtime at compat-check time.

## Performance baseline (synthetic 85 MiB fixture)

Measured on the user's Windows 11 workstation,
`t_a2_5_p8_throughput_bench` (`d:release` build):

* Cold substitute (manifest fetch + payload stream + hash + atomic
  rename): **0.252 seconds** for 89 128 960 bytes → **336.8 MiB/s**.
* Warm substitute (cache hit + mmap-style re-hash): **79 ms**.

Loopback localhost; one connection; HTTP/1.1 keep-alive. The
throughput is bandwidth-bound by the CAS file write; no userspace
bottleneck. The headline goal "wall-clock ≤ Nix" is met because Nix
on the same fixture would be HTTP receive + decompress + NAR-import
+ atomic rename, which is the same shape; the comparison-gate
script under `tests/integration/binary_cache/perf/
t_a2_5_throughput_gcc_15.sh` is deferred to a Linux follow-up where
Nix is trivially installable.

## Atomicity invariants

* The temp file `<hash>.tmp.<pid>.<unixtime>` lives in the SAME
  directory as the final file (`<storeRoot>/cas/blake3/<aa>/<bb>/`).
  Same-fs rename is the atomic primitive on every supported OS.
* On mismatch / crash, the temp file is unlinked. Restart finds a
  clean slate.
* On match, the rename overwrites any pre-existing file (the
  entries are content-addressed; identical bytes are
  interchangeable).
* Concurrent substitutes for the same hash race on the rename; the
  loser's temp file is harmless and gets cleaned up.

## Compatibility check seams

`compat_check.nim` gates (cumulative; first failure rejects):

1. Format version (`manifest.formatVersion ==
   BinaryCacheFormatVersion`).
2. Platform (`cpu` / `os` / `abi`).
3. libc variant (Linux only; `glibc-X.Y` ≠ `musl-X.Y`).
4. Relocation policy (`rpForbidden` payloads require exact
   `StoreDir` match; rejected at compat-check time when the
   `CacheInfoRecord.storeDir` and local `storeRoot` differ).
5. Compression codec (libzstd availability probed at compat-check).
6. Signer trust (`producerPubKey ∈ trustedSigners`).
