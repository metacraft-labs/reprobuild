# Spec example fixtures

This directory contains example projects that exercise the new spec
additions:

- [Build-Graph-Collections.md](../../../../reprobuild-specs/Build-Graph-Collections.md)
- [Configurable-System.md §"Solver-Participating Configurables (Variants)"](../../../../reprobuild-specs/Configurable-System.md)
- [Reprobuild-Standard-Library.md](../../../../reprobuild-specs/Reprobuild-Standard-Library.md)

Each subdirectory is a self-contained project whose `repro.nim` is a
canonical demonstration of one or more of the new features. The projects
serve two purposes:

1. **Spec exhibits** — concrete code shapes that the prose specs point
   at. Reviewers can scan a `repro.nim` and see how the new constructs
   compose in practice.
2. **Acceptance fixtures** — once the implementation lands, these
   projects become end-to-end tests that drive `./build/bin/repro`
   against them and assert the expected behavior (test collection
   discovery, variant-driven graph shape, alias dispatch, etc.).

## Current projects

| Project | Demonstrates |
|---|---|
| [`simple-test-collection/`](./simple-test-collection/) | The `test` build graph collection, auto-enrollment via the `test` template, the `repro test` verb alias. |
| [`variant-feature-flag/`](./variant-feature-flag/) | Solver-participating Configurables (variants), conditional `uses:`, conditional build edges, variant-driven collection enrollment. |
| [`selectable-toolchain/`](./selectable-toolchain/) | Variants driving `uses:` resolution, the cross-cutting `Toolchain` interface, the gcc-vs-clang adapter selection pattern. |

## Status

The fixtures are present as **spec exhibits today**. The `repro.nim`
files reference DSL constructs (`variant:` declarations, `collect(...)`,
the `test` template with auto-enrollment, variant-conditioned `uses:`
arms) that the reprobuild engine does not yet implement. Compiling the
fixtures with the current engine will fail; that is expected.

The structural verifier
[`tests/integration/t_spec_example_fixtures_present.nim`](../../integration/t_spec_example_fixtures_present.nim)
confirms each project's `repro.nim` carries the expected DSL surface so
the fixtures cannot drift silently from the spec.

When the implementation lands, an end-to-end driver gated on
`REPRO_SPEC_EXAMPLES_RUN=1` will compile + run each fixture and assert
the documented behavior. The driver is a placeholder until then.
