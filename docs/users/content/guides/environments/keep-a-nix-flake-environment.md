---
title: Keep an existing Nix flake as the environment
description: Activate a repository's existing flake dev shell through reprobuild, without changing the flake and without direnv.
kind: how-to
persona: build-maintainer
domain: environments
order: 30
platforms: [linux, macos]
verifies:
  commands: [allow, shell hook, flake override-args]
  tests:
    - tests/integration/t_own_flake_ref_survives_an_uninitialised_submodule.nim
    - tests/integration/t_flake_override_resolution_uses_the_invoking_engine.nim
    - tests/integration/t_a_sibling_override_excludes_gitignored_build_output.nim
unverified:
  - claim: "Direnv is not needed for activation."
    reason: "From the existing getting-started guide; no test activates the flake with direnv absent."
    owner: unassigned
  - claim: "Inside a workspace, local flakes get input overrides for sibling checkouts from repro flake override-args; overrideInputs wins and workspaceOverrides = false turns this off; a resolver failure fails activation."
    reason: "From the existing getting-started guide; the cited tests cover override resolution but not each statement."
    owner: unassigned
  - claim: "The default reference is .?submodules=1, which falls back to . when a declared submodule is not initialised."
    reason: "Covered by t_own_flake_ref_survives_an_uninitialised_submodule.nim for the fallback; the default itself is read from the guide."
    owner: unassigned
---

# Keep an existing Nix flake as the environment

This page shows how to keep a repository's Nix flake dev shell as its
development environment, activated by reprobuild, without changing the flake.

## Before you start

- [Install reprobuild](../../install.md) and Nix.
- The repository has a `flake.nix` with a dev shell.
- [Load the shell hook](activate-on-directory-change.md) in your shell.

## Steps

### 1. Create the project file

Create `repro.nim` at the repository root:

```nim
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package projectEnvironment:
  devEnv:
    useFlakeDevShell()
```

If the repository already has a `repro.nim`, add the `devEnv:` block with
`useFlakeDevShell()` to its package instead.

### 2. Ignore the local activation files

Add `.repro/` to `.gitignore`. reprobuild keeps the activation's local files there.

### 3. Allow the directory

Allow the directory:

```bash
repro allow
```

### 4. Enter the directory again

Leave the directory and enter it again. The hook activates the flake's dev shell. You do not need direnv.

## Use another flake or another shell

Pass `flakeRef` to `useFlakeDevShell`:

```nim
useFlakeDevShell(flakeRef = "./nix")    # a flake in a subdirectory
useFlakeDevShell(flakeRef = ".#ci")     # another dev shell of this flake
```

:::note
The default reference includes the repository's initialised git submodules
(`.?submodules=1`). If the repository declares a submodule that is not
initialised, for example in a clone made without `--recurse-submodules`,
reprobuild uses the plain `.` reference instead: activation succeeds, and the
flake does not see that submodule's contents. Run `git submodule update --init`
when the shell needs them.
:::

## In a workspace: build against your sibling checkouts

Inside a workspace, a local flake's inputs that refer to repositories you have
checked out side by side are pointed at those checkouts automatically, using
`repro flake override-args`. An entry in `overrideInputs` takes precedence, and
`workspaceOverrides = false` turns the automatic overrides off. If an override
cannot be resolved, activation fails instead of using different sources without
telling you.

## Check that it worked

In the repository, run a tool that only the flake's dev shell provides, with
`--version`.

## Related

- [Activate environments when you change directory](activate-on-directory-change.md)
- [Coming from Nix](../../coming-from/nix.md)
