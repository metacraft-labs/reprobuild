# Reprobuild

> **Status:** M0 repository skeleton

**Reprobuild** (CLI: `repro`) is a unified build system combining reproducible environments, automatic dependency discovery, incremental rebuilds with artifact caching, and distributed execution.

This repository is the public `metacraft-labs/reprobuild` product repository.
M0 establishes the local repository shape, app entry point manifests, policy
checks, and compileable Nim skeletons that later milestones build on.

## Commands

- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.
- `just bench-quick` exercises the benchmark reporting path.

## Repository Shape

- `libs/` contains importable Nim libraries.
- `apps/` contains thin application entry points.
- `tests/` contains unit, integration, compatibility, fixture, and E2E tests.
- `benchmarks/` contains repeatable benchmark suites.
- `docs/` contains public repository documentation.

## License

MIT
