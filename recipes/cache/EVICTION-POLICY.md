# Binary-cache eviction policy

## Goals

The repro-binary-cache server's CAS directory grows monotonically as
producers publish new entries. Without eviction the on-disk footprint
would consume every byte of the host's storage budget within weeks.
The policy below keeps the footprint bounded while never sacrificing
the bootstrap-critical entries (hex0, gcc, glibc, kernel, systemd).

## Caps

The eviction policy enforces two caps:

  * **Soft cap (default 50 GiB).** After every successful publish,
    if the on-disk footprint exceeds this value the policy evicts
    the oldest unpinned blobs (by mtime ascending) until the
    footprint is back below cap. Asynchronous: the publish completes
    BEFORE the eviction sweep runs so the publishing client doesn't
    pay the eviction cost in its request latency.
  * **Hard cap (default 100 GiB).** Synchronous. The publish handler
    rejects an incoming write whose projected post-publish footprint
    would exceed this value. The producer sees a structured `507
    Insufficient Storage` response. The projection is conservative:
    the handler sums the byte sizes of the multipart `payload` parts
    BEFORE any `storeCasBlob` call, so a rejection leaves the
    on-disk footprint unchanged. The conservativeness double-counts
    a duplicate payload that is already in the CAS — this is
    intentional, so an attacker can't trickle-publish duplicates to
    keep the daemon arbitrarily close to its hard cap without
    triggering a cap response. A future milestone may switch to a
    dedup-aware projection when the threat-model gate relaxes.

Operators tune the caps via environment variables on the
`repro-binary-cache` daemon:

  * `REPRO_BINARY_CACHE_SOFT_CAP_BYTES` (default `53687091200`)
  * `REPRO_BINARY_CACHE_HARD_CAP_BYTES` (default `107374182400`)

## LRU ordering

The policy uses each CAS blob's filesystem **mtime** as the
last-access proxy. This is deliberately conservative — atime is
unreliable on Windows + on Linux mounted with `noatime` (a common
SSD-life optimisation). On both platforms `mtime` is set when the
blob is written, then refreshed by `touchBlob` whenever a successful
substitute reads the blob. The eviction sweep walks the CAS shard
directories once per call and sorts the per-blob list by mtime
ascending; blobs are evicted from the head of the sorted list until
the soft cap is met.

## Pin protection

The file `recipes/cache/pinned-entries.txt` lists pinned entries (one
hex per line; `#` comments tolerated; case-insensitive). Pinned
entries are NEVER evicted, even when they are the oldest unpinned
blobs in the store. The initial set covers the R4-R9 bootstrap
chain — re-bootstrapping any of these from scratch is expensive
(hex0 requires the upstream stage0-posix repository; gcc-15.2.0
takes ~90 min wall-clock per host variant; kernel + systemd are
~25-30 min combined).

### Adding / removing pins

To pin a new entry:

  1. Resolve its binary-cache entry-key hex (e.g. via
     `repro-binary-cache-client derive-key`).
  2. Walk its manifest to extract the CAS payload digests.
  3. Append each digest (or the entry-key hex; both forms are
     accepted) to `pinned-entries.txt` with a comment line above.
  4. Reload the daemon (signal-driven, no restart required —
     TODO: wire `SIGHUP` to the daemon's pin-list reload path).

To unpin an entry: delete its line from `pinned-entries.txt` and
reload the daemon. The next eviction sweep may evict the entry if it
is now the oldest unpinned blob and the cap is exceeded.

## Monitoring

The policy exposes a structured report on each eviction sweep:

```
LruEvictionReport
  bytesBefore       int64
  bytesAfter        int64
  evictedCount      int
  evictedBytes      int64
  evictedKeys       seq[string]    # hex digests evicted (in order)
  skippedPinned     int            # count of pinned-blob skips
```

The daemon logs this report to stderr at INFO level after every
sweep. The metrics endpoint (TODO; sitting beside the existing
healthz route) will surface the same numbers as a Prometheus gauge:

  * `repro_binary_cache_footprint_bytes`
  * `repro_binary_cache_evictions_total{reason="soft_cap"}`
  * `repro_binary_cache_pinned_blob_count`

Operators alert on `footprint_bytes` approaching the hard cap and
on `evictions_total` rate-of-change spikes (a publisher loop bug
would manifest as continuous evictions).

## Threat model

The pin list is a privileged file: a tampered entry that pinned a
non-existent (or attacker-controlled) digest would let stale or
malicious bytes survive indefinitely. The file MUST be owned by
the daemon's user with mode `0600`; deployment scripts under
`recipes/cache/setup-repro-cache.ps1` set the permission during
provisioning.

## See also

  * `libs/repro_local_store/src/repro_local_store/lru_eviction.nim` —
    the policy implementation.
  * `libs/repro_local_store/tests/t_a4_p4_eviction.nim` — the unit
    test gate.
  * `tests/integration/binary_cache/t_a4_p5_parallel_closure.sh` —
    the integration gate for the parallel-build workload that the
    eviction policy keeps tractable in production.
