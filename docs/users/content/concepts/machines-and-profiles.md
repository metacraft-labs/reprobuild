---
title: Machines and profiles
description: How a profile describes your account or a whole operating system, how repro infra plans and applies it as Terraform does, and how each change becomes a generation you can roll back.
kind: explanation
persona: machine-owner
order: 40
verifies:
  commands: [home add, home remove, home apply, home plan, home history, home rollback, system, system rollback, infra plan, infra apply, infra apply --plan, infra apply --no-preview, infra apply --no-elevate, infra apply --accept-drift, infra apply --accept-passwd-destroy]
  tests:
    - tests/e2e/home-apply/t_e2e_repro_home_add_remove_immediate.nim
    - tests/e2e/home-apply/t_e2e_repro_home_apply_noop.nim
    - tests/e2e/home-apply/t_e2e_stow_auto_discovery_and_materialization.nim
    - tests/e2e/gm4b/t_e2e_home_profile_resolves_like_uses.nim
    - tests/e2e/gm4b/t_e2e_home_apply_realizes_nix_selection.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_round_trip.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_user_edit_protection.nim
    - tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim
    - tests/e2e/m69/t_e2e_repro_infra_systemd_system_timer_vm.nim
    - tests/e2e/m69/t_e2e_repro_infra_passwd_group_vm.nim
    - tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim
    - tests/e2e/m69/t_e2e_repro_infra_linux_sysctl_vm.nim
    - tests/e2e/m69/t_e2e_repro_infra_linux_firewallrule_vm.nim
    - tests/e2e/m69/t_e2e_repro_infra_os_hostname_posix_vm.nim
    - tests/e2e/m69/t_e2e_repro_infra_os_timezone_posix_vm.nim
    - tests/e2e/m69/t_e2e_windows_registry_system_scope.nim
    - tests/e2e/m69/t_e2e_windows_optional_feature_and_capability.nim
    - tests/e2e/m69/t_e2e_repro_infra_plan_apply_convergent.nim
    - tests/e2e/m69/t_e2e_repro_infra_depends_on_topological.nim
    - tests/e2e/m69/t_e2e_repro_infra_plan_time_external_drift.nim
    - tests/e2e/home-resources/t_integration_prevent_destroy.nim
    - tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim
    - tests/e2e/m69/t_e2e_repro_system_command_family.nim
    - tests/integration/t_infra_apply_cache_hit_preserves_present_outputs.nim
    - libs/repro_deploy_agent/tests/t_repro_deploy_agent_converges_from_signed_manifest.nim
    - tests/e2e/gm10/t_e2e_infra_apply_refuses_externally_managed_host.nim
unverified:
  - claim: "The profile directory is $XDG_CONFIG_HOME/repro/home, or ~/.config/repro/home, unless --profile-dir or REPRO_HOME_PROFILE_DIR names another."
    reason: "Read from the profile directory resolver; no test checks the default location."
    owner: unassigned
  - claim: "repro home plan shows what an apply would change without applying it."
    reason: "Read from the command's description; no test is cited."
    owner: unassigned
  - claim: "The resource kinds this page lists for a system profile."
    reason: "Each named kind has an apply test, but several run only in a disposable VM, and the list is written by hand rather than generated from the profile parser."
    owner: unassigned
---

# Machines and profiles

This page explains how a profile describes your own account or a whole
operating system, how reprobuild plans and applies it, and how you undo a
change.

## A profile describes an account or a machine

A home profile describes your own account: the tools you want on your `PATH`,
the configuration files you keep, and the lines a tool needs in a file such as
`~/.bashrc`. It is a file named `home.nim` in your profile directory, which is
`~/.config/repro/home` unless `--profile-dir` or `REPRO_HOME_PROFILE_DIR` names
another. It is Nim code, like a project file.

A system profile, `system.nim`, describes the operating system of a machine as
a whole. `repro infra` plans and applies it, and `repro system` manages its
history.

## What a system profile declares

A system profile lists resources, each the desired state of one part of the
operating system:

- On Linux: systemd service units and timers, users and groups, files under the system's directories, kernel parameters set through sysctl, firewall rules, the host name and the time zone.
- On Windows: registry values, services, optional features and capabilities.

A resource can name others with `depends_on`, and reprobuild applies them in
that order. Some orders it knows without being told, such as installing a
Windows capability before the service that comes with it. A cycle is refused
when the plan is made, and the refusal names the resources in it.

## Plan, then apply

reprobuild handles a system profile the way Terraform handles its
configuration. `repro infra plan` compares the profile with the machine and
prints the changes an apply would make, with an id for the plan.
`repro infra apply --plan <id>` makes exactly those changes, and refuses the plan
when the machine has changed since it was made. `repro infra apply --no-preview`
applies the current profile without a separate plan step. After an apply, a new
plan is empty: applying converges.

The plan also reports drift: anything changed on the machine outside reprobuild
since the last apply, with the recorded, observed and desired content of each
resource. Drift that differs from the profile is actionable, and the apply
replaces it with the profile's state, so read the report before you apply.
`--accept-drift` records in the apply's audit log that you acknowledged it.
Drift that already matches the profile is informational, and the apply leaves
it as it is.

A resource you remove from the profile is removed from the machine by the next
apply. Some removals need your consent: deleting a user account takes
`--accept-passwd-destroy`, and rolling back afterwards re-creates the account
with the attributes it had. A resource in a home profile marked
`lifecyclePolicy = preventDestroy` is never removed, whatever flags you pass.

On Windows, an apply that needs administrator rights asks for them once for the
whole apply. With `--no-elevate`, it applies only the changes that need no
elevation and lists the rest as skipped.

## Applying a home profile

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
produced. `repro home history` lists your account's generations and
`repro system history` the machine's. `repro home rollback` and
`repro system rollback` return to the previous generation, and given an id, to
the one you name, forwards as well as backwards.

A rollback does not overwrite your own edits. When a file the profile manages
differs from what the current generation recorded, because you changed it by
hand, the rollback stops, names the file and leaves it as you edited it. Run it
again with `--accept-overwrite` to roll the file back as well.

## The same engine as a build

An apply runs through the same engine as a build. A step whose result is
already in place leaves the result alone instead of writing it again, and a step
that builds something can fetch the result from a binary cache.

A host can be declared as configured from somewhere else, such as a NixOS
configuration in another repository. `repro infra plan`, `repro infra apply` and
`repro system sync` then refuse to touch that host, name where its configuration
lives, and change nothing.

## Many machines

`repro infra` changes the machine it runs on. To keep many machines in the state
you declare, each one runs `repro deploy-agent`, which fetches a signed
manifest of that machine's system profile and applies it with the same steps.
[Fleets and the deploy agent](fleets-and-the-deploy-agent.md) explains how.

## What this does not cover

- reprobuild does not create machines or manage cloud resources, and it does not run Terraform or OpenTofu providers.

## Related

- [Fleets and the deploy agent](fleets-and-the-deploy-agent.md)
- [Coming from Terraform and OpenTofu](../coming-from/terraform-and-opentofu.md)
- [Coming from Nix](../coming-from/nix.md)
- [Glossary: Home profile](../reference/glossary.md#home-profile), [System profile](../reference/glossary.md#system-profile), [Generation](../reference/glossary.md#generation), [Drift](../reference/glossary.md#drift)
