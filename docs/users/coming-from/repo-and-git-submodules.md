---
title: Coming from repo and git submodules
description: How Google's repo manifests and git submodules map onto reprobuild workspaces, what works differently, and when repo or submodules are the better choice.
kind: explanation
persona: workspace-maintainer
order: 50
verifies:
  commands: [workspace init, workspace sync, workspace status, workspace forall, workspace branch-roles, workspace lock, sync, switch, branch, develop]
  tests:
    - tests/integration/t_workspace_init_clones_missing_and_reports_existing.nim
    - tests/integration/t_workspace_develop_overrides_round_trip.nim
unverified:
  - claim: "Each repository commits its own repro.lock; there is no workspace-wide lock file."
    reason: "From the workspace's own documentation; no test is cited yet."
    owner: unassigned
  - claim: "A role a repository does not declare falls back towards its mainline; a declared role whose branch is missing is refused."
    reason: "From the branch-roles documentation; no test is cited yet."
    owner: unassigned
draft: true
---

# Coming from repo and git submodules

This page maps Google's `repo` tool and git submodules onto reprobuild
workspaces, explains where they differ, and says when `repo` or submodules
remain the better choice.

## What carries over

- **A manifest says which repositories belong together**, where each is checked
  out and which branch it follows.
- **Repositories are checked out side by side** and stay separate git
  repositories, each with its own history and remote.
- **One command acts on all of them**: sync, status, or a command run in each.

## Concept map

| `repo` or submodules | reprobuild |
|---|---|
| manifest repository | [workspace root](../reference/glossary.md#workspace-root) |
| `<project>` entry in `default.xml` | [repository fragment](../reference/glossary.md#repository-fragment), `repos/<name>.toml` |
| manifest groups | [workspace projects](../reference/glossary.md#workspace-project), `projects/<name>.toml` |
| `repo init` | `repro workspace init` |
| `repo sync`, `git submodule update` | `repro sync`, `repro workspace pull` |
| `repo status` | `repro workspace status` |
| `repo forall -c` | `repro workspace forall -c` |
| `revision` attribute, submodule commit | [`repro.lock`](../reference/glossary.md#lock-file) in each repository |
| `repo start <branch>` | `repro switch -b <branch>` |

## What works differently

**The workspace and the build know about each other.** A repository builds
against the checkouts of its dependencies in the same workspace when they are in
[develop mode](../reference/glossary.md#develop-mode), so a change in a library
reaches its users at the next build, without a publish step.

**Each repository pins what it was built against.** Instead of one manifest
revision or a submodule commit in a parent repository, each repository commits
its own `repro.lock`. A pre-push check refreshes it and refuses a push whose
dependencies are not published.

**Branches are named by role.** A repository declares which of its branches is
its `mainline`, its `unstable` branch and others, in
[branch roles](../reference/glossary.md#branch-role). `repro sync --mainline`
moves every repository towards its own mainline, whatever each one calls it, and
`repro workspace branch-roles` prints what each role resolves to, without
fetching anything.

**A workspace can be forked.** `repro branch ../<directory>` creates a second
workspace next to the first, on a new branch, for parallel work.

## When repo or submodules remain the better choice

- **Submodules**, when a parent repository has to record the exact commit of each
  child, and readers clone it with nothing but git.
- **`repo`**, when your workflow depends on Gerrit integration such as
  `repo upload`.
- **Either**, when the repositories do not build against each other and you
  only need them checked out together.

## Next steps

- [Join a workspace](../how-to/workspaces/join-a-workspace.md)
- [Work on a dependency's source](../how-to/workspaces/develop-a-dependency.md)
- [Command equivalents](../reference/command-equivalents.md#repo-and-git-submodules)
