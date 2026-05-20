# Reprobuild Agent Instructions

## Commands

- Build: `just build`
- Test: `just test`
- Lint: `just lint`
- Format: `just format`
- Full benchmark suite: `just bench`
- Quick benchmark suite: `just bench --quick` or `just bench-quick`
- Core Reprobuild/RunQuota production benchmark: `just bench_reprobuild_core_mvp_performance`
- CMake Reprobuild vs Ninja benchmark: `just bench_cmake_reprobuild_vs_ninja`
- CMake Reprobuild vs Ninja quick benchmark: `just bench_cmake_reprobuild_vs_ninja_quick`
- CMake Reprobuild vs Ninja medium benchmark: `just bench_cmake_reprobuild_vs_ninja_medium`
- Repository contract check: `just check-repo-requirements`

## Structure

- `libs/` contains importable Nim libraries. App binaries must not own shared
  build, cache, scheduler, monitor, or DSL behavior.
- `apps/` contains thin executable entry points listed in
  `apps/entrypoints.txt`.
- `tests/` contains repository-level tests. Library-local tests live under each
  library once implementation starts.
- `benchmarks/` contains repeatable benchmark suites and reporting helpers.
- `docs/` contains public documentation for contributors and users.

## Benchmarks

- `just bench` writes github-action-benchmark JSON to
  `bench-results/benchmark_results.json` and the self-contained HTML report to
  `bench-results/report.html`.
- `just bench --quick` is the CI/local abbreviated policy suite. It runs the M0
  smoke metrics and the Reprobuild/RunQuota production benchmark; it also runs
  the CMake Reprobuild-vs-Ninja quick benchmark when
  `../reprobuild-cmake/build/bin/cmake` is available.
- CMake benchmark targets require sibling checkouts of `../runquota` and
  `../reprobuild-cmake`; benchmark CI checks out and builds those siblings.

## Boundaries

- Reprobuild consumes RunQuota through protocol/client/helper APIs. Do not vendor
  RunQuota into this repository.
- Workspace source revisions come from workspace lock files, not repo-local
  sibling pin files.
- JSON may be emitted for inspection and benchmark output, but it must not be
  used as an on-disk source of truth.
