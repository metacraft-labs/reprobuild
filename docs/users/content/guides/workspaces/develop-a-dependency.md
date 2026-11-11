---
title: Work on a dependency's source
description: Check out one of your repository's dependencies next to it, build your repository against your changes to it, and return to the locked revision when you are done.
kind: how-to
persona: developer
domain: workspaces
order: 20
platforms: [linux, macos, windows]
verifies:
  commands: [develop, build]
  tests:
    - tests/integration/t_b0_develop_mode_uses_local_source.nim
    - tests/integration/t_workspace_develop_overrides_round_trip.nim
unverified:
  - claim: "repro develop --only=<dependency> checks the dependency out at its locked revision into ../<dependency> and starts develop mode for it."
    reason: "From the develop command design; no scenario runs this page, and no test is cited for --only with a single dependency."
    owner: unassigned
  - claim: "repro develop refuses a checkout that has drifted from the locked revision unless --reset is given."
    reason: "From the develop command design; no test is cited yet."
    owner: unassigned
---

# Work on a dependency's source

This page shows how to change a library your repository depends on and build
your repository against the change, without publishing the library first.

## Before you start

- Your repository is in a [workspace](../../reference/glossary.md#workspace) and commits a `repro.lock` that names the dependency.

## Steps

### 1. List the managed dependencies

List the dependencies your repository's lock file manages, with the revision and path of each:

```bash
repro develop --list
```

### 2. Preview the checkout

Preview what checking one of them out would do:

```bash
repro develop --only=<dependency> --dry-run
```

### 3. Check the dependency out

Check it out and start [develop mode](../../reference/glossary.md#develop-mode) for it:

```bash
repro develop --only=<dependency>
```

The checkout goes next to your repository, at `../<dependency>`, at the
revision your lock file names. Add `--into=<directory>` to put it somewhere
else.

### 4. Change it and build

Change the dependency's source in its checkout, then build your repository as usual:

```bash
repro build
```

The build uses your checkout of the dependency instead of the locked
revision.

### 5. End develop mode

When you have finished, end develop mode for the dependency:

```bash
repro develop --drop=<dependency>
```

:::warning
`repro develop --reset` moves a checkout that has drifted from the locked
revision back to that revision, and discards the drift. Without `--reset`,
reprobuild refuses to touch a drifted checkout.
:::

## Check that it worked

`repro develop --list-overrides` lists each dependency in develop mode and the
path it builds from. After step 5, the dependency is no longer listed.

## If a commit or push is refused over a pinned revision

A check refuses a commit or push when your repository is pinned to a different
revision of a dependency than the one you are developing. Either keep your
change and move the lock file to it:

```bash
repro lock update <dependency>
```

or, if the change was an experiment, end develop mode with
`repro develop --drop=<dependency>`. The refusal prints the exact commands for
your repositories.

## Related

- [Join a workspace](join-a-workspace.md)
- [How reprobuild works](../../concepts/how-reprobuild-works.md), stage 7
