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
