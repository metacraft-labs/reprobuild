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
## Build & Test

`repro --help` lists `build`, `test`, `watch`, `clean` under this heading; the rest are listed by `repro --help-all`.

| Command | Subcommands | What it does |
|---|---|---|
| `repro build` | — | Build the current project or the selected targets. |
| `repro test` | — | Run the project's tests. |
| `repro watch` | — | Watch for changes and rebuild or rerun continuously. |
| `repro clean` | — | Remove the current project's build artifacts. |
| `repro bench` | — | Run the project's benchmarks. |
| `repro lint` | — | Run the project's lint checks. |
| `repro certify` | — | Run the required test set and issue a signed test certificate. |
| `repro certificates` | `list`, `plan`, `policy` | List the project's named certificates or those a plan issues. |
| `repro ci` | `plan` | Plan which targets a CI run must execute. |
| `repro graph` | — | Render the build graph of the current context. |
| `repro deps` | `refresh` | Refresh and check scanner-inferred dependencies. |
| `repro stats` | — | Inspect accumulated build analytics. |
| `repro configs` | — | List the standard build configurations. |
| `repro show-conventions` | — | Print the resolved convention stack of a workspace. |
| `repro cargo` | `gc`, `record-live`, `run` | Manage cargo target directories and run cargo as a build edge. |

## Environments & Services

`repro --help` lists `shell`, `exec`, `up`, `down`, `run`, `tasks` under this heading; the rest are listed by `repro --help-all`.

| Command | Subcommands | What it does |
|---|---|---|
| `repro shell` | `hook` | Enter or print the development shell environment. |
| `repro exec` | — | Run a command inside the development environment. |
| `repro up` | — | Start the project's services. |
| `repro down` | — | Stop the project's supervised development session. |
| `repro run` | — | Run a task, a build output or a target once. |
| `repro tasks` | — | List the current project's tasks. |
| `repro dev` | — | Run the development session with continuous rebuilds. |
| `repro hcr` | `coordinate`, `prepare-object` | Coordinate hot code reloading. |
| `repro allow` | — | Trust a directory's development environment, so the shell hook activates it. |
| `repro deny` | — | Revoke the trust `repro allow` recorded for a directory. |
| `repro dev-env` | `export`, `deactivate` | Export or deactivate a development environment for a shell. |
| `repro prompt` | `init` | Print a workspace-state segment for the shell prompt. |
| `repro launch-plan` | `show`, `id` | Show stored launch plans. |

## Dependencies & Workspaces

`repro --help` lists `develop`, `add`, `why`, `lock`, `workspace` under this heading; the rest are listed by `repro --help-all`.

| Command | Subcommands | What it does |
|---|---|---|
| `repro develop` | — | Set up a project or a dependency for development. |
| `repro add` | — | Add a package dependency to the current project's repro.nim. |
| `repro why` | — | Explain why a package or an action is in the active context. |
| `repro lock` | `list`, `solve`, `refresh`, `update`, `validate`, `diff`, `explain` | Inspect and update the project's lock. |
| `repro workspace` (`repro ws`) | — | Manage the multi-repository workspace. |
| `repro tool` | `realize` | Realize one provisioned tool of the project. |
| `repro remove` | — | Remove a package dependency from the current project's repro.nim. |
| `repro sync` | — | Fast-forward the workspace's repositories toward a target. |
| `repro pull` | — | Converge the workspace onto its declared revisions. |
| `repro branch` | — | Fork a new sibling workspace on a new branch (with no path: print the workspace's branch). |
| `repro switch` | — | Switch the workspace to a branch. |
| `repro push` | — | Publish the current work as a reproducible workspace state. |
| `repro check` | — | Run the publication checks (the pre-push gate). |
| `repro hooks` | `ensure`, `reinstall`, `uninstall` | Install, repair or remove the managed hooks. |
| `repro locking` | `explain`, `adopt-manifest` | Explain or adopt the workspace's locking configuration. |
| `repro flake` | `override-args`, `refresh-lock`, `override-status` | Compute the Nix flake overrides of the develop set. |
| `repro gateway` | `pre-receive`, `post-receive`, `migrate` | Run a push-gateway hook entry point. |
| `repro bundle` | `create`, `publish`, `restore`, `inspect` | Create, publish and restore workspace bundles (docs/workspace-bundles.md). |
| `repro catalog` | `generate`, `verify`, `publish` | Publish a catalog's interface artifacts, or generate and verify a Nimble package index. |
| `repro nimble` | `verify`, `check` | Work with the Nimble packages a lock pins. |

## Machines & Diagnostics

`repro --help` lists `home`, `system`, `infra`, `health` under this heading; the rest are listed by `repro --help-all`.

| Command | Subcommands | What it does |
|---|---|---|
| `repro home` | `add`, `remove`, `enable`, `disable`, `list`, `why`, `history`, `apply`, `plan`, `export`, `facts`, `compare`, `rollback`, `gc`, `set`, `get`, `adopt`, `resource`, `migrate-from-env-scripts` | Manage your home profile. |
| `repro system` | `add`, `remove`, `list`, `why`, `plan`, `apply`, `sync`, `history`, `rollback`, `audit`, `addon`, `state`, `secret`, `adopt` | Manage the machine's system configuration. |
| `repro infra` | `plan`, `apply`, `cache-keys`, `install-root`, `image` | Plan and apply infrastructure. |
| `repro health` | — | Diagnose the reprobuild environment; exit 1 when any check fails. |
| `repro anywhere` | — | Bootstrap a booted distribution host into ReproOS add-on mode over SSH (Linux): without --expect-plan print the plan and exit 3, with it apply. |
| `repro deploy-agent` | `keygen` | Run one deploy-agent tick: poll the manifests, verify them and apply the newest for the target. |
| `repro hardware` | `probe` | Probe the machine's hardware. |
| `repro disk` | `plan`, `apply`, `mount`, `unmount`, `generate`, `image` | Plan, apply and mount disk layouts. |
| `repro attest` | `expect`, `challenge`, `verify`, `cross-check`, `launch`, `reap` | Compute and check launch measurements of attested images. |
| `repro cert-signer` | `serve`, `registration` | Run the certificate signer for remote build workers. |
| `repro daemon` | `status`, `start`, `stop`, `restart`, `logs`, `sessions` | Manage the per-user reprobuild daemon. |
| `repro store` | `gc`, `recover`, `roots`, `list`, `optimise`, `materialize`, `closure`, `export`, `import`, `copy`, `daemon` | Manage the local store. |
| `repro cas` | `gc`, `verify`, `path`, `exists` | Inspect the content-addressed blob store. |
| `repro cache` | `lookup`, `substitute`, `publish`, `derive-key`, `gen-key`, `key`, `explain`, `sharing` | Look up, substitute and publish binary-cache entries, explain build actions' cache keys (`key`, `explain`), and say what another checkout can reuse (`sharing`). |
| `repro reap` | — | Run one sweep of the resource-state store. |
| `repro self` | `install`, `provision`, `hold`, `which`, `list`, `prune-roots` | Install and manage reprobuild's own versions. |
| `repro pressure` | — | Show build-wait pressure from the RunQuota daemon (exit 1 when it cannot be reached or predates it). |
| `repro capabilities` | — | Describe what this build of repro supports. |
| `repro debug` | `io`, `artifact` | Inspect the filesystem monitor and artifacts. |
| `repro version` | — | Show the client version and the protocol versions it speaks. |
| `repro help` | — | Show the help of repro or of one command. |
| `repro completion` | — | Print a shell's completion script. |
<!-- generated:end -->

## All commands, alphabetically

<!-- generated:begin cli-reference index by=name -->
| Command | Area | What it does |
|---|---|---|
| `repro add` | Dependencies & Workspaces | Add a package dependency to the current project's repro.nim. |
| `repro allow` | Environments & Services | Trust a directory's development environment, so the shell hook activates it. |
| `repro anywhere` | Machines & Diagnostics | Bootstrap a booted distribution host into ReproOS add-on mode over SSH (Linux): without --expect-plan print the plan and exit 3, with it apply. |
| `repro attest` | Machines & Diagnostics | Compute and check launch measurements of attested images. |
| `repro bench` | Build & Test | Run the project's benchmarks. |
| `repro branch` | Dependencies & Workspaces | Fork a new sibling workspace on a new branch (with no path: print the workspace's branch). |
| `repro build` | Build & Test | Build the current project or the selected targets. |
| `repro bundle` | Dependencies & Workspaces | Create, publish and restore workspace bundles (docs/workspace-bundles.md). |
| `repro cache` | Machines & Diagnostics | Look up, substitute and publish binary-cache entries, explain build actions' cache keys (`key`, `explain`), and say what another checkout can reuse (`sharing`). |
| `repro capabilities` | Machines & Diagnostics | Describe what this build of repro supports. |
| `repro cargo` | Build & Test | Manage cargo target directories and run cargo as a build edge. |
| `repro cas` | Machines & Diagnostics | Inspect the content-addressed blob store. |
| `repro catalog` | Dependencies & Workspaces | Publish a catalog's interface artifacts, or generate and verify a Nimble package index. |
| `repro cert-signer` | Machines & Diagnostics | Run the certificate signer for remote build workers. |
| `repro certificates` | Build & Test | List the project's named certificates or those a plan issues. |
| `repro certify` | Build & Test | Run the required test set and issue a signed test certificate. |
| `repro check` | Dependencies & Workspaces | Run the publication checks (the pre-push gate). |
| `repro ci` | Build & Test | Plan which targets a CI run must execute. |
| `repro clean` | Build & Test | Remove the current project's build artifacts. |
| `repro completion` | Machines & Diagnostics | Print a shell's completion script. |
| `repro configs` | Build & Test | List the standard build configurations. |
| `repro daemon` | Machines & Diagnostics | Manage the per-user reprobuild daemon. |
| `repro debug` | Machines & Diagnostics | Inspect the filesystem monitor and artifacts. |
| `repro deny` | Environments & Services | Revoke the trust `repro allow` recorded for a directory. |
| `repro deploy-agent` | Machines & Diagnostics | Run one deploy-agent tick: poll the manifests, verify them and apply the newest for the target. |
| `repro deps` | Build & Test | Refresh and check scanner-inferred dependencies. |
| `repro dev` | Environments & Services | Run the development session with continuous rebuilds. |
| `repro dev-env` | Environments & Services | Export or deactivate a development environment for a shell. |
| `repro develop` | Dependencies & Workspaces | Set up a project or a dependency for development. |
| `repro disk` | Machines & Diagnostics | Plan, apply and mount disk layouts. |
| `repro down` | Environments & Services | Stop the project's supervised development session. |
| `repro exec` | Environments & Services | Run a command inside the development environment. |
| `repro flake` | Dependencies & Workspaces | Compute the Nix flake overrides of the develop set. |
| `repro gateway` | Dependencies & Workspaces | Run a push-gateway hook entry point. |
| `repro graph` | Build & Test | Render the build graph of the current context. |
| `repro hardware` | Machines & Diagnostics | Probe the machine's hardware. |
| `repro hcr` | Environments & Services | Coordinate hot code reloading. |
| `repro health` | Machines & Diagnostics | Diagnose the reprobuild environment; exit 1 when any check fails. |
| `repro help` | Machines & Diagnostics | Show the help of repro or of one command. |
| `repro home` | Machines & Diagnostics | Manage your home profile. |
| `repro hooks` | Dependencies & Workspaces | Install, repair or remove the managed hooks. |
| `repro infra` | Machines & Diagnostics | Plan and apply infrastructure. |
| `repro launch-plan` | Environments & Services | Show stored launch plans. |
| `repro lint` | Build & Test | Run the project's lint checks. |
| `repro lock` | Dependencies & Workspaces | Inspect and update the project's lock. |
| `repro locking` | Dependencies & Workspaces | Explain or adopt the workspace's locking configuration. |
| `repro nimble` | Dependencies & Workspaces | Work with the Nimble packages a lock pins. |
| `repro pressure` | Machines & Diagnostics | Show build-wait pressure from the RunQuota daemon (exit 1 when it cannot be reached or predates it). |
| `repro prompt` | Environments & Services | Print a workspace-state segment for the shell prompt. |
| `repro pull` | Dependencies & Workspaces | Converge the workspace onto its declared revisions. |
| `repro push` | Dependencies & Workspaces | Publish the current work as a reproducible workspace state. |
| `repro reap` | Machines & Diagnostics | Run one sweep of the resource-state store. |
| `repro remove` | Dependencies & Workspaces | Remove a package dependency from the current project's repro.nim. |
| `repro run` | Environments & Services | Run a task, a build output or a target once. |
| `repro self` | Machines & Diagnostics | Install and manage reprobuild's own versions. |
| `repro shell` | Environments & Services | Enter or print the development shell environment. |
| `repro show-conventions` | Build & Test | Print the resolved convention stack of a workspace. |
| `repro stats` | Build & Test | Inspect accumulated build analytics. |
| `repro store` | Machines & Diagnostics | Manage the local store. |
| `repro switch` | Dependencies & Workspaces | Switch the workspace to a branch. |
| `repro sync` | Dependencies & Workspaces | Fast-forward the workspace's repositories toward a target. |
| `repro system` | Machines & Diagnostics | Manage the machine's system configuration. |
| `repro tasks` | Environments & Services | List the current project's tasks. |
| `repro test` | Build & Test | Run the project's tests. |
| `repro tool` | Dependencies & Workspaces | Realize one provisioned tool of the project. |
| `repro up` | Environments & Services | Start the project's services. |
| `repro version` | Machines & Diagnostics | Show the client version and the protocol versions it speaks. |
| `repro watch` | Build & Test | Watch for changes and rebuild or rerun continuously. |
| `repro why` | Dependencies & Workspaces | Explain why a package or an action is in the active context. |
| `repro workspace` (`ws`) | Dependencies & Workspaces | Manage the multi-repository workspace. |
<!-- generated:end -->
