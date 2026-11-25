---
title: Diagnose your setup with repro health
description: Run reprobuild's environment check, read each failure and its remedy, apply the safe fixes automatically, and use the check in CI.
kind: how-to
persona: developer
domain: troubleshooting
order: 10
platforms: [linux, macos, windows]
verifies:
  commands: [health]
  tests:
    - tests/integration/t_health_reports_each_layer_status_with_remedy.nim
    - tests/integration/t_health_fix_remediates_safe_issues_only.nim
    - tests/integration/t_health_fix_announces_its_plan_before_acting.nim
    - tests/integration/t_health_reports_a_refusing_hook_as_not_ok.nim
unverified:
  - claim: "repro health exits 1 when any check fails."
    reason: "Read from the command's documentation comment; the cited tests are not confirmed to assert the exit status."
    owner: unassigned
---

# Diagnose your setup with repro health

This page shows how to find out why reprobuild is not working as you expect on
your machine, and how to fix what it finds.

## Before you start

- [Install reprobuild](../../install.md).

## Steps

### 1. Run the check

Run the check from inside your project or workspace:

```bash
repro health
```

Each line names one check and its result. Every failed check names the
command that fixes it.

### 2. Apply the remedies

Run the remedy each failure names, then run `repro health` again.

### 3. Apply the safe fixes in one step

To apply the fixes that cannot lose work in one step, run:

```bash
repro health --fix
```

`--fix` applies only the safe remedies. A failure whose remedy could discard
work stays failed, with its remedy printed, for you to decide.

`--fix` applies every safe remedy at once; you cannot pick one check. One of
them clones each repository of the workspace that is missing on disk, which
can be many. After it has migrated the workspace state file (when there is
one to migrate), and before any other change, `--fix` prints a plan: a
`fix: plan:` header, then one `fix: plan:` line per check it will act on,
with the number of repositories it will clone. It then prints each step as
the step starts, and it does not wait after the plan. With `--json`, neither
the plan nor the steps are printed; stdout carries only the final report.

## Use it in CI

`repro health` exits with status 1 when any check fails, so a CI step can stop
on an unhealthy environment:

```bash
repro health --json
```

`--json` prints the same results as JSON for a script or an agent to read.
`--offline` skips the checks that need the network.

## The checks

<!-- generated:begin cli-reference health checks -->
| Check | What it inspects | Safe `--fix` |
|---|---|---|
| `binary-cache-producer-key` | Checks whether an unused auto-generated binary-cache producer keypair sits on disk without publisher configuration. | No |
| `install-version` | Reports the running `repro` version and executable path. | No |
| `daemon-mode` | Reports whether the per-user store daemon is running or `repro` is operating in single-user direct mode. | Yes (starts user daemon) |
| `lease-reaper` | Checks whether the daemon's wall-clock lease reaper is completing sweeps over leased ephemeral state. | No |
| `store` | Verifies that the content-addressed store root exists and its SQLite index opens cleanly. | No |
| `direnv` | Checks whether `direnv` is installed and any workspace `.envrc` is trusted. | Yes (`direnv allow`) |
| `workspace` | Verifies that an initialised workspace marker exists at the workspace root. | No |
| `manifest` | Resolves the active workspace project set and checks its manifests. | Yes (migrates retired state file) |
| `root-role-manifests` | Checks that every declared branch role of the workspace root loads its manifests cleanly. | No |
| `siblings` | Checks that every repository declared in the active workspace project set is cloned on disk. | Yes (clones missing checkouts) |
| `vcs-host-auth` | Confirms that a usable `git` binary is resolvable for workspace operations. | No |
| `repository-identities` | Compares declared repository URLs against canonical forge identities to spot renames or redirects. | No |
| `vcs-hooks` | Verifies that managed Git hooks are installed, unshadowed, worktree-safe and contract-compatible across participating repositories. | Yes (missing, shadowed, path-unsafe) |
| `chained-hooks` | Checks that any chained `<hook>.repro-local` scripts name interpreters and executables that exist. | No |
| `hook-configs` | Finds generated pre-commit or prek hooks, in a hook slot or chained behind a managed hook, whose configuration file is gone, so the hook refuses every fire. | No |
| `hook-interpreter` | Verifies that shells on this host resolve the same `repro` binary that wrote the managed Git hooks. | No |
| `certificate-propagation` | Reports certificate store roots, linked library version, `pre-push` carrier status and policy configuration. | No |
| `lock-writer` | Reads the `post-commit` lock-writer trace to surface silent lock-refresh refusals. | No |
| `push-gateway` | Compares participating repositories' push remotes against their enacted test-certificate gate policy. | No |
| `sibling-exact-pins` | Lists informational exact commit pins of workspace siblings across participating project files. | No |
| `toolchain` | Confirms that the platform Git toolchain required by workspace operations is provisioned. | No |
| `certificate-policy` | Reads each participating repository's `repro.lock` certificate policy and validates its branch rules. | No |
| `workspace-ergonomics` | Checks that `workspace-projects.md` exists, is ignored in `.gitignore` and is referenced in `AGENTS.md`. | Yes |
| `workspace-state-file` | Checks `.repro/workspace-state.toml` for retired filenames or misplaced manifest layers. | Yes (when unskewed) |
| `local-settings-file` | Reports when per-user `repro-workspace.local.toml` is accidentally tracked by Git. | No |
| `unpublished-heads` | Warns when participating checkouts sit at local commits that exist on no remote. | No |
| `disjoint-local-branches` | Warns about unpublished local branches that share no merge-base with the repository's mainline. | No |
| `shared-clone-leaves` | Inspects checkouts borrowing from shared bare clones for missing pools, broken refetch chains or stale remote refs. | Yes (pools, chains, stale remote refs) |
| `shared-clone-pack-temporaries` | Finds git pack temporaries that an interrupted repack or fetch abandoned in the host's shared clone pools, which git can never read. | Yes (removes them) |
| `certificate-policy-snapshot` | Warns when a repository's recorded certificate-policy snapshot in `repro.lock` is behind its project file. | No |
<!-- generated:end -->

## Related

- [Join a workspace](../workspaces/join-a-workspace.md)
- [Install reprobuild](../../install.md)
