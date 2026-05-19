# CMake Generator Competitiveness Benchmark

This suite compares the forked CMake `Reprobuild` generator against CMake's
`Ninja` generator on the same source tree, CMake binary, compiler toolchain,
build type, and target.

The benchmark uses real CMake configure and build commands. Pinned real
projects are read from
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
summaries. Timing thresholds are disabled by default because local timing is
noisy. Set `REPROBUILD_CMAKE_BENCH_MAX_RATIO` or a scenario-specific variable
such as `REPROBUILD_CMAKE_BENCH_MAX_RATIO_CLEAN_BUILD` to turn a ratio into an
enforced gate. The default benchmark parallelism is `1` for stable smoke
coverage; set `REPROBUILD_CMAKE_BENCH_PARALLEL` or pass `--parallel N` for
multi-core competitiveness runs.

Ninja build scenarios collect Ninja's native `-d stats` diagnostics by default.
The benchmark passes these through CMake as native build-tool arguments:
`cmake --build <dir> ... -- -d stats`. Reprobuild scenario command lines are
left unchanged. The report metadata records the selected diagnostics mode, and
each Ninja build scenario includes parsed `ninjaDiagnostics.metrics` entries
with Ninja's metric name, count, average microseconds, and total milliseconds.
These internal timings help separate CMake/Ninja scheduling and dependency
work from Reprobuild-specific overhead when a Reprobuild/Ninja wall-clock ratio
regresses. Pass `--ninja-diagnostics=none` to disable collection for comparing
against Ninja versions with different diagnostic output.
