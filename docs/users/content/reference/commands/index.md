---
title: Commands
description: Every user-facing repro command and subcommand, generated from the CLI description and grouped both by domain and alphabetically.
kind: reference
persona: developer
order: 10
unverified:
  - claim: "One reference page per command is generated with its options, defaults, exit status and side-effect class."
    reason: "The index tables below are generated from cli_description.nim; per-command pages are pending full flag migration across legacy pass-through commands."
    owner: unassigned
---

# Commands

This page lists every user-facing `repro` command from the CLI's own declarative
description (`cli_description.nim`), grouped first by what it works on and then
alphabetically. Run `repro <command> --help` (or `repro <command> <subcommand> --help`)
to inspect every option, default value and exit code for a command.

Commands fall into four side-effect classes:

- reads only: inspects and reports, and changes nothing;
- changes the working tree: writes files in your project or workspace;
- changes the workspace definition: edits the manifests, which you then commit for everyone;
- publishes: writes to a shared store or a remote.

<!-- generated:begin cli-reference index by=domain -->
## Building and testing

| Command | Subcommands | What it does |
|---|---|---|
| `repro build` | — | Build the current project or the selected targets. |
| `repro test` | — | Run the project's tests. |
| `repro bench` | — | Run the project's benchmarks. |
| `repro lint` | — | Run the project's lint checks. |
| `repro certify` | — | Run the required test set and issue a signed test certificate. |
| `repro certificates` | — | List the project's named certificates or those a plan issues. |
| `repro ci` | — | Plan which targets a CI run must execute. |
| `repro watch` | — | Watch for changes and rebuild or rerun continuously. |
| `repro clean` | — | Remove the current project's build artifacts. |
| `repro run` | — | Run a task, a build output or a target once. |
| `repro tasks` | — | List the current project's tasks. |

## Inspecting the graph

| Command | Subcommands | What it does |
|---|---|---|
| `repro graph` | — | Render the build graph of the current context. |
| `repro why` | — | Explain why a package or an action is in the active context. |
| `repro deps` | `refresh` | Refresh and check scanner-inferred dependencies. |
| `repro stats` | — | Inspect accumulated build analytics. |
| `repro show-conventions` | — | Print the resolved convention stack of a workspace. |
| `repro configs` | — | List the standard build configurations. |
| `repro capabilities` | — | Describe what this build of repro supports. |

## Development environments

| Command | Subcommands | What it does |
|---|---|---|
| `repro exec` | — | Run a command inside the development environment. |
| `repro shell` | `hook` | Enter or print the development shell environment. |
| `repro allow` | — | Trust a directory's development environment, so the shell hook activates it. |
| `repro deny` | — | Revoke the trust `repro allow` recorded for a directory. |
| `repro dev-env` | `export`, `deactivate` | Export or deactivate a development environment for a shell. |
| `repro up` | — | Start the project's services. |
| `repro down` | — | Stop the project's supervised development session. |
| `repro dev` | — | Run the development session with continuous rebuilds. |
| `repro develop` | — | Set up a project or a dependency for development. |
| `repro add` | — | Add a dependency to the active context. |
| `repro remove` | — | Remove a dependency from the active context. |
| `repro hcr` | `coordinate`, `prepare-object` | Coordinate hot code reloading. |

## Workspaces and publication

| Command | Subcommands | What it does |
|---|---|---|
| `repro workspace` (`repro ws`) | — | Manage the multi-repository workspace. |
| `repro sync` | — | Fast-forward the workspace's repositories toward a target. |
| `repro pull` | — | Converge the workspace onto its declared revisions. |
| `repro branch` | — | Fork a new sibling workspace on a new branch (with no path: print the workspace's branch). |
| `repro switch` | — | Switch the workspace to a branch. |
| `repro push` | — | Publish the current work as a reproducible workspace state. |
| `repro check` | — | Run the publication checks (the pre-push gate). |
| `repro hooks` | `ensure`, `reinstall`, `uninstall` | Install, repair or remove the managed hooks. |
| `repro lock` | `list`, `solve`, `refresh`, `update`, `validate`, `diff`, `explain` | Inspect and update the project's lock. |
| `repro locking` | `explain`, `adopt-manifest` | Explain or adopt the workspace's locking configuration. |
| `repro flake` | `override-args`, `refresh-lock`, `override-status` | Compute the Nix flake overrides of the develop set. |
| `repro gateway` | `pre-receive`, `post-receive`, `migrate` | Run a push-gateway hook entry point. |
| `repro prompt` | `init` | Print a workspace-state segment for the shell prompt. |

## Stores, caches and daemons

| Command | Subcommands | What it does |
|---|---|---|
| `repro daemon` | `status`, `start`, `stop`, `restart`, `logs`, `sessions` | Manage the per-user reprobuild daemon. |
| `repro store` | `gc`, `recover`, `roots`, `list`, `optimise`, `materialize`, `closure`, `export`, `import`, `copy`, `daemon` | Manage the local store. |
| `repro cas` | `gc`, `verify`, `path`, `exists` | Inspect the content-addressed blob store. |
| `repro cache` | `lookup`, `substitute`, `publish`, `derive-key`, `gen-key` | Look up, substitute and publish binary-cache entries. |
| `repro bundle` | `create`, `publish`, `restore`, `inspect` | Create, publish and restore workspace bundles (docs/workspace-bundles.md). |
| `repro reap` | — | Run one sweep of the resource-state store. |
| `repro launch-plan` | `show`, `id` | Show stored launch plans. |
| `repro cert-signer` | `serve`, `registration` | Run the certificate signer for remote build workers. |
| `repro self` | `install`, `provision`, `hold`, `which`, `list`, `prune-roots` | Install and manage reprobuild's own versions. |

## Machines

| Command | Subcommands | What it does |
|---|---|---|
| `repro home` | `add`, `remove`, `enable`, `disable`, `list`, `why`, `history`, `apply`, `plan`, `export`, `facts`, `compare`, `rollback`, `gc`, `set`, `get`, `adopt`, `resource`, `migrate-from-env-scripts` | Manage your home profile. |
| `repro system` | `add`, `remove`, `list`, `why`, `sync`, `history`, `rollback`, `audit`, `addon`, `state`, `secret`, `adopt` | Manage the machine's system configuration. |
| `repro infra` | `plan`, `apply`, `cache-keys`, `install-root`, `image` | Plan and apply infrastructure. |
| `repro anywhere` | — | Bootstrap a booted distribution host into ReproOS add-on mode over SSH (Linux): without --expect-plan print the plan and exit 3, with it apply. |
| `repro deploy-agent` | `keygen` | Run one deploy-agent tick: poll the manifests, verify them and apply the newest for the target. |
| `repro hardware` | `probe` | Probe the machine's hardware. |
| `repro disk` | `plan`, `apply`, `mount`, `unmount`, `generate`, `image` | Plan, apply and mount disk layouts. |
| `repro attest` | — | Compute and check launch measurements of attested images. |
| `repro cargo` | `gc`, `record-live`, `run` | Manage cargo target directories and run cargo as a build edge. |

## About repro itself

| Command | Subcommands | What it does |
|---|---|---|
| `repro pressure` | — | Show build-wait pressure from the RunQuota daemon (exit 1 when it cannot be reached or predates it). |
| `repro health` | — | Diagnose the reprobuild environment; exit 1 when any check fails. |
| `repro debug` | `io`, `artifact` | Inspect the filesystem monitor and artifacts. |
| `repro help` | — | Show the help of repro or of one command. |
| `repro version` | — | Show the client version and the protocol versions it speaks. |
| `repro completion` | — | Print a shell's completion script. |
<!-- generated:end -->

## All commands, alphabetically

<!-- generated:begin cli-reference index by=name -->
| Command | Area | What it does |
|---|---|---|
| `repro add` | Development environments | Add a dependency to the active context. |
| `repro allow` | Development environments | Trust a directory's development environment, so the shell hook activates it. |
| `repro anywhere` | Machines | Bootstrap a booted distribution host into ReproOS add-on mode over SSH (Linux): without --expect-plan print the plan and exit 3, with it apply. |
| `repro attest` | Machines | Compute and check launch measurements of attested images. |
| `repro bench` | Building and testing | Run the project's benchmarks. |
| `repro branch` | Workspaces and publication | Fork a new sibling workspace on a new branch (with no path: print the workspace's branch). |
| `repro build` | Building and testing | Build the current project or the selected targets. |
| `repro bundle` | Stores, caches and daemons | Create, publish and restore workspace bundles (docs/workspace-bundles.md). |
| `repro cache` | Stores, caches and daemons | Look up, substitute and publish binary-cache entries. |
| `repro capabilities` | Inspecting the graph | Describe what this build of repro supports. |
| `repro cargo` | Machines | Manage cargo target directories and run cargo as a build edge. |
| `repro cas` | Stores, caches and daemons | Inspect the content-addressed blob store. |
| `repro cert-signer` | Stores, caches and daemons | Run the certificate signer for remote build workers. |
| `repro certificates` | Building and testing | List the project's named certificates or those a plan issues. |
| `repro certify` | Building and testing | Run the required test set and issue a signed test certificate. |
| `repro check` | Workspaces and publication | Run the publication checks (the pre-push gate). |
| `repro ci` | Building and testing | Plan which targets a CI run must execute. |
| `repro clean` | Building and testing | Remove the current project's build artifacts. |
| `repro completion` | About repro itself | Print a shell's completion script. |
| `repro configs` | Inspecting the graph | List the standard build configurations. |
| `repro daemon` | Stores, caches and daemons | Manage the per-user reprobuild daemon. |
| `repro debug` | About repro itself | Inspect the filesystem monitor and artifacts. |
| `repro deny` | Development environments | Revoke the trust `repro allow` recorded for a directory. |
| `repro deploy-agent` | Machines | Run one deploy-agent tick: poll the manifests, verify them and apply the newest for the target. |
| `repro deps` | Inspecting the graph | Refresh and check scanner-inferred dependencies. |
| `repro dev` | Development environments | Run the development session with continuous rebuilds. |
| `repro dev-env` | Development environments | Export or deactivate a development environment for a shell. |
| `repro develop` | Development environments | Set up a project or a dependency for development. |
| `repro disk` | Machines | Plan, apply and mount disk layouts. |
| `repro down` | Development environments | Stop the project's supervised development session. |
| `repro exec` | Development environments | Run a command inside the development environment. |
| `repro flake` | Workspaces and publication | Compute the Nix flake overrides of the develop set. |
| `repro gateway` | Workspaces and publication | Run a push-gateway hook entry point. |
| `repro graph` | Inspecting the graph | Render the build graph of the current context. |
| `repro hardware` | Machines | Probe the machine's hardware. |
| `repro hcr` | Development environments | Coordinate hot code reloading. |
| `repro health` | About repro itself | Diagnose the reprobuild environment; exit 1 when any check fails. |
| `repro help` | About repro itself | Show the help of repro or of one command. |
| `repro home` | Machines | Manage your home profile. |
| `repro hooks` | Workspaces and publication | Install, repair or remove the managed hooks. |
| `repro infra` | Machines | Plan and apply infrastructure. |
| `repro launch-plan` | Stores, caches and daemons | Show stored launch plans. |
| `repro lint` | Building and testing | Run the project's lint checks. |
| `repro lock` | Workspaces and publication | Inspect and update the project's lock. |
| `repro locking` | Workspaces and publication | Explain or adopt the workspace's locking configuration. |
| `repro pressure` | About repro itself | Show build-wait pressure from the RunQuota daemon (exit 1 when it cannot be reached or predates it). |
| `repro prompt` | Workspaces and publication | Print a workspace-state segment for the shell prompt. |
| `repro pull` | Workspaces and publication | Converge the workspace onto its declared revisions. |
| `repro push` | Workspaces and publication | Publish the current work as a reproducible workspace state. |
| `repro reap` | Stores, caches and daemons | Run one sweep of the resource-state store. |
| `repro remove` | Development environments | Remove a dependency from the active context. |
| `repro run` | Building and testing | Run a task, a build output or a target once. |
| `repro self` | Stores, caches and daemons | Install and manage reprobuild's own versions. |
| `repro shell` | Development environments | Enter or print the development shell environment. |
| `repro show-conventions` | Inspecting the graph | Print the resolved convention stack of a workspace. |
| `repro stats` | Inspecting the graph | Inspect accumulated build analytics. |
| `repro store` | Stores, caches and daemons | Manage the local store. |
| `repro switch` | Workspaces and publication | Switch the workspace to a branch. |
| `repro sync` | Workspaces and publication | Fast-forward the workspace's repositories toward a target. |
| `repro system` | Machines | Manage the machine's system configuration. |
| `repro tasks` | Building and testing | List the current project's tasks. |
| `repro test` | Building and testing | Run the project's tests. |
| `repro up` | Development environments | Start the project's services. |
| `repro version` | About repro itself | Show the client version and the protocol versions it speaks. |
| `repro watch` | Building and testing | Watch for changes and rebuild or rerun continuously. |
| `repro why` | Inspecting the graph | Explain why a package or an action is in the active context. |
| `repro workspace` (`ws`) | Workspaces and publication | Manage the multi-repository workspace. |
<!-- generated:end -->
