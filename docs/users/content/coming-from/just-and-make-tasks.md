---
title: Coming from just and make
description: How just recipes and make targets used as a task runner map onto reprobuild's tasks and build actions, and when just or make is the better choice.
kind: explanation
persona: developer
order: 40
verifies:
  commands: [tasks, run, build]
  tests:
    - tests/e2e/local-build-engine/t_e2e_repro_run_lists_tasks_and_edges.nim
---

# Coming from `just` and `make`

This page maps a `justfile`, or a `Makefile` used as a task runner, onto
reprobuild, explains where they differ, and says when `just` or `make` remains
the better choice.

## What carries over

- Named commands live in the repository. A recipe or a phony target becomes a [task](../reference/glossary.md#task) in the project file.
- You list them and run them by name. `just --list` becomes `repro tasks`; `just test` becomes `repro run test`.
- Arguments pass through. Arguments after `--` go to the task's command: `repro run test -- --verbose`.

## Concept map

| `just` or `make` | reprobuild |
|---|---|
| recipe, phony target | task, declared in the `devEnv:` block |
| `just --list`, `make help` | `repro tasks` |
| `just <recipe>`, `make <target>` | `repro run <task>` |
| recipe arguments | arguments after `--` |
| a file target with prerequisites | an [action](../reference/glossary.md#action) in the build graph |

A task is declared like this:

```nim
devEnv:
  task "test",
    command = "just test",
    description = "Build the apps and run the full test suite"
```

The command can stay a call to your existing `justfile` while you move over.

## What works differently

A task runs inside the project's environment. reprobuild activates the
[development environment](../reference/glossary.md#development-environment)
first, so a task uses the project's tools whether or not your shell has them.

Building is not a task. A make rule that produces a file is a build step, and
in reprobuild a build step is an action: it is cached, run in parallel with
independent actions, and run again only when something it read changes. Keep
tasks for commands that are not builds, such as starting a release or seeding a
database.

## When `just` or `make` remains the better choice

- `just`, when you want a small, readable list of commands and nothing that inspects or caches what they do.
- `make`, when your build already is a set of correct make rules and the repository needs no environment or workspace around it.

## Next steps

- [Enter a project's environment](../guides/environments/enter-a-project-environment.md)
- [How caching stays correct](../concepts/how-caching-stays-correct.md)
- [Command equivalents](../reference/command-equivalents.md#just)
