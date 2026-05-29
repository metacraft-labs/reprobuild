# Python

Reprobuild's Python Mode 3 stages sources into the build directory,
runs `python -m compileall` to byte-compile them, and writes a small
launcher wrapper that sets `PYTHONPATH` to the staging dir. There's no
packaging-tool involvement — no `pip`, no `setuptools`, no
`virtualenv`.

## Modes available

- **Mode 3**: `repro.nim` + per-package Python sources. No
  `pyproject.toml` / `setup.py`.
- **Mode 2**: existing `pyproject.toml` / `setup.py` triggers
  Mode 2 (delegates to `pip install -e .` or `python -m build`).
- **Mode 1**: layout-as-manifest (M48, 2026-05-29). Drop sources under
  `apps/<name>/__main__.py` + `libs/<name>/__init__.py`, run
  `repro build`. See
  [The Three Modes §Mode 1](../three-modes.md#mode-1--layout-as-manifest).

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package mathlibPkg:
  uses:
    "python3"
  library mathlib

package calcPkg:
  uses:
    "python3"
  executable calc:
    discard

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B-flat — Python's nested package directories):

```text
my-python-workspace/
  repro.nim
  repro.scanned-deps.nim
  mathlib/
    mathlib/                 # ← package directory (same name as outer)
      __init__.py            # `def add(a, b): return a + b`
  calc/
    calc/
      __init__.py
      __main__.py            # `from mathlib import add; print(add(2, 3))`
```

The `calc/calc/__main__.py` `from mathlib import add` line is what
the scanner reads to emit the `depends_on calcPkg: mathlibPkg` edge.

Build:

```text
repro build
```

Outputs:

```text
.repro/build/mathlib/                # staged sources + .pyc bytecode
.repro/build/calc/                   # staged sources + .pyc bytecode
.repro/build/calc/calc[.exe]         # launcher wrapper script
```

The launcher's `PYTHONPATH` includes the staged `mathlib/` dir so
`from mathlib import add` resolves at runtime.

Reference fixture:
[`reprobuild-examples/python-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/python-mode3/binary-with-library).

## Source layout

The Python convention recognizes the standard nested package layout:
each workspace package's directory contains a same-named subdirectory
holding `__init__.py` (and optionally `__main__.py` for executables).
This matches what `pip install` would lay down for an installed
package.

## Mode 2 escape hatch

If you have a `pyproject.toml` (or `setup.py`), the standard provider
delegates to packaging tools:

```text
my-pkg/
  reprobuild.nim
  pyproject.toml                # ecosystem manifest
  src/
    my_pkg/__init__.py
```

Use Mode 2 when:
- You depend on **PyPI** packages.
- You need to ship a **wheel** / **sdist**.
- You use **setuptools**, **poetry**, or **pdm** with custom build
  steps.
- You need **C extensions** (`setuptools` extension modules).

The Python Mode 3 convention deliberately does NOT touch PyPI or
virtual environments — that's Mode 2's job.

## The scanner

The Python scanner reads:

- `import foo`
- `from foo import ...`
- Package-relative `from . import ...` (mapped to current package)
- `from foo.bar import ...`

Imports that match a workspace package name produce a `depends_on`
edge. Imports that don't are ecosystem-external.

## Outstanding limitations

- **No PyPI dep resolution.** Mode 3 has no `pip`. Use Mode 2 with
  `pyproject.toml` if you need PyPI deps.
- **No virtualenv.** Mode 3 runs against the host Python. If you need
  isolation, use Mode 2.
- **No C extension support.** Mode 3 doesn't build `setuptools`-style
  C extensions. Use Mode 2.
- **No dynamic `__path__` magic.** Packages that mutate `__path__` at
  import time (namespace packages, etc.) may not be picked up by the
  scanner.
- **Conditional imports inside functions.** The scanner reads
  top-level imports only; `import foo` inside a function body is not
  detected.
- **`__pycache__` placement is per-stage.** Bytecode lives next to the
  staged sources under `.repro/build/`, not next to the originals.

## See also

- [Language-Conventions/Python.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Python.md) —
  contributor-facing convention spec.
