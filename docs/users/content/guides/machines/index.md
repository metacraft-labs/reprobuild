---
title: Machines
description: Guides for configuring your account with a home profile, alongside Home Manager or in its place.
kind: explanation
persona: machine-owner
domain: machines
order: 0
---

# Machines

These guides cover [home profiles](../../reference/glossary.md#home-profile):
the tools, files and settings of your account, declared in `home.nim`.
[Machines and profiles](../../concepts/machines-and-profiles.md) explains
the ideas behind them, and
[Coming from Home Manager and NixOS](../../coming-from/home-manager-and-nixos.md)
the path from a Nix configuration.

| Guide | When |
|---|---|
| [Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md) | You keep Home Manager and want your package lists in one place, the profile |
| [Export a home profile for Nix](export-a-home-profile.md) | A Nix configuration or another tool reads what the profile selects |
| [Compare a Home Manager configuration with a profile](compare-with-home-manager.md) | You want to know that both give a host the same thing before you move a part of it |
| [Install a profile's applications with Homebrew](install-applications-with-homebrew.md) | Homebrew installs a Mac's applications, and the profile says which |
