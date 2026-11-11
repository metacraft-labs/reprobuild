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
