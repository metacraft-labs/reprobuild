# Reprobuild for Experienced Developers & AI Agents

Reprobuild is a unified build, dependency, environment, and workspace tool.

## Architecture & Grepable Keywords

Reprobuild models the workspace as a directed acyclic graph (DAG) of type-checked actions defined in the **`repro.nim`** DSL. Sibling repositories declared in **`repro-workspace.toml`** are routed dynamically using **`repro develop`** (develop-mode). Build hermeticity is enforced using the **`librepro_monitor_shim`** user-space filesystem interceptor, and execution is cached locally via the shared-memory **`repro-cache-daemon`**. Package toolchains are concretized using a **`clingo`** solver, and background services are orchestrated using **`servicePlaceholder`** declarations.

## Replaced Systems

- **[Build Systems (Bazel, Buck2, BuildXL, Tup)](Replaces/How-Repro-Replaces-Build-Systems-Like-Bazel-Buck2-BuildXL-and-Tup.md)**: Models the workspace as a type-checked DAG. Enforces hermetic builds using a user-space filesystem monitor shim (`librepro_monitor_shim`) and uses a shared-memory action cache daemon for sub-millisecond cache checks.
- **[Environment & Service Managers (Nix, direnv, devenv, Process Compose, Spack, Conan)](Replaces/How-Repro-Replaces-Environment-and-Service-Managers-Like-Nix-Direnv-Devenv-and-Process-Compose.md)**: Automatically overlays locked environment configurations upon directory entry and uses a `clingo` solver to concretize version constraints. Orchestrates project background services (databases, daemons, queues) natively.
- **[Task Runners (Just, Make)](Replaces/How-Repro-Replaces-Task-Runners-Like-Just-and-Make.md)**: Defines named task scripts within the package DSL that run directly inside the activated dev-env.
- **[Workspace Managers (repo, Git submodules)](Replaces/How-Repro-Replaces-Workspace-Managers-Like-Repo-and-Git-Submodules.md)**: Integrates multi-repository workspace checkout rules (`repro-workspace.toml`) with the build graph.
- **[Local Infrastructure Provisioners (Terraform)](Replaces/How-Repro-Replaces-Local-Infrastructure-Provisioners-Like-Terraform.md)**: Declaratively configures local developer machine state (dotfiles, system packages, services) with generation-based rolling updates and rollbacks.
