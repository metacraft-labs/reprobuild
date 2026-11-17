---
title: Coming from Home Manager and NixOS
description: How Home Manager and NixOS configurations map onto reprobuild's home and system profiles, how to keep Home Manager and move one concern at a time, and when Home Manager or NixOS is the better choice.
kind: explanation
persona: machine-owner
order: 80
verifies:
  commands: [home export, home facts, home compare, home plan, home apply, home history, home rollback, infra plan, infra apply]
  tests:
    - nix/tests/home-manager.nix
    - nix/tests/home-equivalence.nix
    - tests/e2e/m83/t_e2e_home_export_matches_compiled_intent.nim
    - tests/e2e/m83/t_e2e_compare_reports_each_category.nim
    - tests/e2e/gm4b/t_e2e_home_apply_realizes_nix_selection.nim
    - tests/e2e/home-rollback/t_e2e_repro_home_rollback_round_trip.nim
    - tests/e2e/gm7/t_e2e_home_apply_applies_declared_concerns.nim
    - tests/e2e/gm7/t_e2e_hosts_applies_declaration_cli.nim
unverified:
  - claim: "Home Manager refuses to replace a file whose content differs from its own, so files reprobuild placed block handing the files concern back."
    reason: "t_e2e_home_apply_applies_declared_concerns.nim covers that narrowing leaves placed files in place; Home Manager's refusal was not run."
    owner: unassigned
  - claim: "A host can be declared as configured elsewhere, and repro infra then refuses to change it."
    reason: "Stated by Machines and profiles; not run for this page."
    owner: unassigned
---

# Coming from Home Manager and NixOS

This page maps what you know from Home Manager and NixOS onto reprobuild's
profiles, describes a way to move over without a cut-over day, and says when
Home Manager or NixOS remains the better tool.

## What carries over

- Your account and your machines are declared in files you keep in git, and applied from them.
- Each apply records a generation, and you can roll back to an earlier one.
- Packages come from a pinned source. Through reprobuild's Nix catalog, they can still come from nixpkgs.
- One configuration can describe several hosts and differ per host.

## Concept map

| Home Manager or NixOS | reprobuild |
|---|---|
| a Home Manager configuration | [home profile](../reference/glossary.md#home-profile), `home.nim` |
| a NixOS configuration | [system profile](../reference/glossary.md#system-profile), `system.nim` |
| per-host modules, `machines/<host>/` | the `hosts:` block, which names each host's [activities](../reference/glossary.md#activity) |
| `home.packages` | packages listed in an activity |
| `home.file`, `xdg.configFile` | stow directories and file [resources](../reference/glossary.md#resource) |
| `home.sessionVariables`, `home.sessionPath` | environment [resources](../reference/glossary.md#resource) |
| `systemd.user.services`, `launchd.agents` | user service [resources](../reference/glossary.md#resource) |
| `home-manager switch`, `nixos-rebuild switch` | `repro home apply`, `repro infra apply` |
| generations | [generations](../reference/glossary.md#generation) |

Command equivalents are in the
[generated table](../reference/command-equivalents.md#home-manager).

## Before and after

Home Manager lists the packages of each host in Nix:

```nix
home.packages = with pkgs; [ jq fd htop ];
```

A home profile groups them into activities and says which host runs which:

```nim title="home.nim"
import repro_profile

profile "example":
  activity default:
    jq

  activity develop:
    fd
    when linux():
      htop

  hosts:
    "laptop": [default, develop]
    "server": [default]
```

The names are reprobuild's canonical package names. The catalog says where
each comes from on each platform, nixpkgs included.

## What works differently

A profile is a typed program. `home.nim` is Nim, so a misspelt activity or a
host that names an undeclared activity is an error when the profile compiles,
before anything is applied.

Platforms are decided when the profile is read, not when it is written. A
runtime predicate such as `when linux():` travels in the profile's export as
data, so one profile, exported on Linux, also describes your Mac.

reprobuild runs on Windows as well as Linux and macOS, and the same profile
can describe all three.

reprobuild applies a home profile by itself, without a Nix evaluation. It can
also leave applying to Home Manager and only supply the facts, which is how
you move over.

## Moving over side by side

You do not switch every host and every concern on one day. Each concern of
each host (packages, applications, files, environment, services, settings)
moves on its own, and every stage below leaves a working host.

### Keep Home Manager, and drive it from the profile

The profile becomes the only place a package is named. You export it, and
`reprobuild.homeManagerModules.intent` gives Home Manager the packages each
host selects: [Drive Home Manager from a home profile](../guides/machines/drive-home-manager-from-a-profile.md).
On a Mac, applications can still go to Homebrew:
[Install a profile's applications with Homebrew](../guides/machines/install-applications-with-homebrew.md).

### Measure

A flake check compares what the Home Manager configuration gives a host with
what the profile declares for it, per category:
[Compare a Home Manager configuration with a profile](../guides/machines/compare-with-home-manager.md).

### Let reprobuild apply one concern

When the comparison is clean for a concern, name it in the host's entry.
`repro home apply` then applies that concern on that host and Home Manager
applies the rest. With `applies:` declared, each of the module's categories
is on unless reprobuild applies its concern, so remove any explicit
`enable` you set and let the declaration decide:

```nim fragment
hosts:
  "laptop":
    activities: [default, develop]
    applies: [packages]
```

### Retire the Nix side of a concern

Once reprobuild applies a concern on every host, remove the module's category
for it (`packages`, `homebrew`, `files` or `environment`), and the module once
it has none left. Services and settings have no category: the module only
reports them.

### Moving a concern back

Remove the concern from `applies:`, and leave `applies: []` when it was the
last one: an entry with no `applies:` line hands every concern to reprobuild.
Files are the exception. Files that reprobuild placed stay where they are,
and Home Manager refuses to replace a file whose content differs from its
own, so remove them before you hand files back.

### The operating system

NixOS stays in charge of the operating system for as long as you want. A
host's entry can declare that its system is configured elsewhere, and
`repro infra` then leaves the system alone. A home profile works on top of
any system.

## What reprobuild does not do

- It does not evaluate Nix, and has no counterpart to Home Manager's program modules (`programs.git`, `programs.zsh`) that turn options into configuration files. A profile places files you write or generate.
- It does not read a Home Manager or NixOS configuration. The comparison reads the facts that Home Manager's evaluation produces, through reprobuild's Nix library.
- It does not install bootloader entries or rebuild a NixOS system.

## When Home Manager or NixOS remains the better choice

- Your configuration leans on Home Manager's program modules, and writing the files they generate yourself would cost more than it saves.
- Your machines run NixOS and you want the whole system, kernel and boot included, from one evaluation with bootloader generations.
- Every machine you configure runs Linux or macOS, Nix already applies everything you need, and nothing is written twice.

## Next steps

- [Drive Home Manager from a home profile](../guides/machines/drive-home-manager-from-a-profile.md)
- [Export a home profile for Nix](../guides/machines/export-a-home-profile.md)
- [Compare a Home Manager configuration with a profile](../guides/machines/compare-with-home-manager.md)
- [Machines and profiles](../concepts/machines-and-profiles.md)
