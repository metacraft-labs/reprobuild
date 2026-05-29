# D

Reprobuild's D Mode 3 (`d-direct`) uses `ldmd2` (preferred), `dmd`,
or `ldc2` to compile D sources into static archives and link
executables. The convention prefers `ldmd2` because LDC's native
`ldc2` driver crashes on host-CPU auto-detection on some recent AMD
Zen 5 CPUs.

## Modes available

- **Mode 3** (`d-direct`): minimal `repro.nim` + `ldmd2 -lib` /
  `ldmd2 -of=...`. No `dub.json` / `dub.sdl`.
- **Mode 2**: `dub.json` / `dub.sdl` delegation is **deferred** —
  `dub` is a sophisticated build system that would need its own
  introspection lift.
- **Mode 1**: layout-as-manifest scaffold (M48, 2026-05-29). The
  loader infers D targets from the `.d` extension census. See
  [The Three Modes §Mode 1](../three-modes.md#mode-1--layout-as-manifest).

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package dlibPkg:
  uses:
    "d"
  library dlib

package dcalcPkg:
  uses:
    "d"
  executable dcalc:
    discard

depends_on dcalcPkg: dlibPkg

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B):

```text
my-d-workspace/
  repro.nim
  repro.scanned-deps.nim
  dlib/src/lib.d             # `extern (C) int dlib_add(int a, int b)`
  dcalc/src/main.d           # `extern (C) int dlib_add(int a, int b);`
```

Build:

```text
repro build
```

Outputs:

```text
.repro/build/dlib/libdlib.a
.repro/build/dcalc/dcalc[.exe]
```

The convention runs:

```text
ldmd2 -lib -release -O -of=libdlib.a dlib/src/lib.d
ldmd2 -release -O -of=dcalc[.exe] dcalc/src/main.d -L=libdlib.a
```

The `-L=<archive>` form forwards the archive to the underlying
linker (ldmd2/dmd refuses `.a` as a positional source on Windows
because the extension isn't a D-source extension).

Reference fixture:
[`reprobuild-examples/d-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/d-mode3/binary-with-library).

## Source layout

- Libraries: `<pkg>/src/lib.d`.
- Executables: `<pkg>/src/main.d`.

The convention recognizes the `uses:` toolchain tokens `d`, `dmd`,
`ldc2`, `gdc` (any of these mean "use a D compiler"). The driver
preference is `ldmd2` → `dmd` → `ldc2`.

## Toolchain

On hosts without a D compiler, the documented install path is the LDC
Windows download from `github.com/ldc-developers/ldc/releases` unpacked
under `D:/metacraft-dev-deps/ldc/<version>/ldc2-<version>-windows-x64/bin/`.
env.ps1 does NOT yet provision D — install it manually. The M9
harness SKIPs cleanly when no D compiler is on PATH.

## `extern (C)` for cross-language

D routines callable from C use `extern (C)`:

```d
extern (C) int dlib_add(int a, int b) {
    return a + b;
}
```

The reverse direction (C calling D) requires that the D library only
uses `core.stdc.*` (no `import std.*`, no GC, no
`Initialize_runtime`/`Terminate_runtime` bracket calls) — otherwise the
gcc/ld driver can't resolve the runtime references without linking
`phobos2` and `druntime` (which the M45 convention doesn't yet
support).

## Cross-language

- [D ↔ C/C++](../cross-language/d-and-c-cpp.md) — forward and
  reverse directions; reverse is `extern (C)` + `core.stdc.*` only.

## Scanner

No D scanner today. All cross-package edges are hand-authored.

## Outstanding limitations

- **No `dub.json` / `dub.sdl` Mode 2.** Deferred.
- **No D `import` scanner.** Hand-author edges.
- **No multi-target / multi-arch.**
- **No `dub test` / `unittest` discovery.**
- **No shared libraries.** Static archives only.
- **Full Phobos / druntime linking deferred.** Reverse cross-language
  is `extern (C)` + `core.stdc.*` only — no `import std.*` / GC.
- **No GDC support.** Only ldmd2 / dmd / ldc2 drivers.
- **D version pinning deferred.** Runs whatever compiler is on PATH.

## See also

- [Cross-language D ↔ C/C++](../cross-language/d-and-c-cpp.md)
- [Language-Conventions/D.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/D.md)
