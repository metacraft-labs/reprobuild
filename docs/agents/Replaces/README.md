# What Reprobuild Replaces

> **Status:** Skill-style index. Read on demand when you need to understand how Reprobuild covers what a tool you already know does.

Reprobuild is a single end-to-end build, dependency, environment, and workspace tool. It absorbs functionality that is historically split across many smaller tools. This directory is the index of those relationships, written so developers who know those tools can quickly map their concepts to Reprobuild's.

## Index of Replacement Guides

- **[Build Systems (Bazel, Buck2, BuildXL, Tup)](./How-Repro-Replaces-Build-Systems-Like-Bazel-Buck2-BuildXL-and-Tup.md)**: Models the workspace as a type-checked DAG, executes sandboxed actions using a user-space filesystem interceptor shim, and speeds up caching using a local shared-memory cache daemon.
- **[Environment & Service Managers (Nix, direnv, devenv, Process Compose, Spack, Conan)](./How-Repro-Replaces-Environment-and-Service-Managers-Like-Nix-Direnv-Devenv-and-Process-Compose.md)**: Configures and overlays locked environments on directory entry, resolves package constraints using a concretizer solver, and orchestrates background services.
- **[Task Runners (Just, Make)](./How-Repro-Replaces-Task-Runners-Like-Just-and-Make.md)**: Exposes named automation tasks inside the activated dev-env.
- **[Workspace Managers (repo, Git submodules)](./How-Repro-Replaces-Workspace-Managers-Like-Repo-and-Git-Submodules.md)**: Manages multi-repo checkouts through a workspace manifest.
- **[Local Infrastructure Provisioners (Terraform)](./How-Repro-Replaces-Local-Infrastructure-Provisioners-Like-Terraform.md)**: Declaratively configures host packages, dotfiles, and system services with generation-based rolling updates and rollbacks.
