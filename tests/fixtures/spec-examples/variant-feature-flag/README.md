# variant-feature-flag

Exercises solver-participating Configurables (variants) and how a single
variant flag affects `uses:`, build edges, and collection enrollment in
one consistent pass.

## What this fixture demonstrates

- A `variant: bool = true` declaration registers a Configurable with the
  solver-participation tag. The solver resolves it at stage 2
  (Configurable-System §"Solver-Phase Resolution"); by stage 4 (graph
  emission) `enableTLS.value` is a plain `bool`.
- A variant-conditioned `uses:` arm (`if enableTLS.value: "openssl
  >=3.3 <4.0"`) registers the dependency only when the resolved value
  selects that arm.
- A variant-conditioned build edge (`if enableTLS.value: let tlsTest
  = test buildNimUnittest(...)`) is emitted only when the variant
  resolves truthy. The conditional `test buildNimUnittest` also drops the
  TLS test's enrollment in the `test` build graph collection in lockstep.
- Workspace override via `repro --variant enableTLS=false` (CLI form)
  or `enableTLS.override false` (workspace-scope file form) lands at
  `prOverride` priority and outranks the variant's `prDefault`.

## Layout

```
variant-feature-flag/
├── repro.nim         # Variant declaration + conditional uses + conditional edge
├── src/
│   └── server.nim    # The HTTP server (unconditionally compiled)
└── tests/
    ├── t_basic.nim   # Always enrolled in `test` collection
    └── t_tls.nim     # Enrolled in `test` collection only when enableTLS.value == true
```

## Expected behaviour (once implementation lands)

| Command | Effect |
|---|---|
| `repro test` | Default `enableTLS = true`: compiles both `t_basic` and `t_tls` with `openssl` linked, runs both. |
| `repro --variant enableTLS=false test` | Drops `openssl` from the solved graph, drops `t_tls`'s build + execute edges, runs only `t_basic`. |
| `repro --variant enableTLS=false build` | Builds the server WITHOUT TLS support, no openssl dependency materialized. |
| `repro --variant enableTLS=foo test` | Solver rejects the value as not coercible to `bool`; structured diagnostic. |

## What's exercised vs. what's covered elsewhere

- The variant in this fixture is a simple `bool`. The enum-variant case
  (`variant: enum["gcc", "clang"]`) is exercised by `selectable-toolchain/`.
- Cross-package constraint expressions (`requires:`, `conflicts:`,
  `propagates:`) are not exercised here; they are covered by the
  Configurable-System validation criteria and a dedicated unit test once
  the impl lands.
- The `test` collection's auto-enrollment is identical to the
  `simple-test-collection/` fixture; the only addition here is the
  conditional enrollment under a variant guard.
