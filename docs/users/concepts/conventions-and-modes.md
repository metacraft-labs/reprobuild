---
title: Conventions and the three modes
description: Why most projects need little or no project file, how reprobuild chooses between a project's layout, its ecosystem manifest and its project file, and when to move from one mode to another.
kind: explanation
persona: build-maintainer
domain: build
order: 10
verifies:
  commands: [build, show-conventions, deps refresh]
unverified:
  - claim: "In Mode 1 reprobuild writes nothing to the project directory; what it infers lives under .repro/."
    reason: "Stated in the existing three-modes guide; no test is cited yet."
    owner: unassigned
  - claim: "Mode 1 stops with an error on an import that matches more than one candidate."
    reason: "Stated, with sample output, in the existing three-modes guide; no test is cited yet."
    owner: unassigned
  - claim: "Mode 1 does not accept a mix of languages in one layout."
    reason: "Stated in the existing three-modes guide; no test is cited yet."
    owner: unassigned
  - claim: "Where a package has an ecosystem manifest, reprobuild reads it in Mode 2; Mode 3 does not cover registries, build scripts, code-generation plugins or ecosystem features."
    reason: "Stated in the existing recipes and three-modes guides; no test is cited yet."
    owner: unassigned
  - claim: "repro deps refresh writes only repro.scanned-deps.nim and never edits repro.nim."
    reason: "Stated in the existing three-modes guide; libs/repro_core/tests/t_deps_refresh_check.nim covers --check only."
    owner: unassigned
draft: true
---

# Conventions and the three modes

This page explains how reprobuild builds a project from very little description,
and why it offers three ways to describe a project rather than one.

## Conventions do the routine work

Most languages have a standard layout. A Cargo crate keeps its sources in
`src/`, with `main.rs` for a program and `lib.rs` for a library. A Go module
declares itself in `go.mod`. A convention is reprobuild's knowledge of such a
layout: where the sources are, which directories are libraries and which are
programs, what counts as a test, and which compiler invocations turn them into
outputs.

A project that follows its language's layout therefore does not have to list its
source files, compiler flags or link order. It has to say only what a convention
cannot infer: which packages exist, which tools they use, and how they depend on
each other. `repro show-conventions` shows what a convention inferred, which is
the first thing to read when a build does something you did not expect.

## Three modes, by how much the project already says

Projects differ in how much they already say about themselves. reprobuild reads
what is there instead of asking for a second copy of it.

**[Mode 1](../reference/glossary.md#mode-1): the layout is the description.** A
repository arranged as `apps/<name>/` and `libs/<name>/` (or an ecosystem's own
equivalent, such as Go's `cmd/<name>/`) needs no project file. reprobuild infers
the targets from the directories, their language from the file extensions, and
the dependencies between them from the imports in the sources.

Inference has one dangerous failure: guessing wrongly. If an import could refer
to two libraries, Mode 1 stops with an error that names both candidates, instead
of choosing one. The remedy is to move to Mode 3 and state the dependency.

**[Mode 2](../reference/glossary.md#mode-2): the ecosystem's manifest is the
description.** A project with a `Cargo.toml`, `package.json`, `CMakeLists.txt` or
another ecosystem manifest already states its dependencies and structure, in a
form its own tools and your editor read. reprobuild reads that manifest too. The
project file only names the package and the tools it uses.

Mode 2 is the choice for an existing project, for one that depends on its
ecosystem's package registry, and for one whose editor tooling expects the
manifest to stay.

**[Mode 3](../reference/glossary.md#mode-3): a short project file is the
description.** The project file declares the packages and the tools each uses,
and conventions supply the rest. The dependencies between packages are found in
the sources by `repro deps refresh` and written to `repro.scanned-deps.nim`, a
file that the project file includes and that you never edit by hand. A
dependency the scanner cannot see, such as code generation or a plugin loaded at
run time, you write into `repro.nim` yourself.

This split keeps a clear line between what a person wrote and what a tool wrote:
it is a line between two files, not between two regions of one file.

## Modes are per project, not per workspace

A workspace can hold a Mode 2 Rust crate next to a Mode 3 Nim program, and each
package can move from one mode to another when its needs change:

- **From Mode 1 to Mode 3**, when an inference is wrong or ambiguous: write a
  project file that states the dependency.
- **From Mode 3 to Mode 2**, when a package needs what only its ecosystem
  provides: packages from a registry such as crates.io, PyPI or npm, a build
  script such as `build.rs`, code-generation plugins, or ecosystem features
  such as Cargo features. Add the manifest; where a package has one, reprobuild
  reads it in Mode 2.
- **From Mode 2 to Mode 3**, when a package needs none of those and you want
  one description of it instead of two.
- **To a `build:` block** in the project file, for the one target that fits no
  convention, while the rest of the project stays on conventions.

## What conventions cannot do

A convention cannot know what your code does at run time, and it cannot read an
intention you did not write down. It sees what is on disk. When a build needs a
fact that only you know, the project file is where that fact goes, and the
compiler checks it there.

## Related

- [Build an existing project](../how-to/build/build-an-existing-project.md) (Mode 2)
- [Build a repository from its layout](../how-to/build/build-a-monorepo-from-its-layout.md) (Mode 1)
- [Build your first project](../tutorials/first-build.md) (Mode 3)
- [How reprobuild works](how-reprobuild-works.md)
