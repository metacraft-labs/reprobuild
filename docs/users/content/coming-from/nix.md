---
title: Coming from Nix
description: How flakes, derivations, dev shells, the store and generations map onto reprobuild, what works differently, and when Nix is the better choice.
kind: explanation
persona: build-maintainer
order: 10
verifies:
  commands: [build, shell, exec, allow, store gc, home, system, cache]
  tests:
    - tests/integration/t_own_flake_ref_survives_an_uninitialised_submodule.nim
    - tests/e2e/gm4b/t_e2e_home_apply_realizes_nix_selection.nim
    - tests/e2e/dev-env/t_e2e_nf4_flake_dev_shell.nim
    - tests/integration/t_nix_tool_resolution_is_a_provisioning_edge.nim
    - tests/integration/t_emitted_overrides_match_the_develop_set.nim
unverified:
  - claim: "reprobuild's binary cache is not a Nix substituter."
    reason: "Read from the source of reprobuild 84b459adda (repro 0.2.24), which serves no narinfo or nix-cache-info; no test asserts it."
    owner: unassigned
  - claim: "Conventions produce one action per compiler invocation, so a one-file change re-runs the actions that read that file."
    reason: "True of the conventions this page's links describe; not every convention splits its work this way, and no test is cited per convention."
    owner: unassigned
---

# Coming from Nix

This page maps what you know from Nix onto reprobuild, explains where the two
differ, and says when Nix remains the better tool.

## What carries over

- Everything is pinned. A flake pins its inputs in `flake.lock`; a reprobuild repository pins what it was built with in `repro.lock`.
- Outputs live in a content-addressed store, and garbage collection removes what nothing refers to.
- A project carries its own development environment. `nix develop` and `repro shell` both put a project's tools on your `PATH`.
- Machine state has generations. Home Manager and NixOS switch between generations and roll back; so do reprobuild's home and system profiles.

## Concept map

| Nix | reprobuild |
|---|---|
| `flake.nix` | [project file](../reference/glossary.md#project-file), `repro.nim` |
| `flake.lock` | [lock file](../reference/glossary.md#lock-file), `repro.lock` |
| derivation | [action](../reference/glossary.md#action) |
| `/nix/store` | [store](../reference/glossary.md#store) |
| `devShells` and `nix develop` | [development environment](../reference/glossary.md#development-environment) and `repro shell` |
| `use flake` with direnv | [shell hook](../reference/glossary.md#shell-hook) and `repro allow` |
| Home Manager configuration | [home profile](../reference/glossary.md#home-profile) |
| NixOS configuration | [system profile](../reference/glossary.md#system-profile) |
| generations | [generations](../reference/glossary.md#generation) |
| substituters | binary caches (`repro cache`) |

## Before and after

A `flake.nix` that builds a Rust binary and defines a development shell:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux; in {
      packages.x86_64-linux.default = pkgs.rustPlatform.buildRustPackage {
        pname = "cli-tool";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;
      };
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.rustc pkgs.cargo ];
      };
    };
}
```

becomes a `repro.nim` next to the existing `Cargo.toml`:

```nim
import repro_project_dsl

package cli_tool:
  uses:
    "rustc >=1.80 <2.0"
    "cargo >=1.80 <2.0"

  executable cli_tool:
    discard
```

`repro build` compiles it across Linux, macOS and Windows, and `repro shell`
opens the development environment with the same resolved toolchain.

## What works differently

Windows is a first-class target alongside Linux and macOS. Nix targets Linux
and macOS; reprobuild runs natively on Windows as well, resolving tools from
Scoop, release archives or source and reconciling Windows registry values,
services and optional features in `system.nim`.

The project file is a compiled, typed program. `repro.nim` is Nim. A
misspelt option or a value of the wrong type is a compile error, reported with a
line number, before anything builds, and your editor navigates it like any
other code.

Inputs are recorded, not only declared. A Nix derivation reads only what it
declares: the sandbox hides everything else. A reprobuild action runs under a
monitor that records what it read, including files no one declared, and makes
them part of its fingerprint. Both approaches aim at the same guarantee, a
result that depends only on known inputs; [How caching stays correct](../concepts/how-caching-stays-correct.md)
explains reprobuild's.

The unit of caching is smaller. A derivation usually builds a whole package,
so a one-line change rebuilds the package. The conventions split a build into one
action per compiler invocation, so the same change re-runs the actions that read
the changed file.

You can keep Nix. reprobuild can take its tools from Nix
(`--tool-provisioning=nix`, or `defaultToolProvisioning "nix"` in the project
file), and it can use a flake's development shell as a project's environment without
any change to the flake:
[Keep an existing Nix flake as the environment](../guides/environments/keep-a-nix-flake-environment.md).
Adopting reprobuild does not require leaving Nix.

## Moving over side by side

A project does not switch from Nix to reprobuild in one step. Each step below
leaves a working project, and you can stop after any of them. The flake keeps
working for the people who still use it until you remove it.
[Move a project from a Nix flake to reprobuild](../tutorials/move-a-project-from-a-nix-flake.md)
takes one project through all of them.

### The environment

`repro.nim` activates the flake's existing development shell with `useFlakeDevShell()`, unchanged: [Keep an existing Nix flake as the environment](../guides/environments/keep-a-nix-flake-environment.md).

### direnv

reprobuild's shell hook activates the environment when you enter the directory, as `use flake` did: [Activate environments when you change directory](../guides/environments/activate-on-directory-change.md). `.envrc` can stay for the people who still use direnv.

### Inputs you work on

A flake input whose repository you have checked out in a workspace builds from your checkout: [Build a flake against a local checkout of an input](../guides/workspaces/develop-a-flake-input.md).

### Tasks

Scripts that a development shell's `shellHook` defines, and `nix run` apps that wrap a project command, become named tasks in `repro.nim`: [Coming from just and Make](just-and-make-tasks.md).

### Tools

`uses:` names each tool with a version range, and `defaultToolProvisioning "nix"` takes it from Nix through reprobuild's catalog, so the flake no longer has to list it: [Choose where a project's tools come from](../guides/building/choose-where-tools-come-from.md).

### Caches

Nix keeps substituting store paths from the caches it is configured with. reprobuild shares build results through its own [binary cache](../reference/glossary.md#binary-cache), which is not a Nix substituter: [Binary caches and Nix substituters](../concepts/dependencies-and-the-store.md#binary-caches-and-nix-substituters).

## What reprobuild does not do

- It does not evaluate Nix expressions or read nixpkgs as its own package set. It reaches Nix packages through tool provisioning and flake dev shells.
- It has no counterpart to `nix repl`, `nix eval`, `nix flake show`, `nix log` or `nix path-info`.
- It has no package search command.

## When Nix remains the better choice

- You configure whole systems from nixpkgs and its NixOS modules, and depend on their breadth.
- Your builds must be prevented from reading undeclared files, by isolation, rather than have those reads recorded.
- Your Nix expressions already give you correct, cached builds at package granularity, and per-file reuse would not change your feedback loop.

## Next steps

- [Move a project from a Nix flake to reprobuild](../tutorials/move-a-project-from-a-nix-flake.md)
- [Keep an existing Nix flake as the environment](../guides/environments/keep-a-nix-flake-environment.md)
- [Choose where a project's tools come from](../guides/building/choose-where-tools-come-from.md)
- [Build a flake against a local checkout of an input](../guides/workspaces/develop-a-flake-input.md)
- [Build an existing project](../guides/building/build-an-existing-project.md)
- [Command equivalents](../reference/command-equivalents.md#nix)
