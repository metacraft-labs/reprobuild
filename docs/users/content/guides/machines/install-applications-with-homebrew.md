---
title: Install a profile's applications with Homebrew
description: On a Mac whose applications Homebrew installs, name them once in a home profile and have your Nix configuration hand Homebrew the cask and formula tokens, through reprobuild's Homebrew bridge records.
kind: how-to
persona: machine-owner
domain: machines
order: 50
platforms: [linux]
verifies:
  commands: [home export]
  tests:
    - nix/tests/home-manager.nix
    - nix/tests/lib.nix
unverified:
  - claim: "The captured output on this page."
    reason: "Evaluated on Linux, for an aarch64-darwin Home Manager configuration, with the reprobuild flake at 84b459adda; nothing was installed on a Mac and no scenario re-runs it."
    owner: unassigned
  - claim: "A nix-darwin homebrew module installs the casks the module lists."
    reason: "Not run; nix-darwin's homebrew module is outside reprobuild, and the page only passes it the list."
    owner: unassigned
---

# Install a profile's applications with Homebrew

This page shows how to keep Homebrew as the installer of a Mac's
applications while the profile, not your Nix configuration, says which
applications the Mac gets.

## Before you start

- A Home Manager configuration that reads a home profile through `reprobuild.homeManagerModules.intent` ([Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md)).
- Something that installs Homebrew casks and formulae from a list, such as nix-darwin's `homebrew` module. Home Manager has no Homebrew option.

reprobuild never installs anything through Homebrew. It keeps bridge
records that say which cask or formula installs each canonical package, in
the [reprobuild-brew-packages](https://github.com/metacraft-labs/reprobuild-brew-packages)
catalog, so a Nix configuration can name applications by the profile's names.

## Steps

### 1. Name the application in the profile

Add it to an activity by its canonical name, as any other package:

```nim fragment
activity desktop:
  vscode
```

Export the profile again ([Export a home profile for Nix](export-a-home-profile.md)).

### 2. Turn on the module's Homebrew category

```nix
reprobuild.intent = {
  enable = true;
  host = "mac";
  snapshot = ./home-export.json;
  packages.enable = true;
  homebrew.enable = true;
};
```

With `homebrew` on, a package that the bridge records claim for the host's
system goes to `reprobuild.intent.homebrew.casks` or
`reprobuild.intent.homebrew.formulae` instead of `home.packages`. A cask is
claimed only on macOS; a formula on macOS and Linux.

### 3. Pass the lists to Homebrew

Give your Homebrew module the two lists. In a nix-darwin configuration that
runs Home Manager as a module for the user `alice`:

```nix
homebrew.casks = config.home-manager.users.alice.reprobuild.intent.homebrew.casks;
homebrew.brews = config.home-manager.users.alice.reprobuild.intent.homebrew.formulae;
```

## Look up a token

The library answers both directions, which helps when you move a Brewfile
into a profile. From your flake's directory:

```bash
nix eval --json --impure --expr '(builtins.getFlake (toString ./.)).inputs.reprobuild.lib.lookupBrewToken { token = "visual-studio-code"; }'
```

<!-- generated:begin capture install-applications-with-homebrew lookup-token fields="found,kind,name,token" -->
```text
{"found":true,"kind":"cask","name":"vscode","token":"visual-studio-code"}
```
<!-- generated:end -->

A token no record claims comes back with `found = false` and the reason,
never with a guess. `brewRealizationOf { name; system; }` goes the other way
and returns null for a package no record claims on that system.

## Check that it worked

Evaluate the list. The example's `mac` configuration is a standalone Home
Manager configuration, so its lists are under `homeConfigurations.mac`:

```bash
nix eval --json .#homeConfigurations.mac.config.reprobuild.intent.homebrew.casks
```

<!-- generated:begin capture install-applications-with-homebrew casks -->
```text
["visual-studio-code"]
```
<!-- generated:end -->

`vscode` is in the cask list as `visual-studio-code`, and not in
`home.packages`.

## Related

- [Drive Home Manager from a home profile](drive-home-manager-from-a-profile.md)
- [Compare a Home Manager configuration with a profile](compare-with-home-manager.md)
- [Coming from Home Manager and NixOS](../../coming-from/home-manager-and-nixos.md)
