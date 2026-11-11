---
title: Reprobuild documentation
description: What reprobuild does, three ways to start with it, and where each kind of help lives.
kind: explanation
persona: evaluator
order: 0
verifies:
  commands: [build, shell, exec, workspace init]
  tests:
    - tests/integration/t_monitored_zero_output_edge_input_completeness.nim
    - tests/integration/t_workspace_init_clones_missing_and_reports_existing.nim
    - tests/e2e/local-build-engine/t_e2e_repro_run_lists_tasks_and_edges.nim
unverified:
  - claim: "One project file drives the build, the development environment, tasks and services."
    reason: "No single test exercises all four from one repro.nim; the claim rests on four separate features."
    owner: unassigned
---

# Reprobuild documentation

Reprobuild (`repro`) builds your software, provides the environment you develop
it in, runs its tasks and local services, and keeps a workspace of many
repositories in step, from one description of each project.

## What it does, and how

| What you get | How reprobuild does it | See it for yourself |
|---|---|---|
| An unchanged action is skipped, and a changed input re-runs it, even an input you never declared | Each action runs under a monitor that records what it read, probed and listed; the record is part of the action's fingerprint | [How caching stays correct](concepts/how-caching-stays-correct.md) |
| Your shell, your tasks and your services come from the same file as your build | The project file, `repro.nim`, declares the development environment, tasks and services next to the packages | [Enter a project's environment](guides/environments/enter-a-project-environment.md) |
| A change in one repository is built against the others without publishing anything | Repositories sit side by side in a workspace; develop mode builds a dependency from its local checkout | [Work on a dependency's source](guides/workspaces/develop-a-dependency.md) |

## Three ways to start

### Build a project you already have

In a Cargo, Go, CMake, Nim or other project that follows its ecosystem's
layout, add a short project file and run:

```bash
repro build
```

See [Build an existing project](guides/building/build-an-existing-project.md).

### Work in a project's development environment

In a project that has a `repro.nim`, start a shell with its tools on `PATH`:

```bash
repro shell
```

See [Enter a project's environment](guides/environments/enter-a-project-environment.md).

### Join a multi-repository workspace

Clone a workspace and the repositories its default projects need:

```bash
repro workspace init <organisation-or-url>
```

See [Join a workspace](guides/workspaces/join-a-workspace.md).

To learn reprobuild step by step instead, follow
[Build your first project](tutorials/first-build.md).

## Start from what you do

| You | Start with |
|---|---|
| Work in a codebase that already uses reprobuild | [Enter a project's environment](guides/environments/enter-a-project-environment.md), then [Join a workspace](guides/workspaces/join-a-workspace.md) |
| Own a project's build and CI | [Conventions and the three modes](concepts/conventions-and-modes.md), then [Build an existing project](guides/building/build-an-existing-project.md) |
| Maintain a workspace of many repositories | [Coming from repo and git submodules](coming-from/repo-and-git-submodules.md) |
| Already know a tool reprobuild replaces | [Coming from another tool](coming-from/index.md) |

## Where to find what

| Section | Read it when you want to |
|---|---|
| [Install](install.md) | Install `repro` on Linux, macOS or Windows |
| [Tutorials](tutorials/first-build.md) | Learn by doing, one guided path at a time |
| Guides | Reach one goal: build, test, environments, tasks and services, workspaces, machines, CI and caches, troubleshooting |
| [Concepts](concepts/how-reprobuild-works.md) | Understand how reprobuild works and why |
| [Coming from…](coming-from/index.md) | Map what you know from Nix, Bazel, direnv, `just`, `repo` or Terraform onto reprobuild |
| [Reference](reference/index.md) | Look up a command, a file format or a term |
