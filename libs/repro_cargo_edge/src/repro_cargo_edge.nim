## The thin cargo edge: a transparent `RUSTC_WRAPPER` that reports each
## compiled unit's totals to RunQuota, the environment that installs it into
## a cargo action, and product discovery from cargo's JSON messages.
## See `docs/cargo-edge.md`.
import repro_cargo_edge/[rustc_args, wrapper_env, rustc_wrapper, products, edge, edge_cli]
export rustc_args, wrapper_env, rustc_wrapper, products, edge, edge_cli
