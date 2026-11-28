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
- CMake cross-project TryCompile reuse benchmark: `just bench_cmake_cross_project_trycompile_reuse`
- Repository contract check: `just check-repo-requirements`
- Regenerate the tree-derived suite artifacts: `just regen-suite-artifacts`

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
- It also runs the composition suites (`rp1`,`rp2`,`rp3`,`rp5b`,`ti1`,`ti3`)
  that emit the provider-runtime / thin-interface gate metrics:
  provider-compile-time (interface mode vs full mode), provider-session
  round-trip (warm/cold), cold-vs-warm consumer build, resource-op round-trip
  (warm/cold), interface-lift (cold materialize vs cache HIT), and the
  fingerprint-split downstream-invalidation asymmetry. The default suite set is
  `m0,m23,cmake,rp1,rp2,rp3,rp5b,ti1,ti3`; override with `REPROBUILD_BENCH_SUITES`.
  All composition suites are self-contained (no external incus/network).
- CMake benchmark targets require sibling checkouts of `../runquota` and
  `../reprobuild-cmake`; benchmark CI checks out and builds those siblings.
- Before optimizing anything, read
  [Profiling-For-Optimization.md](docs/agents/Profiling-For-Optimization.md):
  what to measure, what invalidates a measurement, and why a faster version of
  a computation is not always the same computation. Its first principle is the
  one to internalize — ask whether a step needs to run at all before asking how
  to make it faster.

## Boundaries

- Reprobuild consumes RunQuota through protocol/client/helper APIs. Do not vendor
  RunQuota into this repository.
- Workspace source revisions come from workspace lock files, not repo-local
  sibling pin files.
- JSON may be emitted for inspection and benchmark output, but it must not be
  used as an on-disk source of truth.
- The four tree-derived suite artifacts — `repro_tests.nim`,
  `scripts/reprobuild-test-shape-parity.tsv`,
  `scripts/reprobuild-suite-static-case-counts.tsv` and
  `benchmarks/reports/reprobuild-suite-m0-inventory-sources.json` — are
  `-merge` in `.gitattributes`. When a merge, rebase or cherry-pick leaves one
  of them unmerged, run `just regen-suite-artifacts` and `git add` the result.
  Never pick a side, never hand-edit, and never reach for `-X ours`/`-X theirs`
  or `--strategy=resolve` to get past it: their correct value is a function of
  the merged tree, so any resolution that is not a regeneration is a fabricated
  document that fails a gate later, on someone else's branch. See the block at
  the top of `.gitattributes`.
- A change that adds, removes or renames a test case regenerates them in the
  same commit. The dev shell installs a `pre-push` hook
  (`scripts/pre_push_suite_checks.sh`, from `.pre-commit-config.yaml`) that
  runs the build-free suite checks on the pushed commit and refuses on drift;
  on `agents`, which has no CI, it is the gate. When it refuses over drift you
  inherited from the branch you rebased onto, regenerate in a `chore(tests)`
  commit of its own, never folded into an unrelated change. Do not push past
  it with `--no-verify`.
- A change to a source of the generated user docs — the CLI description in
  `libs/repro_cli_support/src/repro_cli_support/cli_description.nim`, the
  health checks, the installers, or the front matter under
  `docs/users/content/` — runs `python3 scripts/render_user_docs_generated.py`
  and commits the result in the same commit. The same `pre-push` hook runs
  its `--check` on the pushed commit and refuses a stale page; drift you
  inherited is regenerated in a `chore(docs)` commit of its own.
