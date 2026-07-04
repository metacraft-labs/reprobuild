# How Repro Replaces Task Runners (Just, Make)

> **Status:** Conceptual mapping guide for developers migrating project scripts and task targets to Reprobuild.

Reprobuild integrates script running and dev-env automation directly into the package description.

## Conceptual Mapping

Reprobuild replaces standalone command runners like `just` and `make` by declaring tasks directly in the project configuration. Tasks run automatically inside the project's activated environment.

| Task Runner Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **Recipe / Target Name** (just/make) | `task "<name>"` | Named dev-env tasks are declared inside the `devEnv:` block of the project DSL. |
| **Recipe Commands** | Task `command` | The execution string of the task. |
| **Argument Forwarding** | Forwarded Arguments | Positional arguments passed after `--` are forwarded to the task command. |
| **`just --list` / `make help`** | `repro tasks` | Lists all registered tasks and their descriptions. |

## Key Commands

- `repro tasks` — list all tasks declared in the project.
- `repro run [task] -- [args]` — run a task, forwarding arguments.
