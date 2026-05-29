# Zig

Reprobuild's Zig Mode 3 (`zig-direct`) uses `zig build-exe` and
`zig build-lib` directly, bypassing `zig build` and `build.zig`. The
convention emits static archives for libraries and links executables
against them with the archive bundled as a trailing positional on the
link argv.

## Modes available

- **Mode 3** (`zig-direct`): minimal `repro.nim` + `zig build-exe`
  / `zig build-lib`. No `build.zig`.
- **Mode 2**: `build.zig` delegation is **deferred** — `build.zig` is
  itself Zig code and lifting it would require invoking `zig build`
  blindly without per-member visibility.
- **Mode 1**: not yet (Zig scanner not implemented).

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package ziglibPkg:
  uses:
    "zig"
  library ziglib

package zigcalcPkg:
  uses:
    "zig"
  executable zigcalc:
    discard

depends_on zigcalcPkg: ziglibPkg

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B):

```text
my-zig-workspace/
  repro.nim
  repro.scanned-deps.nim
  ziglib/src/root.zig        # `export fn ziglib_add(a, b: i32) i32`
  zigcalc/src/main.zig       # `extern fn ziglib_add(a, b: i32) i32`
```

Build:

```text
repro build
```

Outputs:

```text
.repro/build/ziglib/libziglib.a
.repro/build/zigcalc/zigcalc[.exe]
```

The convention runs:

```text
zig build-lib -O ReleaseSafe --name ziglib -femit-bin=libziglib.a ziglib/src/root.zig
zig build-exe -O ReleaseSafe --name zigcalc -femit-bin=zigcalc[.exe] \
   zigcalc/src/main.zig libziglib.a
```

Zig's `build-exe` driver forwards the trailing archive to the
underlying linker which resolves the cross-package symbol. Zig static
archives bundle the minimal compiler-rt routines so no extra runtime
libs are needed.

Reference fixture:
[`reprobuild-examples/zig-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/zig-mode3/binary-with-library).

## Source layout

- Libraries: `<pkg>/src/root.zig` (Zig's conventional library
  entry name).
- Executables: `<pkg>/src/main.zig`.

## Toolchain

The convention runs against whatever `zig` is on `PATH`. On hosts
without `zig`, the documented install path is the ziglang.org
download unpacked under `D:/metacraft-dev-deps/zig/<version>/zig.exe`
(on Windows; equivalent prefix on macOS/Linux). The M9 harness SKIPs
cleanly when `zig` is missing.

## Cross-language

- [Zig ↔ C/C++](../cross-language/zig-and-c-cpp.md) — Zig exposes
  C-ABI symbols naturally via `export fn ...` and consumes C symbols
  via `extern fn ...`.

## Scanner

No Zig scanner today. All cross-package edges are hand-authored in
`repro.nim` via `depends_on`. A future milestone will add a Zig
`@import` / `extern` scanner.

## Outstanding limitations

- **No `build.zig` Mode 2.** Deferred.
- **No `build.zig.zon` package manifest.** External deps not
  supported.
- **No multi-target / multi-arch.** Default host triple only.
- **No `zig test` discovery.** Test stanzas in `.zig` files aren't
  enumerated.
- **No WebAssembly target.** `zig build-exe -target wasm32-...` would
  need a `build:` block.
- **No async runtime.** Zig's async is not on the Mode 3 fast path.
- **Shared libraries deferred.** Only static archives (`.a`) emitted.
- **Zig version pinning deferred.** Runs whatever `zig` is on PATH.

## See also

- [Cross-language Zig ↔ C/C++](../cross-language/zig-and-c-cpp.md)
- [Language-Conventions/Zig.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Zig.md)
