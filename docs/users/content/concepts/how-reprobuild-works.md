---
title: How reprobuild works
description: How Reprobuild combines BuildXL's monitored dependency graph, Nix's content-addressed store and generations, and Terraform's plan-and-apply reconciliation from one project file up to ReproOS and fleets.
kind: explanation
persona: evaluator
order: 1
verifies:
  commands: [build, reap, graph, show-conventions, lock update, test, cache publish, cache substitute, shell, exec, run, up, watch, hcr, pressure, develop, workspace, home apply, home rollback, infra plan, infra apply, system rollback, deploy-agent]
  tests:
    - tests/integration/t_monitored_zero_output_edge_input_completeness.nim
    - tests/integration/t_uses_resolves_sqlite3_from_real_reprobuild_packages.nim
    - tests/integration/t_b3_repro_test_runs_through_engine.nim
    - tests/e2e/sharding/t_e2e_repro_test_shard_partition_total_coverage.nim
    - tests/integration/t_certificates_travel_with_pushed_commit.nim
    - libs/repro_binary_cache_client/tests/t_a3_p2_cli_substitute.nim
    - tests/integration/t_b0_develop_mode_uses_local_source.nim
    - tests/integration/t_bulk_develop_skips_exact_recipe_pins.nim
    - tests/integration/t_l7_repro_up_converges_on_one_shared_instance.nim
    - tests/e2e/home-apply/t_e2e_repro_home_apply_noop.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_round_trip.nim
    - tests/integration/t_infra_apply_cache_hit_preserves_present_outputs.nim
    - tests/e2e/m69/t_e2e_repro_infra_plan_apply_convergent.nim
    - tests/e2e/m69/t_e2e_repro_infra_depends_on_topological.nim
    - tests/e2e/m69/t_e2e_repro_infra_plan_time_external_drift.nim
    - tests/e2e/home-resources/t_integration_prevent_destroy.nim
    - tests/e2e/m69/t_e2e_repro_system_command_family.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_converges_from_signed_manifest.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_rejects_wrong_signer.nim
    - libs/repro_resources/tests/t_resource_provider_lane.nim
    - libs/repro_resources/tests/t_l1_state_store.nim
    - libs/repro_resources/tests/t_l3_reaper.nim
unverified:
  - claim: "Paths below a provisioned tool's root are left out of an action's observed inputs because the tool's identity already covers them."
    reason: "Stated in docs/dependency-collection.md; no test is cited yet."
    owner: unassigned
  - claim: "repro develop --only=<dependency> checks one dependency out at its locked revision and switches the build to it."
    reason: "From the develop command design; the cited test covers --all, not --only with a single dependency."
    owner: unassigned
  - claim: "The release archive includes repro-binary-cache, a cache server you can run yourself."
    reason: "Checked by scripts/verify_release.sh when a release is cut, not by a test this page can cite."
    owner: unassigned
  - claim: "Incremental rebuilds compete with Ninja while RunQuota coordinates CPU and memory across concurrent sessions, and repro watch --hcr reloads modified code into running processes."
    reason: "Benchmark harness runs and HCR user-docs scenarios are not yet wired into scenarios/."
    owner: unassigned
---

# How reprobuild works

Reprobuild combines three proven ideas into one engine: BuildXL's monitored
automatic dependency tracking, Nix's pinned toolchains in a content-addressed
store with atomic generations, and Terraform's plan-and-apply reconciliation of
live state. This page explains the single graph behind all three, then follows a
project through each stage, with a link to the page that covers each one in
depth.

## One graph, of files and of states

A classical build tool keeps a graph whose outputs are files: an object file
depends on a source file, and a program on its objects. Reprobuild keeps the
same dependency edges, and allows an action's output to be a state as well as a
file: a tool in the store, a service that is running, a user account, a file
that a profile manages, a setting applied to a machine. Before it changes a
state, reprobuild compares the state it would produce with the state that
exists, shows the plan and reconciles the difference, as Terraform does.

Every stage below is made of actions in that graph, so they share one set of
rules. What an action read is recorded automatically, not assumed, and an action
whose inputs have not changed is skipped at speeds competitive with Ninja.
Across concurrent builds on one host, RunQuota coordinates CPU and memory leases
(`repro pressure`) so parallel developer and AI-agent sessions do not exhaust
RAM. Those rules hold whether the action compiles a file, reloads code into a
running process (`repro watch --hcr`), starts a database or edits `~/.bashrc`:

- `repro build` reuses an action whose fingerprint matches the recorded one.
- `repro up`, run in several projects that declare one shared service, starts one instance of it and leaves it running for the others.
- `repro home apply` changes nothing when your account already matches your profile.
- `repro infra plan` shows what applying a system profile would change, and `repro infra apply` leaves an action's result alone when the result is already in place.
- `repro deploy-agent`, run on each machine of a fleet, applies the signed state published for that machine, through the same actions.

## 1. A project file describes the project

A project is described by its project file, `repro.nim`. It names the project's
packages, the tools and libraries each package uses, its tests, its development
environment, its tasks and its services. It is Nim code, so a misspelt option or
a wrong type is a compile error in the project file rather than a surprise during
the build.

A project file can be short because most of what a build needs is implied by the
language's standard layout. Depending on how much a project already says about
itself, reprobuild reads it in one of three modes: from its directory layout
alone, through its ecosystem's own manifest (`Cargo.toml`, `CMakeLists.txt`,
`package.json`), or from a short project file.
[Conventions and the three modes](conventions-and-modes.md) explains the choice.

## 2. Conventions turn packages into actions

reprobuild derives the build graph from the packages: one action per compiler
invocation, archive, link or generated file, with an edge wherever one action
uses another's output. `repro graph` prints the graph, and
`repro show-conventions` prints what a convention inferred.

## 3. Dependencies resolve to exact versions

Each package names the tools and libraries it uses with version ranges, such as
`"nim >=2.2 <3.0"`, and a catalog defines how to obtain each version of each
package. A solver chooses one version of every dependency that satisfies every
range, and the lock file, `repro.lock`, records the choice, so a build on another
machine uses the same versions. `repro lock update` moves a dependency on
purpose.

Tool provisioning obtains each chosen version: from your `PATH`, from Nix, from a
release tarball, from Scoop, or by building it from source. What reprobuild
builds or obtains goes into its store, under a name derived from its contents.
[Dependencies and the store](dependencies-and-the-store.md) explains each step.

## 4. Each action runs under a monitor

When an action runs, reprobuild records what its processes read, wrote, looked
for and listed. This record, the action's dependency evidence, catches the inputs
nobody declared: a header found on an include path, a configuration file read
from the home directory, a file that appeared in a directory the action listed.

## 5. A fingerprint decides whether to run an action again

An action's fingerprint covers its command, the tools it ran and the contents of
everything its evidence shows it depended on. Before running an action, reprobuild
compares its fingerprint with the recorded one; when they match, it reuses the
recorded outputs. When an action's evidence is incomplete, reprobuild records no
result for it, so it runs again next time instead of being reused on a guess.
[How caching stays correct](how-caching-stays-correct.md) explains the rules and
their limits.

A result does not have to come from your own machine. `repro cache publish` puts
a result in a binary cache, and `repro cache substitute` fetches it elsewhere
instead of building it again. The release archive includes `repro-binary-cache`,
a cache server you can run yourself.

## 6. Tests run in the same graph

A test is an action too, so `repro test` runs it under the same rules as the
build. `repro test --shard 2/4` runs one of four parts of the suite, so four
machines can share it with every test run exactly once. A passing run on a clean
working tree issues a test certificate, which records which content passed which
tests on which platform and travels with the commit when you push it.
[Tests and certificates](tests-and-certificates.md) explains both.

## 7. Resources are declared, reconciled and leased

A resource is a state the graph creates and keeps, such as a container or a
database. Any repository can define a resource type, which plays the part of a
Terraform provider, and a project file declares resources of it with
`dependsOn` between them. reprobuild reconciles them in dependency order and
records each one's state on disk. A test can consume a named group of resources
under a lease, and a reaper destroys the state once no lease holds it.
[Resources and state](resources-and-state.md) explains the model.

## 8. The same file describes how you work on the project

The project file also declares the project's development environment (the tools
and variables you work with), its named tasks and its services, such as a
database. `repro shell` and `repro exec` enter the environment, `repro run` runs a
task and `repro up` starts the services. Because they come from the same file as
the build, the tools in your shell are the tools the build uses.
[Enter a project's environment](../guides/environments/enter-a-project-environment.md)
shows how.

## 9. Workspaces put repositories side by side

A workspace holds several repositories next to each other, with a workspace root
that declares which belong together. Develop mode builds a dependency from its
checkout in the workspace instead of from its locked revision, so a change in a
library reaches the program that uses it at the next build, without publishing
the library first. `repro develop --all` checks out every dependency in the lock
that no project file pins to an exact revision, at its locked revision, and
switches the build to those checkouts; `repro develop --only=<dependency>` does
the same for one. The source of a library your program uses is then one command
away. Each repository commits its own lock file, which records the revisions it
was built against.
[Work on a dependency's source](../guides/workspaces/develop-a-dependency.md)
shows the workflow.

## 10. Profiles configure your account and the operating system

A home profile describes the tools and configuration files on your own account.
A system profile describes the operating system: its services, users and groups,
files, kernel settings and firewall rules, or on Windows its registry values,
services and features. `repro infra plan` shows what an apply would change,
including anything that drifted since the last apply; `repro infra apply` makes
the machine match, in dependency order, and removes what you no longer declare.
`repro home apply` does the same for your account, with tools resolved the same
way as a project's dependencies. Each change is recorded as a generation, and
`repro system rollback` and `repro home rollback` return to an earlier one.
Together with the package catalogs and hot code reloading, these system and home
profiles form ReproOS: either as a complete operating system or layered onto an
existing Linux distribution in add-on mode (`repro anywhere`), giving developers
and AI agents one typed, roll-backable graph for every layer of a live machine.
[Machines and profiles](machines-and-profiles.md) explains how.

## 11. A fleet converges on signed state

Every machine in a fleet runs `repro deploy-agent` on a timer. Each run fetches
the manifest published for that machine, checks its signature against the keys
the machine trusts, and applies the system profile it carries with the same
steps as `repro infra apply`. A manifest from an untrusted key or for another
machine changes nothing, and an older one never replaces a newer one.
[Fleets and the deploy agent](fleets-and-the-deploy-agent.md) explains the model.

## Related

- [Glossary](../reference/glossary.md)
- [Coming from another tool](../coming-from/index.md)
