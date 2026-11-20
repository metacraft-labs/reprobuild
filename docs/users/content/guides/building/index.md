---
title: Building
description: Guides for building a project with reprobuild, from its layout, its ecosystem manifest or its project file.
kind: explanation
persona: build-maintainer
domain: build
order: 0
---

# Building

These guides cover building projects. The ideas behind them are in
[Conventions and the three modes](../../concepts/conventions-and-modes.md) and
[How caching stays correct](../../concepts/how-caching-stays-correct.md).

| Guide | When |
|---|---|
| [Build an existing project](build-an-existing-project.md) | The project has a `Cargo.toml`, a `go.mod`, a `CMakeLists.txt` or another ecosystem manifest |
| [Build a repository from its layout](build-a-monorepo-from-its-layout.md) | The repository keeps programs in `apps/` and libraries in `libs/` |
| [Choose where a project's tools come from](choose-where-tools-come-from.md) | You want the tools in `uses:` from Nix, from your `PATH` or from another source |
| [Find out why two builds of a library are not shared](find-why-two-library-builds-differ.md) | Two applications configure one library differently, or a build you expected to be reused was not |
