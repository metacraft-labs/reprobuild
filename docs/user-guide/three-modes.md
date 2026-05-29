# The Three Modes

Reprobuild describes a project to its action graph through one of three
modes, distinguished by how much you write by hand. The modes coexist
in the same workspace — you don't pick one and live with it forever.

This page is the user-facing summary. For the full design spec, see
[Three-Mode-Convention-System.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Three-Mode-Convention-System.md)
in `reprobuild-specs/`.

## Mode 1 — layout-as-manifest *(supported for Nim, Rust, Go, Python, JS/TS, C/C++, Fortran, Zig, D)*

In Mode 1 the directory tree IS the spec. There is no project file at
all. You drop files into directories whose names match a recognized
layout convention (`apps/<name>/`, `libs/<name>/`, `tools/<name>/`,
plus per-ecosystem alternates like `cmd/<name>/`, `pkg/<name>/`,
`bin/<name>/`) and reprobuild figures out the rest from a file-extension
census and an import scan.

```text
my-monorepo/
  apps/
    calc/
      src/
        main.rs            # `use mathlib::add;`
  libs/
    mathlib/
      src/
        lib.rs             # `pub fn add(a: i32, b: i32) -> i32`
```

Run `repro build` from the workspace root. The Mode 1 loader walks
`apps/<name>/` + `libs/<name>/`, censuses extensions (both targets are
Rust here), synthesises an in-memory `repro.nim` + `repro.scanned-deps.nim`
under `.repro/mode1-synth/`, and dispatches to the rust-direct
convention. NOTHING is written to your workspace root — the synth tree
is plain build scratch.

Mode 1 reuses the Mode 3 scanner; the only difference is "do we persist
the scanner's output to disk?" In Mode 1 the answer is no — the
inferred dep graph lives only in memory and is recomputed every build.

**Status: M48 (2026-05-29).** Mode 1 ships for the Mode 3 languages:
Nim, Rust, Go, Python, JS/TS, C/C++, Fortran, Zig, D. Phase 3
conventions (Java/Maven, Kotlin/Gradle, C#/.NET, Swift/SwiftPM,
OCaml/Dune) are NOT meaningful in Mode 1 — they require an ecosystem
manifest by construction. Mixed-language Mode 1 workspaces are
DEFERRED; the loader errors out and points you to Mode 3.

### Mode 1 debugging — `repro show-conventions`

Mode 1's defining failure mode is silent wrong-builds on ambiguous
imports. `repro show-conventions` is the load-bearing window into what
the loader inferred:

```text
$ repro show-conventions my-monorepo
[Mode 1 — inferred from layout]
Project: D:/work/my-monorepo
Project file: (none — Mode 1 synthesises in-memory)

Inferred targets:
  - calc (executable)
    Source dir: apps/calc
    Language: rust
    Entry source: apps/calc/src/main.rs
    Extension census: .rs=1
  - mathlib (library)
    Source dir: libs/mathlib
    Language: rust
    Entry source: libs/mathlib/src/lib.rs
    Extension census: .rs=1

Inferred dep edges (scanner):
  - apps/calc -> libs/mathlib (evidence: apps/calc/src/main.rs:7: use mathlib::add;)
```

When the loader sees an ambiguous import (e.g. `use greet::hi;` that
could resolve to both `libs/greet/` and `tools/greet/`), it HARD-ERRORS:

```text
$ repro build my-ambig-workspace
Mode 1: ambiguous import detected in D:/work/my-ambig-workspace
  - apps/hello/src/main.rs:1: import 'greet' resolves to candidates: libs/greet, tools/greet

Resolve by graduating to Mode 3: write a repro.nim with explicit `depends_on` lines naming the intended target.
```

No silent pick. No wrong build.

## Mode 2 — delegate to ecosystem build systems

The project already has a `Cargo.toml` / `pyproject.toml` /
`package.json` / `Makefile.am` / `CMakeLists.txt` / `<pkg>.nimble`.
Reprobuild's standard provider recognizes the manifest, reads it, and
emits per-source compile actions tuned to that ecosystem's conventions.

```text
my-rust-crate/
  Cargo.toml                       # ecosystem manifest
  reprobuild.nim                   # tiny shim — declares the package
  src/
    main.rs
    lib.rs
```

The `reprobuild.nim` is a one-line shim — it declares the package
exists and what toolchain it uses. The interesting metadata
(dependencies, source layout, link order) all lives in the ecosystem
manifest, where the ecosystem's own tools can read it.

Mode 2 is the **robust** choice. The ecosystem's graph is the source
of truth: `cargo metadata`, `npm ls`, the autotools-generated Makefile,
or the CMake-driven generator answers "what does this build?" with
authority. When the input doesn't fit the convention, the standard
provider bails cleanly to "no convention matched" and you can fall back
to Tier 1 with an explicit `build:` block.

**Use Mode 2 when:**
- You already have an ecosystem manifest (existing project).
- You need external package management (`cargo`, `pip`, `npm`, etc.).
- You want to keep IDE / editor / language-server integration that
  depends on the ecosystem manifest being present.

## Mode 3 — minimal curated `repro.nim` *(recommended default)*

A small `repro.nim` declares packages, their `uses:` constraints, and
their inter-package dependencies. Everything else — sources, layout,
member discovery, test discovery, link order — comes from the language
conventions. You write only what conventions cannot infer.

```nim
# repro.nim
import repro_project_dsl

package greet:
  uses:
    "go"
  library greet

package hello:
  uses:
    "go"
  executable hello:
    discard

# Workspace-internal dep graph, regenerated by `repro deps refresh`.
include "repro.scanned-deps.nim"
```

That's the entire project file for a two-target Go workspace. No
`build:` block (the standard provider supplies it), no source paths
(the Go convention locates `cmd/hello/main.go` and `greet/`), no test
enumeration.

The `repro.scanned-deps.nim` file is **computer-authored** — generated
by `repro deps refresh`, with a "DO NOT EDIT" header. Reprobuild walks
the workspace, reads import lines from your sources, and emits the
inter-target dependency edges into that file. You commit it; CI checks
that it's up to date via `repro deps refresh --check`.

**Use Mode 3 when:**
- New project, no ecosystem manifest yet.
- You want a single workspace describing several packages without
  one ecosystem manifest per package.
- You want a clean boundary between "what I wrote" (`repro.nim`) and
  "what the scanner inferred" (`repro.scanned-deps.nim`) for
  review-time clarity.

## Decision flowchart — which mode?

```text
                ┌──────────────────────────────────┐
                │  Do you already have a manifest? │
                │  (Cargo.toml, package.json, ...) │
                └───────────────┬──────────────────┘
                                │
                       yes ◄────┴────► no
                        │              │
                        ▼              ▼
              ┌──────────────┐   ┌──────────────────────┐
              │ Use Mode 2.  │   │ Do you need external │
              │ Add a one-   │   │ ecosystem deps?      │
              │ line shim    │   │ (crates.io, pypi,    │
              │ reprobuild   │   │  npm, ...)           │
              │ .nim.        │   └──────┬───────────────┘
              └──────────────┘          │
                              yes ◄─────┴─────► no
                               │                │
                               ▼                ▼
                       ┌──────────────┐  ┌──────────────┐
                       │ Use Mode 2.  │  │ Use Mode 3.  │
                       │ Write the    │  │ Write a      │
                       │ ecosystem    │  │ small        │
                       │ manifest.    │  │ repro.nim.   │
                       └──────────────┘  └──────────────┘
```

**One additional rule:** if the convention doesn't fit (you have a
custom code-generation step, or a non-stock build tool, or you need a
specific compiler flag the convention doesn't thread), add an explicit
`build:` block to the package. That graduates that one package to
Tier 1 — fully imperative, exactly as expressive as a raw shell script.
You don't lose any other automation; the rest of the workspace stays in
its mode.

## Migration paths

Reprobuild's modes are designed so you can graduate between them with
minimal disruption.

### Mode 1 → Mode 3

Run `repro init` once. It writes a starter `repro.nim` describing the
packages it discovered plus the initial `repro.scanned-deps.nim`. After
that you own the `repro.nim` and `repro deps refresh` keeps the scanned
file current. *(Available once Mode 1 ships.)*

### Mode 3 → Mode 2

Add the ecosystem manifest (`Cargo.toml`, `pyproject.toml`, etc.) to
the package's directory. The standard provider sees the manifest and
switches that package over to Mode 2. You can keep the `repro.nim`
entry — or even simplify it to the Mode 2 shim form — and the rest of
the workspace is unaffected.

### Mode 2 → escape hatch (Tier 1)

Add a `build:` block to the package's `repro.nim` (or
`reprobuild.nim`). The standard provider stops trying to recognize the
package and the `build:` block runs verbatim. Use this when you need
a feature the convention doesn't have — custom codegen, non-stock
compilers, etc. — without abandoning reprobuild entirely.

### Any direction is fine

You can move packages between modes one at a time, and the rest of the
workspace doesn't notice. There is no "monorepo flag day" required.

## What about the `repro deps refresh` CLI?

Mode 3's `repro.scanned-deps.nim` file is regenerated by:

```text
repro deps refresh                  # scan from cwd, write next to repro.nim
repro deps refresh --check          # exit non-zero if regeneration would change anything
repro deps refresh path/to/project  # scan a specific workspace
```

The `--check` form is the **CI gate**: wire it into your CI pipeline
(GitHub Actions, pre-commit, `just verify`, etc.) and it'll fail the
build if anyone forgets to refresh after touching imports. Analogous to
`gofmt -l` in CI.

The refresh command writes only to `repro.scanned-deps.nim`. It NEVER
edits `repro.nim`, NEVER touches user-authored files. The human /
computer authorship boundary is a **file boundary**, not a region or
comment marker.

## Related reading

- [Three-Mode-Convention-System.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Three-Mode-Convention-System.md) —
  the contributor-facing design spec.
- [Package-Model.md](https://github.com/metacraft-labs/reprobuild-specs/blob/main/Package-Model.md) —
  the `repro.nim` DSL surface (`package`, `uses:`, `executable`,
  `library`, `files`).
- [Language-Conventions/](https://github.com/metacraft-labs/reprobuild-specs/tree/main/Language-Conventions) —
  the per-language recognition rules that Modes 1 and 2 share.
- [Getting Started](getting-started.md) — five-minute walkthrough.
