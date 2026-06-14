# Cache Key Schema

> **Status:** A3 P1 deliverable for the
> [ReproOS-Generations-And-Foreign-Packages campaign][campaign].
> Documents the canonical encoding rules used to derive a 32-byte
> BLAKE3-256 cache-entry-key from a structured ``CacheEntryIdentity``
> tuple.

[campaign]: ../../../reprobuild-specs/ReproOS-Generations-And-Foreign-Packages.milestones.org
[binary-caches]: ../../../reprobuild-specs/Binary-Caches.md

---

## Where this lives in code

- Public API: `libs/repro_binary_cache_client/src/repro_binary_cache_client/cache_key.nim`
- Canonical encoder: `libs/repro_binary_cache_server/src/repro_binary_cache_server/key.nim`
- Gate: `libs/repro_binary_cache_client/tests/t_a3_p1_cache_key.nim`

## The identity tuple (Binary-Caches.md § Cache Entry Identity)

```nim
type CacheEntryIdentity = object
  packageName*: string         # e.g. "hex0", "gcc"
  packageVersion*: string      # e.g. "0.1.0", "15.2.0"
  selectedOptions*: TableRef[string, string]
  platform*: PlatformTriple    # cpu / os / abi / libcVariant
  toolchain*: ToolchainIdentity
                               # name / version / hostLdSoAbi /
                               # extraFingerprint
  depClosure*: seq[string]     # sorted-or-unsorted dep entry-key hex
  providerRevision*: string    # sha256 of the recipe / provider script
```

## Canonical encoding rules

The encoder ``key.encodeCacheEntryKey`` produces a little-endian byte
sequence with the following shape:

```
u16-le formatVersion (== 1)
u32-le len || utf-8 bytes      packageName
u32-le len || utf-8 bytes      packageVersion
u32-le count
  for each option (SORTED by name lexicographically):
    u32-le len || name bytes
    u32-le len || value bytes
PlatformTriple:
  u32-le len || cpu
  u32-le len || os
  u32-le len || abi
  u32-le len || libcVariant
ToolchainIdentity:
  u32-le len || name
  u32-le len || version
  u32-le len || hostLdSoAbi
  u32-le len || extraFingerprint
32 bytes depClosureDigest      (BLAKE3-256 of the closure)
u32-le len || providerRevision
```

The 32-byte BLAKE3-256 digest of this byte sequence is the on-wire
``cacheEntryKey``. The lowercase-hex rendition (64 chars) is the URL
component on ``GET /manifests/<hex>``.

## Dep-closure normalisation

Before hashing the closure list:

1. Lowercase every dep hex.
2. Sort lexicographically.
3. De-duplicate adjacent equal values.
4. Encode as `u32-le count || (u32-le hex_len || hex bytes) per entry`.
5. BLAKE3-256 over the encoded bytes -> ``depClosureDigest``.

The closure digest is a single 32-byte field of the canonical
encoding, so a deep closure folds into a fixed-size key block.

## Determination rules per R4-R9 phase

Each ``build-*.sh`` script in
``recipes/bootstrap/{tcc-chain,kernel,systemd}/scripts/`` carries a
small identity-flag block that feeds the CLI:

```bash
cache_phase_prepare "${BASH_SOURCE[0]}" "${OUT_ABS}" \
  --package-name=<pkg> \
  --package-version=<ver> \
  --toolchain-name=<chain-name> \
  --toolchain-version=<chain-version> \
  --dep=<prev-phase-key-hex> ...
```

The ``cache_phase_prepare`` helper layers in three host-derived fields
that every R4-R9 phase shares:

- ``--toolchain-host-ldso``: from ``REPRO_HOST_LDSO_ABI``, defaults
  to ``glibc-host``.
- ``--toolchain-extra=host_gcc=<ver>``: ``gcc --version`` of the
  host toolchain. The R8 caveat "byte stability is conditional on
  host gcc 11.x" lives here — flipping to host gcc 13.x flips the
  cache key.
- ``--provider-revision``: sha256 of the build script itself. Any
  change to the script body (env flags, source pinning, build flow)
  flips the key.

Platform defaults to the host's ``uname -s`` (linux/darwin/windows)
with the matching ABI (gnu/empty/msvc); ``REPRO_HOST_OS`` /
``REPRO_HOST_ABI`` override.

## Hard invariants

- **Two entries that are not interchangeable at runtime MUST NOT
  share one cache key.** Enforced by including every field above in
  the canonical encoding.
- **Sort-order invariance.** Options are sorted by name before
  encoding; insertion order does not perturb the derived key.
- **Determinism.** Identical identity tuples produce byte-identical
  canonical encodings and therefore byte-identical 32-byte digests.

## Compat-isolation gate

`tests/integration/binary_cache/t_a3_compat_isolation.sh` exercises
the host-toolchain flip directly:

```
K_A = derive(host_gcc=11.4.0, host_ldso=glibc-2.35)
K_B = derive(host_gcc=13.2.0, host_ldso=glibc-2.39)
assert K_A != K_B
```

Both cache entries coexist in the binary cache; a client running on
a host-gcc-11.4 workstation gets K_A, and a host-gcc-13 client gets
K_B. Neither can accidentally substitute the other's bytes.
