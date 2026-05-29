# Zig ↔ C/C++

Zig's `export fn` (Zig → C) and `extern fn` (C → Zig) make C interop
basically free: no headers to write on the Zig side, no runtime
helper to call, no mangling to disable. Zig static archives bundle
the minimal compiler-rt routines so the C side doesn't need extra
runtime libs.

## Both directions in one paragraph

- **Forward (Zig → C):** Zig source declares C symbols with
  `extern fn foo(a: i32, b: i32) i32;` at top level. The convention
  builds the C archive (`gcc -c` + `ar rcs`), adds it as a trailing
  positional on `zig build-exe` plus `-L <dir>` so Zig's underlying
  linker resolves the C symbols.
- **Reverse (C → Zig):** Zig source exposes symbols with `export fn
  foo(a: i32, b: i32) i32 { ... }`. The convention builds the Zig
  archive (`zig build-lib -femit-bin=...`), threads it onto the C/C++
  binary's `g++ -o` link as a trailing positional. No extra runtime
  libs needed — Zig static archives bundle compiler-rt.

## Minimal fixture (forward — Zig binary calls C library)

`repro.nim`:

```nim
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package zigcalc:
  uses:
    "zig"
  executable zigcalc:
    discard

depends_on zigcalc: mathlib

include "repro.scanned-deps.nim"
```

Layout:

```text
zig-uses-cpp-lib/
  repro.nim
  repro.scanned-deps.nim
  mathlib/src/add.c
  mathlib/include/mathlib/add.h
  zigcalc/src/main.zig
```

`zigcalc/src/main.zig`:

```zig
const std = @import("std");

extern fn add(a: i32, b: i32) i32;

pub fn main() void {
    const result = add(2, 3);
    std.debug.print("zig says: mathlib added 2+3 = {d}\n", .{result});
}
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

`zig-direct` takes ownership, emits the C archive in-line, runs
`zig build-exe -O ReleaseSafe --name zigcalc -femit-bin=zigcalc[.exe]
zigcalc/src/main.zig libmathlib.a -L .repro/build/mathlib`. The
underlying linker resolves `add` against the C archive.

Reference fixture:
[`reprobuild-examples/mixed/zig-uses-cpp-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/zig-uses-cpp-lib).

## Reverse direction (C++ → Zig)

Reference fixture:
[`reprobuild-examples/mixed/cpp-uses-zig-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/cpp-uses-zig-lib).

`ziglib/src/root.zig`:

```zig
export fn zig_add(a: i32, b: i32) i32 {
    return a + b;
}
```

`cppcalc/src/main.cpp`:

```cpp
#include <iostream>

extern "C" int zig_add(int a, int b);

int main() {
    std::cout << "cpp says: zig added 2+3 = " << zig_add(2, 3) << "\n";
}
```

`repro.nim`:

```nim
package ziglib:
  uses:
    "zig"
  library ziglib

package cppcalc:
  uses:
    "gcc >=11"
  executable cppcalc:
    discard

depends_on cppcalc: ziglib
```

## Required declarations

- **Zig side, forward:** `extern fn <name>(...) <ret>;` at top level
  of the Zig source. No headers to write — Zig's `extern fn` is the
  declaration.

- **Zig side, reverse:** `export fn <name>(...) <ret> { ... }`. The
  `export` keyword controls symbol visibility AND symbol naming —
  the exported name matches the function's Zig name verbatim.

- **C side, forward direction:** ordinary C — no Zig-awareness
  needed.

- **C side, reverse direction:** `extern "C" int <name>(int, ...);`
  forward declaration in C++; in C, just declare without `extern
  "C"`.

## No-runtime-libs property

Unlike Rust `no_std` staticlibs (which need `-lpthread -ldl -lm`) or
Fortran archives (which need `-lgfortran -lquadmath -lm`), Zig static
archives bundle the minimal compiler-rt routines INTO the archive
itself. This is why the reverse direction "just works" without
threading runtime-libs onto the consumer's link line.

This makes Zig the easiest cross-language consumer for C/C++ binaries
— no surprise runtime dependencies.

## Outstanding limitations

- **No `@import` / `extern` scanner.** Hand-author `depends_on`
  edges.
- **Multi-target builds (cross-compile) not supported in Mode 3.**
  Default host triple only.
- **`build.zig` Mode 2 deferred.**
- **No `@cImport` translation.** Zig's `@cImport({@cInclude("...")})`
  facility (which translates C headers to Zig declarations at compile
  time) works at the language level but isn't observed by the
  convention's scanner.
- **Async functions not exportable.** Zig async fns don't have a C
  ABI representation.
- **No allocator integration in reverse direction.** Memory
  allocated on the Zig side and freed on the C side (or vice versa)
  needs careful API design — the convention doesn't help.

## See also

- [Zig language page](../languages/zig.md)
- [C/C++ language page](../languages/c-cpp.md)
- [Cross-language overview](README.md)
