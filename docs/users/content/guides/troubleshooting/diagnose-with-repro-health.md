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
<!-- generated:end -->

## Related

- [Join a workspace](../workspaces/join-a-workspace.md)
- [Install reprobuild](../../install.md)
