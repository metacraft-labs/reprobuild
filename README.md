# Reprobuild

Reprobuild (`repro`) exists to make any software easy to modify.

It is a unified build system, package and configuration manager, development environment manager, and infrastructure provisioner (covering both local systems and cloud resources). By folding these layers into a single cohesive description, Reprobuild eliminates the fragmented boundary between "how code is compiled," "how dependencies are resolved," and "how environments are configured."

---

## 1. The Core Philosophy: Easy Modifications

The core goal of Reprobuild is to lower the barrier to modifying any piece of software. In a Reprobuild workspace, the developer workflow is seamless:

1. Type `repro develop firefox` to clone Firefox and auto-provision its exact toolchains, libraries, and dev-env services.
2. If you find a bug in `cairo` (a dependency of Firefox), run `repro develop cairo` from inside the workspace.
3. The workspace automatically clones `cairo` side-by-side, overrides Firefox's dependency pin to this local checkout, and rebuilds dynamically in-process when you edit Cairo's source.

Your workspace grows dynamically into the exact slice of the dependency graph you need to modify.

---

## 2. Framed for Experienced Developers

If you are already familiar with the modern DevOps and build toolchain, Reprobuild maps directly onto concepts you know:

*   **Like Bazel & Buck2**: Models the workspace as a unified build graph of targets with remote action caching. Instead of using a custom language (like Starlark) or a JVM daemon, it uses standard Nim code and compiles into a fast, native binary.
*   **Like BuildXL & Tup**: Enforces hermetic execution and correct caching by monitoring actual file access during compilation. Instead of unstable FUSE layers or proprietary kernel drivers, it uses a user-space filesystem interceptor (`librepro_monitor_shim`) to verify that all observed reads and writes match declared inputs/outputs.
*   **Like Nix & direnv**: Automatically activates locked developer environments on directory entry. Unlike direnv, it prevents toolchain leakage by refusing to run compiler tools directly unless the dev-env context has been activated.
*   **Like devenv.sh & Process Compose**: Orchestrates local background services (databases, queues, daemons) declared inside the DSL, managed by a native dev-env control plane.
*   **Like Terraform**: Declaratively plans and applies configurations across both local hosts (dotfiles, system packages, services) and cloud resources, with generation logs for instant rollbacks.

---

## 3. Key CLI Commands

Reprobuild wraps all development workflows under one CLI.

### Build & Test
*   `repro build [target]` — compile and materialize targets.
*   `repro test` — run the workspace test suite.
*   `repro watch` — start a continuous watch-style build loop.

### Environment & Services
*   `repro shell` — enter an interactive, activated dev-env subshell.
*   `repro exec -- [cmd]` — run a single command within the dev-env context.
*   `repro service start [service]` — spin up background services (e.g. database).
*   `repro service status` — check the state of running services.

### Task Running
*   `repro tasks` — list all named automation tasks registered in `repro.nim`.
*   `repro run [task] -- [args]` — run an environment task, forwarding positional arguments.

### Workspace & Develop Mode
*   `repro develop [package]` — clone a dependency locally and link it in-process.
*   `repro workspace sync` — clone and update all repositories declared in `repro-workspace.toml`.
*   `repro workspace status` — audit git status and alignment across all workspace repos.

### Local Infrastructure
*   `repro infra plan` / `repro infra apply` — plan or apply declarative local machine profiles.
*   `repro infra rollback` — roll back the local system to a previous generation.

---

## 4. Developing Reprobuild

This repository is the public `metacraft-labs/reprobuild` product repository.

### Local Tooling
- `just build` compiles all app entry points listed in `apps/entrypoints.txt`.
- `just test` runs the local Nim test suite.
- `just lint` runs repository requirement and Nim source checks.

### Nix Dev Shell
`nix develop` activates the compiler and library toolchain. To handle private dependency overrides on development hosts, `scripts/dev-shell.sh` auto-detects sibling checkouts:
```bash
# Clone the sibling native recorder (if developer credentials are configured):
gh repo clone metacraft-labs/codetracer-native-recorder ../codetracer-native-recorder

# Enter the dev shell:
bash scripts/dev-shell.sh
```

## 5. License

MIT
