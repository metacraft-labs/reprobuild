# Fortran

Reprobuild's Fortran Mode 3 (`fortran-direct`) uses `gfortran` to
compile Fortran sources into static archives and link executables. The
canonical LAPACK-style "Fortran library called from a C binary" is the
flagship cross-language case.

## Modes available

- **Mode 3** (`fortran-direct`): minimal `repro.nim` + `gfortran`
  workflow. No ecosystem manifest.
- **Mode 2**: `fpm.toml` recognition (Fortran Package Manager) is
  **deferred** — no Mode 2 Fortran convention today.
- **Mode 1**: not yet (Fortran scanner not implemented).

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package fortlibPkg:
  uses:
    "gfortran"
  library fortlib

package fortcalcPkg:
  uses:
    "gfortran"
  executable fortcalc:
    discard

# Manual dep edge: no Fortran scanner yet, so cross-package edges
# are hand-authored.
depends_on fortcalcPkg: fortlibPkg

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B — one subdir per package):

```text
my-fortran-workspace/
  repro.nim
  repro.scanned-deps.nim
  fortlib/src/lib.f90        # `bind(C)` function exporting `lib_add`
  fortcalc/src/main.f90      # calls into fortlib
```

Build:

```text
repro build
```

Outputs:

```text
.repro/build/fortlib/libfortlib.a
.repro/build/fortcalc/fortcalc[.exe]
```

The convention emits `gfortran -c -o ...` per source plus `ar rcs`
for the archive plus `gfortran -o ...` for the executable link. The
`gfortran` driver pulls in `libgfortran` + `libquadmath` + `libm`
automatically.

Reference fixture:
[`reprobuild-examples/fortran-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/fortran-mode3/binary-with-library).

## Source layout

Each package's Fortran source goes under `<pkg>/src/`. Files have
`.f90` extension (free-form Fortran 90+). Older `.f` / `.f77`
fixed-form sources are not currently recognized — convert to
free-form or write a `build:` block.

## `bind(C)` for cross-language

Fortran routines callable from C need an explicit `bind(C)` attribute
and `iso_c_binding`-typed parameters:

```fortran
function lib_add(a, b) bind(C, name="lib_add") result(r)
  use iso_c_binding
  integer(c_int), value :: a, b
  integer(c_int) :: r
  r = a + b
end function
```

The `bind(C, name="...")` controls the symbol exposed to the linker.
Without it, gfortran applies its own name mangling and the C side
can't find the symbol.

## Cross-language

- [Fortran ↔ C/C++](../cross-language/fortran-and-c-cpp.md) —
  bidirectional, the LAPACK pattern.

## Scanner

The Fortran convention does **not** ship a `USE` / `CALL` scanner. All
cross-package edges are hand-authored in `repro.nim` via
`depends_on`. A future milestone will add a Fortran scanner that reads
`USE module_name` lines.

`repro deps refresh` still runs and rewrites `repro.scanned-deps.nim`,
but for now the file is essentially empty for Fortran-only workspaces.

## Outstanding limitations

- **No `USE` / `MODULE` scanner.** Hand-author `depends_on` edges.
- **No `.mod` file tracking.** gfortran's per-module `.mod` files
  aren't yet inputs to dependent compiles, so multi-module workspaces
  may not pick up `.mod` regeneration cleanly.
- **No fixed-form sources.** `.f` / `.f77` not recognized.
- **No `fpm.toml` Mode 2.** Fortran Package Manager support is
  deferred.
- **No coarray / OpenMP / OpenACC flags.** Default `gfortran` flags
  only. Use a `build:` block for parallel-Fortran knobs.
- **Single-arch only.** No cross-compilation.

## See also

- [Cross-language Fortran ↔ C/C++](../cross-language/fortran-and-c-cpp.md)
- [Language-Conventions/Fortran.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Fortran.md)
