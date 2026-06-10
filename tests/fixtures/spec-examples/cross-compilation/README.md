# Cross-Compilation Worked Example

Spec exhibit for the **Spec-Implementation M5** cross-compilation flow.
Demonstrates how a `targetTriple` variant drives the active build
context's `Toolchain` + `CrossTarget` slots so the same recipe
compiles native OR cross-compiles for `aarch64-linux-gnu`.

## Files

- `repro.nim` — the package declaration. Declares the
  `targetTriple: variant string = "native"` variant, the
  variant-conditioned `uses:` arms, and the `build:` body that
  consults `currentBuildContext().toolchain.compile/link(...)`.
- `src/hello.c` — a trivial C source. Prints a single line and
  returns 0.

## Variant Resolution

Default — native build:

```
repro build
```

Cross-build for `aarch64-linux-gnu`:

```
repro --variant targetTriple=aarch64-linux-gnu build
```

The cross-toolchain adapter at
`libs/repro_dsl_stdlib/src/repro_dsl_stdlib/adapters/cross_aarch64_linux_gnu.nim`
takes over the toolchain slot when the resolved triple matches; the
`build:` body's source does not change.

## Cross-Compiler Discovery

The adapter probes for an `aarch64-linux-gnu-gcc` binary in three
places, in order:

1. The `REPRO_AARCH64_GCC` environment variable (escape hatch for
   sandbox / nix-shell-style setups).
2. `aarch64-linux-gnu-gcc` on `$PATH` (Debian-packaged cross
   toolchains).
3. `aarch64-unknown-linux-gnu-gcc` on `$PATH` (nixpkgs
   `pkgsCross.aarch64-multiplatform.buildPackages.gcc` installs).

When none of the three resolves, the adapter still emits a populated
`Toolchain` whose `compile` argv uses the bare fallback name; the
engine reports `aarch64-linux-gnu-gcc: command not found` at action
execution time, surfacing the unavailability cleanly rather than
silently swallowing it.

## See also

- `tests/integration/t_e2e_cross_compilation_aarch64.nim` — exercises
  this fixture's cross path end-to-end (cross compile + verify the
  resulting binary's architecture via `file`).
- `tests/integration/t_integration_cross_target_aarch64_adapter.nim`
  — unit test for the M5 adapter's interface conformance.
- `Reprobuild-Standard-Library.md` §"Worked Example:
  Cross-Compilation" (in `reprobuild-specs/`).
- `Configurable-System.md` §"Worked Example: Cross-Compilation" (in
  `reprobuild-specs/`).
