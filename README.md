# Reprobuild

> **Status:** macOS MVP slice candidate

**Reprobuild** (CLI: `repro`) is a unified build system combining reproducible environments, automatic dependency discovery, incremental rebuilds with artifact caching, and distributed execution.

This repository is the public `metacraft-labs/reprobuild` product repository.
The current foundation includes core value/process/dependency-policy types,
binary-first domain envelopes, and real BLAKE3/XXH3-backed hash policy.

## Commands

- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.
- `just bench-quick` exercises the benchmark reporting path.
- `just e2e_reprobuild_mvp_acceptance` runs the accepted macOS MVP slice gates
  together: selected CodeTracer build subset, selected Nix-backed developer
  environment, shared RunQuota coordination, and core MVP benchmarks. It writes
  `test-logs/reprobuild-mvp-acceptance.json`.

This target does not claim full CodeTracer build replacement or Windows
development-environment replacement; those remain follow-up integration scopes.

## Install

The automatic installer uses the Nix flake package when `nix` is available:

```bash
curl -L https://raw.githubusercontent.com/metacraft-labs/reprobuild/main/install-on-distributions.sh | bash
```

From a local checkout, install the current build into a prefix:

```bash
./install-on-distributions.sh --method local-prefix --prefix "$HOME/.local"
```

The local-prefix mode installs executables into `<prefix>/bin` and runtime
libraries into `<prefix>/lib`, matching the layout expected by `repro`.

## Repository Shape

- `libs/` contains importable Nim libraries.
- `apps/` contains thin application entry points.
- `tests/` contains unit, integration, compatibility, fixture, and E2E tests.
- `benchmarks/` contains repeatable benchmark suites.
- `docs/` contains public repository documentation.

## License

MIT
