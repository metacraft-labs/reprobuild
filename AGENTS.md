# Reprobuild Agent Instructions

## Commands

- Build: `just build`
- Test: `just test`
- Lint: `just lint`
- Format: `just format`
- Quick benchmark smoke: `just bench-quick`
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

## Boundaries

- Reprobuild consumes RunQuota through protocol/client/helper APIs. Do not vendor
  RunQuota into this repository.
- Workspace source revisions come from workspace lock files, not repo-local
  sibling pin files.
- JSON may be emitted for inspection and benchmark output, but it must not be
  used as an on-disk source of truth.
