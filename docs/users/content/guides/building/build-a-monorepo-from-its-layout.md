---
title: Build a repository from its layout
description: Build a repository arranged as apps/<name>/ and libs/<name>/ with no project file, and check what reprobuild inferred from it.
kind: how-to
persona: build-maintainer
domain: build
order: 20
platforms: [linux, macos]
verifies:
  commands: [build, show-conventions]
unverified:
  - claim: "Mode 1 recognises apps/<name>/, libs/<name>/ and tools/<name>/, and ecosystem equivalents such as cmd/<name>/."
    reason: "From the existing three-modes guide; the list belongs in the generated language reference."
    owner: unassigned
  - claim: "Mode 1 stops with an error that names both candidates when an import is ambiguous, and refuses a layout that mixes languages."
    reason: "From the existing three-modes guide; no test is cited yet."
    owner: unassigned
  - claim: "Mode 1 writes nothing in the repository outside .repro/."
    reason: "From the existing three-modes guide; no test is cited yet."
    owner: unassigned
---

# Build a repository from its layout

This page shows how to build a repository whose directory layout already says
what it contains, without writing a project file
([Mode 1](../../concepts/conventions-and-modes.md)).

## Before you start

- [Install reprobuild](../../install.md).
- The repository keeps each program in `apps/<name>/` and each library in `libs/<name>/`, in one language, following that language's own layout inside each directory.
- The repository has no `repro.nim` at its root. If it has one, reprobuild uses that instead.

A repository of that shape looks like this:

```text
my-repository/
├── apps/
│   └── calc/
│       └── src/main.rs      # use mathlib::add;
└── libs/
    └── mathlib/
        └── src/lib.rs
```

## Steps

### 1. Check what reprobuild infers

From the repository root, check what reprobuild infers:

```bash
repro show-conventions
```

It lists each target, its language and source directory, and each dependency
it found, with the import line that shows it.

### 2. Build

Build:

```bash
repro build --tool-provisioning=path
```

reprobuild keeps what it inferred under `.repro/`. It does not write a project
file into your repository.

## Check that it worked

`repro show-conventions` lists every directory under `apps/` and `libs/` as a
target, and every dependency you expect between them.

## If reprobuild stops

- An import matches two candidates. Mode 1 refuses to choose and names both. Write a project file that states the dependency, which moves the repository to [Mode 3](../../concepts/conventions-and-modes.md).
- The repository mixes languages. Mode 1 handles one language per repository. Write a project file instead.

## Related

- [Conventions and the three modes](../../concepts/conventions-and-modes.md)
- [Build an existing project](build-an-existing-project.md)
- [Build your first project](../../tutorials/first-build.md)
