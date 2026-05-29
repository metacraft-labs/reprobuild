# Rust ↔ C/C++

Rust's `extern "C"` blocks and `#[no_mangle] pub extern "C"`
exports make C interop straightforward. The Rust `staticlib` crate
type produces a `.a` archive consumable by any C/C++ linker.

## Both directions in one paragraph

- **Forward (Rust → C):** The Rust binary's source has an
  `extern "C" { fn foo(...); }` block declaring C symbols. The
  convention threads `-L native=<archive-dir>` `-l static=<libname>`
  onto the `rustc` link line, plus the archive's path on `inputs` and
  the archive action's id on `deps`. Symbol resolution succeeds at
  link time.
- **Reverse (C → Rust):** Rust source exports with
  `#[no_mangle] pub extern "C"`, the crate is built as
  `staticlib` (not `rlib`), the resulting `.a` archive is consumed by
  the C/C++ binary's linker. For `no_std` Rust staticlibs, the C
  link line needs explicit `-lpthread -ldl -lm` for Rust runtime
  routines.

## Minimal fixture (forward direction)

`repro.nim`:

```nim
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package calc:
  uses:
    "rust"
  executable calc:
    discard

# Manual edge — the Rust scanner doesn't read `extern "C"` blocks.
depends_on calc: mathlib

include "repro.scanned-deps.nim"
```

Layout:

```text
rust-uses-cpp-lib/
  repro.nim
  repro.scanned-deps.nim
  mathlib/src/add.c
  mathlib/include/mathlib/add.h
  calc/src/main.rs
```

`calc/src/main.rs`:

```rust
extern "C" {
    fn add(a: i32, b: i32) -> i32;
}

fn main() {
    let result = unsafe { add(2, 3) };
    println!("rust says: mathlib added 2+3 = {}", result);
}
```

`mathlib/include/mathlib/add.h`:

```c
#ifndef MATHLIB_ADD_H
#define MATHLIB_ADD_H
int add(int a, int b);
#endif
```

`mathlib/src/add.c`:

```c
#include "mathlib/add.h"
int add(int a, int b) { return a + b; }
```

Build:

```text
repro build
```

`rust-direct` takes ownership of the workspace, emits the C archive
in-line via `gcc -c` + `ar rcs`, threads
`-L native=.repro/build/mathlib` and `-l static=mathlib` onto the
`rustc` link argv. The binary resolves `add` against the C archive.

Reference fixture:
[`reprobuild-examples/mixed/rust-uses-cpp-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/rust-uses-cpp-lib).

## Reverse direction (C → Rust)

Reference fixture:
[`reprobuild-examples/mixed/cpp-uses-rust-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/cpp-uses-rust-lib).

The Rust library exports symbols and is built as `staticlib`:

```rust
#[no_mangle]
pub extern "C" fn rust_add(a: i32, b: i32) -> i32 {
    a + b
}
```

The convention emits both the standard `rlib` (for downstream Rust
consumers) and a sibling `staticlib` action (for C/C++ consumers).
The C/C++ binary links against the `staticlib` archive.

`repro.nim`:

```nim
package rustlib:
  uses:
    "rust"
  library rustlib

package cppapp:
  uses:
    "gcc >=11"
  executable cppapp:
    discard

depends_on cppapp: rustlib
```

## Required flags / declarations

- **Rust side, forward direction:**
  `extern "C" { fn foo(a: i32, ...) -> ...; }` block. Wrap calls in
  `unsafe { ... }`. No build-side configuration; the convention
  threads link flags from the `depends_on` edge.

- **Rust side, reverse direction:**
  `#[no_mangle] pub extern "C" fn foo(...) -> ...`. The
  `#[no_mangle]` is essential — without it, Rust mangles the symbol
  and C can't find it. The convention produces a `staticlib`
  alongside the `rlib`.

- **C side, forward direction:** ordinary header + implementation.
  No mention of Rust on the C side.

- **C side, reverse direction:** declare the imported symbol as
  `extern int rust_add(int a, int b);` (or whatever the signature
  is). For `no_std` Rust staticlibs, add `-lpthread -ldl -lm` to the
  link line; for standard Rust staticlibs (with libstd), the link
  line needs the same runtime libs.

## Outstanding limitations

- **No automatic FFI bindings.** Write `extern "C"` blocks and C
  headers by hand. Tools like `cbindgen` / `bindgen` are not yet
  integrated.
- **Scanner blind to `extern "C"`.** Hand-author `depends_on` edges.
- **`no_std` Rust staticlibs need explicit runtime libs.** The
  convention threads `-lpthread -ldl -lm` but doesn't handle every
  exotic runtime configuration.
- **No proc-macro crates** in either direction (Rust-side limitation
  from the language page).
- **C++ name mangling.** Calling C++ symbols (not C symbols) from
  Rust needs `extern "C"` shims on the C++ side. Plain C++ ABI
  consumption is not first-class.

## See also

- [Rust language page](../languages/rust.md)
- [C/C++ language page](../languages/c-cpp.md)
- [Cross-language overview](README.md)
