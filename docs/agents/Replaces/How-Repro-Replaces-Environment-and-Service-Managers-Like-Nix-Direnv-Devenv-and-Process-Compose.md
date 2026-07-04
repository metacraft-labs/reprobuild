# How Repro Replaces Environment & Service Managers (Nix, direnv, devenv, Process Compose, Spack, Conan)

> **Status:** Conceptual mapping guide for developers familiar with toolchain provisioning, environment hooks, and development service orchestration.

Reprobuild unifies development environment activation, package resolution, and background service management.

## Conceptual Mapping

Reprobuild manages local paths, platform overrides, tool dependencies, and background services under a single locked model, preventing tool leakage and simplifying service setup.

| Environment/Service Concept | Reprobuild Equivalent | How Repro Solves It |
|---|---|---|
| **`.envrc` / Shell Hook** (direnv) | Directory Shell Hook | `repro hooks ensure` registers shell integration to auto-activate the environment on entry. |
| **`nix develop` / `mkShell`** (Nix) | Pinned Dev-Env | Resolves dependencies via Nix, Scoop, or direct tarballs; locks the environment. |
| **Package Concretization** (Spack/Conan) | Concretizer Solver | Uses a built-in `clingo` solver to resolve package version constraints. |
| **Process Compose / Services** (devenv/process-compose) | Service Orchestration | `servicePlaceholder` inside `devEnv:` block declares services (databases, queues, daemons) managed by the dev-env control plane. |

## Key Commands

- `repro shell` — enter an interactive shell with the project environment activated.
- `repro exec -- [cmd]` — run a command directly in the dev-env context.
- `repro hooks ensure --shell-direnv` — install the delegating `.envrc` hook.
- `repro service start [service]` — start background services declared in the workspace.
- `repro service status` — view status of active background services.
