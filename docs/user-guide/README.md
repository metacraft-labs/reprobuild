# Reprobuild User Guide

Reprobuild (CLI: `repro`) is a build system that combines reproducible
environments, automatic dependency discovery, incremental rebuilds with
artifact caching, and distributed execution. This guide is the
**user-facing** entry point: it covers how to describe a project to
reprobuild and how to build it, language by language.

If you are a contributor or want to learn about engine internals, see
the [contributor-facing specs in `reprobuild-specs/`](https://github.com/metacraft-labs/reprobuild-specs)
instead.

## Quick navigation

- **New to reprobuild?** Start with [Getting Started](getting-started.md) for a
  five-minute tutorial that goes from `git clone` to a working binary.
- **Picking a project shape?** Read [The Three Modes](three-modes.md) to
  understand the Mode 1 / Mode 2 / Mode 3 model and pick the right one
  for your project.
- **Per-language details:** see the [Languages](#languages) table below.
- **Mixing languages in one workspace:** see
  [Cross-Language Builds](cross-language/README.md).
- **Common patterns and recipes:** see [Recipes](recipes/README.md).

## What is reprobuild?

Reprobuild reads a small project file called `repro.nim` (or, in some
cases, no project file at all) plus an ecosystem manifest like
`Cargo.toml`, `pyproject.toml`, or `CMakeLists.txt` if one exists, and
turns the result into a deterministic action graph. Every build is
incremental and cached by hash of its inputs, so a `repro build` after
a no-op change is a no-op, and a `repro build` after a one-file change
rebuilds only what that file affects.

There are three ways to describe a project to reprobuild, distinguished
by how much you write by hand:

- **Mode 1 — layout-as-manifest.** The directory tree itself is the
  spec. No project file. *(Shipped in M48, 2026-05-29, for the Mode 3
  languages: Nim, Rust, Go, Python, JS/TS, C/C++, Fortran, Zig, D. See
  [The Three Modes](three-modes.md#mode-1--layout-as-manifest).)*
- **Mode 2 — delegate to ecosystem build systems.** You already wrote
  a `Cargo.toml` / `pyproject.toml` / `CMakeLists.txt` / etc. Reprobuild
  reads it and emits the corresponding actions.
- **Mode 3 — minimal curated `repro.nim`.** A small hand-authored file
  declares packages and the inter-package dependency graph; conventions
  cover everything else. This is the recommended default for new
  projects.

Both modes coexist in the same workspace: you can have a Cargo crate
sitting next to a Mode 3 Python tree under one `repro.nim` umbrella.

## Languages

Reprobuild's standard provider has per-language conventions for the
languages below. Each per-language page covers:

- The minimal `repro.nim` (or ecosystem manifest) you need.
- The minimum source layout.
- Which modes are supported today.
- The escape hatch for features the standard provider doesn't cover.
- Honest limitations the convention has today.

| Language                    | Mode 3       | Mode 2 manifest(s)                     | Page                                              |
|-----------------------------|--------------|----------------------------------------|---------------------------------------------------|
| Nim                         | yes          | `<pkg>.nimble`                         | [nim.md](languages/nim.md)                        |
| Rust                        | yes          | `Cargo.toml`                           | [rust.md](languages/rust.md)                      |
| Go                          | yes          | `go.mod`                               | [go.md](languages/go.md)                          |
| Python                      | yes          | `pyproject.toml`, `setup.py`           | [python.md](languages/python.md)                  |
| JavaScript / TypeScript     | yes          | `package.json`                         | [javascript-typescript.md](languages/javascript-typescript.md) |
| C / C++                     | yes (direct) | `Makefile`, `CMakeLists.txt`, `meson.build`, `configure.ac` | [c-cpp.md](languages/c-cpp.md) |
| Fortran                     | yes          | (Mode 2 deferred)                      | [fortran.md](languages/fortran.md)                |
| Zig                         | yes          | (Mode 2 `build.zig` deferred)          | [zig.md](languages/zig.md)                        |
| D                           | yes          | (Mode 2 `dub.json` deferred)           | [d.md](languages/d.md)                            |
| Java                        | no           | `pom.xml` (Maven)                      | [java.md](languages/java.md)                      |
| Kotlin                      | no           | `build.gradle.kts`                     | [kotlin.md](languages/kotlin.md)                  |
| C# / .NET                   | no           | `*.csproj`                             | [csharp.md](languages/csharp.md)                  |
| Swift                       | no           | `Package.swift`                        | [swift.md](languages/swift.md)                    |
| OCaml                       | no           | `dune-project` + `dune`                | [ocaml.md](languages/ocaml.md)                    |

"Mode 3: yes" means you can build a project in this language without
writing an ecosystem manifest at all — a `repro.nim` is enough. "Mode 2"
means reprobuild will recognize and delegate to that ecosystem's build
system if its manifest is present.

For languages where Mode 3 is not yet supported (Java, Kotlin, C#,
Swift, OCaml), you must use the ecosystem's build system — reprobuild
shells out to `mvn` / `gradle` / `dotnet` / `swift build` / `dune build`.
Those conventions are honest delegators: they don't lift the build into
the action cache; they just sequence the ecosystem tool.

## Cross-language builds

Reprobuild supports a single workspace mixing multiple languages — for
example a Rust binary linking against a C static library, or a Nim
binary calling into a Rust library. See
[Cross-Language Builds](cross-language/README.md) for the supported
combinations and the patterns each one uses.

| Combination               | Page                                                                   |
|---------------------------|------------------------------------------------------------------------|
| Nim ↔ C/C++               | [nim-and-c-cpp.md](cross-language/nim-and-c-cpp.md)                    |
| Rust ↔ C/C++              | [rust-and-c-cpp.md](cross-language/rust-and-c-cpp.md)                  |
| Nim ↔ Rust                | [nim-and-rust.md](cross-language/nim-and-rust.md)                      |
| Go ↔ C/C++ (cgo)          | [go-and-c-cpp.md](cross-language/go-and-c-cpp.md)                      |
| Fortran ↔ C/C++           | [fortran-and-c-cpp.md](cross-language/fortran-and-c-cpp.md)            |
| Zig ↔ C/C++               | [zig-and-c-cpp.md](cross-language/zig-and-c-cpp.md)                    |
| D ↔ C/C++                 | [d-and-c-cpp.md](cross-language/d-and-c-cpp.md)                        |

## Recipes

- [Common recipes](recipes/README.md): collected one-page how-tos for
  things that show up often (refreshing the scanned-deps file, dropping
  to a `build:` block when the convention doesn't fit, etc.).

## Related documentation

- [Reprobuild docs home](../README.md) — the rest of the docs in this
  repo, including engine internals and capabilities.
- [reprobuild-specs](https://github.com/metacraft-labs/reprobuild-specs) —
  contributor-facing design docs and convention specs.
- [reprobuild-examples](https://github.com/metacraft-labs/reprobuild-examples) —
  end-to-end fixtures for every supported language and cross-language
  combination. Every page in this guide points at the corresponding
  fixture.
