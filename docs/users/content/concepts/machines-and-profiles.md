---
title: Machines and profiles
description: How reprobuild sets up your own account and your machine from a profile, records each change as a generation, and rolls one back.
kind: explanation
persona: machine-owner
order: 40
verifies:
  commands: [home add, home remove, home apply, home plan, home history, home rollback, system, infra plan, infra apply]
  tests:
    - tests/e2e/home-apply/t_e2e_repro_home_add_remove_immediate.nim
    - tests/e2e/home-apply/t_e2e_repro_home_apply_noop.nim
    - tests/e2e/home-apply/t_e2e_stow_auto_discovery_and_materialization.nim
    - tests/e2e/gm4b/t_e2e_home_profile_resolves_like_uses.nim
    - tests/e2e/gm4b/t_e2e_home_apply_realizes_nix_selection.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_round_trip.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_user_edit_protection.nim
    - tests/integration/t_infra_apply_cache_hit_preserves_present_outputs.nim
    - tests/e2e/gm10/t_e2e_infra_apply_refuses_externally_managed_host.nim
unverified:
  - claim: "The profile directory is $XDG_CONFIG_HOME/repro/home, or ~/.config/repro/home, unless --profile-dir or REPRO_HOME_PROFILE_DIR names another."
    reason: "Read from the profile directory resolver; no test checks the default location."
    owner: unassigned
  - claim: "repro home plan shows what an apply would change without applying it."
    reason: "Read from the command's description; no test is cited."
    owner: unassigned
---

# Machines and profiles

This page explains how reprobuild sets up your own account and your machine
from a profile, and how it lets you undo a change.

## A profile describes an account or a machine

A home profile describes your own account: the tools you want on your `PATH`,
the configuration files you keep, and the lines a tool needs in a file such as
`~/.bashrc`. It is a file named `home.nim` in your profile directory, which is
`~/.config/repro/home` unless `--profile-dir` or `REPRO_HOME_PROFILE_DIR` names
another. It is Nim code, like a project file.

A system profile, `system.nim`, describes the machine as a whole, and
`repro system` and `repro infra` apply it.

## Applying a profile

`repro home apply` makes your account match the profile. It installs the tools
the profile names, writes the files it generates, and links each file under the
profile's `stow/` directory into your home directory, so an edit through the link
changes the file in the profile. Applying again when nothing has changed does
nothing.

`repro home add <tool>` adds a tool to the profile and applies it in one step,
and `repro home remove <tool>` takes one out the same way; with `--no-apply`,
either one changes the profile only. `repro home plan` shows what an apply would
change without applying it.

A tool in a profile resolves the way a project's dependency does, from the same
catalog and through the same tool provisioning, so a profile can take its tools
from Nix as a project can.
[Dependencies and the store](dependencies-and-the-store.md) explains both.

## Every apply is a generation

Each apply that changes something records a generation: the complete state it
produced. `repro home history` lists your generations. `repro home rollback`
returns to the previous one, and `repro home rollback <id>` to the one you name,
forwards as well as backwards.

A rollback does not overwrite your own edits. When a file the profile manages
differs from what the current generation recorded, because you changed it by
hand, the rollback stops, names the file and leaves it as you edited it. Run it
again with `--accept-overwrite` to roll the file back as well.

## The machine as a whole

`repro infra plan` shows what applying the system profile would change on this
machine, and `repro infra apply` applies it. Its steps run through the same
engine as a build, so a step whose result is already in place leaves the result
alone instead of writing it again.

A host can be declared as configured from somewhere else, such as a NixOS
configuration in another repository. `repro infra plan`, `repro infra apply` and
`repro system sync` then refuse to touch that host, name where its configuration
lives, and change nothing.

## What this does not cover

- `repro infra` manages resources on the machine that runs `repro`. It does not provision remote machines or cloud accounts.

## Related

- [How reprobuild works](how-reprobuild-works.md)
- [Coming from Nix](../coming-from/nix.md)
- [Coming from Terraform and OpenTofu](../coming-from/terraform-and-opentofu.md)
- [Glossary: Home profile](../reference/glossary.md#home-profile), [System profile](../reference/glossary.md#system-profile), [Generation](../reference/glossary.md#generation)
