---
title: Glossary
description: The one name reprobuild's documentation uses for each concept, with the synonyms it avoids.
kind: reference
persona: developer
order: 90
verifies:
  commands: [build, graph, show-conventions, shell, exec, shell hook, allow, deny, dev-env export, up, down, run, tasks, develop, workspace, home, system, store gc, daemon, test, certify]
  tests:
    - tests/integration/t_dev_env_allow.nim
    - tests/integration/t_integration_local_store_gc.nim
unverified:
  - claim: "The project-file names `repro.nim` and `reprobuild.nim` are both read."
    reason: "Read from the loader constants (LegacyProjectFileName); no test is cited yet."
    owner: unassigned
  - claim: "Without `--activity`, the activity is `default`."
    reason: "Read from the dev-env export argument parser; no test is cited yet."
    owner: unassigned
draft: true
---

# Glossary

This page defines the one name the documentation uses for each reprobuild
concept. The style check reads it: every **Do not use** entry is rejected in
user pages, except inside code.

## Action

One unit of work in the [build graph](#build-graph): a command with its inputs
and outputs, such as one compiler invocation. reprobuild runs an action, or
reuses its recorded result when nothing that affects it has changed.

**Do not use:** node, step, job (for an action). Use "edge" only for the link
between two actions.

## Action cache

The record of every action's [fingerprint](#fingerprint) and outputs, which
lets reprobuild skip an action whose inputs are unchanged. The `--action-cache-root`
option of `repro build` moves it.

**Do not use:** build cache (for this record).

## Activity

A named grouping of tools, services and settings that a
[development environment](#development-environment), [home profile](#home-profile)
or [system profile](#system-profile) can switch on. Commands select one with
`--activity=NAME`; without the option, the activity is `default`.

**Do not use:** role, feature, profile (for an activity).

## Branch role

A named purpose for a branch, which each repository in a [workspace](#workspace)
maps to its own branch name. The built-in roles are `mainline`, `unstable`,
`staging`, `stable`, `production` and `lts`; a workspace can add its own. A role
that a repository does not declare falls back towards its mainline.

**Do not use:** branch alias, branch class.

## Build graph

The graph of [actions](#action) reprobuild derives from a [project](#project),
with an edge wherever one action uses another's output. `repro graph` prints it.

**Do not use:** action graph, DAG (in prose).

## Convention

The rules reprobuild applies to a language's standard layout to derive actions
without being told about each file: where the sources are, which directories are
libraries, which files are tests. `repro show-conventions` prints what a
convention inferred for a project.

**Do not use:** standard provider (in user pages), rule set.

## Daemon

The background process, one per user, that runs builds and keeps their state
loaded between commands. `repro daemon status` reports on it.

**Do not use:** server, service (for the daemon).

## Dependency evidence

The record of what an [action](#action) read, wrote and looked for while it ran,
captured by monitoring its processes. reprobuild uses it to decide when the
action has to run again, so an input you did not declare still counts.

**Do not use:** observations, monitor data, traces (for dependency evidence).

## Develop mode

The state in which a [workspace](#workspace) builds a dependency from a local
checkout instead of from its locked revision. `repro develop` starts it for a
dependency and `repro develop --drop` ends it.

**Do not use:** dev mode, link mode, override mode.

## Development environment

The tools, environment variables and [services](#service) a project declares for
working on it. `repro shell` starts a shell inside it, `repro exec` runs one
command inside it, and the [shell hook](#shell-hook) activates it when you enter
the project's directory.

**Do not use:** dev shell, devEnv (outside code), sandbox.

## Fingerprint

A hash over everything that can change an [action](#action)'s result: its
command, the contents of its inputs and the tools it runs. reprobuild treats two
runs with the same fingerprint as interchangeable and reuses the earlier result.

**Do not use:** cache key, checksum (for a fingerprint).

## Generation

One applied state of a [home profile](#home-profile) or
[system profile](#system-profile). Applying a changed profile creates a new
generation; `repro home rollback` and `repro system rollback` return to an
earlier one.

**Do not use:** snapshot, version, revision (for a generation).

## Hermetic

An action is hermetic when everything it reads is accounted for in its
[fingerprint](#fingerprint). reprobuild checks this from the action's
[dependency evidence](#dependency-evidence) instead of trusting its declared
inputs.

**Do not use:** sandboxed, isolated (for hermetic). An action is hermetic because
of what its evidence shows, not because of how it is confined.

## Home profile

A description of the tools, files and services on your own account, written in
`home.nim` and applied with `repro home apply`.

**Do not use:** dotfiles config, home config, home manifest.

## Lock file

The file `repro.lock`, which a repository commits to pin the exact revisions and
versions it was built with.

**Do not use:** lockfile (one word), pin file.

## Mainline

The [branch role](#branch-role) of the branch where completed work lands in a
repository. Each repository declares which of its branches that is.

**Do not use:** main branch, trunk, default branch (for the mainline).

## Mode 1

Building from the directory layout alone, with no [project file](#project-file).
reprobuild recognises layouts such as `apps/<name>/` and `libs/<name>/`.

**Do not use:** zero-config mode, layout mode, Tier 1.

## Mode 2

Building a project through its ecosystem's own manifest, such as `Cargo.toml`,
`package.json` or `CMakeLists.txt`, with a short [project file](#project-file)
that names the package and the tools it uses.

**Do not use:** delegate mode, Tier 2.

## Mode 3

Building from a short [project file](#project-file) that lists packages and the
dependencies between them, with the [conventions](#convention) supplying the
rest.

**Do not use:** curated mode, Tier 3.

## Package

A named unit in a [project file](#project-file): a `package` block holding
executables, libraries, files or [services](#service).

**Do not use:** module, component, crate (for a reprobuild package).

## Project

A directory that reprobuild can build: one with a [project file](#project-file),
or one whose layout it recognises ([Mode 1](#mode-1)). Commands that act on a
project take `--project-root`. In a [workspace](#workspace), a named set of
repositories is a [workspace project](#workspace-project), never a "project".

**Do not use:** codebase, repo (for a project).

## Project file

The file `repro.nim`, which describes a [project](#project) to reprobuild. It is
Nim code, so the compiler checks it and your editor can navigate it. reprobuild
also reads the older name `reprobuild.nim`.

**Do not use:** project DSL, DSL file, build file, recipe (for a project file).

## Reproducible

An output is reproducible when building the same inputs again produces the same
bytes. The documentation uses the word in no weaker sense.

**Do not use:** consistent, deterministic-ish (for reproducible).

## Repository fragment

A file under a workspace's `repos/` directory that declares one repository: its
name, its checkout path, its remote and its [branch roles](#branch-role).

**Do not use:** repo manifest, repo entry.

## Service

A long-running process that a project declares, such as a database. `repro up`
starts a project's services and `repro down` stops them.

**Do not use:** daemon (for a project's service), container.

## Shell hook

A snippet printed by `repro shell hook <shell>` that you load from your shell's
start-up file. It activates a project's
[development environment](#development-environment) when you enter the project's
directory and deactivates it when you leave.

**Do not use:** direnv hook, prompt hook.

## Sibling checkout

A repository cloned next to the others in a [workspace](#workspace) directory, so
that each one can build against the others' working trees.

**Do not use:** submodule, nested checkout.

## Store

The directory in which reprobuild keeps tools, libraries and build outputs, each
under a name derived from its contents. `repro store gc` removes the entries that
nothing refers to.

**Do not use:** cache directory, Nix store (for reprobuild's store).

## System profile

The machine-wide counterpart of a [home profile](#home-profile), managed with
`repro system`.

**Do not use:** machine config, host profile.

## Target

What `repro build` builds when you name it: a package, an executable or library
inside one, or a named collection of them. `repro build --list-targets` lists a
project's targets.

**Do not use:** goal, rule, build target (prefer "target").

## Task

A named command that a project declares, which `repro run <task>` runs inside the
project's [development environment](#development-environment). `repro tasks`
lists them.

**Do not use:** recipe, script, job (for a task).

## Test certificate

A signed record that named tests passed on one platform against one exact content
of a repository. `repro test` and `repro certify` produce them, and commit and
push checks can require them.

**Do not use:** test receipt, test proof.

## Tool provisioning

How reprobuild obtains the tools a project uses: from `PATH`, from Nix, from a
release tarball, from Scoop, or by building them from source. The
`--tool-provisioning` option chooses among them.

**Do not use:** toolchain resolution, adapter (in prose).

## Trust

Your permission for reprobuild to activate a directory's
[development environment](#development-environment) automatically. `repro allow`
grants it for a directory and `repro deny` withdraws it. Trust is recorded
against the directory's path, not against its contents.

**Do not use:** allow-list, approval, whitelist.

## Workspace

A directory that holds several repositories side by side as
[sibling checkouts](#sibling-checkout), together with a
[workspace root](#workspace-root) that declares which repositories belong
together.

**Do not use:** monorepo, superproject, checkout set.

## Workspace project

A named set of repositories in a [workspace](#workspace), declared in
`projects/<name>.toml` of the [workspace root](#workspace-root).
`repro workspace enable <project>` checks its repositories out.

**Do not use:** "project" on its own, product, group.

## Workspace root

The repository at the top of a [workspace](#workspace) that holds its manifests:
`repro-workspace.toml`, `projects/` and `repos/`.

**Do not use:** manifest repo, umbrella repo.
