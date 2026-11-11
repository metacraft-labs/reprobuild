---
title: Build an existing project
description: Build a Cargo, Go or CMake project with reprobuild by adding a short project file next to its existing manifest.
kind: how-to
persona: build-maintainer
domain: build
order: 10
platforms: [linux, macos]
verifies:
  commands: [build, show-conventions]
unverified:
  - claim: "The project files shown build the matching reprobuild-examples fixtures."
    reason: "Copied from reprobuild-examples (rust/binary, go/binary, c-cpp-cmake/hello-binary); no scenario builds them from this page yet, and those fixtures still use the older file name reprobuild.nim."
    owner: unassigned
  - claim: "The version ranges in the uses: lines."
    reason: "Copied from the fixtures; they belong in an include generated from the fixture files."
    owner: unassigned
---

# Build an existing project

This page shows how to build a project that already has its ecosystem's
manifest, such as a `Cargo.toml`, a `go.mod` or a `CMakeLists.txt`, without
changing that manifest.

reprobuild reads the manifest for the project's structure and dependencies
([Mode 2](../../concepts/conventions-and-modes.md)). You add a project file that
names the package and the tools it uses.

## Before you start

- [Install reprobuild](../../install.md).
- The project follows its ecosystem's standard layout.
- The tools named in the project file below are on your `PATH`, or you choose another source for them with `--tool-provisioning`.

## Steps

### 1. Create the project file

In the directory that holds the manifest, create `repro.nim`. Name one package, the tools it uses, and the program or library it produces:

:::tabs
@tab Rust
```nim
import repro_project_dsl

package rust_binary_example:
  uses:
    "rustc >=1.80 <2.0"
    "cargo >=1.80 <2.0"

  executable rust_binary_example:
    discard
```

@tab Go
```nim
import repro_project_dsl

package goBinaryExample:
  uses:
    "go >=1.22 <2.0"

  executable go_binary_example:
    discard
```

@tab CMake
```nim
import repro_project_dsl

package c_cpp_cmake_hello_binary_example:
  uses:
    "gcc >=11"
    "cmake >=3.20"

  executable hello:
    discard
```
:::

The `uses:` lines are version ranges. Use the ranges your project supports.

### 2. Check what reprobuild inferred

Check what reprobuild inferred from the manifest:

```bash
repro show-conventions
```

### 3. Build

Build:

```bash
repro build --tool-provisioning=path
```

`--tool-provisioning=path` uses the tools on your `PATH`. To let reprobuild
provide them instead, choose another source, such as
`--tool-provisioning=nix`.

## Check that it worked

Run the build a second time. Nothing has changed, so reprobuild reuses every
result and runs no compiler.

<!-- generated:begin capture build-an-existing-project rebuild -->
<!-- generated:end -->

## If the build does not match your manifest

- Run `repro show-conventions` again and compare its targets with your manifest. The convention reads only the standard layout.
- For a target that fits no convention, add a `build:` block to that target in `repro.nim`. The rest of the project stays on the convention.

## Related

- [Conventions and the three modes](../../concepts/conventions-and-modes.md)
- [Build a repository from its layout](build-a-monorepo-from-its-layout.md)
- [How caching stays correct](../../concepts/how-caching-stays-correct.md)
