# Fortran ↔ C/C++

The Fortran ↔ C/C++ bridge is the canonical scientific-computing
pattern: LAPACK, BLAS, FFTW, and many other numerical libraries are
Fortran kernels called from C++ application code. Reprobuild's
`fortran-direct` convention handles both directions.

## Both directions in one paragraph

- **Forward (Fortran → C):** Fortran source declares C-callable
  routines via `interface ... end interface` blocks and `bind(C)`
  attributes with `iso_c_binding`-typed parameters. The convention
  builds the C library archive (`gcc -c` + `ar rcs`) and threads it
  onto the Fortran binary's `gfortran -o` link.
- **Reverse (C → Fortran):** Fortran library declares each public
  routine with `bind(C, name="...")` to control the exported symbol.
  The convention builds the Fortran archive (`gfortran -c` + `ar
  rcs`), threads `-lgfortran -lquadmath -lm` (Fortran runtime libs)
  onto the C/C++ binary's link line plus the archive as a positional.

## Minimal fixture (reverse — C++ binary calls Fortran library)

This is the classic LAPACK pattern: numerical kernel in Fortran,
application logic in C++.

`repro.nim`:

```nim
import repro_project_dsl

package fortlib:
  uses:
    "gfortran"
  library fortlib

package cppcalc:
  uses:
    "gcc >=11"
  executable cppcalc:
    discard

depends_on cppcalc: fortlib

include "repro.scanned-deps.nim"
```

Layout:

```text
cpp-uses-fortran-lib/
  repro.nim
  repro.scanned-deps.nim
  fortlib/src/lib.f90
  cppcalc/src/main.cpp
```

`fortlib/src/lib.f90`:

```fortran
function fort_add(a, b) bind(C, name="fort_add") result(r)
  use iso_c_binding
  integer(c_int), value :: a, b
  integer(c_int) :: r
  r = a + b
end function fort_add
```

`cppcalc/src/main.cpp`:

```cpp
#include <iostream>

extern "C" int fort_add(int a, int b);

int main() {
    std::cout << "cpp says: fortran added 2+3 = " << fort_add(2, 3) << "\n";
    return 0;
}
```

Build:

```text
repro build
```

`c-cpp-direct` owns the workspace (C++ binary consumer), emits the
Fortran archive in-line via `gfortran -c` + `ar rcs`, threads the
archive as a trailing positional plus `-lgfortran -lquadmath -lm` on
the `g++ -o` link.

Reference fixture:
[`reprobuild-examples/mixed/cpp-uses-fortran-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/cpp-uses-fortran-lib).

## Forward direction (Fortran → C)

Reference fixture:
[`reprobuild-examples/mixed/fortran-uses-cpp-lib/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/mixed/fortran-uses-cpp-lib).

`fortcalc/src/main.f90`:

```fortran
program fortcalc
  use iso_c_binding
  implicit none
  interface
    function c_add(a, b) bind(C, name="c_add") result(r)
      use iso_c_binding
      integer(c_int), value :: a, b
      integer(c_int) :: r
    end function c_add
  end interface
  print *, "fortran says: c added 2+3 =", c_add(2_c_int, 3_c_int)
end program
```

`mathlib/src/c_add.c`:

```c
#include "mathlib/c_add.h"
int c_add(int a, int b) { return a + b; }
```

`repro.nim`:

```nim
package mathlib:
  uses:
    "gcc >=11"
  library mathlib

package fortcalc:
  uses:
    "gfortran"
  executable fortcalc:
    discard

depends_on fortcalc: mathlib
```

## Required declarations

- **Fortran side:**
  - `use iso_c_binding` to get `c_int`, `c_double`, etc.
  - `bind(C, name="<symbol>")` to control the exported symbol name —
    without this, gfortran applies its own name mangling (typically
    appending an underscore) and the C side won't find the symbol.
  - `integer(c_int), value` (or `real(c_double), value`) for
    pass-by-value semantics matching C calling conventions.

- **C side:** ordinary `extern "C"` (in C++) or no markup (in C). The
  Fortran-side `bind(C, name="...")` ensures the symbol name matches
  what `extern int foo(int);` expects.

## Runtime libs

When a C/C++ binary consumes a Fortran archive, the link line needs:

- `-lgfortran` — the gfortran runtime (I/O, intrinsics, etc.).
- `-lquadmath` — quadruple-precision math support (always linked by
  gfortran; needed if Fortran code uses `real(16)`).
- `-lm` — standard math library.

The `fortran-direct` convention threads these automatically when it
sees a C/C++ binary consuming a Fortran library.

## Outstanding limitations

- **No automatic interface generation.** Write `interface` blocks
  and C headers by hand.
- **Scanner blind to `bind(C)` declarations.** Hand-author
  `depends_on` edges.
- **No coarray / OpenMP / MPI support** in either direction.
- **Pass-by-reference vs pass-by-value.** Fortran defaults to
  pass-by-reference; use `, value` attribute on the Fortran side or
  pointer types on the C side, but not both. The convention doesn't
  diagnose mismatches.
- **Array passing.** Single-element arrays work; multi-dimensional
  arrays with non-trivial strides need explicit interop layer
  (`c_loc`, `c_f_pointer` etc.) that the convention doesn't
  abstract.

## See also

- [Fortran language page](../languages/fortran.md)
- [C/C++ language page](../languages/c-cpp.md)
- [Cross-language overview](README.md)
