# Nim ↔ C/C++

Nim's `{.importc.}` / `{.exportc.}` pragmas make C interop unusually
clean: Nim already emits C, so calling out to (and being called from)
a C library doesn't need an FFI shim layer.

## Both directions in one paragraph

- **Forward (Nim → C):** Nim source uses `{.importc, header: "...".}`
  pragmas to declare C symbols. The convention threads
  `--passC:-I<include-dir>` onto Nim's Phase 1 (`nim c --compileOnly`)
  so the user-written `#include "mathlib/add.h"` resolves at C-compile
  time, plus the upstream `lib<name>.a` archive as a positional on
  Nim's Phase 3 link.
- **Reverse (C → Nim):** Nim source exports symbols with
  `{.exportc, dynlib, cdecl.}` pragmas, the Nim convention emits a
  static archive containing the Nim runtime + user symbols + a
  `NimMain()` initializer. The C binary calls `NimMain()` once before
  using exported procs.

## Minimal fixture (forward direction)

`repro.nim`:

```nim
import repro_project_dsl

package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package nimapp:
  uses:
    "nim >=2.2 <3.0"
  executable nimapp:
    discard

# Manual edge — Nim's scanner doesn't yet pick up `{.importc, header.}`
# pragmas, so the cross-language link is hand-authored.
depends_on nimapp: mathlib

include "repro.scanned-deps.nim"
```

Layout:

```text
nim-uses-cpp-lib/
  repro.nim
  repro.scanned-deps.nim
  src/nimapp.nim                       # Nim source (Layout A for Nim)
  mathlib/src/add.c                    # C source
  mathlib/include/mathlib/add.h        # public header
```

`src/nimapp.nim`:

```nim
proc cAdd(a, b: cint): cint {.importc: "add", header: "mathlib/add.h".}

echo "1 + 2 = ", cAdd(1.cint, 2.cint)
echo "hello from nim-uses-cpp-lib"
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

The Nim convention takes ownership, emits the C archive in-line,
threads `--passC:-I<mathlib>/include` onto Phase 1, and adds the
archive path to Phase 3's link argv. The `nimapp[.exe]` binary prints
`1 + 2 = 3` followed by the greeting.

Reference fixture:
[`reprobuild-examples/mixed/nim-uses-cpp-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/nim-uses-cpp-lib).

## Reverse direction (C → Nim)

Reference fixture:
[`reprobuild-examples/mixed/cpp-uses-nim-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/cpp-uses-nim-lib).

The Nim library exports symbols with `{.exportc, cdecl, dynlib.}`:

```nim
proc nim_add(a, b: cint): cint {.exportc: "nim_add", cdecl, dynlib.} =
  a + b
```

The C/C++ binary calls `NimMain()` once at startup (the Nim runtime
initializer) before using the exports:

```c
extern void NimMain(void);
extern int nim_add(int a, int b);

int main(void) {
    NimMain();
    printf("nim_add(2, 3) = %d\n", nim_add(2, 3));
    return 0;
}
```

The `repro.nim` is symmetric — same shape, swapped `uses:`:

```nim
package nimlib:
  uses:
    "nim >=2.2 <3.0"
  library nimlib

package cppapp:
  uses:
    "gcc >=11"
  executable cppapp:
    discard

depends_on cppapp: nimlib
```

## Required flags / declarations

- **Nim side, forward direction:**
  `{.importc: "<symbol>", header: "<path/header.h>".}` on each
  imported function. The `header:` argument tells Nim to emit
  `#include "<path>"` in the generated C.

- **Nim side, reverse direction:**
  `{.exportc: "<symbol>", cdecl, dynlib.}` on each exported function.
  `dynlib` is needed even for static-archive output — it controls
  Nim's symbol visibility.

- **C side, forward direction:** ordinary header + implementation;
  no special markup.

- **C side, reverse direction:** declare `extern void NimMain(void);`
  and call it once before using any Nim exports. Optional: `extern
  void NimMainModule(void);` for finer-grained init control.

## Outstanding limitations

- **No automatic FFI binding generation.** Write the `{.importc.}`
  pragmas and the C headers by hand.
- **Scanner blind to `{.importc, header.}`.** Hand-author `depends_on`
  edges. A follow-on milestone will fold `header:` arguments into the
  Nim scanner.
- **`NimMain()` call is the user's responsibility.** Forgetting it
  manifests as runtime crashes inside the Nim runtime.
- **Reverse direction doesn't yet support `--threads:on`.** Single-
  threaded Nim runtime only in the reverse fixture.

## See also

- [Nim language page](../languages/nim.md)
- [C/C++ language page](../languages/c-cpp.md)
- [Cross-language overview](README.md)
