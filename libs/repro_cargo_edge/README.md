# repro_cargo_edge

The thin cargo edge: cargo stays the build system, and Reprobuild bounds it,
learns from it and asks it what it produced. See [`docs/cargo-edge.md`](../../docs/cargo-edge.md).

| Module | What it holds |
| --- | --- |
| `repro_cargo_edge/rustc_args.nim` | reads a rustc command line: is it a unit of cargo's graph, and under which statistics key (`rustc/<crate>/<types>/o<opt>`) |
| `repro_cargo_edge/wrapper_env.nim` | the environment that installs the rustc wrapper into a cargo action (a project's own wrapper is chained, not replaced), and the switch |
| `repro_cargo_edge/rustc_wrapper.nim` | the wrapper itself: runs rustc unchanged and reports each unit's totals to RunQuota as a sub-lease of the action's lease |
| `repro_cargo_edge/record_mode.nim` | the wrapper's record mode: records each unit and build-script run cargo starts, writes placeholders instead of compiling, and the build-script stub that prints sentinel directives |
| `repro_cargo_edge/products.nim` | final products from cargo's `--message-format=json`, and the dynamic-graph fragment that declares them |
| `repro_cargo_edge/edge.nim` | runs one cargo invocation and writes what it produced |
| `repro_cargo_edge/edge_cli.nim` | the command line shared by `repro cargo run` and the standard provider's `--cargo-edge` entry |

`apps/repro-rustc-wrapper` is the executable cargo runs as `RUSTC_WRAPPER`.
Tests run real cargo and rustc: `libs/repro_cargo_edge/tests/`,
`tests/integration/t_rqe_cg3_*.nim` and `t_rqe_cg5_record_mode_compiles_nothing.nim`.
