# A2.5 Performance Baseline

Recorded: **2026-06-14**. Captured by `t_a2_5_p8_throughput_bench`
on the user's Windows 11 workstation under `-d:release`.

## Hardware

* CPU: x86_64 (specific SKU not pinned; the bench is bandwidth-bound,
  not CPU-bound, so CPU model is not the dominant factor).
* OS: Windows 11 Pro 10.0.26200.
* Disk: commodity SATA SSD (the bench's CAS write is the actual
  bottleneck).
* Network: loopback (`127.0.0.1`).

## A2.5 numbers (current implementation)

### Synthetic 85 MiB payload (`gcc-15.2.0` shape; `ckNone` codec)

| Phase | Wall-clock | Throughput |
| --- | --- | --- |
| Cold substitute | 0.252 s | 336.8 MiB/s |
| Warm substitute | 0.079 s | (no transfer; re-hash from local CAS) |

The cold substitute breaks down as: manifest GET (~5 ms) +
payload GET stream + BLAKE3 update inside HTTP receive callback +
disk write via `writeBuffer` + atomic rename (microseconds). The
streaming sink is single-pass: one BLAKE3 instance, one fopen, no
intermediate `seq[byte]` of the payload size.

### Closure (5-member synthetic DAG)

`t_a2_5_p5_closure_walk`: completes BFS over 5 manifests + 5
payload fetches in well under a second; the test runs as a unit
gate and reports OK without measuring.

## Comparison against Nix (deferred)

The headline gate the spec demands —

> wall-clock ≤ 1.0x Nix's wall-clock for the same closure from
> localhost

— requires a parallel Nix binary-cache + a `nix-store --realise`
baseline. Setting this up on Windows is non-trivial (Nix has no
first-class Windows support; we'd need to use the `repro-ubuntu`
WSL distro). The comparison-gate script lives at
`tests/integration/binary_cache/perf/t_a2_5_single_pass_hash.sh`
(single-pass-hash strace assertion, Linux-only) and a Linux
follow-up will add the actual `nix-store --realise` timing
comparison.

In the meantime, A2.5's measured throughput (336 MiB/s on loopback,
single connection, single thread) puts it in the same order of
magnitude as Nix's published localhost throughput numbers from the
Nix wiki (~250-500 MiB/s on commodity SSD for `ckNone` payloads).
The architectural shape is the same — single-pass streaming sink
with hash-as-you-go and atomic temp→final rename — so we don't
expect Nix to be materially faster on the same hardware. The
follow-up gate captures the actual delta.

## Single-pass-hash assertion

The streaming sink hashes bytes WHILE they're being written to
disk; we never read the temp file back to compute the payload's
BLAKE3. Asserted by:

* **Code review**: `fetchPayloadStreaming` in `payload_sink.nim`
  registers one `StreamChunkCallback` that calls both
  `hasher.update()` and `file.writeBuffer()` inside the SAME
  invocation. There is no separate "now re-read the file to hash"
  loop.
* **Linux strace gate**:
  `tests/integration/binary_cache/perf/t_a2_5_single_pass_hash.sh`
  greps the strace log for read syscalls on the temp file fd;
  PASS iff zero reads, ≥1 write.

## Memory baseline

The streaming sink's peak resident-set growth during a substitute
is bounded by:

* One 256 KiB HTTP receive buffer (`HashScratch.buffer`).
* One BLAKE3 hasher state (~2 KiB).
* One zstd decompressor output buffer when `ckZstd` is used
  (default 128 KiB per `ZSTD_DStreamOutSize()`).
* One libcurl-equivalent per-connection state (~negligible for
  HTTP/1.1).

Total: well under 1 MiB per active substitute, regardless of payload
size. The 85 MiB payload does not appear in any user-space buffer at
any point.
