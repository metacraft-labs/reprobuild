# Cross-Language Builds

Reprobuild supports a single workspace that mixes more than one
language. This is the killer feature for projects with native cores
(Rust / Zig / D), legacy C/C++ libraries, or scientific Fortran
kernels: you describe the whole tree in one `repro.nim` and the engine
sequences the cross-language link.

## Supported combinations

| Combination               | Forward | Reverse | Page                                                       |
|---------------------------|---------|---------|------------------------------------------------------------|
| Nim ↔ C/C++               | yes     | yes     | [nim-and-c-cpp.md](nim-and-c-cpp.md)                       |
| Rust ↔ C/C++              | yes     | yes     | [rust-and-c-cpp.md](rust-and-c-cpp.md)                     |
| Nim ↔ Rust                | yes     | yes     | [nim-and-rust.md](nim-and-rust.md)                         |
| Go ↔ C/C++ (cgo)          | yes     | partial | [go-and-c-cpp.md](go-and-c-cpp.md)                         |
| Fortran ↔ C/C++           | yes     | yes     | [fortran-and-c-cpp.md](fortran-and-c-cpp.md)               |
| Zig ↔ C/C++               | yes     | yes     | [zig-and-c-cpp.md](zig-and-c-cpp.md)                       |
| D ↔ C/C++                 | yes     | yes (limited) | [d-and-c-cpp.md](d-and-c-cpp.md)                     |

"Forward" = language A's binary links against language B's library.
"Reverse" = language B's binary links against language A's library.

## The shared archive schema

Every cross-language combination uses a **shared static archive
schema** under `.repro/build/`:

```text
.repro/build/<libName>/lib<libName>.a
```

When a binary from language A consumes a library from language B,
language B's archive is built first (its action's `id` is in language
A's link action's `deps`), and the archive's path is threaded onto
language A's linker command line as a positional input.

The schema is symmetric: it doesn't matter which language produced the
archive. Any language that can emit a standard `.a` archive and any
language whose driver accepts a `.a` positional plays the same way.

## How to declare a cross-language workspace

Both packages live in one `repro.nim`. Each declares its own `uses:`
toolchain. The `depends_on` edge expresses the cross-language link:

```nim
# repro.nim
package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package calc:
  uses:
    "rust"
  executable calc:
    discard

# Cross-language: the rust binary `calc` consumes the C archive
# `mathlib`. Hand-authored — the scanner doesn't read `extern "C"`
# blocks yet.
depends_on calc: mathlib
```

The downstream-language convention (`rust-direct` here) takes
ownership of the WHOLE workspace because the upstream-language
convention defers when it sees a non-native `uses:` in the workspace.
The taking-ownership convention then emits the C archive actions
in-line and wires them into the language-native link.

## Pattern: which side owns the workspace?

When two language conventions could both apply, one defers to the
other. The general rule:

- **The downstream consumer wins.** If the C archive is consumed by a
  Rust binary, `rust-direct` owns the workspace. `c-cpp-direct`
  defers when it sees `uses: rust` (or `uses: nim`, `uses: go`,
  `uses: fortran`, `uses: zig`, `uses: d`) AND no ecosystem manifest
  is present.

- **The reverse direction** (C binary consuming Rust library) is
  owned by `c-cpp-direct`. The upstream-language conventions
  contribute their archive actions but the link is C/C++'s.

## Scanner limitations across the cross-language matrix

None of the cross-language fixtures have a fully-automated scanner.
The per-language scanners pick up intra-language imports
(`use mathlib::add;`, `import "mathlib"`, `#include "mathlib/add.h"`)
but the cross-language declarations (`extern "C" { fn ... }`,
`{.importc, header: "...".}`, `import "C"` cgo blocks, `bind(C)`
Fortran) are NOT yet folded into the dep graph. Hand-author the
`depends_on` edges until follow-on scanner extensions land.

## Runtime considerations

Each language combination has runtime-specific quirks:

- **Rust `no_std` staticlibs** need explicit `-lpthread -ldl -lm` on
  the consumer's link line.
- **Fortran archives** need `-lgfortran -lquadmath -lm` on the
  consumer's link line. The fortran-direct convention threads these
  for you when a C/C++ binary consumes a Fortran library.
- **Zig static archives** bundle compiler-rt — no extra runtime
  libs needed.
- **D archives** (reverse direction) require `extern (C)` +
  `core.stdc.*` only — no `import std.*`, no GC.
- **Go cgo** drops `go tool compile` and uses `go build` for the
  whole executable.
- **Nim** emits C and links via gcc; cross-language C consumption
  threads `-I<header-dir>` on phase 1 and `lib<x>.a` on phase 3.

Each cross-language page covers the per-combination details.

## Building cross-language workspaces

Identical to single-language builds:

```text
repro build
```

The engine resolves the cross-language edges and emits a coherent
action graph. The artifact cache works the same way — a no-op rebuild
is a no-op, and a one-source-file change rebuilds only what changed.

## See also

- [Three Modes](../three-modes.md)
- [Language pages](../README.md#languages)
- Reference fixtures:
  [`reprobuild-examples/mixed/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed)
