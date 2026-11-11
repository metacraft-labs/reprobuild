---
title: Enter a project's environment
description: Start a shell with a project's tools and variables, run one command inside its environment, choose an activity, or print the environment for another tool.
kind: how-to
persona: developer
domain: environments
order: 10
platforms: [linux, macos, windows]
verifies:
  commands: [shell, exec, tasks, run, dev-env export]
  tests:
    - tests/e2e/local-build-engine/t_e2e_repro_run_lists_tasks_and_edges.nim
unverified:
  - claim: "repro shell and repro exec do not need repro allow; only automatic activation checks trust."
    reason: "Read from the code: the trust check is on the dev-env export path only. No test asserts that shell and exec skip it."
    owner: unassigned
  - claim: "The --print-env formats posix, fish, powershell and json."
    reason: "Read from the usage text; belongs in the generated CLI reference."
    owner: unassigned
draft: true
---

# Enter a project's environment

This page shows how to use the tools and variables a project declares for
working on it: in a shell, for one command, or exported to another tool.

## Before you start

- [Install reprobuild](../../install.md).
- The project's `repro.nim` declares a development environment, in a `devEnv:`
  block.

## Start a shell in the environment

From anywhere inside the project, run:

```bash
repro shell
```

You are in a new shell with the project's tools on `PATH` and its variables set.
Leave it with `exit`.

## Run one command in the environment

Put the command after `--`:

```bash
repro exec -- cargo --version
```

`repro exec` runs the command and returns its exit status, without starting an
interactive shell. Use it in scripts and in CI.

## Run one of the project's tasks

List the tasks the project declares, then run one by name:

```bash
repro tasks
repro run test
```

Arguments after `--` go to the task's command:

```bash
repro run test -- --verbose
```

## Choose an activity

A project can declare several activities, each switching on a different set of
tools and services. Name the one you want:

```bash
repro shell --activity=docs
```

Without `--activity`, reprobuild uses the activity named `default`.

## Print the environment instead of entering it

To hand the environment to an editor, a CI step or another shell, print it:

```bash
repro shell --print-env=posix
```

`--print-env` also takes `fish`, `powershell` and `json`.

## Related

- [Activate environments when you change directory](activate-on-directory-change.md)
- [Keep an existing Nix flake as the environment](keep-a-nix-flake-environment.md)
- [Development environment](../../reference/glossary.md#development-environment) in the glossary
