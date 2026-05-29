# C / C++

Reprobuild supports C and C++ with the widest spread of any language:
four Mode 2 conventions for the major ecosystem build systems (Make,
CMake, Meson, Autotools) plus a Mode 3 `c-cpp-direct` convention that
builds C/C++ workspaces with no ecosystem manifest at all.

## Modes available

- **Mode 3** (`c-cpp-direct`): minimal `repro.nim`, scanner-driven
  `#include "..."` deps, no Makefile / CMakeLists / etc.
- **Mode 2 (Make)**: existing `Makefile` triggers the
  `c-cpp-make` convention.
- **Mode 2 (CMake)**: existing `CMakeLists.txt` triggers the
  `c-cpp-cmake` convention.
- **Mode 2 (Meson)**: existing `meson.build` triggers the
  `c-cpp-meson` convention.
- **Mode 2 (Autotools)**: existing `configure.ac` + `Makefile.am`
  triggers the `c-cpp-autotools` convention.
- **Mode 1**: coming soon.

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package mathlibPkg:
  uses:
    "gcc >=11"
  library mathlib

package calcPkg:
  uses:
    "gcc >=11"
  executable calc:
    discard

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B — one subdir per package):

```text
my-c-workspace/
  repro.nim
  repro.scanned-deps.nim
  mathlib/
    src/add.c                # the implementation
    include/mathlib/add.h    # the public header
  calc/
    src/calc.c               # `#include "mathlib/add.h"` + uses `add(...)`
```

The `calc/src/calc.c` `#include "mathlib/add.h"` line is what the
scanner reads to emit the `depends_on calcPkg: mathlibPkg` edge.

Build:

```text
repro build
```

Outputs:

```text
.repro/build/mathlib/libmathlib.a
.repro/build/calc/calc[.exe]
```

The `c-cpp-direct` convention emits per-source `gcc -c` actions for
each `.c` file, an `ar rcs` to produce the library archive, and a
final `gcc -o` to link the executable. Upstream `include/` dirs are
threaded onto downstream compile actions' `-I` flags.

Reference fixture:
[`reprobuild-examples/c-cpp-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/c-cpp-mode3/binary-with-library).

## Source layout (Mode 3)

The C/C++ convention recognizes:

- **Layout A** (flat): `src/*.c` + `include/<pkg>/*.h` in the package
  root.
- **Layout B** (workspace): one subdirectory per package, each with
  its own `src/` and `include/`.

Public headers go under `include/<pkg>/...` so downstream packages
include them as `#include "<pkg>/foo.h"`. Private headers can live
next to the `.c` files in `src/`.

## Mode 2 — existing build systems

### Make

```text
my-pkg/
  reprobuild.nim
  Makefile
  src/main.c
```

```nim
import repro_project_dsl

package my_pkg:
  uses:
    "gcc >=11"
    "make >=4"
  executable hello:
    discard
```

The `c-cpp-make` convention recognizes the Makefile layout and emits
per-source compile + final link actions matching what `make` would
produce, without invoking `make` itself (Option B heuristic).

Reference fixture:
[`reprobuild-examples/c-cpp-make/binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/c-cpp-make/binary).

### CMake

```text
my-pkg/
  reprobuild.nim
  CMakeLists.txt
  src/main.c
```

```nim
import repro_project_dsl

package my_pkg:
  uses:
    "gcc >=11"
    "cmake >=3.20"
  executable hello:
    discard
```

The `c-cpp-cmake` (Tier 2b) convention shells out to a stock `cmake`
binary: one `cmake -S ... -B ... -G ...` configure action plus one
`cmake --build ... --target <name>` per declared member. Prefers
**Ninja** if present, else falls back to platform make.

This is **distinct from** `reprobuild-cmake` (Tier 2c) — the forked
CMake with the embedded `cmGlobalReprobuildGenerator`. Tier 2c lifts
the build graph at fine granularity (per-target dep resolution,
try_compile probes); Tier 2b is coarse but lighter (no fork needed).

Reference fixture:
[`reprobuild-examples/c-cpp-cmake/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/c-cpp-cmake/hello-binary).

### Meson

```text
my-pkg/
  reprobuild.nim
  meson.build
  src/main.c
```

The `c-cpp-meson` convention shells out to `meson setup` + `meson
compile`. Reference fixture:
[`reprobuild-examples/c-cpp-meson/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/c-cpp-meson/hello-binary).

### Autotools

```text
my-pkg/
  reprobuild.nim
  configure.ac
  Makefile.am
  src/main.c
```

The `c-cpp-autotools` convention runs `autoreconf -fi`, then
`configure`, then `make`. Reference fixture:
[`reprobuild-examples/c-cpp-autotools/hello-binary/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/c-cpp-autotools/hello-binary).

## Picking a mode

| Project shape                                     | Mode             |
|---------------------------------------------------|------------------|
| New C/C++ workspace, no manifest                  | Mode 3           |
| Existing project with `Makefile`                  | Mode 2 (Make)    |
| Existing CMake project, want coarse-grained build | Mode 2 (CMake)   |
| Existing CMake project, want per-target caching   | Tier 2c `reprobuild-cmake` |
| Existing Meson project                            | Mode 2 (Meson)   |
| Existing autotools project (GNU classic)          | Mode 2 (Autotools) |

## Cross-language

C/C++ is the **lingua franca** of cross-language: most other languages
support calling INTO C, and many support being CALLED FROM C. See:

- [Nim ↔ C/C++](../cross-language/nim-and-c-cpp.md)
- [Rust ↔ C/C++](../cross-language/rust-and-c-cpp.md)
- [Go ↔ C/C++ (cgo)](../cross-language/go-and-c-cpp.md)
- [Fortran ↔ C/C++](../cross-language/fortran-and-c-cpp.md)
- [Zig ↔ C/C++](../cross-language/zig-and-c-cpp.md)
- [D ↔ C/C++](../cross-language/d-and-c-cpp.md)

## The scanner (Mode 3)

The C/C++ scanner reads:

- `#include "..."` (quoted form — workspace-relative)

It does NOT read `#include <...>` (the angle-bracket form is treated
as ecosystem-external — system headers, third-party deps).

## Outstanding limitations (Mode 3)

- **No external lib resolution.** No `pkg-config`, no `find_library`.
  Use Mode 2 with CMake / Meson / Autotools for non-trivial external
  deps.
- **No C++ modules.** `import std;` and `.cppm` files are not
  recognized; pre-modules `#include` only.
- **No precompiled headers.** Each compile action stands alone.
- **No `configure` step.** Conditionally-compiled source via
  `#ifdef HAVE_FOO` requires the `HAVE_FOO` to come from somewhere
  the convention sees — usually you'd switch to autotools or write a
  custom `build:` block.
- **Default flags only.** `-O2`, no `-Wall`, no
  optimization-flavor selection. For full control, drop a `build:`
  block.
- **Single-file objects only.** No unity builds.

## See also

- [Language-Conventions/C-Cpp.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/C-Cpp.md) —
  Mode 3 `c-cpp-direct` spec.
- [Language-Conventions/C-Cpp-Make.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/C-Cpp-Make.md)
- [Language-Conventions/C-Cpp-CMake.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/C-Cpp-CMake.md)
- [Language-Conventions/C-Cpp-Meson.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/C-Cpp-Meson.md)
- [Language-Conventions/C-Cpp-Autotools.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/C-Cpp-Autotools.md)
