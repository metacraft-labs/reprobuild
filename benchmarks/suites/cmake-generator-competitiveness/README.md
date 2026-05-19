# CMake Generator Competitiveness Benchmark

This suite compares the forked CMake `Reprobuild` generator against CMake's
`Ninja` generator on the same source tree, CMake binary, compiler toolchain,
build type, and target.

The benchmark uses real CMake configure commands and can measure build steps in
two execution modes. `cmake-driver` invokes `cmake --build <dir>` so the
forked CMake launcher participates in each build. `direct` invokes the native
tools after generation: `ninja -C <dir>` for Ninja and `repro build
<dir>#<target>` for Reprobuild. The default `--execution-mode=both` configures
separate build trees for both modes so source edits and Reprobuild cache state
from one mode do not affect the other mode.

Pinned real projects are read from
`../reprobuild-cmake/Tests/RunCMake/ReprobuildGenerator/real-project-locks.cmake`
so source identity remains shared with the M11 real-project matrix. The local
generated fixture in `benchmarks/fixtures/cmake-generated-custom-command`
covers generated-source/custom-command rebuild behavior.

Default coverage:

- `zlib` clean, no-op, post-clean/cache-hit, and single-source incremental
  rebuild.
- `fmt` clean, no-op, post-clean/cache-hit, and single-source incremental
  rebuild.
- `nlohmann_json` configure/build/no-op behavior only; it is header-only and is
  not compile-performance proof.
- generated custom-command fixture clean, no-op, source incremental, and
  custom-command input rebuild.

Medium opt-in coverage adds pinned `libuv`.

Reports are written under `bench-results/` as structured JSON with machine,
toolchain, command status, wall-clock timings, and Reprobuild/Ninja ratio
summaries. Every build and ratio record includes `executionMode` so the CMake
driver and direct native paths can be compared separately. Timing thresholds
are disabled by default because local timing is noisy. Set
`REPROBUILD_CMAKE_BENCH_MAX_RATIO`, a scenario-specific variable such as
`REPROBUILD_CMAKE_BENCH_MAX_RATIO_CLEAN_BUILD`, or a mode-and-scenario variable
such as `REPROBUILD_CMAKE_BENCH_MAX_RATIO_DIRECT_NOOP_REBUILD` to turn a ratio
into an enforced gate. The default benchmark parallelism is `1` for stable
smoke coverage; set `REPROBUILD_CMAKE_BENCH_PARALLEL` or pass `--parallel N`
for multi-core competitiveness runs.

Ninja build scenarios collect Ninja's native `-d stats` diagnostics by default.
In `cmake-driver` mode the benchmark passes these through CMake as native
build-tool arguments: `cmake --build <dir> ... -- -d stats`. In `direct` mode
the same diagnostics are passed directly to Ninja. Reprobuild build scenarios
collect `repro build --stats` diagnostics by default via `REPROBUILD_STATS=1`;
direct mode also passes `--stats` explicitly. The report metadata records the
selected diagnostics modes, and each build scenario includes parsed
`ninjaDiagnostics.metrics` or `reprobuildDiagnostics.metrics` entries with the
metric name, count, average microseconds, and total milliseconds.

The benchmark wrapper rebuilds `build/bin/repro` with
`REPROBUILD_BUILD_MODE=release` before running measurements. These internal
timings help separate CMake/Ninja scheduling and dependency work from
Reprobuild-specific overhead when a Reprobuild/Ninja wall-clock ratio
regresses. Pass `--ninja-diagnostics=none` or
`--reprobuild-diagnostics=none` to disable collection.
