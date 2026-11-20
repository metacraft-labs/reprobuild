---
title: Keep an existing Nix flake as the environment
description: Activate a repository's existing flake development shell through reprobuild, without changing the flake and without direnv.
kind: how-to
persona: build-maintainer
domain: environments
order: 30
platforms: [linux]
verifies:
  commands: [allow, exec, flake override-args]
  tests:
    - tests/e2e/dev-env/t_e2e_nf4_flake_dev_shell.nim
    - tests/integration/t_nf4_foreign_env_contract.nim
    - tests/integration/t_own_flake_ref_survives_an_uninitialised_submodule.nim
    - tests/integration/t_flake_override_resolution_uses_the_invoking_engine.nim
    - tests/integration/t_a_sibling_override_excludes_gitignored_build_output.nim
    - tests/integration/t_emitted_overrides_match_the_develop_set.nim
unverified:
  - claim: "The repro.nim sample compiles."
    reason: "It ran on Linux with repro 0.2.24 built from reprobuild 84b459adda; no test compiles this page's samples (the snippet test reads reference/dsl.md only)."
    owner: unassigned
  - claim: "In a workspace, overrideInputs takes precedence over the automatic overrides, workspaceOverrides = false turns them off, and an override that cannot be resolved fails activation."
    reason: "t_nf4_foreign_env_contract.nim covers the precedence and the resolver failure; workspaceOverrides = false is read from the helper, not run."
    owner: unassigned
  - claim: "The default reference is .?submodules=1, which falls back to . when a declared submodule is not initialised."
    reason: "t_own_flake_ref_survives_an_uninitialised_submodule.nim covers the fallback; it was not run for this page."
    owner: unassigned
  - claim: "The captured output, that direnv is not needed, and that flakeRef = \".#ci\" selects that shell with its variables."
    reason: "Run by hand on Linux with repro 0.2.24 built from reprobuild 84b459adda, once with direnv absent from PATH; no scenario re-runs it."
    owner: unassigned
  - claim: "macOS behaves as Linux for every step."
    reason: "The steps were run on Linux only."
    owner: unassigned
---

# Keep an existing Nix flake as the environment

This page shows how to keep a repository's Nix flake development shell as its
development environment, activated by reprobuild, without changing the flake.

## Before you start

- [Install reprobuild](../../install.md), and Nix with the `nix-command` and `flakes` features enabled.
- The repository has a `flake.nix` with a development shell (`devShells`).

## Steps

### 1. Create the project file

Create `repro.nim` at the repository root:

```nim title="repro.nim"
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package projectEnvironment:
  devEnv:
    useFlakeDevShell()
```

If the repository already has a `repro.nim`, add the `devEnv:` block with
`useFlakeDevShell()` to its package instead, and the `foreign_env` import to
the top of the file.

### 2. Ignore the local activation files

Add `.repro/` to `.gitignore`. reprobuild keeps the activation's local files there.

### 3. Allow the directory

```bash
repro allow
```

reprobuild activates the environment of a directory only after you have
allowed it, because activating it runs the flake's code.

### 4. Use the environment

Run a command in it:

```bash
repro exec -- <command>
```

To have it activated whenever you enter the repository, as direnv's
`use flake` did, [load the shell hook](activate-on-directory-change.md).
direnv is not needed for either, and `.envrc` can stay for the people who
still use it.

## Use another flake or another shell

Pass `flakeRef` to `useFlakeDevShell`:

```nim fragment
useFlakeDevShell(flakeRef = "./nix")    # a flake in a subdirectory
useFlakeDevShell(flakeRef = ".#ci")     # another development shell of this flake
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

Inside a [workspace](../../reference/glossary.md#workspace), a local flake's
inputs that refer to repositories in the workspace's
[develop mode](../../reference/glossary.md#develop-mode) are pointed at their
checkouts, with the arguments `repro flake override-args` prints. An entry in
`overrideInputs` takes precedence, and `workspaceOverrides = false` turns the
automatic overrides off. If an override cannot be resolved, activation fails
instead of using different sources without telling you.
[Build a flake against a local checkout of an input](../workspaces/develop-a-flake-input.md)
shows how to choose which inputs are overridden.

## Check that it worked

Ask the environment where a tool that the flake's development shell provides is, and
compare with `nix develop`:

```bash
repro exec -- which <tool>
nix develop --command which <tool>
```

Both print the same Nix store path. For the development shell of
`reprobuild-examples/nix/flake-dev-shell`, run with repro {{ fixtures.flake_migration.repro }}:

<!-- generated:begin capture keep-a-nix-flake-environment same-store-path -->
```text
/nix/store/f6m39cykz58fjhr8dx17zsfrlxslqv2r-x86_64-unknown-linux-gnu-nim-wrapper-2.2.4/bin/nim
/nix/store/f6m39cykz58fjhr8dx17zsfrlxslqv2r-x86_64-unknown-linux-gnu-nim-wrapper-2.2.4/bin/nim
```
<!-- generated:end -->

## Related

- [Move a project from a Nix flake to reprobuild](../../tutorials/move-a-project-from-a-nix-flake.md): the next steps after this one, to removing the flake
- [Activate environments when you change directory](activate-on-directory-change.md)
- [Choose where a project's tools come from](../building/choose-where-tools-come-from.md)
- [Coming from Nix](../../coming-from/nix.md)
