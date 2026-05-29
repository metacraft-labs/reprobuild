# Go

Reprobuild builds Go workspaces in Mode 3 by invoking `go tool compile`
and `go tool link` directly, bypassing `go build` for the in-workspace
case. For external Go modules (`go.mod` deps), Mode 2 delegates to
`go build`.

## Modes available

- **Mode 3**: `repro.nim` + per-package Go sources. No `go.mod`.
- **Mode 2**: existing `go.mod` / `go.work`. Reprobuild delegates to
  `go build`.
- **Mode 1**: layout-as-manifest (M48, 2026-05-29). Drop sources under
  `apps/<name>/main.go` + `libs/<name>/<name>.go`, run `repro build`.
  See [The Three Modes §Mode 1](../three-modes.md#mode-1--layout-as-manifest).

## Quickstart (Mode 3)

Minimal `repro.nim`:

```nim
import repro_project_dsl

package mathlibPkg:
  uses:
    "go"
  library mathlib

package calcPkg:
  uses:
    "go"
  executable calc:
    discard

include "repro.scanned-deps.nim"
```

Minimal layout (Layout B — flat per-package):

```text
my-go-workspace/
  repro.nim
  repro.scanned-deps.nim
  mathlib/
    add.go                   # `package mathlib; func Add(a, b int) int { ... }`
  calc/
    main.go                  # `import "mathlib"; func main() { ... }`
```

The `calc/main.go` `import "mathlib"` line is what the scanner reads
to emit the `depends_on calcPkg: mathlibPkg` edge.

Build:

```text
repro build
```

Outputs:

```text
.repro/build/mathlib/mathlib.a    # Go archive
.repro/build/calc/calc[.exe]
```

The `go-direct` convention runs `go tool compile -p mathlib -o
mathlib.a` for the library, then `go tool compile -importcfg ...`
plus `go tool link -importcfg.link ...` for the executable. The
upstream archive is threaded onto the executable's `importcfg` so
`import "mathlib"` resolves at compile and link time.

Reference fixture:
[`reprobuild-examples/go-mode3/binary-with-library/`](https://github.com/metacraft-labs/reprobuild-examples/tree/main/go-mode3/binary-with-library).

## Source layout

The Go convention recognizes:

**Layout A (flat single-package).** Sources directly in the package
directory:

```text
my-pkg/
  repro.nim
  main.go
  helpers.go
```

**Layout B (workspace).** One subdirectory per package:

```text
my-workspace/
  repro.nim
  mathlib/add.go
  calc/main.go
```

## Mode 2 escape hatch

If you have a `go.mod`, the standard provider switches to Mode 2 and
shells out to `go build`:

```text
my-go-pkg/
  reprobuild.nim
  go.mod                       # ecosystem manifest
  main.go
```

The minimal `reprobuild.nim` shim is:

```nim
import repro_project_dsl

package my_pkg:
  uses:
    "go"
  executable my_pkg:
    discard
```

Use Mode 2 when:
- You depend on **external Go modules** (anything under
  `require (...)` in `go.mod`).
- You need `go generate` codegen steps.
- You need build tags / `//go:build` constraints with conditional
  files.

## Cross-language

- [Go ↔ C/C++ via cgo](../cross-language/go-and-c-cpp.md) — Go binary
  calls a C library via `import "C"`. The convention falls back from
  `go tool compile` to `go build` since cgo requires the full Go
  pipeline.

## The scanner

The Go scanner reads:

- `import "module/path"`
- `import _ "path"` (blank-import side-effects)
- `import` blocks (multi-line)

It matches the import path against workspace package names. Imports
that don't resolve to a workspace package are ecosystem-external and
ignored.

`import "C"` cgo blocks are NOT picked up automatically — the
`#include "..."` directives inside the cgo preamble don't get folded
into the dep graph. Hand-author cross-language `depends_on` edges.

## Outstanding limitations

- **No external module resolution in Mode 3.** Adding a `go.mod` is
  the supported graduation path. Standard library is fine.
- **No cgo in Mode 3 fast path.** cgo requires `go build`, which
  triggers a Mode-2-style fallback to the full Go pipeline. Works,
  but isn't on the action-graph fast path.
- **No `go generate`.** Codegen steps must be expressed as separate
  packages with a `build:` block.
- **No test discovery.** `_test.go` files are not yet enumerated by
  Mode 3. Use Mode 2 (`go test`) or a `build:` block.
- **No build tags.** Conditional source files via `//go:build` are
  not respected by Mode 3.
- **GOPATH layout NOT supported.** Mode 3 assumes module-style
  workspace layout (one directory = one package), not the legacy
  `$GOPATH/src/...` tree.

## See also

- [Cross-language Go ↔ C/C++](../cross-language/go-and-c-cpp.md)
- [Language-Conventions/Go.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Language-Conventions/Go.md) —
  contributor-facing convention spec.
