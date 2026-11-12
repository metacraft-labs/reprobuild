# repro_cargo_gc

Target-directory janitor for cargo projects: `repro cargo gc` and
`repro cargo record-live`. Cargo never prunes `target/`; this library records
which build units each cargo invocation used and deletes the ones outside the
last K invocations that are also older than T. The user-facing description is
[`docs/cargo-gc.md`](../../docs/cargo-gc.md). The CLI only parses arguments
(`libs/repro_cli_support/src/repro_cli_support/cargo_gc.nim`) and calls this
library, so a cargo wrapper or build edge can call the same entry points.

| Module | Does |
| --- | --- |
| `repro_cargo_gc/types.nim` | live sets, settings, provisional defaults (K = 3, T = 14 days), errors |
| `repro_cargo_gc/layout.nim` | reads cargo's profile-directory layout: unit hashes, entries, sizes, fingerprints |
| `repro_cargo_gc/record.nim` | turns `--message-format=json` into a live set and stores it |
| `repro_cargo_gc/store.nim` | the live-set store (one TOML file per invocation), retention |
| `repro_cargo_gc/gc.nim` | plans and executes the sweep, under cargo's `.cargo-lock` |
| `repro_cargo_gc/cargo_home.nim` | age-based sweep of extracted `CARGO_HOME/registry/src` |
| `repro_cargo_gc/config.nim` | flag, environment, user-config and default resolution |

Tests run real cargo and rustc: `libs/repro_cargo_gc/tests/`.
