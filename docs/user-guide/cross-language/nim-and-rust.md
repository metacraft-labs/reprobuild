# Nim ↔ Rust

Nim and Rust talk to each other through the C ABI: Rust's `staticlib`
archive exports `#[no_mangle] pub extern "C"` functions and Nim's
`{.importc.}` pragma imports them as if they were C functions. Same
the other way around.

## Both directions in one paragraph

- **Forward (Nim → Rust):** Nim binary uses `{.importc, dynlib.}`
  pragmas to declare Rust-exported symbols. The Rust library is built
  with `--crate-type staticlib` producing a `lib<name>.a` archive,
  which is threaded onto Nim's Phase 3 link as a positional plus
  `-lpthread -ldl -lm` for the Rust runtime.
- **Reverse (Rust → Nim):** Rust binary declares `extern "C" { ... }`
  symbols, the Nim library uses `{.exportc.}` to expose them, the
  Nim convention emits a static archive that the Rust binary's
  `rustc` link picks up. The Rust binary calls `NimMain()` once
  before using the exports.

## Minimal fixture (forward — Nim binary calls Rust library)

`repro.nim`:

```nim
import repro_project_dsl

package addlib:
  uses:
    "rust"
  library addlib

package nimapp:
  uses:
    "nim >=2.2 <3.0"
  executable nimapp:
    discard

# Manual edge — neither scanner sees the cross-language ABI today.
depends_on nimapp: addlib

include "repro.scanned-deps.nim"
```

Layout:

```text
nim-uses-rust-lib/
  repro.nim
  repro.scanned-deps.nim
  addlib/src/lib.rs                 # Rust library with `#[no_mangle] pub extern "C"`
  src/nimapp.nim                    # Nim binary with `{.importc.}`
```

`addlib/src/lib.rs`:

```rust
#[no_mangle]
pub extern "C" fn rust_add(a: i32, b: i32) -> i32 {
    a + b
}
```

`src/nimapp.nim`:

```nim
proc rustAdd(a, b: cint): cint {.importc: "rust_add", cdecl, dynlib.}

echo "2 + 3 = ", rustAdd(2.cint, 3.cint)
echo "hello from nim-uses-rust-lib"
```

Build:

```text
repro build
```

The Nim convention takes ownership, emits the Rust staticlib in-line
(`rustc --crate-type staticlib ...`), threads the archive path onto
Phase 3 of Nim's link plus `-lpthread -ldl -lm` for Rust runtime
support.

Reference fixture:
[`reprobuild-examples/mixed/nim-uses-rust-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/nim-uses-rust-lib).

## Reverse direction (Rust → Nim)

Reference fixture:
[`reprobuild-examples/mixed/rust-uses-nim-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/rust-uses-nim-lib).

Nim library:

```nim
proc nim_add(a, b: cint): cint {.exportc: "nim_add", cdecl, dynlib.} =
  a + b
```

Rust binary:

```rust
extern "C" {
    fn NimMain();
    fn nim_add(a: i32, b: i32) -> i32;
}

fn main() {
    unsafe {
        NimMain();
        println!("nim_add(2, 3) = {}", nim_add(2, 3));
    }
}
```

`repro.nim`:

```nim
package nimlib:
  uses:
    "nim >=2.2 <3.0"
  library nimlib

package rustapp:
  uses:
    "rust"
  executable rustapp:
    discard

depends_on rustapp: nimlib
```

## Required flags / declarations

- **Forward (Nim → Rust):**
  - Rust side: `#[no_mangle] pub extern "C" fn ...`. The crate is
    built as `staticlib`.
  - Nim side: `{.importc: "rust_add", cdecl, dynlib.}` on the
    forward declaration.
  - Convention threads: archive positional + `-lpthread -ldl -lm`.

- **Reverse (Rust → Nim):**
  - Nim side: `{.exportc: "nim_add", cdecl, dynlib.}` on the
    exported proc.
  - Rust side: `extern "C" { fn nim_add(...); }` block; calls wrapped
    in `unsafe`.
  - The Rust binary must call `NimMain()` once at startup.

## Outstanding limitations

- **No automatic binding generation.**
- **Scanner blind in both directions.** Hand-author `depends_on`
  edges.
- **`NimMain()` is the user's responsibility** in reverse direction.
- **No `--threads:on` Nim runtime** in reverse direction yet.
- **The Rust runtime libs threaded** (`-lpthread -ldl -lm`) are
  Linux-flavored — Windows uses different runtime support. The
  convention currently handles only the Linux/macOS case cleanly.

## See also

- [Nim language page](../languages/nim.md)
- [Rust language page](../languages/rust.md)
- [Cross-language overview](README.md)
