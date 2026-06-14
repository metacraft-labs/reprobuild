# Reprobuild binary-cache operator handbook

> **Status:** ReproOS-Generations-And-Foreign-Packages A2 — v1
> implementation of the Layer-3 plane defined in
> [`Binary-Caches.md`][bcs] §"Overview". Companion to
> [`THREE-LAYER-TAXONOMY.md`](./THREE-LAYER-TAXONOMY.md) and
> [`BINARY-CACHE-IMPL-GAP-2026-06-14.md`](./BINARY-CACHE-IMPL-GAP-2026-06-14.md).

[bcs]: ../../../reprobuild-specs/Binary-Caches.md

This document is the single audit-grade entry point for an operator
running the `repro-cache` distro on a workstation. It covers:

1. Architecture diagram (text).
2. Threat model (single-tenant; user-owned ECDSA key).
3. Provisioning recipe.
4. Rotation + recovery policy.
5. Reference to Binary-Caches.md sections this implementation
   maps to.

---

## 1 — Architecture (text diagram)

```
+----------------------------+         +-------------------------------+
| Windows host (your laptop) |         | Disposable WSL2 distro:       |
|                            |         |   repro-cache (Ubuntu 22.04)  |
| /mnt/d/metacraft/...       |  <----  | systemd boots                 |
| (mirror destination)       |  rsync  |   * repro-binary-cache.service|
|                            |   5 min |   * repro-binary-cache-rsync  |
|                            |  timer  |     .timer (every 5 min)      |
|                            |         |                               |
|  D:/metacraft/             |         | /var/lib/repro-binary-cache/  |
|    repro-binary-cache-     |   <-->  |   store/                      |
|    backup/                 |         |     (CAS payloads via         |
|      latest -> 2026-06-14  |         |      libs/repro_local_store/) |
|      2026-06-14/           |         |   manifests/<ab>/<key>.manifest|
|      2026-06-13/           |         |   index/cache-info.bin        |
|      ...                   |         |   trust/server-ecdsa-p256.key |
|                            |         |   trust/server-ecdsa-p256.cert|
+----------------------------+         +---------------+---------------+
                                                       |
                                       :7878 HTTP      | bound on 0.0.0.0
                                                       |
                                       +---------------v---------------+
                                       | Clients (other WSL distros,   |
                                       | the Windows host build tools, |
                                       | LAN peers):                   |
                                       |   GET /cache-info             |
                                       |   GET /manifests/<entry-key>  |
                                       |   GET /payloads/<blake3>      |
                                       |   POST /publish (signed mp)   |
                                       +-------------------------------+
```

### Code map

| Concern                  | Code                                                                |
| ------------------------ | ------------------------------------------------------------------- |
| Types + envelope magic   | [`libs/repro_binary_cache_server/src/repro_binary_cache_server/types.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/types.nim) |
| Cache-entry-key derive   | [`libs/.../key.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/key.nim)                              |
| Manifest codec + sign    | [`libs/.../manifest_codec.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec.nim)        |
| On-disk index + CAS adapter | [`libs/.../index.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/index.nim)                       |
| HTTP REST handlers       | [`libs/.../server.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/server.nim)                        |
| Daemon CLI               | [`apps/repro-binary-cache/repro_binary_cache.nim`](../../apps/repro-binary-cache/repro_binary_cache.nim)                      |
| systemd units            | [`recipes/cache/systemd-units/`](./systemd-units/)                                                                            |
| Provisioning             | [`recipes/cache/setup-repro-cache.ps1`](./setup-repro-cache.ps1)                                                              |
| Restore                  | [`recipes/cache/restore-from-backup.ps1`](./restore-from-backup.ps1)                                                          |

### Layer boundary

The binary cache is **Layer 3** per
[`THREE-LAYER-TAXONOMY.md`](./THREE-LAYER-TAXONOMY.md). It is
distinct from:

- **Layer 1** — local build-action cache (`libs/repro_build_engine/`
  + `libs/repro_local_store/`). Per-action memoization; finer
  granularity.
- **Layer 2** — peer cache (`libs/repro_peer_cache/`). Distributed
  *transport* for Layer 1 content blobs on a LAN; same identity
  space.

A2 ships the SERVER side of Layer 3 only. The substitution CLIENT
lives in the planned `libs/repro_binary_cache_client/` per the A2.5
milestone.

---

## 2 — Threat model

| Threat                                              | Mitigation                                                                                                       |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Adversary tampers with on-disk manifest             | ECDSA-P256 signature over the canonical envelope (everything except the trailing 64 sig bytes). Verifier refuses on mismatch. |
| Adversary tampers with a payload bytes              | Manifest declares the payload's BLAKE3-256; client re-hashes the bytes it received and refuses on mismatch.       |
| Adversary tampers with the CacheEntryKey block      | The envelope embeds a redundant BLAKE3-256 of the canonical key. Decoder hard-fails before consuming the manifest if the redundancy check fails. |
| Adversary substitutes a different producer pubkey   | The pubkey is part of the signed envelope. A swap invalidates the signature. The client's trust-anchor allowlist gates the pubkey at the consumer boundary. |
| LAN attacker MITM-injects bytes between server/client | v1 ships as HTTP (single-tenant workstation; loopback / WSL-internal traffic). HTTPS is a documented follow-up; the signature on each manifest is the cryptographic boundary regardless of transport. |
| Cache server compromise leaks the producer key      | Key lives under `/var/lib/repro-binary-cache/trust/server-ecdsa-p256.key`, root-owned and mode-0600. The disposable distro reduces the blast radius; key rotation is the operator's responsibility (and triggers re-signing of every entry — out of scope for v1). |
| Loss of the disposable distro                       | rsync mirror to `/mnt/d/metacraft/repro-binary-cache-backup/` includes the producer key. Restoration via `restore-from-backup.ps1` preserves the signing identity verbatim. |

### Single-tenant scope

The campaign spec is explicit: v1 is "single-tenant; the user's
workstation; trust boundary is the user-owned ECDSA-P256 key. NOT a
publishable production-grade key (which would need HSM + multi-party
ceremony + key-transparency-log integration; same shape as the R4
dev key)."

A federated / multi-tenant deployment would extend the trust anchor
machinery already in
[`libs/repro_peer_cache/src/repro_peer_cache/pki.nim`](../../libs/repro_peer_cache/src/repro_peer_cache/pki.nim) —
the `trust/anchors/` subdir under the cache root is forward-compat for
that. v1 leaves it empty (the server signs with its own key; every
manifest it serves has the same `producerPubKey` field).

### What the cache server does NOT defend against

- Out-of-band compromise of the host kernel: a privileged adversary
  can read the producer key off disk regardless of cipher.
- Supply-chain compromise of a producer's *toolchain*: the cache
  server faithfully publishes whatever was realized, signed or not.
  The `Binary-Caches.md` § "Preferred Publishing Model" stricter
  hermeticity policy is the producer's responsibility; A3 surfaces it
  at the publish boundary.

---

## 3 — Provisioning

### Pre-requisites

- WSL2 working on the Windows host (`wsl --status` reports `Default
  Version: 2`).
- `D:/metacraft/env.ps1` sourced (gives a clean PATH where the
  framework's tools resolve correctly; in particular real `gcc` ahead
  of FPC's i386 gcc per the env.ps1 fix commit).
- A pre-built Linux ELF of `repro_binary_cache`. Build it inside a
  scratch `repro-ubuntu` distro:

  ```bash
  cd /mnt/d/metacraft/reprobuild
  nim c -d:release \
    -o:/tmp/repro_binary_cache-linux \
    apps/repro-binary-cache/repro_binary_cache.nim
  cp /tmp/repro_binary_cache-linux /mnt/d/metacraft-dev-deps/builds/
  ```

### One-shot setup

```powershell
. D:/metacraft/env.ps1
$env:PATH = "D:\metacraft-dev-deps\nim\2.2.8\prebuilt\nim-2.2.8\bin;" + $env:PATH
D:/metacraft/reprobuild/recipes/cache/setup-repro-cache.ps1 `
  -DaemonBinary D:/metacraft-dev-deps/builds/repro_binary_cache-linux
```

The script is idempotent — re-running against an existing
`repro-cache` distro reloads the systemd units + restarts the
service without resetting the producer key. To reset state, pass
`-Force` (DESTROYS the producer key on the distro; the rsync mirror
must be intact for the restore path to recover the signing identity).

### Manual liveness probe

```powershell
wsl -d repro-cache -e systemctl is-active repro-binary-cache.service
# Expect: active

wsl -d repro-cache -e curl -fsS http://localhost:7878/healthz
# Expect: ok

wsl -d repro-cache -e curl -fsS http://localhost:7878/cache-info | xxd | head
# Expect: first 4 bytes spell "RCI1" (the cache-info envelope magic)
```

---

## 4 — Rotation + recovery policy

### Rotation

- The `repro-binary-cache-rsync.timer` fires every 5 minutes inside
  the distro.
- Each fire materialises (or no-ops) the current day's snapshot
  under `D:/metacraft/repro-binary-cache-backup/<YYYY-MM-DD>/`.
- The `latest` symlink in the backup root always points at today's
  snapshot.
- Daily rotation: the helper script
  `repro-binary-cache-rsync-snapshot.sh` keeps the last 7 daily
  snapshots and unlinks older ones at every fire.
- Inter-day deduplication: `rsync --link-dest=PREV` hardlinks
  unchanged files against the previous snapshot so the storage cost
  is roughly the *delta* per day.

### Eviction (in-cache, NOT in-backup)

- **A4 P4 (this campaign):** LRU eviction is implemented in
  `libs/repro_local_store/src/repro_local_store/lru_eviction.nim`
  with a default 50 GiB soft cap + 100 GiB hard cap. See
  [`EVICTION-POLICY.md`](EVICTION-POLICY.md) for thresholds, the
  pin/unpin process, and monitoring.
- Pinned entries listed in [`pinned-entries.txt`](pinned-entries.txt)
  are never evicted. Initial pin set covers hex0, gcc-15.2.0
  (multiple host variants), glibc-2.42, linux-6.6.142-bzImage, and
  systemd-257.9.
- The backup-side retention remains fixed at 7 daily snapshots.

### Recovery time objective

Measured against the disposable `repro-cache` distro setup on a
warm rootfs cache (skip the Ubuntu tarball download):

| Step                          | Wall-clock |
| ----------------------------- | ---------- |
| `wsl --unregister repro-cache` | 1 s        |
| `wsl --import` (cached rootfs) | 12 s       |
| systemd boot                   | 15 s       |
| `apt-get install` runtime deps | 30 s       |
| Snapshot copy (typical 5 GiB)  | 90 s       |
| Service start + smoke check    | 5 s        |
| **Total**                      | **~3 min** |

Cold (rootfs not cached): add ~60 s for the Ubuntu tarball download
on a fast connection.

If `D:/metacraft/repro-binary-cache-backup/` itself was lost (disk
failure), recovery requires re-realizing the R4-R9 chain from
source. The campaign A3 milestone lands the cache-aware build
scripts that make this resumable; today this is the ~5 hr cold-build
cost the campaign is trying to remove.

### Recovery procedure

```powershell
D:/metacraft/reprobuild/recipes/cache/restore-from-backup.ps1 `
  -DaemonBinary D:/metacraft-dev-deps/builds/repro_binary_cache-linux
```

The script:

1. Unregisters the (possibly-broken) `repro-cache` distro.
2. Re-imports a fresh one.
3. Re-installs the systemd units + daemon.
4. Stops the daemon so we can atomically swap state.
5. Copies `D:/metacraft/repro-binary-cache-backup/latest/{store,manifests,index,trust}/`
   into `/var/lib/repro-binary-cache/`.
6. Restarts the daemon and asserts `systemctl is-active` returns
   `active`.

Because the producer key is copied verbatim, all previously-signed
manifests remain verifiable. Pass `-SnapshotName <YYYY-MM-DD>` to
roll back to a known-good earlier snapshot.

---

## 5 — Map to Binary-Caches.md sections

| § in Binary-Caches.md            | Implementation                                                                                                                                       |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| § Cache Entry Identity           | [`key.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/key.nim) — canonical encoder + BLAKE3 digest                            |
| § Binary Cache Entry Contents    | [`types.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/types.nim) `BinaryCacheManifest` / `PayloadObject`                    |
| § Manifest                       | [`manifest_codec.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/manifest_codec.nim) — version-tagged SSZ envelope            |
| § Payload objects                | `PayloadObject` + the underlying CAS store (`libs/repro_local_store/`); compression encoded but A2.5 wires the streaming decompressor              |
| § Preferred Publishing Model     | `POST /publish` handler in [`server.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/server.nim) + multipart parser           |
| § Preferred Consumption Model    | OUT OF A2 SCOPE — A2.5 (`libs/repro_binary_cache_client/`)                                                                                            |
| § Compatibility Checks           | A2 lands signature verify + closure-completeness check; A2.5 adds platform/ABI/store-layout matchers                                                 |
| § Interaction With The Store     | [`index.nim`](../../libs/repro_binary_cache_server/src/repro_binary_cache_server/index.nim) rides on `storeCasBlob` / `realizePrefix` — no new backend |
| § Mirror And Snapshot Boundary   | rsync mirror covers the native cache. Cross-distro snapshot with external imported nodes is OUT OF A2 SCOPE (Phase D)                                |
| § External Implementations       | OUT OF A2 SCOPE (Phase C external installation receipts)                                                                                             |

---

## 6 — Disposable-distro discipline

This is a campaign-wide locked rule (memo
`project_reprobuild_destructive_gate_envs` +
`reference_nixos_wsl_eli`).

- `nixos-main` and `ubuntu-main` are **reserved** names for future
  user-stateful instances. NEVER use them in automation.
- `repro-cache`, `repro-fedora`, `repro-debian`, `repro-ubuntu`,
  `repro-arch`, `repro-alpine`, `repro-opensuse`, and any
  `repro-build-<hex>` distros are **disposable**.
- The `repro-cache` distro is special among the disposable set: it's
  long-lived (rsync backup keeps state safe across loss) but the
  state IS recoverable. Treat it as disposable: don't store anything
  in it that isn't also under the rsync mirror.

Every PowerShell + bash automation in this directory asserts
`$DistroName -ne 'nixos-main' -and $DistroName -ne 'ubuntu-main'` at
entry. The CI gate `D:/metacraft/reprobuild/scripts/run-a2-gate.ps1`
exercises the assert path.
