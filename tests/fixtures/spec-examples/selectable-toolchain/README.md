# selectable-toolchain

Exercises a variant driving `uses:` resolution to pick a concrete
toolchain adapter package. This is the gcc-vs-clang case from
Reprobuild-Standard-Library.md §"`uses:` Resolution Under Variants" and
the structural template for cross-compilation, MSVC-vs-mingw, and other
toolchain-selection cross-cutting concerns.

## What this fixture demonstrates

- A `variant: enum["gcc", "clang"] = "gcc"` declaration with a finite
  value set. The solver enforces that the resolved value lies in the
  declared set; out-of-set contributions raise a structured diagnostic
  at contribution time.
- Variant-conditioned `uses:` arms (`case compiler.value: of "gcc":
  "gcc"; of "clang": "clang"`) register the right adapter package
  conditionally. The solver picks the concrete adapter and continues SAT
  resolution with the right transitive dependency set.
- The package's `build:` body calls the abstract `cc.compile(...)`
  surface from the stdlib `Toolchain` cross-cutting interface
  (Reprobuild-Standard-Library.md §"Cross-Cutting Interfaces"). The
  interface call is the same regardless of which adapter the solver
  picked; the adapter's typed-tool wrapper handles the per-compiler
  invocation differences.
- The variant resolves at stage 2 (solver), so `compiler.value` is a
  plain `string` at stage 4 (graph emission) and recipe code can
  branch on it directly.

## Layout

```
selectable-toolchain/
├── repro.nim         # Variant declaration + conditional uses + abstract cc.compile
└── src/
    └── main.c        # Trivial C program
```

## Expected behaviour (once implementation lands)

| Command | Effect |
|---|---|
| `repro build` | Default `compiler = "gcc"`: solver picks the gcc adapter, `cc.compile` invokes gcc, binary at `build/bin/hello`. |
| `repro --variant compiler=clang build` | Solver picks the clang adapter, `cc.compile` invokes clang, binary at the same path. |
| `repro --variant compiler=msvc build` | Solver rejects the value (`msvc` is not in the declared enum); structured diagnostic naming the declared set. |

## What's exercised vs. what's covered elsewhere

- The cross-compilation case (`targetTriple: variant string = "native"`
  driving `pkgsCross`-style adapter selection) is structurally identical
  to this fixture but uses a different variant axis. The full
  cross-compilation worked example lives in
  Reprobuild-Standard-Library.md §"Worked Example: Cross-Compilation".
- The runtime end-to-end execution of gcc/clang is platform-dependent
  and is gated on the e2e acceptance harness, not on the structural
  verifier.
