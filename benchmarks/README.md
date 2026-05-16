# Reprobuild Benchmarks

Run `just bench-quick` for the abbreviated M0 benchmark suite or `just bench`
for the full M0 suite. The M0 suite measures real repository operations:
source enumeration, focused Nim checks, and full local gates in non-quick mode.

Run `just bench_reprobuild_core_mvp_performance` for the M23 production
benchmark gate. This gate uses generated workloads, but the measured paths are
real Reprobuild and RunQuota components: the build-engine scheduler, local
action cache, sibling RunQuota daemon and process helper, and the macOS
`repro-fs-snoop` monitor path when available. Unsupported monitor platforms
emit structured advisory metadata instead of synthetic monitor measurements.

Outputs:

- `bench-results/benchmark_results.json`
- `bench-results/report.html`
- `bench-results/reprobuild-core-mvp-performance.json`
- `bench-results/history/reprobuild-core-mvp-performance.latest.json`
