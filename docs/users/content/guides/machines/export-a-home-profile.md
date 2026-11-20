---
title: Export a home profile for Nix
description: Write what a home profile selects for each host to a JSON file that Nix and other tools read, keep the committed copy current, and evaluate it for another platform.
kind: how-to
persona: machine-owner
domain: machines
order: 30
platforms: [linux]
verifies:
  commands: [home export, home export --check, home export --target, home plan]
  tests:
    - tests/e2e/m83/t_e2e_home_export_matches_compiled_intent.nim
    - tests/e2e/m83/t_e2e_home_export_check_detects_stale_snapshot.nim
    - tests/e2e/m83/t_e2e_home_export_expands_data_files.nim
unverified:
  - claim: "The captured output on this page."
    reason: "Run by hand on Linux with repro 0.2.24 built from reprobuild 84b459adda, against reprobuild-examples nix/home-manager-profile; no scenario re-runs it."
    owner: unassigned
  - claim: "--check never fails on a provenance change alone, such as a newer repro or an edited comment."
    reason: "An edited profile was observed to print the digest change as a note; a repro upgrade was not tried. t_e2e_home_export_check_detects_stale_snapshot.nim covers the stale case."
    owner: unassigned
  - claim: "--target refuses with exit 3 when a compile-time when defined(...) makes the profile differ on the target."
    reason: "Read from the command's contract; the example profile uses runtime predicates only, so the refusal was not produced."
    owner: unassigned
---

# Export a home profile for Nix

This page shows how to write what your
[home profile](../../reference/glossary.md#home-profile) selects to a file
that Nix reads, so a Nix configuration takes facts from the profile instead
of repeating them.

## Before you start

- A home profile, `home.nim`. The steps use the one in `reprobuild-examples/nix/home-manager-profile` ([Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md) shows it).
- `repro` on your `PATH` ([Install reprobuild](../../install.md)).

## Steps

### 1. Export it

From the profile's directory:

```bash
repro home export --profile-dir . --host laptop > home-export.json
```

The command compiles the profile as `repro home plan` does and stops there:
it plans nothing and applies nothing. The file holds the whole profile, every
host's activities included, and the selection of the host you name.

Without `--profile-dir`, the command reads your profile directory
([Machines and profiles](../../concepts/machines-and-profiles.md) says
where it is). The host is `REPRO_HOST` when that is set, else `--host`, else
the machine's host name; a `--host` that differs from `REPRO_HOST` is refused,
so a document is never written for the wrong machine.

:::important
When the profile has a `hosts:` block, a host it does not name is refused:

<!-- generated:begin capture export-a-home-profile undeclared-host -->
```text
repro home export: error: host `nowhere` is not declared in the profile's hosts: registry (declared: laptop, mac, server). Add an entry for it -- `"nowhere": [default]` selects only the `default` activity, `repro home enable <activity> --host nowhere --no-apply` adds one -- or select a declared host with --host / $REPRO_HOST
```
<!-- generated:end -->
:::

:::important
A profile whose `hosts:` entries declare `applies:` needs a checkout of the
[reprobuild-packages](https://github.com/metacraft-labs/reprobuild-packages)
catalog to tell applications from other packages. Point
`REPROBUILD_PACKAGES_ROOT` at it; without it, the export is refused and says
so.
:::

### 2. Commit it next to the profile

Commit `home-export.json`. A Nix evaluation reads the committed file and
never runs `repro`, so it works under restricted evaluation and on machines
without reprobuild.

### 3. Check that the committed copy is current

Run this wherever the profile changes, for example in CI:

```bash
repro home export --profile-dir . --host laptop --check home-export.json
```

It exits 0 when the file says what the profile says. After a package is added
to the profile, it exits 1 and names the difference and the command that
regenerates the file:

<!-- generated:begin capture export-a-home-profile check-stale -->
```text
repro home export --check: note (not compared): provenance.profile.digest: snapshot "947a5c8ff651934a73954c28d0bdbaf2f15fcda7f90f89d5332d17e4c79fda52", now "848fea6579f2edb8a53671d94c36939c09907ecbc49a469443bc8f0dfb1575cf"
repro home export --check: home-export.json is stale for host laptop (1 difference(s)):
  intent.activities[name="develop"].body[1]: only in a fresh export: {"kind":"packageRef","name":"bat","version":""}
  hint: regenerate it with `repro home export --format json --host laptop > home-export.json`
```
<!-- generated:end -->

The check compares what a reader of the file uses, and only notes the
provenance: which `repro` wrote it and the digest of the profile's files.

### 4. Evaluate it for another platform

To see what a host gets on another platform, pass `--target`:

```bash
repro home export --profile-dir . --host mac --target aarch64-darwin
```

The output then also holds an `evaluation`: the activities, packages,
resources and configuration the planner would use for that host on that
platform. For `mac` in the example, it selects the activities `default` and
`desktop`, and the packages `jq` and `vscode`.

A profile describes every platform from one export when it chooses platforms
with runtime predicates, such as `when linux():` or `when macos():`. A
compile-time `when defined(macosx):` is decided by the machine that compiles
the profile, so the export records, per platform, whether it describes it, and
`--target` refuses a platform it does not describe.

## Check that it worked

`--check` exits 0:

<!-- generated:begin capture export-a-home-profile check-current -->
```text
repro home export --check: home-export.json matches a fresh export for host laptop
```
<!-- generated:end -->

## Related

- [Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md)
- [Compare a Home Manager configuration with a profile](compare-with-home-manager.md)
- [Machines and profiles](../../concepts/machines-and-profiles.md)
- [Home profile export](../../reference/files/home-export.md): every field of the document
