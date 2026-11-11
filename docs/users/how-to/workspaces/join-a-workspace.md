---
title: Join a workspace
description: Clone a multi-repository workspace onto a new machine, choose which of its projects to check out, and keep every repository current.
kind: how-to
persona: developer
domain: workspaces
order: 10
platforms: [linux, macos, windows]
verifies:
  commands: [workspace init, workspace projects list, workspace enable, workspace disable, workspace status, sync, hooks ensure, health]
  tests:
    - tests/integration/t_workspace_init_clones_missing_and_reports_existing.nim
    - tests/integration/t_workspace_init_clones_org_root_repo_and_syncs_into_named_path.nim
    - tests/integration/t_workspace_init_cold_starts_a_flat_settings_root.nim
unverified:
  - claim: "Given an organisation name, init clones <organisation>/repro-workspace and checks out the repositories of the workspace's default projects."
    reason: "From the workspace command design; the cited tests cover cloning and syncing, not the default-project selection."
    owner: unassigned
  - claim: "repro ws disable refuses when a checkout carries uncommitted, unpushed or stashed work."
    reason: "From the workspace guide; no test is cited yet."
    owner: unassigned
  - claim: "The managed hooks are not installed by init, sync or enable."
    reason: "From the workspace guide; no test is cited yet."
    owner: unassigned
draft: true
---

# Join a workspace

This page shows how to bring a multi-repository workspace up on a new machine
and keep it current.

## Before you start

- [Install reprobuild](../../install.md).
- git can reach the workspace's repositories. For private repositories, sign in
  to their host first.
- You know the workspace's organisation or the URL of its workspace root.

## Steps

1. Clone the workspace into a new directory:

   ```bash
   repro workspace init <organisation-or-url> ~/work/my-workspace
   cd ~/work/my-workspace
   ```

   Given an organisation name, reprobuild clones that organisation's
   `repro-workspace` repository and checks out the repositories that the
   workspace's default projects need, side by side.

   :::tip
   `repro ws` is short for `repro workspace`.
   :::

2. See the workspace's projects, and which are checked out here:

   ```bash
   repro ws projects list
   ```

3. Check out another project's repositories:

   ```bash
   repro ws enable <project>
   ```

   To remove a project's checkouts again, run `repro ws disable <project>`. It
   removes only the checkouts no other enabled project uses, and refuses when
   one of them carries work that is not pushed.

4. Install the git hooks that keep the repositories consistent:

   ```bash
   repro hooks ensure --vcs
   ```

5. Check the result:

   ```bash
   repro health
   ```

## Keep every repository current

| To | Run |
|---|---|
| Fetch and fast-forward each repository on its current branch | `repro sync` |
| See each repository's branch, uncommitted changes and lock drift | `repro ws status` |
| Run a command in every repository | `repro ws forall -c '<command>'` |

## Check that it worked

`repro ws status` lists every repository of your enabled projects, and
`repro health` reports no failed check.

## Related

- [Work on a dependency's source](develop-a-dependency.md)
- [Coming from repo and git submodules](../../coming-from/repo-and-git-submodules.md)
- [Diagnose your setup with `repro health`](../troubleshooting/diagnose-with-repro-health.md)
