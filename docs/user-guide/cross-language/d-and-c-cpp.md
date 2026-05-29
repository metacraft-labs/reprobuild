# D ↔ C/C++

D's `extern (C)` makes calling C from D straightforward. The reverse
direction (C/C++ binary calls D library) is supported but limited to
`extern (C)` entry points + `core.stdc.*` only — no `import std.*`,
no GC, no full Phobos/druntime linking (yet).

## Both directions in one paragraph

- **Forward (D → C):** D source declares C symbols with `extern (C)
  int add(int a, int b);` at module level. The convention builds the
  C archive (`gcc -c` + `ar rcs`), threads it onto `ldmd2 -of=...` as
  `-L=<archive>` (linker pass-through; ldmd2 refuses `.a` as a
  positional source on Windows).
- **Reverse (C → D):** D library uses `extern (C)` and uses only
  `core.stdc.*` modules (no `import std.*`, no GC). The convention
  builds the D archive (`ldmd2 -lib`), threads it onto the C/C++
  binary's `g++ -o` link as a trailing positional. The
  `core.stdc.*`-only restriction means the linker doesn't need to
  resolve runtime references for the full D standard library.

## Minimal fixture (forward — D binary calls C library)

`repro.nim`:

```nim
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package dcalc:
  uses:
    "d"
  executable dcalc:
    discard

depends_on dcalc: mathlib

include "repro.scanned-deps.nim"
```

Layout:

```text
d-uses-cpp-lib/
  repro.nim
  repro.scanned-deps.nim
  mathlib/src/add.c
  mathlib/include/mathlib/add.h
  dcalc/src/main.d
```

`dcalc/src/main.d`:

```d
import core.stdc.stdio;

extern (C) int add(int a, int b);

extern (C) int main() {
    int result = add(2, 3);
    printf("d says: mathlib added 2+3 = %d\n", result);
    return 0;
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

`d-direct` takes ownership, emits the C archive in-line, runs `ldmd2
-release -O -of=dcalc[.exe] dcalc/src/main.d -L=libmathlib.a`. The
`-L=` form forwards the archive to the underlying linker.

Reference fixture:
[`reprobuild-examples/mixed/d-uses-cpp-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/d-uses-cpp-lib).

## Reverse direction (C++ → D)

Reference fixture:
[`reprobuild-examples/mixed/cpp-uses-d-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/cpp-uses-d-lib).

The reverse case is constrained:

- D library MUST use only `core.stdc.*` modules.
- NO `import std.*` (that would pull in Phobos which the convention
  doesn't yet link).
- NO GC allocation (which would pull in druntime startup).
- NO `Initialize_runtime()` / `Terminate_runtime()` bracket calls
  required — only because the GC isn't used.

`dlib/src/lib.d`:

```d
import core.stdc.stdio;

extern (C) int d_add(int a, int b) {
    return a + b;
}
```

`cppcalc/src/main.cpp`:

```cpp
#include <iostream>

extern "C" int d_add(int a, int b);

int main() {
    std::cout << "cpp says: d added 2+3 = " << d_add(2, 3) << "\n";
}
```

`repro.nim`:

```nim
package dlib:
  uses:
    "d"
  library dlib

package cppcalc:
  uses:
    "gcc >=11"
  executable cppcalc:
    discard

depends_on cppcalc: dlib
```

## Required declarations

- **D side, forward:** `extern (C) <ret> <name>(<args>);` at module
  level. No headers to write on the D side. Calls from D look like
  ordinary D function calls.

- **D side, reverse:** `extern (C) <ret> <name>(<args>) { ... }` at
  module level. The `extern (C)` controls symbol visibility AND
  prevents D's name mangling.

- **C side:** ordinary C — no D-awareness needed. For reverse
  direction the consumer forward-declares the symbol as `extern int
  d_add(int, int);`.

## Runtime constraints (reverse direction)

The M45 convention emits the reverse-direction D archive WITHOUT
linking `phobos2` / `druntime` because:

- It would require additional runtime libs on every consumer.
- The `Initialize_runtime()` / `Terminate_runtime()` bracket calls
  would have to be user-managed.

This deliberate scope limitation makes the reverse direction
"just work" for `extern (C)` + `core.stdc.*` use cases, which covers
most cross-language scenarios where D is the speed-of-light kernel.

Full Phobos / druntime linking is deferred to a future milestone.

## Outstanding limitations

- **Reverse direction limited to `extern (C)` + `core.stdc.*`.** No
  `import std.*`, no GC, no full Phobos.
- **No D `import` scanner.** Hand-author `depends_on` edges.
- **`-L=<archive>` form** is forward-direction Windows-specific
  workaround for ldmd2's positional-source restriction.
- **No `dub.json` / `dub.sdl` Mode 2.** Deferred.
- **No GDC driver support.** Only ldmd2 / dmd / ldc2.
- **No D shared libraries.** Static archives only.

## See also

- [D language page](../languages/d.md)
- [C/C++ language page](../languages/c-cpp.md)
- [Cross-language overview](README.md)
