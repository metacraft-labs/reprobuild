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
unverified:
  - claim: "reprobuild obtains tools from Nix with --tool-provisioning=nix and keeps a flake's dev shell with useFlakeDevShell()."
    reason: "Both are documented features; only the dev-shell half has a cited test."
    owner: unassigned
  - claim: "Conventions produce one action per compiler invocation, so a one-file change re-runs the actions that read that file."
    reason: "True of the conventions this page's links describe; not every convention splits its work this way, and no test is cited per convention."
    owner: unassigned
draft: true
---

# Coming from Nix

This page maps what you know from Nix onto reprobuild, explains where the two
differ, and says when Nix remains the better tool.

## What carries over

- **Everything is pinned.** A flake pins its inputs in `flake.lock`; a reprobuild
  repository pins what it was built with in `repro.lock`.
- **Outputs live in a content-addressed store**, and garbage collection removes
  what nothing refers to.
- **A project carries its own development environment.** `nix develop` and
  `repro shell` both put a project's tools on your `PATH`.
- **Machine state has generations.** Home Manager and NixOS switch between
  generations and roll back; so do reprobuild's home and system profiles.

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

## What works differently

**The project file is a compiled, typed program.** `repro.nim` is Nim. A
misspelt option or a value of the wrong type is a compile error, reported with a
line number, before anything builds, and your editor navigates it like any
other code.

**Inputs are recorded, not only declared.** A Nix derivation reads only what it
declares: the sandbox hides everything else. A reprobuild action runs under a
monitor that records what it read, including files no one declared, and makes
them part of its fingerprint. Both approaches aim at the same guarantee, a
result that depends only on known inputs; [How caching stays correct](../concepts/how-caching-stays-correct.md)
explains reprobuild's.

**The unit of caching is smaller.** A derivation usually builds a whole package,
so a one-line change rebuilds the package. The conventions split a build into one
action per compiler invocation, so the same change re-runs the actions that read
the changed file.

**You can keep Nix.** reprobuild can take its tools from Nix
(`--tool-provisioning=nix`), and it can use a flake's dev shell as a project's
environment without any change to the flake:
[Keep an existing Nix flake as the environment](../how-to/environments/keep-a-nix-flake-environment.md).
Adopting reprobuild does not require leaving Nix.

## What reprobuild does not do

- It does not evaluate Nix expressions or read nixpkgs as its own package set.
  It reaches Nix packages through tool provisioning and flake dev shells.
- It has no counterpart to `nix repl`, `nix eval`, `nix flake show`, `nix log` or
  `nix path-info`.
- It has no package search command.

## When Nix remains the better choice

- You configure whole systems from nixpkgs and its NixOS modules, and depend on
  their breadth.
- Your builds must be prevented from reading undeclared files, by isolation,
  rather than have those reads recorded.
- Your Nix expressions already give you correct, cached builds at package
  granularity, and per-file reuse would not change your feedback loop.

## Next steps

- [Keep an existing Nix flake as the environment](../how-to/environments/keep-a-nix-flake-environment.md)
- [Build an existing project](../how-to/build/build-an-existing-project.md)
- [Command equivalents](../reference/command-equivalents.md#nix)
