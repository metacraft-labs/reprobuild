# Reprobuild Benchmarks

Run `just bench-quick` for the abbreviated M0 benchmark suite or `just bench`
for the full M0 suite. The M0 suite measures real repository operations:
source enumeration, focused Nim checks, and full local gates in non-quick mode.

Run `just bench_reprobuild_core_mvp_performance` for the M23 production
benchmark gate. This gate uses generated workloads, but the measured paths are
real Reprobuild and RunQuota components: the build-engine scheduler, local
action cache, sibling RunQuota daemon and process helper, and the macOS
`repro internal io monitor` path when available. Unsupported monitor platforms
emit structured advisory metadata instead of synthetic monitor measurements.

Run `just bench_cmake_reprobuild_vs_ninja` to compare the forked CMake
`Reprobuild` generator with CMake's `Ninja` generator on pinned real projects
from the CMake M11 lock file plus a generated-source fixture. Use
`just bench_cmake_reprobuild_vs_ninja_quick` for a shorter smoke profile and
`just bench_cmake_reprobuild_vs_ninja_medium` to add the pinned `libuv` medium
project. These benchmarks record timing ratios by default; set
`REPROBUILD_CMAKE_BENCH_MAX_RATIO` or a scenario-specific ratio environment
variable to make timing thresholds enforced. By default the CMake generator
benchmark measures both `cmake --build` driver executions and direct native
tool executions after generation; pass `--execution-mode=cmake-driver` or
`--execution-mode=direct` to narrow a run.

Run `just bench_cmake_cross_project_trycompile_reuse` for the
`cross_project_trycompile_reuse` scenario (Cache-Scope Phase 1): project A is
configured against a fresh action cache, project B against the same cache, and
B is compared with B configured against an empty cache. It reports the
action-cache hit rate of B's TryCompile builds, counted from the `actions`
tally each `repro build` writes into `$REPRO_STATS_DIR`, and the wall-time
saving with its spread over `--cross-project-runs` samples. Add pairs with
`--cross-project-pair A:B`; the medium profile runs `zlib:libuv` by default.
Set `REPROBUILD_CMAKE_BENCH_MIN_CROSS_PROJECT_HIT_RATE` to enforce a hit rate.
The scenario defaults `REPRO_DAEMON=off` for the configures it measures. On
Windows, keep `--work-root` short: CMake and the engine add about 200
characters below each TryCompile's build directory.

Outputs:

- `bench-results/benchmark_results.json`
- `bench-results/report.html`
- `bench-results/reprobuild-core-mvp-performance.json`
- `bench-results/history/reprobuild-core-mvp-performance.latest.json`
- `bench-results/cmake-reprobuild-vs-ninja-default.json`
- `bench-results/cmake-reprobuild-vs-ninja-quick.json`
- `bench-results/cmake-reprobuild-vs-ninja-medium.json`
- `bench-results/cmake-cross-project-trycompile-reuse.json`
