---
title: Reprobuild documentation
description: Reprobuild is a build system whose graph also describes operating systems and fleets of machines; what it does in each area, how one graph covers all of it, and where each kind of help lives.
kind: explanation
persona: evaluator
order: 0
verifies:
  commands: [build, lock update, test, test --shard, shell, exec, run, up, workspace init, develop, home apply, home rollback, infra plan, infra apply, infra apply --accept-passwd-destroy, system, deploy-agent, cache publish, cache substitute]
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
unverified:
  - claim: "One project file drives the build, the development environment, tasks and services."
    reason: "No single test exercises all four from one repro.nim; the claim rests on four separate features."
    owner: unassigned
---

# Reprobuild documentation

Reprobuild (`repro`) is a build system whose graph describes more than
software. In one typed language, and with one engine, it builds your programs
and the tools and libraries they depend on, configures the operating system
they run on, and keeps a fleet of computers in the state you declared.

Its graph connects files, as any build system's does, and also states: a
running service, a user account, a systemd unit, a registry value. As Terraform
does, reprobuild compares the state you declare with the state that exists,
shows you the plan, applies the difference and removes what you no longer
declare. Each applied state is a generation you can roll back to, and applying
runs through the same engine as a build, so a step whose result is already in
place is not repeated. [How reprobuild works](concepts/how-reprobuild-works.md)
explains the idea.

For a project, one tool obtains its dependencies, builds and tests it, gives you
the environment to work on it in, runs its tasks and services, and keeps the
repositories it is made from in step.

## What reprobuild does

| Area | What reprobuild does | Commands |
|---|---|---|
| [Building](guides/building/index.md) | Derives a build graph from the project's layout or project file, and re-runs only the actions whose recorded inputs changed | `repro build`, `repro graph`, `repro watch` |
| [Dependencies](concepts/dependencies-and-the-store.md) | Resolves each tool and library a project names with a version range to one exact version, records it in the lock file, and keeps it in its store | `repro lock`, `repro why`, `repro store` |
| [Testing](concepts/tests-and-certificates.md) | Runs tests as actions in the same graph, splits a suite across machines, and issues test certificates that travel with the commit | `repro test`, `repro certify` |
| [Environments](guides/environments/index.md) | Puts the project's tools on your `PATH`: in a shell, for one command, or whenever you enter its directory | `repro shell`, `repro exec`, `repro allow` |
| [Tasks and services](guides/environments/enter-a-project-environment.md) | Runs the project's named commands, and starts its services, such as a database, with the same tools | `repro run`, `repro up`, `repro down` |
| [Workspaces](guides/workspaces/index.md) | Keeps many repositories side by side at the revisions they declare, and builds a dependency from your checkout of it | `repro workspace`, `repro sync`, `repro develop` |
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
