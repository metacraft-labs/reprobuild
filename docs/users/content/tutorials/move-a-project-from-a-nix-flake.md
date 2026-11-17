---
title: Move a project from a Nix flake to reprobuild
description: Take a project whose tools come from a flake development shell, hand its environment and its build to reprobuild one step at a time, and remove the flake at the end.
kind: tutorial
persona: build-maintainer
order: 20
platforms: [linux]
verifies:
  scenario: scenarios/move-a-project-from-a-nix-flake.toml
  commands: [allow, exec, build]
  tests:
    - tests/e2e/dev-env/t_e2e_nf4_flake_dev_shell.nim
    - tests/integration/t_nf4_foreign_env_contract.nim
    - tests/integration/t_nix_tool_resolution_is_a_provisioning_edge.nim
unverified:
  - claim: "Every step and every result on this page."
    reason: "No scenario runner exists yet. The steps were run by hand on Linux with the build the scenario's [capture] table names, and the capture regions hold that run's output; nothing re-runs them when the page or reprobuild changes."
    owner: unassigned
  - claim: "The three repro.nim samples compile."
    reason: "They ran in the hand-run scenario with repro 0.2.24 built from reprobuild 84b459adda; no test compiles this page's samples (the snippet test reads reference/dsl.md only)."
    owner: unassigned
  - claim: "The steps work on macOS."
    reason: "Not run on macOS; the page declares linux only."
    owner: unassigned
---

# Move a project from a Nix flake to reprobuild

In this tutorial you take a small project whose tools come from a Nix flake's
development shell and move it to reprobuild one step at a time. The flake keeps
working until the last step, and you check the result after each one.

## What you need

- `repro` on your `PATH` ([Install reprobuild](../install.md)). The captures
  on this page come from repro {{ fixtures.flake_migration.repro }}.
- git.
- Nix, with the `nix-command` and `flakes` features enabled.

## How long

{{ fixtures.flake_migration.seconds }} seconds when the scenario last ran, on
a machine whose Nix store already held the packages the example uses. On a
new machine, add the time Nix takes to download them.

## 1. Get the example

Clone the examples repository at the revision this tutorial was checked
against, and enter the example:

```bash
git clone https://github.com/metacraft-labs/reprobuild-examples
git -C reprobuild-examples checkout {{ fixtures.flake_migration.rev }}
cd reprobuild-examples/nix/flake-dev-shell
ls -A
```

<!-- generated:begin capture move-a-project-from-a-nix-flake list -->
```text
.envrc
flake.lock
flake.nix
.gitignore
README.md
src
```
<!-- generated:end -->

The directory holds a program, `src/hello.nim`, and the files of a project
that uses Nix for its tools: `flake.nix`, whose development shell provides
the Nim compiler, `flake.lock`, which pins nixpkgs, and `.envrc`, which tells
direnv to activate the shell.

## 2. Look at the starting point

Ask the flake's development shell where its Nim compiler is:

```bash
nix develop --command which nim
```

<!-- generated:begin capture move-a-project-from-a-nix-flake flake-shell -->
```text
/nix/store/f6m39cykz58fjhr8dx17zsfrlxslqv2r-x86_64-unknown-linux-gnu-nim-wrapper-2.2.4/bin/nim
```
<!-- generated:end -->

This is the compiler everyone working on the project uses today.

## 3. Let reprobuild activate the flake

Create `repro.nim` next to `flake.nix`:

```nim title="repro.nim"
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package hello:
  devEnv:
    useFlakeDevShell()
```

The project file declares one package, `hello`, whose
[development environment](../reference/glossary.md#development-environment)
is the flake's development shell. Nothing about the flake changes.

Allow the directory, then run the same command inside the environment
reprobuild prepares:

```bash
repro allow
repro exec -- which nim
```

<!-- generated:begin capture move-a-project-from-a-nix-flake activate-the-flake -->
```text
Allowed repro dev-env for: ~/reprobuild-examples/nix/flake-dev-shell
/nix/store/f6m39cykz58fjhr8dx17zsfrlxslqv2r-x86_64-unknown-linux-gnu-nim-wrapper-2.2.4/bin/nim
```
<!-- generated:end -->

The path is the one from step 2: reprobuild ran the flake's development shell
and used its environment. The flake is unchanged, so `nix develop` and direnv
keep working for anyone who still uses them.

## 4. Let reprobuild build the program

Replace `repro.nim` with:

```nim title="repro.nim"
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package hello:
  uses:
    "nim >=2.2 <3.0"

  defaultToolProvisioning "nix"

  devEnv:
    useFlakeDevShell()

  build:
    discard nim.c(source = "src/hello.nim", binary = "build/hello")
```

Three things are new:

- `uses:` names the tool the package needs, Nim, with the range of versions it works with.
- `defaultToolProvisioning "nix"` tells reprobuild to obtain that tool from Nix.
- `build:` declares one action: compile `src/hello.nim` into `build/hello`.

Build the program and run it:

```bash
repro build
./build/hello
```

<!-- generated:begin capture move-a-project-from-a-nix-flake build -->
```text
hello from a project that used to need a flake
```
<!-- generated:end -->

`repro build` prints nothing when it succeeds and its progress display is
off, which is how this capture was made. In a terminal you see the action run.

The Nim that compiled the program did not come from the flake. reprobuild
looked `nim` up in its package catalog, which names a Nix package for it, and
built or downloaded that package into the Nix store.

## 5. Take the environment from the project file

Replace `useFlakeDevShell()` with `discard`, and remove the import it needed.
`repro.nim` is now:

```nim title="repro.nim"
import repro_project_dsl

package hello:
  uses:
    "nim >=2.2 <3.0"

  defaultToolProvisioning "nix"

  devEnv:
    discard

  build:
    discard nim.c(source = "src/hello.nim", binary = "build/hello")
```

The `devEnv:` block is still there, but empty: the environment is now the
tools in `uses:`. Ask it for its Nim again:

```bash
repro exec -- which nim
```

<!-- generated:begin capture move-a-project-from-a-nix-flake environment-from-the-project-file -->
```text
/nix/store/f6m39cykz58fjhr8dx17zsfrlxslqv2r-x86_64-unknown-linux-gnu-nim-wrapper-2.2.4/bin/nim
```
<!-- generated:end -->

It is the same store path as before, because the catalog and this example's
`flake.lock` pin the same nixpkgs revision. In another project the two pins
can differ, and then so do the paths.

## 6. Remove the flake

Nothing reads the flake any more. Delete it, and direnv's `.envrc` with it:

```bash
rm flake.nix flake.lock .envrc
```

Delete the program you built, build it again, and ask the environment for its
Nim once more:

```bash
rm -r build
repro build
./build/hello
repro exec -- which nim
```

<!-- generated:begin capture move-a-project-from-a-nix-flake remove-the-flake -->
```text
hello from a project that used to need a flake
/nix/store/f6m39cykz58fjhr8dx17zsfrlxslqv2r-x86_64-unknown-linux-gnu-nim-wrapper-2.2.4/bin/nim
```
<!-- generated:end -->

The project builds and its environment works with no flake. Apart from its
opening comment, your `repro.nim` is now the one in the finished project,
`reprobuild-examples/nix/flake-dev-shell-migrated`.

## What you learned

- A project's [development environment](../reference/glossary.md#development-environment) can be its flake's development shell, unchanged, while reprobuild activates it: [How reprobuild works](../concepts/how-reprobuild-works.md).
- Tools can still come from Nix after the flake is gone, because the catalog names a Nix package for each: [Dependencies and the store](../concepts/dependencies-and-the-store.md).
- Every intermediate step is a working state, so a project can stop at any of them: [Coming from Nix](../coming-from/nix.md).

## Next

- [Keep an existing Nix flake as the environment](../guides/environments/keep-a-nix-flake-environment.md) and [Choose where a project's tools come from](../guides/building/choose-where-tools-come-from.md): the options behind steps 3 to 5.
- [Activate environments when you change directory](../guides/environments/activate-on-directory-change.md): replace direnv's `use flake` with reprobuild's shell hook.
- [Build a flake against a local checkout of an input](../guides/workspaces/develop-a-flake-input.md): for a project that keeps its flake.
- [Dependencies and the store](../concepts/dependencies-and-the-store.md): how a range in `uses:` becomes one version.
