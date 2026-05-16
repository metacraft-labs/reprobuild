# Reprobuild

> **Status:** M6 foundation slice

**Reprobuild** (CLI: `repro`) is a unified build system combining reproducible environments, automatic dependency discovery, incremental rebuilds with artifact caching, and distributed execution.

This repository is the public `metacraft-labs/reprobuild` product repository.
The current foundation includes core value/process/dependency-policy types,
binary-first domain envelopes, and real BLAKE3/XXH3-backed hash policy.

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
