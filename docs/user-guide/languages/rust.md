# Rust

Reprobuild builds Rust workspaces either as a curated `repro.nim`
(Mode 3 — recommended for in-workspace-only projects) or by delegating
to `cargo` (Mode 2 — required for crates.io / git dependencies).

## Modes available

- **Mode 3**: `repro.nim` + per-package `src/lib.rs` or `src/main.rs`.
  No `Cargo.toml`. Cross-package `use` lines are scanned automatically.
- **Mode 2**: existing `Cargo.toml`. Reprobuild reads `cargo metadata`
  output and lifts the workspace graph.
- **Mode 1**: coming soon.

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package mathlibPkg:
  uses:
    "rust"
  library mathlib

package calcPkg:
  uses:
    "rust"
  executable calc:
    discard

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B — one subdir per package):

```text
my-rust-workspace/
  repro.nim
  repro.scanned-deps.nim
  mathlib/
    src/lib.rs               # `pub fn add(a: i32, b: i32) -> i32 { a + b }`
  calc/
    src/main.rs              # `use mathlib::add; fn main() { ... }`
```

The `calc/src/main.rs` `use mathlib::add;` line is what the scanner
reads to emit the `depends_on calcPkg: mathlibPkg` edge.

Build:

```text
repro build
```

Outputs:

```text
.repro/build/mathlib/libmathlib.rlib
.repro/build/calc/calc[.exe]
```

The `rust-direct` convention compiles libraries to `rlib` (not
`staticlib`) because Rust-to-Rust `use upstream::...` requires the
metadata only `rlib` carries. For cross-language consumption (a C
binary linking the Rust library), the convention emits a sibling
`staticlib` action — see
[Cross-language Rust ↔ C/C++](../cross-language/rust-and-c-cpp.md).

Reference fixture:
[`reprobuild-examples/rust-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/rust-mode3/binary-with-library).

## Source layout

The Rust convention recognizes:

**Layout A (single-package, flat).** All under `src/`:

```text
my-crate/
  repro.nim
  src/
    main.rs
    lib.rs
```

**Layout B (workspace).** One subdirectory per package, each with its
own `src/`:

```text
my-workspace/
  repro.nim
  mathlib/src/lib.rs
  calc/src/main.rs
```

## Mode 2 escape hatch

If you have a `Cargo.toml` (or want to add one to pull in crates.io
dependencies), the standard provider switches to Mode 2 automatically:

```text
my-crate/
  reprobuild.nim
  Cargo.toml                    # ecosystem manifest
  src/
    main.rs
```

The minimal `reprobuild.nim` shim is:

```nim
import repro_project_dsl

package my_crate:
  uses:
    "rust"
  executable my_crate:
    discard
```

Use Mode 2 when:
- You depend on **crates.io** packages.
- You depend on a **git** dependency.
- You need **Cargo features**, build scripts (`build.rs`), or other
  Cargo-only mechanics.

The Rust Mode 3 convention deliberately does NOT support external
crate resolution — adding `Cargo.toml` is the supported graduation
path.

## Cross-language

- [Rust ↔ C/C++](../cross-language/rust-and-c-cpp.md) — forward
  (Rust binary → C library) via `extern "C"`; reverse (C binary →
  Rust library) via `#[no_mangle] pub extern "C"` + `staticlib`.
- [Nim ↔ Rust](../cross-language/nim-and-rust.md) — Nim binary calls
  a Rust library via the Rust staticlib + `{.importc.}`.

## The scanner

The Rust scanner reads:

- `use crate::...`
- `mod ...` declarations
- `extern crate ...` (in `lib.rs` / `main.rs`)

It maps these against the workspace package names declared in
`repro.nim`. Imports that don't match a workspace package are treated
as ecosystem-external and ignored — Mode 2 / Cargo handles those.

`extern "C" { fn foo(...); }` declarations are NOT picked up
automatically. Cross-language Rust → C edges are hand-authored in
`repro.nim` via `depends_on`.

## Outstanding limitations

- **No crates.io support in Mode 3.** External package resolution is
  Mode 2's job. Add a `Cargo.toml` to use crates.io.
- **No build scripts.** Mode 3 doesn't run `build.rs`. Switch to
  Mode 2 if you need one.
- **No proc-macro crates.** Mode 3 can't compile or apply proc-macros.
  Mode 2 handles them via Cargo.
- **Cargo features not supported.** The Mode 3 path has no feature
  selection — use Mode 2.
- **Edition: hard-coded to 2021.** The Mode 3 convention uses
  `--edition 2021`; if you need a different edition, add a
  `Cargo.toml`.
- **Tests not discovered.** Rust unit tests via `#[test]` aren't
  enumerated by Mode 3. Use Mode 2 (`cargo test`) or a `build:` block.

## See also

- [Cross-language Rust ↔ C/C++](../cross-language/rust-and-c-cpp.md)
- [Language-Conventions/Rust.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Rust.md) —
  contributor-facing convention spec.
