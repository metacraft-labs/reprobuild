---
title: Reprobuild documentation
description: Reprobuild combines BuildXL's monitored dependency tracking, Nix's pinned store and generations, and Terraform's plan-and-apply state reconciliation into one compile-time-checked build and system graph.
kind: explanation
persona: evaluator
order: 0
verifies:
  commands: [build, reap, lock update, test, test --shard, shell, exec, run, up, watch, hcr, workspace init, develop, home apply, home rollback, infra plan, infra apply, infra apply --accept-passwd-destroy, system, deploy-agent, cache publish, cache substitute]
  tests:
    - tests/integration/t_monitored_zero_output_edge_input_completeness.nim
    - tests/integration/t_uses_resolves_sqlite3_from_real_reprobuild_packages.nim
    - tests/integration/t_lock_update_rewrites_exact_pin_in_both_recipes.nim
    - tests/e2e/sharding/t_e2e_repro_test_shard_partition_total_coverage.nim
    - tests/integration/t_certificates_travel_with_pushed_commit.nim
    - tests/e2e/local-build-engine/t_e2e_repro_run_lists_tasks_and_edges.nim
    - tests/integration/t_l7_repro_up_converges_on_one_shared_instance.nim
    - tests/integration/t_workspace_init_clones_missing_and_reports_existing.nim
    - tests/integration/t_b0_develop_mode_uses_local_source.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_round_trip.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_user_edit_protection.nim
    - libs/repro_binary_cache_client/tests/t_a3_p2_cli_substitute.nim
    - tests/e2e/m69/t_e2e_repro_infra_plan_apply_convergent.nim
    - tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim
    - tests/e2e/m69/t_e2e_windows_registry_system_scope.nim
    - tests/e2e/home-resources/t_integration_prevent_destroy.nim
    - tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim
    - tests/integration/t_infra_apply_cache_hit_preserves_present_outputs.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_converges_from_signed_manifest.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_rejects_wrong_signer.nim
    - libs/repro_resources/tests/t_resource_provider_lane.nim
    - libs/repro_resources/tests/t_rp4_resource_type_macro.nim
    - libs/repro_resources/tests/t_l2_lease_edge.nim
unverified:
  - claim: "One project file drives the build, the development environment, tasks and services."
    reason: "No single test exercises all four from one repro.nim; the claim rests on four separate features."
    owner: unassigned
  - claim: "Incremental no-op and single-file rebuilds compete with Ninja while RunQuota coordinates CPU and memory across concurrent builds."
    reason: "Benchmark harness results against Ninja and RunQuota multi-session pressure tests are not yet wired into scenarios/."
    owner: unassigned
  - claim: "repro watch --hcr reloads modified code into running processes and forms part of the ReproOS runtime model."
    reason: "Hot code reloading (repro watch --hcr, repro hcr) and ReproOS image/add-on gates exist in the repository, and dedicated user-docs scenarios are pending."
    owner: unassigned
---

# Reprobuild documentation

**Reprobuild** (`repro`) combines core ideas from **BuildXL**, **Nix** and
**Terraform** into a single system that builds software, configures operating
systems and converges entire fleets of computers across Linux, macOS and
Windows. It pairs BuildXL's monitored automatic dependency tracking, Nix's
pinned toolchains in a content-addressed store with atomic generations, and
Terraform's plan-and-apply reconciliation into one engine.

Everything is expressed in a compact Nim language (`repro.nim` for projects,
`home.nim` for user accounts and `system.nim` for machines) built on a single
abstraction: **a build graph with automatically tracked dependencies whose
outputs can be live system states as well as files**. An output can be an object
file or an executable, or a running database, a user account, a systemd unit or
a Windows registry key. One typed description replaces separate Makefiles,
Dockerfiles, Nix flakes, direnv hooks, task runners and machine playbooks,
catching structural and type errors at compile time before any action runs.

On incremental builds, Reprobuild competes with fast low-level executors such
as **Ninja** while recording undeclared file reads through user-space filesystem
monitoring and coordinating host CPU and memory across concurrent sessions
through **RunQuota** so parallel developer and AI-agent builds do not thrash the
machine. Paired with package catalogs spanning `reprobuild-packages`, Nix, Scoop
and native OS repositories, atomic generations and in-process **hot code
reloading** (`repro watch --hcr`), it forms the foundation of **ReproOS**: a
malleable operating system where developers and agents can modify, rebuild and
reload any layer of a live machine on the fly.
[How reprobuild works](concepts/how-reprobuild-works.md) traces the graph from
start to finish.

## What reprobuild does

| Area | What reprobuild does | Commands |
|---|---|---|
| [Building](guides/building/index.md) | Derives a build graph from the project's layout or project file, re-runs only the actions whose recorded inputs changed, and reloads modified code into running processes | `repro build`, `repro graph`, `repro watch`, `repro hcr` |
| [Dependencies](concepts/dependencies-and-the-store.md) | Resolves each tool and library a project names with a version range to one exact version, records it in the lock file, and keeps it in its store | `repro lock`, `repro why`, `repro store` |
| [Testing](concepts/tests-and-certificates.md) | Runs tests as actions in the same graph, splits a suite across machines, and issues test certificates that travel with the commit | `repro test`, `repro certify` |
| [Environments](guides/environments/index.md) | Puts the project's tools on your `PATH`: in a shell, for one command, or whenever you enter its directory | `repro shell`, `repro exec`, `repro allow` |
| [Tasks and services](guides/environments/enter-a-project-environment.md) | Runs the project's named commands, and starts its services, such as a database, with the same tools | `repro run`, `repro up`, `repro down` |
| [Workspaces](guides/workspaces/index.md) | Keeps many repositories side by side at the revisions they declare, and builds a dependency from your checkout of it | `repro workspace`, `repro sync`, `repro develop` |
| [Resources](concepts/resources-and-state.md) | Declares resources of types any repository defines, such as a container or a database, reconciles them in dependency order, and leases them to tests | `repro run`, `repro reap` |
| [Operating systems](concepts/machines-and-profiles.md) | Plans and applies a system profile: services and timers, users and groups, files, kernel settings and firewall rules, or registry values, services and features on Windows | `repro infra plan`, `repro infra apply`, `repro system` |
| [Your account](concepts/machines-and-profiles.md#applying-a-home-profile) | Applies a home profile: the tools, files and shell settings of your own account | `repro home` |
| [Fleets](concepts/fleets-and-the-deploy-agent.md) | Keeps each machine at the state a signed manifest declares for it: the machine fetches the manifest, checks the signature and applies it | `repro deploy-agent` |
| [Sharing results](concepts/how-reprobuild-works.md#5-a-fingerprint-decides-whether-to-run-an-action-again) | Publishes what it built to a binary cache, from which another machine fetches it instead of building it again | `repro cache` |

## What it guarantees, and how

| What you get | How reprobuild does it | See it for yourself |
|---|---|---|
| An unchanged action is skipped, and a changed input re-runs it, even an input you never declared | Each action runs under a monitor that records what it read, probed and listed; the record is part of the action's fingerprint | [How caching stays correct](concepts/how-caching-stays-correct.md) |
| Every machine builds with the same version of every tool and library | A solver turns each version range into one version, and the lock file the repository commits records the choice | [Dependencies and the store](concepts/dependencies-and-the-store.md) |
| A suite split across machines runs every test exactly once | `repro test --shard K/N` partitions the suite, sized by how long each test took before | [Tests and certificates](concepts/tests-and-certificates.md) |
| Your shell, your tasks and your services come from the same file as your build | The project file, `repro.nim`, declares the development environment, tasks and services next to the packages | [Enter a project's environment](guides/environments/enter-a-project-environment.md) |
| A change in one repository is built against the others without publishing anything | Repositories sit side by side in a workspace; develop mode builds a dependency from its local checkout | [Work on a dependency's source](guides/workspaces/develop-a-dependency.md) |
| A change to your account's setup can be undone | Each apply records a generation, and a rollback restores an earlier one without overwriting a file you edited | [Machines and profiles](concepts/machines-and-profiles.md) |
| A resource you stop declaring is removed, and a change that loses data needs your consent | Each apply compares the profile with the state the last generation recorded and removes what left it; deleting a user account needs a flag that confirms it, and a protected resource is never removed | [Machines and profiles](concepts/machines-and-profiles.md#plan-then-apply) |
| A machine applies only state that a key it trusts signed | The deploy agent checks each manifest's signature, ignores manifests for other machines, and never applies an older one | [Fleets and the deploy agent](concepts/fleets-and-the-deploy-agent.md) |

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
| Own a project's build, tests and CI | [Conventions and the three modes](concepts/conventions-and-modes.md), [Build an existing project](guides/building/build-an-existing-project.md), then [Tests and certificates](concepts/tests-and-certificates.md) |
| Maintain a workspace of many repositories | [Coming from repo and git submodules](coming-from/repo-and-git-submodules.md) |
| Configure your own account, a machine's operating system or a fleet | [Machines and profiles](concepts/machines-and-profiles.md), [Fleets and the deploy agent](concepts/fleets-and-the-deploy-agent.md), then [Coming from Terraform and OpenTofu](coming-from/terraform-and-opentofu.md) |
| Already know a tool reprobuild replaces | [Coming from another tool](coming-from/index.md) |

## Where to find what

| Section | Read it when you want to |
|---|---|
| [Install](install.md) | Install `repro` on Linux, macOS or Windows |
| [Tutorials](tutorials/first-build.md) | Learn by doing, one guided path at a time |
| [Guides](guides/index.md) | Reach one goal: building, environments, workspaces, troubleshooting |
| [Concepts](concepts/index.md) | Understand how reprobuild works and why |
| [Coming from…](coming-from/index.md) | Map what you know from Nix, Bazel, direnv, `just`, `repo` or Terraform onto reprobuild |
| [Reference](reference/index.md) | Look up a command, a file format or a term |
