---
title: Build a flake against a local checkout of an input
description: Point a flake's inputs at the repositories you have checked out in a workspace, choose which ones, check what is substituted, and keep flake.lock in step with what you built.
kind: how-to
persona: developer
domain: workspaces
order: 30
platforms: [linux]
verifies:
  commands: [flake override-status, flake override-args, flake refresh-lock, develop]
  tests:
    - tests/integration/t_emitted_overrides_match_the_develop_set.nim
    - tests/integration/t_a_repo_not_in_develop_mode_is_not_substituted.nim
    - tests/integration/t_flake_inputs_match_original_coordinates.nim
    - tests/integration/t_behind_pin_warns_and_does_not_fail.nim
    - tests/integration/t_a_refreshed_flake_pin_carries_what_nix_would_write.nim
    - tests/integration/t_cs_m6_develop_and_flake_command_lines.nim
    - tests/e2e/dev-env/t_e2e_nf4_flake_dev_shell.nim
unverified:
  - claim: "repro flake refresh-lock records in flake.lock the revision each substituted checkout is at, and the managed pre-commit hook runs it."
    reason: "Covered by t_a_refreshed_flake_pin_carries_what_nix_would_write.nim; not run for this page, because it writes the flake.lock of a real repository."
    owner: unassigned
  - claim: "An input is matched to a workspace repository by the repository coordinates its flake.lock records, not by its name."
    reason: "Covered by t_flake_inputs_match_original_coordinates.nim; the run for this page showed the reports that name it, not a mismatch."
    owner: unassigned
  - claim: "After repro develop --only=<repository>, every flake in the workspace that has the repository as an input uses its checkout."
    reason: "Covered by t_emitted_overrides_match_the_develop_set.nim; repro develop was not run for this page, because it changes the develop set of a real workspace. The captures use --only on the repro flake command instead."
    owner: unassigned
  - claim: "The captured output on this page."
    reason: "Run by hand on Linux with repro 0.2.24 built from reprobuild 84b459adda, in a workspace whose path is shown as /home/you/workspace; no scenario re-runs it."
    owner: unassigned
  - claim: "macOS behaves as Linux for every step."
    reason: "The steps were run on Linux only."
    owner: unassigned
---

# Build a flake against a local checkout of an input

This page shows how to make a flake's development shell, or any `nix`
command on the flake, use your checkout of one of its inputs. It replaces the
revision `flake.lock` pins, as `--override-input <name> path:../<input>` does
by hand.

## Before you start

- The flake's repository and the input's repository are both in a [workspace](../../reference/glossary.md#workspace), checked out side by side ([Join a workspace](join-a-workspace.md)).
- The flake's `flake.lock` pins the input.

reprobuild matches an input to a workspace repository by the repository that
the input's entry in `flake.lock` records, so an input named `foo-src` can
match a repository named `foo`.

## Steps

### 1. See what is substituted now

In the flake's repository, run:

```bash
repro flake override-status
```

It prints one line for each input that keeps its pin, with the reason, and a
summary of the inputs it substitutes. For example, for an input whose
repository is checked out but not in develop mode:

<!-- generated:begin capture develop-a-flake-input not-in-develop-set -->
```text
repro flake override-status: NOT substituted: flake input 'nim-shm-gset-src' names repo 'nim-shm-gset', which IS checked out at /home/you/workspace/nim-shm-gset but is NOT in the develop set, so it keeps its flake.lock pin and the shell builds the PINNED revision rather than that working tree. A repo enters the develop set only when a lock backend holds a record pinning it to an exact revision. Remedy: give it one — `repro lock refresh` run IN /home/you/workspace/nim-shm-gset publishes that repo's own committed lock, which is the record this reads — or, if the omission is deliberate, it came from this invocation's selection (--only / --except / --tier).
```
<!-- generated:end -->

### 2. Choose the inputs to substitute

Put the input's repository in [develop mode](../../reference/glossary.md#develop-mode):

```bash
repro develop --only=<repository>
```

From then on its checkout replaces the pinned revision, for every flake in
the workspace that has it as an input. [Work on a dependency's
source](develop-a-dependency.md) covers develop mode in full.

To substitute an input for one command only, pass the same selection to the
`repro flake` command instead, as step 3 does.

### 3. Use the checkout

If the repository activates its flake through reprobuild
(`useFlakeDevShell()`, see [Keep an existing Nix flake as the
environment](../environments/keep-a-nix-flake-environment.md)), there is
nothing more to do: activation applies the overrides.

For `nix` commands, `repro flake override-args` prints the arguments:

```bash
repro flake override-args --only=<repository>
```

<!-- generated:begin capture develop-a-flake-input override-args -->
```text
--override-input io-mon-src git+file:///home/you/workspace/io-mon
```
<!-- generated:end -->

Pass them to the `nix` command:

```bash
nix develop $(repro flake override-args)
```

### 4. Keep `flake.lock` in step before you commit

When you commit a change that depends on your checkout of the input, record
the checkout's revision in `flake.lock`:

```bash
repro flake refresh-lock
```

It writes only the inputs that are substituted, and only when the revision
has moved. The workspace's pre-commit hook runs it for you once the hooks are
installed with `repro hooks ensure --vcs`.

### 5. Return to the pinned revision

When you have finished, end develop mode:

```bash
repro develop --drop=<repository>
```

## Check that it worked

Run `repro flake override-status` again, with the same `--only` if step 3
used one. Its last line counts the
substituted inputs, and says for each whether the checkout is at, ahead of or
behind the revision `flake.lock` pins:

<!-- generated:begin capture develop-a-flake-input status-summary -->
```text
repro flake override-status: 1 substituted input(s) of /home/you/workspace/reprobuild/flake.lock: 0 at pin, 1 ahead, 0 behind, 0 diverged, 0 unfetched, 0 unknown, 0 unpinned
```
<!-- generated:end -->

A checkout that is behind its pin builds an older revision than `flake.lock`
names. reprobuild warns about it on every activation and does not fail.

## Related

- [Work on a dependency's source](develop-a-dependency.md)
- [Keep an existing Nix flake as the environment](../environments/keep-a-nix-flake-environment.md)
- [Coming from Nix](../../coming-from/nix.md)
